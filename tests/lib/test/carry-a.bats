#!/usr/bin/env bats
# Carry-over pass A of the hand-off audit: each controlplane cell's latest attempt (A1, A9),
# planned cells (A2), the not-finished sweep record (A3), Istio CR generations and K2 (A5),
# the dirty-tree hash (A6), proxy versions (A7), masked kubectl errors (A8), the pushes n
# (A10), the sweep-dir id as a fallback (A11) and the round-10 leftovers (A12). Through the
# real scripts where a test can reach them (PL33); no cluster: kubectl is a stub, or fails
# against an empty kubeconfig.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh"
PENDING_MARK='<!-- sweep-outcome: pending -->'

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The kubectl stub: the Istio CR reads answer as fake-istio-cr.sh (the Istio CR's
	# generation from the file crgen, default 2); the istiod pod list (A7's read, after the
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

# a1_dir <tsv_lines|legacy|none>: a sweep dir holding the fixture's cell twice: attempt 1
# (the fixture's 10 rows, one with istiod_restarted=1, then a PROBE_FAILED status row),
# then a --resume's attempt 2 (two valid rows, RSS 800 Mi). resumes.txt marks where attempt
# 2 starts by TSV_LINES (A1), by RESUMED_AT only (a harness before A1), or is absent.
a1_dir() {
	A1="${BATS_TEST_TMPDIR}/sweep-a1"
	rm -rf "$A1"
	mkdir -p "$A1"
	local f="${A1}/controlplane-fixture-t2.tsv"
	cp "$FIXTURE" "$f"
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" { r = $0 }
		END { $0 = r; $1 = "2026-06-01T00:15:00+00:00"; $2 = "PROBE_FAILED"; for (i = 8; i <= 43; i++) $i = "N/A"; $31 = "unknown"; print }' "$FIXTURE" >> "$f"
	case "$1" in
	tsv_lines)
		printf 'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\tTSV_LINES\n2026-06-01T00:20:00+00:00\tfixture\tnone\tmesh-a=v1.34.8\t%s\n' \
			"$(wc -l < "$f" | tr -d ' ')" > "${A1}/resumes.txt" ;;
	legacy)
		printf 'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\n2026-06-01T00:20:00+00:00\tfixture\tnone\tmesh-a=v1.34.8\n' > "${A1}/resumes.txt" ;;
	esac
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" && !n++ { $1 = "2026-06-01T00:30:00+00:00"; $8 = 800; print; print }' "$FIXTURE" >> "$f"
}

# ---------------------------------------------------------------------------
# A1, A9: each cell's latest attempt

