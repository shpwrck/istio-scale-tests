#!/usr/bin/env bats
# Controlplane sweep resumes, part 2, through 003 and 004 (PL33; no cluster: kubectl is a
# stub, and where a step must outlive a signal, 001 and 002 are fakes in a symlinked copy
# of the tree): a harness change an earlier run recorded does not stop a --resume, which
# carries it once; the first run's axis flags from the TSV when planned-cells.txt is
# gone; the sweep's pages before a --resume say so until it ends; each window's row count
# (WINDOW_ROWS) decides INCOMPLETE; leftovers on a mesh member outside --contexts stop the
# sweep before any deletion; a step still running after a second signal is killed before
# the INTERRUPTED row, and a step killed at the grace's end names the cleanup to run; a
# --resume whose HARNESS_SHA differs only in git describe is the same harness.

bats_require_minimum_version 1.5.0
load test_helper

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The kubectl stub of controlplane-resume.bats (files in RS_DIR, per context where named
	# <file>.<ctx>): the Istio CR reads answer as fake-istio-cr.sh; `config get-contexts -o
	# name` lists kube-contexts; a member's Istio remote secrets are remote.<ctx>; its
	# controlplane-test namespaces are one while ns-left.<ctx> exists, and their delete
	# removes it. 002's first read (its Running istiod pods) fails; under CP_TERM (once) it
	# sends SIGTERM to the topmost *003-run-sweep.sh ancestor, closes its output and waits.
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
	rm -f "$d/ns-left.$ctx" ;;
*" delete namespace controlplane-test "*) : ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running -o jsonpath="*)
	if [ -n "${CP_TERM:-}" ] && [ ! -e "$d/term-sent" ]; then
		: > "$d/term-sent"
		p=$PPID s=""
		while [ "${p:-1}" -gt 1 ]; do
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
	# The stubs' and fakes' own processes, when a test left them (only PIDs they recorded).
	local f p
	for f in "${BATS_TEST_TMPDIR}/sleep-pid" "${BATS_TEST_TMPDIR}/stub-pid" "${BATS_TEST_TMPDIR}/fake-pid"; do
		[[ -s "$f" ]] || continue
		p="$(<"$f")"
		if [[ "$p" =~ ^[0-9]+$ ]]; then kill -KILL "$p" 2>/dev/null || true; fi
	done
}

# cp_sweep <args...>: controlplane 003 ($SWEEP) with the stub kubectl, its results under
# res/; stdout in $output and stderr in $stderr.
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run --separate-stderr bash "$SWEEP" "$@"
}

# sweep_dir: the one sweep dir under res/.
sweep_dir() {
	find "${BATS_TEST_TMPDIR}/res" -mindepth 1 -maxdepth 1 -name 'sweep-*' -type d
}

# sweep_tsv <dir>: its controlplane TSV.
sweep_tsv() {
	find "$1" -maxdepth 1 -name 'controlplane-*.tsv'
}

# cp_row <ts> <ctx> <mesh> <svcs> <mem_mi>: a valid measurement row (66 columns, window
# kind deploy, 3 replicas, 1 namespace, scoping none, traffic none).
cp_row() {
	printf '%s\t%s\t%s\t%s\t3\t1\tnone\t%s\t50\t90\t5\t9\t100\t3.33\t10\t60\t10\t10\t10\t50\t1.67\t20\t2048\t1048576\t1048576\t1048576\t3/3\t30.0\t100\t30\t0\t100\t200\t250\t10\t15\t40\t50\t120\t250\t22\t22\tOK\tnone\t0\t0\t1.00\t0.50\t30\t51200\t20480\t0\tpods\t4\t0\tnone\tdeploy\t%s\t12.5\t45\t120\t200\t3\t210\t180\t0\n' \
		"$1" "$2" "$3" "$4" "$5" "$(($4 * 2))"
}

