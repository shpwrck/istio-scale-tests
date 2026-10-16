#!/usr/bin/env bats
# tests/lib/istiod-diag.sh (istiod restart evidence): one case per cause over a fake
# kubectl and hand-written fixtures, the cost, dedup, budget and deadline bounds, PL40
# containment, redaction, the report renderer, the ISTIOD_DIAG_* --config keys, the
# controlplane window hook, and the entrypoints that call the capture (dataplane 002,
# churn 002) plus the tuning comparison that must not read the index (PL33).
# Fixtures use documentation addresses (192.0.2.0/24, 2001:db8::/32) and made-up node
# names (worker-node-a/b): never real cluster data.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/config.sh"
source "${ROOT}/tests/lib/reach.sh"
source "${ROOT}/tests/lib/istiod-diag.sh"

FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
SUITES=(controlplane dataplane churn churn-dataplane propagation)

# _fake_kubectl: log the call, answer from the FAKE_* fixtures.
_fake_kubectl() {
	printf '%s\n' "$*" >> "$CALLS"
	[[ -z "${FAKE_DIE:-}" ]] || die "fake kubectl died"
	if [[ -n "${FAKE_FAIL_ALL:-}" ]]; then
		echo "error: Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout" >&2
		return 1
	fi
	case " $* " in
	*" get pods "*) cat "$FAKE_PODS" ;;
	*" -n istio-system get events "*) cat "${FAKE_EVENTS:-${FX}/empty_list.json}" ;;
	*" -n default get events "*) cat "${FX}/empty_list.json" ;;
	*" get deploy,rs "*) cat "${FAKE_DEPLOY_RS:-${FX}/empty_list.json}" ;;
	*" get node "*) cat "${FX}/node_ready.json" ;;
	*" logs "*" --previous "*)
		if [[ -n "${FAKE_PREV_FAIL:-}" ]]; then
			echo 'previous terminated container "discovery" in pod "istiod-abc-x1" not found' >&2
			return 1
		fi
		cat "${FAKE_LOG:-${FX}/log_secrets.txt}"
		;;
	*" logs "*) cat "${FAKE_LOG:-${FX}/log_secrets.txt}" ;;
	*) return 1 ;;
	esac
}

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	D="${RES}/istiod-diag-RUN1"
	export CALLS="${BATS_TEST_TMPDIR}/calls.log"
	: > "$CALLS"
	PODSET="${BATS_TEST_TMPDIR}/pre.podset"
	printf 'istiod-abc-x1\n' > "$PODSET"
	PRE="${BATS_TEST_TMPDIR}/pre-0.metrics"
	cp "${FX}/pre_metrics.txt" "$PRE"
	echo 1716940800123456789 > "${BATS_TEST_TMPDIR}/pre-0.ts"  # ns, 2024-05-29T00:00:00Z
	FAKE_PODS="${FX}/pods_oom.json"
}

# _cap [trigger] [tag]: one capture of ctx-a into $D.
_cap() { istiod_diag_capture "$D" "${2:-iter1}" ctx-a "${1:-1}" "$PODSET" "$PRE" _fake_kubectl; }

# _col <column> [pod] [context]: a column of the last index row (of <pod> and <context>
# when given), by header name.
_col() {
	awk -F'\t' -v c="$1" -v pod="${2:-}" -v ctx="${3:-}" '
		/^#/ { next }
		$1 == "captured_at" { for (i = 1; i <= NF; i++) ix[$i] = i; next }
		(pod == "" || $(ix["pod"]) == pod) && (ctx == "" || $(ix["context"]) == ctx) { v = $(ix[c]) }
		END { print v }' "${D}/index.tsv"
}

# _rows: the number of index data rows.
_rows() { awk -F'\t' '!/^#/ && $1 != "captured_at" { n++ } END { print n + 0 }' "${D}/index.tsv"; }

# --- one case per cause ---

@test "OOM in place: restarted_in_place/oom_killed, limit and pre-window memory, bounded --previous fetch" {
	run _cap
	assert_success
	[ "$(_col change)" = restarted_in_place ]
	[ "$(_col cause)" = oom_killed ]
	[ "$(_col exit_code)" = 137 ]
	[ "$(_col signal)" = 9 ]
	[ "$(_col term_reason)" = OOMKilled ]
	[ "$(_col restart_count)" = 1 ]
	[ "$(_col started_at)" = 2024-05-29T00:10:00Z ]
	[ "$(_col finished_at)" = 2024-05-29T00:09:58Z ]
	[ "$(_col mem_limit_mi)" = 3072 ]
	[ "$(_col rss_pre_mi)" = 300 ]
	[ "$(_col heap_inuse_pre_mi)" = 200 ]
	[ "$(_col goroutines_pre)" = 1234 ]
	[ "$(_col proxies_pre)" = 5 ]
	[ "$(_col pre_scrape_at)" = 2024-05-29T00:00:00Z ]
	[ "$(_col node_ready_at)" = 2026-10-13T12:23:08Z ]
	ev="$(_col evidence)"
	[ "$ev" = 001-iter1-ctx-a ]
	grep -q -- '-n istio-system logs istiod-abc-x1 -c discovery .*--previous --tail=5000 --limit-bytes=8388608' "$CALLS"
	[ -s "${D}/${ev}/istiod-abc-x1.previous.log.gz" ]
	[ -s "${D}/${ev}/istiod-abc-x1.pre.metrics.gz" ]
	grep -q 'container_memory_working_set_bytes{namespace="istio-system",pod="istiod-abc-x1",container="discovery"}' "${D}/${ev}/summary.md"
	# The pod projection keeps no env, managedFields or IPs.
	[ -s "${D}/${ev}/pods.json" ]
	run grep -E 'do-not-copy|managedFields|podIP|hostIP' "${D}/${ev}/pods.json"
	assert_failure
	grep -qx '# ISTIOD_DIAG_SCHEMA=1' "${D}/index.tsv"
	grep -qx '# RUN_ID=RUN1' "${D}/index.tsv"
	grep -qx '# ISTIOD_DIAG_LOG_BYTES=1048576' "${D}/index.tsv"
	[ -s "${D}/README.md" ]
	[ "$(_rows)" -eq 1 ]
	# The folder ignores itself, so even a tracked --output-dir cannot commit the raw evidence.
	grep -qx '\*' "${D}/.gitignore"
	git init -q "$RES"
	git -C "$RES" check-ignore -q "istiod-diag-RUN1/${ev}/istiod-abc-x1.previous.log.gz"
	git -C "$RES" check-ignore -q "istiod-diag-RUN1/index.tsv"
}

