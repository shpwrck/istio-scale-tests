#!/usr/bin/env bats
# tests/lib/istiod-diag.sh (istiod restart evidence): the cause of each kind of restart over a
# fake kubectl and hand-written fixtures, one restart counted once, the bounds that still keep
# its row, PL40 containment, redaction, the report renderer, the ISTIOD_DIAG_* --config keys,
# the controlplane window hook, and the entrypoints that call the capture (dataplane 002,
# churn-dataplane 002, controlplane 002, churn 002, propagation 002) plus the tuning
# comparison that must not read the index (PL33).
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
	export TMPDIR="$BATS_TEST_TMPDIR"
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

# _next <dir>: start a fresh index in <dir> and the call log.
_next() { D="$1"; : > "$CALLS"; }

# --- causes ---

@test "each kind of restart gets its cause, exit code and pre-window memory against its limit; nothing changed is no_restart_found after one call; no Running istiod is no_pods" {
	# OOM in place: the limit, the pre-window memory, the previous log, bounded.
	run _cap
	assert_success
	[ "$(_col change)/$(_col cause)/$(_col exit_code)/$(_col signal)/$(_col term_reason)" = restarted_in_place/oom_killed/137/9/OOMKilled ]
	[ "$(_col restart_count)" = 1 ]
	[ "$(_col started_at)/$(_col finished_at)" = 2024-05-29T00:10:00Z/2024-05-29T00:09:58Z ]
	[ "$(_col mem_limit_mi)/$(_col rss_pre_mi)/$(_col heap_inuse_pre_mi)" = 3072/300/200 ]
	[ "$(_col goroutines_pre)/$(_col proxies_pre)" = 1234/5 ]
	[ "$(_col pre_scrape_at)" = 2024-05-29T00:00:00Z ]
	[ "$(_col node_ready_at)" = 2026-10-13T12:23:08Z ]
	ev="$(_col evidence)"
	[ "$ev" = 001-iter1-ctx-a ]
	grep -q -- '-n istio-system logs istiod-abc-x1 -c discovery .*--previous --tail=5000 --limit-bytes=8388608' "$CALLS"
	[ -s "${D}/${ev}/istiod-abc-x1.previous.log.gz" ]
	[ -s "${D}/${ev}/istiod-abc-x1.pre.metrics.gz" ]
	grep -qx '# ISTIOD_DIAG_SCHEMA=1' "${D}/index.tsv"
	grep -qx '# RUN_ID=RUN1' "${D}/index.tsv"
	[ "$(_rows)" -eq 1 ]
	# Deleted: the gone pod's own row (no log call for it), its replacement's startup log.
	_next "${RES}/istiod-diag-DEL"
	FAKE_PODS="${FX}/pods_deleted.json" FAKE_EVENTS="${FX}/events_deleted.json" run _cap
	assert_success
	[ "$(_col change istiod-abc-x1)/$(_col cause istiod-abc-x1)/$(_col rs_changed istiod-abc-x1)/$(_col rss_pre_mi istiod-abc-x1)" = replaced_gone/deleted/0/300 ]
	[ "$(_col change istiod-abc-y2)/$(_col cause istiod-abc-y2)" = new_pod/replacement ]
	! grep -q 'logs istiod-abc-x1' "$CALLS" || false
	grep -q -- 'logs istiod-abc-y2 -c discovery .*--limit-bytes=262144' "$CALLS"
	# Rollout: another ReplicaSet; the gone pod's limit is its old ReplicaSet's.
	_next "${RES}/istiod-diag-ROLL"
	FAKE_PODS="${FX}/pods_rollout.json" FAKE_DEPLOY_RS="${FX}/deploy_rs_rollout.json" run _cap
	assert_success
	[ "$(_col cause istiod-abc-x1)/$(_col rs_changed istiod-abc-x1)/$(_col mem_limit_mi istiod-abc-x1)" = rollout/1/3072 ]
	[ "$(_col cause istiod-def-z3)/$(_col rs_changed istiod-def-z3)/$(_col mem_limit_mi istiod-def-z3)" = rollout/1/512 ]
	# Evicted: the old pod still exists, so its current log (no --previous).
	_next "${RES}/istiod-diag-EVIC"
	FAKE_PODS="${FX}/pods_evicted.json" FAKE_EVENTS="${FX}/events_evicted.json" run _cap
	assert_success
	[ "$(_col change istiod-abc-x1)/$(_col cause istiod-abc-x1)/$(_col exit_code istiod-abc-x1)" = replaced_failed/evicted/137 ]
	[[ "$(_col note istiod-abc-x1)" == *"low on resource: memory"* ]]
	grep -q -- 'logs istiod-abc-x1 -c discovery --request-timeout=15 --tail=5000 --limit-bytes=8388608$' "$CALLS"
	[ "$(_col cause istiod-abc-y2)" = replacement ]
	# Probe kill: an Unhealthy liveness event plus Killing, even with exit 0; without the
	# events the same restart is a plain exit.
	_next "${RES}/istiod-diag-PROBE"
	FAKE_PODS="${FX}/pods_probe.json" FAKE_EVENTS="${FX}/events_probe.json" run _cap
	[ "$(_col change)/$(_col cause)/$(_col exit_code)" = restarted_in_place/probe_kill/0 ]
	_next "${RES}/istiod-diag-EXIT"
	FAKE_PODS="${FX}/pods_probe.json" run _cap
	[ "$(_col cause)" = exited ]
	# Crash: exit 2 in a crash loop, the panic line in the note.
	_next "${RES}/istiod-diag-CRASH"
	FAKE_PODS="${FX}/pods_crash.json" run _cap
	[ "$(_col change)/$(_col cause)/$(_col exit_code)/$(_col started_at)" = restarted_in_place/crash/2/N/A ]
	[[ "$(_col note)" == *"panic: runtime error: invalid memory address or nil pointer dereference"* ]]
	[[ "$(_col note)" == *"waiting: CrashLoopBackOff"* ]]
	# Node restart (lab case): empty lastState, node Ready 2 s before the start, no
	# previous log.
	_next "${RES}/istiod-diag-NODE"
	FAKE_PODS="${FX}/pods_node_restart.json" FAKE_PREV_FAIL=1 run _cap
	assert_success
	[ "$(_col change)/$(_col cause)/$(_col restart_count)" = restarted_in_place/node_restart/2 ]
	[[ "$(_col note)" == *"previous log unavailable: previous terminated container"*"not found"* ]]
	[ -s "${D}/$(_col evidence)/istiod-abc-x1.previous.log.unavailable" ]
	# Nothing changed after an unknown trigger: one call, no folder.
	_next "${RES}/istiod-diag-STEADY"
	FAKE_PODS="${FX}/pods_steady.json" run _cap unknown
	assert_success
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	grep -q -- '-n istio-system get pods -l app=istiod -o json --request-timeout=15' "$CALLS"
	[ "$(_col trigger)/$(_col change)/$(_col cause)/$(_col evidence)" = unknown/no_change/no_restart_found/- ]
	[ -z "$(ls -d "${D}"/[0-9][0-9][0-9]-* 2>/dev/null)" ]
	# No Running istiod at the start (no pod set): no_pods without pods, restarted_untimed
	# with restarts.
	_next "${RES}/istiod-diag-NOPODS"
	FAKE_PODS="${FX}/empty_list.json" run istiod_diag_capture "$D" m2 ctx-a no_running_pods "" "" _fake_kubectl
	assert_success
	[ "$(_col trigger)/$(_col change)/$(_col cause)" = no_running_pods/no_pods/no_istiod_pods ]
	run istiod_diag_capture "$D" m2 ctx-a unknown "" "" _fake_kubectl
	[ "$(_col change istiod-abc-x1)/$(_col cause istiod-abc-x1)" = restarted_untimed/oom_killed ]
}