# measured <tsv> <lines>: replace the TSV's data rows (the status rows the stub's failed
# probes left) with the given lines.
measured() {
	grep -E '^#|^timestamp' "$1" > "${1}.new"
	printf '%s' "$2" >> "${1}.new"
	mv "${1}.new" "$1"
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

# stubborn_tree: a copy of the repo (symlinks) whose controlplane 001 succeeds and whose
# 002 --phase final ignores SIGTERM (a step whose cleanup hangs): it records its PID, sends
# the sweep FAKE_TERMS (1 or 2) SIGTERMs, then appends a late row as soon as the TSV holds
# the sweep's INTERRUPTED row, unless it was killed first. Sets SWEEP and TREE.
stubborn_tree() {
	TREE="${BATS_TEST_TMPDIR}/tree"
	local f
	mkdir -p "${TREE}/tests/controlplane"
	ln -s "${ROOT}/config" "${TREE}/config"
	ln -s "${ROOT}/charts" "${TREE}/charts"
	ln -s "${ROOT}/tests/lib" "${TREE}/tests/lib"
	for f in "$CP"/*; do
		case "${f##*/}" in 001-* | 002-*) ;; *) ln -s "$f" "${TREE}/tests/controlplane/${f##*/}" ;; esac
	done
	printf '#!/bin/sh\nexit 0\n' > "${TREE}/tests/controlplane/001-setup-controlplane-test.sh"
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
trap '' TERM
echo "$$" > "${RS_DIR}/fake-pid"
tsv="${out}/controlplane-${rid}.tsv"
kill -TERM "$PPID"
if [[ "${FAKE_TERMS:-1}" == 2 ]]; then
	sleep 1
	kill -TERM "$PPID"
fi
# Polled with builtins only (no fork per read): the row lands at once.
while ((SECONDS < 60)); do
	l=()
	mapfile -t l < "$tsv" 2>/dev/null || true
	if [[ "${l[*]-}" == *$'\t'INTERRUPTED$'\t'* ]]; then
		cp_row "$(date -u -Iseconds)" "${ctxs%%,*}" "$ms" "$sc" 999 >> "$tsv"
		exit 0
	fi
done
FAKE
	} > "${TREE}/tests/controlplane/002-collect-resource-metrics.sh"
	chmod +x "${TREE}/tests/controlplane/001-setup-controlplane-test.sh" "${TREE}/tests/controlplane/002-collect-resource-metrics.sh"
	SWEEP="${TREE}/tests/controlplane/003-run-sweep.sh"
}

@test "a harness change an earlier run recorded does not stop a --resume: its outcome carries it once, also from a run that did not finish; a change of the mesh still does" {
	local date
	done_dir
	echo 'PROBLEM=the harness changed during the sweep: HARNESS_SHA=aaa1111 at its start, bbb2222 at its end (bats)' >> "${D}/sweep-outcome.txt"
	date="$(sed -n 's/^# DATE=//p' "${D}/sweep-outcome.txt")"
	[ -n "$date" ]
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	[[ "$stderr" != *"records a problem"* ]]
	[ "$(grep -c "^PROBLEM=an earlier run of this sweep (outcome of ${date}) recorded: the harness changed during the sweep: HARNESS_SHA=aaa1111 at its start, bbb2222 at its end (bats)$" "${D}/sweep-outcome.txt")" = 1 ]
	# Resumed again: the carried line is carried as it is, once.
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=.*the harness changed during the sweep: HARNESS_SHA=aaa1111' "${D}/sweep-outcome.txt")" = 1 ]
	grep -q "^PROBLEM=an earlier run of this sweep (outcome of ${date}) recorded: the harness changed" "${D}/sweep-outcome.txt"
	# A run that did not finish (its not-finished record) noted a harness change: carried too.
	mv -f "${D}/sweep-outcome.txt" "${D}/sweep-outcome.prev.txt"
	printf 'RUN_ID=x\nEXIT=unfinished\nSTARTED_AT=2030-01-01T00:00:00Z\nNOTE=the harness changed during the sweep: HARNESS_SHA=ccc3333 at its start (bats)\n' > "${D}/sweep-outcome.txt"
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	grep -qx 'PROBLEM=an earlier run of this sweep (started at 2030-01-01T00:00:00Z, not finished) recorded: the harness changed during the sweep: HARNESS_SHA=ccc3333 at its start (bats)' "${D}/sweep-outcome.txt"
	[ "$(grep -c '^PROBLEM=.*HARNESS_SHA=aaa1111' "${D}/sweep-outcome.txt")" = 1 ]
	# A change of the mesh under the sweep still refuses the --resume.
	echo 'PROBLEM=the Istio version changed during the sweep (bats)' >> "${D}/sweep-outcome.txt"
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"--resume: this sweep's sweep-outcome.txt records a problem (the Istio version changed during the sweep (bats)), so no later run can vouch for its rows"* ]]
}

