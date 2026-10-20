#!/usr/bin/env bats
# Controlplane sweep resumes, through 003 and 004 (PL33; no cluster: kubectl is a stub, and
# where a cell must write rows, 001 and 002 are fakes in a symlinked copy of the tree): a
# --resume takes the first run's axis flags and refuses cells no run planned; a --resume
# that adds no rows is left out of the rows' provenance; the full resume command wherever
# the sweep or its report says to resume; the legacy leftover check (mesh members, sizing,
# settle, records); a cell whose rows were all written gets no INTERRUPTED row; the plan's
# TSV, the replica INCOMPLETE rule and its markers; what each attempt records; the
# sweep's scratch files.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"

setup() {
	# The test's own process (bats runs setup and the test in one): the CP_TERM stub looks for
	# the sweep below it only, never in a shell that started bats.
	export TEST_PID="$BASHPID"
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The kubectl stub (files in RS_DIR, per context where named <file>.<ctx>): the Istio CR
	# reads answer as fake-istio-cr.sh; `config get-contexts -o name` lists kube-contexts (no
	# file: it fails); a member's Istio remote secrets are remote.<ctx> (no file: the read
	# fails); its controlplane-test namespaces are one while ns-left.<ctx> exists, and their
	# delete removes it unless ns-stuck exists (then the delete fails); `version` answers
	# kver (no file: it fails). 002's first read (its Running istiod pods) fails; under
	# CP_TERM (once) it lists TMPDIR into tmp-at-term, sends SIGTERM to the topmost
	# *003-run-sweep.sh ancestor below the test's process, closes its output and waits.
	# Anything else fails, as against an empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$RS_DIR"
[ -z "${KLOG:-}" ] || printf '%s\n' "$*" >> "$KLOG"
ctx=""
for a in "$@"; do case "$a" in --context=*) ctx="${a#--context=}" ;; esac; done
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
"config get-contexts -o name")
	[ -f "$d/kube-contexts" ] || exit 1
	cat "$d/kube-contexts" ;;
*" get secrets -l istio/multiCluster=true -o json"*)
	[ -f "$d/remote.$ctx" ] || exit 1
	cat "$d/remote.$ctx" ;;
*" get namespaces -l app.kubernetes.io/instance=controlplane-test -o json"*)
	if [ -f "$d/ns-left.$ctx" ]; then echo '{"items":[{"metadata":{"name":"controlplane-test-0","labels":{}}}]}'; else echo '{"items":[]}'; fi ;;
*" get namespace -l app.kubernetes.io/instance=controlplane-test -o name"*|*" get ns -l app.kubernetes.io/instance=controlplane-test -o name"*)
	[ ! -f "$d/ns-left.$ctx" ] || echo namespace/controlplane-test-0 ;;
*" delete namespace -l app.kubernetes.io/instance=controlplane-test "*)
	[ ! -f "$d/ns-stuck" ] || exit 1
	rm -f "$d/ns-left.$ctx" ;;
*" delete namespace controlplane-test "*) : ;;
*" version --output=json"*)
	[ -f "$d/kver" ] || exit 1
	printf '{"serverVersion":{"gitVersion":"%s"}}\n' "$(cat "$d/kver")" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running -o jsonpath="*)
	if [ -n "${CP_TERM:-}" ] && [ ! -e "$d/term-sent" ]; then
		: > "$d/term-sent"
		ls "${TMPDIR:-/tmp}" > "$d/tmp-at-term" 2>/dev/null || :
		p=$PPID s=""
		while [ "${p:-1}" -gt 1 ] && [ "$p" != "${TEST_PID:?}" ]; do
			case "$(ps -o args= -p "$p" 2>/dev/null)" in *003-run-sweep.sh*) s="$p" ;; esac
			p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
		done
		[ -z "$s" ] || kill -TERM "$s"
		exec >/dev/null 2>&1 3>&-
		echo "$$" > "$d/stub-pid"
		sleep 30 &
		echo "$!" > "$d/sleep-pid"
		wait
	fi
	exit 1 ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	export RS_DIR="$BATS_TEST_TMPDIR"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	SWEEP="${CP}/003-run-sweep.sh"
}

teardown() {
	# The CP_TERM stub's own processes, when a test left them (only PIDs it recorded).
	local f p
	for f in "${BATS_TEST_TMPDIR}/sleep-pid" "${BATS_TEST_TMPDIR}/stub-pid"; do
		[[ -s "$f" ]] || continue
		p="$(<"$f")"
		if [[ "$p" =~ ^[0-9]+$ ]]; then kill "$p" 2>/dev/null || true; fi
	done
}

# cp_sweep <args...>: controlplane 003 ($SWEEP) with the stub kubectl, its results under
# res/; output and stderr together, in order.
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run bash "$SWEEP" "$@"
}