@test "one restart is one restart however often it is seen: a repeat gets a row but no second folder (already_captured), a row-only repeat is already_reported, a restart skipped on the deadline gets its folder later, a pod seen failed then gone; the report counts each once" {
	_cap
	n1="$(wc -l < "$CALLS")"
	run _cap iter2
	assert_success
	[ "$(_col evidence)/$(_col cause)" = already_captured/oom_killed ]
	[ "$(($(wc -l < "$CALLS") - n1))" -eq 1 ]
	[ "$(ls -d "${D}"/[0-9][0-9][0-9]-* | wc -l)" -eq 1 ]
	# Row-only captures (no budget): the repeat is already_reported, counted once.
	_next "${RES}/istiod-diag-RO"
	ISTIOD_DIAG_MAX_CAPTURES=0 _cap 1 iter1
	ISTIOD_DIAG_MAX_CAPTURES=0 _cap 1 iter2
	[ "$(_col evidence)" = already_reported ]
	[ "$(_rows)" -eq 2 ]
	# Skipped on the deadline, then captured at a later call: the report lists that row.
	_next "${RES}/sweep-x/istiod-diag-DL"
	ISTIOD_DIAG_MAX_SEC=0 _cap 1 iter1
	[ "$(_col evidence)" = skipped_deadline ]
	_cap 1 iter2
	[ "$(_col evidence)" = 001-iter2-ctx-a ]
	_cap 1 iter3
	[ "$(_col evidence)" = already_captured ]
	# A replaced pod seen failed, then gone: one restart, no second folder.
	_next "${RES}/sweep-y/istiod-diag-EV"
	FAKE_PODS="${FX}/pods_evicted.json" FAKE_EVENTS="${FX}/events_evicted.json" _cap 1 iter1
	[ "$(_col change istiod-abc-x1)" = replaced_failed ]
	n1="$(wc -l < "$CALLS")"
	FAKE_PODS="${FX}/pods_deleted.json" FAKE_EVENTS="${FX}/events_deleted.json" _cap podset_changed iter2
	[ "$(_col change istiod-abc-x1)/$(_col evidence istiod-abc-x1)/$(_col evidence istiod-abc-y2)" = replaced_gone/already_captured/already_captured ]
	[ "$(($(wc -l < "$CALLS") - n1))" -eq 1 ]
	[ "$(ls -d "${D}"/[0-9][0-9][0-9]-* | wc -l)" -eq 1 ]
	# Each index alone, then all four together.
	run istiod_diag_report json "${RES}/sweep-x"
	[ "$(jq -c '[.rows, .repeat_rows, .by_cause]' <<<"$output")" = '[3,2,{"oom_killed":1}]' ]
	[ "$(jq -c '[.captures[] | select(.repeat | not) | .evidence]' <<<"$output")" = '["istiod-diag-DL/001-iter2-ctx-a"]' ]
	run istiod_diag_report json "${RES}/sweep-y"
	[ "$(jq -c '[.rows, .repeat_rows, .by_cause]' <<<"$output")" = '[4,2,{"evicted":1,"replacement":1}]' ]
	run istiod_diag_report json "$RES"
	# Across runs too: the three indexes of the same OOM count it once.
	[ "$(jq -c '[.index_files, .rows, .repeat_rows, .by_cause]' <<<"$output")" = '[4,11,8,{"evicted":1,"oom_killed":1,"replacement":1}]' ]
}

