#!/usr/bin/env bats
# The controlplane probe (002, its windows) and its sweep (003), through the real scripts
# (PL33; no cluster: kubectl and curl are stubs, and where a cell must write rows, 001 and
# 002 are fakes in a symlinked copy of the tree). 002: the istiod %-of-limit and the
# WINDOW_ROWS line, a TSV's cut last line, the not-Ready istiod pods of a window's two ends,
# --watch windows, the config_dump samples, the scrape skew of split phases. 003: a window
# cut short, a sweep ended inside a cell, the leftover check before the first cell. 004 has
# its own tests (controlplane-report.bats). Names are placeholders.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/capacity.sh"

CP="${ROOT}/tests/controlplane"
FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
LIST='{.metadata.name}={.status.conditions'

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	RES="${BATS_TEST_TMPDIR}/res"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN" "$RES"
	export FX LIST KLOG="${BATS_TEST_TMPDIR}/klog" SEQ_N="${BATS_TEST_TMPDIR}/seq-n"
	# 002's reads. The Istio CR reads answer as fake-istio-cr.sh. Each member runs the pods
	# STUB_PODS names (istiod-a istiod-b unless set), Running, each at 1500m and 1900Mi in
	# `kubectl top`, of a Deployment that wants STUB_DEPLOY_REPLICAS (2 unless set) at a
	# 2 CPU / 2Gi limit (its read fails while STUB_DEPLOY_FAIL is set). The n-th pod list
	# read of a 002 run (resolve_pods' at a baseline, the read after each final scrape; SEQ_N
	# counts them) gives the pods the n-th "|"-separated entry of STUB_READY_SEQ as their
	# Ready conditions (the last entry for every read after it; "True True" unless set; FAIL
	# fails that read). One Running controlplane-test pod (ns1/sc-1) answers /config_dump
	# with a fixture body; other lists are empty. Anything else fails, as against an empty
	# kubeconfig. Every call is logged to KLOG, and each scrape of /metrics as "curl <url>".
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KLOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running -o jsonpath="*"$LIST"*)
	n="$(cat "$SEQ_N" 2>/dev/null || echo 0)"
	echo $((n + 1)) > "$SEQ_N"
	IFS='|' read -r -a seq <<<"${STUB_READY_SEQ:-True True}"
	((n < ${#seq[@]})) || n=$((${#seq[@]} - 1))
	[[ "${seq[n]}" != FAIL ]] || exit 1
	read -r -a rd <<<"${seq[n]}"
	i=0
	for p in ${STUB_PODS:-istiod-a istiod-b}; do printf '%s=%s ' "$p" "${rd[i]-}"; i=$((i + 1)); done ;;
*" -n istio-system get deploy istiod -o json "*)
	[[ -z "${STUB_DEPLOY_FAIL:-}" ]] || exit 1
	r="${STUB_DEPLOY_REPLICAS:-2}"
	printf '{"spec":{"replicas":%s,"template":{"spec":{"containers":[{"name":"discovery","resources":{"limits":{"cpu":"2","memory":"2Gi"}}}]}}},"status":{"replicas":%s,"readyReplicas":2}}\n' "$r" "$r" ;;
*" -n istio-system top pod -l app=istiod --no-headers "*)
	for p in ${STUB_PODS:-istiod-a istiod-b}; do printf '%s 1500m 1900Mi\n' "$p"; done ;;
*" -l app.kubernetes.io/instance=controlplane-test -o jsonpath="*) printf 'ns1|sc-1\n' ;;
*" exec sc-1 "*) cat "$FX/../fortio_ok.json" ;;
*" -o json "*) cat "$FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	# /metrics answers one body; with STUB_COUNT (a counter file) a numbered body per call:
	# call n fails when STUB_FAIL_CALLS lists it, reads 4 GiB of memory when STUB_BIG_CALLS
	# does (300 Mi otherwise), and its eds push counter is 100 x n.
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
*/metrics)
	[[ -n "$out" ]] || echo "curl $url" >> "$KLOG"
	if [[ -n "${STUB_COUNT:-}" ]]; then
		[[ "$out" == /dev/null ]] && exit 0
		n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 ))
		echo "$n" > "$STUB_COUNT"
		[[ " ${STUB_FAIL_CALLS:-} " != *" $n "* ]] || exit 7
		mem=3.145728e+08
		[[ " ${STUB_BIG_CALLS:-} " != *" $n "* ]] || mem=4.294967296e+09
		body="$(sed -e "s/^process_resident_memory_bytes .*/process_resident_memory_bytes $mem/" \
			-e "s/^pilot_xds_pushes{type=\"eds\"} .*/pilot_xds_pushes{type=\"eds\"} $((n * 100))/" "$FX/pre_metrics.txt")"
		if [[ -n "$out" ]]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi
		exit 0
	fi
	body="$FX/pre_metrics.txt" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	# A short sleep: 002 waits 3 s for its port-forwards and --watch polls every 5 s; a
	# sweep's settles are the --settle given.
	printf '#!/bin/sh\nexec %s 0.05\n' "$(command -v sleep)" > "${BIN}/sleep"
	chmod +x "${BIN}/kubectl" "${BIN}/curl" "${BIN}/sleep"
	TSV="${RES}/controlplane-R1.tsv"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	# `kubectl top nodes` fails against the stub: one try, no backoff.
	export CAP_TOP_ATTEMPTS=1 CAP_TOP_BACKOFF_S=0
}