@test "a --resume of a sweep without planned-cells.txt takes the first run's axis flags from the TSV's # Contexts: line and says so; without that line too, it is refused unless the axis flags are given" {
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5,6
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	rm -f "${D}/planned-cells.txt"
	CONTROLPLANE_SERVICE_COUNTS=10 cp_sweep --resume "$D" --contexts ci-a,ci-b
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"note: --resume: the axis flags not given take the first run's values (the TSV's \"# Contexts:\" line: an older harness started this sweep without planned-cells.txt): --mesh-sizes 2 --service-counts 5,6 --replica-counts 3 --namespace-counts 1 --sidecar-scopings none --traffic-configs none"* ]]
	[[ "$stderr" == *"Planned matrix:    2 = 1×2×1×1×1×1"* ]]
	# Neither record: refused before any change, unless the flags are given.
	rm -f "${D}/planned-cells.txt"
	sed -i.bak '/^# Contexts: /d' "$TSV" && rm -f "${TSV}.bak"
	local before
	before="$(cksum < "$TSV")"
	cp_sweep --resume "$D" --contexts ci-a,ci-b
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"--resume: ${D} records none of its first run's axis values (no planned-cells.txt from its first run, no \"# Contexts:\" line in a controlplane-*.tsv), so a --resume without axis flags would run the environment's, --config's or default cells; nothing was run."* ]]
	[ "$(cksum < "$TSV")" = "$before" ]
	cp_sweep --resume "$D" --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5,6
	[ "$status" -eq 4 ]
}

@test "the sweep's pages from before a --resume say so until it ends: a resume that is interrupted leaves them marked; one that ends writes them again" {
	local p
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	# The sweep page and the envelope end with the outcome (the charts page has none).
	for p in "$D"/sweep-[0-9]*.md "$D"/scale-envelope-*.md; do grep -q '^## Sweep outcome' "$p"; done
	CP_TERM=1 cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 143 ]
	for p in "$D"/sweep-*.md "$D"/scale-envelope-*.md; do
		[ "$(grep -c '^## Sweep outcome' "$p")" = 0 ] || { echo "${p}: still shows the outcome"; false; }
		grep -q '^> \*\*Sweep outcome\*\*: not written yet: a --resume of this sweep started at [0-9T:-]*Z, and this page is from before it' "$p"
		[ "$(grep -c 'not written yet' "$p")" = 1 ]
	done
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	for p in "$D"/sweep-*.md "$D"/scale-envelope-*.md; do
		[ "$(grep -c 'not written yet' "$p")" = 0 ] || { echo "${p}: still marked"; false; }
	done
	for p in "$D"/sweep-[0-9]*.md "$D"/scale-envelope-*.md; do grep -q '^## Sweep outcome' "$p"; done
}

@test "each window's WINDOW_ROWS line decides INCOMPLETE: a member with fewer rows than its istiod replicas but all its window wrote is complete; one with fewer than its window wrote is not, and a --resume runs it again" {
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 1,2 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	sed -i.bak 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=ci-a=1,ci-b=2/' "$TSV" && rm -f "${TSV}.bak"
	# ci-b runs two replicas, but its window wrote one row (one replica was not Running).
	measured "$TSV" "# WINDOW_ROWS=ci-a=1"$'\n'"$(cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000)"$'\n'"# WINDOW_ROWS=ci-a=1,ci-b=1"$'\n'"$(cp_row 2026-06-01T00:02:00+00:00 ci-a 2 5 1100)"$'\n'"$(cp_row 2026-06-01T00:02:00+00:00 ci-b 2 5 1100)"$'\n'
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	jq -e '[.metadata.data_warnings[]? | select(test("INCOMPLETE"))] | length == 0' <<<"$output"
	# The window wrote two rows of ci-b; one is in the TSV (cut while written).
	sed -i.bak 's/^# WINDOW_ROWS=ci-a=1,ci-b=1$/# WINDOW_ROWS=ci-a=1,ci-b=2/' "$TSV" && rm -f "${TSV}.bak"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	jq -e '[.metadata.data_warnings[] | select(test("1 cell\\(s\\) are INCOMPLETE: .*mesh=2 svcs=5 reps=3 ns=1 scope=none traffic=none \\(ci-b has 1 of the 2 rows its window wrote\\)"))] | length == 1' <<<"$output"
	cp_sweep --resume "$D" --contexts ci-a,ci-b
	[ "$status" -eq 4 ]
	[[ "${output}${stderr}" == *"mesh=1 svcs=5 reps=3 ns=1 scope=none traffic=none — already has a valid row; skipping (resume)"* ]]
	[[ "${output}${stderr}" == *"mesh=2 svcs=5 reps=3 ns=1 scope=none traffic=none — cut short while its rows were written (INCOMPLETE: ci-b has 1 of the 2 rows its window wrote): running it again"* ]]
}