@test "the capture is bounded and still writes each restart's row: past the budget (budget_exhausted) or the deadline (skipped_deadline) a row only, the last ISTIOD_DIAG_LOG_BYTES of a log, the request timeout as given (a bad one warns and uses 15); ISTIOD_DIAG_ENABLED=0 makes no call" {
	ISTIOD_DIAG_MAX_CAPTURES=1 _cap
	n1="$(wc -l < "$CALLS")"
	FAKE_PODS="${FX}/pods_crash.json" ISTIOD_DIAG_MAX_CAPTURES=1 run _cap iter2
	assert_success
	[ "$(_col evidence)/$(_col cause)" = budget_exhausted/crash ]
	[ "$(($(wc -l < "$CALLS") - n1))" -eq 1 ]
	[ "$(ls -d "${D}"/[0-9][0-9][0-9]-* | wc -l)" -eq 1 ]
	_next "${RES}/istiod-diag-DL"
	ISTIOD_DIAG_MAX_SEC=0 run _cap
	assert_success
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	[ "$(_col evidence)/$(_col cause)" = skipped_deadline/oom_killed ]
	[ -z "$(ls -d "${D}"/[0-9][0-9][0-9]-* 2>/dev/null)" ]
	# A 5 MiB log keeps its last bytes (the marker line); the pre scrape stays gzipped.
	_next "${RES}/istiod-diag-BIG"
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
	gzip -dc "${D}/${ev}/istiod-abc-x1.pre.metrics.gz" | grep -q '^process_start_time_seconds 1.7169408e+09$'
	grep -qx '# ISTIOD_DIAG_LOG_BYTES=262144' "${D}/index.tsv"
	_next "${RES}/istiod-diag-TO"
	ISTIOD_DIAG_REQUEST_TIMEOUT=1ms run _cap
	assert_success
	grep -q -- '--request-timeout=1ms$' "$CALLS"
	! grep -q -- '1mss' "$CALLS" || false
	_next "${RES}/istiod-diag-TO2"
	ISTIOD_DIAG_REQUEST_TIMEOUT='1 ms' run --separate-stderr _cap
	assert_success
	[[ "$stderr" == *"ISTIOD_DIAG_REQUEST_TIMEOUT='1 ms' is not a kubectl --request-timeout"* ]]
	grep -q -- '--request-timeout=15 ' "$CALLS"
	_next "${RES}/istiod-diag-OFF"
	ISTIOD_DIAG_ENABLED=0 run _cap
	assert_success
	[ ! -s "$CALLS" ]
	[ ! -e "$D" ]
}

# --- safety (PL40) and redaction ---

@test "containment (PL40): every call failing under set -euo pipefail and an ERR trap, or a die inside the helper, gives a capture_failed row with its reason and rc 0; an unwritable results dir or a missing reach.sh warns and returns 0" {
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
	[ "$(_col change)/$(_col evidence)" = capture_failed/capture_failed ]
	note="$(_col note)"
	[[ "$note" == *"istiod pod list failed: error: Unable to connect to the server"* ]]
	[[ "$note" == *"<ip>"* && "$note" != *192.0.2* ]]
	export D="${RES}/istiod-diag-DIE"
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
	: > "$CALLS"
	touch "${BATS_TEST_TMPDIR}/afile"
	run --separate-stderr istiod_diag_capture "${BATS_TEST_TMPDIR}/afile/istiod-diag-x" iter1 ctx-a 1 "$PODSET" "$PRE" _fake_kubectl
	assert_success
	[[ "$stderr" == *"cannot create"* ]]
	[ ! -s "$CALLS" ]
	run --separate-stderr bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/istiod-diag.sh"; istiod_diag_capture "$2" t c 1 "" "" kubectl; echo "rc=$?"' _ "$ROOT" "$D"
	assert_output "rc=0"
	[[ "$stderr" == *"reach.sh is not sourced"* ]]
}