# cp_sweep2 <args...>: as cp_sweep, stdout in $output and stderr in $stderr.
cp_sweep2() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run --separate-stderr bash "$SWEEP" "$@"
}

# sweep_dir: the one sweep dir under res/.
sweep_dir() {
	find "${BATS_TEST_TMPDIR}/res" -maxdepth 1 -name 'sweep-*' -type d
}

# sweep_tsv <dir>: its controlplane TSV.
sweep_tsv() {
	find "$1" -maxdepth 1 -name 'controlplane-*.tsv'
}

# cp_row <ts> <ctx> <mesh> <svcs> <mem_mi>: a valid legacy measurement row (66 columns, window
# kind deploy, 3 replicas, 1 namespace, scoping none, traffic none).
cp_row() {
	printf '%s\t%s\t%s\t%s\t3\t1\tnone\t%s\t50\t90\t5\t9\t100\t3.33\t10\t60\t10\t10\t10\t50\t1.67\t20\t2048\t1048576\t1048576\t1048576\t3/3\t30.0\t100\t30\t0\t100\t200\t250\t10\t15\t40\t50\t120\t250\t22\t22\tOK\tnone\t0\t0\t1.00\t0.50\t30\t51200\t20480\t0\tpods\t4\t0\tnone\tdeploy\t%s\t12.5\t45\t120\t200\t3\t210\t180\t0\n' \
		"$1" "$2" "$3" "$4" "$5" "$(($4 * 2))"
}

# measured <tsv> <row>...: replace the TSV's data rows (the status rows the stub's failed
# probes left) with the given rows.
measured() {
	local tsv="$1"
	shift
	grep -E '^#|^timestamp' "$tsv" > "${tsv}.new"
	printf '%s' "$@" >> "${tsv}.new"
	mv "${tsv}.new" "$tsv"
}

# done_dir: a first run of mesh 1 (ci-a) x svcs 5 whose cell then holds a valid row (the
# sweep measured it). Sets D and TSV.
done_dir() {
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	measured "$TSV" "$(cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000)"$'\n'
}

# fake_tree: a copy of the repo (symlinks) whose controlplane 001 succeeds and whose 002
# --phase final appends a measurement row (cp_row's) for the first FAKE_ROWS members of its
# cell (default: all of its mesh size), then sends SIGTERM to the sweep that runs it and
# waits for it: the sweep ends after the cell's rows were written, before its end. Sets SWEEP.
fake_tree() {
	local t="${BATS_TEST_TMPDIR}/tree" f
	mkdir -p "${t}/tests/controlplane"
	ln -s "${ROOT}/config" "${t}/config"
	ln -s "${ROOT}/charts" "${t}/charts"
	ln -s "${ROOT}/tests/lib" "${t}/tests/lib"
	for f in "$CP"/*; do
		case "${f##*/}" in 001-* | 002-*) ;; *) ln -s "$f" "${t}/tests/controlplane/${f##*/}" ;; esac
	done
	printf '#!/bin/sh\nexit 0\n' > "${t}/tests/controlplane/001-setup-controlplane-test.sh"
	{
		echo '#!/usr/bin/env bash'
		echo 'set -euo pipefail'
		declare -f cp_row
		cat <<'FAKE'
phase="" ctxs="" ms=0 sc=0 out="" rid=""
while (($#)); do
	case "$1" in
	--phase) phase="$2"; shift 2 ;;
	--contexts) ctxs="$2"; shift 2 ;;
	--mesh-size) ms="$2"; shift 2 ;;
	--service-count) sc="$2"; shift 2 ;;
	--output-dir) out="$2"; shift 2 ;;
	--run-id) rid="$2"; shift 2 ;;
	*) shift ;;
	esac
done
[[ "$phase" == final ]] || exit 0
IFS=, read -r -a c <<<"$ctxs"
n="${FAKE_ROWS:-$ms}"
rows=""
for ((i = 0; i < n; i++)); do rows+="$(cp_row "$(date -u -Iseconds)" "${c[i]}" "$ms" "$sc" 1000)"$'\n'; done
printf '%s' "$rows" >> "${out}/controlplane-${rid}.tsv"
kill -TERM "$PPID"
sleep 30 &
wait
FAKE
	} > "${t}/tests/controlplane/002-collect-resource-metrics.sh"
	chmod +x "${t}/tests/controlplane/001-setup-controlplane-test.sh" "${t}/tests/controlplane/002-collect-resource-metrics.sh"
	SWEEP="${t}/tests/controlplane/003-run-sweep.sh"
}

# ---------------------------------------------------------------------------
# C2: a --resume finishes the sweep it resumes

