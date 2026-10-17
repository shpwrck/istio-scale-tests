#!/usr/bin/env bats
# The not-finished sweep record (sweep-outcome.txt from a sweep's start until it writes
# its outcome) and how the reports show it: a controlplane sweep that dies, the other
# sweeps' records at their start and end, a tuning sweep that stops after its start, and a
# sweep dir's own id as the fallback for its record. Through the real scripts (PL33); no
# cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
PENDING_MARK='<!-- sweep-outcome: pending -->'

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The kubectl stub: the Istio CR reads answer as fake-istio-cr.sh (the Istio CR's
	# generation from the file crgen, default 2); the istiod pod list (the proxy versions read, after the
	# start's version read) first copies bump-on-pods to crgen when that file exists;
	# `version` answers the file kver (unreachable, or no file: it fails); anything else
	# fails, as against an empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$CA_DIR"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	STUB_ISTIO_CR_GEN="$(cat "$d/crgen" 2>/dev/null || echo 2)"
	export STUB_ISTIO_CR_GEN
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" get pods -l app=istiod "*)
	[ ! -f "$d/bump-on-pods" ] || cp "$d/bump-on-pods" "$d/crgen"
	exit 1 ;;
*" version --output=json"*)
	k="$(cat "$d/kver" 2>/dev/null || echo unreachable)"
	[ "$k" != unreachable ] || exit 1
	printf '{"serverVersion":{"gitVersion":"%s"}}\n' "$k" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	export CA_DIR="$BATS_TEST_TMPDIR"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
}

# cp_sweep <args...>: controlplane 003 with the stub kubectl (PATH_PRE first on PATH, for a
# fake awk), its results under res/; output and stderr together.
cp_sweep() {
	PATH="${PATH_PRE:+${PATH_PRE}:}${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run bash "$CP/003-run-sweep.sh" "$@"
}

# sweep_dir: the one sweep dir under res/.
sweep_dir() {
	find "${BATS_TEST_TMPDIR}/res" -maxdepth 1 -name 'sweep-*' -type d
}

# fake_awk <case pattern> <action>: a fake awk in fakeawk/ that runs <action> (sh) when its
# arguments match <case pattern>, else the real awk. Prints the dir.
fake_awk() {
	local d="${BATS_TEST_TMPDIR}/fakeawk"
	mkdir -p "$d"
	printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$*" in %s) %s ;; esac\nexec %s "$@"\n' "$1" "$2" "$(command -v awk)" > "${d}/awk"
	chmod +x "${d}/awk"
	printf '%s' "$d"
}

# The count's awk program (003's cell count) prints this.
COUNT_PAT='*"print \"TOTAL\\t\" ncell"*'

