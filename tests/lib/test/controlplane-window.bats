#!/usr/bin/env bats
# Controlplane windows, through 002, 003 and 004 (PL33; no cluster: kubectl and curl are
# stubs): 002's istiod %-of-limit divides by the limit of the pods it summed, and its
# WINDOW_ROWS line records the replicas each istiod Deployment wants (fewer Running warns);
# a split window across a harness change records both harnesses in the TSV; 004 over a
# sweep's TSV warns of a window on fewer pods than wanted; and a member with no istiod pod
# Running (one N/A row, <ctx>=1/<spec>) gives no replica shortfall.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/capacity.sh"

CP="${ROOT}/tests/controlplane"
FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	RES="${BATS_TEST_TMPDIR}/res"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export FX
	# The Istio CR reads answer as fake-istio-cr.sh. With STUB_ISTIOD=1, 002's reads of one
	# member: two Running istiod pods of a Deployment that wants three (one Pending), each at
	# 1500m and 1900Mi of a 2 CPU / 2Gi limit in `kubectl top`, other lists empty. Without it
	# 002's first read fails (a sweep's cells fail as PROBE_FAILED). Anything else fails, as
	# against an empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
esac
[[ -n "${STUB_ISTIOD:-}" ]] || exit 1
case " $* " in
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-a istiod-b\n' ;;
*" -n istio-system get deploy istiod -o json "*)
	printf '%s\n' '{"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"discovery","resources":{"limits":{"cpu":"2","memory":"2Gi"}}}]}}},"status":{"replicas":3,"readyReplicas":2}}' ;;
*" -n istio-system top pod -l app=istiod --no-headers "*) printf 'istiod-a 1500m 1900Mi\nistiod-b 1500m 1900Mi\n' ;;
*" -o json "*) cat "$FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
case "$url" in
*/metrics) body="$FX/pre_metrics.txt" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
	TSV="${RES}/controlplane-R1.tsv"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
}

# cp_window [args...]: one 002 window of ctx-a into res/controlplane-R1.tsv (STUB_ISTIOD=1).
cp_window() {
	PATH="${BIN}:${PATH}" STUB_ISTIOD=1 run --separate-stderr "${CP}/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$RES" --run-id R1 "$@"
}

# col <name>: the TSV column's values, one line, space-separated.
col() {
	awk -F'\t' -v c="$1" '$1 == "timestamp" { for (i = 1; i <= NF; i++) if ($i == c) k = i; next }
		/^#/ { next } k { printf "%s%s", (n++ ? " " : ""), $k } END { print "" }' "$TSV"
}

# cp_sweep <args...>: controlplane 003 with the stub kubectl (its cells fail as
# PROBE_FAILED), its results under res/; stdout in $output and stderr in $stderr.
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="$RES" \
		run --separate-stderr bash "${CP}/003-run-sweep.sh" "$@"
}

# sweep_dir: the one sweep dir under res/; sweep_tsv <dir>: its controlplane TSV.
sweep_dir() {
	find "$RES" -mindepth 1 -maxdepth 1 -name 'sweep-*' -type d
}
sweep_tsv() {
	find "$1" -maxdepth 1 -name 'controlplane-*.tsv'
}

# cp_row <ts> <ctx> <mesh> <svcs> <mem_mi>: a valid measurement row (66 columns, window
# kind deploy, 3 replicas, 1 namespace, scoping none, traffic none).
cp_row() {
	printf '%s\t%s\t%s\t%s\t3\t1\tnone\t%s\t50\t90\t5\t9\t100\t3.33\t10\t60\t10\t10\t10\t50\t1.67\t20\t2048\t1048576\t1048576\t1048576\t3/3\t30.0\t100\t30\t0\t100\t200\t250\t10\t15\t40\t50\t120\t250\t22\t22\tOK\tnone\t0\t0\t1.00\t0.50\t30\t51200\t20480\t0\tpods\t4\t0\tnone\tdeploy\t%s\t12.5\t45\t120\t200\t3\t210\t180\t0\n' \
		"$1" "$2" "$3" "$4" "$5" "$(($4 * 2))"
}

