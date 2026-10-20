#!/usr/bin/env bats
# A controlplane --resume of a sweep whose first run died before it wrote its TSV, through
# 003 and 004 in a copy of the checkout (PL33; no cluster: kubectl and curl are stubs, 001
# and 005 stand-ins, 002 the real one): the resume records its start in resumes.txt
# (TSV_LINES 0), so its rows are its own, a harness change of that first run ends as a NOTE
# "(that run wrote no rows)", and the reports name no value of the first run (its TSV
# preamble is the resume's), also after a later --resume of one that was interrupted.

bats_require_minimum_version 1.5.0
load test_helper
load harness_helper

setup() {
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
	export TEST_PID="$BASHPID" NT_DIR="$BATS_TEST_TMPDIR"
	R="${BATS_TEST_TMPDIR}/cp"
	RES="${BATS_TEST_TMPDIR}/res"
	export NT_EDIT="$R/tests/controlplane/chart/zz-edit.yaml"
	_suite_copy "$R" controlplane
	# 001: reads the harness as the real one does; under NT_TERM001 (once), it stops the
	# sweep (term-sweep) in its first cell and runs on, as a real step does, until the sweep
	# stops it (one that exits as the signal arrives can leave the sweep waiting for it for
	# good while its peak-metrics poller runs: bash 5.2), else fails. 005: nothing to remove.
	cat > "$R/tests/controlplane/001-setup-controlplane-test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${ROOT}/tests/lib/common.sh"
harness_read _hs _hk
if [[ -n "${NT_TERM001:-}" && ! -e "$NT_DIR/term001-sent" ]]; then
	: > "$NT_DIR/term001-sent"
	term-sweep
	sleep 60
	exit 1
fi
EOF
	printf '#!/bin/sh\nexit 0\n' > "$R/tests/controlplane/005-cleanup.sh"
	git -C "$R" add -A
	git -C "$R" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m stand-ins
	: > "${BATS_TEST_TMPDIR}/kubeconfig"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# term-sweep: SIGTERM to the sweep, the topmost *003-run-sweep.sh ancestor below the
	# test's process.
	cat > "${BIN}/term-sweep" <<'STUB'
#!/bin/sh
p=$PPID s=""
while [ "${p:-1}" -gt 1 ] && [ "$p" != "${TEST_PID:?}" ]; do
	case "$(ps -o args= -p "$p" 2>/dev/null)" in *003-run-sweep.sh*) s="$p" ;; esac
	p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
done
[ -n "$s" ] && kill -TERM "$s"
STUB
	# The Istio CR reads answer as fake-istio-cr.sh, one Ready istiod pod whose metrics are a
	# fixture. `top nodes` (the metrics preflight, after the sweep's not-finished record and
	# before its TSV) fails; under NT_TOP_TERM (once) it first adds a harness file and stops
	# the sweep.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$HS_FAKE_CR" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1=True \n' ;;
*" top nodes "*)
	if [ -n "${NT_TOP_TERM:-}" ] && [ ! -e "$NT_DIR/top-sent" ]; then
		: > "$NT_DIR/top-sent"
		echo x > "$NT_EDIT"
		term-sweep
	fi
	exit 1 ;;
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
	chmod +x "${BIN}/term-sweep" "${BIN}/kubectl" "${BIN}/curl"
}

# cp_sweep <args...>: the copy's 003 with the stubs, results under res/ (the metrics
# preflight off unless METRICS_READY_TIMEOUT is given); stdout in $output, stderr in $stderr.
cp_sweep() {
	HS_FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh" HS_FX="${ROOT}/tests/lib/test/fixtures/istiod-diag" \
		HARNESS_SHA_CHECK_SEC=3600 ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 \
		METRICS_READY_TIMEOUT="${METRICS_READY_TIMEOUT:-0}" METRICS_READY_INTERVAL=1 ISTIO_VERSION_READY_WAIT_SEC=0 \
		PATH="${BIN}:${PATH}" KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" CONTROLPLANE_RESULTS_DIR="$RES" \
		run --separate-stderr bash "$R/tests/controlplane/003-run-sweep.sh" "$@"
}

