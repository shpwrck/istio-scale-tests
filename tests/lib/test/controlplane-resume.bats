#!/usr/bin/env bats
# The controlplane sweep through 003 and 004 (PL33; no cluster: kubectl is a stub, and
# where a cell must write rows, 001 and 002 are fakes in a symlinked copy of the tree): the
# legacy leftover check (mesh members, sizing, settle, records); a cell whose rows were all
# written gets no INTERRUPTED row; the replica INCOMPLETE rule and its markers; the sweep's
# scratch files; the help texts.

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
	# delete removes it unless ns-stuck exists (then the delete fails). 002's first read (its
	# Running istiod pods) fails; under CP_TERM (once) it lists TMPDIR into tmp-at-term, sends
	# SIGTERM to the topmost *003-run-sweep.sh ancestor below the test's process, closes its
	# output and waits. Anything else fails, as against an empty kubeconfig.
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

# ---------------------------------------------------------------------------
# C6: a cell whose rows were all written

@test "a sweep that ends after its cell's 002 wrote every member's rows writes no INTERRUPTED row (the cell is done); one that wrote fewer does" {
	fake_tree
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	[[ "$output" == *"note: the cell in progress (mesh=2 svcs=5 "*") had written every member's rows before the sweep ended: it is done (no INTERRUPTED row)"* ]]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	[ "$(awk -F'\t' '!/^#/ && $1 != "timestamp"' "$TSV" | wc -l | tr -d ' ')" -eq 2 ]
	! grep -q 'INTERRUPTED' "$TSV" || false
	# Rows of one member of two: the cell is cut short, INTERRUPTED.
	rm -rf "${BATS_TEST_TMPDIR}/res"
	FAKE_ROWS=1 cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	[[ "$output" != *"had written every member's rows"* ]]
	[ "$(awk -F'\t' '$2 == "INTERRUPTED"' "$(sweep_tsv "$(sweep_dir)")" | wc -l | tr -d ' ')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# C10: the replica rule, INCOMPLETE markers

@test "a member with fewer rows than its istiod replicas in the cell written last is INCOMPLETE: marked in the text block header, the markdown cells table and the charts" {
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
}

@test "a standalone 002 refuses a --mesh-size larger than its contexts before any read" {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr bash "${CP}/002-collect-resource-metrics.sh" \
		--contexts ci-a --mesh-size 2 --dry-run
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"--mesh-size 2 is larger than the 1 context(s) given (ci-a)"*"(INCOMPLETE). Give a context per member, or a smaller --mesh-size."* ]]
}

# ---------------------------------------------------------------------------
# C11: the sweep's scratch files

@test "the sweep's scratch dir (envelope stderr, counts, cells) is gone after a run and after an interrupt" {
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'controlplane-sweep.*')" ]
	CP_TERM=1 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 143 ]
	grep -q '^controlplane-sweep\.' "${BATS_TEST_TMPDIR}/tmp-at-term"
	[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'controlplane-sweep.*')" ]
}

# ---------------------------------------------------------------------------
# C10: help texts

@test "002, 003 and 004 --help fit 100 columns; 004's names a failed end-of-sweep check, INTERRUPTED and the INCOMPLETE markers" {
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
	run bash "${CP}/002-collect-resource-metrics.sh" --help
	[[ "$output" == *"at most that"* ]]
}
