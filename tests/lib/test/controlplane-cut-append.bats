#!/usr/bin/env bats
# A window write cut short inside a controlplane run, through 003 and 004 (PL33; no
# cluster: kubectl is a stub, and 001 and 002 are fakes in a symlinked copy of the tree):
# the cell's status row starts a line of its own instead of merging onto the cut row, so
# the cell reads as failed in 003's count and in 004, never as measured; a cut line that
# cannot be ended stops the sweep with that reason, and in the EXIT trap (an interrupt
# inside the cell) it skips the INTERRUPTED row with a warning but still writes the record.

bats_require_minimum_version 1.5.0
load test_helper

CP="${ROOT}/tests/controlplane"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The Istio CR reads answer as fake-istio-cr.sh; no controlplane-test namespace is left
	# on any member, and its delete succeeds. Anything else fails, as against an empty
	# kubeconfig.
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
# kind deploy, 3 replicas, 1 namespace, scoping none, traffic none), as
# controlplane-resume2.bats writes it.
cp_row() {
	printf '%s\t%s\t%s\t%s\t3\t1\tnone\t%s\t50\t90\t5\t9\t100\t3.33\t10\t60\t10\t10\t10\t50\t1.67\t20\t2048\t1048576\t1048576\t1048576\t3/3\t30.0\t100\t30\t0\t100\t200\t250\t10\t15\t40\t50\t120\t250\t22\t22\tOK\tnone\t0\t0\t1.00\t0.50\t30\t51200\t20480\t0\tpods\t4\t0\tnone\tdeploy\t%s\t12.5\t45\t120\t200\t3\t210\t180\t0\n' \
		"$1" "$2" "$3" "$4" "$5" "$(($4 * 2))"
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
	[[ "$stderr" == *"warning: could not write the INTERRUPTED row of the cell in progress; a --resume finds it by its rows"* ]]
	grep -qx 'ENDED_SIGNAL=SIGTERM' "${D}/sweep-outcome.txt"
	[ "$(awk -F'\t' '$2 == "INTERRUPTED"' "$TSV" | wc -l | tr -d ' ')" -eq 0 ]
}