# first_run_no_tsv: the first run, stopped in its metrics preflight after a harness file
# was added (status 143): a not-finished record that holds the change, no TSV. Sets D and
# T1 (its STARTED_AT).
first_run_no_tsv() {
	NT_TOP_TERM=1 METRICS_READY_TIMEOUT=60 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5 --config-dump-samples 0
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[ -e "${NT_DIR}/top-sent" ]
	D="$(find "$RES" -maxdepth 1 -name 'sweep-*' -type d)"
	grep -qx 'EXIT=unfinished' "$D/sweep-outcome.txt"
	grep -q '^\(NOTE\|PROBLEM\)=the harness changed during the sweep: ' "$D/sweep-outcome.txt" || { cat "$D/sweep-outcome.txt"; false; }
	[ -z "$(find "$D" -name 'controlplane-*.tsv')" ]
	T1="$(sed -n 's/^STARTED_AT=//p' "$D/sweep-outcome.txt")"
	[ -n "$T1" ]
	# 003's end check reads whole seconds: a resume that starts in the second of T1 could be
	# the run that record is about, so the next one starts after it.
	until [[ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$T1" ]]; do sleep 0.2; done
}

# one_note <record>: the record names the first run's harness change once, as the NOTE
# "(that run wrote no rows)", and holds no PROBLEM.
one_note() {
	[ "$(grep -c "^NOTE=an earlier run of this sweep (started at ${T1}, not finished) recorded: the harness changed during the sweep: .* (that run wrote no rows)$" "$1")" = 1 ] \
		|| { cat "$1"; false; }
	[ "$(grep -c '^PROBLEM=\|the harness changed during the sweep' "$1")" = 1 ]
}

@test "a first run stopped before its TSV after a harness change, then --resume: its resumes.txt line (TSV_LINES 0), the NOTE (that run wrote no rows), exit 0; 004 names no harness for the first run" {
	local tsv h
	first_run_no_tsv
	cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; cat "$D/sweep-outcome.txt"; false; }
	grep -qx 'EXIT=0' "$D/sweep-outcome.txt"
	one_note "$D/sweep-outcome.txt"
	# The resume's line, at line 0 of the TSV it then wrote (no "# RESUMED_AT=" line in it).
	[ "$(awk -F'\t' 'NR > 1 { print $5 }' "$D/resumes.txt")" = 0 ]
	tsv="$(find "$D" -name 'controlplane-*.tsv')"
	[ "$(grep -c '^# RESUMED_AT=' "$tsv")" = 0 ]
	h="$(sed -n 's/^# HARNESS_SHA=//p' "$tsv")"
	[[ "$h" == *-dirty.* ]]
	run --separate-stderr bash "$R/tests/controlplane/004-report-results.sh" --results-dir "$D" --format text
	assert_success
	assert_output --partial "the first run HARNESS_SHA=unknown KUBE_VERSIONS=unknown (added no rows), then --resume at "
	refute_output --partial "the first run HARNESS_SHA=${h}"
	run --separate-stderr bash "$R/tests/controlplane/004-report-results.sh" --results-dir "$D" --format json
	assert_success
	[ "$(jq -c '[.metadata.attempts[] | [.run[0:9], .harness_sha == "unknown", .started_at == "unknown", .rows]]' <<<"$output")" = '[["first run",true,true,0],["--resume ",false,false,1]]' ] \
		|| { jq -c '.metadata.attempts' <<<"$output"; false; }
}

@test "the same, its --resume stopped in its first cell, then a later --resume: the rows of each resume are its own, the NOTE (that run wrote no rows) once, no first-run note from the preamble that resume wrote" {
	local tsv
	first_run_no_tsv
	NT_TERM001=1 cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[ -e "${NT_DIR}/term001-sent" ]
	tsv="$(find "$D" -name 'controlplane-*.tsv')"
	cut -f 2 "$tsv" | grep -qx INTERRUPTED
	# Had the first run started not ready, the preamble would say so; this one is the
	# resume's, whose resumes.txt line names its own start.
	sed -i.bak 's/^# ISTIO_NOTREADY_AT_START=.*/# ISTIO_NOTREADY_AT_START=ci-a=IstiodNotReady/' "$tsv" && rm -f "${tsv}.bak"
	cp_sweep --resume "$D" --contexts ci-a --config-dump-samples 0
	[ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; cat "$D/sweep-outcome.txt"; false; }
	one_note "$D/sweep-outcome.txt"
	[ "$(grep -c "first run started\|the first run's start" "$D/sweep-outcome.txt")" = 0 ] || { cat "$D/sweep-outcome.txt"; false; }
	[ "$(awk -F'\t' 'NR > 1 { print ($5 == 0 ? "zero" : "lines") }' "$D/resumes.txt" | paste -sd, -)" = zero,lines ]
	run --separate-stderr bash "$R/tests/controlplane/004-report-results.sh" --results-dir "$D" --format json
	assert_success
	[ "$(jq -c '[.metadata.attempts[] | [.harness_sha == "unknown", .rows, .rows_kept]]' <<<"$output")" = '[[true,0,0],[false,1,0],[false,1,1]]' ] \
		|| { jq -c '.metadata.attempts' <<<"$output"; false; }
}