@test "redaction: index, summaries and README hold no IP, host or node name; notes, raw logs, events, the pod and node projections mask them (and tokens, JWTs); the folder ignores itself" {
	_cap
	FAKE_PODS="${FX}/pods_evicted.json" FAKE_EVENTS="${FX}/events_evicted.json" _cap unknown iter2
	FAKE_PODS="${FX}/pods_crash.json" _cap 1 iter3
	FAKE_PODS="${FX}/pods_node_restart.json" FAKE_PREV_FAIL=1 _cap 1 iter4
	local f note
	for f in "${D}/index.tsv" "${D}/README.md" "${D}"/*/summary.md; do
		[ -s "$f" ]
		run grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|2001:db8|worker-node|example\.internal' "$f"
		assert_failure 1
	done
	# The eviction note is masked, not dropped.
	note="$(awk -F'\t' '$1 != "captured_at" && /low on resource/' "${D}/index.tsv")"
	[[ "$note" == *"<ip>"* && "$note" == *"<host>"* && "$note" == *"<node>"* ]]
	log="${BATS_TEST_TMPDIR}/raw.log"
	gzip -dc "${D}/001-iter1-ctx-a/istiod-abc-x1.previous.log.gz" > "$log"
	run grep -E 's3cr3t-token|eyJhbGciOiJSUzI1NiJ9|192\.0\.2\.40|2001:db8' "$log"
	assert_failure
	grep -q 'Bearer <token>' "$log"
	grep -q '<jwt>' "$log"
	grep -q 'sidecar~<ip>~' "$log"
	grep -q 'peer <ip>:15012' "$log"
	# Raw events keep the host (stack traces and events need it) but mask the IPs; the pod
	# projection keeps no env, managedFields or IPs; the node's no IP.
	run grep -E '192\.0\.2|2001:db8' "${D}"/002-iter2-ctx-a/events.tsv
	assert_failure
	[ -s "${D}/001-iter1-ctx-a/pods.json" ]
	run grep -E 'do-not-copy|managedFields|podIP|hostIP' "${D}/001-iter1-ctx-a/pods.json"
	assert_failure 1
	f="$(ls "${D}"/*-iter4-ctx-a/node-1.json)"
	[ -s "$f" ]
	run grep -q '192.0.2' "$f"
	assert_failure 1
	# The folder ignores itself, so even a tracked --output-dir cannot commit the raw evidence.
	grep -qx '\*' "${D}/.gitignore"
	git init -q "$RES"
	git -C "$RES" check-ignore -q "istiod-diag-RUN1/001-iter1-ctx-a/istiod-abc-x1.previous.log.gz"
	git -C "$RES" check-ignore -q "istiod-diag-RUN1/index.tsv"
}

@test "folder names: no ':', '+' or '/' (NTFS copies); a context's part is ctx_file_safe's form in any locale (tuning's ctx_key too), so redact-results maps it in the index and names the folder" {
	local loc ctx want got
	D="${BATS_TEST_TMPDIR}/ntfs/istiod-diag-N" run istiod_diag_capture "${BATS_TEST_TMPDIR}/ntfs/istiod-diag-N" \
		'w2026-10-13T12:23:10+00:00' 'default/api-x:6443/kube:admin' 1 "$PODSET" "$PRE" _fake_kubectl
	assert_success
	got="$(D="${BATS_TEST_TMPDIR}/ntfs/istiod-diag-N" _col evidence)"
	[[ "$got" != *:* && "$got" != *+* && "$got" != */* ]]
	[ -d "${BATS_TEST_TMPDIR}/ntfs/istiod-diag-N/${got}" ]
	[[ "$(D="${BATS_TEST_TMPDIR}/ntfs/istiod-diag-N" _col tag)" != *:* ]]
	run istiod_diag_dir /x/y/latency-R1.tsv 'R1:+'
	assert_output "/x/y/istiod-diag-R1__"
	source "${ROOT}/tests/tuning/lib/tuning.sh"
	export -f _fake_kubectl
	export PODSET PRE FAKE_PODS FX
	export D="${RES}/istiod-diag-RUN2"
	# A UTF-8 letter is two bytes (ctx-é1 -> ctx-__1, as in a C locale), a long name is cut
	# to CTX_FILE_NAME_MAX, and the cut and whole forms are what ctx_key and redact use.
	for ctx in 'ctx-é1' 'ns/api-long-cluster-name.example:6443/ci-user-with-long-name'; do
		for loc in C C.UTF-8; do
			rm -rf "$D"
			run --separate-stderr env LC_ALL="$loc" bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/config.sh"
				source "$1/tests/lib/reach.sh"; source "$1/tests/lib/istiod-diag.sh"
				istiod_diag_capture "$D" iter1 "$2" 1 "$PODSET" "$PRE" _fake_kubectl' _ "$ROOT" "$ctx"
			assert_success
			got="$(_col evidence)"
			want="001-iter1-$(ctx_file_safe "$ctx" "$CTX_FILE_NAME_MAX")"
			[ "$got" = "$want" ] || { echo "${loc}: ${got} (want ${want})"; false; }
			[ -d "${D}/${got}" ]
			# tuning's state-file key is the whole form; the folder's is its first 40 characters.
			[[ "$(ctx_file_safe "$ctx")" == "$(ctx_key "$ctx")" && "001-iter1-$(ctx_key "$ctx")" == "$want"* ]]
		done
	done
	[ "$(ctx_key 'ctx-é1')" = ctx-__1 ]
	# The last capture (the long name, C.UTF-8): redact-results maps the context and the
	# folder's cut form in the index to one placeholder, and names the raw folder it skips.
	LC_ALL=C.UTF-8 run --separate-stderr "${ROOT}/tests/lib/redact-results.sh" --context "$ctx" \
		--out "${BATS_TEST_TMPDIR}/copy" "$RES"
	assert_success
	[ "$(awk -F'\t' '!/^#/ && $1 != "captured_at" { print $3 "|" $(NF - 1) }' "${BATS_TEST_TMPDIR}/copy/res/istiod-diag-RUN2/index.tsv")" = '<mesh-a-ctx>|001-iter1-<mesh-a-ctx>' ]
	[[ "$stderr" == *"istiod-diag-RUN2/${got}/"*"raw istiod-diag evidence"* ]]
	run grep -rF -e 'ns_api-long' -e 'long-cluster' "${BATS_TEST_TMPDIR}/copy"
	assert_failure
}

