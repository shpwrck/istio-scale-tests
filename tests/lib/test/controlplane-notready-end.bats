#!/usr/bin/env bats
# An istiod pod that is not Ready at a window's end, through the real 002 and
# redact-results.sh (PL33; no cluster: kubectl and curl are stubs, as in
# controlplane-notready.bats): the pod-set read after the window's final scrape also reads
# the pods' Ready condition, in every phase and in every --watch window, and 002 writes a
# "# ISTIOD_NOT_READY_AT_END=" line after the baseline's "# ISTIOD_NOT_READY=" line and
# before WINDOW_ROWS; its own controlplane-<RUN_ID>.md lists each window's not-Ready pods;
# redaction maps the member names in the new line. Names are placeholders.

bats_require_minimum_version 1.5.0
load test_helper

CP="${ROOT}/tests/controlplane"
FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
LIST='{.metadata.name}={.status.conditions'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN" "$RES"
	export FX LIST KLOG="${BATS_TEST_TMPDIR}/klog" SEQ_N="${BATS_TEST_TMPDIR}/seq-n"
	# Each member runs the pods STUB_PODS names (istiod-a istiod-b unless set), Running, of
	# a Deployment that wants two. The n-th pod list read of a 002 run (resolve_pods' at a
	# baseline, the pod-set read after each final scrape; SEQ_N counts them) gives them the
	# n-th "|"-separated entry of STUB_READY_SEQ as Ready conditions (the last entry for
	# every read after it; "True True" unless set); STUB_LIST_FAIL fails it. Anything else fails, as against an empty
	# kubeconfig. Every call is logged to KLOG, and each scrape of /metrics as "curl <url>".
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KLOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running -o jsonpath="*"$LIST"*)
	[[ -z "${STUB_LIST_FAIL:-}" ]] || exit 1
	n="$(cat "$SEQ_N" 2>/dev/null || echo 0)"
	echo $((n + 1)) > "$SEQ_N"
	IFS='|' read -r -a seq <<<"${STUB_READY_SEQ:-True True}"
	((n < ${#seq[@]})) || n=$((${#seq[@]} - 1))
	read -r -a rd <<<"${seq[n]}"
	i=0
	for p in ${STUB_PODS:-istiod-a istiod-b}; do printf '%s=%s ' "$p" "${rd[i]-}"; i=$((i + 1)); done ;;
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
if [[ -n "$out" ]]; then cp "$body" "$out"; else echo "curl $url" >> "$KLOG"; cat "$body"; fi
STUB
	# A short sleep (002 waits 3 s for its port-forwards; --watch polls every 5 s).
	printf '#!/bin/sh\nexec %s 0.05\n' "$(command -v sleep)" > "${BIN}/sleep"
	chmod +x "${BIN}/kubectl" "${BIN}/curl" "${BIN}/sleep"
	TSV="${RES}/controlplane-R1.tsv"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
}

# cp_window [args...]: one 002 window of ctx-a into res/controlplane-R1.tsv.
cp_window() {
	rm -f "$SEQ_N"
	PATH="${BIN}:${PATH}" run --separate-stderr "${CP}/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$RES" --run-id R1 "$@"
}

# nr_lines [n]: the TSV's (first n) not-Ready and WINDOW_ROWS lines, in order, joined by " | ".
nr_lines() {
	grep -E '^# (ISTIOD_NOT_READY|WINDOW_ROWS)' "$TSV" | head -n "${1:-100}" \
		| awk '{ printf "%s%s", (NR > 1 ? " | " : ""), $0 } END { print "" }'
}

@test "--phase final reads the Ready condition in its pod-set read after the final scrape: an ISTIOD_NOT_READY_AT_END line after the baseline's, right before WINDOW_ROWS; a pod gone is not listed; all Ready or an unread list, no line" {
	local sd="${BATS_TEST_TMPDIR}/state" end_warn
	end_warn="warning: context ctx-a: istiod pod(s) not Ready at the window's end: istiod-a, istiod-b (a readiness probe failing under load, or a replica shutting down?): the window's ISTIOD_NOT_READY_AT_END line tells the reports so"
	mkdir -p "$sd"
	STUB_READY_SEQ="True False" cp_window --phase baseline --state-dir "$sd"
	assert_success
	[[ "$stderr" != *"window's end"* ]]
	rm -f "$KLOG"
	STUB_READY_SEQ="False False" cp_window --phase final --state-dir "$sd"
	assert_success
	[[ "$stderr" == *"$end_warn"* ]] || { echo "$stderr"; false; }
	[ "$(nr_lines)" = "# ISTIOD_NOT_READY=ctx-a=istiod-b | # ISTIOD_NOT_READY_AT_END=ctx-a=istiod-a,ctx-a=istiod-b | # WINDOW_ROWS=ctx-a=2/2" ]
	# The rows follow the WINDOW_ROWS line.
	[ "$(grep -A 1 '^# WINDOW_ROWS=' "$TSV" | tail -n 1 | cut -f 2)" = ctx-a ]
	# One list read, after the window's last scrape of /metrics: its end.
	[ "$(grep -cF -- "$LIST" "$KLOG")" -eq 1 ]
	[ "$(grep -nF -- "$LIST" "$KLOG" | cut -d: -f 1)" -gt "$(grep -n '^curl .*/metrics' "$KLOG" | tail -n 1 | cut -d: -f 1)" ]
	# istiod-b is gone at the end: only istiod-a is named.
	cp_window --phase baseline --state-dir "$sd"
	assert_success
	STUB_PODS=istiod-a STUB_READY_SEQ=False cp_window --phase final --state-dir "$sd"
	assert_success
	[ "$(grep '^# ISTIOD_NOT_READY_AT_END=' "$TSV" | tail -n 1)" = "# ISTIOD_NOT_READY_AT_END=ctx-a=istiod-a" ]
	[[ "$stderr" == *"not Ready at the window's end: istiod-a ("* ]]
	# All Ready at the end, or the list not read: no line (the latter says so).
	for v in "" 1; do
		cp_window --phase baseline --state-dir "$sd"
		assert_success
		STUB_LIST_FAIL="$v" cp_window --phase final --state-dir "$sd"
		assert_success
		[[ "$stderr" != *"window's end"* ]]
	done
	[[ "$stderr" == *"warning: ctx-a: could not list Running istiod pods after the final scrape; cluster_connected_proxies=N/A, and no ISTIOD_NOT_READY_AT_END entry (their readiness was not read)"* ]]
	[ "$(grep -c '^# ISTIOD_NOT_READY_AT_END=' "$TSV")" -eq 2 ]
	[ "$(grep -c '^# WINDOW_ROWS=' "$TSV")" -eq 4 ]
}

@test "a combined window and every --watch window read their end: the AT_END line in each window that has a not-Ready pod then; the baseline line only in the first --watch window" {
	local pid i n=0
	# Combined: Ready at the baseline, istiod-b not Ready at the end.
	STUB_READY_SEQ="True True|True False" cp_window
	assert_success
	[ "$(nr_lines)" = "# ISTIOD_NOT_READY_AT_END=ctx-a=istiod-b | # WINDOW_ROWS=ctx-a=2/2" ]
	[[ "$stderr" == *"not Ready at the window's end: istiod-b ("* ]]
	[[ "$stderr" != *"Running but not Ready"* ]]
	# --watch: the baseline read (istiod-a not Ready), then window 1's end (istiod-b),
	# window 2's (all Ready) and window 3's and after (both).
	rm -f "$TSV" "$SEQ_N"
	PATH="${BIN}:${PATH}" STUB_READY_SEQ="False True|True False|True True|False False" \
		"${CP}/002-collect-resource-metrics.sh" --contexts ctx-a --config-dump-samples 0 \
		--output-dir "$RES" --run-id R1 --watch --interval 1 \
		> "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" 3>&- &
	pid=$!
	for ((i = 0; i < 600; i++)); do
		n="$(grep -c '^# WINDOW_ROWS=' "$TSV" 2>/dev/null || true)"
		((${n:-0} >= 3)) && break
		sleep 0.1
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[ "${n:-0}" -ge 3 ]
	[ "$(nr_lines 6)" = "# ISTIOD_NOT_READY=ctx-a=istiod-a | # ISTIOD_NOT_READY_AT_END=ctx-a=istiod-b | # WINDOW_ROWS=ctx-a=2/2 | # WINDOW_ROWS=ctx-a=2/2 | # ISTIOD_NOT_READY_AT_END=ctx-a=istiod-a,ctx-a=istiod-b | # WINDOW_ROWS=ctx-a=2/2" ]
	# Each window's lines are written together, right before its WINDOW_ROWS line.
	[ "$(grep -B 1 '^# WINDOW_ROWS=' "$TSV" | grep -c '^# ISTIOD_NOT_READY_AT_END=')" -ge 2 ]
}

@test "002's controlplane-<RUN_ID>.md lists each window's not-Ready istiod pods with the table's cell labels; a TSV without the lines has no such section" {
	local sd="${BATS_TEST_TMPDIR}/state" md="${RES}/controlplane-R1.md"
	mkdir -p "$sd"
	STUB_READY_SEQ="True False" cp_window --phase baseline --state-dir "$sd"
	assert_success
	STUB_READY_SEQ="False True" cp_window --phase final --state-dir "$sd" --service-count 7
	assert_success
	# An all-Ready window, then one not Ready at its end only.
	cp_window --service-count 8
	assert_success
	STUB_READY_SEQ="True True|True False" cp_window --service-count 9 --traffic-config vsdr
	assert_success
	# The section, between the table and the raw data (the window times masked).
	[ "$(grep -E '^## ' "$md" | paste -sd ',' -)" = "## Summary,## Istiod pods not Ready,## Raw Data" ]
	run sed -E -n '/^## Istiod pods not Ready$/,/^## Raw Data$/{ s/^- Window at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9:]{5} /- Window at <ts> /; p; }' "$md"
	assert_output "$(cat <<'MD'
## Istiod pods not Ready

A pod that is not Ready takes no new proxy connection, and one shutting down also drops its own as it exits (their reconnects to the other replicas add to those replicas' pushes and convergence), so its row's Proxies can read below the other replicas'.

- Window at <ts> (mesh 1, svc 7, reps 3, ns 1, scoping none, traffic none): Running but not Ready at its baseline: istiod-b on ctx-a; not Ready at its end: istiod-a on ctx-a
- Window at <ts> (mesh 1, svc 9, reps 3, ns 1, scoping none, traffic vsdr): not Ready at its end: istiod-b on ctx-a

## Raw Data
MD
)"
	# A run whose windows had every pod Ready.
	cp_window --run-id R2
	assert_success
	run ! grep -q 'not Ready' "${RES}/controlplane-R2.md"
	grep -qx '## Raw Data' "${RES}/controlplane-R2.md"
}

@test "redact-results maps the member names of an ISTIOD_NOT_READY_AT_END line, a member it alone names included, and keeps the pod names" {
	local d="${BATS_TEST_TMPDIR}/sweep-r1" c
	mkdir -p "$d"
	{
		printf '# RUN_ID=r1\n# ISTIO_VERSION_BY_CONTEXT=ci-a=v1.30.5,ci-b=v1.30.5\n'
		printf 'timestamp\tcontext\tmesh_size\tservice_count\tistiod_mem_mi\n'
		printf '# ISTIOD_NOT_READY=ci-a=istiod-6b7c9d-x2k4p\n'
		printf '# ISTIOD_NOT_READY_AT_END=ci-a=istiod-6b7c9d-x2k4p,ci-d=istiod-6b7c9d-t5v7w\n'
		printf '# WINDOW_ROWS=ci-a=1/2,ci-b=1/1\n'
		printf '2026-10-18T05:13:37+00:00\tci-a\t2\t5\t120\n'
		printf '2026-10-18T05:13:37+00:00\tci-b\t2\t5\t118\n'
	} > "${d}/controlplane-r1.tsv"
	printf -- '- Window at 2026-10-18T05:13:37+00:00 (mesh 2, svc 5, reps 3, ns 1, scoping none, traffic none): not Ready at its end: istiod-6b7c9d-t5v7w on ci-d\n' > "${d}/controlplane-r1.md"
	export TMPDIR="$BATS_TEST_TMPDIR"
	run --separate-stderr "${ROOT}/tests/lib/redact-results.sh" --out "${BATS_TEST_TMPDIR}/out" "$d"
	assert_success
	[[ "$stderr" == *"<mesh-c-ctx>     ci-d"* ]] || { echo "$stderr"; false; }
	c="${BATS_TEST_TMPDIR}/out/sweep-r1/controlplane-r1.tsv"
	[ "$(grep '^# ISTIOD_NOT_READY_AT_END=' "$c")" = "# ISTIOD_NOT_READY_AT_END=<mesh-a-ctx>=istiod-6b7c9d-x2k4p,<mesh-c-ctx>=istiod-6b7c9d-t5v7w" ]
	[ "$(cat "${BATS_TEST_TMPDIR}/out/sweep-r1/controlplane-r1.md")" = "- Window at 2026-10-18T05:13:37+00:00 (mesh 2, svc 5, reps 3, ns 1, scoping none, traffic none): not Ready at its end: istiod-6b7c9d-t5v7w on <mesh-c-ctx>" ]
	run grep -rcE '(^|[^A-Za-z0-9_<])ci-[abd]([^A-Za-z0-9_]|$)' "${BATS_TEST_TMPDIR}/out/sweep-r1"
	refute_output --regexp ':[1-9]'
}
