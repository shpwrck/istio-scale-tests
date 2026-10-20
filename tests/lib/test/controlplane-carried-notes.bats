#!/usr/bin/env bats
# What a controlplane --resume carries from an earlier run, through 003 and 004 in a copy of
# the checkout (PL33; no cluster: kubectl and curl are stubs, 001 and 005 stand-ins, 002
# the real one): a harness change in a run that wrote no rows (interrupted before its first
# cell) is a NOTE once the resume's rows ran one harness, also after a second interrupted
# run; one that a --resume made a NOTE before it was interrupted is carried once; the note
# that the steps' own harness reads could not be checked is carried from a finished and
# from an interrupted run.

bats_require_minimum_version 1.5.0
load test_helper
load harness_helper

setup() {
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
	R="${BATS_TEST_TMPDIR}/cp"
	RES="${BATS_TEST_TMPDIR}/res"
	export CN_DIR="$BATS_TEST_TMPDIR"
	_suite_copy "$R" controlplane
	# 001: reads the harness as the real one does (CN_RMLOG: after removing the steps' log,
	# as a temp-file cleaner would), then adds the harness file CN_EDIT1 and fails under
	# CN_FAIL; 004: under CN_TERM004, its first call sends the sweep (its parent) SIGTERM;
	# 005: the leftover namespaces are gone.
	cat > "$R/tests/controlplane/001-setup-controlplane-test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${ROOT}/tests/lib/common.sh"
[[ -z "${CN_RMLOG:-}" ]] || rm -f "${HARNESS_SWEEP_LOG:-/nonexistent}"
harness_read _hs _hk
[[ -z "${CN_EDIT1:-}" ]] || echo x > "$CN_EDIT1"
[[ -z "${CN_FAIL:-}" ]] || exit 1
EOF
	{
		echo '#!/usr/bin/env bash'
		echo 'if [[ -n "${CN_TERM004:-}" && ! -e "$CN_DIR/term004-sent" ]]; then : > "$CN_DIR/term004-sent"; kill -TERM "$PPID"; exit 0; fi'
		tail -n +2 "$R/tests/controlplane/004-report-results.sh"
	} > "$R/tests/controlplane/004-report-results.sh.new"
	mv "$R/tests/controlplane/004-report-results.sh.new" "$R/tests/controlplane/004-report-results.sh"
	chmod +x "$R/tests/controlplane/004-report-results.sh"
	printf '#!/bin/sh\nrm -f "$CN_DIR/ns-left"\n' > "$R/tests/controlplane/005-cleanup.sh"
	git -C "$R" add -A
	git -C "$R" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m stand-ins
	: > "${BATS_TEST_TMPDIR}/kubeconfig"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The Istio CR reads answer as fake-istio-cr.sh, one Ready istiod pod whose metrics are a
	# fixture; one controlplane-test namespace is left while ns-left exists.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$HS_FAKE_CR" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1=True \n' ;;
*" get namespaces -l app.kubernetes.io/instance=controlplane-test "*)
	if [ -f "$CN_DIR/ns-left" ]; then echo '{"items":[{"metadata":{"name":"controlplane-test-0","labels":{}}}]}'; else echo '{"items":[]}'; fi ;;
*" -o json "*) cat "$HS_FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	cat > "${BIN}/curl" <<'STUB'
#!/bin/sh
out="" url=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
case "$url" in
*/metrics) body="$HS_FX/pre_metrics.txt" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [ -n "$out" ]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	# Under CN_TERM=<s>, the first `sleep <s>` (the settle after the leftover deletion, before
	# the first cell): CN_EDIT adds a harness file, CN_RMLOG removes the steps' log, then the
	# sweep (its parent) gets SIGTERM. Any other sleep is the real one.
	{
		echo '#!/bin/sh'
		echo 'if [ -n "${CN_TERM:-}" ] && [ "$1" = "$CN_TERM" ] && [ ! -e "$CN_DIR/term-sent" ]; then'
		echo '	: > "$CN_DIR/term-sent"'
		echo '	[ -z "${CN_EDIT:-}" ] || echo x > "$CN_EDIT"'
		echo '	[ -z "${CN_RMLOG:-}" ] || rm -f "${HARNESS_SWEEP_LOG:-/nonexistent}"'
		echo '	kill -TERM "$PPID"'
		echo '	exit 0'
		echo 'fi'
		printf 'exec %s "$@"\n' "$(command -v sleep)"
	} > "${BIN}/sleep"
	chmod +x "${BIN}/kubectl" "${BIN}/curl" "${BIN}/sleep"
	EDIT="$R/tests/controlplane/chart/zz-edit.yaml"
}

