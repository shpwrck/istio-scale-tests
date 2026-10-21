#!/usr/bin/env bats
# The controlplane sweep through 003 and 004 (PL33; no cluster: kubectl is a stub, and where
# a cell must write rows, 001 and 002 are fakes in a symlinked copy of the tree). Before the
# first cell, the leftover check: the controlplane-test namespaces an earlier run left on
# the members are deleted (and recorded) before the first cell, and those that stay stop
# the sweep before it starts. A window write cut short: the cell's status row starts a line
# of its own instead of merging onto the cut row, so the cell reads as failed in 003's count
# and in 004, never as measured; a cut line that cannot be ended stops the sweep with that
# reason, and in the EXIT trap (an interrupt inside the cell) it skips the INTERRUPTED row
# with a warning but still writes the record. A sweep that ends inside a cell writes the
# INTERRUPTED row unless the cell had written every member's rows.

bats_require_minimum_version 1.5.0
load test_helper

CP="${ROOT}/tests/controlplane"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The kubectl stub (files in CUT_DIR, per context where named <file>.<ctx>; each call is
	# logged to KLOG when it is set): the Istio CR reads answer as fake-istio-cr.sh; `config
	# get-contexts -o name` lists kube-contexts (no file: it fails); a member's Istio remote
	# secrets are remote.<ctx> (no file: the read fails); its controlplane-test namespaces
	# are one while ns-left.<ctx> exists (their list fails while ns-uncountable exists), and
	# their delete removes it unless ns-stuck exists (then the delete fails). Anything else
	# fails, as against an empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$CUT_DIR"
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
	[ ! -f "$d/ns-uncountable" ] || exit 1
	if [ -f "$d/ns-left.$ctx" ]; then echo '{"items":[{"metadata":{"name":"controlplane-test-0","labels":{}}}]}'; else echo '{"items":[]}'; fi ;;
*" get namespace -l app.kubernetes.io/instance=controlplane-test -o name"*|*" get ns -l app.kubernetes.io/instance=controlplane-test -o name"*)
	[ ! -f "$d/ns-left.$ctx" ] || echo namespace/controlplane-test-0 ;;
*" delete namespace -l app.kubernetes.io/instance=controlplane-test "*)
	[ ! -f "$d/ns-stuck" ] || exit 1
	rm -f "$d/ns-left.$ctx" ;;
*" delete namespace "*) : ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	export CUT_DIR="$BATS_TEST_TMPDIR"
}

teardown() {
	local p
	[[ -s "${BATS_TEST_TMPDIR}/fake-pid" ]] || return 0
	p="$(<"${BATS_TEST_TMPDIR}/fake-pid")"
	if [[ "$p" =~ ^[0-9]+$ ]]; then kill -KILL "$p" 2>/dev/null || true; fi
}

# cut_tree [noend]: a copy of the repo (symlinks) whose 001 succeeds and whose 002 --phase
# final appends a window cut inside its row's next-to-last column (no newline: a full
# disk), then fails, or with FAKE_TERM=1 sends the sweep SIGTERM and waits to be stopped.
# With noend, tsv_end_line always fails (a line that cannot be ended). Sets SWEEP.
cut_tree() {
	local tree="${BATS_TEST_TMPDIR}/tree" f
	mkdir -p "${tree}/tests/controlplane" "${tree}/tests/lib"
	ln -s "${ROOT}/config" "${tree}/config"
	ln -s "${ROOT}/charts" "${tree}/charts"
	for f in "${ROOT}/tests/lib"/*; do ln -s "$f" "${tree}/tests/lib/${f##*/}"; done
	if [[ "${1:-}" == noend ]]; then
		rm "${tree}/tests/lib/common.sh"
		printf 'source "%s/tests/lib/common.sh"\ntsv_end_line() { return 1; }\n' "$ROOT" > "${tree}/tests/lib/common.sh"
	fi
	for f in "$CP"/*; do
		case "${f##*/}" in 001-* | 002-*) ;; *) ln -s "$f" "${tree}/tests/controlplane/${f##*/}" ;; esac
	done
	printf '#!/bin/sh\nexit 0\n' > "${tree}/tests/controlplane/001-setup-controlplane-test.sh"
	{
		echo '#!/usr/bin/env bash'
		echo 'set -euo pipefail'
		declare -f cp_row
		cat <<'FAKE'
phase="" ms=0 sc=0 out="" rid=""
while (($#)); do
	case "$1" in
	--phase) phase="$2"; shift 2 ;;
	--mesh-size) ms="$2"; shift 2 ;;
	--service-count) sc="$2"; shift 2 ;;
	--output-dir) out="$2"; shift 2 ;;
	--run-id) rid="$2"; shift 2 ;;
	*) shift ;;
	esac