teardown() {
	local p
	[[ -s "${BATS_TEST_TMPDIR}/fake-pid" ]] || return 0
	p="$(<"${BATS_TEST_TMPDIR}/fake-pid")"
	if [[ "$p" =~ ^[0-9]+$ ]]; then kill -KILL "$p" 2>/dev/null || true; fi
}

# cp_window [args...]: one 002 window of ctx-a (or the --contexts given) into
# res/controlplane-R1.tsv; stderr in $stderr.
cp_window() {
	rm -f "$SEQ_N"
	PATH="${BIN}:${PATH}" run --separate-stderr "${CP}/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$RES" --run-id R1 "$@"
}

# col <name>: the TSV column's values, one line, space-separated.
col() {
	awk -F'\t' -v c="$1" '$1 == "timestamp" { for (i = 1; i <= NF; i++) if ($i == c) k = i; next }
		/^#/ { next } k { printf "%s%s", (n++ ? " " : ""), $k } END { print "" }' "$TSV"
}

# nr_lines [n]: the TSV's (first n) not-Ready and WINDOW_ROWS lines, in order, joined by " | ".
nr_lines() {
	grep -E '^# (ISTIOD_NOT_READY|WINDOW_ROWS)' "$TSV" | head -n "${1:-100}" \
		| awk '{ printf "%s%s", (NR > 1 ? " | " : ""), $0 } END { print "" }'
}

@test "002's istiod %-of-limit divides the usage of the pods it summed by their limit (a Pending replica counts in neither) and WINDOW_ROWS records <n>/<spec>; split phases use the baseline's Deployment read, or read it at the rows when it failed; a final's scrape skew is the spread of the baseline's completion stamps" {
	local sd="${BATS_TEST_TMPDIR}/state" k
	run cap_parse_istiod_used <<<$'istiod-a 1500m 1900Mi\nistiod-b 1500m 1900Mi'
	assert_output "cpu_m=3000 mem_mi=3800 pods=2"
	run cap_parse_istiod_used < /dev/null
	assert_output "cpu_m=unknown mem_mi=unknown pods=unknown"
	# Two pods Running of the three the Deployment wants.
	STUB_DEPLOY_REPLICAS=3 cp_window
	assert_success
	[[ "$stderr" == *"warning: context ctx-a: 2 istiod pod(s) Running, but its Deployment wants 3"*"(ctx-a=2/3)"* ]]
	[ "$(grep '^# WINDOW_ROWS=' "$TSV")" = "# WINDOW_ROWS=ctx-a=2/3" ]
	# Split phases whose baseline could not read the Deployment; four baseline scrapes
	# (2 contexts x 2 replicas) that started together and finished 3 s apart.
	mkdir -p "$sd"
	STUB_DEPLOY_FAIL=1 cp_window --contexts ctx-a,ctx-b --phase baseline --state-dir "$sd"
	assert_success
	for k in 0 1 2 3; do
		echo 1000 > "${sd}/baseline-${k}.ts"
		echo $((1000 + k * 3000)) > "${sd}/baseline-${k}.tsend"
	done
	cp_window --contexts ctx-a,ctx-b --phase final --state-dir "$sd"
	assert_success
	# Every row: 3800Mi of 2 x 2048Mi and 3000m of 2 x 2000m (over the Deployment's 3: 62
	# and 50).
	[ "$(col istiod_mem_pct_of_limit)" = "93 93 93 93 93 93" ]
	[ "$(col istiod_cpu_pct_of_limit)" = "75 75 75 75 75 75" ]
	[ "$(col scrape_skew_ms | cut -d' ' -f 3-)" = "9000 9000 9000 9000" ]
}