# cp_sweep <args...>: the copy's 003 with the stubs, results under res/ (settle 0 unless
# CONTROLPLANE_SETTLE_SEC is given); stdout in $output, stderr in $stderr.
cp_sweep() {
	HS_FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh" HS_FX="${ROOT}/tests/lib/test/fixtures/istiod-diag" \
		HARNESS_SHA_CHECK_SEC=3600 ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC="${CONTROLPLANE_SETTLE_SEC:-0}" \
		METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0 PATH="${BIN}:${PATH}" \
		KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" CONTROLPLANE_RESULTS_DIR="$RES" \
		run --separate-stderr bash "$R/tests/controlplane/003-run-sweep.sh" "$@"
}

# cp_term <args...>: cp_sweep with a namespace left on the member, SIGTERMed in the settle
# after its deletion, before its first cell (it adds no row); status 143. Sets D.
cp_term() {
	: > "${CN_DIR}/ns-left"
	rm -f "${CN_DIR}/term-sent"
	CN_TERM=9 CONTROLPLANE_SETTLE_SEC=9 cp_sweep "$@"
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[ -e "${CN_DIR}/term-sent" ]
	D="$(find "$RES" -maxdepth 1 -name 'sweep-*' -type d)"
	grep -qx 'EXIT=unfinished' "$D/sweep-outcome.txt"
}

# no_rows: the sweep's TSV holds no data row.
no_rows() {
	[ "$(grep -cv '^#\|^timestamp' "$D"/controlplane-*.tsv)" = 0 ]
}

@test "a harness change in a first run interrupted before its first cell (no rows), then --resume on the changed tree: a NOTE ending (that run wrote no rows), no PROBLEM, exit 0" {
	local t1
	CN_EDIT="$EDIT" cp_term --contexts ci-a --mesh-sizes 1 --service-counts 5 --config-dump-samples 0
	no_rows
	grep -q '^NOTE=the harness changed during the sweep: ' "$D/sweep-outcome.txt"
	t1="$(sed -n 's/^STARTED_AT=//p' "$D/sweep-outcome.txt")"
	[ -n "$t1" ]
	[ -e "$EDIT" ]
	cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; cat "$D/sweep-outcome.txt"; false; }
	grep -qx 'EXIT=0' "$D/sweep-outcome.txt"
	[ "$(grep -c "^NOTE=an earlier run of this sweep (started at ${t1}, not finished) recorded: the harness changed during the sweep: .* keep the start's (that run wrote no rows)$" "$D/sweep-outcome.txt")" = 1 ] \
		|| { cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c '^PROBLEM=\|(kept: \|run the sweep again if' "$D/sweep-outcome.txt")" = 0 ]
}

@test "the same harness change, then a --resume interrupted before its first cell too: its record keeps the carried line, the next --resume writes the NOTE once, and one interrupted after that keeps it a NOTE" {
	local t1 n
	CN_EDIT="$EDIT" cp_term --contexts ci-a --mesh-sizes 1 --service-counts 5 --config-dump-samples 0
	t1="$(sed -n 's/^STARTED_AT=//p' "$D/sweep-outcome.txt")"
	[ -n "$t1" ]
	cp_term --resume "$D" --contexts ci-a --config-dump-samples 0
	no_rows
	grep -q "^NOTE=an earlier run of this sweep (started at ${t1}, not finished) recorded: the harness changed during the sweep: " "$D/sweep-outcome.txt"
	[ "$(grep -c '^NOTE=the harness changed during the sweep' "$D/sweep-outcome.txt")" = 0 ]
	[ ! -e "$D/sweep-outcome.prev.txt" ]
	n="^NOTE=an earlier run of this sweep (started at ${t1}, not finished) recorded: the harness changed during the sweep: .* (that run wrote no rows)$"
	cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c "$n" "$D/sweep-outcome.txt")" = 1 ] || { cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c '^PROBLEM=\|the harness changed during the sweep' "$D/sweep-outcome.txt")" = 1 ]
	# Interrupted once more: that record holds the NOTE as it is, and the next outcome too
	# (from it and from sweep-outcome.prev.txt alike), once, no PROBLEM.
	cp_term --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$(grep -c "$n" "$D/sweep-outcome.txt")" = 1 ]
	cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c "$n" "$D/sweep-outcome.txt")" = 1 ] || { cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c '^PROBLEM=\|the harness changed during the sweep' "$D/sweep-outcome.txt")" = 1 ]
}

