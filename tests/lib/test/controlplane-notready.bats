#!/usr/bin/env bats
# A Running istiod pod that is not Ready at a window's baseline, through the real 002, 004
# and redact-results.sh (PL33; no cluster: kubectl and curl are stubs, as in
# controlplane-window2.bats, or fixture TSVs): 002 keeps the pods with the pod manifest
# (istiod-spec.tsv, so --phase final has them) and writes a "# ISTIOD_NOT_READY=" line
# right before the window's WINDOW_ROWS line; 004 gives a data warning naming the cell (a
# growth window too), from the cell's latest attempt only, and the verdict does not change;
# the cell stays done; redaction maps the member names in the line. Names are placeholders.

bats_require_minimum_version 1.5.0
load test_helper

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"
FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
GROWTH="${ROOT}/tests/lib/test/fixtures/controlplane_ns_growth.tsv"
WARN_TAIL="A pod that is not Ready takes no new proxy connection, and one shutting down also drops its own as it exits (their reconnects to the other replicas add to the cell's push, convergence and CPU figures), so these cells' per-replica figures may include a replica that carried fewer proxies than the others, or none (its row's connected_proxies shows what it held at the window's end; a restarted replica's row is left out); it does not change the verdict."

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN" "$RES"
	export FX KLOG="${BATS_TEST_TMPDIR}/klog"
	# Each member runs istiod-a and istiod-b, Running, with the Ready conditions STUB_READY
	# gives ("True True" unless set), of a Deployment that wants two; other lists are empty.
	# Anything else fails, as against an empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KLOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*)
	read -r ra rb <<<"${STUB_READY:-True True}"
	printf 'istiod-a=%s istiod-b=%s ' "$ra" "$rb" ;;
*" -n istio-system get deploy istiod -o json "*)
	printf '%s\n' '{"spec":{"replicas":2,"template":{"spec":{"containers":[{"name":"discovery","resources":{"limits":{"cpu":"2","memory":"2Gi"}}}]}}},"status":{"replicas":2,"readyReplicas":2}}' ;;
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
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
}

# cp_window <res dir> [args...]: one 002 window of ctx-a into <res dir>/controlplane-R1.tsv.
cp_window() {
	local res="$1"
	shift
	PATH="${BIN}:${PATH}" run --separate-stderr "${CP}/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$res" --run-id R1 "$@"
}

# report <format> <dir>: 004 over <dir>, its stderr apart.
report() {
	run --separate-stderr "$REPORT" --results-dir "$2" --format "$1"
	assert_success
}

# cp_tsv <file> <line before the second window>: the fixture's preamble (plus
# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3) and two cells (15 and 30 services) of
# valid rows, each member 3 rows a window; the line goes right before the second window's
# WINDOW_ROWS line.
cp_tsv() {
	awk -F'\t' -v OFS='\t' -v x="$2" '
	function row(at, s, m,    i) { for (i = 1; i <= 3; i++) { $0 = t; $1 = "2026-06-01T" at ":00+00:00"; $2 = m; $4 = s; $31 = 0; print } }
	/^#/ {
		print
		if (index($0, "# ISTIOD_REPLICAS=") == 1) print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3"
		next
	}
	$1 == "timestamp" { print; next }
	t == "" { t = $0 }
	END {
		print "# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3"; row("00:00", 15, "mesh-a"); row("00:00", 15, "mesh-b")
		if (x != "") print x
		print "# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3"; row("00:10", 30, "mesh-a"); row("00:10", 30, "mesh-b")
	}' "$FIXTURE" > "$1"
}