@test "002 ends a TSV's last line that lost its newline (a write cut short) before the window's lines, so its rows do not merge onto it" {
	local cut
	cp_window
	assert_success
	# The last row loses its last column and newline.
	cut="$(<"$TSV")"
	cut="${cut%$'\t'*}"
	printf '%s' "$cut" > "$TSV"
	cp_window
	assert_success
	[ "$(grep -c '^# WINDOW_ROWS=' "$TSV")" -eq 2 ]
	grep -qxF -- "$(tail -n 1 <<<"$cut")" "$TSV"
	# Two whole windows of two rows each, and the cut row: no merged line.
	[ "$(awk -F'\t' '$2 == "ctx-a" && NF == 66' "$TSV" | wc -l | tr -d ' ')" -eq 3 ]
	[ "$(awk -F'\t' '$2 == "ctx-a" && NF != 66' "$TSV" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "002 writes a window's Running istiod pods not Ready at its baseline (ISTIOD_NOT_READY) and at its end (ISTIOD_NOT_READY_AT_END) right before its WINDOW_ROWS line, in split phases and in one, and its .md lists them; 004 names those cells" {
	local sd="${BATS_TEST_TMPDIR}/state" md="${RES}/controlplane-R1.md" w
	mkdir -p "$sd"
	# Split phases: istiod-b not Ready at the baseline; at the end istiod-b is gone (not
	# named) and istiod-a is not Ready.
	STUB_READY_SEQ="True False" cp_window --phase baseline --state-dir "$sd"
	assert_success
	[[ "$stderr" == *"warning: context ctx-a: istiod pod(s) Running but not Ready: istiod-b ("* ]]
	# The pods the final scrapes keep their bare names.
	[ "$(cut -f 3 "${sd}/pods.tsv" | tr '\n' ' ')" = "istiod-a istiod-b " ]
	rm -f "$KLOG"
	STUB_PODS=istiod-a STUB_READY_SEQ=False cp_window --phase final --state-dir "$sd" --service-count 7
	assert_success
	[[ "$stderr" == *"warning: context ctx-a: istiod pod(s) not Ready at the window's end: istiod-a ("* ]]
	[ "$(nr_lines)" = "# ISTIOD_NOT_READY=ctx-a=istiod-b | # ISTIOD_NOT_READY_AT_END=ctx-a=istiod-a | # WINDOW_ROWS=ctx-a=2/2" ]
	[ "$(grep -A 1 '^# WINDOW_ROWS=' "$TSV" | tail -n 1 | cut -f 2)" = ctx-a ]
	# The end's one list read comes after the window's last scrape of /metrics.
	[ "$(grep -cF -- "$LIST" "$KLOG")" -eq 1 ]
	[ "$(grep -nF -- "$LIST" "$KLOG" | cut -d: -f 1)" -gt "$(grep -n '^curl .*/metrics' "$KLOG" | tail -n 1 | cut -d: -f 1)" ]
	# One phase: istiod-b has no Ready condition read (not Ready either), at both ends.
	STUB_READY_SEQ=True cp_window --service-count 9 --traffic-config vsdr
	assert_success
	[ "$(nr_lines | cut -d'|' -f 4-)" = " # ISTIOD_NOT_READY=ctx-a=istiod-b | # ISTIOD_NOT_READY_AT_END=ctx-a=istiod-b | # WINDOW_ROWS=ctx-a=2/2" ]
	# All Ready, or the end's list not read: no line (the latter says so).
	cp_window --service-count 8
	assert_success
	[[ "$stderr" != *"not Ready"* ]]
	STUB_READY_SEQ="True True|FAIL" cp_window --service-count 10
	assert_success
	[[ "$stderr" == *"warning: ctx-a: could not list Running istiod pods after the final scrape; cluster_connected_proxies=N/A, and no ISTIOD_NOT_READY_AT_END entry"* ]]
	[ "$(grep -c '^# ISTIOD_NOT_READY=' "$TSV")" -eq 2 ]
	[ "$(grep -c '^# ISTIOD_NOT_READY_AT_END=' "$TSV")" -eq 2 ]
	[ "$(grep -c '^# WINDOW_ROWS=' "$TSV")" -eq 4 ]
	# The .md names each such window by its cell (the window times masked).
	run sed -E -n 's/^- Window at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9:]{5} /- Window at <ts> /p' "$md"
	assert_output "$(cat <<'MD'
- Window at <ts> (mesh 1, svc 7, reps 3, ns 1, scoping none, traffic none): Running but not Ready at its baseline: istiod-b on ctx-a; not Ready at its end: istiod-a on ctx-a
- Window at <ts> (mesh 1, svc 9, reps 3, ns 1, scoping none, traffic vsdr): Running but not Ready at its baseline: istiod-b on ctx-a; not Ready at its end: istiod-b on ctx-a
MD
)"
	# 004 over 002's own TSV: each kind names its cells' pods, and the cells are done.
	run --separate-stderr "${CP}/004-report-results.sh" --results-dir "$RES" --format json
	assert_success
	w="$(jq -r '.metadata.data_warnings[] | select(test("Running but not Ready at the window.s baseline"))' <<<"$output")"
	[[ "$w" == "2 cell(s) "*"svcs=7 "*"(istiod-b on ctx-a); "*"svcs=9 "*"(istiod-b on ctx-a). "* ]]
	w="$(jq -r '.metadata.data_warnings[] | select(test("not Ready at the window.s end"))' <<<"$output")"
	[[ "$w" == "2 cell(s) "*"svcs=7 "*"(istiod-a on ctx-a); "*"svcs=9 "*"(istiod-b on ctx-a). "* ]]
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" != *INCOMPLETE* ]]
}