@test "a controlplane sweep that dies keeps its not-finished record and every 004 format says so; a --resume of it runs, and a finished sweep leaves no pending line; an unfinished --resume's json keeps the earlier record under earlier" {
	local d rid fa
	# The first run dies while it counts its cells (TERM, as an interrupt), after its reports.
	fa="$(fake_awk "$COUNT_PAT" 'kill -TERM "$PPID"; exit 0')"
	PATH_PRE="$fa" cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 143
	d="$(sweep_dir)"
	rid="${d##*/sweep-}"
	grep -qx 'EXIT=unfinished' "$d/sweep-outcome.txt"
	grep -qx "RUN_ID=${rid}" "$d/sweep-outcome.txt"
	grep -q '^HARNESS_SHA=.' "$d/sweep-outcome.txt"
	grep -qE '^STARTED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$d/sweep-outcome.txt"
	grep -qx 'NEXT=if it died, --resume this sweep dir with the flags it ran with: the cells already measured are kept' "$d/sweep-outcome.txt"
	# Its own reports keep the "not written yet" line: the outcome never came.
	grep -qF "$PENDING_MARK" "$d/sweep-${rid}.md"
	grep -qF "$PENDING_MARK" "$d/scale-envelope-${rid}.md"
	# Every format says the sweep has not finished.
	# Its EXIT trap ran (the TERM trap), so the record says when and by what.
	grep -qE '^ENDED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$d/sweep-outcome.txt"
	grep -qx 'ENDED_EXIT=143' "$d/sweep-outcome.txt"
	grep -qx 'ENDED_SIGNAL=SIGTERM' "$d/sweep-outcome.txt"
	! grep -q '^STOP' "$d/sweep-outcome.txt"
	run --separate-stderr "$REPORT" --results-dir "$d" --format text
	assert_output --partial "# SWEEP OUTCOME (recorded in sweep-outcome.txt by run ${rid}): NOT FINISHED"
	assert_output --partial "#   warning: this sweep has not finished: the run that started at "
	assert_output --partial " (SIGTERM) before it wrote its outcome, so no cell count vouches for these results, which may be partial; next: --resume this sweep dir"
	run --separate-stderr "$REPORT" --results-dir "$d" --format md
	assert_output --partial "> **Sweep outcome** (recorded in \`sweep-outcome.txt\` by run \`${rid}\`): **not finished**"
	refute_output --partial "$PENDING_MARK"
	run --separate-stderr "$REPORT" --results-dir "$d" --format csv
	assert_line "# SWEEP_OUTCOME_EXIT=unfinished"
	run --separate-stderr "$REPORT" --results-dir "$d" --format json
	[ "$(jq -c '.sweep_outcome | [.exit, .unfinished, (.started_at | test("Z$")), .run_id, (.interrupted_at | test("Z$")), .interrupted_by]' <<<"$output")" = "[null,true,true,\"${rid}\",true,\"SIGTERM\"]" ]
	run --separate-stderr "$REPORT" --results-dir "$d" --format charts
	assert_output --partial "> **Warning:** this sweep has not finished: it was interrupted before it wrote its outcome (sweep-outcome.txt), so these charts may show partial results."
	# A --resume of it: the record is no recorded problem (it runs), and it writes the outcome.
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	refute_output --partial "records a problem"
	grep -qx 'EXIT=4' "$d/sweep-outcome.txt"
	! grep -qx 'EXIT=unfinished' "$d/sweep-outcome.txt"
	! grep -qF "$PENDING_MARK" "$d/sweep-${rid}.md"
	! grep -qF "$PENDING_MARK" "$d/scale-envelope-${rid}.md"
	grep -q '^## Sweep outcome' "$d/sweep-${rid}.md"
	run --separate-stderr "$REPORT" --results-dir "$d" --format json
	[ "$(jq -c '.sweep_outcome | [.exit, .unfinished, .failed]' <<<"$output")" = '[4,false,1]' ]
	run --separate-stderr "$REPORT" --results-dir "$d" --format charts
	refute_output --partial "has not finished"
	# A --resume that dies keeps the finished record as sweep-outcome.prev.txt; json says
	# the resume has not finished and keeps that record under "earlier", with nothing at the
	# top level that reads as this resume's count.
	PATH_PRE="$fa" cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 143
	run --separate-stderr "$REPORT" --results-dir "$d" --format json
	[ "$(jq -c '.sweep_outcome | [.exit, .failed, .failed_by, .unfinished, .resume_unfinished, .run_id, .earlier.exit, .earlier.failed, .earlier.unfinished, .interrupted_by]' <<<"$output")" = "[null,null,null,true,true,\"${rid}\",4,1,false,\"SIGTERM\"]" ]
	run --separate-stderr "$REPORT" --results-dir "$d" --format text
	assert_output --partial "the last --resume of this sweep (started at "
	assert_output --partial "has not finished (it was interrupted at "
	assert_output --partial " by SIGTERM; run the same --resume again): this is the outcome before it, from sweep-outcome.prev.txt"
}

