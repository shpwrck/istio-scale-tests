#!/usr/bin/env bats
# tests/lib/redact-results.sh through its real entrypoint (PL33): what it replaces, what it
# learns the member names from and when it refuses, file and dir names, --in-place, the
# artifacts a sweep writes besides its TSV and reports (a controlplane --resume's
# resumes.txt and # RESUMED_AT lines, planned-cells.txt, the .sweep.lock it skips), and
# the file-name form of a context it shares with tuning and istiod-diag. Names are
# placeholders (ci-a, ctx-a), addresses come from the documentation ranges (192.0.2.0/24,
# 2001:db8::/32), hosts end in .example or .example.com.

bats_require_minimum_version 1.5.0
load test_helper

REDACT="${ROOT}/tests/lib/redact-results.sh"
CP="${ROOT}/tests/controlplane"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# --- a controlplane sweep's own artifacts --------------------------------------------

# _cp_stub: a kubectl that answers the Istio CR reads (fake-istio-cr.sh), lists no
# controlplane-test namespace and fails everything else, as against an empty kubeconfig:
# controlplane 003 runs, and every cell's probe fails (PROBE_FAILED).
_cp_stub() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" get namespaces -l app.kubernetes.io/instance=controlplane-test -o json"*) echo '{"items":[]}' ;;
*" get namespace -l app.kubernetes.io/instance=controlplane-test -o name"*|*" get ns -l app.kubernetes.io/instance=controlplane-test -o name"*) : ;;
*" delete namespace "*) : ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	: > "${BATS_TEST_TMPDIR}/kubeconfig"
}

# cp_sweep <args...>: controlplane 003 with the stub, its results under res/.
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" CONTROLPLANE_RESULTS_DIR="$RES" \
		ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0 \
		run --separate-stderr bash "$CP/003-run-sweep.sh" "$@"
}