done
[[ "$phase" == final ]] || exit 0
row="$(cp_row "$(date -u -Iseconds)" ci-a "$ms" "$sc" 1000)"
printf '# WINDOW_ROWS=ci-a=1\n%s' "${row%80$'\t'0}" >> "${out}/controlplane-${rid}.tsv"
[[ -n "${FAKE_TERM:-}" ]] || exit 1
echo "$$" > "${CUT_DIR}/fake-pid"
kill -TERM "$PPID"
exec sleep 30
FAKE
	} > "${tree}/tests/controlplane/002-collect-resource-metrics.sh"
	chmod +x "${tree}/tests/controlplane/001-setup-controlplane-test.sh" "${tree}/tests/controlplane/002-collect-resource-metrics.sh"
	SWEEP="${tree}/tests/controlplane/003-run-sweep.sh"
}

# cp_row <ts> <ctx> <mesh> <svcs> <mem_mi>: a valid measurement row (66 columns, window
# kind deploy, 3 replicas, 1 namespace, scoping none, traffic none).
cp_row() {
	printf '%s\t%s\t%s\t%s\t3\t1\tnone\t%s\t50\t90\t5\t9\t100\t3.33\t10\t60\t10\t10\t10\t50\t1.67\t20\t2048\t1048576\t1048576\t1048576\t3/3\t30.0\t100\t30\t0\t100\t200\t250\t10\t15\t40\t50\t120\t250\t22\t22\tOK\tnone\t0\t0\t1.00\t0.50\t30\t51200\t20480\t0\tpods\t4\t0\tnone\tdeploy\t%s\t12.5\t45\t120\t200\t3\t210\t180\t0\n' \
		"$1" "$2" "$3" "$4" "$5" "$(($4 * 2))"
}

# done_tree: a copy of the repo (symlinks) whose 001 succeeds and whose 002 --phase final
# appends a measurement row (cp_row's) for the first FAKE_ROWS members of its cell (default:
# all of its mesh size), then sends SIGTERM to the sweep that runs it and waits for it: the
# sweep ends after the cell's rows were written, before its end. Sets SWEEP.
done_tree() {
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

# cp_sweep <args...>: $SWEEP (the real 003 unless a tree set it) with the stub kubectl, its
# results under res/; output and stderr together, in order. cp_sweep2: stderr in $stderr.
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run bash "${SWEEP:-${CP}/003-run-sweep.sh}" "$@"
	sweep_dirs
}
cp_sweep2() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run --separate-stderr bash "${SWEEP:-${CP}/003-run-sweep.sh}" "$@"
	sweep_dirs
}

# sweep_dirs: D, the one sweep dir under res/, and TSV, its controlplane TSV (empty when none).
sweep_dirs() {
	D="$(find "${BATS_TEST_TMPDIR}/res" -mindepth 1 -maxdepth 1 -name 'sweep-*' -type d 2>/dev/null || true)"
	TSV=""
	[[ -z "$D" ]] || TSV="$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
}

# cut_sweep: one cell (mesh 1, ci-a, 5 Services) of $SWEEP; sets D (the sweep dir) and TSV.
cut_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run --separate-stderr bash "$SWEEP" --contexts ci-a --mesh-sizes 1 --service-counts 5
	D="$(find "${BATS_TEST_TMPDIR}/res" -mindepth 1 -maxdepth 1 -name 'sweep-*' -type d)"
	TSV="$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
}

@test "a window cut short without its newline: the cell's PROBE_FAILED row starts a line of its own, and 003's count and 004 read the cell as failed, not measured" {
	cut_tree
	cut_sweep
	[ "$status" -eq 4 ]
	# The cut row keeps its 65 columns; the status row has its 66 on a line of its own.
	[ "$(awk -F'\t' '$2 == "ci-a"' "$TSV" | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(awk -F'\t' '$2 == "ci-a" { print NF }' "$TSV")" -eq 65 ]
	[ "$(awk -F'\t' '$2 == "PROBE_FAILED" && $1 ~ /^[0-9]{4}-/ { print NF }' "$TSV")" -eq 66 ]
	# 003's count: the cell failed.
	grep -qx 'FAILED=1' "${D}/sweep-outcome.txt"
	grep -q '^FAILED_BY=.*PROBE_FAILED' "${D}/sweep-outcome.txt"
	# 004: the cell's one row is its status row (no valid sample), and the verdict is not PASS.
	run --separate-stderr bash "${CP}/004-report-results.sh" --results-dir "$D" --format json
	assert_success
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" != PASS ]
	[ "$(jq -c '[.results[] | [.n_total, .n_valid]]' <<<"$output")" = '[[1,0]]' ]
}