@test "a harness change in a finished run, made a NOTE by a --resume that was interrupted in its reports: the next --resume carries it once (from sweep-outcome.prev.txt), a NOTE, and 004 names it once" {
	local d1 n
	# The first run: 001 adds a harness file and its cell fails (a PROBLEM, exit 4).
	CN_EDIT1="$EDIT" CN_FAIL=1 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5 --config-dump-samples 0
	[ "$status" -eq 4 ] || { echo "status ${status}: ${stderr}"; false; }
	D="$(find "$RES" -maxdepth 1 -name 'sweep-*' -type d)"
	grep -q '^PROBLEM=the harness changed during the sweep: ' "$D/sweep-outcome.txt"
	d1="$(sed -n 's/^# DATE=//p' "$D/sweep-outcome.txt")"
	[ -n "$d1" ]
	n="^NOTE=an earlier run of this sweep (outcome of ${d1}) recorded: the harness changed during the sweep: .* (its rows were all run again later)$"
	# A --resume runs the cell again, makes the PROBLEM a NOTE at its end check, and is
	# interrupted in its first report: its record holds the NOTE, sweep-outcome.prev.txt
	# the PROBLEM.
	CN_TERM004=1 cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[ -e "${CN_DIR}/term004-sent" ]
	grep -qx 'EXIT=unfinished' "$D/sweep-outcome.txt"
	[ "$(grep -c "$n" "$D/sweep-outcome.txt")" = 1 ] || { cat "$D/sweep-outcome.txt"; false; }
	grep -q '^PROBLEM=the harness changed during the sweep: ' "$D/sweep-outcome.prev.txt"
	# The next --resume (every cell done): the change once, as that NOTE; no PROBLEM, exit 0.
	cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; cat "$D/sweep-outcome.txt"; false; }
	grep -qx 'EXIT=0' "$D/sweep-outcome.txt"
	[ "$(grep -c "$n" "$D/sweep-outcome.txt")" = 1 ] || { cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c '^PROBLEM=\|the harness changed during the sweep' "$D/sweep-outcome.txt")" = 1 ]
	run bash "$R/tests/controlplane/004-report-results.sh" --results-dir "$D" --format text
	assert_success
	[ "$(grep -c 'the harness changed during the sweep' <<<"$output")" = 1 ] || { echo "$output"; false; }
}

@test "the steps' log removed during a finished run (its NOTE), then --resume --extend-plan: the new outcome carries the NOTE once, and 004 names it" {
	local date note
	CN_RMLOG=1 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5 --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; false; }
	D="$(find "$RES" -maxdepth 1 -name 'sweep-*' -type d)"
	note="the steps' own harness reads could not be checked: the temp file they are added to (HARNESS_SWEEP_LOG) was gone at the end check (removed during the sweep, as a temp-file cleaner does), so a harness change that only a step read (undone before the sweep's next read) is not in its outcome"
	grep -qxF "NOTE=${note}" "$D/sweep-outcome.txt"
	date="$(sed -n 's/^# DATE=//p' "$D/sweep-outcome.txt")"
	[ -n "$date" ]
	cp_sweep --resume "$D" --contexts ci-a --mesh-sizes 1 --service-counts 5,6 --extend-plan --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; false; }
	[ "$(grep -cxF "NOTE=an earlier run of this sweep (outcome of ${date}) noted: ${note}" "$D/sweep-outcome.txt")" = 1 ] \
		|| { cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c "could not be checked" "$D/sweep-outcome.txt")" = 1 ]
	run bash "$R/tests/controlplane/004-report-results.sh" --results-dir "$D" --format text
	assert_output --partial "an earlier run of this sweep (outcome of ${date}) noted: the steps' own harness reads could not be checked"
}

@test "the steps' log removed during a run interrupted before its first cell: the --resume carries the note from its not-finished record, as a NOTE" {
	local t1
	CN_RMLOG=1 cp_term --contexts ci-a --mesh-sizes 1 --service-counts 5 --config-dump-samples 0
	no_rows
	grep -q "^NOTE=the steps' own harness reads could not be checked: the temp file" "$D/sweep-outcome.txt"
	t1="$(sed -n 's/^STARTED_AT=//p' "$D/sweep-outcome.txt")"
	[ -n "$t1" ]
	cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c "^NOTE=an earlier run of this sweep (started at ${t1}, not finished) noted: the steps' own harness reads could not be checked: the temp file .* is not in its outcome$" "$D/sweep-outcome.txt")" = 1 ] \
		|| { cat "$D/sweep-outcome.txt"; false; }
	[ "$(grep -c '^PROBLEM=' "$D/sweep-outcome.txt")" = 0 ]
}