@test "a failed or partial pre-window scrape (PL29): memory N/A, never 0; the restart is untimed and stays out of the tally; restarts long before it are no_change, within the clock margin still untimed" {
	: > "$PRE"
	run _cap unknown
	[ "$(_col rss_pre_mi)/$(_col heap_inuse_pre_mi)" = N/A/N/A ]
	[ "$(_col change)/$(_col cause)" = restarted_untimed/oom_killed ]
	[[ "$(_col note)" == *"no pre-window start time"* ]]
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.rows, .untimed_rows, .repeat_rows, .by_cause, .untimed_by_cause, .captures[0].untimed]' <<<"$output")" = '[1,1,0,{},{"oom_killed":1},true]' ]
	run istiod_diag_report md "$RES"
	assert_output --partial "by cause: none. Not in the tally: 1 restart(s) at an unknown time (\`restarted_untimed\`"
	assert_output --partial "| restarted_untimed | oom_killed (untimed) |"
	run istiod_diag_report text "$RES"
	assert_output --partial "not in the tally, 1 restart(s) at an unknown time"
	assert_output --partial "| restarted_untimed | oom_killed (untimed) | exit=137"
	head -c 100 "${FX}/pre_metrics.txt" > "$PRE"
	D="${RES}/istiod-diag-RUN2" run _cap
	[ "$(D="${RES}/istiod-diag-RUN2" _col rss_pre_mi)/$(D="${RES}/istiod-diag-RUN2" _col proxies_pre)" = N/A/N/A ]
	# Lab case: restartCount 2 from an old node reboot, then one flaky pre-window scrape.
	: > "$PRE"
	_next "${BATS_TEST_TMPDIR}/res3/istiod-diag-RUN3"
	echo 1791980590000 > "${BATS_TEST_TMPDIR}/pre-0.ts"  # ms, a day after the 12:23:10Z start
	FAKE_PODS="${FX}/pods_node_restart.json" run _cap unknown
	assert_success
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	[ "$(_rows)" -eq 1 ]
	[ "$(_col change)/$(_col cause)" = no_change/no_restart_found ]
	[[ "$(_col note)" == *"1 with restarts that predate it"* ]]
	run istiod_diag_report json "${BATS_TEST_TMPDIR}/res3"
	[ "$(jq -c '[.by_cause, .untimed_rows]' <<<"$output")" = '[{"no_restart_found":1},0]' ]
	_next "${BATS_TEST_TMPDIR}/res3/istiod-diag-RUN4"
	echo 1791894290000 > "${BATS_TEST_TMPDIR}/pre-0.ts"  # 100 s after the start
	FAKE_PODS="${FX}/pods_node_restart.json" run _cap unknown
	[ "$(_col change)" = restarted_untimed ]
}

# --- report ---

@test "istiod_diag_report: by cause over every index file in md, text and json (csv prints nothing), repeats listed apart; two runs with the same tag stay apart; none captured; an index of another width is skipped with a warning" {
	run istiod_diag_report text "$RES"
	assert_output "istiod restart diagnostics: none captured"
	run istiod_diag_report md "$RES"
	assert_output --partial "None captured"
	run istiod_diag_report json "$RES"
	[ "$(jq -c '[.index_files, .rows, .by_cause]' <<<"$output")" = '[0,0,{}]' ]
	_cap
	_cap 1 iter2  # a repeat row: listed apart, not tallied
	D="${RES}/sweep-x/istiod-diag-RUN2" FAKE_PODS="${FX}/pods_deleted.json" FAKE_EVENTS="${FX}/events_deleted.json" _cap
	# Another run with the same tag and folder name.
	D="${RES}/istiod-diag-RUN3" FAKE_PODS="${FX}/pods_crash.json" _cap 1 iter1
	mkdir -p "${RES}/istiod-diag-OLD"
	printf 'captured_at\tpod\n2026-01-01T00:00:00Z\tp\n' > "${RES}/istiod-diag-OLD/index.tsv"
	run --separate-stderr istiod_diag_report json "$RES"
	assert_success
	[[ "$stderr" == *"skipped 1 index row(s) of another schema"* ]]
	[ "$(jq -c '[.index_files, .rows, .repeat_rows, .untimed_rows]' <<<"$output")" = '[4,5,1,0]' ]
	[ "$(jq -c '.by_cause' <<<"$output")" = '{"crash":1,"deleted":1,"oom_killed":1,"replacement":1}' ]
	[ "$(jq -c '[.captures[] | select(.tag == "iter1" and .run_id != "RUN2") | [.run_id, .evidence, .cause]]' <<<"$output")" = '[["RUN1","istiod-diag-RUN1/001-iter1-ctx-a","oom_killed"],["RUN3","istiod-diag-RUN3/001-iter1-ctx-a","crash"]]' ]
	[ "$(jq -c '[.captures[] | select(.repeat) | .evidence]' <<<"$output")" = '["already_captured"]' ]
	# A trailing slash on the results dir gives the same relative paths.
	run --separate-stderr istiod_diag_report json "${RES}/"
	[ "$(jq -r '[.captures[].evidence] | index("istiod-diag-RUN3/001-iter1-ctx-a") != null' <<<"$output")" = true ]
	run istiod_diag_report md "$RES"
	assert_output --partial "## istiod restart diagnostics"
	assert_output --partial "5 row(s) from 4 \`istiod-diag-*/index.tsv\` file(s); by cause: oom_killed=1, crash=1, deleted=1, replacement=1."
	assert_output --partial "1 repeat row(s) of an already listed restart are not listed."
	assert_output --partial "| RUN1 | ctx-a | iter1 | istiod-abc-x1 | restarted_in_place | oom_killed | 137 | 300/3072 | istiod-diag-RUN1/001-iter1-ctx-a |"
	assert_output --partial "| RUN3 | ctx-a | iter1 | istiod-abc-x1 | restarted_in_place | crash |"
	refute_output --partial "already_captured"
	run istiod_diag_report text "$RES"
	assert_output --partial "istiod restart diagnostics: 5 row(s) from 4 istiod-diag-*/index.tsv file(s)"
	assert_output --partial "RUN2 | ctx-a | iter1 | istiod-abc-y2 | new_pod | replacement | exit=N/A | rss_pre/limit=N/A/3072 Mi | sweep-x/istiod-diag-RUN2/001-iter1-ctx-a"
	assert_output --partial "  RUN3 | ctx-a | iter1 | istiod-abc-x1 |"
	run istiod_diag_report csv "$RES"
	assert_success
	assert_output ""
}