@test "leftovers on a mesh member outside --contexts stop the sweep before any deletion, with the 005 command for that member; the --contexts members' leftovers stay too" {
	printf 'ci-a\nci-c\n' > "${BATS_TEST_TMPDIR}/kube-contexts"
	printf '%s\n' '{"items":[{"metadata":{"name":"istio-remote-secret-ci-c","labels":{"istio/multiCluster":"true"},"annotations":{"networking.istio.io/cluster":"ci-c"}}}]}' > "${BATS_TEST_TMPDIR}/remote.ci-a"
	: > "${BATS_TEST_TMPDIR}/ns-left.ci-a"
	: > "${BATS_TEST_TMPDIR}/ns-left.ci-c"
	export KLOG="${BATS_TEST_TMPDIR}/klog"
	CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=7 \
		cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"controlplane-test namespaces an earlier run left are on mesh members outside --contexts (ci-c: 1; named by the Istio remote secrets of the measured members)"*"so nothing was deleted or measured. Delete these with: "*"/005-cleanup.sh --contexts ci-c --timeout 7 (about 7 s per namespace), then run this command again (it then deletes those on the --contexts members: ci-a: 1)."* ]]
	[ "$(grep -c 'delete namespace' "$KLOG")" = 0 ]
	[ -e "${BATS_TEST_TMPDIR}/ns-left.ci-a" ]
	[ -e "${BATS_TEST_TMPDIR}/ns-left.ci-c" ]
}

@test "a step still running after a second signal is killed before the INTERRUPTED row (no late row after it); one killed at the grace's end names the cleanup to run" {
	stubborn_tree
	FAKE_TERMS=2 SWEEP_STOP_GRACE_SEC=60 cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	# Killed before the INTERRUPTED row: it never saw that row (no late row), and it is gone.
	[ "$(awk -F'\t' '$2 == "INTERRUPTED"' "$TSV" | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(awk -F'\t' '$8 == 999' "$TSV" | wc -l | tr -d ' ')" -eq 0 ]
	[[ "$stderr" == *"warning: the sweep ended while its step (002-collect-resource-metrics.sh) still ran: sent SIGKILL to its "* ]]
	run kill -0 "$(cat "${BATS_TEST_TMPDIR}/fake-pid")"
	assert_failure
	# One signal: the step still runs at the grace's end and gets SIGKILL; the warning names
	# the cleanup its own could not run.
	rm -rf "${BATS_TEST_TMPDIR}/res" "${BATS_TEST_TMPDIR}/fake-pid"
	FAKE_TERMS=1 SWEEP_STOP_GRACE_SEC=1 cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	[ "$(awk -F'\t' '$8 == 999' "$(sweep_tsv "$(sweep_dir)")" | wc -l | tr -d ' ')" -eq 0 ]
	[[ "$stderr" == *"still ran 1s after SIGTERM: sent SIGKILL (their own cleanup did not run; clean up with: $(printf '%q' "${TREE}/tests/controlplane/005-cleanup.sh") --contexts ci-a,ci-b; a --resume of this sweep also deletes the namespaces before its first cell)"* ]]
}

@test "a --resume whose HARNESS_SHA differs from the run before it only in git describe (the same HARNESS_CONTENT_KEY) gets an INFO, not the harness warning or NOTE" {
	local key sha t
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(sweep_tsv "$D")"
	key="$(sed -n 's/^# HARNESS_CONTENT_KEY=//p' "$TSV")"
	[[ "$key" =~ ^[0-9a-f]{12}$ ]]
	# The first run's describe was another tag on the same harness files.
	sed -i.bak 's/^# HARNESS_SHA=.*/# HARNESS_SHA=v0.0.1-tagged/' "$TSV" && rm -f "${TSV}.bak"
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	[[ "$stderr" != *"warning: --resume: this resume runs harness"* ]]
	sha="$(sed -n 's/^HARNESS_SHA=//p' "${D}/sweep-outcome.txt")"
	t="$(awk -F'\t' 'NR == 2 { print $1 }' "${D}/resumes.txt")"
	grep -qx "INFO=the --resume at ${t} ran HARNESS_SHA=${sha}, after HARNESS_SHA=v0.0.1-tagged: they differ only in git describe (a commit or tag that changed no harness file; the same HARNESS_CONTENT_KEY ${key}), so its rows ran the same harness" "${D}/sweep-outcome.txt"
	[ "$(grep -c '^NOTE=the --resume at .* ran HARNESS_SHA=' "${D}/sweep-outcome.txt")" = 0 ]
	# The report: one harness, no provenance warning.
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = null ]
}
