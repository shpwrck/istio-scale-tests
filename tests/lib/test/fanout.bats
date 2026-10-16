#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/timestamp.sh"
source "${ROOT}/tests/lib/metrics.sh"
source "${ROOT}/tests/lib/fanout.sh"

FIXTURES="${ROOT}/tests/lib/test/fixtures"
POD0="${FIXTURES}/istiod_pod0.txt"
POD1="${FIXTURES}/istiod_pod1.txt"
ZERO="${FIXTURES}/istiod_zero_baseline.txt"

# --- counter aggregation ---------------------------------------------------

@test "fanout_counter_sum: sums a counter across pods" {
	# pilot_xds_pushes pod0 = 100+200+100=400, pod1 = 50+120+50=220 -> 620
	result=$(fanout_counter_sum pilot_xds_pushes "$POD0" "$POD1")
	[ "$result" = "620" ]
}

@test "fanout_counter_sum: skips an empty (failed-scrape) pod file" {
	empty=$(mktemp); : > "$empty"
	result=$(fanout_counter_sum pilot_xds_pushes "$POD0" "$empty")
	rm -f "$empty"
	[ "$result" = "400" ]
}

@test "fanout_counter_by_label_sum: sums eds across pods" {
	# eds: pod0=200, pod1=120 -> 320
	result=$(fanout_counter_by_label_sum pilot_xds_pushes type eds "$POD0" "$POD1")
	[ "$result" = "320" ]
}

@test "fanout_counter_sum: counter in no pod's scrape is unknown, not 0 (R10)" {
	result=$(fanout_counter_sum pilot_xds_pushes_renamed "$POD0" "$POD1")
	[ "$result" = "unknown" ]
	result=$(fanout_counter_by_label_sum pilot_xds_pushes_renamed type eds "$POD0" "$POD1")
	[ "$result" = "unknown" ]
}

@test "fanout_counter_sum: every scrape failed (all files empty) is unknown, not 0 (R10, PL29)" {
	e1=$(mktemp); e2=$(mktemp)
	result=$(fanout_counter_sum pilot_xds_pushes "$e1" "$e2")
	r2=$(fanout_counter_by_label_sum pilot_xds_pushes type eds "$e1" "$e2")
	rm -f "$e1" "$e2"
	[ "$result" = "unknown" ]
	[ "$r2" = "unknown" ]
}

@test "fanout_counter_sum: a pod that has not registered the counter yet adds 0" {
	other=$(mktemp)
	printf 'process_start_time_seconds 1716940800\n' > "$other"
	result=$(fanout_counter_sum pilot_xds_pushes "$POD0" "$other")
	rm -f "$other"
	[ "$result" = "400" ]
}

# --- gauge SUM vs INVARIANT (the load-bearing distinction) ------------------

@test "extract_gauge_sum: sums multiple label permutations WITHIN a pod (3+2=5)" {
	# PL12 axis 1: pod0 has pilot_xds{type=ads}=3 + pilot_xds{type=grpc}=2.
	result=$(extract_gauge_sum "$POD0" pilot_xds)
	[ "$result" = "5" ]
}

@test "extract_gauge_sum: within-pod sum for pod1 (4+3=7)" {
	result=$(extract_gauge_sum "$POD1" pilot_xds)
	[ "$result" = "7" ]
}

@test "extract_gauge (last-line) is NOT a sum — documents the trap fanout avoids" {
	# Plain extract_gauge returns ONE permutation (last line), here grpc=2, not 5.
	result=$(extract_gauge "$POD0" pilot_xds)
	[ "$result" = "2" ]
}

@test "extract_gauge_sum: missing gauge returns unknown" {
	result=$(extract_gauge_sum "$ZERO" pilot_xds)
	[ "$result" = "unknown" ]
}

@test "fanout_gauge_sum: pilot_xds SUM on BOTH axes (within-pod 5/7 -> cross-pod 12)" {
	# Each pod has TWO pilot_xds permutations; fanout must sum within (axis 1)
	# AND across pods (axis 2): (3+2) + (4+3) = 12.
	result=$(fanout_gauge_sum pilot_xds "$POD0" "$POD1")
	[ "$result" = "12" ]
}

# --- strict cross-pod gauge sum (PL29: complete or unknown) ----------------