@test "dataplane, churn, propagation and churn-dataplane sweeps write the not-finished record at their start and their outcome at their end; their own markdown keeps no pending line; ISTIO_PROXY_VERSIONS is in the placeholder preambles and the dataplane report (PL36)" {
	local suite script res d snap_bin="${BATS_TEST_TMPDIR}/snapbin"
	mkdir -p "$snap_bin"
	# A kubectl that fails every call, but first copies the sweep's sweep-outcome.txt (once):
	# what the record said while the sweep ran. STUB_ISTIOD: one istiod pod for the
	# churn-dataplane preflight.
	cat > "${snap_bin}/kubectl" <<'STUB'
#!/bin/sh
for f in "$CA_DIR/res-$CA_SUITE"/sweep-*/sweep-outcome.txt; do
	if [ -f "$f" ] && [ ! -f "$CA_DIR/snap-$CA_SUITE" ]; then cp "$f" "$CA_DIR/snap-$CA_SUITE"; fi
done
case "$*" in
*" get pods "*"-l app=istiod"*) [ -z "${STUB_ISTIOD:-}" ] || echo istiod-0 ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${snap_bin}/kubectl"
	for suite in dataplane churn propagation churn-dataplane; do
		res="${BATS_TEST_TMPDIR}/res-${suite}"
		case "$suite" in
		dataplane) script=tests/dataplane/003-run-sweep.sh ;;
		churn) script=tests/churn/003-run-sweep.sh ;;
		propagation) script=tests/propagation/006-run-sweep.sh ;;
		churn-dataplane) script=tests/churn-dataplane/004-run-sweep.sh ;;
		esac
		CA_SUITE="$suite" STUB_ISTIOD=1 DATAPLANE_RESULTS_DIR="$res" CHURN_RESULTS_DIR="$res" PROPAGATION_RESULTS_DIR="$res" \
			COEXEC_RESULTS_DIR="$res" DATAPLANE_INTER_COMBO_SETTLE_SEC=0 COEXEC_INTER_COMBO_SETTLE_SEC=0 PROPAGATION_SETTLE_SEC=0 \
			PATH="${snap_bin}:${PATH}" KUBECONFIG="$EK" CA_DIR="$BATS_TEST_TMPDIR" \
			run --separate-stderr bash "${ROOT}/${script}" --contexts ci-a --mesh-sizes 1
		assert_failure 4
		d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
		# While it ran: the not-finished record of this sweep.
		grep -qx 'EXIT=unfinished' "${BATS_TEST_TMPDIR}/snap-${suite}"
		grep -qx "RUN_ID=${d##*/sweep-}" "${BATS_TEST_TMPDIR}/snap-${suite}"
		grep -q '^STARTED_AT=' "${BATS_TEST_TMPDIR}/snap-${suite}"
		grep -q '^NEXT=if it died, .*the sweep again into a new dir' "${BATS_TEST_TMPDIR}/snap-${suite}"
		# At its end: the outcome, and no pending line left in its markdown.
		grep -qx 'EXIT=4' "$d/sweep-outcome.txt"
		! grep -rqF "$PENDING_MARK" "$d" --include='*.md'
		grep -rlq '^ISTIO_PROXY_VERSIONS=\|^# ISTIO_PROXY_VERSIONS=' "$d" --include='*.tsv'
	done
	run --separate-stderr bash "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$(find "${BATS_TEST_TMPDIR}/res-dataplane" -maxdepth 1 -name 'sweep-*' -type d)" --format text
	assert_output --partial "ISTIO_PROXY_VERSIONS"
}

