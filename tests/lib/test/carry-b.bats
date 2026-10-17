#!/usr/bin/env bats
# Carry-over pass B of PR #107, each item through its real entrypoint where one reaches
# it (PL33): B1 the active revisions and proxy versions in four more reports, B2 a P1 kept
# when only the remotes failed, B3 the remote EDS poller that never scraped, B4 the
# overflowed P1 iterations in tuning 004, B5 controlplane 002 watch-mode windows, B6 the
# fork-free size check and run-key read (same results), B7 tests/lib/redact-results.sh,
# B8 a member listed twice (or a remote equal to the source) refused before any cluster
# call, B9 the keyed-array lint. Names are placeholders (ci-a, ctx-a), addresses come
# from the documentation ranges (192.0.2.0/24, 2001:db8::/32), hosts end in .example.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/timestamp.sh"
source "${ROOT}/tests/lib/metrics.sh"
source "${ROOT}/tests/lib/fanout.sh"
source "${ROOT}/tests/lib/config.sh"

FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
REDACT="${ROOT}/tests/lib/redact-results.sh"
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'
CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CD_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	KC="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$KC"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _stub_bin: kubectl, oc and helm that log every call, and a curl that serves /metrics
# from STUB_PRE_BODY before the probe's change (STUB_MARK) and STUB_POST_BODY after.
# STUB_COUNT switches /metrics to a numbered body per call (B5); STUB_EDS_FAIL fails the
# churn EDS poller's scrapes (B3).
_stub_bin() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark" FX
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" fortio load "*" -json - "*) : > "$STUB_MARK"; cat "$FX/../fortio_ok.json" ;;
*" get pod -l app=fortio-client "*) printf 'fortio-client-0' ;;
*" exec "*) cat "$FX/../fortio_ok.json" ;;
*" scale "*" --replicas=1 "*) : ;;
*" scale "*) : > "$STUB_MARK" ;;
*" label pod/"*"=true "*) : > "$STUB_MARK" ;;
*" label pod/"*) : ;;
*" wait pod/"*) : ;;
*" get pods -l app=propagation-canary "*) printf 'canary-backer-0\n' ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1\n' ;;
*" -n istio-system get pods -l app=istiod -o json "*) cat "$FX/pods_oom.json" ;;
*" get events "* | *" get deploy,rs "*) cat "$FX/empty_list.json" ;;
*" get node "*) cat "$FX/node_ready.json" ;;
*" logs "*) echo "istiod log line" ;;
*" -o json "*) cat "$FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	printf '#!/usr/bin/env bash\nprintf "oc %%s\\n" "$*" >> "$STUB_LOG"\nexit 1\n' > "${BIN}/oc"
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
if [[ -n "${STUB_EDS_FAIL:-}" && "$out" == */eds-poll-* ]]; then exit 7; fi
case "$url" in
*/metrics)
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
	body="$STUB_PRE_BODY"; [[ -f "$STUB_MARK" ]] && body="$STUB_POST_BODY" ;;
*/clusters) body="$FX/../fortio_ok.json" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/oc" "${BIN}/curl"
	export STUB_PRE_BODY="${FX}/pre_metrics.txt" STUB_POST_BODY="${FX}/pre_metrics.txt"
}

# --- B8: a member listed twice, or a remote equal to the source ---------------

# _refuses <suite/script> <stderr fragment> <args...>: --dry-run with an empty kubeconfig
# exits non-zero with the fragment on stderr, before any kubectl or oc call.
_refuses() {
	local s="$1" want="$2"
	shift 2
	: > "$STUB_LOG"
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/${s}.sh" --dry-run "$@"
	if [[ "$status" -eq 0 || "$stderr" != *"$want"* ]]; then
		echo "${s} $*: exit ${status}, stderr: ${stderr}" >&2
		return 1
	fi
	if [[ -s "$STUB_LOG" ]]; then
		echo "${s}: a cluster call before the refusal: $(cat "$STUB_LOG")" >&2
		return 1
	fi
}

@test "B8: every --contexts entrypoint refuses a member listed twice under --dry-run, naming it and the flag" {
	_stub_bin
	local s extra
	for s in churn-dataplane/004-run-sweep churn-dataplane/006-cleanup churn/001-setup-churn-test churn/003-run-sweep \
		churn/005-cleanup controlplane/001-setup-controlplane-test controlplane/002-collect-resource-metrics \
		controlplane/003-run-sweep controlplane/005-cleanup dataplane/003-run-sweep dataplane/005-cleanup \
		propagation/001-setup-propagation-test propagation/004-collect-pilot-metrics propagation/006-run-sweep \
		propagation/007-cleanup; do
		_refuses "$s" "--contexts lists ci-a twice (ci-a,ci-b,ci-a): list each mesh member once" --contexts ci-a,ci-b,ci-a
	done
	_refuses gateway-api/001-run-ingress-check "--contexts (or SETUP_CONTEXTS) lists ci-a twice" \
		--contexts ci-a,ci-b,ci-a --workload-context ci-b
	_refuses tuning/003-run-tuning-sweep "--contexts (or SETUP_CONTEXTS) lists ci-a twice" \
		--suite churn-dataplane --contexts ci-a,ci-b,ci-a --gitops-context ci-hub
	_refuses tuning/005-cleanup "--contexts (or SETUP_CONTEXTS) lists ci-a twice" --contexts ci-a,ci-b,ci-a
	_refuses tuning/001-apply-profile "--contexts (or SETUP_CONTEXTS) lists ci-a twice (ci-a,ci-a)" \
		--profile 01-push-throttling --contexts ci-a,ci-a
	mkdir -p "${BATS_TEST_TMPDIR}/state"
	_refuses tuning/002-revert-profile "lists ci-a twice (ci-a,ci-a)" --state-dir "${BATS_TEST_TMPDIR}/state" --contexts ci-a,ci-a
	_refuses controlplane/003-run-sweep \
		"--mem-guard-contexts (or CONTROLPLANE_MEM_GUARD_CONTEXTS) lists ci-c twice (ci-a,ci-c,ci-c)" \
		--contexts ci-a,ci-b --services-per-namespace 5 --mem-guard-contexts ci-a,ci-c,ci-c
	# The same list once each runs on (a dry run passes the split).
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/churn/005-cleanup.sh" --dry-run --contexts ci-a,ci-b
	assert_success
}