@test "a --resume without axis flags takes the first run's (planned-cells.txt PLAN=1), not the environment's, prints the ones it took and its axis flags, and plans no cell" {
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5,6
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	[ "$(sed -n 2p "${D}/planned-cells.txt")" = "# TSV=$(basename "$(sweep_tsv "$D")")" ]
	# The environment's axis values (a forgotten export) are not the sweep's.
	CONTROLPLANE_SERVICE_COUNTS=10 CONTROLPLANE_MESH_SIZES=1,2 cp_sweep2 --resume "$D" --contexts ci-a,ci-b
	[ "$status" -eq 4 ]
	[[ "$stderr" == *'note: --resume: the axis flags not given take the first run'"'"'s values (planned-cells.txt "# PLAN=1"): --mesh-sizes 2 --service-counts 5,6 --replica-counts '* ]]
	[[ "$stderr" == *"Resume axis flags: --mesh-sizes 2 --service-counts 5,6 --replica-counts "* ]]
	[[ "$stderr" == *"Planned matrix:    2 = 1×2×1×1×1×1"* ]]
	[ "$(grep -c '^# PLAN=' "${D}/planned-cells.txt")" -eq 1 ]
	! grep -q 'svcs=10\|	10	3	1	none' "$(sweep_tsv "$D")" || false
	# A flag given wins over the plan: a narrower resume runs only its cell.
	cp_sweep2 --resume "$D" --contexts ci-a,ci-b --service-counts 6
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"(planned-cells.txt \"# PLAN=1\"): --mesh-sizes 2 --replica-counts "* ]]
	[[ "$stderr" == *"Planned matrix:    1 = 1×1×1×1×1×1"* ]]
	[ "$(grep -c '^# PLAN=' "${D}/planned-cells.txt")" -eq 1 ]
}

@test "a --resume whose axis flags plan a cell no earlier run planned is refused before any change; --extend-plan or CONTROLPLANE_EXTEND_PLAN=1 adds it as a new PLAN; a --config cannot set that key" {
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5,6
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	local before
	before="$(cat "$TSV" "${D}/planned-cells.txt" | cksum)"
	cp_sweep2 --resume "$D" --contexts ci-a,ci-b --service-counts 5,10
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"--resume: this run's axis flags plan 1 cell(s) no earlier run of this sweep planned (mesh=2 svcs=10 reps=3 ns=1 scope=none traffic=none). A --resume finishes the sweep it resumes; nothing was run."* ]]
	[[ "$stderr" == *"add --extend-plan to add these cells"* ]]
	[[ "$stderr" == *"The plans so far, each with the command that resumes with its axis flags:"$'\n'"  PLAN 1 the first run: --mesh-sizes 2 --service-counts 5,6 "*$'\n'"    ./tests/controlplane/003-run-sweep.sh --resume $(printf '%q' "$D") --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5,6 "* ]]
	[ "$(cat "$TSV" "${D}/planned-cells.txt" | cksum)" = "$before" ]
	[ ! -e "${D}/resumes.txt" ]
	# The refusal released the sweep's lock.
	[ ! -e "${D}/.sweep.lock" ]
	cp_sweep2 --resume "$D" --contexts ci-a,ci-b --service-counts 10 --extend-plan
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"note: --resume --extend-plan: this run adds 1 cell(s) no earlier run of this sweep planned (mesh=2 svcs=10 "* ]]
	grep -q '^# PLAN=2 the --resume at .*: --mesh-sizes 2 --service-counts 10 ' "${D}/planned-cells.txt"
	CONTROLPLANE_EXTEND_PLAN=1 cp_sweep2 --resume "$D" --contexts ci-a,ci-b --service-counts 11
	[ "$status" -eq 4 ]
	grep -q '^# PLAN=3 the --resume at .*: --mesh-sizes 2 --service-counts 11 ' "${D}/planned-cells.txt"
	CONTROLPLANE_EXTEND_PLAN=yes cp_sweep2 --dry-run --contexts ci-a
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"CONTROLPLANE_EXTEND_PLAN must be 0 or 1 (got: yes)"* ]]
	printf 'CONTROLPLANE_EXTEND_PLAN=1\n' > "${BATS_TEST_TMPDIR}/x.env"
	cp_sweep2 --dry-run --contexts ci-a --config "${BATS_TEST_TMPDIR}/x.env"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"CONTROLPLANE_EXTEND_PLAN is not settable from --config (env only: "* ]]
	run bash "$SWEEP" --help
	assert_success
	[[ "$output" == *"--extend-plan"* ]]
}

# ---------------------------------------------------------------------------
# C1: a --resume that adds no rows