@test "a tuning sweep that stops after its start records the stop (die: its reason, exit 1, UNIT=passes) and what to do, not a sweep that has not finished" {
	local res="${BATS_TEST_TMPDIR}/res-tuning" d
	# The suite setup fails against the empty kubeconfig: the sweep stops (exit 1) after its start.
	CONTROLPLANE_APPLY_ATTEMPTS=1 KUBECONFIG="$EK" run bash "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" --suite controlplane \
		--contexts ci-a --no-gitops-pause --no-baseline --profiles 01-push-throttling --settle 0 --rollout-timeout 1 --output-dir "$res"
	assert_failure 1
	assert_output --partial "error: suite setup failed"
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	! grep -q '^EXIT=unfinished' "$d/sweep-outcome.txt"
	grep -qx 'EXIT=1' "$d/sweep-outcome.txt"
	grep -qx 'STOPPED=1' "$d/sweep-outcome.txt"
	grep -qx 'STOP_REASON=suite setup failed' "$d/sweep-outcome.txt"
	grep -qx 'UNIT=passes' "$d/sweep-outcome.txt"
	grep -qx 'TOTAL=unknown' "$d/sweep-outcome.txt"
	grep -qx 'CUT_SHORT=1' "$d/sweep-outcome.txt"
	grep -q '^STARTED_AT=' "$d/sweep-outcome.txt"
	grep -q '^ENDED_AT=' "$d/sweep-outcome.txt"
	grep -qx "RUN_ID=${d##*/sweep-}" "$d/sweep-outcome.txt"
	grep -q "^PROBLEM=could not count the sweep's passes: it stopped before its end at " "$d/sweep-outcome.txt"
	grep -q '^NOTE=next: check that no profile is still applied (005-cleanup.sh) and Argo CD auto-sync is resumed' "$d/sweep-outcome.txt"
	run sweep_outcome_recorded "$d" text
	refute_output --partial "NOT FINISHED"
	assert_output --partial "SWEEP OUTCOME (recorded in sweep-outcome.txt by run ${d##*/sweep-}, exit 1):"
	assert_output --partial "  stopped early: suite setup failed"
	run sweep_outcome_recorded "$d" json
	[ "$(jq -c '[.exit, .unfinished, .stop_reason]' <<<"$output")" = '[1,false,"suite setup failed"]' ]
}

@test "a sweep dir's own id vouches for its record only when no TSV under it names its sweep" {
	local d="${BATS_TEST_TMPDIR}/sweep-r9" e="${BATS_TEST_TMPDIR}/churn/sweep-r9"
	mkdir -p "$d" "$e"
	# Controlplane: the TSV's RUN_ID is the sweep's (r2): a record of r9 in sweep-r9 is not its.
	sed 's/^# RUN_ID=fixture-t2$/# RUN_ID=r2/' "$FIXTURE" > "${d}/controlplane-r2.tsv"
	sweep_outcome --run-id r9 --record "$d" 1 >/dev/null
	run --separate-stderr "$REPORT" --results-dir "$d" --format text
	assert_success
	[[ "$stderr" == *"warning: ${d}/sweep-outcome.txt was recorded by run r9, not by this report's run r2"* ]]
	assert_output --partial "the record is from run r9, not from the run this report reads (r2)"
	run --separate-stderr "$REPORT" --results-dir "$d" --format json
	[ "$(jq -r '.sweep_outcome.report_run_id' <<<"$output")" = r2 ]
	# The TSV names r9: its record.
	sed -i.bak 's/^# RUN_ID=r2$/# RUN_ID=r9/' "${d}/controlplane-r2.tsv" && rm -f "${d}/controlplane-r2.tsv.bak"
	run --separate-stderr "$REPORT" --results-dir "$d" --format text
	[[ "$stderr" != *"was recorded by run"* ]]
	# Churn and dataplane cells mint their own RUN_IDs and record no SWEEP_RUN_ID: the dir's id
	# still vouches.
	printf '# RUN_ID=20261016T100501Z-7\nrun_id\tx\n' > "${e}/churn-20261016T100501Z-7.tsv"
	sweep_outcome --run-id r9 --record "$e" 1 >/dev/null
	MULTI_RUN_N=1 MULTI_RUN_IDS=sweep-r9 run --separate-stderr sweep_outcome_recorded "$e" text
	[ -z "$stderr" ]
	refute_output --partial "not from the run"
	# Propagation names its sweep (SWEEP_RUN_ID): another one is not vouched for by the dir.
	printf '# SWEEP_RUN_ID=r2\n# RUN_ID=r2-ms1\nrun_id\tx\n' > "${e}/endpoint-1.tsv"
	MULTI_RUN_N=1 MULTI_RUN_IDS=sweep-r9 run --separate-stderr sweep_outcome_recorded "$e" text
	[[ "$stderr" == *"was recorded by run r9, not by this report's run"* ]]
}