@test "pod deleted: replaced_gone/deleted plus new_pod/replacement; no log call for the gone pod" {
	FAKE_PODS="${FX}/pods_deleted.json" FAKE_EVENTS="${FX}/events_deleted.json" run _cap
	assert_success
	[ "$(_col change istiod-abc-x1)" = replaced_gone ]
	[ "$(_col cause istiod-abc-x1)" = deleted ]
	[ "$(_col rs_changed istiod-abc-x1)" = 0 ]
	[ "$(_col rss_pre_mi istiod-abc-x1)" = 300 ]
	[ "$(_col change istiod-abc-y2)" = new_pod ]
	[ "$(_col cause istiod-abc-y2)" = replacement ]
	run grep -q 'logs istiod-abc-x1' "$CALLS"
	assert_failure
	grep -q -- 'logs istiod-abc-y2 -c discovery .*--limit-bytes=262144' "$CALLS"
	ev="$(_col evidence istiod-abc-y2)"
	[ -s "${D}/${ev}/istiod-abc-y2.startup.log.gz" ]
	grep -q $'\tKilling\tPod\tistiod-abc-x1\t' "${D}/${ev}/events.tsv"
	# Only istiod objects' events are kept.
	run grep -q 'istio-ingressgateway' "${D}/${ev}/events.tsv"
	assert_failure
}

@test "rollout: the new pod has another ReplicaSet; the gone pod's limit comes from its old ReplicaSet" {
	FAKE_PODS="${FX}/pods_rollout.json" FAKE_DEPLOY_RS="${FX}/deploy_rs_rollout.json" run _cap
	assert_success
	[ "$(_col cause istiod-abc-x1)" = rollout ]
	[ "$(_col rs_changed istiod-abc-x1)" = 1 ]
	[ "$(_col mem_limit_mi istiod-abc-x1)" = 3072 ]
	[ "$(_col cause istiod-def-z3)" = rollout ]
	[ "$(_col rs_changed istiod-def-z3)" = 1 ]
	[ "$(_col mem_limit_mi istiod-def-z3)" = 512 ]
	ev="$(_col evidence istiod-def-z3)"
	[ "$(jq -r '.[] | select(.kind == "Deployment") | .revision' "${D}/${ev}/deploy-rs.json")" = 22 ]
	run grep -q 'istio-ingressgateway' "${D}/${ev}/deploy-rs.json"
	assert_failure
}

@test "evicted: replaced_failed/evicted, the old pod's own log, IPs, hosts and node names masked in the note" {
	FAKE_PODS="${FX}/pods_evicted.json" FAKE_EVENTS="${FX}/events_evicted.json" run _cap
	assert_success
	[ "$(_col change istiod-abc-x1)" = replaced_failed ]
	[ "$(_col cause istiod-abc-x1)" = evicted ]
	[ "$(_col exit_code istiod-abc-x1)" = 137 ]
	note="$(_col note istiod-abc-x1)"
	[[ "$note" == *"low on resource: memory"* ]]
	[[ "$note" == *"<ip>"* && "$note" == *"<host>"* && "$note" == *"<node>"* ]]
	[[ "$note" != *192.0.2* && "$note" != *example.internal* && "$note" != *worker-node* ]]
	# The old pod still exists: its current log (no --previous).
	grep -q -- 'logs istiod-abc-x1 -c discovery --request-timeout=15 --tail=5000 --limit-bytes=8388608$' "$CALLS"
	[ "$(_col cause istiod-abc-y2)" = replacement ]
}

@test "probe kill: an Unhealthy liveness event plus Killing gives probe_kill even with exit 0" {
	FAKE_PODS="${FX}/pods_probe.json" FAKE_EVENTS="${FX}/events_probe.json" run _cap
	assert_success
	[ "$(_col change)" = restarted_in_place ]
	[ "$(_col cause)" = probe_kill ]
	[ "$(_col exit_code)" = 0 ]
	# Without the events the same restart is a plain exit.
	D="${RES}/istiod-diag-RUN2" FAKE_PODS="${FX}/pods_probe.json" run _cap
	[ "$(D="${RES}/istiod-diag-RUN2" _col cause)" = exited ]
}

@test "crash: exit 2 in a crash loop gives crash, with the sanitized panic line in the note" {
	FAKE_PODS="${FX}/pods_crash.json" run _cap
	assert_success
	[ "$(_col change)" = restarted_in_place ]
	[ "$(_col cause)" = crash ]
	[ "$(_col exit_code)" = 2 ]
	[ "$(_col started_at)" = N/A ]
	note="$(_col note)"
	[[ "$note" == *"panic: runtime error: invalid memory address or nil pointer dereference"* ]]
	[[ "$note" == *"waiting: CrashLoopBackOff"* ]]
	[[ "$note" != *192.0.2* ]]
}

@test "node restart (lab case): empty lastState, node Ready 2 s before the start, no previous log, still 0" {
	FAKE_PODS="${FX}/pods_node_restart.json" FAKE_PREV_FAIL=1 run _cap
	assert_success
	[ "$(_col change)" = restarted_in_place ]
	[ "$(_col cause)" = node_restart ]
	[ "$(_col restart_count)" = 2 ]
	[ "$(_col node_ready_at)" = 2026-10-13T12:23:08Z ]
	[[ "$(_col note)" == *"previous log unavailable: previous terminated container"*"not found"* ]]
	ev="$(_col evidence)"
	[ -s "${D}/${ev}/istiod-abc-x1.previous.log.unavailable" ]
	[ -s "${D}/${ev}/node-1.json" ]
	[ "$(jq -r '.boot_id' "${D}/${ev}/node-1.json")" = 00000000-0000-0000-0000-000000000001 ]
	run grep -q '192.0.2' "${D}/${ev}/node-1.json"
	assert_failure
}

# --- cost, dedup, budget, deadline, size ---

@test "unknown trigger, nothing changed: exactly one kubectl call and a no_restart_found row" {
	FAKE_PODS="${FX}/pods_steady.json" run _cap unknown
	assert_success
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	grep -q -- '-n istio-system get pods -l app=istiod -o json --request-timeout=15' "$CALLS"
	[ "$(_col trigger)" = unknown ]
	[ "$(_col change)" = no_change ]
	[ "$(_col cause)" = no_restart_found ]
	[ "$(_col evidence)" = - ]
	[ -z "$(ls -d "${D}"/[0-9][0-9][0-9]-* 2>/dev/null)" ]
}

@test "dedup: the same restart twice gets a row, not a second folder, and only the pod list" {
	_cap
	n1="$(wc -l < "$CALLS")"
	run _cap iter2
	assert_success
	[ "$(_col evidence)" = already_captured ]
	[ "$(_col cause)" = oom_killed ]
	[ "$(($(wc -l < "$CALLS") - n1))" -eq 1 ]
	[ "$(ls -d "${D}"/[0-9][0-9][0-9]-* | wc -l)" -eq 1 ]
}