@test "002 --watch: each window reads its own end (the AT_END line where a pod is not Ready then; the baseline line only in the first window); a failed final scrape is an N/A row, never the last window's gauges; peaks are per window" {
	local pid i n=0
	# One pod. Body calls per window: baseline, one peak poll, final. Call 2 (window 1's
	# poll) reads 4 GiB; call 6 (window 2's final) fails. The baseline read (not Ready),
	# then window 1's end (not Ready), window 2's (Ready), window 3's and after (not Ready).
	export STUB_PODS=istiod-abc-x1 STUB_DEPLOY_REPLICAS=1 STUB_READY_SEQ="False|False|True|False"
	export STUB_COUNT="${BATS_TEST_TMPDIR}/count" STUB_FAIL_CALLS=6 STUB_BIG_CALLS=2
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" "${CP}/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --output-dir "$RES" --run-id R1 --watch --interval 1 \
		> "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" 3>&- &
	pid=$!
	for ((i = 0; i < 600; i++)); do
		n="$(awk -F'\t' '!/^#/ && $1 != "timestamp"' "$TSV" 2>/dev/null | wc -l | tr -d ' ')"
		((${n:-0} >= 3)) && break
		sleep 0.1
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[ "${n:-0}" -ge 3 ]
	[ "$(nr_lines 6)" = "# ISTIOD_NOT_READY=ctx-a=istiod-abc-x1 | # ISTIOD_NOT_READY_AT_END=ctx-a=istiod-abc-x1 | # WINDOW_ROWS=ctx-a=1/1 | # WINDOW_ROWS=ctx-a=1/1 | # ISTIOD_NOT_READY_AT_END=ctx-a=istiod-abc-x1 | # WINDOW_ROWS=ctx-a=1/1" ]
	# context, istiod_mem_mi, istiod_restarted, xds_pushes_delta of the first three rows.
	run awk -F'\t' '$1 == "timestamp" { for (i = 1; i <= NF; i++) ix[$i] = i; next }
		!/^#/ && n++ < 3 { print $(ix["context"]), $(ix["istiod_mem_mi"]), $(ix["istiod_restarted"]), $(ix["xds_pushes_delta"]) }' "$TSV"
	assert_line --index 0 "ctx-a 4096 0 200"
	# Window 2: its final scrape failed. An older probe reused window 1's final body
	# (memory 4096, restarted 0) and read the counter's drop from 400 to 300 as a reset.
	assert_line --index 1 "ctx-a N/A unknown N/A"
	# Window 3: its own peak (300 Mi), not window 1's 4 GiB.
	assert_line --index 2 "ctx-a 300 0 200"
}

@test "002 takes the config_dump samples once per context in a window, not once per istiod replica: each replica's row shows the same samples, got of attempted" {
	local a b
	cp_window --contexts ci-a --config-dump-samples 1
	assert_success
	[ "$(col context)" = "ci-a ci-a" ]
	[ "$(grep -c ' exec sc-1 ' "$KLOG")" -eq 1 ]
	[ "$(col sidecar_config_bytes_samples)" = "1/1 1/1" ]
	read -r a b <<<"$(col sidecar_config_bytes_avg)"
	[[ "$a" =~ ^[1-9][0-9]*$ && "$b" == "$a" ]]
}

