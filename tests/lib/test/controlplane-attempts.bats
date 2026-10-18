#!/usr/bin/env bats
# Controlplane sweep attempts and resumes, through 003 and 004 (PL33; no cluster: kubectl
# is a stub, or fails against an empty kubeconfig): 004 reads each cell's latest attempt
# and says how many rows it left out; the first run records its planned cells and a
# narrower --resume counts the ones that never ran as NOT_RUN; and what a --resume says
# when the first run could not count its cells or died before its TSV, or a member's
# Kubernetes version could not be read.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"

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

# attempts_dir <tsv_lines|legacy|none>: a sweep dir holding the fixture's cell twice: attempt 1
# (the fixture's 10 rows, one with istiod_restarted=1, then a PROBE_FAILED status row),
# then a --resume's attempt 2 (a valid row of each member, RSS 800 Mi). resumes.txt marks where attempt
# 2 starts by TSV_LINES, by RESUMED_AT only (an older harness), or is absent.
attempts_dir() {
	ATT_DIR="${BATS_TEST_TMPDIR}/sweep-att"
	rm -rf "$ATT_DIR"
	mkdir -p "$ATT_DIR"
	local f="${ATT_DIR}/controlplane-fixture-t2.tsv"
	cp "$FIXTURE" "$f"
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" { r = $0 }
		END { $0 = r; $1 = "2026-06-01T00:15:00+00:00"; $2 = "PROBE_FAILED"; for (i = 8; i <= 43; i++) $i = "N/A"; $31 = "unknown"; print }' "$FIXTURE" >> "$f"
	case "$1" in
	tsv_lines)
		printf 'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\tTSV_LINES\n2026-06-01T00:20:00+00:00\tfixture\tnone\tmesh-a=v1.34.8\t%s\n' \
			"$(wc -l < "$f" | tr -d ' ')" > "${ATT_DIR}/resumes.txt" ;;
	legacy)
		printf 'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\n2026-06-01T00:20:00+00:00\tfixture\tnone\tmesh-a=v1.34.8\n' > "${ATT_DIR}/resumes.txt" ;;
	esac
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" && !seen[$2]++ { $1 = "2026-06-01T00:30:00+00:00"; $8 = 800; print }' "$FIXTURE" >> "$f"
}

@test "controlplane 004 reads each cell's latest attempt (TSV_LINES, or RESUMED_AT in an older resumes.txt), says how many rows it left out in every format, and its verdict counts that attempt" {
	local mode
	for mode in tsv_lines legacy; do
		attempts_dir "$mode"
		run --separate-stderr "$REPORT" --results-dir "$ATT_DIR" --format json
		assert_success
		[ "$(jq -c '[.metadata.earlier_attempt_rows_left_out, .metadata.earlier_attempt_cells, (.results | length), .results[0].n_total, .results[0].n_valid, .results[0].istiod_rss_peak_mi.avg, .results[0].status_rows]' <<<"$output")" = '[11,1,1,2,2,800,0]' ]
		# The cell failed, then ran valid: it is covered; the earlier attempt's restart and
		# status row never reach the verdict.
		[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
		[[ "$stderr" == *"note: Each cell's latest attempt only: 11 row(s) of earlier attempts of 1 cell(s) (failed, then run again by a --resume) are left out of every figure, count and verdict; they stay in the TSV."* ]]
	done
	run --separate-stderr "$REPORT" --results-dir "$ATT_DIR" --format text
	assert_success
	assert_output --partial "# NOTE: Each cell's latest attempt only: 11 row(s) of earlier attempts of 1 cell(s)"
	assert_output --partial "n_total=2 n_valid=2"
	refute_output --partial "the cell was skipped or failed"
	refute_output --partial "partial coverage"
	run --separate-stderr "$REPORT" --results-dir "$ATT_DIR" --format csv
	assert_line "# earlier_attempts: rows_left_out=11 cells=1"
	run --separate-stderr "$REPORT" --results-dir "$ATT_DIR" --format md
	assert_line "earlier_attempt_rows_left_out: 11"
	assert_line "earlier_attempt_cells: 1"
	assert_output --partial "> **Note:** Each cell's latest attempt only: 11 row(s)"
	run --separate-stderr "$REPORT" --results-dir "$ATT_DIR" --format charts
	assert_output --partial "> **Note:** Each cell's latest attempt only: 11 row(s)"
	# The scale envelope reads the report: its verdict and the note.
	run --separate-stderr render_scale_envelope "$ATT_DIR" "$REPORT" "mesh-a,mesh-b" false
	assert_success
	assert_output --partial "Each cell's latest attempt only: 11 row(s) of earlier attempts of 1 cell(s)"
	assert_output --partial "PASS"
	refute_output --partial "partial coverage"
	# Without resumes.txt the TSV is one attempt (a first run, or a growth series): every row
	# counts, so the restart and the status row reach the verdict.
	attempts_dir none
	run --separate-stderr "$REPORT" --results-dir "$ATT_DIR" --format json
	assert_success
	[ "$(jq -c '[.metadata.earlier_attempt_rows_left_out, .results[0].n_total, .results[0].n_valid, .metadata.sla.verdict]' <<<"$output")" = '[0,13,11,"FAIL"]' ]
	[[ "$stderr" != *"latest attempt only"* ]]
}

@test "the first run records its planned cells; a narrower --resume counts a planned cell that never ran as NOT_RUN and names the flags that planned it; a sweep dir without the file says its planned set is unknown" {
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
	grep -qx "NOTE=1 planned cell(s) have no row (NOT_RUN: planned in planned-cells.txt, never reached: the run that planned them died or stopped first): mesh=1 svcs=6 reps=3 ns=1 scope=none traffic=none. To finish this sweep, --resume it with the axis flags that planned them: ./tests/controlplane/003-run-sweep.sh --resume <sweep dir> --contexts ci-a --mesh-sizes 1 --service-counts 5,6 --replica-counts 3 --namespace-counts 1 --sidecar-scopings none --traffic-configs none (<sweep dir> is this sweep's directory)" "$d/sweep-outcome.txt"
	# The text report prints it too, the command whole (no "." taken into its last flag).
	run --separate-stderr "$REPORT" --results-dir "$d" --format text
	assert_output --partial "--sidecar-scopings none --traffic-configs none (<sweep dir> is this sweep's directory)"
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

@test "a first run that could not count its cells says to --resume it, not to run the same --resume again" {
	local fa
	fa="$(fake_awk "$COUNT_PAT" 'echo "awk: simulated" >&2; exit 2')"
	PATH_PRE="$fa" cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	assert_output --partial "error: could not count the sweep's cells: awk: simulated; the rows are intact: --resume this sweep dir with the flags it ran with to count them; exit 4."
	refute_output --partial "run the same --resume again"
}

@test "a --resume of a sweep whose first run died before its TSV notes no missing preamble key; the TSV it writes has them" {
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

@test "a Kubernetes version note ends its span at a later --resume that could not read the member" {
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