@test "budget: ISTIOD_DIAG_MAX_CAPTURES=1 leaves a second restart with a row only (budget_exhausted)" {
	export ISTIOD_DIAG_MAX_CAPTURES=1
	_cap
	n1="$(wc -l < "$CALLS")"
	FAKE_PODS="${FX}/pods_crash.json" run _cap iter2
	assert_success
	[ "$(_col evidence)" = budget_exhausted ]
	[ "$(_col cause)" = crash ]
	[ "$(($(wc -l < "$CALLS") - n1))" -eq 1 ]
	[ "$(ls -d "${D}"/[0-9][0-9][0-9]-* | wc -l)" -eq 1 ]
}

@test "deadline: ISTIOD_DIAG_MAX_SEC=0 runs only the pod list and marks the row skipped_deadline" {
	ISTIOD_DIAG_MAX_SEC=0 run _cap
	assert_success
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	[ "$(_col evidence)" = skipped_deadline ]
	[ "$(_col cause)" = oom_killed ]
	[ -z "$(ls -d "${D}"/[0-9][0-9][0-9]-* 2>/dev/null)" ]
}

@test "size bound: a 5 MiB log keeps its last ISTIOD_DIAG_LOG_BYTES (marker line kept); the pre scrape stays gzipped" {
	big="${BATS_TEST_TMPDIR}/big.log"
	awk 'BEGIN { for (i = 0; i < 70000; i++) printf "%08d filler line for the size bound test, 192.0.2.99 ..................\n", i; print "FINAL-MARKER-LINE" }' > "$big"
	[ "$(wc -c < "$big")" -gt 5000000 ]
	ISTIOD_DIAG_LOG_BYTES=262144 FAKE_LOG="$big" run _cap
	assert_success
	ev="$(_col evidence)"
	kept="${BATS_TEST_TMPDIR}/kept.log"
	gzip -dc "${D}/${ev}/istiod-abc-x1.previous.log.gz" > "$kept"
	[ "$(wc -c < "$kept")" -le 262144 ]
	[ "$(tail -n 1 "$kept")" = FINAL-MARKER-LINE ]
	run grep -c '192.0.2.99' "$kept"
	[ "$output" = 0 ]
	gzip -dc "${D}/${ev}/istiod-abc-x1.pre.metrics.gz" | grep -q '^process_start_time_seconds 1.7169408e+09$'
	grep -qx '# ISTIOD_DIAG_LOG_BYTES=262144' "${D}/index.tsv"
}

@test "ISTIOD_DIAG_REQUEST_TIMEOUT goes to kubectl unchanged (1ms stays 1ms); a bad one warns and uses 15" {
	ISTIOD_DIAG_REQUEST_TIMEOUT=1ms run _cap
	assert_success
	grep -q -- '--request-timeout=1ms$' "$CALLS"
	run grep -q -- '1mss' "$CALLS"
	assert_failure
	: > "$CALLS"
	D="${RES}/istiod-diag-RUN2" ISTIOD_DIAG_REQUEST_TIMEOUT='1 ms' run --separate-stderr _cap
	assert_success
	[[ "$stderr" == *"ISTIOD_DIAG_REQUEST_TIMEOUT='1 ms' is not a kubectl --request-timeout"* ]]
	grep -q -- '--request-timeout=15 ' "$CALLS"
}

# --- safety (PL40) and redaction ---

@test "containment: every call failing under set -euo pipefail and an ERR trap -> capture_failed row, rc 0, run continues" {
	export -f _fake_kubectl
	export FX D PODSET PRE ROOT FAKE_PODS
	FAKE_FAIL_ALL=1 run --separate-stderr bash -c '
		set -euo pipefail
		trap "echo ERR-TRAP-FIRED >&2" ERR
		source "$ROOT/tests/lib/common.sh"
		source "$ROOT/tests/lib/reach.sh"
		source "$ROOT/tests/lib/istiod-diag.sh"
		istiod_diag_capture "$D" iter1 ctx-a 1 "$PODSET" "$PRE" _fake_kubectl
		echo "rc=$? CONTINUED"'
	assert_success
	assert_output "rc=0 CONTINUED"
	[[ "$stderr" != *ERR-TRAP-FIRED* ]]
	[[ "$stderr" == *"change=capture_failed"* ]]
	[ "$(_col change)" = capture_failed ]
	[ "$(_col evidence)" = capture_failed ]
	note="$(_col note)"
	[[ "$note" == *"istiod pod list failed: error: Unable to connect to the server"* ]]
	[[ "$note" == *"<ip>"* && "$note" != *192.0.2* ]]
}

@test "containment: a die inside the helper (subshell) -> capture_failed with its reason, rc 0" {
	export -f _fake_kubectl
	export FX D PODSET PRE ROOT FAKE_PODS
	FAKE_DIE=1 run --separate-stderr bash -c '
		set -euo pipefail
		source "$ROOT/tests/lib/common.sh"
		source "$ROOT/tests/lib/reach.sh"
		source "$ROOT/tests/lib/istiod-diag.sh"
		istiod_diag_capture "$D" iter1 ctx-a unknown "$PODSET" "$PRE" _fake_kubectl
		echo "rc=$? CONTINUED"'
	assert_success
	assert_output "rc=0 CONTINUED"
	[ "$(_col change)" = capture_failed ]
	[[ "$(_col note)" == *"fake kubectl died"* ]]
}

@test "containment: an unwritable results dir or a missing reach.sh warns and returns 0" {
	touch "${BATS_TEST_TMPDIR}/afile"
	run --separate-stderr istiod_diag_capture "${BATS_TEST_TMPDIR}/afile/istiod-diag-x" iter1 ctx-a 1 "$PODSET" "$PRE" _fake_kubectl
	assert_success
	[[ "$stderr" == *"cannot create"* ]]
	[ ! -s "$CALLS" ]
	run --separate-stderr bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/istiod-diag.sh"; istiod_diag_capture "$2" t c 1 "" "" kubectl; echo "rc=$?"' _ "$ROOT" "$D"
	assert_output "rc=0"
	[[ "$stderr" == *"reach.sh is not sourced"* ]]
}