# --- --config keys (every suite) ---

@test "--config: every suite takes the ISTIOD_DIAG_* keys; an unknown one is refused, naming them" {
	local f="${BATS_TEST_TMPDIR}/diag.env" s want=""
	printf '%s\n' ISTIOD_DIAG_ENABLED=0 ISTIOD_DIAG_REQUEST_TIMEOUT=1ms ISTIOD_DIAG_MAX_SEC=5 ISTIOD_DIAG_MAX_CAPTURES=2 \
		ISTIOD_DIAG_LOG_LINES=10 ISTIOD_DIAG_LOG_BYTES=4096 > "$f"
	# In a child bash: the key lists' loops are slow under the bats DEBUG trap.
	run --separate-stderr bash -c 'source "$1/tests/lib/common.sh"; ROOT="$1"; source "$1/tests/lib/config.sh"; f="$2"; shift 2
		for s in "$@"; do
			(load_config "$f" "$s" > /dev/null && echo "$s $ISTIOD_DIAG_ENABLED $ISTIOD_DIAG_REQUEST_TIMEOUT $ISTIOD_DIAG_MAX_SEC $ISTIOD_DIAG_MAX_CAPTURES $ISTIOD_DIAG_LOG_LINES $ISTIOD_DIAG_LOG_BYTES")
		done' _ "$ROOT" "$f" "${SUITES[@]}"
	assert_success
	for s in "${SUITES[@]}"; do want+="${s} 0 1ms 5 2 10 4096"$'\n'; done
	assert_output "${want%$'\n'}"
	printf 'ISTIOD_DIAG_TYPO=1\n' > "$f"
	run bash -c 'source "$1/tests/lib/common.sh"; ROOT="$1"; source "$1/tests/lib/config.sh"; load_config "$2" churn' _ "$ROOT" "$f"
	assert_failure
	assert_output --partial "unknown key ISTIOD_DIAG_TYPO"
	assert_output --partial "every suite also takes ISTIOD_DIAG_*"
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

# --- entrypoints (PL33) ---

# Stub kubectl and curl on PATH for the probes. istiod /metrics answers STUB_PRE_BODY
# until the measured window starts (STUB_MARK: the fortio load, the churn scale-up or
# the propagation t0 label), STUB_POST_BODY after. With STUB_REPLACE_ON_DRAIN, the
# propagation drain replaces istiod-abc-x1 by istiod-abc-y2 and kills its port-forward
# once (the next /metrics read fails). The churn targets settle at once.
_stub_bin() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark" FX
	export STUB_REPLACED="${BATS_TEST_TMPDIR}/replaced.mark" STUB_FAIL_ONCE="${BATS_TEST_TMPDIR}/fail-once.mark"
	# controlplane 002's kubectl top reads retry without a pause.
	export CAP_TOP_BACKOFF_S=0
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;  # the pin
*" fortio load "*" -json - "*) : > "$STUB_MARK"; cat "$FX/../fortio_ok.json" ;;
*" get pod -l app=fortio-client "*) printf 'fortio-client-0\t\tTrue' ;;
*" exec "*) cat "$FX/../fortio_ok.json" ;;
*" scale "*" --replicas=1 "*)
	if [[ -n "${STUB_REPLACE_ON_SCALE_DOWN:-}" ]]; then : > "$STUB_REPLACED"; fi ;;