@test "a --resume that adds no rows (every cell done) says so, and 004 lists it as (added no rows), out of harness_shas, the provenance warning and the Kubernetes change check" {
	# The first run cannot read ci-a's Kubernetes version (no kver: unreachable in its preamble), so
	# the resume that reads one goes on (one that differs from a recorded version is refused).
	done_dir
	# The first run on another harness commit; the resume reads a Kubernetes version.
	sed -i.bak 's/^# HARNESS_SHA=.*/# HARNESS_SHA=abc1234/' "$TSV"
	grep -qx '# KUBE_VERSIONS=ci-a=unreachable' "$TSV"
	echo v1.31.0 > "${BATS_TEST_TMPDIR}/kver"
	cp_sweep2 --resume "$D" --contexts ci-a
	assert_success
	[[ "$stderr" == *"already has a valid row; skipping (resume)"* || "$output" == *"already has a valid row; skipping (resume)"* ]]
	grep -q "^INFO=this --resume (at .*) added no rows: every cell of its axis flags was already done, so the reports leave it out of the rows' provenance" "${D}/sweep-outcome.txt"
	# Its own harness and Kubernetes notes are left out of the record: it measured nothing.
	! grep -q 'HARNESS_SHA abc1234\|abc1234.*harness\|v1.31.0' "${D}/sweep-outcome.txt" || false
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	[ "$(jq -c '.metadata.harness_shas' <<<"$output")" = '["abc1234"]' ]
	[ "$(jq -r '.metadata.harness_sha' <<<"$output")" = abc1234 ]
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = null ]
	[ "$(jq -c '[.metadata.attempts[].rows]' <<<"$output")" = '[1,0]' ]
	# No data warning names its version or a Kubernetes change (the read at its end could not
	# compare KUBE_VERSIONS with the start's, which was not read: that warning stays).
	jq -e '[.metadata.data_warnings[]? | select(test("v1[.]31[.]0|Kubernetes server version"))] | length == 0' <<<"$output"
	# Nor is its version the rows': the record keeps the first run's.
	[ "$(jq -r '.metadata.kube_versions' <<<"$output")" = ci-a=unreachable ]
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format text
	assert_success
	[[ "$output" == *"# attempts: the rows come from one run (no other run's rows are in the figures): the first run "*"(added no rows)"* ]]
	[[ "$output" != *"more than one run"* ]]
}

@test "004 leaves out an earlier --resume that stopped before its first cell (its resumes.txt line and # RESUMED_AT= line, no rows after them)" {
	done_dir
	# What a --resume that stopped before any cell (on another harness, another Kubernetes)
	# leaves: its records, no row.
	printf 'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\tTSV_LINES\tISTIO_PROXY_VERSIONS\tISTIO_GENERATIONS\tTSV\n2026-06-02T00:00:00+00:00\tdef5678\tnone\tci-a=v1.99.0\t%s\tci-a=unknown\tci-a=2/2\t%s\n' \
		"$(wc -l < "$TSV" | tr -d ' ')" "$(basename "$TSV")" > "${D}/resumes.txt"
	echo '# RESUMED_AT=2026-06-02T00:00:00+00:00 TSV_LINES=0 HARNESS_SHA=def5678 KUBE_VERSIONS=ci-a=v1.99.0' >> "$TSV"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	[ "$(jq -r '.metadata.harness_shas | length' <<<"$output")" -eq 1 ]
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = null ]
	[ "$(jq -c '[.metadata.attempts[] | [.run, .rows]]' <<<"$output")" = '[["first run",1],["--resume at 2026-06-02T00:00:00Z",0]]' ]
	jq -e '[.metadata.data_warnings[]? | select(test("v1.99.0"))] | length == 0' <<<"$output"
	local fmt
	for fmt in text csv markdown; do
		run --separate-stderr bash "$REPORT" --results-dir "$D" --format "$fmt"
		assert_success
		[[ "$output" == *"--resume at 2026-06-02T00:00:00Z HARNESS_SHA=def5678 KUBE_VERSIONS=ci-a=v1.99.0 (added no rows)"* ]] || { echo "${fmt}: ${output}"; false; }
	done
}

# ---------------------------------------------------------------------------
# C3, C10: the full resume command