@test "redaction: index, summaries and README hold no IP, host or node name; raw logs mask tokens, JWTs and IPs" {
	_cap
	FAKE_PODS="${FX}/pods_evicted.json" FAKE_EVENTS="${FX}/events_evicted.json" _cap unknown iter2
	FAKE_PODS="${FX}/pods_crash.json" _cap 1 iter3
	FAKE_PODS="${FX}/pods_node_restart.json" FAKE_PREV_FAIL=1 _cap 1 iter4
	local f
	for f in "${D}/index.tsv" "${D}/README.md" "${D}"/*/summary.md; do
		run grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|2001:db8|worker-node|example\.internal' "$f"
		assert_failure
	done
	log="${BATS_TEST_TMPDIR}/raw.log"
	gzip -dc "${D}/001-iter1-ctx-a/istiod-abc-x1.previous.log.gz" > "$log"
	run grep -E 's3cr3t-token|eyJhbGciOiJSUzI1NiJ9|192\.0\.2\.40|2001:db8' "$log"
	assert_failure
	grep -q 'Bearer <token>' "$log"
	grep -q '<jwt>' "$log"
	grep -q 'sidecar~<ip>~' "$log"
	grep -q 'peer <ip>:15012' "$log"
	# Raw events keep the host (stack traces and events need it) but mask the IPs.
	run grep -E '192\.0\.2|2001:db8' "${D}"/002-iter2-ctx-a/events.tsv
	assert_failure
}

@test "kill switch: ISTIOD_DIAG_ENABLED=0 makes no call and writes nothing" {
	ISTIOD_DIAG_ENABLED=0 run _cap
	assert_success
	[ ! -s "$CALLS" ]
	[ ! -e "$D" ]
}

@test "PL29: an empty or 100-byte pre-window scrape gives N/A memory, never 0 (and no start time to time it)" {
	: > "$PRE"
	run _cap
	[ "$(_col rss_pre_mi)" = N/A ]
	[ "$(_col heap_inuse_pre_mi)" = N/A ]
	[ "$(_col change)" = restarted_untimed ]
	[[ "$(_col note)" == *"no pre-window start time"* ]]
	head -c 100 "${FX}/pre_metrics.txt" > "$PRE"
	D="${RES}/istiod-diag-RUN2" run _cap
	[ "$(D="${RES}/istiod-diag-RUN2" _col rss_pre_mi)" = N/A ]
	[ "$(D="${RES}/istiod-diag-RUN2" _col proxies_pre)" = N/A ]
}

@test "no pod set (no Running istiod at the start): no_pods row without pods, restarted_untimed with restarts" {
	FAKE_PODS="${FX}/empty_list.json" run istiod_diag_capture "$D" m2 ctx-a no_running_pods "" "" _fake_kubectl
	assert_success
	[ "$(_col trigger)" = no_running_pods ]
	[ "$(_col change)" = no_pods ]
	[ "$(_col cause)" = no_istiod_pods ]
	run istiod_diag_capture "$D" m2 ctx-a unknown "" "" _fake_kubectl
	[ "$(_col change istiod-abc-x1)" = restarted_untimed ]
	[ "$(_col cause istiod-abc-x1)" = oom_killed ]
}

@test "tag and folder names carry no ':' or '+' (NTFS copies)" {
	run istiod_diag_capture "$D" 'w2026-10-13T12:23:10+00:00' 'default/api-x:6443/kube:admin' 1 "$PODSET" "$PRE" _fake_kubectl
	assert_success
	ev="$(_col evidence)"
	[[ "$ev" != *:* && "$ev" != *+* && "$ev" != */* ]]
	[ -d "${D}/${ev}" ]
	[[ "$(_col tag)" != *:* ]]
	run istiod_diag_dir /x/y/latency-R1.tsv 'R1:+'
	assert_output "/x/y/istiod-diag-R1__"
}

# --- report ---

@test "istiod_diag_report: tally by cause over two index files in md, text and json; csv prints nothing" {
	_cap
	_cap 1 iter2  # a repeat row: listed apart, not tallied
	D="${RES}/sweep-x/istiod-diag-RUN2" FAKE_PODS="${FX}/pods_deleted.json" FAKE_EVENTS="${FX}/events_deleted.json" _cap
	run istiod_diag_report json "$RES"
	assert_success
	[ "$(jq -c '[.index_files, .rows, .repeat_rows, .untimed_rows]' <<<"$output")" = '[2,4,1,0]' ]
	[ "$(jq -c '.by_cause' <<<"$output")" = '{"deleted":1,"oom_killed":1,"replacement":1}' ]
	[ "$(jq -c '.untimed_by_cause' <<<"$output")" = '{}' ]
	[ "$(jq -c '.captures[0] | [.run_id, .cause, .evidence, .repeat, .untimed]' <<<"$output")" = '["RUN1","oom_killed","istiod-diag-RUN1/001-iter1-ctx-a",false,false]' ]
	[ "$(jq -c '.captures[1] | [.evidence, .repeat]' <<<"$output")" = '["already_captured",true]' ]
	run istiod_diag_report md "$RES"
	assert_output --partial "## istiod restart diagnostics"
	assert_output --partial "4 row(s) from 2 \`istiod-diag-*/index.tsv\` file(s); by cause: oom_killed=1, deleted=1, replacement=1."
	assert_output --partial "1 repeat row(s) of an already listed restart are not listed."
	assert_output --partial "| RUN1 | ctx-a | iter1 | istiod-abc-x1 | restarted_in_place | oom_killed | 137 | 300/3072 | istiod-diag-RUN1/001-iter1-ctx-a |"
	refute_output --partial "already_captured"
	run istiod_diag_report text "$RES"
	assert_output --partial "istiod restart diagnostics: 4 row(s) from 2 istiod-diag-*/index.tsv file(s)"
	assert_output --partial "RUN2 | ctx-a | iter1 | istiod-abc-y2 | new_pod | replacement | exit=N/A | rss_pre/limit=N/A/3072 Mi | sweep-x/istiod-diag-RUN2/001-iter1-ctx-a"
	run istiod_diag_report csv "$RES"
	assert_success
	assert_output ""
}

@test "istiod_diag_report: two runs with the same tag and folder name stay apart (run_id, evidence path)" {
	_cap 1 iter1
	D="${RES}/istiod-diag-RUN2" FAKE_PODS="${FX}/pods_crash.json" _cap 1 iter1
	[ -d "${RES}/istiod-diag-RUN1/001-iter1-ctx-a" ]
	[ -d "${RES}/istiod-diag-RUN2/001-iter1-ctx-a" ]
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.captures[] | [.run_id, .tag, .evidence, .cause]]' <<<"$output")" = '[["RUN1","iter1","istiod-diag-RUN1/001-iter1-ctx-a","oom_killed"],["RUN2","iter1","istiod-diag-RUN2/001-iter1-ctx-a","crash"]]' ]
	[ "$(jq -c '.by_cause' <<<"$output")" = '{"crash":1,"oom_killed":1}' ]
	run istiod_diag_report md "$RES"
	assert_output --partial "| RUN1 | ctx-a | iter1 | istiod-abc-x1 | restarted_in_place | oom_killed |"
	assert_output --partial "| istiod-diag-RUN1/001-iter1-ctx-a |"
	assert_output --partial "| RUN2 | ctx-a | iter1 | istiod-abc-x1 | restarted_in_place | crash |"
	assert_output --partial "| istiod-diag-RUN2/001-iter1-ctx-a |"
	run istiod_diag_report text "$RES"
	assert_output --partial "  RUN1 | ctx-a | iter1 | istiod-abc-x1 |"
	assert_output --partial "  RUN2 | ctx-a | iter1 | istiod-abc-x1 |"
	# A trailing slash on the results dir gives the same relative paths.
	run istiod_diag_report json "${RES}/"
	[ "$(jq -r '.captures[1].evidence' <<<"$output")" = istiod-diag-RUN2/001-iter1-ctx-a ]
}