*" scale "*) : > "$STUB_MARK" ;;
*" get pods -l churn-target=true "*) : ;;
*" label pod/"*"=true "*) : > "$STUB_MARK" ;;
*" label pod/"*)
	if [[ -n "${STUB_REPLACE_ON_DRAIN:-}" ]]; then : > "$STUB_REPLACED"; : > "$STUB_FAIL_ONCE"; fi ;;
*" wait pod/"*) : ;;
*" get pods -l app=propagation-canary "*) printf 'canary-backer-0\n' ;;
*" get deploy dataplane-server "*) printf '1/1' ;;
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0\t\tTrue' ;;
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

@test "dataplane 002 entrypoint: no restart, no diag call or folder; a restart sets its rows to 1, the index says oom_killed and the report's md and json tally it (csv prints nothing); every capture call failing leaves exit 0, the rows and a capture_failed row" {
	_stub_bin
	_dp_run
	assert_success
	f="$(ls "$RES"/latency-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $16 }' "$f" | sort -u)" = 0 ]
	run grep -E 'app=istiod -o json|get events|get deploy,rs|get node| logs ' "$STUB_LOG"
	assert_failure
	[ -z "$(ls -d "$RES"/istiod-diag-* 2>/dev/null)" ]
	RES="${BATS_TEST_TMPDIR}/res2"
	rm -f "$STUB_MARK"
	STUB_POST_BODY="$RESTARTED_BODY" _dp_run
	assert_success
	f="$(ls "$RES"/latency-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $16 }' "$f" | sort -u)" = 1 ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col cause istiod-abc-x1)/$(_col tag istiod-abc-x1)" = oom_killed/m1 ]
	[[ "$stderr" == *"istiod-diag: ctx-a istiod-abc-x1: change=restarted_in_place cause=oom_killed"* ]]
	run "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "## istiod restart diagnostics"
	assert_output --partial "oom_killed=1"
	# stdout only: the report's warnings (the stub reads no platform record) go to stderr (H5).
	run --separate-stderr "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '.istiod_diag.by_cause' <<<"$output")" = '{"oom_killed":1}' ]
	run "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$RES" --format csv
	refute_output --partial "oom_killed"
	RES="${BATS_TEST_TMPDIR}/res3"
	rm -f "$STUB_MARK"
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
	[ "$(_col tag istiod-abc-x1)/$(_col cause istiod-abc-x1)" = c7-baseline/oom_killed ]
	run --separate-stderr "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '.istiod_diag.by_cause' <<<"$output")" = '{"oom_killed":1}' ]
}

@test "controlplane 002 entrypoint, split phases as 003 runs it: a restart between baseline and final sets istiod_restarted=1 and captures an oom_killed row with the pre-window scrape" {
	_stub_bin
	SD="${BATS_TEST_TMPDIR}/state"
	mkdir -p "$SD"
	# 002 waits a fixed 3 s for its port-forwards; the stub has none to wait for.
	printf '#!/bin/sh\n[ "$*" = 3 ] && exit 0\nexec %s "$@"\n' "$(command -v sleep)" > "${BIN}/sleep"
	chmod +x "${BIN}/sleep"
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$RES" --phase baseline --state-dir "$SD"
	assert_success
	: > "$STUB_MARK"
	PATH="${BIN}:${PATH}" STUB_POST_BODY="$RESTARTED_BODY" run --separate-stderr "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$RES" --phase final --state-dir "$SD"
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
		--source-context ctx-a --timeout 2 --settle 0 --deployment-count 1 --output-dir "$RES" "$@"
}

@test "churn 002 entrypoint (PL32): a capture inside the iteration subshell, failing or not, never adds a row" {
	_stub_bin
	export CHURN_POLL_INTERVAL_MS=50
	STUB_POST_BODY="$RESTARTED_BODY" STUB_DIAG_FAIL=1 _churn_run --iterations 1
	assert_success
	f="$(ls "$RES"/churn-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $21 }' "$f")" = POISONED_RESTART ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col change)/$(_col tag)" = capture_failed/iter1 ]
	RES="${BATS_TEST_TMPDIR}/res2"
	rm -f "$STUB_MARK"
	STUB_POST_BODY="$RESTARTED_BODY" _churn_run --iterations 1
	assert_success
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id"' "$(ls "$RES"/churn-*.tsv)" | wc -l)" -eq 1 ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col cause istiod-abc-x1)" = oom_killed ]
	run "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$RES" --format md
	assert_output --partial "## istiod restart diagnostics"
}

@test "churn 002 entrypoint: a pod replaced during the scale-down is captured at the next re-open (podset_changed), and neither window is POISONED_RESTART" {
	_stub_bin
	export CHURN_POLL_INTERVAL_MS=50
	STUB_REPLACE_ON_SCALE_DOWN=1 STUB_PODS_JSON="${FX}/pods_deleted.json" _churn_run --iterations 2
	assert_success
	f="$(ls "$RES"/churn-*.tsv)"
	# MISSING_VALUE: this stub's watcher lists no churn target, so convergence_local_ms is N/A.
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $21 }' "$f" | sort -u)" = MISSING_VALUE ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col trigger istiod-abc-x1)/$(_col tag istiod-abc-x1)/$(_col change istiod-abc-x1)/$(_col rss_pre_mi istiod-abc-x1)" = podset_changed/before-iter2/replaced_gone/300 ]
	[ "$(_col change istiod-abc-y2)" = new_pod ]
}