@test "B8: SETUP_CONTEXTS with a member twice is refused, named as SETUP_CONTEXTS" {
	_stub_bin
	local s
	for s in churn/003-run-sweep controlplane/002-collect-resource-metrics dataplane/005-cleanup propagation/006-run-sweep; do
		SETUP_CONTEXTS=ci-a,ci-b,ci-b _refuses "$s" "SETUP_CONTEXTS lists ci-b twice (ci-a,ci-b,ci-b): list each mesh member once"
	done
	SETUP_CONTEXTS=ci-a,ci-b,ci-b _refuses tuning/005-cleanup "--contexts (or SETUP_CONTEXTS) lists ci-b twice"
}

@test "B8: every --remote-contexts entrypoint refuses a remote listed twice or equal to the source" {
	_stub_bin
	local s extra
	for s in propagation/002-run-endpoint-probe churn/002-run-churn-probe dataplane/001-setup-dataplane-test \
		dataplane/002-run-latency-probe churn-dataplane/001-setup-coexec-test churn-dataplane/002-run-baseline-probe \
		churn-dataplane/003-run-churn-probe; do
		extra=()
		[[ "$s" != churn-dataplane/003-run-churn-probe ]] || extra=(--churn-rate 5)
		_refuses "$s" "--remote-contexts lists the source context ci-a: the remotes are the other mesh members" \
			--source-context ci-a --remote-contexts ci-b,ci-a ${extra[@]+"${extra[@]}"}
		_refuses "$s" "--remote-contexts lists ci-b twice (ci-b,ci-c,ci-b): list each mesh member once" \
			--source-context ci-a --remote-contexts ci-b,ci-c,ci-b ${extra[@]+"${extra[@]}"}
	done
}