@test "istiod_diag_report: an untimed restart (failed pre-window scrape, old OOM) stays out of the tally" {
	: > "$PRE"  # the pre-window scrape failed: no start time to place the restart
	_cap unknown
	[ "$(_col change)" = restarted_untimed ]
	[ "$(_col cause)" = oom_killed ]
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.rows, .untimed_rows, .repeat_rows]' <<<"$output")" = '[1,1,0]' ]
	[ "$(jq -c '.by_cause' <<<"$output")" = '{}' ]
	[ "$(jq -c '.untimed_by_cause' <<<"$output")" = '{"oom_killed":1}' ]
	[ "$(jq -r '.captures[0].untimed' <<<"$output")" = true ]
	run istiod_diag_report md "$RES"
	assert_output --partial "by cause: none. Not in the tally: 1 restart(s) at an unknown time (\`restarted_untimed\`"
	assert_output --partial "may predate the window): oom_killed=1."
	assert_output --partial "| restarted_untimed | oom_killed (untimed) |"
	run istiod_diag_report text "$RES"
	assert_output --partial "by cause: none"
	assert_output --partial "not in the tally, 1 restart(s) at an unknown time"
	assert_output --partial "| restarted_untimed | oom_killed (untimed) | exit=137"
}

@test "untimed: restarts of a container that started long before the failed pre-window scrape are no_change" {
	# Lab case: restartCount 2 from an old node reboot, then one flaky pre-window scrape.
	: > "$PRE"
	echo 1791980590000 > "${BATS_TEST_TMPDIR}/pre-0.ts"  # ms, a day after the 12:23:10Z start
	FAKE_PODS="${FX}/pods_node_restart.json" run _cap unknown
	assert_success
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	[ "$(_rows)" -eq 1 ]
	[ "$(_col change)" = no_change ]
	[ "$(_col cause)" = no_restart_found ]
	[[ "$(_col note)" == *"1 with restarts that predate it"* ]]
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.by_cause, .untimed_rows]' <<<"$output")" = '[{"no_restart_found":1},0]' ]
	# Within the clock margin of the scrape the restart stays untimed, never no_change.
	rm -rf "$D"
	echo 1791894290000 > "${BATS_TEST_TMPDIR}/pre-0.ts"  # 100 s after the start
	FAKE_PODS="${FX}/pods_node_restart.json" run _cap unknown
	[ "$(_col change)" = restarted_untimed ]
}

@test "dedup of row-only captures: a repeat without a folder is already_reported and counted once" {
	export ISTIOD_DIAG_MAX_CAPTURES=0
	_cap 1 iter1
	_cap 1 iter2
	[ "$(_col evidence)" = already_reported ]
	[ "$(_rows)" -eq 2 ]
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.rows, .repeat_rows, .by_cause]' <<<"$output")" = '[2,1,{"oom_killed":1}]' ]
	# A restart first skipped on the deadline gets its folder at a later call; the report
	# lists that row and counts the restart once.
	rm -rf "$D"
	unset ISTIOD_DIAG_MAX_CAPTURES
	ISTIOD_DIAG_MAX_SEC=0 _cap 1 iter1
	[ "$(_col evidence)" = skipped_deadline ]
	_cap 1 iter2
	[ "$(_col evidence)" = 001-iter2-ctx-a ]
	_cap 1 iter3
	[ "$(_col evidence)" = already_captured ]
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.rows, .repeat_rows, .by_cause]' <<<"$output")" = '[3,2,{"oom_killed":1}]' ]
	[ "$(jq -c '[.captures[] | select(.repeat | not) | .evidence]' <<<"$output")" = '["istiod-diag-RUN1/001-iter2-ctx-a"]' ]
}

@test "dedup: a replaced pod seen failed, then gone, is one restart (no second folder, one tally entry)" {
	FAKE_PODS="${FX}/pods_evicted.json" FAKE_EVENTS="${FX}/events_evicted.json" _cap 1 iter1
	[ "$(_col change istiod-abc-x1)" = replaced_failed ]
	n1="$(wc -l < "$CALLS")"
	FAKE_PODS="${FX}/pods_deleted.json" FAKE_EVENTS="${FX}/events_deleted.json" _cap podset_changed iter2
	[ "$(_col change istiod-abc-x1)" = replaced_gone ]
	[ "$(_col evidence istiod-abc-x1)" = already_captured ]
	[ "$(_col evidence istiod-abc-y2)" = already_captured ]
	[ "$(($(wc -l < "$CALLS") - n1))" -eq 1 ]
	[ "$(ls -d "${D}"/[0-9][0-9][0-9]-* | wc -l)" -eq 1 ]
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.rows, .repeat_rows, .by_cause]' <<<"$output")" = '[4,2,{"evicted":1,"replacement":1}]' ]
}

@test "istiod_diag_report: none captured, and an index of another width is skipped with a warning" {
	mkdir -p "${RES}"
	run istiod_diag_report md "$RES"
	assert_output --partial "None captured"
	run istiod_diag_report text "$RES"
	assert_output "istiod restart diagnostics: none captured"
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.index_files, .rows, .by_cause]' <<<"$output")" = '[0,0,{}]' ]
	mkdir -p "${RES}/istiod-diag-OLD"
	printf 'captured_at\tpod\n2026-01-01T00:00:00Z\tp\n' > "${RES}/istiod-diag-OLD/index.tsv"
	run --separate-stderr istiod_diag_report json "$RES"
	[ "$(jq -c '.rows' <<<"$output")" = 0 ]
	[[ "$stderr" == *"skipped 1 index row(s) of another schema"* ]]
}

# --- --config keys (every suite) ---