@test "fanout_gauge_sum_strict: sums both axes like fanout_gauge_sum (5+7=12)" {
	result=$(fanout_gauge_sum_strict pilot_xds "$POD0" "$POD1")
	[ "$result" = "12" ]
}

@test "fanout_gauge_sum_strict: an empty pod file -> unknown (lenient sum would undercount to 5)" {
	empty="${BATS_TEST_TMPDIR}/empty.metrics"; : > "$empty"
	[ "$(fanout_gauge_sum_strict pilot_xds "$POD0" "$empty")" = "unknown" ]
	# The contrast that motivates the strict variant: the lenient sum drops the pod.
	[ "$(fanout_gauge_sum pilot_xds "$POD0" "$empty")" = "5" ]
}

@test "fanout_gauge_sum_strict: a missing path or no files -> unknown" {
	[ "$(fanout_gauge_sum_strict pilot_xds "$POD0" "${BATS_TEST_TMPDIR}/nope.metrics")" = "unknown" ]
	[ "$(fanout_gauge_sum_strict pilot_xds)" = "unknown" ]
}

@test "fanout_gauge_sum_strict: a body below FANOUT_MIN_SCRAPE_BYTES -> unknown" {
	short="${BATS_TEST_TMPDIR}/short.metrics"
	printf 'pilot_xds{version="1.30.5"} 3\n' > "$short"
	[ "$(fanout_gauge_sum_strict pilot_xds "$short")" = "unknown" ]
	[ "$(fanout_gauge_sum_strict pilot_xds "$POD1" "$short")" = "unknown" ]
}

@test "fanout_gauge_sum_strict: a complete body with no pilot_xds series counts as 0" {
	# A replica with no connected proxies emits no pilot_xds series at all.
	idle="${BATS_TEST_TMPDIR}/idle.metrics"
	grep -v '^pilot_xds[{ ]' "$POD0" > "$idle"
	(( $(wc -c < "$idle") >= FANOUT_MIN_SCRAPE_BYTES ))
	[ "$(fanout_gauge_sum_strict pilot_xds "$idle")" = "0" ]
	[ "$(fanout_gauge_sum_strict pilot_xds "$idle" "$POD1")" = "7" ]
}

@test "fanout_gauge_sum_strict: live label shape (version=) with mixed proxy versions" {
	live="${BATS_TEST_TMPDIR}/live.metrics"
	grep -v '^pilot_xds[{ ]' "$POD0" > "$live"
	printf 'pilot_xds{version="1.30.5"} 9\npilot_xds{version="1.29.0"} 1\n' >> "$live"
	[ "$(fanout_gauge_sum_strict pilot_xds "$live")" = "10" ]
	[ "$(fanout_gauge_sum_strict pilot_xds "$live" "$POD1")" = "17" ]
}

# --- histogram bucket-sum -> delta_histogram_p99 ---------------------------

@test "fanout_merge_histogram + delta_histogram_p99: merged buckets land p99 on the expected bucket" {
	# Merged convergence buckets (pod0+pod1) against a zero baseline:
	#   le=0.5:40  le=1:90  le=3:120  +Inf:120 ; count=120
	# target = 120 * 0.99 = 118.8 -> crosses in the [1,3] bucket (cum 90->120).
	# Linear interpolation: 1 + (3-1)*(118.8-90)/(120-90) = 2.92s -> 2920.00ms
	# (was 3000.00 when this emitted the bucket ceiling; FINDING #5 interpolation fix)
	merged=$(mktemp)
	fanout_merge_histogram pilot_proxy_convergence_time "$merged" "$POD0" "$POD1"
	result=$(delta_histogram_p99 "$ZERO" "$merged" pilot_proxy_convergence_time)
	rm -f "$merged"
	[ "$result" = "2920.00" ]
}

@test "fanout_merge_histogram: merged _count equals the sum of per-pod counts" {
	merged=$(mktemp)
	fanout_merge_histogram pilot_proxy_convergence_time "$merged" "$POD0" "$POD1"
	# pod0 count 50 + pod1 count 70 = 120
	cnt=$(awk '/_count /{print $2}' "$merged")
	rm -f "$merged"
	[ "$cnt" = "120" ]
}