@test "A1, A9: controlplane 004 reads each cell's latest attempt (TSV_LINES, or RESUMED_AT in an older resumes.txt), says how many rows it left out in every format, and its verdict counts that attempt" {
	local mode
	for mode in tsv_lines legacy; do
		a1_dir "$mode"
		run --separate-stderr "$REPORT" --results-dir "$A1" --format json
		assert_success
		[ "$(jq -c '[.metadata.earlier_attempt_rows_left_out, .metadata.earlier_attempt_cells, (.results | length), .results[0].n_total, .results[0].n_valid, .results[0].istiod_rss_peak_mi.avg, .results[0].status_rows]' <<<"$output")" = '[11,1,1,2,2,800,0]' ]
		# A9: the cell failed, then ran valid: it is covered; the earlier attempt's restart and
		# status row never reach the verdict.
		[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
		[[ "$stderr" == *"note: Each cell's latest attempt only: 11 row(s) of earlier attempts of 1 cell(s) (failed, then run again by a --resume) are left out of every figure, count and verdict; they stay in the TSV."* ]]
	done
	run --separate-stderr "$REPORT" --results-dir "$A1" --format text
	assert_success
	assert_output --partial "# NOTE: Each cell's latest attempt only: 11 row(s) of earlier attempts of 1 cell(s)"
	assert_output --partial "n_total=2 n_valid=2"
	refute_output --partial "the cell was skipped or failed"
	refute_output --partial "partial coverage"
	run --separate-stderr "$REPORT" --results-dir "$A1" --format csv
	assert_line "# earlier_attempts: rows_left_out=11 cells=1"
	run --separate-stderr "$REPORT" --results-dir "$A1" --format md
	assert_line "earlier_attempt_rows_left_out: 11"
	assert_line "earlier_attempt_cells: 1"
	assert_output --partial "> **Note:** Each cell's latest attempt only: 11 row(s)"
	run --separate-stderr "$REPORT" --results-dir "$A1" --format charts
	assert_output --partial "> **Note:** Each cell's latest attempt only: 11 row(s)"
	# The scale envelope reads the report: its verdict and the note.
	run --separate-stderr render_scale_envelope "$A1" "$REPORT" "mesh-a,mesh-b" false
	assert_success
	assert_output --partial "Each cell's latest attempt only: 11 row(s) of earlier attempts of 1 cell(s)"
	assert_output --partial "PASS"
	refute_output --partial "partial coverage"
	# Without resumes.txt the TSV is one attempt (a first run, or a growth series): every row
	# counts, so the restart and the status row reach the verdict.
	a1_dir none
	run --separate-stderr "$REPORT" --results-dir "$A1" --format json
	assert_success
	[ "$(jq -c '[.metadata.earlier_attempt_rows_left_out, .results[0].n_total, .results[0].n_valid, .metadata.sla.verdict]' <<<"$output")" = '[0,13,11,"FAIL"]' ]
	[[ "$stderr" != *"latest attempt only"* ]]
}

# ---------------------------------------------------------------------------
# A2: planned cells

@test "A2: the first run records its planned cells; a narrower --resume counts a planned cell that never ran as NOT_RUN and names the flags that planned it; a sweep dir without the file says its planned set is unknown" {
	local d tsv
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	assert_failure 4
	d="$(sweep_dir)"
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	grep -qx '# PLAN=1 the first run: --mesh-sizes 1 --service-counts 5,6 --replica-counts 3 --namespace-counts 1 --sidecar-scopings none --traffic-configs none' "$d/planned-cells.txt"
	[ "$(grep -c "$(printf '^1\t[56]\t3\t1\tnone\tnone\tdeploy$')" "$d/planned-cells.txt")" = 2 ]
	# The run died before its second cell (no row of svcs=6): a --resume of the first cell
	# alone still counts the second, as not run, and says how to finish the sweep.
	awk -F'\t' '!(NF >= 40 && $4 == 6)' "$tsv" > "${tsv}.tmp" && mv "${tsv}.tmp" "$tsv"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	assert_output --partial "error: 2 of 2 cells failed: NOT_RUN x1, PROBE_FAILED x1."
	grep -qx 'TOTAL=2' "$d/sweep-outcome.txt"
	grep -qx 'FAILED_BY=NOT_RUN x1, PROBE_FAILED x1' "$d/sweep-outcome.txt"
	grep -qx "NOTE=1 planned cell(s) have no row (NOT_RUN: planned in planned-cells.txt, never reached: the run that planned them died or stopped first): mesh=1 svcs=6 reps=3 ns=1 scope=none traffic=none. To finish this sweep, --resume this sweep dir with the axis flags that planned them (and its --contexts); the first run: --mesh-sizes 1 --service-counts 5,6 --replica-counts 3 --namespace-counts 1 --sidecar-scopings none --traffic-configs none" "$d/sweep-outcome.txt"
	[ "$(grep -c '^# PLAN=' "$d/planned-cells.txt")" = 1 ]
	run --separate-stderr "$REPORT" --results-dir "$d" --format text
	assert_output --partial "#   error: 2 of 2 cells failed: NOT_RUN x1, PROBE_FAILED x1"
	# Resumed with the first run's flags, the cell runs (and fails again here): no NOT_RUN.
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	assert_failure 4
	assert_output --partial "error: 2 of 2 cells failed: PROBE_FAILED x2."
	! grep -q 'NOT_RUN' "$d/sweep-outcome.txt"
	# A sweep dir an older harness started (no planned-cells.txt): the resume starts one,
	# marked partial, and its outcome says the planned set is not known.
	rm -f "$d/planned-cells.txt"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	grep -q '^# PLANNED_SET=partial' "$d/planned-cells.txt"
	grep -q '^# PLAN=1 the --resume at ' "$d/planned-cells.txt"
	grep -qx "NOTE=this sweep's planned cells are not all known (planned-cells.txt: an older harness started it without one), so cells its first run planned but never reached are not counted; the count covers the cells with rows and the matrix of each later run" "$d/sweep-outcome.txt"
}

# ---------------------------------------------------------------------------
# A3: the not-finished record

@test "A3: a controlplane sweep that dies keeps its not-finished record and every 004 format says so; a --resume of it runs, and a finished sweep leaves no pending line; an unfinished --resume's json keeps the earlier record under earlier (A12)" {
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
	grep -qx 'NEXT=if it died, --resume this sweep dir with the flags it ran with: the cells with a valid row are kept' "$d/sweep-outcome.txt"
	# Its own reports keep the "not written yet" line: the outcome never came.
	grep -qF "$PENDING_MARK" "$d/sweep-${rid}.md"
	grep -qF "$PENDING_MARK" "$d/scale-envelope-${rid}.md"
	# Every format says the sweep has not finished.
	# I5: its EXIT trap ran (the TERM trap), so the record says when and by what.
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
	# A12: a --resume that dies keeps the finished record as sweep-outcome.prev.txt; json says
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

@test "A3: dataplane, churn, propagation and churn-dataplane sweeps write the not-finished record at their start and their outcome at their end; their own markdown keeps no pending line; ISTIO_PROXY_VERSIONS is in the placeholder preambles and the dataplane report (A7, PL36)" {
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

@test "A3, I5: a tuning sweep that stops after its start records the stop (die: its reason, exit 1, UNIT=passes) and what to do, not a sweep that has not finished" {
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

# ---------------------------------------------------------------------------
# A5: generations, K2

@test "A5: the Istio CR or its IstioRevision edited during a sweep at the same version and revision is a problem naming what changed; an unread generation is not compared" {
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=0
		istio_version_resolve ci-a,ci-b 0 "$1" 2>/dev/null
		echo "GENS=${ISTIO_GENERATIONS}"
		out=(); istio_version_recheck out "$1"; echo "SAME=${#out[@]}"
		export STUB_ISTIO_CR_GEN=3
		out=(); istio_version_recheck out "$1"; printf "%s\n" "${out[@]}"
		export STUB_ISTIO_CR_GEN=2 STUB_ISTIO_REV_GEN=5
		out=(); istio_version_recheck out "$1"; printf "%s\n" "${out[@]}"
		export STUB_ISTIO_VERSION=fail
		out=(); istio_version_recheck out "$1"; printf "%s\n" "${out[@]}"' _ "$FAKE_CR"
	assert_success
	assert_line --index 0 "GENS=ci-a=2/2,ci-b=2/2"
	assert_line --index 1 "SAME=0"
	assert_line --index 2 "--problem"
	assert_line --index 3 "the Istio CR or its IstioRevision was edited during the sweep, though the version and active revision read the same at the end (ci-a: its Istio CR default (generation 2 at the start, 3 at the end); ci-b: its Istio CR default (generation 2 at the start, 3 at the end); ISTIO_GENERATIONS): a version changed and changed back, or a values change, so its rows may not all come from one control-plane configuration"
	assert_line --index 4 "--problem"
	assert_line --index 5 --partial "(ci-a: its IstioRevision default (generation 2 at the start, 5 at the end); ci-b: its IstioRevision default (generation 2 at the start, 5 at the end); ISTIO_GENERATIONS)"
	# Unreadable at the end: unconfirmed (a note), never a generation problem.
	refute_output --partial "$(printf '%s\n' --problem "the Istio CR or its IstioRevision was edited during the sweep, though the version and active revision read the same at the end (ci-a: its Istio CR default (generation 2 at the start, 2")"
	assert_line --index 6 "--note"
	assert_line --index 7 --partial "the Istio version at the end of the sweep is unconfirmed"
	[ "${#lines[@]}" -eq 8 ]
}

@test "A5: through 003, an Istio CR edited during the sweep is a problem in its outcome (exit 4); a --resume refuses a sweep whose Istio CR was edited since it started" {
	local d tsv
	# The generation goes from 2 to 3 right after the start's read.
	echo 3 > "${BATS_TEST_TMPDIR}/bump-on-pods"
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	d="$(sweep_dir)"
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	grep -qx '# ISTIO_GENERATIONS=ci-a=2/2' "$tsv"
	assert_output --partial "error: the Istio CR or its IstioRevision was edited during the sweep, though the version and active revision read the same at the end (ci-a: its Istio CR default (generation 2 at the start, 3 at the end); ISTIO_GENERATIONS)"
	grep -q '^PROBLEM=the Istio CR or its IstioRevision was edited during the sweep' "$d/sweep-outcome.txt"
	# A --resume refuses a recorded problem anyway; without it, it refuses the edit itself,
	# before any change.
	rm -f "${BATS_TEST_TMPDIR}/bump-on-pods"
	sed -i.bak '/^PROBLEM=/d' "$d/sweep-outcome.txt" && rm -f "$d/sweep-outcome.txt.bak"
	local before
	before="$(cat "$tsv")"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 1
	assert_output --partial "--resume: the Istio CR or its active IstioRevision was edited since this sweep started (ci-a: Istio CR generation 2 when the sweep started, 3 now; ISTIO_GENERATIONS), at the same version and active revision"
	[ "$(cat "$tsv")" = "$before" ]
	# Back at the generation it started on (nothing edited since): it resumes.
	echo 2 > "${BATS_TEST_TMPDIR}/crgen"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	refute_output --partial "was edited since this sweep started"
}

# _k2_kubectl: the Istio CR and IstioRevision as fake-istio-cr.sh; the istiod Deployment
# rolls out on its first read, is rolled out on its second, and every later read fails.
_k2_kubectl() {
	local n
	case " $* " in
	*" get deployments.apps istiod -o json "*)
		n="$(cat "${BATS_TEST_TMPDIR}/k2n" 2>/dev/null || echo 0)"
		echo $((n + 1)) > "${BATS_TEST_TMPDIR}/k2n"
		case "$n" in
		0) echo '{"metadata":{"generation":5},"status":{"observedGeneration":5,"replicas":3,"updatedReplicas":2,"readyReplicas":3}}' ;;
		1) echo '{"metadata":{"generation":5},"status":{"observedGeneration":5,"replicas":2,"updatedReplicas":2,"readyReplicas":2}}' ;;
		*)
			echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2
			return 1 ;;
		esac ;;
	*) "$FAKE_CR" "$@" ;;
	esac
}

@test "A5 (K2): a rollout that ended, whose confirming read then fails, is not ready (rollout-unconfirmed), never the ok the read before it saw" {
	# POLL = WAIT: the first poll is at the deadline; the rollout ends there, so it gets its
	# extra read one poll later, which fails.
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=2
		eval "$2"; FAKE_CR="$1"
		istio_version_resolve ci-a 0 _k2_kubectl
		echo "V=${ISTIO_VERSION} NR=${ISTIO_NOTREADY_AT_START}"' _ "$FAKE_CR" "$(declare -f _k2_kubectl)" 2>/dev/null
	[ "$(cat "${BATS_TEST_TMPDIR}/k2n")" -eq 3 ]
	assert_line "V=v1.30.5 NR=ci-a=rollout-unconfirmed"
	# The note names it.
	local -a o=()
	_istio_notready_notes o start "ci-a=rollout-unconfirmed" 2
	[[ "${o[*]}" == *"rollout-unconfirmed (an istiod rollout had just ended, and the read that confirms no old istiod pod still serves failed) on 1 member (ci-a)"* ]]
}

# ---------------------------------------------------------------------------
# A6: the dirty-tree hash

@test "A6: harness_sha names a dirty tree's uncommitted content as -dirty.<8hex>: the same for the same changes, staged or not; another for other changes; untracked files count, ignored ones do not" {
	local r="${BATS_TEST_TMPDIR}/repo" clean a b c
	mkdir -p "$r"
	git -C "$r" init -q
	printf 'one\n' > "$r/f"
	printf '*.log\n' > "$r/.gitignore"
	git -C "$r" add f .gitignore
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m init
	clean="$(ROOT="$r" harness_sha)"
	[[ "$clean" =~ ^[0-9a-f]{7}$ ]]
	: > "$r/x.log"
	[ "$(ROOT="$r" harness_sha)" = "$clean" ]
	printf 'two\n' > "$r/f"
	a="$(ROOT="$r" harness_sha)"
	[[ "$a" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	[ "$(ROOT="$r" harness_sha)" = "$a" ]
	git -C "$r" add f
	[ "$(ROOT="$r" harness_sha)" = "$a" ]
	printf 'three\n' > "$r/f"
	b="$(ROOT="$r" harness_sha)"
	[[ "$b" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	[ "$b" != "$a" ]
	git -C "$r" checkout -q -- f 2>/dev/null || true
	git -C "$r" reset -q --hard
	[ "$(ROOT="$r" harness_sha)" = "$clean" ]
	# An untracked file (git describe --dirty does not see it) makes it dirty; its content counts.
	printf 'u1\n' > "$r/new"
	c="$(ROOT="$r" harness_sha)"
	[[ "$c" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	printf 'u2\n' > "$r/new"
	[ "$(ROOT="$r" harness_sha)" != "$c" ]
	# Readers keep the -dirty substring (PL2): the gateway-api check strips it to compare commits.
	grep -q 'hc="${HARNESS%%-dirty\*}"' "${ROOT}/tests/gateway-api/001-run-ingress-check.sh"
}

# ---------------------------------------------------------------------------
# A7: proxy versions

# _pv_kubectl: istiod pods and their metrics for istio_proxy_versions, from files in pv/:
# <ctx>.pods (the Running istiod pods, one per line; no file: the list fails) and
# <pod>.metrics (its /metrics body; no file: the read fails); the Istio CR reads as
# fake-istio-cr.sh. Logs each call.
_pv_kubectl() {
	local ctx="" a d="${BATS_TEST_TMPDIR}/pv"
	for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
	echo "$*" >> "${d}/log"
	case " $* " in
	*" get pods -l app=istiod "*)
		if [[ ! -f "${d}/${ctx}.pods" ]]; then
			echo "error: You must be logged in to the server (Unauthorized)" >&2
			return 1
		fi
		sed 's#^#pod/#' "${d}/${ctx}.pods" ;;
	*" get --raw /api/v1/namespaces/istio-system/pods/"*)
		a="$*"
		a="${a##*/pods/}"
		a="${a%%:15014/proxy/metrics*}"
		if [[ ! -f "${d}/${a}.metrics" ]]; then
			echo "Error from server (ServiceUnavailable): the server is currently unable to handle the request" >&2
			return 1
		fi
		cat "${d}/${a}.metrics" ;;
	*) "$FAKE_CR" "$@" ;;
	esac
}

# pv_pod <pod> <version=count>...: a pod's metrics with those pilot_xds series.
pv_pod() {
	local p="$1" kv
	shift
	{
		echo '# HELP pilot_xds Number of endpoints connected to this pilot using XDS.'
		echo '# TYPE pilot_xds gauge'
		for kv in "$@"; do printf 'pilot_xds{version="%s"} %s\n' "${kv%=*}" "${kv#*=}"; done
		echo '# TYPE pilot_xds_pushes counter'
		echo 'pilot_xds_pushes{type="cds"} 42'
	} > "${BATS_TEST_TMPDIR}/pv/${p}.metrics"
}

@test "A7: istio_proxy_versions sums pilot_xds by version over a member's istiod pods, read through the API server's pod proxy; none, unknown per member" {
	mkdir -p "${BATS_TEST_TMPDIR}/pv"
	printf '%s\n' istiod-a1 istiod-a2 > "${BATS_TEST_TMPDIR}/pv/a.pods"
	pv_pod istiod-a1 1.30.5=100 1.30.4=3 1.29.9=0
	pv_pod istiod-a2 1.30.5=20
	echo istiod-b1 > "${BATS_TEST_TMPDIR}/pv/b.pods"
	pv_pod istiod-b1
	# c: the pod list fails; d: one pod of two cannot be read; e: no Running istiod pod;
	# f: an answer that is not Prometheus text.
	printf '%s\n' istiod-d1 istiod-d2 > "${BATS_TEST_TMPDIR}/pv/d.pods"
	pv_pod istiod-d1 1.30.5=7
	: > "${BATS_TEST_TMPDIR}/pv/e.pods"
	echo istiod-f1 > "${BATS_TEST_TMPDIR}/pv/f.pods"
	echo '<html>proxy error</html>' > "${BATS_TEST_TMPDIR}/pv/istiod-f1.metrics"
	METRICS_SCRAPE_TIMEOUT=7 run istio_proxy_versions a,b,c,d,e,f _pv_kubectl
	assert_success
	assert_output "a=1.30.5:120+1.30.4:3,b=none,c=unknown,d=unknown,e=unknown,f=unknown"
	run cat "${BATS_TEST_TMPDIR}/pv/log"
	assert_line "--context=a --request-timeout=5s -n istio-system get pods -l app=istiod --field-selector=status.phase=Running -o name"
	assert_line "--context=a --request-timeout=7s get --raw /api/v1/namespaces/istio-system/pods/istiod-a1:15014/proxy/metrics"
	refute_output --partial "port-forward"
	# Off the istiod version: a warning at the start (never a stop), a note at the end.
	ISTIO_PROXY_VERSIONS="a=1.30.5:120+1.30.4:3,b=none,c=unknown" ISTIO_VERSION_BY_CONTEXT="a=v1.30.5,b=v1.30.5,c=v1.30.5" \
		run --separate-stderr _istio_proxy_versions_warn
	assert_success
	[[ "$stderr" == "warning: proxies on another Istio version than their istiod are connected (a (istiod 1.30.5): 3 on 1.30.4; ISTIO_PROXY_VERSIONS): a sidecar keeps the version it was injected with until its pod restarts. The run goes on;"* ]]
	ISTIO_PROXY_VERSIONS="a=1.30.5:120,b=none" ISTIO_VERSION_BY_CONTEXT="a=v1.30.5,b=v1.30.5" run --separate-stderr _istio_proxy_versions_warn
	[ -z "$stderr" ]
}

@test "A7: istio_version_resolve records ISTIO_PROXY_VERSIONS (unchecked under --dry-run, without a read), istio_version_kv writes it, and the end of the sweep notes proxies off their istiod's version" {
	mkdir -p "${BATS_TEST_TMPDIR}/pv"
	echo istiod-a1 > "${BATS_TEST_TMPDIR}/pv/ci-a.pods"
	pv_pod istiod-a1 1.30.5=50 1.30.4=2
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		eval "$2"; FAKE_CR="$1"
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=0
		istio_version_resolve ci-a 0 _pv_kubectl
		istio_version_kv | grep "^ISTIO_PROXY_VERSIONS="
		out=(); istio_version_recheck out _pv_kubectl; printf "%s\n" "${out[@]}"' _ "$FAKE_CR" "$(declare -f _pv_kubectl)"
	assert_success
	assert_line --index 0 "ISTIO_PROXY_VERSIONS=ci-a=1.30.5:50+1.30.4:2"
	assert_line --index 1 "--note"
	assert_line --index 2 "proxies on another Istio version than their istiod were connected at the start (ci-a (istiod 1.30.5): 2 on 1.30.4; ISTIO_PROXY_VERSIONS): a sidecar keeps the version it was injected with until its pod restarts, so part of the traffic and xDS load came from it"
	[[ "$stderr" == *"warning: proxies on another Istio version than their istiod are connected (ci-a (istiod 1.30.5): 2 on 1.30.4;"* ]]
	: > "${BATS_TEST_TMPDIR}/pv/log"
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		eval "$2"; FAKE_CR="$1"
		export ISTIO_VERSION=v1.30.5
		istio_version_resolve ci-a 1 _pv_kubectl
		istio_version_kv | grep "^ISTIO_PROXY_VERSIONS="' _ "$FAKE_CR" "$(declare -f _pv_kubectl)"
	assert_output "ISTIO_PROXY_VERSIONS=unchecked"
	[ ! -s "${BATS_TEST_TMPDIR}/pv/log" ]
}

@test "A7: env_proxy_versions_summary sums over the members without naming them; controlplane 004 and the envelope print it" {
	run env_proxy_versions_summary "ci-a=1.30.5:120+1.30.4:3,ci-b=1.30.5:5,ci-c=none,ci-d=unknown"
	assert_output "1.30.5: 125, 1.30.4: 3 (4 members; 1 with none; 1 unknown)"
	run env_proxy_versions_summary "ci-a=none"
	assert_output "no proxy connected (1 member; 1 with none)"
	run env_proxy_versions_summary "ci-a=unknown"
	assert_output "unknown (1 member; 1 unknown)"
	run env_proxy_versions_summary unchecked
	assert_output unchecked
	run env_proxy_versions_summary ""
	assert_output unknown
	local r="${BATS_TEST_TMPDIR}/sweep-pv"
	mkdir -p "$r"
	awk '/^# HARNESS_SHA=/ { print "# ISTIO_GENERATIONS=mesh-a=2/2,mesh-b=3/2"; print "# ISTIO_PROXY_VERSIONS=mesh-a=1.30.5:30,mesh-b=1.30.5:34+1.30.4:2" } { print }' "$FIXTURE" > "${r}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$r" --format text
	assert_output --partial "  proxy versions (at start):   1.30.5: 64, 1.30.4: 2 (2 members)  [proxies connected to istiod, by Istio version, summed over the members]"
	run --separate-stderr "$REPORT" --results-dir "$r" --format md
	assert_line 'istio_proxy_versions: "mesh-a=1.30.5:30,mesh-b=1.30.5:34+1.30.4:2"'
	assert_line 'istio_generations: "mesh-a=2/2,mesh-b=3/2"'
	assert_output --partial "| proxy versions at start (connected to istiod, summed over the members) | 1.30.5: 64, 1.30.4: 2 (2 members) |"
	run --separate-stderr "$REPORT" --results-dir "$r" --format csv
	assert_output --partial "ISTIO_PROXY_VERSIONS=mesh-a=1.30.5:30,mesh-b=1.30.5:34+1.30.4:2"
	run --separate-stderr "$REPORT" --results-dir "$r" --format json
	[ "$(jq -r '.metadata.istio_proxy_versions' <<<"$output")" = "mesh-a=1.30.5:30,mesh-b=1.30.5:34+1.30.4:2" ]
	[ "$(jq -r '.metadata.istio_generations' <<<"$output")" = "mesh-a=2/2,mesh-b=3/2" ]
	run --separate-stderr render_scale_envelope "$r" "$REPORT" "mesh-a,mesh-b" false
	assert_output --partial "| Proxy (Envoy) versions at the start | 1.30.5: 64, 1.30.4: 2 (2 members) |"
	# A TSV from before A7: unknown, never a guess.
	cp "$FIXTURE" "${r}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$r" --format json
	[ "$(jq -r '.metadata.istio_proxy_versions' <<<"$output")" = "unknown" ]
}

# ---------------------------------------------------------------------------
# A8: masked kubectl errors

@test "A8: kubectl errors are recorded with API hosts and addresses masked; context names stay; localhost:8080 and a bracketed time are not masked" {
	run _istio_version_mask 'Get "https://api.ci-a.example:6443/apis/sailoperator.io/v1/istios/default?timeout=5s": dial tcp 192.0.2.10:6443: i/o timeout'
	assert_output 'Get "https://<api-host>:6443/apis/sailoperator.io/v1/istios/default?timeout=5s": dial tcp <ip>: i/o timeout'
	run _istio_version_mask 'Unable to connect to the server: dial tcp: lookup api.ci-a.example on 192.0.2.53:53: no such host'
	assert_output 'Unable to connect to the server: dial tcp: lookup <api-host> on <ip>: no such host'
	run _istio_version_mask 'Unable to connect to the server: dial tcp [2001:db8::1]:6443: connect: connection refused'
	assert_output 'Unable to connect to the server: dial tcp <ip>: connect: connection refused'
	run _istio_version_mask 'Get "https://[2001:db8:0:0:0:0:0:1]:6443/api": x'
	assert_output 'Get "https://<api-host>:6443/api": x'
	run _istio_version_mask 'The connection to the server api.ci-a.example:6443 was refused - did you specify the right host or port?'
	assert_output 'The connection to the server <api-host> was refused - did you specify the right host or port?'
	# kubectl without a kubeconfig context: not an API host refusing, so it stays apart.
	run _istio_version_mask 'The connection to the server localhost:8080 was refused - did you specify the right host or port?'
	assert_output 'The connection to the server localhost:8080 was refused - did you specify the right host or port?'
	run _istio_version_mask 'tls: failed to verify certificate: x509: certificate is valid for api.ci-b.example, *.apps.ci-b.example, not api.ci-a.example'
	assert_output 'tls: failed to verify certificate: x509: certificate is valid for <names>, not <api-host>'
	# Bracketed text that is no IPv6 address stays.
	run _istio_version_mask 'retrying [a:b] at [10:00:00.1]'
	assert_output 'retrying [a:b] at [10:00:00.1]'
	run _istio_version_mask 'error: context "ci-a" does not exist'
	assert_output 'error: context "ci-a" does not exist'
	# Grouping keys: members whose certificates differ group; localhost:8080 does not group
	# with a real API host refusing; a context kubectl does not find groups by message.
	[ "$(_istio_version_hostkey 'x509: certificate is valid for api.ci-a.example, not api.ci-x.example')" = \
		"$(_istio_version_hostkey 'x509: certificate is valid for api.ci-b.example, *.apps.ci-b.example, not api.ci-y.example')" ]
	[ "$(_istio_version_hostkey 'The connection to the server localhost:8080 was refused')" != \
		"$(_istio_version_hostkey 'The connection to the server api.ci-a.example:6443 was refused')" ]
	[ "$(_istio_version_hostkey 'error: context "ci-a" does not exist')" = "$(_istio_version_hostkey 'error: context "ci-b" does not exist')" ]
	# The why recorded from kubectl's stderr (_istio_version_errline): masked, klog prefix gone.
	printf 'E1017 10:00:00.000000   12345 memcache.go:265] couldn'"'"'t get current server API group list: Get "https://api.ci-a.example:6443/api?timeout=32s": dial tcp 198.51.100.7:6443: i/o timeout\n' > "${BATS_TEST_TMPDIR}/err"
	run _istio_version_errline "${BATS_TEST_TMPDIR}/err"
	assert_output 'couldn'"'"'t get current server API group list: Get "https://<api-host>:6443/api?timeout=32s": dial tcp <ip>: i/o timeout'
}

@test "A8: through 003, the outcome and the console name no API host or address of an unreadable member" {
	local d
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*"get istios.sailoperator.io default"*) echo 'Unable to connect to the server: dial tcp: lookup api.ci-a.example on 192.0.2.53:53: no such host' >&2; exit 1 ;;
*) exit 1 ;;
esac
STUB
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	assert_output --partial "lookup <api-host> on <ip>: no such host"
	refute_output --partial "api.ci-a.example"
	refute_output --partial "192.0.2.53"
	d="$(sweep_dir)"
	! grep -rqF -e "api.ci-a.example" -e "192.0.2.53" "$d"
}

# ---------------------------------------------------------------------------
# A10: the pushes n

@test "A10: a valid row without a push count: a data warning, pushes_avg shown with got/n_valid in every format (csv pushes_n, json xds_pushes_n)" {
	local r="${BATS_TEST_TMPDIR}/sweep-a10"
	mkdir -p "$r"
	# The first valid row's xds_pushes_delta (column 13) is N/A.
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" && !n++ { $13 = "N/A" } { print }' "$FIXTURE" > "${r}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$r" --format json
	assert_success
	[ "$(jq -c '[.results[0].n_valid, .results[0].xds_pushes_n, .results[0].xds_pushes_avg]' <<<"$output")" = '[9,8,100]' ]
	[[ "$(jq -r '.metadata.data_warnings | join(" ")' <<<"$output")" == *"1 valid row(s) of 1 cell(s) have no xDS push count"* ]]
	[[ "$stderr" == *"1 valid row(s) of 1 cell(s) have no xDS push count"* ]]
	run --separate-stderr "$REPORT" --results-dir "$r" --format text
	assert_output --partial "xDS pushes avg=100 (from 8/9 valid rows: the others have no push count)"
	run --separate-stderr "$REPORT" --results-dir "$r" --format csv
	[ "$(grep -v '^#' <<<"$output" | sed -n 2p | awk -F, '{ print $NF }')" = 8 ]
	# Every valid row with a count: pushes_n is n_valid, no warning.
	cp "$FIXTURE" "${r}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$r" --format json
	[ "$(jq -c '[.results[0].n_valid, .results[0].xds_pushes_n]' <<<"$output")" = '[9,9]' ]
	[[ "$stderr" != *"no xDS push count"* ]]
}

@test "A10: the conv_p99 fit's push gate says when it read pushes_avg from only some of a point's valid rows (FITNOTE in every format)" {
	local g="${BATS_TEST_TMPDIR}/g" f
	mkdir -p "$g"
	f="${g}/controlplane-fixture-ns.tsv"
	# The growth fixture at p99 300 ms (fitted), plus a second valid wide-probe row at N=400
	# without a push count.
	awk -F'\t' 'BEGIN { OFS = "\t" } /^#/ || $1 == "timestamp" { print; next }
		$10 == 90 { $10 = 300 }
		$7 == "wide" && $57 == "probe" && $6 == 400 && $31 == "0" && !d++ { print; $13 = "N/A" }
		{ print }' "${ROOT}/tests/lib/test/fixtures/controlplane_ns_growth.tsv" > "$f"
	run --separate-stderr "$REPORT" --results-dir "$g" --format json
	assert_success
	[[ "$(jq -r '.namespace_scaling.fit_note' <<<"$output")" == "the conv_p99_ms push gate (at least 120 xDS pushes per istiod replica) read pushes_avg from only some of the valid rows of 1 fitted point(s), the others having no push count: "*"N=400 (1/2 rows)" ]]
	run --separate-stderr "$REPORT" --results-dir "$g" --format text
	assert_output --partial "  NOTE: the conv_p99_ms push gate (at least 120 xDS pushes per istiod replica) read pushes_avg from only some of the valid rows of 1 fitted point(s)"
	run --separate-stderr "$REPORT" --results-dir "$g" --format md
	assert_output --partial "> **Note:** the conv_p99_ms push gate"
	run --separate-stderr "$REPORT" --results-dir "$g" --format csv
	assert_output --partial "# scaling_fit: NOTE: the conv_p99_ms push gate"
}

# ---------------------------------------------------------------------------
# A11: the sweep dir's id is a fallback

@test "A11: a sweep dir's own id vouches for its record only when no TSV under it names its sweep" {
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

# ---------------------------------------------------------------------------
# A12: round-10 leftovers

@test "A12: a first run that could not count its cells says to --resume it, not to run the same --resume again" {
	local fa
	fa="$(fake_awk "$COUNT_PAT" 'echo "awk: simulated" >&2; exit 2')"
	PATH_PRE="$fa" cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	assert_output --partial "error: could not count the sweep's cells: awk: simulated; the rows are intact: --resume this sweep dir with the flags it ran with to count them; exit 4."
	refute_output --partial "run the same --resume again"
}

@test "A12: a --resume of a sweep whose first run died before its TSV notes no missing preamble key; the TSV it writes has them" {
	local d tsv
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	d="$(sweep_dir)"
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	rm -f "$tsv" "$d"/*.md
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	refute_output --partial "does not record its members' active Istio revisions"
	refute_output --partial "does not record its Istio CR and IstioRevision generations"
	refute_output --partial "an older harness started it"
	! grep -q "an older harness started it" "$d/sweep-outcome.txt"
	grep -qx '# ISTIO_ACTIVE_REVISIONS=ci-a=default' "$tsv"
	grep -qx '# ISTIO_GENERATIONS=ci-a=2/2' "$tsv"
}

@test "A12: a Kubernetes version note ends its span at a later --resume that could not read the member" {
	local d tsv t1 t2
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	d="$(sweep_dir)"
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	sed -i.bak 's/^# KUBE_VERSIONS=.*/# KUBE_VERSIONS=ci-a=v1.30.4/' "$tsv" && rm -f "${tsv}.bak"
	echo v1.31.2 > "${BATS_TEST_TMPDIR}/kver"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	t1="$(awk -F'\t' 'NR == 2 { print $1 }' "$d/resumes.txt")"
	grep -qx "NOTE=the --resume at ${t1} read other Kubernetes server versions than the last known ones (ci-a: v1.30.4 before it, v1.31.2 then; from the TSV preamble's KUBE_VERSIONS and resumes.txt): rows from ${t1} on ran on them, up to a later change noted here" "$d/sweep-outcome.txt"
	echo unreachable > "${BATS_TEST_TMPDIR}/kver"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	t2="$(awk -F'\t' 'NR == 3 { print $1 }' "$d/resumes.txt")"
	grep -qx "NOTE=the --resume at ${t1} read other Kubernetes server versions than the last known ones (ci-a: v1.30.4 before it, v1.31.2 then; from the TSV preamble's KUBE_VERSIONS and resumes.txt): rows from ${t1} until ${t2} ran on them (the --resume at ${t2} could not read every member's version, so from there on they are not known), up to a later change noted here" "$d/sweep-outcome.txt"
}