@test "--config: every suite takes the six ISTIOD_DIAG_* keys; an unknown key names them" {
	local s k f
	for s in "${SUITES[@]}"; do
		for k in ISTIOD_DIAG_ENABLED ISTIOD_DIAG_REQUEST_TIMEOUT ISTIOD_DIAG_MAX_SEC ISTIOD_DIAG_MAX_CAPTURES \
			ISTIOD_DIAG_LOG_LINES ISTIOD_DIAG_LOG_BYTES; do
			config_allowed_keys "$s" | grep -qx "$k" || { echo "$s: missing $k"; false; }
		done
	done
	f="${BATS_TEST_TMPDIR}/diag.env"
	printf 'ISTIOD_DIAG_ENABLED=0\nISTIOD_DIAG_REQUEST_TIMEOUT=1ms\n' > "$f"
	for s in "${SUITES[@]}"; do
		run --separate-stderr bash -c 'source "$1/tests/lib/common.sh"; ROOT="$1"; source "$1/tests/lib/config.sh"
			load_config "$2" "$3" >/dev/null; echo "$ISTIOD_DIAG_ENABLED $ISTIOD_DIAG_REQUEST_TIMEOUT $RUN_CONFIG_SHA256"' _ "$ROOT" "$f" "$s"
		assert_success
		assert_output --regexp '^0 1ms ([0-9a-f]{64}|unknown)$'
	done
	printf 'ISTIOD_DIAG_TYPO=1\n' > "$f"
	run load_config "$f" churn
	assert_failure
	assert_output --partial "keys CHURN_*, FANOUT_*, METRICS_SCRAPE_TIMEOUT); every suite also takes ISTIOD_DIAG_*"
	# options.env defaults.
	run bash -c 'source "$1/config/options.env"; echo "$ISTIOD_DIAG_ENABLED $ISTIOD_DIAG_REQUEST_TIMEOUT $ISTIOD_DIAG_MAX_SEC $ISTIOD_DIAG_MAX_CAPTURES $ISTIOD_DIAG_LOG_LINES $ISTIOD_DIAG_LOG_BYTES"' _ "$ROOT"
	assert_output "1 15 120 20 5000 1048576"
}

# --- controlplane 002: the window hook reads its rows back ---

# _cp_tsv <ts> <row...>: a controlplane-like TSV whose istiod_restarted is NOT column 31,
# so the hook has to find it by header name. A row is "context restarted".
_cp_tsv() {
	local ts="$1" r
	shift
	{
		echo "# RUN_ID=RUN1"
		printf 'timestamp\textra\tcontext\tmesh_size\tistiod_restarted\n'
		for r in "$@"; do printf '%s\tx\t%s\t2\t%s\n' "$ts" "${r% *}" "${r#* }"; done
	} > "$TSV_FILE"
}

@test "controlplane window hook: columns by header name, only non-0 contexts, no_running_pods for a dropped one" {
	TSV_FILE="${RES}/controlplane-RUN1.tsv"
	RUN_ID=RUN1
	TMP_DIR="${BATS_TEST_TMPDIR}/cp"
	mkdir -p "$RES" "$TMP_DIR"
	cp "${FX}/pre_metrics.txt" "${TMP_DIR}/baseline-0.metrics"
	echo 1716940800123 > "${TMP_DIR}/baseline-0.ts"  # ms stamps in controlplane
	cp "${FX}/pre_metrics.txt" "${TMP_DIR}/baseline-1.metrics"
	POD_CTXS=(ctx-a ctx-b)
	POD_NAMES=(istiod-abc-x1 istiod-zzz-q1)
	KUBECTL=(_fake_kubectl)
	ts="2026-10-13T12:23:10+00:00"
	# Every row 0: the hook makes no call and writes nothing.
	_cp_tsv "$ts" "ctx-a 0" "ctx-b 0"
	run istiod_diag_after_window "$ts"
	assert_success
	[ ! -s "$CALLS" ]
	[ ! -e "$D" ]
	# ctx-a restarted, ctx-b fine, ctx-c dropped (no istiod pod, unknown row).
	_cp_tsv "$ts" "ctx-a 1" "ctx-b 0" "ctx-c unknown"
	run istiod_diag_after_window "$ts"
	assert_success
	[ "$(_col trigger istiod-abc-x1 ctx-a)" = 1 ]
	[ "$(_col cause istiod-abc-x1 ctx-a)" = oom_killed ]
	[ "$(_col change istiod-abc-x1 ctx-a)" = restarted_in_place ]
	[ "$(_col pre_scrape_at istiod-abc-x1 ctx-a)" = 2024-05-29T00:00:00Z ]
	[ "$(_col tag istiod-abc-x1 ctx-a)" = w20261013T122310Z ]
	run grep -c -- '--context=ctx-b ' "$CALLS"
	[ "$output" = 0 ]
	# The dropped context has no pod set: every pod with restarts counts, untimed.
	[ "$(_col trigger "" ctx-c)" = no_running_pods ]
	[ "$(_col change "" ctx-c)" = restarted_untimed ]
	# Another window's rows are not this window's.
	: > "$CALLS"
	run istiod_diag_after_window "2026-10-13T12:30:00+00:00"
	[ ! -s "$CALLS" ]
}

# --- entrypoints (PL33): dataplane 002, churn 002, tuning 004 ---

# Stub kubectl and curl on PATH for the probes. istiod /metrics answers STUB_PRE_BODY
# until the measured window starts (STUB_MARK: the fortio load, the churn scale-up or
# the propagation t0 label), STUB_POST_BODY after. With STUB_REPLACE_ON_DRAIN, the
# propagation drain replaces istiod-abc-x1 by istiod-abc-y2 and kills its port-forward
# once (the next /metrics read fails).
_stub_bin() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark" FX
	export STUB_REPLACED="${BATS_TEST_TMPDIR}/replaced.mark" STUB_FAIL_ONCE="${BATS_TEST_TMPDIR}/fail-once.mark"
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "*) printf '%s' "$ISTIO_VERSION" ;;  # the pin (R4)
*" fortio load "*" -json - "*) : > "$STUB_MARK"; cat "$FX/../fortio_ok.json" ;;
*" get pod -l app=fortio-client "*) printf 'fortio-client-0' ;;
*" exec "*) cat "$FX/../fortio_ok.json" ;;
*" scale "*" --replicas=1 "*)
	if [[ -n "${STUB_REPLACE_ON_SCALE_DOWN:-}" ]]; then : > "$STUB_REPLACED"; fi ;;
*" scale "*) : > "$STUB_MARK" ;;
*" label pod/"*"=true "*) : > "$STUB_MARK" ;;
*" label pod/"*)
	if [[ -n "${STUB_REPLACE_ON_DRAIN:-}" ]]; then : > "$STUB_REPLACED"; : > "$STUB_FAIL_ONCE"; fi ;;
*" wait pod/"*) : ;;
*" get pods -l app=propagation-canary "*) printf 'canary-backer-0\n' ;;
*" get deploy dataplane-server "*) printf '1/1' ;;
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0' ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*)
	if [[ -f "$STUB_REPLACED" ]]; then printf 'istiod-abc-y2\n'; else printf 'istiod-abc-x1\n'; fi ;;
*" -n istio-system get pods -l app=istiod -o json "*)
	if [[ -n "${STUB_DIAG_FAIL:-}" ]]; then echo "error: the server is currently unable to handle the request" >&2; exit 1; fi
	cat "${STUB_PODS_JSON:-$FX/pods_oom.json}" ;;
*" get events "* | *" get deploy,rs "*) cat "$FX/empty_list.json" ;;
*" get node "*) cat "$FX/node_ready.json" ;;
*" logs "*) echo "istiod log line" ;;
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
*/metrics)
	if [[ -f "$STUB_FAIL_ONCE" ]]; then rm -f "$STUB_FAIL_ONCE"; exit 7; fi
	body="$STUB_PRE_BODY"; [[ -f "$STUB_MARK" ]] && body="$STUB_POST_BODY" ;;