@test "fanout_merge_histogram: a single pod merges to itself (identity for one replica)" {
	merged=$(mktemp)
	fanout_merge_histogram pilot_proxy_convergence_time "$merged" "$POD0"
	result=$(delta_histogram_p99 "$ZERO" "$merged" pilot_proxy_convergence_time)
	rm -f "$merged"
	# pod0 alone: count 50, target 49.5; crosses in [0.5,1] (cum 30->50).
	# Linear interpolation: 0.5 + (1-0.5)*(49.5-30)/(50-30) = 0.9875s -> 987.50ms
	# (was 1000.00 when this emitted the bucket ceiling; FINDING #5 interpolation fix)
	[ "$result" = "987.50" ]
}

# --- empty / incomplete scrape detection -----------------------------------
# Stub curl so fanout_scrape_all can be exercised without a live istiod. The
# stub maps a port to a canned body via $CURL_BODY_DIR/<port>; a missing file
# simulates a connection failure (curl exits non-zero, empty out file).

_install_curl_stub() {
	CURL_BODY_DIR="$(mktemp -d)"
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

@test "fanout_scrape_all: full body on every pod -> failed=0, returns 0" {
	_install_curl_stub
	# Two pods with full multi-KB-ish bodies.
	cp "$POD0" "$CURL_BODY_DIR/30000"
	cp "$POD1" "$CURL_BODY_DIR/30001"
	d=$(mktemp -d)
	run fanout_scrape_all "$d" tick 30000 30001
	[ "$status" -eq 0 ]
	[ "$(fanout_scrape_failed_count "$d" tick)" = "0" ]
	rm -rf "$d" "$CURL_BODY_DIR"
}

@test "fanout_scrape_all: a dead PF (no body) -> failed=1, returns non-zero" {
	_install_curl_stub
	cp "$POD0" "$CURL_BODY_DIR/30000"
	# port 30001 has NO canned body -> stub returns 7 (connection failure)
	d=$(mktemp -d)
	run fanout_scrape_all "$d" tick 30000 30001
	[ "$status" -ne 0 ]
	[ "$(fanout_scrape_failed_count "$d" tick)" = "1" ]
	# The reachable pod's scrape is intact; the dead pod's file is empty.
	[ -s "$d/tick-0.metrics" ]
	[ ! -s "$d/tick-1.metrics" ]
	rm -rf "$d" "$CURL_BODY_DIR"
}

@test "fanout_scrape_all: short/truncated body counts as failed (not a legit 0)" {
	_install_curl_stub
	cp "$POD0" "$CURL_BODY_DIR/30000"
	printf 'pilot_xds{type="ads"} 0\n' > "$CURL_BODY_DIR/30001"  # < 512 bytes
	d=$(mktemp -d)
	run fanout_scrape_all "$d" tick 30000 30001
	[ "$status" -ne 0 ]
	[ "$(fanout_scrape_failed_count "$d" tick)" = "1" ]
	rm -rf "$d" "$CURL_BODY_DIR"
}

# --- O3: scrape-skew ceiling (incoherent-snapshot tagging) ------------------
# fanout_scrape_all stamps per-pod COMPLETION timestamps in backgrounded subshells
# (so the absolute spread is not deterministic in a unit test), but it MUST persist
# whatever skew it computed to <prefix>.skew so a caller that discards stdout can
# read it back.

@test "fanout_scrape_all: persists the echoed batch skew to <prefix>.skew" {
	_install_curl_stub
	cp "$POD0" "$CURL_BODY_DIR/30000"
	cp "$POD1" "$CURL_BODY_DIR/30001"
	d=$(mktemp -d)
	skew=$(fanout_scrape_all "$d" tick 30000 30001)
	# The persisted sidecar matches the value echoed on stdout (whatever it was).
	[ "$(cat "$d/tick.skew")" = "$skew" ]
	rm -rf "$d" "$CURL_BODY_DIR"
}

# --- skew gate (fanout_skew_high_value, strict ">") -------------------------

@test "fanout_skew_high_value: 4043ms over the 1000ms default -> 1" {
	FANOUT_MAX_SKEW_MS=1000 run fanout_skew_high_value 4043
	[ "$output" = "1" ]
}

@test "fanout_skew_high_value: 300ms under the ceiling -> 0" {
	FANOUT_MAX_SKEW_MS=1000 run fanout_skew_high_value 300
	[ "$output" = "0" ]
}

@test "fanout_skew_high_value: exactly at the ceiling is NOT high (strict >)" {
	FANOUT_MAX_SKEW_MS=1000 run fanout_skew_high_value 1000
	[ "$output" = "0" ]
}

@test "fanout_skew_high_value: empty/non-numeric value -> 0 (treated as no skew)" {
	FANOUT_MAX_SKEW_MS=1000 run fanout_skew_high_value ""
	[ "$output" = "0" ]
}

# --- restart detection (pod-set change + per-pod start-time advance) --------

_mk_podset() { # <file> <podname>...
	local f="$1"; shift
	printf '%s\n' "$@" > "$f"
}

@test "fanout_restart_status: identical pod set + start times -> 0" {
	pre=$(mktemp); post=$(mktemp)
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-bbb
	result=$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$POD1")
	rm -f "$pre" "$post"
	[ "$result" = "0" ]
}

@test "fanout_restart_status: pod-set change -> 1" {
	pre=$(mktemp); post=$(mktemp)
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-ccc
	result=$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$POD1")
	rm -f "$pre" "$post"
	[ "$result" = "1" ]
}

@test "fanout_restart_status: per-pod start-time advance -> 1" {
	pre=$(mktemp); post=$(mktemp)
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-bbb
	# Same pod set, but istiod-bbb's process_start_time advanced (restarted file).
	result=$(fanout_restart_status "$pre" "$post" \
		"$POD0,$POD1" "$POD0,${FIXTURES}/istiod_pod1_restarted.txt")
	rm -f "$pre" "$post"
	[ "$result" = "1" ]
}

@test "fanout_restart_status: missing start time on a pod -> unknown" {
	pre=$(mktemp); post=$(mktemp); nostart=$(mktemp)
	printf 'pilot_xds{type="grpc"} 7\npilot_services 42\n' > "$nostart"
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-bbb
	result=$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$nostart")
	rm -f "$pre" "$post" "$nostart"
	[ "$result" = "unknown" ]
}

@test "fanout_restart_status: missing podset file -> unknown" {
	pre=$(mktemp); post=$(mktemp)
	: > "$pre"  # empty
	_mk_podset "$post" istiod-aaa
	result=$(fanout_restart_status "$pre" "$post" "$POD0" "$POD0")
	rm -f "$pre" "$post"
	[ "$result" = "unknown" ]
}

# --- fanout_open out-arrays ---------------------------------------------------
# Fake kubectl: `get pods` lists two istiod pods; port-forward returns at once.
_fake_kubectl() {
	case " $* " in
		*" get pods "*) printf 'istiod-a\nistiod-b\n' ;;
		*) : ;;
	esac
}