@test "a standalone 002 refuses a --mesh-size larger than its contexts before any read" {
	PATH="${BIN}:${PATH}" run --separate-stderr bash "${CP}/002-collect-resource-metrics.sh" \
		--contexts ci-a --mesh-size 2 --dry-run
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"--mesh-size 2 is larger than the 1 context(s) given (ci-a)"* ]]
	[ ! -s "$KLOG" ]
}

@test "redact-results maps the member names of the not-Ready lines and the .md's not-Ready list, a member only they name included, and keeps the pod names" {
	local d="${BATS_TEST_TMPDIR}/sweep-r1" c
	mkdir -p "$d"
	{
		printf '# RUN_ID=r1\n# ISTIO_VERSION_BY_CONTEXT=ci-a=v1.30.5,ci-b=v1.30.5\n'
		printf 'timestamp\tcontext\tmesh_size\tservice_count\tistiod_mem_mi\n'
		printf '# ISTIOD_NOT_READY=ci-a=istiod-6b7c9d-x2k4p,ci-c=istiod-6b7c9d-q8r2s\n'
		printf '# ISTIOD_NOT_READY_AT_END=ci-a=istiod-6b7c9d-x2k4p,ci-d=istiod-6b7c9d-t5v7w\n'
		printf '# WINDOW_ROWS=ci-a=1/2,ci-b=1/1\n'
		printf '2026-10-18T05:13:37+00:00\tci-a\t2\t5\t120\n'
		printf '2026-10-18T05:13:37+00:00\tci-b\t2\t5\t118\n'
	} > "${d}/controlplane-r1.tsv"
	printf -- '- Window at 2026-10-18T05:13:37+00:00 (mesh 2, svc 5, reps 3, ns 1, scoping none, traffic none): not Ready at its end: istiod-6b7c9d-t5v7w on ci-d\n' > "${d}/controlplane-r1.md"
	export TMPDIR="$BATS_TEST_TMPDIR"
	run --separate-stderr "${ROOT}/tests/lib/redact-results.sh" --out "${BATS_TEST_TMPDIR}/out" "$d"
	assert_success
	c="${BATS_TEST_TMPDIR}/out/sweep-r1/controlplane-r1.tsv"
	[ "$(grep '^# ISTIOD_NOT_READY=' "$c")" = "# ISTIOD_NOT_READY=<mesh-a-ctx>=istiod-6b7c9d-x2k4p,<mesh-c-ctx>=istiod-6b7c9d-q8r2s" ]
	[ "$(grep '^# ISTIOD_NOT_READY_AT_END=' "$c")" = "# ISTIOD_NOT_READY_AT_END=<mesh-a-ctx>=istiod-6b7c9d-x2k4p,<mesh-d-ctx>=istiod-6b7c9d-t5v7w" ]
	[ "$(cat "${BATS_TEST_TMPDIR}/out/sweep-r1/controlplane-r1.md")" = "- Window at 2026-10-18T05:13:37+00:00 (mesh 2, svc 5, reps 3, ns 1, scoping none, traffic none): not Ready at its end: istiod-6b7c9d-t5v7w on <mesh-d-ctx>" ]
	run grep -rcE '(^|[^A-Za-z0-9_<])ci-[abcd]([^A-Za-z0-9_]|$)' "${BATS_TEST_TMPDIR}/out/sweep-r1"
	refute_output --regexp ':[1-9]'
}

# ---------------------------------------------------------------------------
# The sweep (003)

# sweep_stub: the sweep's kubectl (files in CUT_DIR, per context where named <file>.<ctx>;
# each call is logged to KLOG): the Istio CR reads answer as fake-istio-cr.sh; `config
# get-contexts -o name` lists kube-contexts (no file: it fails); a member's Istio remote
# secrets are remote.<ctx> (no file: the read fails); its controlplane-test namespaces are
# one while ns-left.<ctx> exists (their list fails while ns-uncountable exists), and their
# delete removes it unless ns-stuck exists (then the delete fails). Anything else fails, as
# against an empty kubeconfig (a real 002's cells fail as PROBE_FAILED).
sweep_stub() {
	export CUT_DIR="$BATS_TEST_TMPDIR"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$CUT_DIR"
printf '%s\n' "$*" >> "$KLOG"
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
}