@test "a resumed controlplane sweep: resumes.txt's member columns and the TSV's own lines are redacted, planned-cells.txt is copied, the lock file is not; 004 still tells the attempts apart in the copy" {
	_cp_stub
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 4 ]
	local d tsv out="${BATS_TEST_TMPDIR}/copy"
	d="$(find "$RES" -maxdepth 1 -name 'sweep-*' -type d)"
	cp_sweep --resume "$d" --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 4 ]
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	grep -q '^# RESUMED_AT=[^ ]* TSV_LINES=[0-9]* HARNESS_SHA=' "$tsv"
	# The resume's line names both members in its member columns.
	[[ "$(awk -F'\t' 'NR == 2 { print $4 "|" $6 "|" $7 }' "$d/resumes.txt")" == ci-a=*,ci-b=*"|"ci-a=*,ci-b=*"|"ci-a=*,ci-b=* ]]
	[ -s "$d/planned-cells.txt" ]
	# A run that died while it held the dir leaves its lock (the real sweep_lock).
	bash -c 'source "$1/tests/lib/common.sh"; sweep_lock "$2"' _ "$ROOT" "$d"
	[ -s "$d/.sweep.lock" ]
	run --separate-stderr "$REDACT" --out "$out" "$d"
	assert_success
	[[ "$stderr" == *"/.sweep.lock (a sweep's lock file: the PID of the run that held the dir)"* ]]
	local c="${out}/${d##*/}"
	[ ! -e "${c}/.sweep.lock" ]
	cmp "$d/planned-cells.txt" "${c}/planned-cells.txt"
	# resumes.txt: the header as it was, the member columns with placeholders, the TSV's
	# name (it names no member) as it was.
	[ "$(head -n 1 "${c}/resumes.txt")" = "$(head -n 1 "$d/resumes.txt")" ]
	[[ "$(awk -F'\t' 'NR == 2 { print $4 "|" $6 "|" $7 "|" $8 }' "${c}/resumes.txt")" == "<mesh-a-ctx>="*",<mesh-b-ctx>="*"|<mesh-a-ctx>="*",<mesh-b-ctx>="*"|<mesh-a-ctx>="*",<mesh-b-ctx>="*"|${tsv##*/}" ]]
	# The TSV's resume line, its header and its preamble's resume keys.
	[ "$(grep '^# RESUMED_AT=' "${c}/${tsv##*/}" | sed 's/ ISTIO_NOTREADY_AT_RESUME=.*//')" = "$(grep '^# RESUMED_AT=' "$tsv" | sed 's/ ISTIO_NOTREADY_AT_RESUME=.*//')" ]
	[[ "$(grep '^# RESUMED_AT=' "${c}/${tsv##*/}")" == *" KUBE_VERSIONS=<mesh-a-ctx>="*",<mesh-b-ctx>="* ]]
	[ "$(grep '^timestamp' "${c}/${tsv##*/}")" = "$(grep '^timestamp' "$tsv")" ]
	run grep -rlE '(^|[^A-Za-z0-9_<])ci-[ab]([^A-Za-z0-9_]|$)' "$out"
	assert_output ""
	# The copy still tells the attempts apart (resumes.txt applies to its TSV by name).
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$c" --format json
	assert_success
	[ "$(jq -r '.metadata.attempts | length' <<<"$output")" = 2 ]
	# resumes.txt alone: its member columns name the members, so it is not refused.
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/alone" "$d/resumes.txt"
	assert_success
	[[ "$stderr" == *"<mesh-a-ctx>     ci-a"* && "$stderr" == *"<mesh-b-ctx>     ci-b"* ]]
	run grep -cE '(^|[^<])ci-[ab]=' "${BATS_TEST_TMPDIR}/alone/resumes.txt"
	assert_output 0
}

@test "a TSV's header row is redacted like any other line; its column names still pick the context columns the scan checks" {
	local d="${RES}/s" out="${BATS_TEST_TMPDIR}/copy"
	mkdir -p "$d"
	# A TSV without a header: its first row is the line read as one.
	printf '# CONTEXTS=ci-a,ci-b\nr1\tci-a\t192.0.2.10\tapi.cluster-1.example.com\nr2\tci-b\t192.0.2.11\t-\n' > "${d}/headerless.tsv"
	printf '# CONTEXTS=ci-a,ci-b\nrun_id\tcontext\tdetail\nr1\tci-a\t-\nr1\tci-z\t-\n' > "${d}/ctxcol.tsv"
	run --separate-stderr "$REDACT" --out "$out" "$d"
	assert_failure
	# The context column of the other file still holds a name it was not told about.
	[[ "$stderr" == *"ctxcol.tsv: refused, not written:"*"column context holds ci-z"* ]]
	[ ! -e "${out}/s/ctxcol.tsv" ]
	run cat "${out}/s/headerless.tsv"
	assert_line $'r1\t<mesh-a-ctx>\t<ip>\t<api-host>'
	assert_line $'r2\t<mesh-b-ctx>\t<ip>\t-'
	rm -rf "$out"
	run --separate-stderr "$REDACT" --out "$out" --context ci-z "$d"
	assert_success
	# A named context takes the first letter (ci-z), the learned ones follow.
	run cat "${out}/s/ctxcol.tsv"
	assert_line $'run_id\tcontext\tdetail'
	assert_line $'r1\t<mesh-b-ctx>\t-'
	assert_line $'r1\t<mesh-a-ctx>\t-'
}

@test "a tuning sweep's raw copies of the Istio CR (istio-spec/, state/istio-before-*.json) are named and never copied; the revert patch is" {
	local d="${RES}/sweep-t1" out="${BATS_TEST_TMPDIR}/copy"
	mkdir -p "${d}/istio-spec" "${d}/01-x/state"
	printf '# CONTEXTS=ci-a\n# SUITE=controlplane\n' > "${d}/sweep-metadata.txt"
	printf '{"values":{"global":{"meshID":"mesh1","multiCluster":{"clusterName":"cluster-one"},"network":"cluster-one-network"}}}\n' > "${d}/istio-spec/start-ci-a.json"
	cp "${d}/istio-spec/start-ci-a.json" "${d}/istio-spec/end-ci-a.json"
	printf '{"metadata":{"name":"default"},"spec":{"values":{"global":{"multiCluster":{"clusterName":"cluster-one"}}}}}\n' > "${d}/01-x/state/istio-before-ci-a.json"
	printf '{"spec":{"values":{"pilot":{"env":{"PILOT_DEBOUNCE_AFTER":null}}}}}\n' > "${d}/01-x/state/istio-revert-ci-a.json"
	run --separate-stderr "$REDACT" --out "$out" "$d"
	assert_success
	[[ "$stderr" == *"istio-spec/start-ci-a.json (a raw copy of an Istio CR: keeps the cluster and network names, never paste it)"* ]]
	[[ "$stderr" == *"01-x/state/istio-before-ci-a.json (a raw copy of an Istio CR"* ]]
	[ ! -e "${out}/sweep-t1/istio-spec" ]
	[ ! -e "${out}/sweep-t1/01-x/state/istio-before-mesh-a-ctx.json" ]
	jq -e '.spec.values.pilot.env | has("PILOT_DEBOUNCE_AFTER")' "${out}/sweep-t1/01-x/state/istio-revert-mesh-a-ctx.json"
	run grep -rl 'cluster-one' "$out"
	assert_output ""
}

# --- what it replaces, learns and refuses; file and dir names --------------------------

# _redact_fixture <dir>: a sweep dir that names ci-a, ci-b, ci-c, an API URL, IPs, an
# email, an ARN, cluster hosts, a home dir, and raw istiod-diag evidence.
_redact_fixture() {
	local d="$1/sweep-r1"
	mkdir -p "${d}/istiod-diag-r1/001-restart-ci-a"
	cat > "${d}/endpoint-r1.tsv" <<'EOF'
# SOURCE_CTX=ci-a
# REMOTES=ci-b ci-c
# ISTIO_VERSION_BY_CONTEXT=ci-a=1.30.5,ci-b=1.30.5,ci-c=1.30.4
# ISTIO_PROXY_VERSIONS=ci-a=1.30.5:120+1.30.4:3,ci-b=1.30.5:10,ci-c=unknown
# RUN_CONFIG=/home/someone/run.env
run_id	mesh_size	iteration	source_ctx	remote_ctx	status	detail
r1	3	1	ci-a	ci-b	OK	-
r1	3	1	ci-a	ci-c	TIMEOUT_P3	Get "https://api.cluster-1.example.com:6443/api?timeout=32s": dial tcp 192.0.2.10:6443: i/o timeout
EOF
	cat > "${d}/reach-r1.tsv" <<'EOF'
run_id	source_ctx	target_ctx	detail
r1	ci-a	ci-b	fortio-server-ci-b.ns.svc.cluster.local from 2001:db8::1 via [2001:db8::2]:8080
r1	ci-a	ci-c	upstream ip-192-0-2-7.ec2.internal at 192.0.2.12
EOF
	printf 'run_id\tcontext\tfolder\nr1\tci-a\t001-restart-ci-a\n' > "${d}/istiod-diag-r1/index.tsv"
	echo 'raw log from api.cluster-1.example.com' > "${d}/istiod-diag-r1/001-restart-ci-a/istiod.log.txt"
	cat > "${d}/report.md" <<'EOF'
ISTIO_ACTIVE_REVISIONS: "mixed:ci-a=default,ci-b=default | ci-a=canary"
| ISTIO_PROXY_VERSIONS | `ci-a=1.30.5:120\|ci-b=1.30.5` |
Owner user@example.com, role arn:aws:iam::123456789012:role/x
Console console-openshift-console.apps.cluster-1.example.com and lb a1b2.elb.amazonaws.com
On ci-a, ci-b and ci-c; ci-ab is another word.
EOF
	printf '{"metadata":{"istio_version_by_context":"ci-a=1.30.5,ci-b=1.30.5"},"rows":[{"source_ctx":"ci-a","target_ctx":"ci-c","url":"https://192.0.2.7:6443/x"}]}\n' > "${d}/report.json"
	printf 'RUN_ID=r1\nNOTE=not ready at the start: IstiodNotReady on 2 members (ci-a, ci-b)\n' > "${d}/sweep-outcome.txt"
	printf 'PNG' > "${d}/chart.png"
}

# _ids_fixture <dir>: a sweep dir whose TSV names ci-a and ci-b and holds AWS resource ids,
# with files and dirs named after a context (a tuning pass and its revert state, a note),
# and raw istiod-diag evidence named after one.
_ids_fixture() {
	local d="$1/sweep-r9"
	mkdir -p "${d}/pass-1-ci-a/state" "${d}/istiod-diag-r9/001-restart-ci-b"
	cat > "${d}/run-r9.tsv" <<'TSV'
# CONTEXTS=ci-a,ci-b
run_id	context	detail
r9	ci-a	vpc-0123abcd subnet-0123456789abcdef0 sg-deadbeef,i-0123456789abcdef0 eni-12345678 vol-0a1b2c3d igw-00000000 nat-ffffffff rtb-a1b2c3d4 (vpc-0123abcd) "subnet-0123abcd"
r9	ci-b	stays: sg-0123abcd0123 my-sg-0123abcd sg-0123abcdx i-0123ABCD vpc-0123abc i-0123456789abcdef01 vpce-0123abcd
TSV
	echo '{"ok":true}' > "${d}/pass-1-ci-a/state/istio-revert-ci-a.json"
	echo 'on ci-b' > "${d}/notes-ci-b.md"
	echo 'raw' > "${d}/istiod-diag-r9/001-restart-ci-b/istiod.log.txt"
}

CP_REPORT="${ROOT}/tests/controlplane/004-report-results.sh"

# _envelope <dir>: the scale envelope 003 writes, alone in <dir>: the real renderer (no
# cluster: kubectl is `false`) over a controlplane run on ci-a and ci-b whose preamble
# records each member's Istio version.
_envelope() {
	local d="$1" run="${BATS_TEST_TMPDIR}/cp-run"
	mkdir -p "$run" "$d"
	awk '{ gsub(/mesh-a/, "ci-a"); gsub(/mesh-b/, "ci-b"); print }
		/^# ISTIO_VERSION=/ { v = $0; sub(/^# ISTIO_VERSION=/, "", v)
			print "# ISTIO_VERSION_SOURCE=live"; print "# ISTIO_VERSION_PIN=" v
			print "# ISTIO_VERSION_BY_CONTEXT=ci-a=" v ",ci-b=" v }' \
		"${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" > "${run}/controlplane-fixture-t2.tsv"
	(
		source "${ROOT}/tests/lib/capacity.sh"
		source "${ROOT}/tests/lib/envelope.sh"
		source "${ROOT}/tests/lib/platform.sh"
		render_scale_envelope "$run" "$CP_REPORT" "ci-a,ci-b" false
	) > "${d}/scale-envelope-t2.md" 2>/dev/null
}


@test "redact-results --out: placeholders for every context, URL, IP, email, account and host; mapping on stderr only; input untouched" {
	_redact_fixture "$RES"
	local before after out="${BATS_TEST_TMPDIR}/copy"
	before="$(cd "$RES" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r1"
	assert_success
	[[ "$stderr" == *"istiod-diag-r1/001-restart-ci-a/istiod.log.txt (raw istiod-diag evidence"* ]]
	[[ "$stderr" == *"chart.png (not a .tsv/.md/.txt/.csv/.json file)"* ]]
	after="$(cd "$RES" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
	[ "$before" = "$after" ]
	# The mapping: stderr only, sorted names.
	[[ "$stderr" == *"<mesh-a-ctx>     ci-a"* && "$stderr" == *"<mesh-c-ctx>     ci-c"* ]]
	refute_output --partial "ci-a"
	local c="${out}/sweep-r1"
	run cat "${c}/endpoint-r1.tsv"
	assert_line "# SOURCE_CTX=<mesh-a-ctx>"
	assert_line "# REMOTES=<mesh-b-ctx> <mesh-c-ctx>"
	assert_line "# ISTIO_PROXY_VERSIONS=<mesh-a-ctx>=1.30.5:120+1.30.4:3,<mesh-b-ctx>=1.30.5:10,<mesh-c-ctx>=unknown"
	assert_line "# RUN_CONFIG=<home>/run.env"
	assert_line $'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tstatus\tdetail'
	assert_line $'r1\t3\t1\t<mesh-a-ctx>\t<mesh-c-ctx>\tTIMEOUT_P3\tGet "<api-host>": dial tcp <ip>:6443: i/o timeout'
	run cat "${c}/reach-r1.tsv"
	assert_line $'r1\t<mesh-a-ctx>\t<mesh-b-ctx>\tfortio-server-<mesh-b-ctx>.ns.svc.cluster.local from <ip> via <ip>:8080'
	assert_line $'r1\t<mesh-a-ctx>\t<mesh-c-ctx>\tupstream <host> at <ip>'
	run cat "${c}/istiod-diag-r1/index.tsv"
	assert_line $'r1\t<mesh-a-ctx>\t001-restart-<mesh-a-ctx>'
	run cat "${c}/report.md"
	assert_line 'ISTIO_ACTIVE_REVISIONS: "mixed:<mesh-a-ctx>=default,<mesh-b-ctx>=default | <mesh-a-ctx>=canary"'
	assert_line 'Owner <email>, role arn:aws:iam::<account>:role/x'
	assert_line 'Console <host> and lb <host>'
	assert_line 'On <mesh-a-ctx>, <mesh-b-ctx> and <mesh-c-ctx>; ci-ab is another word.'
	jq -e '.rows[0].source_ctx == "<mesh-a-ctx>" and .rows[0].url == "<api-host>"' "${c}/report.json"
	grep -qx 'NOTE=not ready at the start: IstiodNotReady on 2 members (<mesh-a-ctx>, <mesh-b-ctx>)' "${c}/sweep-outcome.txt"
	# Raw evidence and other file types are not copied, and say so on stderr.
	[ ! -e "${c}/istiod-diag-r1/001-restart-ci-a" ]
	[ ! -e "${c}/chart.png" ]
	# Nothing identifying is left anywhere in the copy.
	run grep -rlE 'ci-[abc]([^A-Za-z0-9_]|$)|192\.0\.2|2001:db8|example\.com|amazonaws|123456789012|someone' "$out"
	assert_output ""
	# A second run over the copy finds nothing more to change.
	run "$REDACT" --dry-run "$out"
	assert_success
	refute_output --partial "  would change  "
	assert_output --partial "6 file(s), 0 would change, 0 refused"
}

@test "redact-results --dry-run writes nothing and lists the changes; no mode at all is refused" {
	_redact_fixture "$RES"
	local out="${BATS_TEST_TMPDIR}/copy"
	run --separate-stderr "$REDACT" --dry-run --out "$out" "${RES}/sweep-r1"
	assert_success
	[ ! -e "$out" ]
	assert_output --partial "dry run, nothing written"
	assert_line --regexp "^  would change  .*/sweep-r1/endpoint-r1\.tsv \([0-9]+ line\(s\): context [0-9]+, url 1, ip 1, home 1\)$"
	assert_line --regexp "^  would change  .*/sweep-r1/report\.md \([0-9]+ line\(s\): context [0-9]+, account 1, email 1, host 2\)$"
	run --separate-stderr "$REDACT" "${RES}/sweep-r1"
	assert_failure
	[[ "$stderr" == *"say where the redacted files go"* ]]
	run --separate-stderr "$REDACT" --out "${RES}/sweep-r1/x" "${RES}/sweep-r1"
	assert_failure
	[[ "$stderr" == *"overlap"* ]]
	mkdir -p "$out" && touch "${out}/old.md"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r1"
	assert_failure
	[[ "$stderr" == *"is not empty"* ]]
	run "$REDACT" --help
	assert_success
	local flag
	for flag in --out --in-place --dry-run --context --hub-context --help; do assert_output --partial -- "$flag"; done
}

@test "a context column naming a member the metadata does not: exit 1, the file named and not written; --context maps it" {
	_redact_fixture "$RES"
	printf 'r1\tci-a\tci-z\t-\n' >> "${RES}/sweep-r1/reach-r1.tsv"
	local out="${BATS_TEST_TMPDIR}/copy"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r1"
	assert_failure
	[[ "$stderr" == *"/sweep-r1/reach-r1.tsv: refused, not written:"* ]]
	[[ "$stderr" == *"column target_ctx holds ci-z, a context it was not told about (pass --context ci-z)"* ]]
	[ ! -e "${out}/sweep-r1/reach-r1.tsv" ]
	[ -e "${out}/sweep-r1/endpoint-r1.tsv" ]
	rm -rf "$out"
	run --separate-stderr "$REDACT" --out "$out" --context ci-z --hub-context ci-hub "${RES}/sweep-r1"
	assert_success
	# A named context takes the first letter; the hub has its own placeholder.
	[[ "$stderr" == *"<mesh-a-ctx>     ci-z"* && "$stderr" == *"<hub-a-ctx>      ci-hub"* ]]
	grep -qx $'r1\t<mesh-b-ctx>\t<mesh-a-ctx>\t-' "${out}/sweep-r1/reach-r1.tsv"
}

@test "--in-place rewrites only a file that passes the scan; a JSON file stays valid JSON" {
	_redact_fixture "$RES"
	local d="${RES}/sweep-r1"
	run --separate-stderr "$REDACT" --in-place "${d}/endpoint-r1.tsv" "${d}/report.json"
	assert_success
	grep -qx '# SOURCE_CTX=<mesh-a-ctx>' "${d}/endpoint-r1.tsv"
	jq -e '.rows[0].target_ctx == "<mesh-c-ctx>"' "${d}/report.json"
	# A file the scan refuses keeps its content.
	cp "${d}/reach-r1.tsv" "${BATS_TEST_TMPDIR}/reach.orig"
	run --separate-stderr "$REDACT" --in-place "${d}/reach-r1.tsv"
	assert_failure
	cmp "${d}/reach-r1.tsv" "${BATS_TEST_TMPDIR}/reach.orig"
}

@test "a real controlplane sweep (TSV, markdown and json reports, scale envelope md) redacts; the envelope is left as is" {
	local d="${RES}/sweep-t2" out="${BATS_TEST_TMPDIR}/copy" rep="${ROOT}/tests/controlplane/004-report-results.sh"
	mkdir -p "$d"
	cp "${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" "${d}/controlplane-fixture-t2.tsv"
	"$rep" --results-dir "$d" --format markdown > "${d}/summary-t2.md" 2>/dev/null
	"$rep" --results-dir "$d" --format json > "${d}/report-t2.json" 2>/dev/null
	# The envelope as 003 writes it: the real renderer, no cluster (kubectl is `false`).
	(
		source "${ROOT}/tests/lib/capacity.sh"
		source "${ROOT}/tests/lib/envelope.sh"
		source "${ROOT}/tests/lib/platform.sh"
		render_scale_envelope "$d" "$rep" "mesh-a,mesh-b" false
	) > "${d}/scale-envelope-t2.md" 2>/dev/null
	grep -q '^## Scale envelope' "${d}/scale-envelope-t2.md"
	run --separate-stderr "$REDACT" --out "$out" "$d"
	assert_success
	[[ "$stderr" == *"<mesh-a-ctx>     mesh-a"* && "$stderr" == *"<mesh-b-ctx>     mesh-b"* ]]
	assert_output --partial "4 of 4 file(s) written"
	local c="${out}/sweep-t2"
	# The envelope names no member: copied byte for byte (no metric or path mangled).
	cmp "${d}/scale-envelope-t2.md" "${c}/scale-envelope-t2.md"
	run grep -rlE '(^|[^<])mesh-[ab]' "$out"
	assert_output ""
	jq -e '.metadata.proxy_check.flagged == "<mesh-a-ctx>@2026-06-01T00:10:00+00:00:LOW:30/40"' "${c}/report-t2.json"
	# Same columns and the same header row as the input.
	[ "$(awk -F'\t' '!/^#/ { print NF }' "${c}/controlplane-fixture-t2.tsv" | sort -u)" = 51 ]
	[ "$(grep -v '^#' "${d}/controlplane-fixture-t2.tsv" | head -1)" = "$(grep -v '^#' "${c}/controlplane-fixture-t2.tsv" | head -1)" ]
	run "$REDACT" --dry-run "$out"
	assert_success
	assert_output --partial "4 file(s), 0 would change, 0 refused"
}

@test "redact-results masks AWS resource ids with 8 or 17 hex digits, as its own word; a 12-digit suffix, a longer one, upper case or a longer name stays" {
	_ids_fixture "$RES"
	local out="${BATS_TEST_TMPDIR}/copy"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r9"
	assert_success
	run cat "${out}/sweep-r9/run-r9.tsv"
	assert_line $'r9\t<mesh-a-ctx>\t<vpc-id> <subnet-id> <sg-id>,<instance-id> <eni-id> <volume-id> <igw-id> <nat-id> <rtb-id> (<vpc-id>) "<subnet-id>"'
	assert_line $'r9\t<mesh-b-ctx>\tstays: sg-0123abcd0123 my-sg-0123abcd sg-0123abcdx i-0123ABCD vpc-0123abc i-0123456789abcdef01 vpce-0123abcd'
	# The dry run counts them as their own kind.
	run "$REDACT" --dry-run "${RES}/sweep-r9"
	assert_success
	assert_line --regexp '^  would change  .*/sweep-r9/run-r9\.tsv \(3 line\(s\): context [0-9]+, aws-id 11\)$'
}

@test "--out renames a file or dir whose name holds a context (no angle brackets), lists each rename on stderr only, and the copy names no context in a path" {
	_ids_fixture "$RES"
	local out="${BATS_TEST_TMPDIR}/copy" before after
	before="$(cd "$RES" && find . | LC_ALL=C sort)"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r9"
	assert_success
	assert_output --partial "3 of 3 file(s) written under ${out}, 0 refused, 2 renamed"
	refute_output --partial "ci-a"
	refute_output --partial "ci-b"
	[[ "$stderr" == *"renamed in the copy (stderr only):"* ]]
	[[ "$stderr" == *"sweep-r9/pass-1-ci-a/state/istio-revert-ci-a.json -> sweep-r9/pass-1-mesh-a-ctx/state/istio-revert-mesh-a-ctx.json"* ]]
	[[ "$stderr" == *"sweep-r9/notes-ci-b.md -> sweep-r9/notes-mesh-b-ctx.md"* ]]
	[ -f "${out}/sweep-r9/pass-1-mesh-a-ctx/state/istio-revert-mesh-a-ctx.json" ]
	grep -qx 'on <mesh-b-ctx>' "${out}/sweep-r9/notes-mesh-b-ctx.md"
	# No path in the copy names a context; the input is untouched.
	run find "$out" -name '*ci-[ab]*'
	assert_output ""
	after="$(cd "$RES" && find . | LC_ALL=C sort)"
	[ "$before" = "$after" ]
	# A dir given by a context's name is renamed in the copy too.
	mv "${RES}/sweep-r9" "${RES}/ci-a"
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/copy2" "${RES}/ci-a"
	assert_success
	[ -f "${BATS_TEST_TMPDIR}/copy2/mesh-a-ctx/run-r9.tsv" ]
	[ ! -e "${BATS_TEST_TMPDIR}/copy2/ci-a" ]
	# The file-name form of a name (other characters as _) maps to the same placeholder.
	mkdir -p "${RES}/s2"
	printf '# CONTEXTS=ns/api-c1:6443/admin,ci-b\n' > "${RES}/s2/run.tsv"
	echo '{}' > "${RES}/s2/istio-revert-ns_api-c1_6443_admin.json"
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/copy3" "${RES}/s2"
	assert_success
	[ -f "${BATS_TEST_TMPDIR}/copy3/s2/istio-revert-mesh-b-ctx.json" ]
	grep -qx '# CONTEXTS=<mesh-b-ctx>,<mesh-a-ctx>' "${BATS_TEST_TMPDIR}/copy3/s2/run.tsv"
}

@test "--in-place renames below the given dir and a given file, removes the emptied old dirs, and lists what still names a context (skipped files); a dry run renames nothing" {
	_ids_fixture "$RES"
	local d="${RES}/sweep-r9"
	run --separate-stderr "$REDACT" --dry-run --in-place "$d"
	assert_success
	assert_output --partial "3 file(s), 2 would change, 0 refused, 2 would be renamed"
	[[ "$stderr" == *"file and dir names it would rename (stderr only):"* ]]
	[ -f "${d}/notes-ci-b.md" ]
	run --separate-stderr "$REDACT" --in-place "$d"
	assert_success
	assert_output --partial "3 file(s), 2 rewritten in place, 0 refused, 2 renamed"
	[ -f "${d}/pass-1-mesh-a-ctx/state/istio-revert-mesh-a-ctx.json" ]
	[ -f "${d}/notes-mesh-b-ctx.md" ]
	[ ! -e "${d}/pass-1-ci-a" ]
	[ ! -e "${d}/notes-ci-b.md" ]
	# The raw evidence is skipped, so it keeps its name: listed once, by its topmost path.
	[ -f "${d}/istiod-diag-r9/001-restart-ci-b/istiod.log.txt" ]
	[[ "$stderr" == *"still named after a context, neither redacted nor renamed"* ]]
	grep -qxF "  ${d}/istiod-diag-r9/001-restart-ci-b" <<<"$stderr"
	! grep -qxF "  ${d}/istiod-diag-r9/001-restart-ci-b/istiod.log.txt" <<<"$stderr" || false
	# A second run finds nothing more to rename.
	run --separate-stderr "$REDACT" --in-place "$d"
	assert_success
	assert_output --partial "0 refused, 0 renamed"
	# A given file is renamed where it is.
	printf 'on ci-c\n' > "${RES}/note-ci-c.md"
	run --separate-stderr "$REDACT" --in-place --context ci-c "${RES}/note-ci-c.md"
	assert_success
	grep -qx 'on <mesh-a-ctx>' "${RES}/note-mesh-a-ctx.md"
	[ ! -e "${RES}/note-ci-c.md" ]
}

@test "--in-place refuses, before it writes anything, a given dir named after a context, a rename onto a path that exists, and two files that land at one name" {
	_ids_fixture "$RES"
	local before
	_tree_sum() { (cd "$RES" && find . -print && find . -type f -exec cksum {} +) | LC_ALL=C sort; }
	mv "${RES}/sweep-r9" "${RES}/ci-a"
	before="$(_tree_sum)"
	run --separate-stderr "$REDACT" --in-place "${RES}/ci-a"
	assert_failure
	[[ "$stderr" == *"holds a context name in its own name, and --in-place renames only what is below it"* ]]
	[ "$before" = "$(_tree_sum)" ]
	# The new name is taken by a path the run does not list (a dir): mv would move the
	# file into it.
	mkdir -p "${RES}/x/a-mesh-a-ctx.md"
	printf '# CONTEXTS=ci-b\n' > "${RES}/x/run.tsv"
	printf 'on ci-b\n' > "${RES}/x/a-ci-b.md"
	before="$(_tree_sum)"
	run --separate-stderr "$REDACT" --in-place "${RES}/x"
	assert_failure
	[[ "$stderr" == *"x/a-ci-b.md would be renamed to ${RES}/x/a-mesh-a-ctx.md, which exists"* ]]
	[ "$before" = "$(_tree_sum)" ]
	# Two listed files that land at one name.
	rmdir "${RES}/x/a-mesh-a-ctx.md"
	printf 'other\n' > "${RES}/x/a-mesh-a-ctx.md"
	run --separate-stderr "$REDACT" --in-place "${RES}/x"
	assert_failure
	[[ "$stderr" == *"two files land at x/a-mesh-a-ctx.md once their names are redacted"* ]]
	grep -qx 'on ci-b' "${RES}/x/a-ci-b.md"
	grep -qx '# CONTEXTS=ci-b' "${RES}/x/run.tsv"
	# --out refuses it the same way.
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/copy" "${RES}/x"
	assert_failure
	[[ "$stderr" == *"two files land at x/a-mesh-a-ctx.md"* ]]
	[ ! -e "${BATS_TEST_TMPDIR}/copy" ]
	# A renamed dir whose new name is a file (one the run skips): mv cannot go below it.
	rm "${RES}/x/a-mesh-a-ctx.md"
	mkdir -p "${RES}/x/d-ci-b" && printf 'on ci-b\n' > "${RES}/x/d-ci-b/n.md" && printf 'x' > "${RES}/x/d-mesh-a-ctx"
	before="$(_tree_sum)"
	run --separate-stderr "$REDACT" --in-place "${RES}/x"
	assert_failure
	[[ "$stderr" == *"x/d-ci-b/n.md would move below ${RES}/x/d-mesh-a-ctx, which is not a dir"* ]]
	[ "$before" = "$(_tree_sum)" ]
}

@test "redact-results: a scale envelope redacted alone learns the members from its by member list; the copy names none and redacts again" {
	local e="${RES}/env" out="${BATS_TEST_TMPDIR}/copy"
	_envelope "$e"
	grep -q 'by member ci-a=1\.30\.5,ci-b=1\.30\.5' "${e}/scale-envelope-t2.md"
	run --separate-stderr "$REDACT" --out "$out" "$e"
	assert_success
	[[ "$stderr" =~ \<mesh-a-ctx\>\ +ci-a && "$stderr" =~ \<mesh-b-ctx\>\ +ci-b ]]
	grep -q 'by member <mesh-a-ctx>=1\.30\.5,<mesh-b-ctx>=1\.30\.5' "${out}/env/scale-envelope-t2.md"
	run grep -rlE '(^|[^<])ci-[ab]' "$out"
	assert_output ""
	# The copy: its by member list names members by placeholder only, so a second run
	# (here a dry run) passes and changes nothing.
	run --separate-stderr "$REDACT" --dry-run "$out"
	assert_success
	assert_output --partial "1 file(s), 0 would change, 0 refused"
	[[ "$stderr" == *"(none: the files' metadata names members by placeholder only"* ]]
}

@test "redact-results: files it learns no member from are refused (exit 1, nothing written) unless --context names them or --no-contexts says they name none" {
	local d="${RES}/lone" out="${BATS_TEST_TMPDIR}/copy"
	mkdir -p "$d"
	# A summary that names members in prose only: nothing to learn them from.
	printf '# Summary\n\nci-a answered, ci-b did not.\n' > "${d}/summary.md"
	cp "${d}/summary.md" "${BATS_TEST_TMPDIR}/orig.md"
	run --separate-stderr "$REDACT" --out "$out" "$d"
	assert_failure 1
	[[ "$stderr" == *"no member context found"*"--context NAME"*"--no-contexts"*"nothing written"* ]]
	[ ! -e "$out" ]
	run --separate-stderr "$REDACT" --in-place "$d"
	assert_failure 1
	cmp "${d}/summary.md" "${BATS_TEST_TMPDIR}/orig.md"
	run --separate-stderr "$REDACT" --dry-run "$d"
	assert_failure 1
	# Named on the command line, as one comma list.
	run --separate-stderr "$REDACT" --context ci-a,ci-b --out "$out" "$d"
	assert_success
	grep -qx '<mesh-a-ctx> answered, <mesh-b-ctx> did not.' "${out}/lone/summary.md"
	# Files that name no kube context: --no-contexts runs the other checks.
	rm -rf "$out"
	printf 'p99 12 ms on 192.0.2.10\n' > "${d}/summary.md"
	run --separate-stderr "$REDACT" --no-contexts --out "$out" "$d"
	assert_success
	# The mapping says the names were not checked, never that the files name none.
	[[ "$stderr" == *"  none: not checked (--no-contexts): read the copy for member names"* ]]
	[[ "$stderr" != *"name no kube context"* ]]
	grep -qx 'p99 12 ms on <ip>' "${out}/lone/summary.md"
}

@test "redact-results: --context and --hub-context split a comma list and refuse a name with a space or no name; --help lists --no-contexts and TMPDIR" {
	local d="${RES}/s"
	mkdir -p "$d"
	printf 'ci-a and hub-x\n' > "${d}/n.md"
	run --separate-stderr "$REDACT" --context 'ci-a,my ctx' --dry-run "$d"
	assert_failure
	[[ "$stderr" == *"--context 'my ctx': a context name has no spaces"* ]]
	run --separate-stderr "$REDACT" --context '' --dry-run "$d"
	assert_failure
	[[ "$stderr" == *"--context needs a context name"* ]]
	run --separate-stderr "$REDACT" --hub-context ' , ' --dry-run "$d"
	assert_failure
	[[ "$stderr" == *"--hub-context needs a context name"* ]]
	# Spaces around a comma are trimmed (split_csv), as everywhere else.
	run --separate-stderr "$REDACT" --context 'ci-a, ci-b' --hub-context hub-x --dry-run "$d"
	assert_success
	[[ "$stderr" =~ \<mesh-a-ctx\>\ +ci-a && "$stderr" =~ \<mesh-b-ctx\>\ +ci-b && "$stderr" =~ \<hub-a-ctx\>\ +hub-x ]]
	run "$REDACT" --help
	assert_success
	assert_output --partial "--no-contexts"
	assert_output --partial "TMPDIR"
}

@test "ctx_file_safe: one file-name form of a context in any locale (other bytes as _, cut to CTX_FILE_NAME_MAX on request); tuning's ctx_key and redact's aliases use it" {
	local loc want long40
	long40="$(printf 'a%.0s' {1..40})"
	want="$(printf '%s\n' 'ctx-__1' 'ns_api-x.example_6443_ci-user' "$long40" 'plain-ctx_1.x')"
	for loc in C C.UTF-8; do
		run --separate-stderr env LC_ALL="$loc" bash -c 'source "$1/tests/lib/common.sh"
			ctx_file_safe "ctx-é1"; ctx_file_safe "ns/api-x.example:6443/ci-user"
			ctx_file_safe "$(printf "a%.0s" {1..50})" "$CTX_FILE_NAME_MAX"; ctx_file_safe plain-ctx_1.x' _ "$ROOT"
		assert_success
		assert_output "$want"
	done
	run --separate-stderr env LC_ALL=C.UTF-8 BASH_COMPAT=51 bash -c 'source "$1/tests/lib/common.sh"; ctx_file_safe "ctx-é1"' _ "$ROOT"
	assert_output 'ctx-__1'
	[ "$CTX_FILE_NAME_MAX" = 40 ]
	source "${ROOT}/tests/tuning/lib/tuning.sh"
	[ "$(ctx_key 'ns/api-x.example:6443/ci-user')" = ns_api-x.example_6443_ci-user ]
	[ "$(ctx_key 'ctx-é1')" = ctx-__1 ]
	# redact-results maps both file-name forms (whole, and cut for istiod-diag folders) of a
	# name to its placeholder, in a UTF-8 locale too.
	local d="${RES}/s" long='ns/api-long-cluster-name.example:6443/ci-user-with-long-name'
	mkdir -p "${d}/istiod-diag-r1/ns_api-long-cluster-name.example_6443_ci" "${d}/istiod-diag-r1/ctx-__1"
	printf '# CONTEXTS=%s\nrun_id\tnote\nr1\tctx-é1 and %s\n' "$long" "$long" > "${d}/run.tsv"
	echo raw > "${d}/istiod-diag-r1/ns_api-long-cluster-name.example_6443_ci/a.txt"
	echo raw > "${d}/istiod-diag-r1/ctx-__1/b.txt"
	LC_ALL=C.UTF-8 run --separate-stderr "$REDACT" --context 'ctx-é1' --out "${BATS_TEST_TMPDIR}/copy" "$d"
	assert_success
	[ -f "${BATS_TEST_TMPDIR}/copy/s/istiod-diag-r1/mesh-a-ctx/b.txt" ]
	[ -f "${BATS_TEST_TMPDIR}/copy/s/istiod-diag-r1/mesh-b-ctx/a.txt" ]
	grep -qx $'r1\t<mesh-a-ctx> and <mesh-b-ctx>' "${BATS_TEST_TMPDIR}/copy/s/run.tsv"
}

@test "redact-results: home dirs under /home and /Users read <home>, emails <email>, the vocabulary preamble.sh masks with; --help says so" {
	local d="${RES}/h" out="${BATS_TEST_TMPDIR}/copy"
	mkdir -p "$d"
	printf '# SOURCE_CTX=ci-a\n# RUN_CONFIG=/Users/some.one/campaign/run.env\nrun_id\tsource_ctx\tdetail\nr1\tci-a\topen /home/someone/.kube/config: owner ops.person@example.com\n' > "${d}/endpoint-r1.tsv"
	run --separate-stderr "$REDACT" --out "$out" "$d"
	assert_success
	run cat "${out}/h/endpoint-r1.tsv"
	assert_line "# RUN_CONFIG=<home>/campaign/run.env"
	assert_line $'r1\t<mesh-a-ctx>\topen <home>/.kube/config: owner <email>'
	run grep -rlE 'someone|some\.one|ops\.person|/Users/|/home/' "$out"
	assert_output ""
	run "$REDACT" --help
	assert_output --partial "home dirs (/home/<name> and /Users/<name>) <home>"
	assert_output --partial "emails <email>"
}
