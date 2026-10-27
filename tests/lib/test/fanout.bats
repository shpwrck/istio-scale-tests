#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/timestamp.sh"
source "${ROOT}/tests/lib/metrics.sh"
source "${ROOT}/tests/lib/fanout.sh"

FIXTURES="${ROOT}/tests/lib/test/fixtures"
POD0="${FIXTURES}/istiod_pod0.txt"
POD1="${FIXTURES}/istiod_pod1.txt"
ZERO="${FIXTURES}/istiod_zero_baseline.txt"

# _idle_body <file>: a complete body (>= FANOUT_MIN_SCRAPE_BYTES) from a replica that never
# pushed: no pilot_xds_pushes sample and no # TYPE/HELP line for it, as istiod writes it.
_idle_body() {
	grep -v '^pilot_xds_pushes[{ ]\|^# [A-Z]* pilot_xds_pushes ' "$POD0" > "$1"
	(( $(wc -c < "$1") >= FANOUT_MIN_SCRAPE_BYTES ))
	! grep -q 'pilot_xds_pushes' "$1"
}

# --- counter aggregation ---------------------------------------------------

@test "fanout_counter_sum and fanout_counter_by_label_sum: the counter summed across pods (a pod that has not registered it yet adds 0); in no pod's scrape it is unknown, not 0; an empty, short or missing pod file, or every one, is unscraped, never a partial sum, and a failed baseline's delta N/A (PL29)" {
	# pilot_xds_pushes pod0 = 100+200+100=400, pod1 = 50+120+50=220 -> 620; eds 200 + 120.
	[ "$(fanout_counter_sum pilot_xds_pushes "$POD0" "$POD1")" = 620 ]
	[ "$(fanout_counter_by_label_sum pilot_xds_pushes type eds "$POD0" "$POD1")" = 320 ]
	other="${BATS_TEST_TMPDIR}/idle.metrics"
	_idle_body "$other"
	[ "$(fanout_counter_sum pilot_xds_pushes "$POD0" "$other")" = 400 ]
	[ "$(fanout_counter_sum pilot_xds_pushes_renamed "$POD0" "$POD1")" = unknown ]
	[ "$(fanout_counter_by_label_sum pilot_xds_pushes_renamed type eds "$POD0" "$POD1")" = unknown ]
	empty="${BATS_TEST_TMPDIR}/empty.metrics"; : > "$empty"
	short="${BATS_TEST_TMPDIR}/short.metrics"
	printf 'pilot_xds_pushes{type="eds"} 5\n' > "$short"
	for f in "$empty" "$short" "${BATS_TEST_TMPDIR}/nope.metrics"; do
		[ "$(fanout_counter_sum pilot_xds_pushes "$POD0" "$f")" = "unscraped" ]
		[ "$(fanout_counter_by_label_sum pilot_xds_pushes type eds "$f" "$POD0")" = "unscraped" ]
	done
	[ "$(fanout_counter_sum pilot_xds_pushes)" = "unscraped" ]
	# A failed baseline never yields the counter's lifetime total as a window delta.
	run --separate-stderr counter_delta "$(fanout_counter_sum pilot_xds_pushes "$POD0" "$empty")" \
		"$(fanout_counter_sum pilot_xds_pushes "$POD0" "$POD1")" pilot_xds_pushes
	assert_output "N/A"
	[[ "$stderr" == *"baseline scrape is empty, short or unreadable"* ]]
	[ "$(fanout_counter_sum pilot_xds_pushes "$empty" "$empty")" = unscraped ]
	[ "$(fanout_counter_by_label_sum pilot_xds_pushes type eds "$empty" "$empty")" = unscraped ]
}

# --- per-replica counters ----------------------------------------------------