*/clusters) body="$FX/../fortio_ok.json" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
	export STUB_PRE_BODY="${FX}/pre_metrics.txt"
	# Same body after the load: no restart. A restart test points this at an advanced start.
	export STUB_POST_BODY="${FX}/pre_metrics.txt"
	RESTARTED_BODY="${BATS_TEST_TMPDIR}/post_restarted.txt"
	sed 's/^process_start_time_seconds .*/process_start_time_seconds 1.7169414e+09/' "${FX}/pre_metrics.txt" > "$RESTARTED_BODY"
}

_dp_run() {
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/dataplane/002-run-latency-probe.sh" \
		--source-context ctx-a --qps-levels 10,100 --settle 0 --warmup-duration 0 --reach-requests 0 \
		--output-dir "$RES"
}

@test "dataplane 002 entrypoint, istiod_restarted=0: no extra API call and no istiod-diag folder" {
	_stub_bin
	_dp_run
	assert_success
	f="$(ls "$RES"/latency-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $16 }' "$f" | sort -u)" = 0 ]
	run grep -E 'app=istiod -o json|get events|get deploy,rs|get node| logs ' "$STUB_LOG"
	assert_failure
	[ -z "$(ls -d "$RES"/istiod-diag-* 2>/dev/null)" ]
}

@test "dataplane 002 entrypoint, restart: rows say 1 and the index says oom_killed; report sections in md and json" {
	_stub_bin
	STUB_POST_BODY="$RESTARTED_BODY" _dp_run
	assert_success
	f="$(ls "$RES"/latency-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $16 }' "$f" | sort -u)" = 1 ]
	idx="$(ls "$RES"/istiod-diag-*/index.tsv)"
	D="$(dirname "$idx")"
	[ "$(_col cause istiod-abc-x1)" = oom_killed ]
	[ "$(_col tag istiod-abc-x1)" = m1 ]
	[[ "$stderr" == *"istiod-diag: ctx-a istiod-abc-x1: change=restarted_in_place cause=oom_killed"* ]]
	run "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "## istiod restart diagnostics"
	assert_output --partial "oom_killed=1"
	run "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '.istiod_diag.by_cause' <<<"$output")" = '{"oom_killed":1}' ]
	# No comment line in CSV output: the section is in text, md and json only.
	run "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$RES" --format csv
	refute_output --partial "restart diagnostics"
	refute_output --partial "oom_killed"
}

@test "dataplane 002 entrypoint, restart with every capture call failing: exit 0, rows intact, capture_failed" {
	_stub_bin
	STUB_POST_BODY="$RESTARTED_BODY" STUB_DIAG_FAIL=1 _dp_run
	assert_success
	f="$(ls "$RES"/latency-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id"' "$f" | wc -l)" -eq 2 ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col change)" = capture_failed ]
	[[ "$(_col note)" == *"server is currently unable to handle the request"* ]]
}

@test "churn-dataplane 002 entrypoint: a restart gets POISONED_RESTART and an index row tagged <combo>-baseline" {
	_stub_bin
	PATH="${BIN}:${PATH}" STUB_POST_BODY="$RESTARTED_BODY" run --separate-stderr \
		"${ROOT}/tests/churn-dataplane/002-run-baseline-probe.sh" --source-context ctx-a --combo-id c7 \
		--duration 1 --settle-sec 0 --reach-requests 0 --output-dir "$RES"
	assert_success
	f="$(ls "$RES"/churn-dataplane-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $16 "/" $17 }' "$f")" = 1/POISONED_RESTART ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col tag istiod-abc-x1)" = c7-baseline ]
	[ "$(_col cause istiod-abc-x1)" = oom_killed ]
	run "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '.istiod_diag.by_cause' <<<"$output")" = '{"oom_killed":1}' ]
	run "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$RES" --format md
	assert_output --partial "| ctx-a | c7-baseline | istiod-abc-x1 | restarted_in_place | oom_killed |"
}

_cp_run() {
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$RES" "$@"
}

@test "controlplane 002 entrypoint: no restart -> no extra call; a restart across split phases -> oom_killed row" {
	_stub_bin
	_cp_run
	assert_success
	f="$(ls "$RES"/controlplane-*.tsv)"
	[ "$(awk -F'\t' '$1 == "timestamp" { for (i = 1; i <= NF; i++) if ($i == "istiod_restarted") c = i; next } !/^#/ && c { print $c }' "$f")" = 0 ]
	run grep -E 'app=istiod -o json|get events|get deploy,rs| logs ' "$STUB_LOG"
	assert_failure
	[ -z "$(ls -d "$RES"/istiod-diag-* 2>/dev/null)" ]
	# Split phase (as 003 runs it): the restart lands between baseline and final.
	rm -rf "$RES"
	SD="${BATS_TEST_TMPDIR}/state"
	mkdir -p "$SD"
	_cp_run --phase baseline --state-dir "$SD"
	assert_success
	: > "$STUB_MARK"
	STUB_POST_BODY="$RESTARTED_BODY" _cp_run --phase final --state-dir "$SD"
	assert_success
	f="$(ls "$RES"/controlplane-*.tsv)"
	[ "$(awk -F'\t' '$1 == "timestamp" { for (i = 1; i <= NF; i++) if ($i == "istiod_restarted") c = i; next } !/^#/ && c { print $c }' "$f")" = 1 ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col cause istiod-abc-x1)" = oom_killed ]
	[ "$(_col pre_scrape_at istiod-abc-x1)" != N/A ]
	[[ "$(_col tag istiod-abc-x1)" =~ ^w[0-9]{8}T[0-9]{6}Z$ ]]
}

_churn_run() {
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/churn/002-run-churn-probe.sh" \
		--source-context ctx-a --iterations 1 --timeout 2 --settle 0 --deployment-count 1 \
		--output-dir "$RES"
}

@test "churn 002 entrypoint (PL32): a capture inside the iteration subshell never adds a SETUP_FAILED row" {
	_stub_bin
	export CHURN_POLL_INTERVAL_MS=50
	STUB_POST_BODY="$RESTARTED_BODY" STUB_DIAG_FAIL=1 _churn_run
	assert_success
	f="$(ls "$RES"/churn-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id"' "$f" | wc -l)" -eq 1 ]
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $21 }' "$f")" = POISONED_RESTART ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col change)" = capture_failed ]
	[ "$(_col tag)" = iter1 ]
	# The same run with a working capture names the cause.
	rm -rf "$RES"
	: > "$STUB_LOG"
	rm -f "$STUB_MARK"
	STUB_POST_BODY="$RESTARTED_BODY" _churn_run
	assert_success
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id"' "$(ls "$RES"/churn-*.tsv)" | wc -l)" -eq 1 ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col cause istiod-abc-x1)" = oom_killed ]
	run "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$RES" --format md
	assert_output --partial "## istiod restart diagnostics"
}