@test "B8: no suite script splits a member list with split_csv any more (split_contexts does)" {
	run grep -nE 'split_csv[[:space:]]+"\$\{?(CONTEXTS_CSV|REMOTE_CONTEXTS_CSV|MEM_GUARD_CONTEXTS_CSV|SETUP_CONTEXTS)' \
		"$ROOT"/tests/*/[0-9]*.sh
	# The one left: controlplane 003's guard list, the union of --contexts and SETUP_CONTEXTS
	# (a member in both is expected there and deduplicated).
	assert_output --regexp '^[^ ]*controlplane/003-run-sweep\.sh:[0-9]+:[[:space:]]+split_csv "\$\{SETUP_CONTEXTS:-\}" _setup_ctxs$'
	[ "${#lines[@]}" -eq 1 ]
	# split_contexts itself: split_csv's split, then the checks.
	run split_contexts "a,b" OUT --contexts
	assert_success
	split_contexts " a , b ,," OUT --contexts
	[ "${OUT[*]}" = "a b" ]
	run split_contexts "a,b,a" OUT --contexts
	assert_failure
	assert_output "error: --contexts lists a twice (a,b,a): list each mesh member once"
	run split_contexts "b,a" OUT --remote-contexts a
	assert_output "error: --remote-contexts lists the source context a: the remotes are the other mesh members"
	# A key holding a quote or a bracket is still one key (no arithmetic on it).
	run split_contexts "x\"y],x\"y]" OUT --contexts
	assert_output --partial 'lists x"y] twice'
}

# --- B9: the keyed-array lint ------------------------------------------------

@test "B9: the lint flags (( )), \$(( )), let, [[ -gt ]] and -v on name[\$k] and name[\"\$k\"]; the tree is clean" {
	source "${ROOT}/tests/lib/lint-keyed-arith.sh"
	local f="${BATS_TEST_TMPDIR}/bad.sh" g="${BATS_TEST_TMPDIR}/good.sh"
	cat > "$f" <<'EOF'
(( count[$k] += 1 ))
n=$(( total["$k"] + 1 ))
let seen[$k]++
if [[ hits[$k] -gt 0 ]]; then :; fi
if [[ 0 -lt hits["$k"] ]]; then :; fi
[[ -v seen[$k] ]] && echo yes
test -v "seen[$k]"
while (( n < max[$k] )); do :; done
EOF
	run lint_keyed_arith_file "$f"
	assert_failure
	[ "${#lines[@]}" -eq 8 ]
	assert_line --partial "bad.sh:1: arithmetic (( ))"
	assert_line --partial "bad.sh:2: arithmetic (( ))"
	assert_line --partial "bad.sh:3: let"
	assert_line --partial "bad.sh:4: [[ -eq/-lt/... ]]"
	assert_line --partial "bad.sh:5: [[ -eq/-lt/... ]]"
	assert_line --partial "bad.sh:6: -v test"
	assert_line --partial "bad.sh:7: -v test"
	assert_line --partial "bad.sh:8: arithmetic (( ))"
	cat > "$g" <<'EOF'
# (( count[$k] += 1 )) in a comment
n="${count[$k]}"; count[$k]=$((n + 1))
(( ${#arr[@]} > 0 ))
(( i < ${#x[$k]} ))
[[ -n "${seen[$k]+x}" ]]
[[ "${hits[$k]}" -gt 0 ]]
(( arr[3] + i ))
let n++
EOF
	run lint_keyed_arith_file "$g"
	assert_success
	assert_output ""
	run lint_keyed_arith_paths "${ROOT}/tests" "${ROOT}/terraform"
	assert_success
	assert_output ""
}

# --- B6: the same results without a fork per file ------------------------------

@test "B6: fanout_body_complete: complete at FANOUT_MIN_SCRAPE_BYTES bytes, never for an empty, short or missing file" {
	local d="$BATS_TEST_TMPDIR"
	head -c 511 /dev/zero | tr '\0' x > "${d}/b511"
	head -c 512 /dev/zero | tr '\0' x > "${d}/b512"
	: > "${d}/empty"
	# 300 two-byte characters: 600 bytes, fewer than 512 characters (counted in bytes).
	printf '%300s' '' | sed 's/ /é/g' > "${d}/multi"
	[ "$(wc -c < "${d}/multi" | tr -d ' ')" -eq 600 ]
	run fanout_body_complete "${d}/b511"; assert_failure
	run fanout_body_complete "${d}/b512"; assert_success
	run fanout_body_complete "${d}/empty"; assert_failure
	run fanout_body_complete "${d}/missing"; assert_failure
	LC_ALL=C.UTF-8 run fanout_body_complete "${d}/multi"; assert_success
	run fanout_body_complete "${d}/multi"; assert_success
	FANOUT_MIN_SCRAPE_BYTES=601 run fanout_body_complete "${d}/multi"; assert_failure
	# A complete body costs no fork: a wc that fails cannot change the answer.
	mkdir -p "${d}/nowc"
	printf '#!/bin/sh\nexit 1\n' > "${d}/nowc/wc"
	chmod +x "${d}/nowc/wc"
	PATH="${d}/nowc:${PATH}" run fanout_body_complete "${d}/b512"
	assert_success
	PATH="${d}/nowc:${PATH}" run fanout_body_complete "${d}/missing"
	assert_failure
}

@test "B6: _config_distinct and config_check_multi_run read a=b names, empty, missing and sweep files as before" {
	local d="${BATS_TEST_TMPDIR}/mr"
	mkdir -p "${d}/sweep-s1"
	printf '# SWEEP_RUN_ID=sweep-s1\n# RUN_ID=s1-a\n# HARNESS_SHA=aaa\n# ISTIO_VERSION=v1.30.5\nrun_id\tx\ns1-a\t1\n' > "${d}/sweep-s1/a.tsv"
	printf '# RUN_ID=s1-b\n# HARNESS_SHA=aaa\nrun_id\tx\ns1-b\t1\n' > "${d}/sweep-s1/b.tsv"
	printf '# RUN_ID=r9\n# HARNESS_SHA=bbb\n# ISTIO_VERSION=1.30.4\nrun_id\tx\nr9\t1\n' > "${d}/a=b.tsv"
	: > "${d}/empty.tsv"
	printf 'run_id\tx\nr7\t1\n' > "${d}/norunid.tsv"
	local -a F=("${d}/sweep-s1/a.tsv" "${d}/sweep-s1/b.tsv" "${d}/a=b.tsv" "${d}/empty.tsv" "${d}/norunid.tsv" "${d}/missing.tsv")
	[ "$(_config_distinct HARNESS_SHA unknown "${F[@]}" | paste -sd'|' -)" = "aaa|bbb|unknown" ]
	[ "$(_config_distinct HARNESS_SHA '' "${F[@]}" | paste -sd'|' -)" = "aaa|bbb" ]
	[ "$(_config_distinct ISTIO_VERSION unknown "${F[@]}" | paste -sd'|' -)" = "v1.30.5|unknown|1.30.4" ]
	[ -z "$(_config_distinct HARNESS_SHA unknown)" ]
	# The run key: the sweep-* dir, else SWEEP_RUN_ID, RUN_ID, the first row's run id, the name.
	[ "$(_config_run_key "${d}/a=b.tsv" "${d}/norunid.tsv" "${d}/empty.tsv" | paste -sd'|' -)" = "r9|r7|empty.tsv" ]
	config_check_multi_run "$d" 1 "${F[@]}" 2>/dev/null
	[ "$MULTI_RUN_N" = 5 ]
	[ "$MULTI_RUN_IDS" = "empty.tsv,missing.tsv,r7,r9,sweep-s1" ]
	[ "$MULTI_RUN_HARNESS_SHAS" = "aaa,bbb,unknown" ]
	[ "$MULTI_RUN_ISTIO_VERSIONS" = "v1.30.5,unknown,1.30.4" ]
	run config_check_multi_run "$d" 0 "${F[@]}"
	assert_failure
	assert_output --partial "holds 5 runs"
	assert_output --partial "  sweep-s1:"
	assert_output --partial "for f in '${d}/a=b.tsv'; do"
	# One sweep alone: one run, nothing printed.
	run config_check_multi_run "${d}/sweep-s1" 0 "${d}/sweep-s1/a.tsv" "${d}/sweep-s1/b.tsv"
	assert_success
	assert_output ""
}

# --- B5: controlplane 002 watch mode -------------------------------------------

@test "B5: controlplane 002 --watch: a failed final scrape is an N/A row, never the last window's gauges; peaks are per window" {
	_stub_bin
	# A short sleep (the script polls every 5 s and waits 3 s for its port-forwards).
	printf '#!/bin/sh\nexec %s 0.05\n' "$(command -v sleep)" > "${BIN}/sleep"
	chmod +x "${BIN}/sleep"
	# Body calls per window: baseline, one peak poll, final. Call 2 (window 1's poll) reads
	# 4 GiB; call 6 (window 2's final) fails. Each body's eds counter is 100 x its number.
	export STUB_COUNT="${BATS_TEST_TMPDIR}/count" STUB_FAIL_CALLS=6 STUB_BIG_CALLS=2
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --output-dir "$RES" --watch --interval 1 \
		> "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" 3>&- &
	local pid=$! i f="" rows=0
	for ((i = 0; i < 600; i++)); do
		f="$(ls "$RES"/controlplane-*.tsv 2>/dev/null | head -1)"
		if [[ -n "$f" ]]; then
			rows="$(awk -F'\t' '!/^#/ && $1 != "timestamp"' "$f" | wc -l | tr -d ' ')"
			((rows >= 3)) && break
		fi
		sleep 0.1
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[ "$rows" -ge 3 ]
	# context, istiod_mem_mi, istiod_restarted, xds_pushes_delta of the first three rows.
	run awk -F'\t' '$1 == "timestamp" { for (i = 1; i <= NF; i++) ix[$i] = i; next }
		!/^#/ && n++ < 3 { print $(ix["context"]), $(ix["istiod_mem_mi"]), $(ix["istiod_restarted"]), $(ix["xds_pushes_delta"]) }' "$f"
	assert_line --index 0 "ctx-a 4096 0 200"
	# Window 2: its final scrape failed. Before B5 the row reused window 1's final body
	# (memory 4096, restarted 0) and read the counter's drop from 400 to 300 as a reset.
	assert_line --index 1 "ctx-a N/A unknown N/A"
	# Window 3: its own peak (300 Mi), not window 1's 4 GiB.
	assert_line --index 2 "ctx-a 300 0 200"
	grep -q "no final scrape for ctx-a/istiod-abc-x1; emitting N/A row" "${BATS_TEST_TMPDIR}/err"
	run grep -c "counter went from" "${BATS_TEST_TMPDIR}/err"
	assert_output 0
	# I1: the harness provenance comes from harness_sha (-dirty.<8hex> on a dirty tree).
	grep -qxF "# HARNESS_SHA=$(source "${ROOT}/tests/lib/preamble.sh"; harness_sha)" "$f"
	[ "$(grep -cE '^# HARNESS_SHA=.*-dirty$' "$f" || true)" = 0 ]
}

# --- B2: P1 dropped only for a source-side reason --------------------------------

_prop_run() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/propagation/002-run-endpoint-probe.sh" \
		--source-context ctx-a --timeout 2 --poll-interval-ms 100 --settle-sec 0 --tsv \
		--output-dir "$RES" "$@"
}

@test "B2: propagation 002 + 005: every remote timed out, the source was clean: P1 is n=1/1 in the summary and every 005 format" {
	_stub_bin
	hist() { printf 'pilot_proxy_convergence_time_bucket{le="0.1"} %s\npilot_proxy_convergence_time_bucket{le="+Inf"} %s\npilot_proxy_convergence_time_sum %s\npilot_proxy_convergence_time_count %s\n' "$1" "$1" "$2" "$1"; }
	{ cat "${FX}/pre_metrics.txt"; hist 0 0; } > "${BATS_TEST_TMPDIR}/pre.txt"
	{ cat "${FX}/pre_metrics.txt"; hist 10 0.5; } > "${BATS_TEST_TMPDIR}/post.txt"
	STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre.txt" STUB_POST_BODY="${BATS_TEST_TMPDIR}/post.txt" \
		_prop_run --remote-contexts ctx-b --iterations 1
	assert_success
	f="$(ls "$RES"/endpoint-*.tsv)"
	# The remote's P2/P3 timed out (the stub never shows the canary there); P1 is clean.
	# remote_status (22) is the remote's own verdict, remote_scrape_skew_ms (23) its skew (I6).
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $20 "/" $21 "/" $22 "/" $23 }' "$f")" = "TIMEOUT_P3/OK/0/TIMEOUT_P3/0" ]
	# One schema for every writer (PL36): the shared header, 23 fields on every line.
	source "${ROOT}/tests/lib/propagation.sh"
	grep -qxF "$PROP_TSV_HEADER" "$f"
	[ "$(awk -F'\t' '!/^#/ { print NF }' "$f" | sort -u)" = 23 ]
	# I1: the harness provenance comes from harness_sha (-dirty.<8hex> on a dirty tree,
	# never a bare -dirty that names no content).
	grep -qxF "# HARNESS_SHA=$(source "${ROOT}/tests/lib/preamble.sh"; harness_sha)" "$f"
	[ "$(grep -cE '^# HARNESS_SHA=.*-dirty$' "$f" || true)" = 0 ]
	# Before B2 the summary read n=0/1: the iteration's only row was dropped for a remote reason.
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --regexp 'P3 remote sidecar: +n=0/1 \(no valid sample\)'
	grep -qE '^\| P1 local xDS push \| 1/1 \| [0-9]+ \|' "$RES"/endpoint-*.md
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line --regexp '^2,P1_local_wall,1,1,[0-9]+,'
	assert_line --regexp '^2,P3_dataplane,1,0,'
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format md
	assert_line --regexp '^\| P1 local xDS \(wall\) \| 1 \| 1 \| [0-9]+ \|'
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES"
	assert_output --regexp 'P1 local xDS \(wall\) +\| +1 \| +1 \|'
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall" or .phase == "P3_dataplane") | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
		'[["P1_local_wall",1,1],["P3_dataplane",1,0]]' ]
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format charts
	assert_success
}

# prow21 <iteration> <remote> <p1_ms> <status> <p1_overflow> <restarted> <p1_status> <p1_scrape_skew_ms>
prow21() {
	local p2=50 p3=60
	[[ "$4" == OK ]] || { p2=N/A p3=N/A; }
	printf 'r1\t3\t%s\tsrc\t%s\t0\t%s\t%s\t%s\t%s\t99\t99\t10/10\t10\t%s\t%s\t0\t5000\t10\t%s\t%s\n' \
		"$1" "$2" "$3" "$p2" "$p3" "$4" "$5" "$6" "$7" "$8"
}

@test "B2: 005 and tuning 004 on 21-column rows: remote failures keep P1; a source restart, overflow or skew drops it" {
	{
		echo "# RUN_ID=r1"
		printf '%s\tp1_status\tp1_scrape_skew_ms\n' "$PROP_HDR"
		# 1: both remotes timed out, the source was clean: P1 counts.
		prow21 1 b 100 TIMEOUT_P3 0 0 OK 5
		prow21 1 c 100 TIMEOUT_P2 0 0 OK 5
		# 2: a remote restarted (restarted=1 on its row), the source was clean: P1 counts.
		prow21 2 b 200 RESTART 0 1 OK 5
		prow21 2 c 200 OK 0 0 OK 5
		# 3: the source istiod restarted: P1 is dropped, whatever the remotes did.
		prow21 3 b 900 OK 0 0 RESTART 5
		prow21 3 c 900 OK 0 0 RESTART 5
		# 4: P1 overflowed: dropped.
		prow21 4 b 900 OK 1 0 OK 5
		prow21 4 c 900 OK 1 0 OK 5
		# 5: the source scrape skewed past FANOUT_MAX_SKEW_MS: dropped.
		prow21 5 b 900 OK 0 0 OK 5000
		prow21 5 c 900 OK 0 0 OK 5000
	} > "${RES}/endpoint-r1.tsv"
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall") | [.n_total, .n_valid, .avg_ms]]' <<<"$output")" = '[[5,2,150]]' ]
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line "3,P1_local_wall,5,2,100,200,150,100,N/A,N/A,"
	# The same rules in tuning 004 (one shared definition).
	P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	cp "${RES}/endpoint-r1.tsv" "${P}/baseline/"
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$P" --format md
	assert_success
	[[ "$output" == *"| P1 local push (ms) | 150.00 (1 overflowed) |"$'\n'"|   n (got/attempted) | 2/5 |"* ]]
	# A legacy 19-column file keeps the old rule: an iteration with no valid row has no P1.
	{
		echo "# RUN_ID=r2"
		echo "$PROP_HDR"
		prow21 1 b 100 TIMEOUT_P3 0 0 OK 5 | cut -f1-19
		prow21 2 b 200 OK 0 0 OK 5 | cut -f1-19
	} > "${BATS_TEST_TMPDIR}/legacy.tsv"
	mkdir -p "${BATS_TEST_TMPDIR}/legacy"
	mv "${BATS_TEST_TMPDIR}/legacy.tsv" "${BATS_TEST_TMPDIR}/legacy/endpoint-r2.tsv"
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "${BATS_TEST_TMPDIR}/legacy" --format json
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall") | [.n_total, .n_valid]]' <<<"$output")" = '[[2,1]]' ]
}

# --- B3: a remote EDS poller that never completed a scrape -----------------------

@test "B3: churn 002: no complete scrape of the remote istiod is SCRAPE_INCOMPLETE_REMOTE_EDS, not TIMEOUT_REMOTE_EDS; 004 counts it in n_total only" {
	_stub_bin
	export CHURN_POLL_INTERVAL_MS=50
	_churn() {
		PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/churn/002-run-churn-probe.sh" \
			--source-context ctx-a --remote-contexts ctx-b --iterations 1 --timeout 2 --settle 0 \
			--deployment-count 1 --output-dir "$1"
	}
	_col() { awk -F'\t' -v c="$1" '$1 == "run_id" { for (i = 1; i <= NF; i++) ix[$i] = i; next } !/^#/ { print $(ix[c]) }' "$2"; }
	# Clean scrapes, no EDS push in the window: a real timeout.
	_churn "${RES}/clean"
	assert_success
	[ "$(_col status "$(ls "$RES"/clean/churn-*.tsv)")" = TIMEOUT_REMOTE_EDS ]
	# Every poller scrape fails: nothing was measured.
	rm -f "$STUB_MARK"
	STUB_EDS_FAIL=1 _churn "${RES}/inc"
	assert_success
	assert_output --partial "Convergence (remote ctx-b, EDS push): not measured (no complete scrape of its istiod)"
	f="$(ls "$RES"/inc/churn-*.tsv)"
	[ "$(_col convergence_remote_eds_ms "$f")" = N/A ]
	[ "$(_col status "$f")" = SCRAPE_INCOMPLETE_REMOTE_EDS ]
	run "${ROOT}/tests/churn/004-report-results.sh" --results-dir "${RES}/inc" --format md
	assert_success
	assert_output --regexp '\| 2 \| 1 \| 1->5 \| 1 \| 0 \|'
	run "${ROOT}/tests/churn/004-report-results.sh" --results-dir "${RES}/inc" --format csv
	assert_line "2,1,1,5,rows_valid_of_total,0,0,1,0,,"
	run "${ROOT}/tests/churn/004-report-results.sh" --results-dir "${RES}/inc"
	assert_output --regexp 'Rows \(valid/total\): +0/1'
	run "${ROOT}/tests/churn/004-report-results.sh" --help
	assert_output --partial "SCRAPE_INCOMPLETE_REMOTE_EDS"
	grep -q 'SCRAPE_INCOMPLETE_REMOTE_EDS' "${ROOT}/tests/churn/README.md"
}

# --- B4: tuning 004's P1 cell names its overflowed iterations ------------------------

@test "B4: tuning 004: the P1 local push cell says how many overflowed iterations its mean leaves out, in md and text" {
	P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	prow() { printf 'r1\t2\t%s\tsrc\t%s\t0\t%s\t50\t60\tOK\t99\t99\t10/10\t10\t0\t0\t0\t5000\t10\n' "$1" "$2" "$3"; }
	local i r
	{
		echo "# RUN_ID=r1"
		echo "$PROP_HDR"
		for i in 1 2 3 4 5; do for r in b c; do prow "$i" "$r" 100; done; done
	} > "${P}/baseline/endpoint-r1.tsv"
	# Iterations 2-4 overflowed (every row carries p1_overflow=1); iteration 5 also
	# restarted, which drops it for the restart, so it is not counted as overflowed.
	{
		echo "# RUN_ID=r2"
		echo "$PROP_HDR"
		for i in 1 2 3 4 5; do for r in b c; do prow "$i" "$r" "$((100 * i))"; done; done \
			| awk -F'\t' 'BEGIN { OFS = "\t" } $3 >= 2 && $3 <= 4 { $15 = 1 } $3 == 5 { $15 = 1; $16 = 1 } 1'
	} > "${P}/01-x/endpoint-r2.tsv"
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$P" --format md
	assert_success
	[[ "$output" == *"| P1 local push (ms) | 100.00 | 100.00 (+0.0%) (3 overflowed) |"$'\n'"|   n (got/attempted) | 5/5 | 1/5 (baseline n 5/5) |"* ]]
	assert_output --partial '"(N overflowed)" in the P1 local push cell'
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$P"
	assert_success
	assert_output --regexp 'P1 local push \(ms\) +100\.00 +100\.00 \(\+0\.0%\) \(3 overflowed\)'
	# The baseline had none: its cell has no note.
	refute_output --regexp 'P1 local push \(ms\) +100\.00 \([0-9]+ overflowed\)'
}

# --- B1: active revisions and proxy versions in four more reports -----------------

REV_A="ci-a=default,ci-b=default"
REV_B="ci-a=canary,ci-b=default"
PV_A="ci-a=1.30.5:12,ci-b=1.30.5:10"
PV_B="ci-a=1.30.4:12,ci-b=1.30.5:10"

# keys <revisions> <proxy versions>: the two preamble lines.
keys() { printf '# ISTIO_ACTIVE_REVISIONS=%s\n# ISTIO_PROXY_VERSIONS=%s\n' "$1" "$2"; }

@test "B1: propagation 005 prints both keys in every format; differing inputs read mixed; an older TSV reads unknown" {
	prow() { printf '%s\t2\t1\tsrc\trmt\t0\t100\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n' "$1"; }
	mkdir -p "${RES}/one" "${RES}/two" "${RES}/old"
	{ echo "# RUN_ID=r1"; keys "$REV_A" "$PV_A"; echo "$PROP_HDR"; prow r1; } > "${RES}/one/endpoint-r1.tsv"
	cp "${RES}/one/endpoint-r1.tsv" "${RES}/two/"
	{ echo "# RUN_ID=r2"; keys "$REV_B" "$PV_B"; echo "$PROP_HDR"; prow r2; } > "${RES}/two/endpoint-r2.tsv"
	{ echo "# RUN_ID=r3"; echo "$PROP_HDR"; prow r3; } > "${RES}/old/endpoint-r3.tsv"
	local R="${ROOT}/tests/propagation/005-report-results.sh"
	run "$R" --results-dir "${RES}/one"
	assert_line "  ISTIO_ACTIVE_REVISIONS: ${REV_A}"
	assert_line "  ISTIO_PROXY_VERSIONS: ${PV_A}"
	run "$R" --results-dir "${RES}/one" --format csv
	assert_line "# ISTIO_ACTIVE_REVISIONS=${REV_A}"
	assert_line "# ISTIO_PROXY_VERSIONS=${PV_A}"
	run "$R" --results-dir "${RES}/one" --format md
	assert_line "ISTIO_PROXY_VERSIONS: \"${PV_A}\""
	run "$R" --results-dir "${RES}/one" --format charts
	assert_line "ISTIO_ACTIVE_REVISIONS: \"${REV_A}\""
	run "$R" --results-dir "${RES}/one" --format json
	[ "$(jq -r '.metadata.ISTIO_ACTIVE_REVISIONS + " " + .metadata.ISTIO_PROXY_VERSIONS' <<<"$output")" = "${REV_A} ${PV_A}" ]
	run --separate-stderr "$R" --results-dir "${RES}/two" --allow-multi-run --format json
	[ "$(jq -r '.metadata.ISTIO_PROXY_VERSIONS' <<<"$output")" = "mixed:${PV_A} | ${PV_B}" ]
	[[ "$stderr" == *"disagree on sweep-level ISTIO_ACTIVE_REVISIONS"* ]]
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format md
	assert_line "ISTIO_ACTIVE_REVISIONS: \"mixed:${REV_A} | ${REV_B}\""
	run "$R" --results-dir "${RES}/old" --format csv
	assert_line "# ISTIO_ACTIVE_REVISIONS=unknown"
	assert_line "# ISTIO_PROXY_VERSIONS=unknown"
	run "$R" --results-dir "${RES}/old"
	assert_line "  ISTIO_PROXY_VERSIONS: unknown"
}

@test "B1: churn 004 prints both keys in text, csv, md and charts; mixed and unknown as well" {
	crow() { printf '%s\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\t99\t50\t60\t10\t10\tOK\n' "$1"; }
	mkdir -p "${RES}/two" "${RES}/old"
	{ echo "# RUN_ID=r1"; keys "$REV_A" "$PV_A"; echo "$CHURN_HDR"; crow r1; } > "${RES}/two/churn-r1.tsv"
	{ echo "# RUN_ID=r2"; keys "$REV_B" "$PV_B"; echo "$CHURN_HDR"; crow r2; } > "${RES}/two/churn-r2.tsv"
	{ echo "# RUN_ID=r3"; echo "$CHURN_HDR"; crow r3; } > "${RES}/old/churn-r3.tsv"
	local R="${ROOT}/tests/churn/004-report-results.sh"
	run "$R" --results-dir "${RES}/two" --allow-multi-run
	assert_line "# istio_active_revisions: mixed:${REV_A} | ${REV_B}"
	assert_line "# istio_proxy_versions: mixed:${PV_A} | ${PV_B}"
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format csv
	assert_line "# ISTIO_PROXY_VERSIONS=mixed:${PV_A} | ${PV_B}"
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format md
	assert_line "istio_active_revisions: \"mixed:${REV_A} | ${REV_B}\""
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format charts
	assert_line "istio_proxy_versions: \"mixed:${PV_A} | ${PV_B}\""
	run "$R" --results-dir "${RES}/old" --format csv
	assert_line "# ISTIO_ACTIVE_REVISIONS=unknown (not recorded)"
	assert_line "# ISTIO_PROXY_VERSIONS=unknown (not recorded)"
	run "$R" --results-dir "${RES}/old" --format md
	assert_line "istio_proxy_versions: \"unknown (not recorded)\""
}

@test "B1: churn-dataplane 005 prints both keys in every format, md cells escaped; mixed and unknown as well" {
	drow() { printf '%s\tsha\tc1\t2\t%s\t%s\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n' "$1" "$2" "$3"; }
	mkdir -p "${RES}/two" "${RES}/old"
	{ echo "# RUN_ID=r1"; keys "$REV_A" "$PV_A"; echo "$CD_HDR"; drow r1 0 baseline; drow r1 1 churn; } > "${RES}/two/churn-dataplane-r1.tsv"
	{ echo "# RUN_ID=r2"; keys "$REV_B" "$PV_B"; echo "$CD_HDR"; drow r2 0 baseline; drow r2 1 churn; } > "${RES}/two/churn-dataplane-r2.tsv"
	{ echo "# RUN_ID=r3"; echo "$CD_HDR"; drow r3 0 baseline; drow r3 1 churn; } > "${RES}/old/churn-dataplane-r3.tsv"
	local R="${ROOT}/tests/churn-dataplane/005-report-results.sh" fmt
	for fmt in text csv charts; do
		run "$R" --results-dir "${RES}/two" --allow-multi-run --format "$fmt"
		assert_output --partial "ISTIO_ACTIVE_REVISIONS=mixed:${REV_A} | ${REV_B}"
		assert_output --partial "ISTIO_PROXY_VERSIONS=mixed:${PV_A} | ${PV_B}"
		run "$R" --results-dir "${RES}/old" --format "$fmt"
		assert_output --partial "ISTIO_ACTIVE_REVISIONS=unknown"
		assert_output --partial "ISTIO_PROXY_VERSIONS=unknown"
	done
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format md
	assert_line "| ISTIO_PROXY_VERSIONS | \`mixed:${PV_A} \\| ${PV_B}\` |"
	run --separate-stderr "$R" --results-dir "${RES}/two" --allow-multi-run --format json
	[ "$(jq -r '.metadata.istio_active_revisions' <<<"$output")" = "mixed:${REV_A} | ${REV_B}" ]
	run "$R" --results-dir "${RES}/old" --format json
	[ "$(jq -r '.metadata.istio_proxy_versions' <<<"$output")" = unknown ]
}

@test "B1: tuning 004 prints both keys over every pass, in md and text; mixed and unknown as well" {
	P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	# sweep-metadata.txt records the keys at the sweep's start, as 003 writes it.
	{ printf '# SUITE=propagation\n# PASSES=baseline,01-x\n'; keys "$REV_A" "$PV_A"; } > "${P}/sweep-metadata.txt"
	prow() { printf '%s\t2\t1\tsrc\tb\t0\t100\t50\t60\tOK\t99\t99\t10/10\t10\t0\t0\t0\t5000\t10\n' "$1"; }
	{ echo "# RUN_ID=r1"; keys "$REV_A" "$PV_A"; echo "$PROP_HDR"; prow r1; } > "${P}/baseline/endpoint-r1.tsv"
	{ echo "# RUN_ID=r2"; keys "$REV_A" "$PV_B"; echo "$PROP_HDR"; prow r2; } > "${P}/01-x/endpoint-r2.tsv"
	local R="${ROOT}/tests/tuning/004-compare-profiles.sh"
	run "$R" --results-dir "$P" --format md
	# ISTIO_GENERATIONS (I3): no input records it here, so unknown.
	assert_line "- Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${REV_A}; ISTIO_GENERATIONS=unknown; ISTIO_PROXY_VERSIONS=mixed:${PV_A} | ${PV_B}"
	run "$R" --results-dir "$P"
	assert_line "Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${REV_A}; ISTIO_GENERATIONS=unknown; ISTIO_PROXY_VERSIONS=mixed:${PV_A} | ${PV_B}"
	sed -i.bak '/^# ISTIO_ACTIVE_REVISIONS=/d; /^# ISTIO_PROXY_VERSIONS=/d' "${P}/sweep-metadata.txt" "${P}/baseline/endpoint-r1.tsv" "${P}/01-x/endpoint-r2.tsv"
	run "$R" --results-dir "$P" --format md
	assert_line "- Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=unknown; ISTIO_GENERATIONS=unknown; ISTIO_PROXY_VERSIONS=unknown"
}

# --- B7: tests/lib/redact-results.sh ----------------------------------------------

# _redact_fixture <dir>: a sweep dir that names ci-a, ci-b, ci-c, an API URL, IPs, an
# email, an ARN, cluster hosts, a home dir, and raw istiod-diag evidence.
_redact_fixture() {
	local d="$1/sweep-r1"
	mkdir -p "${d}/istiod-diag-r1/001-restart-ci-a"
	cat > "${d}/endpoint-r1.tsv" <<'EOF'
# SOURCE_CTX=ci-a
# REMOTES=ci-b ci-c
# ISTIO_VERSION_BY_CONTEXT=ci-a=1.30.5,ci-b=1.30.5,ci-c=1.30.4
# ISTIO_PROXY_VERSIONS=ci-a=1.30.5:120+1.30.4:3,ci-b=1.30.5:10,ci-c=unknown
# RUN_CONFIG=/home/someone/run.env
run_id	mesh_size	iteration	source_ctx	remote_ctx	status	detail
r1	3	1	ci-a	ci-b	OK	-
r1	3	1	ci-a	ci-c	TIMEOUT_P3	Get "https://api.cluster-1.example.com:6443/api?timeout=32s": dial tcp 192.0.2.10:6443: i/o timeout
EOF
	cat > "${d}/reach-r1.tsv" <<'EOF'
run_id	source_ctx	target_ctx	detail
r1	ci-a	ci-b	fortio-server-ci-b.ns.svc.cluster.local from 2001:db8::1 via [2001:db8::2]:8080
r1	ci-a	ci-c	upstream ip-192-0-2-7.ec2.internal at 192.0.2.12
EOF
	printf 'run_id\tcontext\tfolder\nr1\tci-a\t001-restart-ci-a\n' > "${d}/istiod-diag-r1/index.tsv"
	echo 'raw log from api.cluster-1.example.com' > "${d}/istiod-diag-r1/001-restart-ci-a/istiod.log.txt"
	cat > "${d}/report.md" <<'EOF'
ISTIO_ACTIVE_REVISIONS: "mixed:ci-a=default,ci-b=default | ci-a=canary"
| ISTIO_PROXY_VERSIONS | `ci-a=1.30.5:120\|ci-b=1.30.5` |
Owner user@example.com, role arn:aws:iam::123456789012:role/x
Console console-openshift-console.apps.cluster-1.example.com and lb a1b2.elb.amazonaws.com
On ci-a, ci-b and ci-c; ci-ab is another word.
EOF
	printf '{"metadata":{"istio_version_by_context":"ci-a=1.30.5,ci-b=1.30.5"},"rows":[{"source_ctx":"ci-a","target_ctx":"ci-c","url":"https://192.0.2.7:6443/x"}]}\n' > "${d}/report.json"
	printf 'RUN_ID=r1\nNOTE=not ready at the start: IstiodNotReady on 2 members (ci-a, ci-b)\n' > "${d}/sweep-outcome.txt"
	printf 'PNG' > "${d}/chart.png"
}

@test "B7: redact-results --out: placeholders for every context, URL, IP, email, account and host; mapping on stderr only; input untouched" {
	_redact_fixture "$RES"
	local before after out="${BATS_TEST_TMPDIR}/copy"
	before="$(cd "$RES" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r1"
	assert_success
	[[ "$stderr" == *"istiod-diag-r1/001-restart-ci-a/istiod.log.txt (raw istiod-diag evidence"* ]]
	[[ "$stderr" == *"chart.png (not a .tsv/.md/.txt/.csv/.json file)"* ]]
	after="$(cd "$RES" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
	[ "$before" = "$after" ]
	# The mapping: stderr only, sorted names.
	[[ "$stderr" == *"<mesh-a-ctx>     ci-a"* && "$stderr" == *"<mesh-c-ctx>     ci-c"* ]]
	refute_output --partial "ci-a"
	local c="${out}/sweep-r1"
	run cat "${c}/endpoint-r1.tsv"
	assert_line "# SOURCE_CTX=<mesh-a-ctx>"
	assert_line "# REMOTES=<mesh-b-ctx> <mesh-c-ctx>"
	assert_line "# ISTIO_PROXY_VERSIONS=<mesh-a-ctx>=1.30.5:120+1.30.4:3,<mesh-b-ctx>=1.30.5:10,<mesh-c-ctx>=unknown"
	assert_line "# RUN_CONFIG=/home/<user>/run.env"
	assert_line $'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tstatus\tdetail'
	assert_line $'r1\t3\t1\t<mesh-a-ctx>\t<mesh-c-ctx>\tTIMEOUT_P3\tGet "<api-host>": dial tcp <ip>:6443: i/o timeout'
	run cat "${c}/reach-r1.tsv"
	assert_line $'r1\t<mesh-a-ctx>\t<mesh-b-ctx>\tfortio-server-<mesh-b-ctx>.ns.svc.cluster.local from <ip> via <ip>:8080'
	assert_line $'r1\t<mesh-a-ctx>\t<mesh-c-ctx>\tupstream <host> at <ip>'
	run cat "${c}/istiod-diag-r1/index.tsv"
	assert_line $'r1\t<mesh-a-ctx>\t001-restart-<mesh-a-ctx>'
	run cat "${c}/report.md"
	assert_line 'ISTIO_ACTIVE_REVISIONS: "mixed:<mesh-a-ctx>=default,<mesh-b-ctx>=default | <mesh-a-ctx>=canary"'
	assert_line 'Owner <email>, role arn:aws:iam::<account>:role/x'
	assert_line 'Console <host> and lb <host>'
	assert_line 'On <mesh-a-ctx>, <mesh-b-ctx> and <mesh-c-ctx>; ci-ab is another word.'
	jq -e '.rows[0].source_ctx == "<mesh-a-ctx>" and .rows[0].url == "<api-host>"' "${c}/report.json"
	grep -qx 'NOTE=not ready at the start: IstiodNotReady on 2 members (<mesh-a-ctx>, <mesh-b-ctx>)' "${c}/sweep-outcome.txt"
	# Raw evidence and other file types are not copied, and say so on stderr.
	[ ! -e "${c}/istiod-diag-r1/001-restart-ci-a" ]
	[ ! -e "${c}/chart.png" ]
	# Nothing identifying is left anywhere in the copy.
	run grep -rlE 'ci-[abc]([^A-Za-z0-9_]|$)|192\.0\.2|2001:db8|example\.com|amazonaws|123456789012|someone' "$out"
	assert_output ""
	# A second run over the copy finds nothing more to change.
	run "$REDACT" --dry-run "$out"
	assert_success
	refute_output --partial "  would change  "
	assert_output --partial "6 file(s), 0 would change, 0 refused"
}

@test "B7: redact-results --dry-run writes nothing and lists the changes; no mode at all is refused" {
	_redact_fixture "$RES"
	local out="${BATS_TEST_TMPDIR}/copy"
	run --separate-stderr "$REDACT" --dry-run --out "$out" "${RES}/sweep-r1"
	assert_success
	[ ! -e "$out" ]
	assert_output --partial "dry run, nothing written"
	assert_line --regexp "^  would change  .*/sweep-r1/endpoint-r1\.tsv \([0-9]+ line\(s\): context [0-9]+, url 1, ip 1, user 1\)$"
	assert_line --regexp "^  would change  .*/sweep-r1/report\.md \([0-9]+ line\(s\): context [0-9]+, account 1, email 1, host 2\)$"
	run --separate-stderr "$REDACT" "${RES}/sweep-r1"
	assert_failure
	[[ "$stderr" == *"say where the redacted files go"* ]]
	run --separate-stderr "$REDACT" --out "${RES}/sweep-r1/x" "${RES}/sweep-r1"
	assert_failure
	[[ "$stderr" == *"overlap"* ]]
	mkdir -p "$out" && touch "${out}/old.md"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r1"
	assert_failure
	[[ "$stderr" == *"is not empty"* ]]
	run "$REDACT" --help
	assert_success
	local flag
	for flag in --out --in-place --dry-run --context --hub-context --help; do assert_output --partial -- "$flag"; done
}