@test "fanout_replica_counter: an idle replica among busy ones is a real 0 (delta 0, no warning); absent from every replica it stays unknown (renamed?), a delta N/A with a warning; an incomplete body counts for nothing" {
	idle="${BATS_TEST_TMPDIR}/idle.metrics"
	_idle_body "$idle"
	in_batch=$(fanout_counter_in_batch pilot_xds_pushes "$idle" "$POD0" "$idle" "$POD1")
	[ "$in_batch" = "1" ]
	[ "$(fanout_replica_counter "$in_batch" "$idle" pilot_xds_pushes)" = "0" ]
	[ "$(fanout_replica_counter "$in_batch" "$idle" pilot_xds_pushes type eds)" = "0" ]
	# The busy replicas read as before.
	[ "$(fanout_replica_counter "$in_batch" "$POD0" pilot_xds_pushes)" = "400" ]
	[ "$(fanout_replica_counter "$in_batch" "$POD1" pilot_xds_pushes type eds)" = "120" ]
	# Its window delta is 0, with no "renamed" warning.
	run --separate-stderr counter_delta "$(fanout_replica_counter "$in_batch" "$idle" pilot_xds_pushes)" \
		"$(fanout_replica_counter "$in_batch" "$idle" pilot_xds_pushes)" pilot_xds_pushes
	assert_output "0"
	[ -z "$stderr" ]
	i1="${BATS_TEST_TMPDIR}/idle1.metrics"; i2="${BATS_TEST_TMPDIR}/idle2.metrics"
	_idle_body "$i1"; _idle_body "$i2"
	in_batch=$(fanout_counter_in_batch pilot_xds_pushes "$i1" "$i2")
	[ "$in_batch" = "0" ]
	[ "$(fanout_replica_counter "$in_batch" "$i1" pilot_xds_pushes)" = "unknown" ]
	[ "$(fanout_replica_counter "$in_batch" "$i1" pilot_xds_pushes type eds)" = "unknown" ]
	run --separate-stderr counter_delta "$(fanout_replica_counter "$in_batch" "$i1" pilot_xds_pushes)" \
		"$(fanout_replica_counter "$in_batch" "$i2" pilot_xds_pushes)" pilot_xds_pushes
	assert_output "N/A"
	[[ "$stderr" == *"neither scrape"* ]]
	# A short body with the counter does not prove the counter exists in this batch, and one
	# replica's short or missing body is unscraped, whatever the batch says.
	short="${BATS_TEST_TMPDIR}/short.metrics"
	printf 'pilot_xds_pushes{type="eds"} 5\n' > "$short"
	[ "$(fanout_counter_in_batch pilot_xds_pushes "$short" "$idle" "${BATS_TEST_TMPDIR}/nope")" = "0" ]
	[ "$(fanout_replica_counter 1 "$short" pilot_xds_pushes)" = "unscraped" ]
	[ "$(fanout_replica_counter 1 "${BATS_TEST_TMPDIR}/nope" pilot_xds_pushes type eds)" = "unscraped" ]
}

# --- gauge SUM vs INVARIANT (the load-bearing distinction) ------------------

@test "extract_gauge_sum and fanout_gauge_sum: every label permutation within a pod (3+2, 4+3), then across pods (12); a gauge in no scrape is unknown" {
	result=$(extract_gauge_sum "$POD0" pilot_xds)
	[ "$result" = "5" ]
	result=$(extract_gauge_sum "$POD1" pilot_xds)
	[ "$result" = "7" ]
	result=$(extract_gauge_sum "$ZERO" pilot_xds)
	[ "$result" = "unknown" ]
	result=$(fanout_gauge_sum pilot_xds "$POD0" "$POD1")
	[ "$result" = "12" ]
}