@test "the full resume command: in the outcome's NEXT and on the console after an interrupt, after a narrower --resume (its start note, before the capacity check, and its NOT_RUN end) and in 004's NOT_RUN warning" {
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	local cmd='./tests/controlplane/003-run-sweep.sh --resume <sweep dir> --contexts ci-a --mesh-sizes 1 --service-counts 5,6 '
	# Only svcs=5 measured: svcs=6 is planned, with no row.
	measured "$TSV" "$(cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000)"$'\n'
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	jq -e --arg c "$cmd" '[.metadata.data_warnings[] | select(contains("NOT_RUN") and contains("To finish the sweep, resume it with the axis flags that planned them: " + $c))] | length == 1' <<<"$output"
	# A narrower --resume: the note at its start (before the cleanup and the capacity check)
	# and its end print the command with the sweep dir.
	cp_sweep --resume "$D" --contexts ci-a --service-counts 5
	[ "$status" -eq 4 ]
	local qd
	qd="$(printf '%q' "$D")"
	[[ "$output" == *"  the first run: --mesh-sizes 1 --service-counts 5,6 "*"    ./tests/controlplane/003-run-sweep.sh --resume ${qd} --contexts ci-a --mesh-sizes 1 --service-counts 5,6 "*"--- Capacity plan check"* ]]
	[[ "$output" == *"To finish this sweep, --resume it with the axis flags that planned its NOT_RUN cells:"*"./tests/controlplane/003-run-sweep.sh --resume ${qd} --contexts ci-a --mesh-sizes 1 --service-counts 5,6 "* ]]
	# An interrupted resume: its NEXT and the console's next: name the command too.
	CP_TERM=1 cp_sweep2 --resume "$D" --contexts ci-a
	[ "$status" -eq 143 ]
	grep -q "^NEXT=if it died, --resume this sweep dir with the flags it ran with (the cells already measured are kept): ./tests/controlplane/003-run-sweep.sh --resume <sweep dir> --contexts ci-a --mesh-sizes 1 --service-counts 5,6 .* (<sweep dir> is this sweep's directory)$" "${D}/sweep-outcome.txt"
	# The console's next: the command with this sweep dir's path (SWEEP_NEXT_CONSOLE).
	[[ "$stderr" == *"  sweep dir: ${D}; next: ./tests/controlplane/003-run-sweep.sh --resume ${qd} --contexts ci-a --mesh-sizes 1 --service-counts 5,6 "* ]]
	# The stop record's times are UTC with Z, as its DATE.
	grep -Eq '^RESUMED_AT=[0-9T:-]+Z$' "${D}/sweep-outcome.txt"
}

# ---------------------------------------------------------------------------
# C4, C5: the legacy leftover check

@test "the legacy leftover check: --dry-run says what a live run does; a live run counts on the measured members and the mesh members their remote secrets name (warning about one without a kube context), deletes with a sized --timeout, records it, and settles before the first cell" {
	cp_sweep2 --dry-run --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_success
	[[ "$stderr" == *"Leftover check: a live run counts the controlplane-test namespaces on the members (and on the mesh members their Istio remote secrets name), deletes those an earlier run left on the --contexts members through 005-cleanup.sh before the first cell, then waits --settle (0s) before it; it deletes nothing on the other mesh members, and stops first when they hold some; a dry run reads no cluster."* ]]
	# ci-a's remote secrets name ci-c (a kube context) and ci-d (none); ci-a holds a leftover
	# (one on ci-c, outside --contexts, stops the sweep: controlplane-resume2.bats).
	printf 'ci-a\nci-c\n' > "${BATS_TEST_TMPDIR}/kube-contexts"
	printf '%s\n' '{"items":[{"metadata":{"name":"istio-remote-secret-ci-c","labels":{"istio/multiCluster":"true"},"annotations":{"networking.istio.io/cluster":"ci-c"}}},{"metadata":{"name":"istio-remote-secret-ci-d","labels":{"istio/multiCluster":"true"}}}]}' > "${BATS_TEST_TMPDIR}/remote.ci-a"
	: > "${BATS_TEST_TMPDIR}/ns-left.ci-a"
	export KLOG="${BATS_TEST_TMPDIR}/klog"
	CONTROLPLANE_SETTLE_SEC=1 CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=7 \
		cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$output" == *"Leftover check: also counts on mesh member(s) ci-c (named by the Istio remote secrets, not measured)"* ]]
	[[ "$output" == *"warn: mesh member(s) ci-d (named by the Istio remote secrets) have no kube context of that name"*"check each with: kubectl --context <its context> get namespaces -l app.kubernetes.io/instance=controlplane-test"* ]]
	[[ "$output" == *"note: controlplane-test namespaces are left on the members (ci-a: 1) by a run cut short or a growth series."*"so 005-cleanup.sh deletes them now, before the first cell. Its --timeout is 7 s (about 7 s per namespace, 1 on the fullest member)"* ]]
	grep -q -- '--context=ci-a .*delete namespace -l app.kubernetes.io/instance=controlplane-test' "$KLOG"
	[ "$(grep -c -- '--context=ci-c .*delete namespace' "$KLOG")" = 0 ]
	[ ! -e "${BATS_TEST_TMPDIR}/ns-left.ci-a" ]
	# The settle comes after the deletion and before the first cell's baseline (the order;
	# its length is the configured --settle, PL44).
	local o="$output" a b c
	a="${o%%so 005-cleanup.sh deletes them now*}"
	b="${o%%--- Post-cleanup settle (1s) ---*}"
	c="${o%%--- Baseline metrics scrape (phase 1/3) ---*}"
	[ "${#a}" -lt "${#b}" ]
	[ "${#b}" -lt "${#c}" ]
	D="$(sweep_dir)"
	grep -qx '# LEFTOVER_TEST_NAMESPACES=ci-a=1 (deleted by 005-cleanup.sh before the first cell)' "$(sweep_tsv "$D")"
	grep -q '^INFO=the leftover check found controlplane-test namespaces an earlier run left (ci-a: 1) and 005-cleanup.sh deleted them before the first cell' "${D}/sweep-outcome.txt"
}