@test "002 keeps a not-Ready istiod pod with the pod manifest and writes it right before the WINDOW_ROWS line, in split phases and in one; all Ready, no line" {
	local sd="${BATS_TEST_TMPDIR}/state" tsv="${RES}/controlplane-R1.tsv"
	mkdir -p "$sd"
	STUB_READY="True False" cp_window "$RES" --phase baseline --state-dir "$sd"
	assert_success
	[[ "$stderr" == *"warning: context ctx-a: istiod pod(s) Running but not Ready: istiod-b (a replacement still syncing its remote clusters, an old replica shutting down, or one failing its readiness probe under load?): such a pod takes no new proxy connection while not Ready (one shutting down also drops its own as it exits), and the window's ISTIOD_NOT_READY line tells the reports so"* ]]
	[ "$(cut -f 1,4 "${sd}/istiod-spec.tsv")" = "ctx-a"$'\t'"istiod-b" ]
	# The baseline's state dir carries the baseline's not-Ready pods: the final phase reads
	# the pods once, at the window's end (all Ready here: no ISTIOD_NOT_READY_AT_END line).
	rm -f "$KLOG"
	cp_window "$RES" --phase final --state-dir "$sd"
	assert_success
	[ "$(grep -cF '{.metadata.name}={.status.conditions' "$KLOG")" -eq 1 ]
	[ "$(grep -A 1 '^# ISTIOD_NOT_READY=' "$tsv")" = "# ISTIOD_NOT_READY=ctx-a=istiod-b"$'\n'"# WINDOW_ROWS=ctx-a=2/2" ]
	# The rows follow the WINDOW_ROWS line, as cp_cell_row needs.
	[ "$(grep -A 1 '^# WINDOW_ROWS=' "$tsv" | tail -n 1 | cut -f 2)" = ctx-a ]
	# One phase, both pods not Ready: one entry per pod.
	STUB_READY="False False" cp_window "$RES"
	assert_success
	[[ "$stderr" == *"istiod pod(s) Running but not Ready: istiod-a, istiod-b ("* ]]
	[ "$(grep -c '^# ISTIOD_NOT_READY=' "$tsv")" -eq 2 ]
	[ "$(grep '^# ISTIOD_NOT_READY=' "$tsv" | tail -n 1)" = "# ISTIOD_NOT_READY=ctx-a=istiod-a,ctx-a=istiod-b" ]
	# All Ready: no line, no warning.
	cp_window "$RES"
	assert_success
	[[ "$stderr" != *"not Ready"* ]]
	[ "$(grep -c '^# ISTIOD_NOT_READY=' "$tsv")" -eq 2 ]
	[ "$(grep -c '^# WINDOW_ROWS=' "$tsv")" -eq 3 ]
}

@test "004 names a cell whose window had a not-Ready istiod pod in a data warning, in every format, and the verdict does not change; 002's own TSV through 004 too" {
	local w a="${BATS_TEST_TMPDIR}/a" b="${BATS_TEST_TMPDIR}/b" v
	mkdir -p "$a" "$b"
	w="1 cell(s) have an istiod pod that was Running but not Ready at the window's baseline: mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (istiod-x on mesh-b, istiod-y on mesh-b). ${WARN_TAIL}"
	cp_tsv "${a}/controlplane-fixture-t2.tsv" "# ISTIOD_NOT_READY=mesh-b=istiod-x,mesh-b=istiod-y"
	cp_tsv "${b}/controlplane-fixture-t2.tsv" ""
	report json "$b"
	v="$(jq -c '.metadata.sla' <<<"$output")"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	report json "$a"
	[ "$(jq -c '.metadata.sla' <<<"$output")" = "$v" ]
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = "$(jq -cn --arg w "$w" '[$w]')" ]
	[[ "$stderr" == *"WARNING: ${w}"* ]]
	report text "$a"
	assert_line "# WARNING: ${w}"
	report csv "$a"
	assert_line "# WARNING: ${w}"
	report markdown "$a"
	assert_line "> **Warning:** ${w}"
	# The rows 002 writes with the line: the cell is done (no INCOMPLETE), and named.
	STUB_READY="True False" cp_window "${BATS_TEST_TMPDIR}/w"
	assert_success
	report json "${BATS_TEST_TMPDIR}/w"
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"have an istiod pod that was Running but not Ready at the window's baseline: mesh=1 "*" (istiod-b on ctx-a). ${WARN_TAIL}"* ]]
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" != *INCOMPLETE* ]]
}