@test "fanout_gauge_sum_strict: both axes (12), complete or unknown: an empty, short (< FANOUT_MIN_SCRAPE_BYTES) or missing pod file, or none, is unknown where the lenient sum drops the pod; a complete body without the series is 0; the live label shape (version=) with mixed proxy versions sums (PL29)" {
	result=$(fanout_gauge_sum_strict pilot_xds "$POD0" "$POD1")
	[ "$result" = "12" ]
	empty="${BATS_TEST_TMPDIR}/empty.metrics"; : > "$empty"
	[ "$(fanout_gauge_sum_strict pilot_xds "$POD0" "$empty")" = "unknown" ]
	# The contrast that motivates the strict variant: the lenient sum drops the pod.
	[ "$(fanout_gauge_sum pilot_xds "$POD0" "$empty")" = "5" ]
	[ "$(fanout_gauge_sum_strict pilot_xds "$POD0" "${BATS_TEST_TMPDIR}/nope.metrics")" = "unknown" ]
	[ "$(fanout_gauge_sum_strict pilot_xds)" = "unknown" ]
	short="${BATS_TEST_TMPDIR}/short.metrics"
	printf 'pilot_xds{version="1.30.5"} 3\n' > "$short"
	[ "$(fanout_gauge_sum_strict pilot_xds "$short")" = "unknown" ]
	[ "$(fanout_gauge_sum_strict pilot_xds "$POD1" "$short")" = "unknown" ]
	# A replica with no connected proxies emits no pilot_xds series at all.
	idle="${BATS_TEST_TMPDIR}/idle.metrics"
	grep -v '^pilot_xds[{ ]' "$POD0" > "$idle"
	(( $(wc -c < "$idle") >= FANOUT_MIN_SCRAPE_BYTES ))
	[ "$(fanout_gauge_sum_strict pilot_xds "$idle")" = "0" ]
	[ "$(fanout_gauge_sum_strict pilot_xds "$idle" "$POD1")" = "7" ]
	live="${BATS_TEST_TMPDIR}/live.metrics"
	grep -v '^pilot_xds[{ ]' "$POD0" > "$live"
	printf 'pilot_xds{version="1.30.5"} 9\npilot_xds{version="1.29.0"} 1\n' >> "$live"
	[ "$(fanout_gauge_sum_strict pilot_xds "$live")" = "10" ]
	[ "$(fanout_gauge_sum_strict pilot_xds "$live" "$POD1")" = "17" ]
}

# --- histogram bucket-sum -> delta_histogram_p99 ---------------------------

@test "fanout_merge_histogram + delta_histogram_p99: the merged buckets (their _count the pods' sum) land p99 on the expected bucket, interpolated; one pod merges to itself" {
	# Merged convergence buckets (pod0+pod1) against a zero baseline:
	#   le=0.5:40  le=1:90  le=3:120  +Inf:120 ; count=120 (pod0 50 + pod1 70)
	# target = 120 * 0.99 = 118.8 -> crosses in the [1,3] bucket (cum 90->120).
	# Linear interpolation: 1 + (3-1)*(118.8-90)/(120-90) = 2.92s -> 2920.00ms
	merged="${BATS_TEST_TMPDIR}/merged"
	fanout_merge_histogram pilot_proxy_convergence_time "$merged" "$POD0" "$POD1"
	[ "$(delta_histogram_p99 "$ZERO" "$merged" pilot_proxy_convergence_time)" = 2920.00 ]
	[ "$(awk '/_count /{print $2}' "$merged")" = 120 ]
	# pod0 alone merges to itself: count 50, target 49.5; crosses in [0.5,1] (cum 30->50):
	# 0.5 + (1-0.5)*(49.5-30)/(50-30) = 0.9875s -> 987.50ms
	fanout_merge_histogram pilot_proxy_convergence_time "$merged" "$POD0"
	[ "$(delta_histogram_p99 "$ZERO" "$merged" pilot_proxy_convergence_time)" = 987.50 ]
}

# --- empty / incomplete scrape detection -----------------------------------
# Stub curl so fanout_scrape_all can be exercised without a live istiod. The
# stub maps a port to a canned body via $CURL_BODY_DIR/<port>; a missing file
# simulates a connection failure (curl exits non-zero, empty out file).