@test "B7: a context column naming a member the metadata does not: exit 1, the file named and not written; --context maps it" {
	_redact_fixture "$RES"
	printf 'r1\tci-a\tci-z\t-\n' >> "${RES}/sweep-r1/reach-r1.tsv"
	local out="${BATS_TEST_TMPDIR}/copy"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r1"
	assert_failure
	[[ "$stderr" == *"/sweep-r1/reach-r1.tsv: refused, not written:"* ]]
	[[ "$stderr" == *"column target_ctx holds ci-z, a context it was not told about (pass --context ci-z)"* ]]
	[ ! -e "${out}/sweep-r1/reach-r1.tsv" ]
	[ -e "${out}/sweep-r1/endpoint-r1.tsv" ]
	rm -rf "$out"
	run --separate-stderr "$REDACT" --out "$out" --context ci-z --hub-context ci-hub "${RES}/sweep-r1"
	assert_success
	# A named context takes the first letter; the hub has its own placeholder.
	[[ "$stderr" == *"<mesh-a-ctx>     ci-z"* && "$stderr" == *"<hub-a-ctx>      ci-hub"* ]]
	grep -qx $'r1\t<mesh-b-ctx>\t<mesh-a-ctx>\t-' "${out}/sweep-r1/reach-r1.tsv"
}