# cp_row <ts> <ctx> <mesh> <svcs> <mem_mi>: a valid measurement row (66 columns, window
# kind deploy, 3 replicas, 1 namespace, scoping none, traffic none).
cp_row() {
	printf '%s\t%s\t%s\t%s\t3\t1\tnone\t%s\t50\t90\t5\t9\t100\t3.33\t10\t60\t10\t10\t10\t50\t1.67\t20\t2048\t1048576\t1048576\t1048576\t3/3\t30.0\t100\t30\t0\t100\t200\t250\t10\t15\t40\t50\t120\t250\t22\t22\tOK\tnone\t0\t0\t1.00\t0.50\t30\t51200\t20480\t0\tpods\t4\t0\tnone\tdeploy\t%s\t12.5\t45\t120\t200\t3\t210\t180\t0\n' \
		"$1" "$2" "$3" "$4" "$5" "$(($4 * 2))"
}

# sweep_tree <live|cut|noend|done>: a copy of the repo (symlinks) whose 004 does nothing
# (the end-of-sweep reports are 004's tests'), with the stub kubectl; sets SWEEP.
#   live   the real 001 and 002 (their cells fail as PROBE_FAILED against the stub)
#   cut    001 succeeds; 002 --phase final appends a window cut inside its row's
#          next-to-last column (no newline: a full disk), then fails, or with FAKE_TERM=1
#          sends the sweep SIGTERM and waits to be stopped
#   noend  cut, and tsv_end_line always fails (a line that cannot be ended)
#   done   001 succeeds; 002 --phase final appends a measurement row for the first
#          FAKE_ROWS members of its cell (default: all of its mesh size), then sends the
#          sweep SIGTERM and waits: the sweep ends after the cell's rows, before its end
sweep_tree() {
	local t="${BATS_TEST_TMPDIR}/tree" f
	sweep_stub
	mkdir -p "${t}/tests/controlplane" "${t}/tests/lib"
	ln -s "${ROOT}/config" "${t}/config"
	ln -s "${ROOT}/charts" "${t}/charts"
	for f in "${ROOT}/tests/lib"/*; do ln -s "$f" "${t}/tests/lib/${f##*/}"; done
	if [[ "$1" == noend ]]; then
		rm "${t}/tests/lib/common.sh"
		printf 'source "%s/tests/lib/common.sh"\ntsv_end_line() { return 1; }\n' "$ROOT" > "${t}/tests/lib/common.sh"
	fi
	for f in "$CP"/*; do
		case "${f##*/}" in 004-*) ;; 001-* | 002-*) [[ "$1" != live ]] || ln -s "$f" "${t}/tests/controlplane/${f##*/}" ;; *) ln -s "$f" "${t}/tests/controlplane/${f##*/}" ;; esac
	done
	printf '#!/bin/sh\nexit 0\n' > "${t}/tests/controlplane/004-report-results.sh"
	chmod +x "${t}/tests/controlplane/004-report-results.sh"
	SWEEP="${t}/tests/controlplane/003-run-sweep.sh"
	[[ "$1" != live ]] || return 0
	printf '#!/bin/sh\nexit 0\n' > "${t}/tests/controlplane/001-setup-controlplane-test.sh"
	{
		echo '#!/usr/bin/env bash'
		echo 'set -euo pipefail'
		printf 'real_sleep=%q\nmode=%q\n' "$(command -v sleep)" "$1"
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
if [[ "$mode" == done ]]; then
	rows=""
	for ((i = 0; i < ${FAKE_ROWS:-$ms}; i++)); do rows+="$(cp_row "$(date -u -Iseconds)" "${c[i]}" "$ms" "$sc" 1000)"$'\n'; done
	printf '%s' "$rows" >> "${out}/controlplane-${rid}.tsv"
else
	row="$(cp_row "$(date -u -Iseconds)" "${c[0]}" "$ms" "$sc" 1000)"
	printf '# WINDOW_ROWS=%s=1\n%s' "${c[0]}" "${row%80$'\t'0}" >> "${out}/controlplane-${rid}.tsv"
	[[ -n "${FAKE_TERM:-}" ]] || exit 1
fi
echo "$$" > "${CUT_DIR}/fake-pid"
kill -TERM "$PPID"
"$real_sleep" 30 &
wait
FAKE
	} > "${t}/tests/controlplane/002-collect-resource-metrics.sh"
	chmod +x "${t}/tests/controlplane/001-setup-controlplane-test.sh" "${t}/tests/controlplane/002-collect-resource-metrics.sh"
}