_install_curl_stub() {
	CURL_BODY_DIR="${BATS_TEST_TMPDIR}/curl-bodies"
	mkdir -p "$CURL_BODY_DIR"
	export CURL_BODY_DIR
	curl() {
		local out="" url="" port=""
		while (($#)); do
			case "$1" in
				-o) out="$2"; shift 2 ;;
				http://localhost:*/metrics) url="$1"; shift ;;
				*) shift ;;
			esac
		done
		port="${url#http://localhost:}"; port="${port%/metrics}"
		local body="${CURL_BODY_DIR}/${port}"
		if [[ -f "$body" ]]; then
			[[ -n "$out" ]] && cp "$body" "$out"
			return 0
		fi
		[[ -n "$out" ]] && : > "$out"
		return 7  # curl: couldn't connect
	}
	export -f curl
}

@test "fanout_scrape_all: a full body on every pod is failed=0 with the batch skew persisted to <prefix>.skew; a dead port-forward (no body) or a short body is a failed pod and a non-zero return" {
	_install_curl_stub
	# Two pods with full bodies: none failed, and the skew it echoes is persisted to
	# <prefix>.skew (the completion stamps are taken in background subshells, so the spread
	# itself is not deterministic here).
	cp "$POD0" "$CURL_BODY_DIR/30000"
	cp "$POD1" "$CURL_BODY_DIR/30001"
	d="${BATS_TEST_TMPDIR}/full"
	mkdir -p "$d"
	skew=$(fanout_scrape_all "$d" tick 30000 30001)
	[ "$(fanout_scrape_failed_count "$d" tick)" = "0" ]
	[ "$(cat "$d/tick.skew")" = "$skew" ]
	# A dead port-forward (no body): failed=1, non-zero; the reachable pod's scrape intact.
	rm "$CURL_BODY_DIR/30001"
	d="${BATS_TEST_TMPDIR}/dead"
	mkdir -p "$d"
	run fanout_scrape_all "$d" tick 30000 30001
	[ "$status" -ne 0 ]
	[ "$(fanout_scrape_failed_count "$d" tick)" = "1" ]
	[ -s "$d/tick-0.metrics" ]
	[ ! -s "$d/tick-1.metrics" ]
	# A short (truncated) body is failed too, not a legit 0.
	printf 'pilot_xds{type="ads"} 0\n' > "$CURL_BODY_DIR/30001"  # < 512 bytes
	d="${BATS_TEST_TMPDIR}/short"
	mkdir -p "$d"
	run fanout_scrape_all "$d" tick 30000 30001
	[ "$status" -ne 0 ]
	[ "$(fanout_scrape_failed_count "$d" tick)" = "1" ]
}

@test "fanout_skew_high_value: high only over FANOUT_MAX_SKEW_MS (strict >); empty or non-numeric is no skew" {
	FANOUT_MAX_SKEW_MS=1000 run fanout_skew_high_value 4043
	[ "$output" = "1" ]
	FANOUT_MAX_SKEW_MS=1000 run fanout_skew_high_value 300
	[ "$output" = "0" ]
	FANOUT_MAX_SKEW_MS=1000 run fanout_skew_high_value 1000
	[ "$output" = "0" ]
	FANOUT_MAX_SKEW_MS=1000 run fanout_skew_high_value ""
	[ "$output" = "0" ]
}

# --- restart detection (pod-set change + per-pod start-time advance) --------

_mk_podset() { # <file> <podname>...
	local f="$1"; shift
	printf '%s\n' "$@" > "$f"
}

@test "fanout_restart_status: 0 for the same pod set and start times; 1 for a pod-set change or a start time that advanced; unknown without a pod's start time or a pod set" {
	pre="${BATS_TEST_TMPDIR}/pre" post="${BATS_TEST_TMPDIR}/post" nostart="${BATS_TEST_TMPDIR}/nostart"
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-bbb
	[ "$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$POD1")" = 0 ]
	# Same pod set, but istiod-bbb's process_start_time advanced.
	[ "$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,${FIXTURES}/istiod_pod1_restarted.txt")" = 1 ]
	# A pod without a start time.
	printf 'pilot_xds{type="grpc"} 7\npilot_services 42\n' > "$nostart"
	[ "$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$nostart")" = unknown ]
	_mk_podset "$post" istiod-aaa istiod-ccc
	[ "$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$POD1")" = 1 ]
	# An empty pod-set file.
	: > "$pre"
	_mk_podset "$post" istiod-aaa
	[ "$(fanout_restart_status "$pre" "$post" "$POD0" "$POD0")" = unknown ]
}