@test "the legacy leftover check: no leftover, no settle before the first cell and LEFTOVER_TEST_NAMESPACES=none; one that stays stops the sweep with the sized --timeout to give 005" {
	CONTROLPLANE_SETTLE_SEC=1 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	local o="$output" b c
	b="${o%%--- Post-cleanup settle*}"
	c="${o%%--- Baseline metrics scrape (phase 1/3) ---*}"
	[ "${#c}" -lt "${#b}" ]
	grep -qx '# LEFTOVER_TEST_NAMESPACES=none' "$(sweep_tsv "$(sweep_dir)")"
	rm -rf "${BATS_TEST_TMPDIR}/res"
	: > "${BATS_TEST_TMPDIR}/ns-left.ci-b"
	: > "${BATS_TEST_TMPDIR}/ns-stuck"
	CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=3 \
		cp_sweep2 --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"controlplane-test namespaces are still on the members after 005-cleanup.sh (ci-b: 1"*"Run "*"005-cleanup.sh --contexts ci-b until it leaves none, then run this command again. Give it --timeout 3 (about 3 s per namespace, 1 on the fullest member; its default is 1 s)."* ]]
}

@test "a --resume that stops before its first cell says what the leftover check had changed: an earlier run's namespaces deleted, or nothing" {
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	# An append to resumes.txt fails: a directory in its place.
	rm -f "${D}/resumes.txt"
	mkdir "${D}/resumes.txt"
	: > "${BATS_TEST_TMPDIR}/ns-left.ci-a"
	cp_sweep2 --resume "$D" --contexts ci-a
	[ "$status" -eq 1 ]
	[ ! -e "${BATS_TEST_TMPDIR}/ns-left.ci-a" ]
	[[ "$stderr" == *"--resume: could not append to ${D}/resumes.txt, which tells this run's rows from earlier ones; no cell ran (the leftover check had already deleted an earlier run's controlplane-test namespaces with 005-cleanup.sh; nothing else was changed on the cluster)."* ]] || { echo "$stderr"; false; }
	cp_sweep2 --resume "$D" --contexts ci-a
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"--resume: could not append to ${D}/resumes.txt, which tells this run's rows from earlier ones; no cell ran, and nothing was changed on the cluster."* ]]
}

# ---------------------------------------------------------------------------
# C6: a cell whose rows were all written