@test "cap_parse_istiod_used prints the pods it summed; 002 divides istiod's usage by the limit of those pods (a Pending replica counts in neither), warns, and records ctx=<n>/<spec> in WINDOW_ROWS" {
	run cap_parse_istiod_used <<<$'istiod-a 1500m 1900Mi\nistiod-b 1500m 1900Mi'
	assert_output "cpu_m=3000 mem_mi=3800 pods=2"
	run cap_parse_istiod_used < /dev/null
	assert_output "cpu_m=unknown mem_mi=unknown pods=unknown"
	cp_window
	assert_success
	[[ "$stderr" == *"warning: context ctx-a: 2 istiod pod(s) Running, but its Deployment wants 3 (one evicted or Pending?): this window measures it on 2 replica(s), and its WINDOW_ROWS entry (ctx-a=2/3) tells the reports so"* ]]
	[ "$(grep '^# WINDOW_ROWS=' "$TSV")" = "# WINDOW_ROWS=ctx-a=2/3" ]
	# 3800Mi of 2 x 2048Mi and 3000m of 2 x 2000m (over the Deployment's 3: 62 and 50).
	[ "$(col istiod_mem_pct_of_limit)" = "93 93" ]
	[ "$(col istiod_cpu_pct_of_limit)" = "75 75" ]
}

@test "002 split phases across a harness change: the rows go to the baseline's harness, a HARNESS_CHANGED_AT line after them records the final's, and the next window adds none" {
	local sd="${BATS_TEST_TMPDIR}/state" live key
	mkdir -p "$sd"
	cp_window
	assert_success
	live="$(sed -n 's/^# HARNESS_SHA=//p' "$TSV")"
	key="$(sed -n 's/^# HARNESS_CONTENT_KEY=//p' "$TSV")"
	cp_window --phase baseline --state-dir "$sd"
	assert_success
	# A checkout between the phases: the baseline ran other files than the final and the TSV.
	printf 'base999\t111111111111\t2030-01-01T00:00:00Z\n' > "${sd}/harness"
	cp_window --phase final --state-dir "$sd"
	assert_success
	[[ "$stderr" == *"warning: [002] this window's baseline ran other harness files (HARNESS_SHA=base999) than its final scrape (HARNESS_SHA=${live}): a harness file was edited, or a checkout ran, during the window; the TSV records both"* ]]
	[[ "$stderr" == *"warning: [002] these rows ran other harness files than controlplane-R1.tsv records (HARNESS_SHA=${live}, HARNESS_CONTENT_KEY=${key}; now HARNESS_SHA=base999, HARNESS_CONTENT_KEY=111111111111): a HARNESS_CHANGED_AT line before them records it"* ]]
	cp_window
	assert_success
	[[ "$stderr" != *"other harness files"* ]]
	run awk -F'\t' '/^# (WINDOW_ROWS|HARNESS_CHANGED_AT)=/ { print; next } !/^#/ && $1 != "timestamp" { print "row" }' "$TSV"
	assert_line --index 3 "# HARNESS_CHANGED_AT=2030-01-01T00:00:00Z HARNESS_SHA=base999 HARNESS_CONTENT_KEY=111111111111"
	assert_line --index 4 "# WINDOW_ROWS=ctx-a=2/3"
	assert_line --index 6 "row"
	assert_line --index 7 --regexp "^# HARNESS_CHANGED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z HARNESS_SHA=${live} HARNESS_CONTENT_KEY=${key}\$"
	assert_line --index 8 "# WINDOW_ROWS=ctx-a=2/3"
	[ "${#lines[@]}" -eq 11 ]
}

@test "004 over a sweep's TSV: a window that wrote all its rows on fewer pods than its Deployment wants is a data warning; a member whose one row is N/A (no istiod pod Running) gives no shortfall" {
	local tsv dg
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	tsv="$(sweep_tsv "$D")"
	# Its window wrote 2 rows on 2 of the 3 pods the Deployment wants, both in the TSV.
	{
		echo "# WINDOW_ROWS=ci-a=2/3"
		cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000
		cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000
	} >> "$tsv"
	run --separate-stderr "${CP}/004-report-results.sh" --results-dir "$D" --format json
	assert_success
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"(ci-a ran 2 of its 3 istiod replicas)"* ]]
	# A member with no istiod pod Running writes one degraded N/A row (istiod_restarted
	# unknown) and the entry <ctx>=1/<spec>: not "ran 1 of its 3" (its row is in no figure;
	# the verdict already reads CAUTION for it, n_valid below n_total).
	rm -rf "$RES"
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	tsv="$(sweep_tsv "$D")"
	dg="$(cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000 | awk -F'\t' -v OFS='\t' '{ for (i = 8; i <= 27; i++) $i = "N/A"; $31 = "unknown"; print }')"
	printf '# WINDOW_ROWS=ci-a=1/3\n%s\n' "$dg" >> "$tsv"
	run --separate-stderr "${CP}/004-report-results.sh" --results-dir "$D" --format json
	assert_success
	[ "$(jq -r '.metadata.data_warnings[]' <<<"$output" | grep -c 'istiod replicas')" = 0 ]
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" != PASS ]
}