# --- fanout_open out-arrays ---------------------------------------------------
# Fake kubectl: `get pods` lists two istiod pods; port-forward returns at once.
_fake_kubectl() {
	case " $* " in
		*" get pods "*) printf 'istiod-a\nistiod-b\n' ;;
		*) : ;;
	esac
}

@test "fanout_open: fills the out-arrays even when named pods/ports (no nameref shadowing); an unreachable pod is skipped and keeps its port gap" {
	_install_curl_stub
	base=$(fanout_ctx_port_base 0)
	echo x > "${CURL_BODY_DIR}/${base}"
	echo x > "${CURL_BODY_DIR}/$(( base + 1 ))"
	local -a pids=() ports=() pods=()
	fanout_open ctx-a 0 pids ports pods _fake_kubectl
	[ "${pods[*]}" = "istiod-a istiod-b" ]
	[ "${ports[*]}" = "${base} $(( base + 1 ))" ]
	[ "${#pids[@]}" -eq 2 ]
	# An unreachable pod is skipped and keeps its port gap.
	_install_curl_stub
	rm "${CURL_BODY_DIR}/${base}"
	FANOUT_PF_READY_ATTEMPTS=0
	pids=() ports=() pods=()
	fanout_open ctx-a 0 pids ports pods _fake_kubectl 2>/dev/null
	[ "${pods[*]}" = "istiod-b" ]
	[ "${ports[*]}" = "$(( base + 1 ))" ]
}

@test "fanout_scrape_via_api: a complete body through the pod proxy path succeeds; an empty or short body, or a failed call, fails with an empty file" {
	out="${BATS_TEST_TMPDIR}/via-api.metrics"
	_api_kubectl() {
		[[ " $* " == *" --context=ctx-a "* && " $* " == *" get --raw /api/v1/namespaces/istio-system/pods/istiod-a:15014/proxy/metrics "* ]] || return 1
		cat "$API_BODY"
	}
	API_BODY="$POD0"
	fanout_scrape_via_api ctx-a istiod-a "$out" _api_kubectl
	cmp -s "$POD0" "$out"
	API_BODY="${BATS_TEST_TMPDIR}/short"
	echo short > "$API_BODY"
	run fanout_scrape_via_api ctx-a istiod-a "$out" _api_kubectl
	assert_failure
	run fanout_scrape_via_api ctx-a istiod-b "$out" _api_kubectl
	assert_failure
	[ ! -s "$out" ]
}

@test "fanout port allocation: 5 pods x 10 contexts give 50 distinct ports above the 15014/15100 blocks, each context's block 5 wide at least" {
	# local_port = FANOUT_PF_BASE + ctx*FANOUT_CTX_STRIDE + pod
	declare -A seen=()
	collisions=0
	for ((ctx = 0; ctx < 10; ctx++)); do
		base=$(fanout_ctx_port_base "$ctx")
		for ((pod = 0; pod < 5; pod++)); do
			port=$(( base + pod ))
			if [[ -n "${seen[$port]:-}" ]]; then collisions=$((collisions + 1)); fi
			seen[$port]=1
		done
	done
	[ "$collisions" -eq 0 ]
	# 50 distinct ports, all >= 21014 (above the 15014/15100 blocks).
	[ "${#seen[@]}" -eq 50 ]
	[ "$(fanout_ctx_port_base 0)" -eq 21014 ]
	[ "$(fanout_ctx_port_base 9)" -eq 21194 ]
	# Adjacent context blocks do not overlap even at the 5-replica ceiling.
	[ $(( $(fanout_ctx_port_base 1) - $(fanout_ctx_port_base 0) )) -ge 5 ]
}