@test "004 reads the line only right before a WINDOW_ROWS line of the cell's latest attempt: a --resume that ran the cell again drops it; a growth window's own line counts" {
	local d="${BATS_TEST_TMPDIR}/r" g="${BATS_TEST_TMPDIR}/g" n rows
	mkdir -p "$d" "$g"
	# The 30-service cell's first attempt had a not-Ready pod; a --resume ran it again.
	cp_tsv "${d}/controlplane-fixture-t2.tsv" "# ISTIOD_NOT_READY=mesh-b=istiod-x"
	n="$(wc -l < "${d}/controlplane-fixture-t2.tsv" | tr -d ' ')"
	rows="$(tail -n 6 "${d}/controlplane-fixture-t2.tsv" | sed 's/^2026-06-01T00:10:00/2026-06-01T00:20:00/')"
	{
		printf '# RESUMED_AT=2026-06-01T00:20:00+00:00 TSV_LINES=%s HARNESS_SHA=fixture KUBE_VERSIONS=mesh-a=v1.34.8,mesh-b=v1.34.8\n' "$n"
		printf '# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3\n%s\n' "$rows"
	} >> "${d}/controlplane-fixture-t2.tsv"
	report json "$d"
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	[ "$(jq -c '[.metadata.attempts[].rows_kept]' <<<"$output")" = '[6,6]' ]
	# A line that is not right before a WINDOW_ROWS line names nothing.
	cp_tsv "${d}/controlplane-fixture-t2.tsv" "# ISTIOD_NOT_READY=mesh-b=istiod-x"$'\n'"# NOTE=bats"
	report json "$d"
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	# A growth series' first window.
	awk '!/^#/ && $1 != "timestamp" && !d++ { print "# ISTIOD_NOT_READY=mesh-a=istiod-g"; print "# WINDOW_ROWS=mesh-a=1/1" } { print }' "$GROWTH" > "${g}/controlplane-fixture-ns.tsv"
	report json "$g"
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"1 cell(s) have an istiod pod that was Running but not Ready at the window's baseline: mesh=1 svcs=200 reps=1 ns=100 scope=namespace traffic=none window=grow (istiod-g on mesh-a). ${WARN_TAIL}"* ]]
}

@test "redact-results maps the member names of an ISTIOD_NOT_READY line, a member it alone names included, and keeps the pod names" {
	local d="${BATS_TEST_TMPDIR}/sweep-r1" c
	mkdir -p "$d"
	{
		printf '# RUN_ID=r1\n# ISTIO_VERSION_BY_CONTEXT=ci-a=v1.30.5,ci-b=v1.30.5\n'
		printf 'timestamp\tcontext\tmesh_size\tservice_count\tistiod_mem_mi\n'
		printf '# ISTIOD_NOT_READY=ci-a=istiod-6b7c9d-x2k4p,ci-c=istiod-6b7c9d-q8r2s\n'
		printf '# WINDOW_ROWS=ci-a=1/2,ci-b=1/1\n'
		printf '2026-10-18T05:13:37+00:00\tci-a\t2\t5\t120\n'
		printf '2026-10-18T05:13:37+00:00\tci-b\t2\t5\t118\n'
	} > "${d}/controlplane-r1.tsv"
	export TMPDIR="$BATS_TEST_TMPDIR"
	run --separate-stderr "${ROOT}/tests/lib/redact-results.sh" --out "${BATS_TEST_TMPDIR}/out" "$d"
	assert_success
	[[ "$stderr" == *"<mesh-c-ctx>     ci-c"* ]] || { echo "$stderr"; false; }
	c="${BATS_TEST_TMPDIR}/out/sweep-r1/controlplane-r1.tsv"
	[ "$(grep '^# ISTIOD_NOT_READY=' "$c")" = "# ISTIOD_NOT_READY=<mesh-a-ctx>=istiod-6b7c9d-x2k4p,<mesh-c-ctx>=istiod-6b7c9d-q8r2s" ]
	run grep -cE '(^|[^A-Za-z0-9_<])ci-[abc]([^A-Za-z0-9_]|$)' "$c"
	assert_output 0
}

@test "004 --help names the ISTIOD_NOT_READY data warning, within 100 columns" {
	run --separate-stderr "$REPORT" --help
	assert_success
	[ -z "$(awk 'length($0) > 100' <<<"$output")" ] || { awk 'length($0) > 100' <<<"$output"; false; }
	[[ "$(tr '\n' ' ' <<<"$output" | tr -s ' ')" == *"an istiod pod that was Running but not Ready at a window's baseline (its \"# ISTIOD_NOT_READY=<member>=<pod>,...\" line), and one not Ready at the window's end (its \"# ISTIOD_NOT_READY_AT_END=\" line): a pod that is not Ready takes no new proxy connection"* ]]
}