@test "a cut last line that cannot be ended stops the sweep with that reason; in the EXIT trap it skips the INTERRUPTED row with a warning, and the record is still written" {
	cut_tree noend
	cut_sweep
	[ "$status" -eq 1 ]
	grep -q '^STOP_REASON=could not end the last line of <sweep dir>/controlplane-.*\.tsv (a write cut short left it without a newline), so the cell.s PROBE_FAILED row cannot start a line of its own' "${D}/sweep-outcome.txt"
	[ "$(awk -F'\t' '$2 == "PROBE_FAILED"' "$TSV" | wc -l | tr -d ' ')" -eq 0 ]
	# Interrupted inside the cell: the EXIT trap's INTERRUPTED row cannot be written, and the
	# trap goes on to the record.
	rm -rf "${BATS_TEST_TMPDIR}/res"
	FAKE_TERM=1 cut_sweep
	[ "$status" -eq 143 ]
	[[ "$stderr" == *"warning: could not write the INTERRUPTED row of the cell in progress; the reports judge it by its rows"* ]]
	grep -qx 'STATUS=interrupted' "${D}/sweep-outcome.txt"
	grep -qx 'SIGNAL=SIGTERM' "${D}/sweep-outcome.txt"
	[ "$(awk -F'\t' '$2 == "INTERRUPTED"' "$TSV" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "a sweep that ends after its cell's 002 wrote every member's rows writes no INTERRUPTED row (the cell is done); one that wrote fewer does" {
	done_tree
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	[[ "$output" == *"note: the cell in progress (mesh=2 svcs=5 "*") had written every member's rows before the sweep ended: it is done (no INTERRUPTED row)"* ]]
	[ "$(awk -F'\t' '!/^#/ && $1 != "timestamp"' "$TSV" | wc -l | tr -d ' ')" -eq 2 ]
	! grep -q 'INTERRUPTED' "$TSV" || false
	grep -qx 'STATUS=interrupted' "${D}/sweep-outcome.txt"
	# Rows of one member of two: the cell is cut short, INTERRUPTED.
	rm -rf "${BATS_TEST_TMPDIR}/res"
	FAKE_ROWS=1 cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	[[ "$output" != *"had written every member's rows"* ]]
	[ "$(awk -F'\t' '$2 == "INTERRUPTED"' "$TSV" | wc -l | tr -d ' ')" -eq 1 ]
	# The row names the cell (mesh, Services, replicas, namespaces), not the trap's own values.
	[ "$(awk -F'\t' -v OFS=/ '$2 == "INTERRUPTED" { print $3, $4, $5, $6 }' "$TSV")" = 2/5/3/1 ]
}

# ---------------------------------------------------------------------------
# The leftover check before the first cell

@test "the leftover check: --dry-run says what a live run does; a live run counts on the measured members and the mesh members their remote secrets name (warning about one without a kube context), deletes with a sized --timeout, records it, and settles before the first cell; with none left, none is recorded and nothing settles before it" {
	cp_sweep2 --dry-run --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_success
	[[ "$stderr" == *"Leftover check: a live run counts the controlplane-test namespaces on the members (and on the mesh members their Istio remote secrets name), deletes those an earlier run left on the --contexts members through 005-cleanup.sh before the first cell, then waits --settle (0s) before it; it deletes nothing on the other mesh members, and stops first when they hold some; a dry run reads no cluster."* ]]
	# ci-a's remote secrets name ci-c (a kube context) and ci-d (none); ci-a holds a leftover.
	printf 'ci-a\nci-c\n' > "${CUT_DIR}/kube-contexts"
	printf '%s\n' '{"items":[{"metadata":{"name":"istio-remote-secret-ci-c","labels":{"istio/multiCluster":"true"},"annotations":{"networking.istio.io/cluster":"ci-c"}}},{"metadata":{"name":"istio-remote-secret-ci-d","labels":{"istio/multiCluster":"true"}}}]}' > "${CUT_DIR}/remote.ci-a"
	: > "${CUT_DIR}/ns-left.ci-a"
	export KLOG="${CUT_DIR}/klog"
	CONTROLPLANE_SETTLE_SEC=1 CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=7 \
		cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$output" == *"Leftover check: also counts on mesh member(s) ci-c (named by the Istio remote secrets, not measured)"* ]]
	[[ "$output" == *"warn: mesh member(s) ci-d (named by the Istio remote secrets) have no kube context of that name"*"check each with: kubectl --context <its context> get namespaces -l app.kubernetes.io/instance=controlplane-test"* ]]
	[[ "$output" == *"note: controlplane-test namespaces are left on the members (ci-a: 1) by a run cut short or a growth series."*"so 005-cleanup.sh deletes them now, before the first cell. Its --timeout is 7 s (about 7 s per namespace, 1 on the fullest member)"* ]]
	grep -q -- '--context=ci-a .*delete namespace -l app.kubernetes.io/instance=controlplane-test' "$KLOG"
	[ "$(grep -c -- '--context=ci-c .*delete namespace' "$KLOG")" = 0 ]
	[ ! -e "${CUT_DIR}/ns-left.ci-a" ]
	# The settle comes after the deletion and before the first cell's baseline (the order;
	# its length is the configured --settle, PL44).
	local o="$output" a b c
	a="${o%%so 005-cleanup.sh deletes them now*}"
	b="${o%%--- Post-cleanup settle (1s) ---*}"
	c="${o%%--- Baseline metrics scrape (phase 1/3) ---*}"
	[ "${#a}" -lt "${#b}" ]
	[ "${#b}" -lt "${#c}" ]
	grep -qx '# LEFTOVER_TEST_NAMESPACES=ci-a=1 (deleted by 005-cleanup.sh before the first cell)' "$TSV"
	grep -q '^NOTE=the leftover check found controlplane-test namespaces an earlier run left (ci-a: 1) and 005-cleanup.sh deleted them before the first cell' "${D}/sweep-outcome.txt"
	# None left: none recorded, and the first settle comes after the first cell's baseline.
	rm -rf "${BATS_TEST_TMPDIR}/res"
	CONTROLPLANE_SETTLE_SEC=1 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	o="$output"
	b="${o%%--- Post-cleanup settle*}"
	c="${o%%--- Baseline metrics scrape (phase 1/3) ---*}"
	[ "${#c}" -lt "${#b}" ]
	grep -qx '# LEFTOVER_TEST_NAMESPACES=none' "$TSV"
}

@test "leftovers that stay stop the sweep before its start (no row, no record): on a mesh member outside --contexts, before any deletion, with the 005 command for it; or still there after 005, with the sized --timeout to give it; a member whose namespaces cannot be counted only warns" {
	printf 'ci-a\nci-c\n' > "${CUT_DIR}/kube-contexts"
	printf '%s\n' '{"items":[{"metadata":{"name":"istio-remote-secret-ci-c","labels":{"istio/multiCluster":"true"},"annotations":{"networking.istio.io/cluster":"ci-c"}}}]}' > "${CUT_DIR}/remote.ci-a"
	: > "${CUT_DIR}/ns-left.ci-a"
	: > "${CUT_DIR}/ns-left.ci-c"
	export KLOG="${CUT_DIR}/klog"
	CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=7 \
		cp_sweep2 --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"controlplane-test namespaces an earlier run left are on mesh members outside --contexts (ci-c: 1; named by the Istio remote secrets of the measured members)"*"so nothing was deleted or measured. Delete these with: "*"/005-cleanup.sh --contexts ci-c --timeout 7 (about 7 s per namespace), then run this command again (it then deletes those on the --contexts members: ci-a: 1)."* ]]
	[ "$(grep -c 'delete namespace' "$KLOG")" = 0 ]
	[ -e "${CUT_DIR}/ns-left.ci-a" ]
	[ -e "${CUT_DIR}/ns-left.ci-c" ]
	[ -z "$(find "$D" -maxdepth 1 \( -name 'controlplane-*.tsv' -o -name sweep-outcome.txt \))" ]
	# Namespaces 005 cannot delete.
	rm -rf "${BATS_TEST_TMPDIR}/res"
	rm -f "${CUT_DIR}"/ns-left.* "${CUT_DIR}/kube-contexts" "${CUT_DIR}/remote.ci-a"
	: > "${CUT_DIR}/ns-left.ci-b"
	: > "${CUT_DIR}/ns-stuck"
	CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=3 \
		cp_sweep2 --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"warn: 005-cleanup.sh reported a failure; counting the namespaces again"* ]]
	[[ "$stderr" == *"controlplane-test namespaces are still on the members after 005-cleanup.sh (ci-b: 1: still Terminating, or the delete failed), and a cell would measure on top of them; nothing was measured. Run "*"005-cleanup.sh --contexts ci-b until it leaves none, then run this command again. Give it --timeout 3 (about 3 s per namespace, 1 on the fullest member; its default is 1 s)."* ]]
	[[ "$stderr" != *"Sweep [1/1]"* && "$output" != *"Sweep [1/1]"* ]]
	[ -z "$(find "$D" -maxdepth 1 \( -name 'controlplane-*.tsv' -o -name sweep-outcome.txt \))" ]
	# A member whose namespaces cannot be counted (as when unreachable): a warning, no cleanup.
	rm -rf "${BATS_TEST_TMPDIR}/res"
	rm -f "${CUT_DIR}"/ns-left.* "${CUT_DIR}/ns-stuck"
	: > "${CUT_DIR}/ns-uncountable"
	cp_sweep2 --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"warn: could not count the controlplane-test namespaces on ci-a, so a cell there may run on top of an earlier run's"* ]]
	[[ "$stderr" != *"005-cleanup.sh deletes them now"* ]]
}