# cp_sweep <args...>: $SWEEP with the stub kubectl, its results under res/; output and
# stderr together, in order. cp_sweep2: stderr in $stderr. Both set D (the one sweep dir)
# and TSV (its controlplane TSV; empty when none).
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="$RES" run bash "$SWEEP" "$@"
	sweep_dirs
}
cp_sweep2() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="$RES" run --separate-stderr bash "$SWEEP" "$@"
	sweep_dirs
}
sweep_dirs() {
	D="$(find "$RES" -mindepth 1 -maxdepth 1 -name 'sweep-*' -type d 2>/dev/null || true)"
	TSV=""
	[[ -z "$D" ]] || TSV="$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
}

@test "a window cut short without its newline: the cell's PROBE_FAILED row starts a line of its own, and 003's count and 004 read the cell as failed, not measured" {
	sweep_tree cut
	cp_sweep2 --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	# The cut row keeps its 65 columns; the status row has its 66 on a line of its own.
	[ "$(awk -F'\t' '$2 == "ci-a" { print NF }' "$TSV")" = 65 ]
	[ "$(awk -F'\t' '$2 == "PROBE_FAILED" && $1 ~ /^[0-9]{4}-/ { print NF }' "$TSV")" = 66 ]
	grep -qx 'FAILED=1' "${D}/sweep-outcome.txt"
	grep -q '^FAILED_BY=.*PROBE_FAILED' "${D}/sweep-outcome.txt"
	# 004: the cell's one row is its status row (no valid sample), and the verdict is not PASS.
	run --separate-stderr bash "${CP}/004-report-results.sh" --results-dir "$D" --format json
	assert_success
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" != PASS ]
	[ "$(jq -c '[.results[] | [.n_total, .n_valid]]' <<<"$output")" = '[[1,0]]' ]
}

@test "a cut last line that cannot be ended gets no status row onto it: the sweep stops with that reason; in the EXIT trap it skips the INTERRUPTED row with a warning, and the record is still written" {
	sweep_tree noend
	cp_sweep2 --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 1 ]
	grep -q '^STOP_REASON=could not end the last line of <sweep dir>/controlplane-.*\.tsv' "${D}/sweep-outcome.txt"
	[ "$(awk -F'\t' '$2 == "PROBE_FAILED"' "$TSV" | wc -l | tr -d ' ')" -eq 0 ]
	# Interrupted inside the cell.
	rm -rf "$RES"
	FAKE_TERM=1 cp_sweep2 --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 143 ]
	[[ "$stderr" == *"warning: could not write the INTERRUPTED row of the cell in progress"* ]]
	grep -qx 'STATUS=interrupted' "${D}/sweep-outcome.txt"
	grep -qx 'SIGNAL=SIGTERM' "${D}/sweep-outcome.txt"
	[ "$(awk -F'\t' '$2 == "INTERRUPTED"' "$TSV" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "a sweep that ends after its cell's 002 wrote every member's rows writes no INTERRUPTED row (the cell is done); one that wrote fewer writes one naming the cell" {
	sweep_tree done
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	[ "$(awk -F'\t' '!/^#/ && $1 != "timestamp"' "$TSV" | wc -l | tr -d ' ')" -eq 2 ]
	run ! grep -q INTERRUPTED "$TSV"
	grep -qx 'STATUS=interrupted' "${D}/sweep-outcome.txt"
	# Rows of one member of two: the cell is cut short, INTERRUPTED.
	rm -rf "$RES"
	FAKE_ROWS=1 cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 143 ]
	# The row names the cell (mesh, Services, replicas, namespaces), not the trap's own values.
	[ "$(awk -F'\t' -v OFS=/ '$2 == "INTERRUPTED" { print $3, $4, $5, $6 }' "$TSV")" = 2/5/3/1 ]
}