_prop_run() {
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/propagation/002-run-endpoint-probe.sh" \
		--source-context ctx-a --poll-interval-ms 100 --settle-sec 0 --tsv --output-dir "$RES" "$@"
}

# _conv <body> <count> <sum>: <body> plus a convergence histogram. The t0 flip from count 0
# to 10 (10 samples for 5 proxies) makes P1 converge at once, so no run waits its timeout.
_conv() {
	cat "$1"
	printf 'pilot_proxy_convergence_time_bucket{le="0.1"} %s\npilot_proxy_convergence_time_bucket{le="+Inf"} %s\npilot_proxy_convergence_time_sum %s\npilot_proxy_convergence_time_count %s\n' "$2" "$2" "$3" "$2"
}

@test "propagation 002 entrypoint: the summary averages only the rows 005 counts and tallies the rest" {
	_stub_bin
	_conv "${FX}/pre_metrics.txt" 0 0 > "${BATS_TEST_TMPDIR}/pre.txt"
	_conv "${FX}/pre_metrics.txt" 10 0.5 > "${BATS_TEST_TMPDIR}/post.txt"
	STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre.txt" STUB_POST_BODY="${BATS_TEST_TMPDIR}/post.txt" _prop_run --iterations 1 --timeout 2
	assert_success
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --partial "rows_dropped_total=0/1"
	grep -qE '^\| P1 local xDS push \| 1/1 \| [0-9]+ \|' "$RES"/endpoint-*.md
	# The same P1 with no process_start_time_seconds: the row is written OK with
	# restarted=unknown, which 005 drops. The summary used to average it anyway.
	RES="${BATS_TEST_TMPDIR}/res2"
	rm -f "$STUB_MARK"
	grep -v '^process_start_time_seconds' "${BATS_TEST_TMPDIR}/pre.txt" > "${BATS_TEST_TMPDIR}/pre-u.txt"
	grep -v '^process_start_time_seconds' "${BATS_TEST_TMPDIR}/post.txt" > "${BATS_TEST_TMPDIR}/post-u.txt"
	STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre-u.txt" STUB_POST_BODY="${BATS_TEST_TMPDIR}/post-u.txt" _prop_run --iterations 1 --timeout 2
	assert_success
	f="$(ls "$RES"/endpoint-*.tsv)"
	[[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $16 }' "$f")" == OK/unknown ]]
	[[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $7 }' "$f")" =~ ^[0-9]+$ ]]
	assert_output --partial "P1 local xDS push:          n=0/1 (no valid sample)"
	assert_output --partial "rows_dropped_total=1/1"
	# A row with no remote measures P1 only, so its source side decides (p1_status).
	[[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $20 "/" $22 }' "$f")" == RESTART_UNKNOWN/N/A ]]
	assert_output --regexp 'RESTART_UNKNOWN +1'
	grep -qxF '| P1 local xDS push | 0/1 | - | - | - |' "$RES"/endpoint-*.md
	grep -qxF '| `RESTART_UNKNOWN` | 1 |' "$RES"/endpoint-*.md
	# 005 counts the same rows; n_attempted (the last column) is the probe's one iteration.
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line "1,P1_local_wall,1,0,,,,,,,,1"
}

@test "propagation 002 entrypoint: a restart in the window gives a RESTART row and an oom_killed index row; a pod replaced between iterations is captured at the re-open (podset_changed)" {
	_stub_bin
	export STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre.txt"
	_conv "${FX}/pre_metrics.txt" 0 0 > "$STUB_PRE_BODY"
	_conv "$RESTARTED_BODY" 10 0.5 > "${BATS_TEST_TMPDIR}/restarted.txt"
	_conv "${FX}/pre_metrics.txt" 10 0.5 > "${BATS_TEST_TMPDIR}/post.txt"
	STUB_POST_BODY="${BATS_TEST_TMPDIR}/restarted.txt" _prop_run --iterations 1 --timeout 1
	assert_success
	f="$(ls "$RES"/endpoint-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $16 }' "$f")" = RESTART/1 ]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col cause istiod-abc-x1)/$(_col tag istiod-abc-x1)" = oom_killed/iter1 ]
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '.istiod_diag.by_cause' <<<"$output")" = '{"oom_killed":1}' ]
	RES="${BATS_TEST_TMPDIR}/res2"
	rm -f "$STUB_MARK"
	STUB_POST_BODY="${BATS_TEST_TMPDIR}/post.txt" STUB_REPLACE_ON_DRAIN=1 STUB_PODS_JSON="${FX}/pods_deleted.json" \
		_prop_run --iterations 2 --timeout 1
	assert_success
	[[ "$stderr" == *"re-opening fanout block"* ]]
	D="$(dirname "$(ls "$RES"/istiod-diag-*/index.tsv)")"
	[ "$(_col trigger istiod-abc-x1)/$(_col change istiod-abc-x1)/$(_col tag istiod-abc-x1)/$(_col rss_pre_mi istiod-abc-x1)" = podset_changed/replaced_gone/iter1/300 ]
	[ "$(_col change istiod-abc-y2)/$(_col cause istiod-abc-y2)" = new_pod/replacement ]
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