@test "churn 002 entrypoint: a pod replaced during the scale-down is captured at the next re-open (podset_changed)" {
	_stub_bin
	export CHURN_POLL_INTERVAL_MS=50
	PATH="${BIN}:${PATH}" STUB_REPLACE_ON_SCALE_DOWN=1 STUB_PODS_JSON="${FX}/pods_deleted.json" run --separate-stderr \
		"${ROOT}/tests/churn/002-run-churn-probe.sh" --source-context ctx-a --iterations 2 --timeout 2 --settle 0 \
		--deployment-count 1 --output-dir "$RES"
	assert_success
	f="$(ls "$RES"/churn-*.tsv)"
	# Neither row is POISONED_RESTART: the replacement happened between the windows.
	# (They are MISSING_VALUE: this stub's watcher lists no churn target, so
	# convergence_local_ms is N/A, R12.)
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $21 }' "$f" | sort -u)" = MISSING_VALUE ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col trigger istiod-abc-x1)" = podset_changed ]
	[ "$(_col tag istiod-abc-x1)" = before-iter2 ]
	[ "$(_col change istiod-abc-x1)" = replaced_gone ]
	[ "$(_col rss_pre_mi istiod-abc-x1)" = 300 ]
	[ "$(_col change istiod-abc-y2)" = new_pod ]
}

_prop_run() {
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/propagation/002-run-endpoint-probe.sh" \
		--source-context ctx-a --timeout 2 --poll-interval-ms 100 --settle-sec 0 --tsv \
		--output-dir "$RES" "$@"
}

@test "propagation 002 entrypoint (R6): the summary averages only the rows 005 counts and tallies the rest" {
	_stub_bin
	# P1 converges: the flip adds 10 convergence samples for 5 proxies.
	hist() { printf 'pilot_proxy_convergence_time_bucket{le="0.1"} %s\npilot_proxy_convergence_time_bucket{le="+Inf"} %s\npilot_proxy_convergence_time_sum %s\npilot_proxy_convergence_time_count %s\n' "$1" "$1" "$2" "$1"; }
	{ cat "${FX}/pre_metrics.txt"; hist 0 0; } > "${BATS_TEST_TMPDIR}/pre.txt"
	{ cat "${FX}/pre_metrics.txt"; hist 10 0.5; } > "${BATS_TEST_TMPDIR}/post.txt"
	STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre.txt" STUB_POST_BODY="${BATS_TEST_TMPDIR}/post.txt" _prop_run --iterations 1
	assert_success
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --partial "rows_dropped_total=0/1"
	grep -qE '^\| P1 local xDS push \| 1/1 \| [0-9]+ \|' "$RES"/endpoint-*.md
	# The same P1 with no process_start_time_seconds: the row is written OK with
	# restarted=unknown, which 005 drops. The summary used to average it anyway.
	rm -rf "$RES"; rm -f "$STUB_MARK"
	grep -v '^process_start_time_seconds' "${BATS_TEST_TMPDIR}/pre.txt" > "${BATS_TEST_TMPDIR}/pre-u.txt"
	grep -v '^process_start_time_seconds' "${BATS_TEST_TMPDIR}/post.txt" > "${BATS_TEST_TMPDIR}/post-u.txt"
	STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre-u.txt" STUB_POST_BODY="${BATS_TEST_TMPDIR}/post-u.txt" _prop_run --iterations 1
	assert_success
	f="$(ls "$RES"/endpoint-*.tsv)"
	[[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $16 }' "$f")" == OK/unknown ]]
	[[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $7 }' "$f")" =~ ^[0-9]+$ ]]
	assert_output --partial "P1 local xDS push:          n=0/1 (no valid sample)"
	assert_output --partial "rows_dropped_total=1/1"
	assert_output --regexp 'restarted=unknown +1'
	grep -qxF '| P1 local xDS push | 0/1 | - | - | - |' "$RES"/endpoint-*.md
	grep -qxF '| `restarted=unknown` | 1 |' "$RES"/endpoint-*.md
	grep -qF 'counts: status OK, `restarted=0` (not 1 or' "$RES"/endpoint-*.md
	# 005 counts the same rows.
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line "1,P1_local_wall,1,0,,,,,,,"
}

@test "propagation 002 entrypoint: a restart in the window (RESTART row) gets an oom_killed index row" {
	_stub_bin
	STUB_POST_BODY="$RESTARTED_BODY" _prop_run --iterations 1
	assert_success
	f="$(ls "$RES"/endpoint-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $16 }' "$f")" = RESTART/1 ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col cause istiod-abc-x1)" = oom_killed ]
	[ "$(_col tag istiod-abc-x1)" = iter1 ]
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '.istiod_diag.by_cause' <<<"$output")" = '{"oom_killed":1}' ]
}

@test "propagation 002 entrypoint: a pod replaced between iterations is captured at the re-open (podset_changed)" {
	_stub_bin
	STUB_REPLACE_ON_DRAIN=1 STUB_PODS_JSON="${FX}/pods_deleted.json" _prop_run --iterations 2
	assert_success
	[[ "$stderr" == *"re-opening fanout block"* ]]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col trigger istiod-abc-x1)" = podset_changed ]
	[ "$(_col change istiod-abc-x1)" = replaced_gone ]
	[ "$(_col tag istiod-abc-x1)" = iter1 ]
	[ "$(_col rss_pre_mi istiod-abc-x1)" = 300 ]
	[ "$(_col change istiod-abc-y2)" = new_pod ]
	[ "$(_col cause istiod-abc-y2)" = replacement ]
	# Without a replacement the re-open check costs no API call.
	rm -rf "$RES" "$STUB_REPLACED"
	: > "$STUB_LOG"
	rm -f "$STUB_MARK"
	_prop_run --iterations 2
	assert_success
	run grep -E 'app=istiod -o json' "$STUB_LOG"
	assert_failure
	[ -z "$(ls -d "$RES"/istiod-diag-* 2>/dev/null)" ]
}

@test "tuning 004: an istiod-diag-*/index.tsv inside a pass dir is not read as a pass TSV" {
	S="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "${S}/baseline/istiod-diag-R1"
	printf '# SUITE=churn\n# PASSES=baseline\n' > "${S}/sweep-metadata.txt"
	{
		printf 'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus\n'
		printf 'r\t1\t5\t1\t5\t1\t0\t100\tN/A\tN/A\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\tOK\n'
		printf 'r\t1\t5\t1\t5\t2\t0\t300\tN/A\tN/A\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\tOK\n'
	} > "${S}/baseline/churn-R1.tsv"
	D="${S}/baseline/istiod-diag-R1"
	_cap
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$S"
	assert_success
	assert_output --regexp 'Valid / total rows +2/2'
	assert_output --regexp 'Local convergence \(ms\) +200\.00'
}