@test "B7: --in-place rewrites only a file that passes the scan; a JSON file stays valid JSON" {
	_redact_fixture "$RES"
	local d="${RES}/sweep-r1"
	run --separate-stderr "$REDACT" --in-place "${d}/endpoint-r1.tsv" "${d}/report.json"
	assert_success
	grep -qx '# SOURCE_CTX=<mesh-a-ctx>' "${d}/endpoint-r1.tsv"
	jq -e '.rows[0].target_ctx == "<mesh-c-ctx>"' "${d}/report.json"
	# A file the scan refuses keeps its content.
	cp "${d}/reach-r1.tsv" "${BATS_TEST_TMPDIR}/reach.orig"
	run --separate-stderr "$REDACT" --in-place "${d}/reach-r1.tsv"
	assert_failure
	cmp "${d}/reach-r1.tsv" "${BATS_TEST_TMPDIR}/reach.orig"
}

@test "B7: a real controlplane sweep (TSV, markdown and json reports, scale envelope md) redacts; the envelope is left as is" {
	local d="${RES}/sweep-t2" out="${BATS_TEST_TMPDIR}/copy" rep="${ROOT}/tests/controlplane/004-report-results.sh"
	mkdir -p "$d"
	cp "${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" "${d}/controlplane-fixture-t2.tsv"
	"$rep" --results-dir "$d" --format markdown > "${d}/summary-t2.md" 2>/dev/null
	"$rep" --results-dir "$d" --format json > "${d}/report-t2.json" 2>/dev/null
	# The envelope as 003 writes it: the real renderer, no cluster (kubectl is `false`).
	(
		source "${ROOT}/tests/lib/capacity.sh"
		source "${ROOT}/tests/lib/envelope.sh"
		render_scale_envelope "$d" "$rep" "mesh-a,mesh-b" false
	) > "${d}/scale-envelope-t2.md" 2>/dev/null
	grep -q '^## Scale envelope' "${d}/scale-envelope-t2.md"
	run --separate-stderr "$REDACT" --out "$out" "$d"
	assert_success
	[[ "$stderr" == *"<mesh-a-ctx>     mesh-a"* && "$stderr" == *"<mesh-b-ctx>     mesh-b"* ]]
	assert_output --partial "4 of 4 file(s) written"
	local c="${out}/sweep-t2"
	# The envelope names no member: copied byte for byte (no metric or path mangled).
	cmp "${d}/scale-envelope-t2.md" "${c}/scale-envelope-t2.md"
	run grep -rlE '(^|[^<])mesh-[ab]' "$out"
	assert_output ""
	jq -e '.metadata.proxy_check.flagged == "<mesh-a-ctx>@2026-06-01T00:10:00+00:00:LOW:30/40"' "${c}/report-t2.json"
	# Same columns and the same header row as the input.
	[ "$(awk -F'\t' '!/^#/ { print NF }' "${c}/controlplane-fixture-t2.tsv" | sort -u)" = 51 ]
	[ "$(grep -v '^#' "${d}/controlplane-fixture-t2.tsv" | head -1)" = "$(grep -v '^#' "${c}/controlplane-fixture-t2.tsv" | head -1)" ]
	run "$REDACT" --dry-run "$out"
	assert_success
	assert_output --partial "4 file(s), 0 would change, 0 refused"
}