@test "a sweep that ends after its cell's 002 wrote every member's rows writes no INTERRUPTED row (the cell is done, and a --resume keeps it); one that wrote fewer does" {
	fake_tree
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	[[ "$output" == *"note: the cell in progress (mesh=2 svcs=5 "*") had written every member's rows before the sweep ended: it is done (no INTERRUPTED row), and a --resume keeps it"* ]]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	[ "$(awk -F'\t' '!/^#/ && $1 != "timestamp"' "$TSV" | wc -l | tr -d ' ')" -eq 2 ]
	! grep -q 'INTERRUPTED' "$TSV" || false
	cp_sweep --resume "$D" --contexts ci-a,ci-b
	assert_success
	[[ "$output" == *"mesh=2 svcs=5 reps=3 ns=1 scope=none traffic=none — already has a valid row; skipping (resume)"* ]]
	# Rows of one member of two: the cell is cut short, INTERRUPTED.
	rm -rf "${BATS_TEST_TMPDIR}/res"
	FAKE_ROWS=1 cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	[[ "$output" != *"had written every member's rows"* ]]
	[ "$(awk -F'\t' '$2 == "INTERRUPTED"' "$(sweep_tsv "$(sweep_dir)")" | wc -l | tr -d ' ')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# C7, C10: the plan's TSV, the replica rule, INCOMPLETE markers

@test "planned-cells.txt applies only to the TSV it names (# TSV=); a plan without the key applies to every TSV beside it" {
	local dir="${BATS_TEST_TMPDIR}/nr2"
	mkdir -p "$dir"
	cp "${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" "${dir}/controlplane-fixture-t2.tsv"
	# Another run's TSV beside it (--allow-multi-run): the same rows at svcs=30.
	awk -F'\t' -v OFS='\t' '/^# RUN_ID=/ { print "# RUN_ID=other-run"; next } !/^#/ && $1 != "timestamp" { $4 = 30 } { print }' \
		"${dir}/controlplane-fixture-t2.tsv" > "${dir}/controlplane-other-run.tsv"
	printf '# Planned cells\n# TSV=controlplane-fixture-t2.tsv\nmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\ttraffic_config\twindow_kind\n# PLAN=1 the first run: --service-counts 15\n2\t15\t2\t1\tnone\tnone\tdeploy\n' > "${dir}/planned-cells.txt"
	run --separate-stderr bash "$REPORT" --results-dir "$dir" --allow-multi-run --format json
	assert_success
	jq -e '[.metadata.data_warnings[]? | select(test("NOT_RUN"))] | length == 0' <<<"$output"
	local verdict
	verdict="$(jq -r '.metadata.sla.headline' <<<"$output")"
	[[ "$verdict" != *"NOT_RUN"* ]]
	[[ "$stderr" == *"note: planned-cells.txt is the plan of controlplane-fixture-t2.tsv, not of controlplane-other-run.tsv: its planned cells are not counted for controlplane-other-run.tsv"* ]]
	# Without the key (an older harness): the plan applies to both, and the other TSV has no
	# svcs=15 row.
	sed -i.bak '/^# TSV=/d' "${dir}/planned-cells.txt"
	run --separate-stderr bash "$REPORT" --results-dir "$dir" --allow-multi-run --format json
	assert_success
	jq -e '[.metadata.data_warnings[]? | select(test("1 planned cell\\(s\\) never ran"))] | length == 1' <<<"$output"
}

@test "a member with fewer rows than its istiod replicas in the cell written last is INCOMPLETE: marked in the text block header, the markdown cells table and the charts, and a --resume runs it again" {
	# Mesh 1 and 2 (charts need two mesh sizes); the cell written last (mesh 2) has one row
	# of ci-b, which runs two istiod replicas.
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 1,2 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	measured "$TSV" "$(cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000)"$'\n'"$(cp_row 2026-06-01T00:02:00+00:00 ci-a 2 5 1100)"$'\n'"$(cp_row 2026-06-01T00:02:00+00:00 ci-b 2 5 1100)"$'\n'
	sed -i.bak 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=ci-a=1,ci-b=2/' "$TSV"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	jq -e '[.metadata.data_warnings[] | select(test("1 cell\\(s\\) are INCOMPLETE: .*or a member fewer rows than its window wrote: its WINDOW_ROWS line, or in a TSV without one its istiod replicas.*mesh=2 svcs=5 reps=3 ns=1 scope=none traffic=none \\(ci-b has rows of 1 of its 2 istiod replicas\\)"))] | length == 1' <<<"$output"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" != PASS ]
	# The SLA headline names the replica case too, not only fewer members than the mesh size.
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == *"1 cell(s) are INCOMPLETE (rows of fewer members than their mesh size, or a member with fewer rows than its window wrote"* ]]
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format text
	assert_success
	[[ "$output" == *"--- mesh_size=2 service_count=5 "*"(n_total=2 n_valid=2; INCOMPLETE: ci-b has rows of 1 of its 2 istiod replicas) ---"* ]]
	[[ "$output" == *"--- mesh_size=1 service_count=5 "*"(n_total=1 n_valid=1) ---"* ]]
	[[ "$output" == *"  ! INCOMPLETE: ci-b has rows of 1 of its 2 istiod replicas: "* ]]
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format markdown
	assert_success
	[[ "$output" == *" ‡ |"* ]]
	[[ "$output" == *"> ‡ INCOMPLETE: "* ]]
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format charts
	assert_success
	[[ "$output" == *"‡"* ]]
	[[ "$output" == *"> ‡ INCOMPLETE points"* ]]
	# The same rows from a standalone 002 run (PHASE is not sweep) are no sweep's cells:
	# never INCOMPLETE.
	local s2="${BATS_TEST_TMPDIR}/standalone"
	mkdir -p "$s2"
	sed 's/^# PHASE=sweep$/# PHASE=final/' "$TSV" > "${s2}/${TSV##*/}"
	run --separate-stderr bash "$REPORT" --results-dir "$s2" --format json
	assert_success
	jq -e '[.metadata.data_warnings[]? | select(test("INCOMPLETE"))] | length == 0' <<<"$output"
	cp_sweep --resume "$D" --contexts ci-a,ci-b
	[ "$status" -eq 4 ]
	[[ "$output" == *"mesh=1 svcs=5 reps=3 ns=1 scope=none traffic=none — already has a valid row; skipping (resume)"* ]]
	[[ "$output" == *"mesh=2 svcs=5 reps=3 ns=1 scope=none traffic=none — cut short while its rows were written (INCOMPLETE: ci-b has rows of 1 of its 2 istiod replicas): running it again"* ]]
}

@test "a standalone 002 refuses a --mesh-size larger than its contexts before any read" {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr bash "${CP}/002-collect-resource-metrics.sh" \
		--contexts ci-a --mesh-size 2 --dry-run
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"--mesh-size 2 is larger than the 1 context(s) given (ci-a)"*"(INCOMPLETE). Give a context per member, or a smaller --mesh-size."* ]]
}

# ---------------------------------------------------------------------------
# C9: what each attempt records, escaped