@test "the leftover check counts on the measured members and the mesh members their remote secrets name (warning of one without a kube context), deletes the measured members' with a sized --timeout, records it, and settles before the first cell; with none left, none is recorded and nothing settles before it" {
	local o a b c
	sweep_tree live
	# ci-a's remote secrets name ci-c (a kube context) and ci-d (none); ci-a holds a leftover.
	printf 'ci-a\nci-c\n' > "${CUT_DIR}/kube-contexts"
	printf '%s\n' '{"items":[{"metadata":{"name":"istio-remote-secret-ci-c","labels":{"istio/multiCluster":"true"},"annotations":{"networking.istio.io/cluster":"ci-c"}}},{"metadata":{"name":"istio-remote-secret-ci-d","labels":{"istio/multiCluster":"true"}}}]}' > "${CUT_DIR}/remote.ci-a"
	: > "${CUT_DIR}/ns-left.ci-a"
	CONTROLPLANE_SETTLE_SEC=1 CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=7 \
		cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$output" == *"Leftover check: also counts on mesh member(s) ci-c "* ]]
	[[ "$output" == *"warn: mesh member(s) ci-d "*"have no kube context of that name"* ]]
	[[ "$output" == *"left on the members (ci-a: 1)"*"Its --timeout is 7 s"* ]]
	grep -q -- '--context=ci-a .*delete namespace -l app.kubernetes.io/instance=controlplane-test' "$KLOG"
	[ "$(grep -c -- '--context=ci-c .*delete namespace' "$KLOG")" = 0 ]
	[ ! -e "${CUT_DIR}/ns-left.ci-a" ]
	# The settle comes after the deletion and before the first cell's baseline (the order;
	# its length is the configured --settle, PL44).
	o="$output"
	a="${o%%so 005-cleanup.sh deletes them now*}"
	b="${o%%--- Post-cleanup settle (1s) ---*}"
	c="${o%%--- Baseline metrics scrape (phase 1/3) ---*}"
	[ "${#a}" -lt "${#b}" ]
	[ "${#b}" -lt "${#c}" ]
	grep -qx '# LEFTOVER_TEST_NAMESPACES=ci-a=1 (deleted by 005-cleanup.sh before the first cell)' "$TSV"
	grep -q '^NOTE=the leftover check found controlplane-test namespaces an earlier run left (ci-a: 1)' "${D}/sweep-outcome.txt"
	# None left: none recorded, and the first settle comes after the first cell's baseline.
	rm -rf "$RES"
	CONTROLPLANE_SETTLE_SEC=1 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	o="$output"
	b="${o%%--- Post-cleanup settle*}"
	c="${o%%--- Baseline metrics scrape (phase 1/3) ---*}"
	[ "${#c}" -lt "${#b}" ]
	grep -qx '# LEFTOVER_TEST_NAMESPACES=none' "$TSV"
}

@test "leftovers that stay stop the sweep before its start (no row, no record): on a mesh member outside --contexts, before any deletion, with the 005 command for it; or still there after 005, with the sized --timeout to give it; a member whose namespaces cannot be counted only warns" {
	sweep_tree live
	printf 'ci-a\nci-c\n' > "${CUT_DIR}/kube-contexts"
	printf '%s\n' '{"items":[{"metadata":{"name":"istio-remote-secret-ci-c","labels":{"istio/multiCluster":"true"},"annotations":{"networking.istio.io/cluster":"ci-c"}}}]}' > "${CUT_DIR}/remote.ci-a"
	: > "${CUT_DIR}/ns-left.ci-a"
	: > "${CUT_DIR}/ns-left.ci-c"
	CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=7 \
		cp_sweep2 --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"on mesh members outside --contexts (ci-c: 1;"*"005-cleanup.sh --contexts ci-c --timeout 7 "* ]]
	[ "$(grep -c 'delete namespace' "$KLOG")" = 0 ]
	[ -e "${CUT_DIR}/ns-left.ci-a" ]
	[ -e "${CUT_DIR}/ns-left.ci-c" ]
	[ -z "$(find "$D" -maxdepth 1 \( -name 'controlplane-*.tsv' -o -name sweep-outcome.txt \))" ]
	# Namespaces 005 cannot delete.
	rm -rf "$RES"
	rm -f "${CUT_DIR}"/ns-left.* "${CUT_DIR}/kube-contexts" "${CUT_DIR}/remote.ci-a"
	: > "${CUT_DIR}/ns-left.ci-b"
	: > "${CUT_DIR}/ns-stuck"
	CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=1 CONTROLPLANE_NS_DELETE_SEC_PER_NS=3 \
		cp_sweep2 --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"still on the members after 005-cleanup.sh (ci-b: 1:"*"005-cleanup.sh --contexts ci-b "*"--timeout 3 "* ]]
	[[ "$stderr" != *"Sweep [1/1]"* && "$output" != *"Sweep [1/1]"* ]]
	[ -z "$(find "$D" -maxdepth 1 \( -name 'controlplane-*.tsv' -o -name sweep-outcome.txt \))" ]
	# A member whose namespaces cannot be counted (as when unreachable): a warning, no cleanup.
	rm -rf "$RES"
	rm -f "${CUT_DIR}"/ns-left.* "${CUT_DIR}/ns-stuck"
	: > "${CUT_DIR}/ns-uncountable"
	cp_sweep2 --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"warn: could not count the controlplane-test namespaces on ci-a"* ]]
	[[ "$stderr" != *"005-cleanup.sh deletes them now"* ]]
}