@test "fanout_open: out-arrays named pods/ports are filled (no nameref shadowing)" {
	_install_curl_stub
	base=$(fanout_ctx_port_base 0)
	echo x > "${CURL_BODY_DIR}/${base}"
	echo x > "${CURL_BODY_DIR}/$(( base + 1 ))"
	local -a pids=() ports=() pods=()
	fanout_open ctx-a 0 pids ports pods _fake_kubectl
	rm -rf "$CURL_BODY_DIR"
	[ "${pods[*]}" = "istiod-a istiod-b" ]
	[ "${ports[*]}" = "${base} $(( base + 1 ))" ]
	[ "${#pids[@]}" -eq 2 ]
}

@test "fanout_open: an unreachable pod is skipped and keeps its port gap" {
	_install_curl_stub
	base=$(fanout_ctx_port_base 0)
	echo x > "${CURL_BODY_DIR}/$(( base + 1 ))"
	FANOUT_PF_READY_ATTEMPTS=0
	local -a pids=() ports=() pods=()
	fanout_open ctx-a 0 pids ports pods _fake_kubectl 2>/dev/null
	rm -rf "$CURL_BODY_DIR"
	[ "${pods[*]}" = "istiod-b" ]
	[ "${ports[*]}" = "$(( base + 1 ))" ]
}

# --- port allocation (collision-free for 5 pods x 10 contexts) -------------

@test "fanout port allocation: 5 pods x 10 contexts produce no overlapping ports" {
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
}

@test "fanout_ctx_port_base: stride leaves headroom for 5-replica pin + restart" {
	# Adjacent context blocks must not overlap even at the 5-replica ceiling.
	b0=$(fanout_ctx_port_base 0)
	b1=$(fanout_ctx_port_base 1)
	[ $(( b1 - b0 )) -ge 5 ]
}