@test "each resume's # RESUMED_AT= line records KUBE_VERSIONS; the attempts show each resume's Istio state; json escapes \" and \\; the scale envelope shows the provenance warning and the report's harness" {
	echo v1.30.0 > "${BATS_TEST_TMPDIR}/kver"
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	measured "$TSV" "$(cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000)"$'\n'
	sed -i.bak 's/^# HARNESS_SHA=.*/# HARNESS_SHA=abc1234/; s/^# HARNESS_CONTENT_KEY=.*/# HARNESS_CONTENT_KEY=000000000000/' "$TSV"
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	# The resume's platform record (platform_resume_words) before KUBE_VERSIONS, the rest of the line.
	grep -Eq '^# RESUMED_AT=[0-9T:+-]+ TSV_LINES=[0-9]+ HARNESS_SHA=[^ ]+ HARNESS_CONTENT_KEY=[^ ]+ ISTIO_NOTREADY_AT_RESUME=none ISTIO_GENERATIONS=ci-a=[^ ]+ ISTIO_PROXY_VERSIONS=ci-a=[^ ]+ PLATFORM=[^ ]+ TEST_PLATFORM=auto PLATFORM_BY_CONTEXT=ci-a=[^ ]+ MESH_OPERATOR_BY_CONTEXT=ci-a=[^ ]+ ISTIOD_IMAGE_BY_CONTEXT=ci-a=[^ ]+ PROXY_IMAGE_BY_CONTEXT=ci-a=[^ ]+ NODE_PROVIDER_BY_CONTEXT=ci-a=[^ ]+ ISTIOD_ENV_BY_CONTEXT=ci-a=[^ ]+ TUNING_OBJECTS_BY_CONTEXT=ci-a=[^ ]+ KUBE_VERSIONS=ci-a=v1.30.0$' "$TSV"
	# A value with " and \ (resumes.txt is plain text).
	awk -F'\t' -v OFS='\t' 'NR == 2 { $7 = "ci-a=2/2\"x\\y" } { print }' "${D}/resumes.txt" > "${D}/resumes.new"
	mv "${D}/resumes.new" "${D}/resumes.txt"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	jq -e '.metadata.attempts[1] | (.istio_generations == "ci-a=2/2\"x\\y") and (.istio_notready == "none") and (.istio_proxy_versions | test("ci-a="))' <<<"$output"
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" != null ]
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format text
	assert_success
	[[ "$output" == *"# attempts, Istio at each start: the first run ISTIO_NOTREADY_AT_START=none ISTIO_GENERATIONS="*"; --resume at "*" ISTIO_NOTREADY_AT_RESUME=none ISTIO_GENERATIONS=ci-a=2/2\"x\\y ISTIO_PROXY_VERSIONS="* ]]
	source "${ROOT}/tests/lib/platform.sh"
	run --separate-stderr render_scale_envelope "$D" "$REPORT" "ci-a" false
	assert_success
	[[ "$output" == *"> **Provenance warning:** "* ]]
	[[ "$output" == *"; report harness \`"*"\`: REPORT_HARNESS_SHA, the harness that rendered it)"* ]]
}

# ---------------------------------------------------------------------------
# C11: the sweep's scratch files

@test "the sweep's scratch dir (envelope stderr, counts, cells) is gone after a run and after an interrupt" {
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'controlplane-sweep.*')" ]
	CP_TERM=1 cp_sweep --resume "$(sweep_dir)" --contexts ci-a
	[ "$status" -eq 143 ]
	grep -q '^controlplane-sweep\.' "${BATS_TEST_TMPDIR}/tmp-at-term"
	[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'controlplane-sweep.*')" ]
}

# ---------------------------------------------------------------------------
# C10: help texts

@test "002, 003 and 004 --help fit 100 columns; 004's names a failed end-of-sweep check, INTERRUPTED and the INCOMPLETE markers; 003's the resume defaults and --extend-plan" {
	local s
	for s in 002-collect-resource-metrics 003-run-sweep 004-report-results; do
		run bash "${CP}/${s}.sh" --help
		assert_success
		[ -z "$(awk 'length($0) > 100' <<<"$output")" ] || { echo "${s}: $(awk 'length($0) > 100' <<<"$output")"; false; }
	done
	run bash "$REPORT" --help
	# Its prose with each line break as a space (the wrap may move).
	local h
	h="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
	[[ "$h" == *"changed under the sweep, or the end-of-sweep check failed)"* ]]
	[[ "$h" == *"INTERRUPTED: the sweep ended inside the cell"* ]]
	[[ "$h" == *"its n_total in the markdown cells table (‡, with a footnote) and its chart series (‡, with a note)"* ]]
	run bash "$SWEEP" --help
	[[ "$output" == *"--extend-plan"* ]]
	[[ "$output" == *"PLAN=1"* ]]
	run bash "${CP}/002-collect-resource-metrics.sh" --help
	[[ "$output" == *"at most that"* ]]
}
