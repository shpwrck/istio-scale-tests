#!/usr/bin/env bash
# istiod restart diagnostics: save the evidence of an istiod restart at the moment a
# suite detects it. Sourced, never executed.
#
# Consumers: controlplane (002), dataplane (002, 004), churn (002, 004),
#   churn-dataplane (002, 003, 005), propagation (002, 005); tuning runs them.
#
# A suite calls istiod_diag_capture where it has decided a context's istiod restarted
# (istiod_restarted 1 or unknown, POISONED_RESTART, RESTART) or its istiod pod set
# changed, after the row is written. The capture lists the context's istiod pods once,
# works out what changed against the suite's own pre-window pod set and /metrics
# scrape, and saves the evidence that expires first: the previous container's logs
# (gone at the next restart or delete), the istio-system events (gone after a few
# hours), the Deployment and ReplicaSet revisions, the nodes' conditions and events.
# One sanitized index row per affected pod goes to
#   <dir of the run's TSV>/istiod-diag-<RUN_ID>/index.tsv
# and the raw evidence to a numbered folder beside it. The capture never changes a row
# or its status: rows stay poisoned as before (PL13, PL15).
#
# Cost: nothing when no restart was detected (the suites call it only on a non-0
# status). Per call: one pod list. With an affected pod not captured yet and budget
# left: one Deployment/ReplicaSet list, one istio-system event list, one log fetch per
# affected pod (at most 10) and two reads per node (at most 3). Every call carries
# --request-timeout, and no call starts after ISTIOD_DIAG_MAX_SEC.
#
# Best-effort (PL40): the work runs in a subshell with its stderr in <dir>/.capture.err.
# istiod_diag_capture always returns 0; a failure becomes an index row
# (change=capture_failed) carrying the sanitized error, never a dead run.
#
# Redaction: index.tsv, summary.md and README.md hold no IPs and no node names. Free
# text has the node and context names replaced (<node>, <ctx>), then goes through
# reach_sanitize. The context column holds the context name, as every suite TSV does;
# replace it with a placeholder before quoting a row. The raw evidence (logs, events,
# pod, node and ReplicaSet JSON) keeps host and node names, which stack traces need,
# with IPs, bearer tokens and JWTs masked. It lives under the gitignored results dir
# and must never be committed.
#
# Knobs (config/options.env; read at call time, settable from --config in every suite):
#   ISTIOD_DIAG_ENABLED (0 = off), ISTIOD_DIAG_REQUEST_TIMEOUT, ISTIOD_DIAG_MAX_SEC,
#   ISTIOD_DIAG_MAX_CAPTURES, ISTIOD_DIAG_LOG_LINES, ISTIOD_DIAG_LOG_BYTES.
#
# Exposes:
#   istiod_diag_dir <tsv_file> <run_id>  -> <dir of tsv_file>/istiod-diag-<run_id>
#   istiod_diag_capture <diag_dir> <tag> <ctx> <trigger> <pre_podset|''> <pre_metrics_csv|''> <kubectl argv...>
#        trigger: 1 | unknown | podset_changed | no_running_pods (recorded as given).
#        pre_podset: file of the pre-window pod names, one per line, lined up with
#        pre_metrics_csv (comma-joined per-pod /metrics files; the <file>.ts beside one
#        holds its scrape time in ns or ms). Without a pod set, every istiod pod that
#        restarted or is not Running counts. Always returns 0.
#   istiod_diag_after_window <ts>        -> controlplane 002: capture for every context
#        whose rows of the window <ts> in $TSV_FILE have istiod_restarted != 0 (columns
#        found by header name). Reads TSV_FILE, RUN_ID, TMP_DIR (baseline-<k>.metrics),
#        POD_CTXS, POD_NAMES, KUBECTL. A context with no istiod pod gets no_running_pods.
#   istiod_diag_report <text|md|csv|json> <results_dir>
#        -> the "istiod restart diagnostics" section over every istiod-diag-*/index.tsv
#           under results_dir: a tally by cause, then one line per restart with its
#           run (RUN_ID) and its evidence folder relative to results_dir
#           (istiod-diag-<RUN_ID>/NNN-...). Rows of one restart seen more than once
#           (same context, pod, restart count and start time; a replaced pod by name)
#           are listed once, preferring the row with a folder; the rest are repeats.
#           restarted_untimed rows stay out of the tally (the restart may predate the
#           window) and are counted apart. csv prints nothing (CSV output carries no
#           comment lines); json prints one object for the caller's "istiod_diag" key.
#
# index.tsv (ISTIOD_DIAG_SCHEMA=1): a `# KEY=value` preamble, then one row per pod:
#   captured_at tag context trigger pod change cause restart_count exit_code signal
#   term_reason started_at finished_at mem_limit_mi rss_pre_mi heap_inuse_pre_mi
#   goroutines_pre proxies_pre pre_scrape_at rs_changed node_ready_at evidence note
# trigger: 1 | unknown | podset_changed | no_running_pods, as the suite passed it.
# change: restarted_in_place, restarted_untimed (restarts but no pre-window start time
#   to place them: the restart may predate the window), replaced_gone, replaced_failed,
#   replaced_terminating, new_pod, not_running (no pod set given), no_change, no_pods,
#   capture_failed.
# cause: oom_killed, probe_kill, crash, killed, exited, node_restart, no_last_state;
#   evicted, preempted, node_lost, rollout, deleted, scaled, replaced_unknown;
#   replacement (a new pod standing in for a replaced one); no_restart_found,
#   no_istiod_pods, unknown (capture failed).
# rs_changed (replaced and new pods): 1 when the ReplicaSets changed (a new pod's is
#   not a pre-window one, or a replaced pod's runs no new or Running pod now: a
#   rollout), 0 when they match, N/A when there is nothing to compare (in-place
#   restarts, no ReplicaSet owner).
# evidence: the evidence folder, or why there is none: already_captured (this restart
#   has a folder from an earlier call), already_reported (an earlier call wrote a row
#   for it without a folder, and this one could not make one either),
#   budget_exhausted (ISTIOD_DIAG_MAX_CAPTURES reached), skipped_deadline
#   (ISTIOD_DIAG_MAX_SEC spent), capture_failed, or - when nothing changed. Only the
#   pod list feeds the cause of a row without a folder.
# Clocks: captured_at and pre_scrape_at come from the harness clock; started_at,
# finished_at and node_ready_at from the cluster. Restart timing compares only
# cluster-side values: the pre-window process_start_time_seconds against the
# container's startedAt (or its last finishedAt). One exception, for a pod whose
# pre-window scrape has no start time (failed or short): a running container that
# started more than _ISTIOD_DIAG_CLOCK_MARGIN_SEC before that scrape (harness clock)
# restarted before the window, so the pod counts as no_change, not restarted_untimed.
#
# Requires: common.sh (is_nonneg_int, is_pos_int, file_min_bytes, MD_CELL_AWK,
# ctx_file_safe, CTX_FILE_NAME_MAX, RUN_ID_FILE_NAME_MAX, TAG_FILE_NAME_MAX), reach.sh
# (reach_sanitize), jq, awk, sed, tail, mktemp; gzip when present (evidence stays
# uncompressed without it); common.sh's harness_read (else HARNESS_SHA and
# HARNESS_CONTENT_KEY are unknown). Callers run `set -euo pipefail`.
# shellcheck shell=bash

ISTIOD_DIAG_SCHEMA=1
# Fixed bounds, not tunables.
_ISTIOD_DIAG_FETCH_BYTES=8388608   # kubectl logs --limit-bytes for a full log (an integer)
_ISTIOD_DIAG_STARTUP_BYTES=262144  # a new pod's startup log (its first 256 KiB)
_ISTIOD_DIAG_MAX_EVENTS=100        # istio-system events kept (newest)
_ISTIOD_DIAG_MAX_NODE_EVENTS=50    # events kept per node (newest)
_ISTIOD_DIAG_MAX_PODS=10           # pods per capture that get their logs fetched
_ISTIOD_DIAG_MAX_NODES=3           # nodes per capture
_ISTIOD_DIAG_NODE_WINDOW_SEC=300   # node Ready at most this long before the start -> node_restart
_ISTIOD_DIAG_SLACK_SEC=2           # a start must beat the pre-window start by more than this
_ISTIOD_DIAG_CLOCK_MARGIN_SEC=300  # harness vs cluster clock allowance (untimed restarts only)
_ISTIOD_DIAG_HEADER=(captured_at tag context trigger pod change cause restart_count exit_code
	signal term_reason started_at finished_at mem_limit_mi rss_pre_mi heap_inuse_pre_mi
	goroutines_pre proxies_pre pre_scrape_at rs_changed node_ready_at evidence note)

# jq helpers shared by the projections: Kubernetes memory quantity -> MiB (floor),
# ISO time -> epoch seconds ("" when absent or unparsable), one-line non-empty field.
# shellcheck disable=SC2016  # jq program, not shell
_ISTIOD_DIAG_JQ_DEFS='
def mem_mi($q):
	if $q == null then "N/A" else
		([($q | tostring) | capture("^(?<n>[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?)(?<u>[A-Za-z]*)$")] | .[0]) as $c
		| if $c == null then "N/A" else
			({"": 1, "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776,
			  "k": 1000, "M": 1000000, "G": 1000000000, "T": 1000000000000}[$c.u]) as $m
			| if $m == null then "N/A" else ((($c.n | tonumber) * $m / 1048576) | floor | tostring) end
		end
	end;
def ep: if . == null or . == "" then "" else ((sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) // "") end;
def ep_safe: (try ep catch "");
def clean: tostring | gsub("[\t\r\n]+"; " ") | if . == "" then "-" else . end;
def disc(f): (f // []) | ((map(select(.name == "discovery")) + .)[0] // {});
'

# The pod list, projected: no IPs, env or managedFields.
# shellcheck disable=SC2016
_ISTIOD_DIAG_JQ_PODS='
if (.items | type) != "array" then error("no pod list in the reply") else . end
| {items: [.items[] | (disc(.status.containerStatuses)) as $c | (disc(.spec.containers)) as $s | {
	name: .metadata.name,
	phase: (.status.phase // "Unknown"),
	deleting: (.metadata.deletionTimestamp != null),
	created: (.metadata.creationTimestamp // ""),
	owner_rs: ([.metadata.ownerReferences[]? | select(.kind == "ReplicaSet") | .name][0] // ""),
	node: (.spec.nodeName // ""),
	container: ($s.name // "discovery"),
	status_reason: (.status.reason // ""),
	status_message: (.status.message // ""),
	mem_limit_mi: mem_mi($s.resources.limits.memory),
	restart_count: ($c.restartCount // 0),
	ready: ($c.ready // false),
	state: ($c.state // {}),
	last_state: ($c.lastState // {}),
	conditions: [.status.conditions[]? | {type, status, lastTransitionTime, reason}]
}]}'

# One TSV line per pod of the projection; every field non-empty ("-"), so a tab
# split keeps the columns (IFS treats a run of tabs as one separator).
# shellcheck disable=SC2016
_ISTIOD_DIAG_JQ_PODS_TSV='
.items[] | (.last_state.terminated // null) as $t | (.state.terminated // null) as $ct
| (.state.running.startedAt // .state.terminated.startedAt // "") as $st
| [ .name, .phase, (if .deleting then 1 else 0 end), .owner_rs, .node, .restart_count,
	$st, ($st | ep_safe), (if $t then 1 else 0 end),
	($t.reason // ""), ($t.exitCode // ""), ($t.signal // ""), ($t.finishedAt // ""),
	(($t.finishedAt // "") | ep_safe), .mem_limit_mi, .status_reason,
	(.state.waiting.reason // ""),
	((($t.message // "") | split("\n") | map(select(test("panic|fatal"; "i"))) | .[0]) // ""),
	.status_message, ($ct.reason // ""), ($ct.exitCode // ""), ($ct.finishedAt // ""),
	.container ]
| map(clean) | join("\t")'

# Events: newest $max, as time type reason kind name count message. $pfx keeps only
# objects named with it ("" keeps all).
# shellcheck disable=SC2016
_ISTIOD_DIAG_JQ_EVENTS='
[.items[]? | select((.involvedObject.name // "") | startswith($pfx))
	| {t: (.lastTimestamp // .eventTime // .firstTimestamp // .metadata.creationTimestamp // ""),
	   type: (.type // ""), reason: (.reason // ""), kind: (.involvedObject.kind // ""),
	   name: (.involvedObject.name // ""), count: (.count // 1), message: (.message // "")}]
| sort_by(.t) | .[-$max:][] | [.t, .type, .reason, .kind, .name, .count, .message] | map(clean) | join("\t")'

# Deployments and ReplicaSets of istiod: revisions, generations, replicas, limit (PL39).
# shellcheck disable=SC2016
_ISTIOD_DIAG_JQ_DEPLOY_RS='
[.items[]? | select(((.metadata.labels.app // "") == "istiod") or ((.metadata.name // "") | startswith("istiod")))
	| {kind, name: .metadata.name, created: (.metadata.creationTimestamp // ""),
	   revision: (.metadata.annotations["deployment.kubernetes.io/revision"] // ""),
	   generation: .metadata.generation, observed_generation: .status.observedGeneration,
	   replicas: .spec.replicas, ready: .status.readyReplicas, updated: .status.updatedReplicas,
	   available: .status.availableReplicas,
	   owner: ([.metadata.ownerReferences[]?.name][0] // ""),
	   mem_limit_mi: mem_mi(disc(.spec.template.spec.containers).resources.limits.memory)}]'

# A node: conditions, memory, boot id (no addresses).
# shellcheck disable=SC2016
_ISTIOD_DIAG_JQ_NODE='
{name: .metadata.name, boot_id: (.status.nodeInfo.bootID // ""),
 kubelet: (.status.nodeInfo.kubeletVersion // ""),
 allocatable_memory: (.status.allocatable.memory // ""), capacity_memory: (.status.capacity.memory // ""),
 conditions: [.status.conditions[]? | {type, status, lastTransitionTime, reason, message}]}'

# --- small helpers ------------------------------------------------------------

# File and folder names: ctx_file_safe (tests/lib/common.sh), the one file-name form of a
# context that tuning's state files and redact-results.sh's renames use too: every byte
# outside [A-Za-z0-9._-] becomes _ in any locale (no ':' or '+', for NTFS copies). A
# context in a folder name is cut to CTX_FILE_NAME_MAX characters, a run id to
# RUN_ID_FILE_NAME_MAX (64), a tag to TAG_FILE_NAME_MAX (48). An empty token reads x.

# _istiod_diag_now: harness UTC time, ISO 8601 (portable: no GNU date flags).
# shellcheck disable=SC2329
_istiod_diag_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _istiod_diag_int <VAR> <default> <pos|nonneg>: the knob's value, or the default with a
# warning when it is not an integer of that kind.
# shellcheck disable=SC2329
_istiod_diag_int() {
	local name="$1" def="$2" kind="$3" v
	v="${!name:-$def}"
	if [[ "$kind" == pos ]] && is_pos_int "$v"; then
		printf '%s\n' "$v"
	elif [[ "$kind" == nonneg ]] && is_nonneg_int "$v"; then
		printf '%s\n' "$v"
	else
		echo "warning: ${name}='${v}' is not a valid integer; using ${def}" >&2
		printf '%s\n' "$def"
	fi
}

# _istiod_diag_settings: the knobs, validated, into _IDG_*. ISTIOD_DIAG_REQUEST_TIMEOUT
# goes to kubectl unchanged (a bare integer is seconds; 15s, 500ms and 1ms are durations).
# shellcheck disable=SC2329
_istiod_diag_settings() {
	_IDG_RT="${ISTIOD_DIAG_REQUEST_TIMEOUT:-15}"
	if ! [[ "$_IDG_RT" =~ ^[0-9]+(ms|s|m|h)?$ ]]; then
		echo "warning: ISTIOD_DIAG_REQUEST_TIMEOUT='${_IDG_RT}' is not a kubectl --request-timeout (15, 15s, 500ms); using 15" >&2
		_IDG_RT=15
	fi
	_IDG_MAX_SEC="$(_istiod_diag_int ISTIOD_DIAG_MAX_SEC 120 nonneg)"
	_IDG_MAX_CAPTURES="$(_istiod_diag_int ISTIOD_DIAG_MAX_CAPTURES 20 nonneg)"
	_IDG_LOG_LINES="$(_istiod_diag_int ISTIOD_DIAG_LOG_LINES 5000 pos)"
	_IDG_LOG_BYTES="$(_istiod_diag_int ISTIOD_DIAG_LOG_BYTES 1048576 pos)"
}

# _istiod_diag_mask: stdin -> stdout with IPv4/IPv6 addresses, bearer tokens and JWTs
# masked, for the raw evidence (hosts are kept; same address forms as reach_sanitize).
# shellcheck disable=SC2329
_istiod_diag_mask() {
	sed -E \
		-e 's/([Bb]earer)[[:space:]]+[A-Za-z0-9._~+\/=-]+/\1 <token>/g' \
		-e 's/eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*/<jwt>/g' \
		-e 's/\[[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*(%[0-9A-Za-z_.-]+)?]/<ip>/g' \
		-e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' \
		-e 's/(^|[^0-9A-Za-z_])[0-9A-Fa-f:]*([0-9A-Fa-f]::|::[0-9A-Fa-f])([0-9A-Fa-f:]*[0-9A-Fa-f])?(%[0-9A-Za-z_.-]+)?/\1<ip>/g' \
		-e 's/(^|[^0-9A-Za-z_])([0-9A-Fa-f]{1,4}:){3,}[0-9A-Fa-f]{1,4}(%[0-9A-Za-z_.-]+)?/\1<ip>/g'
}

# _istiod_diag_text <text> <ctx> [node...]: free text for the index or summary.md: the
# node names and the context name replaced, then reach_sanitize (one line, IPs and
# dotted hosts masked, <= 256 characters).
# shellcheck disable=SC2329
_istiod_diag_text() {
	local t="${1:-}" ctx="${2:-}" n
	shift 2 || true
	for n in "$@"; do
		[[ -n "$n" && "$n" != "-" ]] && t="${t//"$n"/<node>}"
	done
	[[ -n "$ctx" ]] && t="${t//"$ctx"/<ctx>}"
	reach_sanitize "$t"
}

# _istiod_diag_gzip <file>: gzip in place when gzip exists; leave it as is otherwise.
# shellcheck disable=SC2329
_istiod_diag_gzip() {
	command -v gzip >/dev/null 2>&1 || return 0
	gzip -f "$1" 2>/dev/null || true
}

# _istiod_diag_ts_sec <ts_file>: a scrape stamp (epoch ns, ms or s, by its digit count)
# as epoch seconds, or nothing.
# shellcheck disable=SC2329
_istiod_diag_ts_sec() {
	local v=""
	[[ -n "${1:-}" && -s "${1:-}" ]] && v="$(head -n 1 "$1" 2>/dev/null)"
	v="${v//[^0-9]/}"
	v="${v#"${v%%[1-9]*}"}"  # no leading zeros (bash would read octal)
	[[ -n "$v" && ${#v} -le 19 ]] || return 0
	if ((${#v} >= 18)); then echo $((v / 1000000000))
	elif ((${#v} >= 12)); then echo $((v / 1000))
	else echo "$v"
	fi
}

# _istiod_diag_ts_iso <ts_file>: a scrape stamp as ISO UTC, or N/A.
# shellcheck disable=SC2329
_istiod_diag_ts_iso() {
	local s
	s="$(_istiod_diag_ts_sec "${1:-}")"
	[[ -n "$s" ]] || { echo N/A; return 0; }
	jq -nr --argjson s "$s" '$s | todate' 2>/dev/null || echo N/A
}

# _istiod_diag_pre_values <metrics_file>: "start rss_mi heap_inuse_mi goroutines proxies"
# from one awk pass over a pre-window scrape (PL21, PL22). A missing, empty or short
# body (under FANOUT_MIN_SCRAPE_BYTES) gives N/A for every field, never 0 (PL29).
# proxies sums pilot_xds over its label series (PL12).
# shellcheck disable=SC2329
_istiod_diag_pre_values() {
	local f="${1:-}" out=""
	# No wc fork per file (file_min_bytes, common.sh); the same rule as before.
	if [[ -n "$f" && -s "$f" ]] && file_min_bytes "$f" "${FANOUT_MIN_SCRAPE_BYTES:-512}"; then
		out="$(awk '
			function v(x, d) { return (x == "") ? "N/A" : sprintf("%.0f", x / d) }
			/^#/ { next }
			$1 == "process_start_time_seconds" { pst = $NF; next }
			$1 == "process_resident_memory_bytes" { rss = $NF; next }
			$1 == "go_memstats_heap_inuse_bytes" { heap = $NF; next }
			$1 == "go_goroutines" { gr = $NF; next }
			$1 == "pilot_xds" || index($1, "pilot_xds{") == 1 { xds += $NF; xs = 1 }
			END {
				s = v(pst, 1); if (s == "0") s = "N/A"
				printf "%s %s %s %s %s\n", s, v(rss, 1048576), v(heap, 1048576), v(gr, 1), (xs ? sprintf("%.0f", xds) : "N/A")
			}' "$f" 2>/dev/null)" || out=""
	fi
	[[ -n "$out" ]] || out="N/A N/A N/A N/A N/A"
	printf '%s\n' "$out"
}

# _istiod_diag_panic_line <log_base>: the first panic/fatal line of a saved log
# (<log_base>.gz or <log_base>), or nothing.
# shellcheck disable=SC2329
_istiod_diag_panic_line() {
	local b="$1"
	if [[ -f "${b}.gz" ]]; then
		gzip -dc "${b}.gz" 2>/dev/null | awk 'tolower($0) ~ /panic|fatal/ { print; exit }' 2>/dev/null || true
	elif [[ -f "$b" ]]; then
		awk 'tolower($0) ~ /panic|fatal/ { print; exit }' "$b" 2>/dev/null || true
	fi
}

# _istiod_diag_event <events_tsv> <pod> <reason_re> <message_re>: true when an event of
# <pod> matches both regexes (events_tsv: time type reason kind name count message).
# shellcheck disable=SC2329
_istiod_diag_event() {
	[[ -s "$1" ]] || return 1
	awk -F'\t' -v p="$2" -v r="$3" -v m="$4" '$5 == p && $3 ~ r && $7 ~ m { f = 1; exit } END { exit !f }' "$1"
}

# _istiod_diag_readme: the README.md of an istiod-diag-<RUN_ID>/ folder.
# shellcheck disable=SC2329
_istiod_diag_readme() {
	cat <<'README'
# istiod restart diagnostics

Written by `tests/lib/istiod-diag.sh` when a suite detected an istiod restart
(`istiod_restarted` 1 or unknown, `POISONED_RESTART`, `RESTART`) or a changed istiod
pod set. The suite's rows are unchanged; this folder only adds evidence.

- `index.tsv`: one row per affected pod (schema in the `# ISTIOD_DIAG_SCHEMA=` line,
  columns in the header). Free text is sanitized: no IPs, node names or context names.
  The `context` column holds the context name, as the suite TSVs do.
- `NNN-<tag>-<context>/`: the raw evidence of one capture:
  - `summary.md`: sanitized summary, plus a PromQL query for the memory history
  - `pods.json`: istiod pod status (no IPs, env or managedFields)
  - `deploy-rs.json`: Deployment and ReplicaSet revisions and memory limits
  - `events.tsv`: the newest istio-system events of istiod objects
  - `<pod>.previous.log.gz`, `<pod>.log.gz`: the last ISTIOD_DIAG_LOG_BYTES of a log;
    `<pod>.startup.log.gz`: the first 256 KiB of a new pod's log
  - `<pod>.pre.metrics.gz`: the suite's last /metrics scrape before the window
  - `node-<n>.json`, `node-<n>-events.tsv`: node conditions, memory and events
  - `*.unavailable`: why that piece could not be fetched
- `.seen`, `.reported`: the keys of the restarts that have a folder or only a row, so
  a later call writes `already_captured` or `already_reported` instead of counting a
  restart twice.

Redaction: the raw evidence keeps host and node names (stack traces need them); IPs,
bearer tokens and JWTs are masked. Never commit this folder (its `.gitignore` ignores
everything in it, wherever the results dir is). Quote only `index.tsv` or `summary.md`,
after replacing context names with placeholders.
README
}

# _istiod_diag_init <dir>: the single writer (PL36) of README.md, the folder's .gitignore
# (everything: the raw evidence must not be committed even under a tracked --output-dir)
# and the index.tsv preamble and header; a no-op for the parts that exist.
# shellcheck disable=SC2329
_istiod_diag_init() {
	local dir="$1" idx="${1}/index.tsv" run_id sha=unknown key=unknown
	mkdir -p "$dir" || return 1
	if [[ ! -f "${dir}/README.md" ]]; then
		_istiod_diag_readme > "${dir}/README.md" || return 1
	fi
	if [[ ! -f "${dir}/.gitignore" ]]; then
		printf '# Raw istiod restart evidence: never commit (see README.md).\n*\n' > "${dir}/.gitignore" || return 1
	fi
	[[ -f "$idx" ]] && return 0
	run_id="${dir##*/}"
	run_id="${run_id#istiod-diag-}"
	# The harness without the probe's output dir this folder is in (its results would read
	# dirty), as the probe's own TSV records it.
	if declare -F harness_read >/dev/null 2>&1; then
		harness_read sha key --exclude "$(dirname "$dir")" 2>/dev/null || true
	fi
	{
		echo "# ISTIOD_DIAG_SCHEMA=${ISTIOD_DIAG_SCHEMA}"
		echo "# RUN_ID=${run_id}"
		echo "# CREATED_BY=${0##*/}"
		echo "# HARNESS_SHA=${sha:-unknown}"
		echo "# HARNESS_CONTENT_KEY=${key:-unknown}"
		echo "# DATE=$(_istiod_diag_now)"
		echo "# ISTIOD_DIAG_REQUEST_TIMEOUT=${_IDG_RT}"
		echo "# ISTIOD_DIAG_MAX_SEC=${_IDG_MAX_SEC}"
		echo "# ISTIOD_DIAG_MAX_CAPTURES=${_IDG_MAX_CAPTURES}"
		echo "# ISTIOD_DIAG_LOG_LINES=${_IDG_LOG_LINES}"
		echo "# ISTIOD_DIAG_LOG_BYTES=${_IDG_LOG_BYTES}"
		(IFS=$'\t'; echo "${_ISTIOD_DIAG_HEADER[*]}")
	} > "$idx"
}

# _istiod_diag_row <dir> <field...>: append one index row; tabs and newlines in a field
# become spaces, an empty field N/A.
# shellcheck disable=SC2329
_istiod_diag_row() {
	local dir="$1" f line="" sep=""
	shift
	for f in "$@"; do
		f="${f//[$'\t\r\n']/ }"
		[[ -n "$f" ]] || f="N/A"
		line+="${sep}${f}"
		sep=$'\t'
	done
	printf '%s\n' "$line" >> "${dir}/index.tsv"
}

# _istiod_diag_fail_row <dir> <tag> <ctx> <trigger> <error line>: the row of a capture
# that failed before writing its own rows.
# shellcheck disable=SC2329
_istiod_diag_fail_row() {
	local dir="$1" tag="$2" ctx="$3" trigger="$4" err="${5:-}"
	_istiod_diag_init "$dir" || return 1
	[[ -n "$err" ]] || err="the capture stopped without an error message"
	_istiod_diag_row "$dir" "$(_istiod_diag_now)" "$tag" "$ctx" "$trigger" - capture_failed unknown \
		N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A capture_failed \
		"$(_istiod_diag_text "$err" "$ctx")"
}

# _istiod_diag_time_ok: true while the capture's wall-clock budget lasts.
# shellcheck disable=SC2329
_istiod_diag_time_ok() { (( SECONDS < _IDG_DEADLINE )); }

# _istiod_diag_log <folder> <ctx> <pod> <container> <previous|current|startup> <kubectl...>:
# one log fetch, masked, cut to its bound and gzipped. Returns 1 and leaves
# <file>.unavailable (the masked kubectl error) when the fetch fails; the error line
# is in _IDG_LOG_ERR.
# shellcheck disable=SC2329
_istiod_diag_log() {
	local f="$1" ctx="$2" pod="$3" cont="$4" kind="$5" out
	shift 5
	local raw="${_IDG_WORK}/log.raw" err="${_IDG_WORK}/log.err"
	local -a args=(logs "$pod" -c "$cont" --request-timeout="$_IDG_RT")
	case "$kind" in
	previous) args+=(--previous --tail="$_IDG_LOG_LINES" --limit-bytes="$_ISTIOD_DIAG_FETCH_BYTES"); out="${pod}.previous.log" ;;
	current) args+=(--tail="$_IDG_LOG_LINES" --limit-bytes="$_ISTIOD_DIAG_FETCH_BYTES"); out="${pod}.log" ;;
	*) args+=(--limit-bytes="$_ISTIOD_DIAG_STARTUP_BYTES"); out="${pod}.startup.log" ;;
	esac
	_IDG_LOG_ERR=""
	if "$@" --context="$ctx" -n istio-system "${args[@]}" > "$raw" 2> "$err"; then
		# Mask first, then keep the last bytes, so the kept file never exceeds the bound.
		if [[ "$kind" == startup ]]; then
			_istiod_diag_mask < "$raw" > "${f}/${out}"
		else
			_istiod_diag_mask < "$raw" | tail -c "$_IDG_LOG_BYTES" > "${f}/${out}"
		fi
		_istiod_diag_gzip "${f}/${out}"
		rm -f "$raw" "$err"
		return 0
	fi
	_IDG_LOG_ERR="$(tail -n 1 "$err" 2>/dev/null)"
	[[ -n "$_IDG_LOG_ERR" ]] || _IDG_LOG_ERR="kubectl logs failed"
	printf 'kubectl logs (%s) failed: %s\n' "$kind" "$_IDG_LOG_ERR" | _istiod_diag_mask > "${f}/${out}.unavailable"
	rm -f "$raw" "$err"
	return 1
}

# _istiod_diag_restart_change <pre_start> <started_epoch> <last_finished_epoch> <restart_count> [pre_scrape_sec]:
# restarted_in_place when the container started, or its last run ended, after the
# scraped process started (both cluster-side clocks). Without a pre-window start time
# but with restarts: predates_window when the running container started, and its last
# run ended, more than _ISTIOD_DIAG_CLOCK_MARGIN_SEC before the pre-window scrape
# (harness clock; the margin covers clock skew), else restarted_untimed. no_change
# otherwise.
# shellcheck disable=SC2329
_istiod_diag_restart_change() {
	local pre="$1" st="$2" lf="$3" rc="$4" at="${5:-}" m=$_ISTIOD_DIAG_CLOCK_MARGIN_SEC
	if [[ "$pre" =~ ^[1-9][0-9]*$ ]]; then
		if [[ "$st" =~ ^[0-9]+$ ]] && (( st > pre + _ISTIOD_DIAG_SLACK_SEC )); then
			echo restarted_in_place
		elif [[ "$lf" =~ ^[0-9]+$ ]] && (( lf > pre + _ISTIOD_DIAG_SLACK_SEC )); then
			echo restarted_in_place
		else
			echo no_change
		fi
	elif [[ "$rc" =~ ^[1-9][0-9]*$ ]]; then
		if [[ "$at" =~ ^[1-9][0-9]*$ && "$st" =~ ^[0-9]+$ ]] && (( st + m < at )) \
			&& { [[ ! "$lf" =~ ^[0-9]+$ ]] || (( lf + m < at )); }; then
			echo predates_window
		else
			echo restarted_untimed
		fi
	else
		echo no_change
	fi
}

# --- the capture ----------------------------------------------------------------

# _istiod_diag_run_exit <rc>: the capture subshell's EXIT trap. An exit the run did not
# explain itself (a die or exit in a helper or in the kubectl wrapper) names the last
# error a call left in the work dir, so the capture_failed row carries a reason. It
# appends to <dir>/.capture.err by name: the exit may come from inside a call whose
# stderr is redirected, and the trap runs under that redirection. Then the work dir goes.
# shellcheck disable=SC2329
_istiod_diag_run_exit() {
	local rc="$1" f="" g msg
	if ((rc != 0)) && [[ -z "${_IDG_EXPLAINED:-}" && -d "${_IDG_WORK:-}" && -n "${_IDG_ERRFILE:-}" ]]; then
		for g in "${_IDG_WORK}"/*.err; do
			[[ -s "$g" ]] || continue
			[[ -z "$f" || "$g" -nt "$f" ]] && f="$g"
		done
		msg="the capture stopped (exit ${rc}) without an error message"
		[[ -n "$f" ]] && msg="the capture stopped (exit ${rc}): $(tail -n 1 "$f" 2>/dev/null)"
		printf '%s\n' "$msg" >> "$_IDG_ERRFILE" 2>/dev/null || true
	fi
	rm -rf "${_IDG_WORK:-}"
}

# _istiod_diag_run <dir> <tag> <ctx> <trigger> <podset> <pre_csv> <kubectl...>: the
# capture proper. Runs in a subshell (stderr -> .capture.err) where `set -e` may be off,
# so every step checks its own status. Returns non-zero only when it wrote no row.
# shellcheck disable=SC2329
_istiod_diag_run() {
	local dir="$1" tag="$2" ctx="$3" trigger="$4" podset="$5" pre_csv="$6"
	shift 6
	local -a kc=("$@")
	_IDG_DEADLINE=$(( SECONDS + _IDG_MAX_SEC ))
	_IDG_EXPLAINED=""
	_IDG_ERRFILE="${dir}/.capture.err"
	_istiod_diag_init "$dir" || { echo "cannot write ${dir}/index.tsv" >&2; return 1; }
	_IDG_WORK="$(mktemp -d "${dir}/.work.XXXXXX")" || { echo "cannot create a work dir in ${dir}" >&2; return 1; }
	trap '_istiod_diag_run_exit $?' EXIT
	local work="$_IDG_WORK" now
	now="$(_istiod_diag_now)"

	# 1. The pod list: the one call every trigger costs.
	if ! "${kc[@]}" --context="$ctx" -n istio-system get pods -l app=istiod -o json \
		--request-timeout="$_IDG_RT" > "${work}/pods.raw" 2> "${work}/pods.err"; then
		echo "istiod pod list failed: $(tail -n 1 "${work}/pods.err" 2>/dev/null)" >&2
		_IDG_EXPLAINED=1
		return 1
	fi
	if ! jq -e "${_ISTIOD_DIAG_JQ_DEFS}${_ISTIOD_DIAG_JQ_PODS}" "${work}/pods.raw" > "${work}/pods.json" 2>"${work}/jq.err" \
		|| ! jq -r "${_ISTIOD_DIAG_JQ_DEFS}${_ISTIOD_DIAG_JQ_PODS_TSV}" "${work}/pods.json" > "${work}/pods.tsv" 2>>"${work}/jq.err"; then
		echo "istiod pod list unreadable: $(tail -n 1 "${work}/jq.err" 2>/dev/null)" >&2
		_IDG_EXPLAINED=1
		return 1
	fi

	# Current pods, by name.
	local -A P_PHASE=() P_DEL=() P_RS=() P_NODE=() P_RC=() P_START=() P_STARTE=() P_HASLAST=() \
		P_LREASON=() P_LEXIT=() P_LSIG=() P_LFIN=() P_LFINE=() P_LIM=() P_SREASON=() P_WREASON=() \
		P_PANIC=() P_SMSG=() P_CREASON=() P_CEXIT=() P_CFIN=() P_CONT=()
	local -a NOW=()
	local n ph del rs node rc st ste hl lr le ls lf lfe lim sr wr pan smsg cr ce cf cont v
	while IFS=$'\t' read -r n ph del rs node rc st ste hl lr le ls lf lfe lim sr wr pan smsg cr ce cf cont; do
		[[ -n "$n" && "$n" != "-" ]] || continue
		# "-" stands for an empty field in the TSV.
		for v in rs node st ste lr le ls lf lfe sr wr pan smsg cr ce cf cont; do
			[[ "${!v}" == "-" ]] && printf -v "$v" '%s' ""
		done
		NOW+=("$n")
		P_PHASE[$n]="$ph"; P_DEL[$n]="$del"; P_RS[$n]="$rs"; P_NODE[$n]="$node"
		P_RC[$n]="$rc"; P_START[$n]="$st"; P_STARTE[$n]="$ste"; P_HASLAST[$n]="$hl"
		P_LREASON[$n]="$lr"; P_LEXIT[$n]="$le"; P_LSIG[$n]="$ls"; P_LFIN[$n]="$lf"
		P_LFINE[$n]="$lfe"; P_LIM[$n]="$lim"; P_SREASON[$n]="$sr"; P_WREASON[$n]="$wr"
		P_PANIC[$n]="$pan"; P_SMSG[$n]="$smsg"; P_CREASON[$n]="$cr"; P_CEXIT[$n]="$ce"
		P_CFIN[$n]="$cf"; P_CONT[$n]="${cont:-discovery}"
	done < "${work}/pods.tsv"

	# Pre-window pods, lined up with their scrape files.
	local -a PRE=() PREF=()
	local -A IN_PRE=() PRE_RS=()
	local i p
	if [[ -n "$podset" && -s "$podset" ]]; then mapfile -t PRE < "$podset"; fi
	[[ -n "$pre_csv" ]] && IFS=',' read -ra PREF <<<"$pre_csv"
	local -a PV_PST=() PV_RSS=() PV_HEAP=() PV_GR=() PV_XDS=() PV_AT=() PV_ATS=()
	local pf
	for i in "${!PRE[@]}"; do
		p="${PRE[i]}"
		[[ -n "$p" ]] || continue
		IN_PRE[$p]=1
		if [[ -n "${P_RS[$p]:-}" ]]; then PRE_RS[${P_RS[$p]}]=1; else PRE_RS[${p%-*}]=1; fi
		pf="${PREF[i]:-}"
		read -r "PV_PST[i]" "PV_RSS[i]" "PV_HEAP[i]" "PV_GR[i]" "PV_XDS[i]" <<<"$(_istiod_diag_pre_values "$pf")"
		PV_AT[i]=N/A
		PV_ATS[i]=""
		if [[ -n "$pf" ]]; then
			PV_ATS[i]="$(_istiod_diag_ts_sec "${pf%.metrics}.ts")"
			PV_AT[i]="$(_istiod_diag_ts_iso "${pf%.metrics}.ts")"
		fi
	done

	# What changed. A_* are the affected pods: name, change, pre index (-1 for none).
	# n_old counts pods whose restarts all predate the pre-window scrape.
	local -a A_POD=() A_CH=() A_PI=()
	local ch at_s n_old=0
	for i in "${!PRE[@]}"; do
		p="${PRE[i]}"
		[[ -n "$p" ]] || continue
		if [[ -z "${P_PHASE[$p]+x}" ]]; then ch=replaced_gone
		elif [[ "${P_DEL[$p]}" == 1 ]]; then ch=replaced_terminating
		elif [[ "${P_PHASE[$p]}" != Running ]]; then ch=replaced_failed
		else
			# The scrape time places only a container that is running now.
			at_s="${PV_ATS[i]:-}"
			[[ -z "${P_CEXIT[$p]:-}" ]] || at_s=""
			ch="$(_istiod_diag_restart_change "${PV_PST[i]}" "${P_STARTE[$p]}" "${P_LFINE[$p]}" "${P_RC[$p]}" "$at_s")"
		fi
		[[ "$ch" == predates_window ]] && { n_old=$((n_old + 1)); continue; }
		[[ "$ch" == no_change ]] && continue
		A_POD+=("$p"); A_CH+=("$ch"); A_PI+=("$i")
	done
	if ((${#IN_PRE[@]})); then
		for p in "${NOW[@]}"; do
			[[ -n "${IN_PRE[$p]:-}" ]] && continue
			A_POD+=("$p"); A_CH+=(new_pod); A_PI+=(-1)
		done
	else
		# No pre-window pod set: every pod that restarted or is not Running counts.
		for p in "${NOW[@]}"; do
			ch=""
			if [[ "${P_DEL[$p]}" == 1 ]]; then ch=replaced_terminating
			elif [[ "${P_PHASE[$p]}" != Running ]]; then ch=not_running
			elif [[ "${P_RC[$p]}" =~ ^[1-9][0-9]*$ ]]; then ch=restarted_untimed
			fi
			[[ -n "$ch" ]] || continue
			A_POD+=("$p"); A_CH+=("$ch"); A_PI+=(-1)
		done
	fi

	if ((${#A_POD[@]} == 0)); then
		if ((${#NOW[@]} == 0)); then
			_istiod_diag_row "$dir" "$now" "$tag" "$ctx" "$trigger" - no_pods no_istiod_pods \
				N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A - "no istiod pod on the context"
		else
			local msg="${#NOW[@]} istiod pod(s), none restarted or replaced since the pre-window scrape"
			((n_old)) && msg+="; ${n_old} with restarts that predate it (no pre-window start time; the container started over ${_ISTIOD_DIAG_CLOCK_MARGIN_SEC} s before the scrape, harness clock)"
			_istiod_diag_row "$dir" "$now" "$tag" "$ctx" "$trigger" - no_change no_restart_found \
				N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A N/A - "$msg"
		fi
		return 0
	fi

	# Dedup: a restart that already has a folder gets a row, not a second folder (.seen);
	# one that already has a row without a folder gets another try at a folder, and
	# already_reported when it cannot get one either (.reported). A replaced pod is one
	# restart whether it is terminating, failed or gone; the report keys rows the same way.
	local seen="${dir}/.seen" reported="${dir}/.reported" k key
	local -a A_KEY=() A_EV=() A_NOTE=()
	local pending=0 any_replaced=0 any_new=0
	for k in "${!A_POD[@]}"; do
		p="${A_POD[k]}"
		case "${A_CH[k]}" in
		restarted_*) key="${ctx}|${p}|${P_RC[$p]}|${P_START[$p]}" ;;
		replaced_*) key="${ctx}|replaced|${p}" ;;
		new_pod) key="${ctx}|new|${p}" ;;
		*) key="${ctx}|${A_CH[k]}|${p}" ;;
		esac
		A_KEY[k]="$key"
		A_NOTE[k]=""
		if [[ -f "$seen" ]] && grep -qxF -- "$key" "$seen" 2>/dev/null; then
			A_EV[k]=already_captured
		else
			A_EV[k]=""
			pending=$((pending + 1))
		fi
		case "${A_CH[k]}" in
		replaced_*) any_replaced=1 ;;
		new_pod) any_new=1 ;;
		esac
	done

	# Budget and deadline, checked before the folder exists.
	local folder="" nfold=0 d skip=""
	for d in "${dir}"/[0-9][0-9][0-9]-*; do [[ -d "$d" ]] && nfold=$((nfold + 1)); done
	if ((pending > 0)); then
		if ((nfold >= _IDG_MAX_CAPTURES)); then skip=budget_exhausted
		elif ! _istiod_diag_time_ok; then skip=skipped_deadline
		fi
	fi
	if ((pending > 0)) && [[ -z "$skip" ]]; then
		local num=$((nfold + 1))
		local cfs
		cfs="$(ctx_file_safe "$ctx" "$CTX_FILE_NAME_MAX")"
		while [[ -e "${dir}/$(printf '%03d' "$num")-${tag}-${cfs:-x}" ]]; do num=$((num + 1)); done
		folder="$(printf '%03d' "$num")-${tag}-${cfs:-x}"
		mkdir -p "${dir}/${folder}" || { echo "cannot create ${dir}/${folder}" >&2; _IDG_EXPLAINED=1; return 1; }
	fi
	for k in "${!A_POD[@]}"; do
		[[ -z "${A_EV[k]}" ]] || continue
		if [[ -n "$folder" ]]; then A_EV[k]="$folder"
		elif [[ -f "$reported" ]] && grep -qxF -- "${A_KEY[k]}" "$reported" 2>/dev/null; then A_EV[k]=already_reported
		else A_EV[k]="$skip"
		fi
	done

	local fdir="${dir}/${folder}" partial=0 logs_left=$_ISTIOD_DIAG_MAX_PODS
	local events="${work}/events.tsv"
	: > "$events"
	local -A NODE_READY=() NODE_READYE=() RS_LIM=()
	local -a NODES=()
	if [[ -n "$folder" ]]; then
		_istiod_diag_mask < "${work}/pods.json" > "${fdir}/pods.json"

		# 2. What expires first: the previous container's logs (gone at the next restart).
		for k in "${!A_POD[@]}"; do
			[[ "${A_EV[k]}" == "$folder" && "${A_CH[k]}" == restarted_* ]] || continue
			p="${A_POD[k]}"
			if ((logs_left <= 0)); then A_NOTE[k]+="log skipped (pod cap); "; continue; fi
			_istiod_diag_time_ok || { partial=1; break; }
			logs_left=$((logs_left - 1))
			_istiod_diag_log "$fdir" "$ctx" "$p" "${P_CONT[$p]}" previous "${kc[@]}" \
				|| A_NOTE[k]+="previous log unavailable: ${_IDG_LOG_ERR}; "
		done

		# 3. The istio-system events of istiod objects (they expire after a few hours).
		if _istiod_diag_time_ok; then
			if "${kc[@]}" --context="$ctx" -n istio-system get events -o json --request-timeout="$_IDG_RT" \
				> "${work}/events.raw" 2> "${work}/events.err" \
				&& jq -r --arg pfx istiod --argjson max "$_ISTIOD_DIAG_MAX_EVENTS" \
					"${_ISTIOD_DIAG_JQ_DEFS}${_ISTIOD_DIAG_JQ_EVENTS}" "${work}/events.raw" > "$events" 2>/dev/null; then
				{ printf 'time\ttype\treason\tkind\tname\tcount\tmessage\n'; _istiod_diag_mask < "$events"; } > "${fdir}/events.tsv"
			else
				: > "$events"
				printf 'kubectl get events failed: %s\n' "$(tail -n 1 "${work}/events.err" 2>/dev/null)" \
					| _istiod_diag_mask > "${fdir}/events.tsv.unavailable"
			fi
		else
			partial=1
		fi

		# 4. The logs of old pods that still exist (terminating or failed).
		for k in "${!A_POD[@]}"; do
			[[ "${A_EV[k]}" == "$folder" ]] || continue
			case "${A_CH[k]}" in replaced_terminating | replaced_failed | not_running) ;; *) continue ;; esac
			p="${A_POD[k]}"
			if ((logs_left <= 0)); then A_NOTE[k]+="log skipped (pod cap); "; continue; fi
			_istiod_diag_time_ok || { partial=1; break; }
			logs_left=$((logs_left - 1))
			_istiod_diag_log "$fdir" "$ctx" "$p" "${P_CONT[$p]}" current "${kc[@]}" \
				|| A_NOTE[k]+="log unavailable: ${_IDG_LOG_ERR}; "
		done

		# 5. Deployment and ReplicaSet revisions (a GitOps rollout shows here, PL39).
		if _istiod_diag_time_ok; then
			if "${kc[@]}" --context="$ctx" -n istio-system get deploy,rs -o json --request-timeout="$_IDG_RT" \
				> "${work}/deploy-rs.raw" 2> "${work}/deploy-rs.err" \
				&& jq "${_ISTIOD_DIAG_JQ_DEFS}${_ISTIOD_DIAG_JQ_DEPLOY_RS}" "${work}/deploy-rs.raw" > "${work}/deploy-rs.json" 2>/dev/null; then
				_istiod_diag_mask < "${work}/deploy-rs.json" > "${fdir}/deploy-rs.json"
				while IFS=$'\t' read -r n lim; do
					[[ -n "$n" ]] && RS_LIM[$n]="$lim"
				done < <(jq -r '.[] | select(.kind == "ReplicaSet") | [.name, .mem_limit_mi] | @tsv' "${work}/deploy-rs.json" 2>/dev/null)
			else
				printf 'kubectl get deploy,rs failed: %s\n' "$(tail -n 1 "${work}/deploy-rs.err" 2>/dev/null)" \
					| _istiod_diag_mask > "${fdir}/deploy-rs.json.unavailable"
			fi
		else
			partial=1
		fi

		# 6. Nodes of the affected pods that still exist: conditions and events.
		local -A NODE_SEEN=()
		for k in "${!A_POD[@]}"; do
			[[ "${A_EV[k]}" == "$folder" ]] || continue
			node="${P_NODE[${A_POD[k]}]:-}"
			[[ -n "$node" && -z "${NODE_SEEN[$node]:-}" ]] || continue
			((${#NODES[@]} < _ISTIOD_DIAG_MAX_NODES)) || break
			NODE_SEEN[$node]=1
			NODES+=("$node")
		done
		local ni=0 rd
		for node in ${NODES[@]+"${NODES[@]}"}; do
			ni=$((ni + 1))
			_istiod_diag_time_ok || { partial=1; break; }
			if "${kc[@]}" --context="$ctx" get node "$node" -o json --request-timeout="$_IDG_RT" \
				> "${work}/node.raw" 2> "${work}/node.err" \
				&& jq "$_ISTIOD_DIAG_JQ_NODE" "${work}/node.raw" > "${work}/node.json" 2>/dev/null; then
				_istiod_diag_mask < "${work}/node.json" > "${fdir}/node-${ni}.json"
				rd="$(jq -r '[.conditions[]? | select(.type == "Ready") | .lastTransitionTime][0] // ""' "${work}/node.json" 2>/dev/null)" || rd=""
				NODE_READY[$node]="${rd:-N/A}"
				NODE_READYE[$node]="$(jq -rn --arg t "$rd" "${_ISTIOD_DIAG_JQ_DEFS}"' $t | ep_safe' 2>/dev/null)" || NODE_READYE[$node]=""
			else
				printf 'kubectl get node failed: %s\n' "$(tail -n 1 "${work}/node.err" 2>/dev/null)" \
					| _istiod_diag_mask > "${fdir}/node-${ni}.json.unavailable"
			fi
			_istiod_diag_time_ok || { partial=1; break; }
			if "${kc[@]}" --context="$ctx" -n default get events -o json --request-timeout="$_IDG_RT" \
				--field-selector="involvedObject.kind=Node,involvedObject.name=${node}" \
				> "${work}/node-events.raw" 2> "${work}/node-events.err" \
				&& jq -r --arg pfx "" --argjson max "$_ISTIOD_DIAG_MAX_NODE_EVENTS" \
					"${_ISTIOD_DIAG_JQ_DEFS}${_ISTIOD_DIAG_JQ_EVENTS}" "${work}/node-events.raw" > "${work}/node-events.tsv" 2>/dev/null; then
				{ printf 'time\ttype\treason\tkind\tname\tcount\tmessage\n'; _istiod_diag_mask < "${work}/node-events.tsv"; } > "${fdir}/node-${ni}-events.tsv"
			else
				printf 'kubectl get node events failed: %s\n' "$(tail -n 1 "${work}/node-events.err" 2>/dev/null)" \
					| _istiod_diag_mask > "${fdir}/node-${ni}-events.tsv.unavailable"
			fi
		done

		# 7. Startup logs of the new pods.
		for k in "${!A_POD[@]}"; do
			[[ "${A_EV[k]}" == "$folder" && "${A_CH[k]}" == new_pod ]] || continue
			p="${A_POD[k]}"
			if ((logs_left <= 0)); then A_NOTE[k]+="log skipped (pod cap); "; continue; fi
			_istiod_diag_time_ok || { partial=1; break; }
			logs_left=$((logs_left - 1))
			_istiod_diag_log "$fdir" "$ctx" "$p" "${P_CONT[$p]}" startup "${kc[@]}" \
				|| A_NOTE[k]+="startup log unavailable: ${_IDG_LOG_ERR}; "
		done

		# 8. The pre-window scrapes of the affected pre pods (local files, no API call).
		for k in "${!A_POD[@]}"; do
			[[ "${A_EV[k]}" == "$folder" ]] || continue
			i="${A_PI[k]}"
			((i >= 0)) || continue
			[[ -n "${PREF[i]:-}" && -s "${PREF[i]}" ]] || continue
			cp "${PREF[i]}" "${fdir}/${A_POD[k]}.pre.metrics" 2>/dev/null \
				&& _istiod_diag_gzip "${fdir}/${A_POD[k]}.pre.metrics"
		done
	fi

	# Cause, first rule that matches (only the pod list without a folder).
	local -a A_CAUSE=() A_RSC=()
	local old_rs cur_set exitc se nre pline
	local -A NEW_RS=() LIVE_RS=()
	for k in "${!A_POD[@]}"; do
		[[ "${A_CH[k]}" == new_pod && -n "${P_RS[${A_POD[k]}]:-}" ]] && NEW_RS[${P_RS[${A_POD[k]}]}]=1
	done
	for p in "${NOW[@]}"; do
		[[ "${P_PHASE[$p]}" == Running && "${P_DEL[$p]}" != 1 && -n "${P_RS[$p]:-}" ]] && LIVE_RS[${P_RS[$p]}]=1
	done
	for k in "${!A_POD[@]}"; do
		p="${A_POD[k]}"
		ch="${A_CH[k]}"
		A_RSC[k]=N/A
		case "$ch" in
		restarted_* | not_running)
			exitc="${P_LEXIT[$p]:-}"
			# node_restart: no last state, and the node turned Ready at most
			# _ISTIOD_DIAG_NODE_WINDOW_SEC before the container started (both cluster clocks).
			se="${P_STARTE[$p]:-}"
			nre="${NODE_READYE[${P_NODE[$p]:-x}]:-}"
			if [[ "${P_LREASON[$p]:-}" == OOMKilled ]]; then A_CAUSE[k]=oom_killed
			elif [[ "${P_HASLAST[$p]}" == 1 ]] && { _istiod_diag_event "$events" "$p" '^Unhealthy$' '^(Liveness|Startup) probe failed' \
				|| _istiod_diag_event "$events" "$p" '^Killing$' 'failed (liveness|startup) probe'; }; then A_CAUSE[k]=probe_kill
			elif [[ "$exitc" =~ ^[0-9]+$ && "$exitc" != 0 && "$exitc" != 137 && "$exitc" != 143 ]]; then A_CAUSE[k]=crash
			elif [[ "$exitc" == 137 || "$exitc" == 143 ]]; then A_CAUSE[k]=killed
			elif [[ "$exitc" == 0 ]]; then A_CAUSE[k]=exited
			elif [[ "${P_HASLAST[$p]}" != 1 && "$se" =~ ^[0-9]+$ && "$nre" =~ ^[0-9]+$ ]] \
				&& ((se - nre >= 0 && se - nre <= _ISTIOD_DIAG_NODE_WINDOW_SEC)); then A_CAUSE[k]=node_restart
			else A_CAUSE[k]=no_last_state
			fi
			# A crash's first panic/fatal line: from the termination message, else the saved log.
			if [[ "${A_CAUSE[k]}" == crash && -z "${P_PANIC[$p]:-}" && -n "$folder" ]]; then
				pline="$(_istiod_diag_panic_line "${fdir}/${p}.previous.log")"
				[[ -n "$pline" ]] && P_PANIC[$p]="$pline"
			fi
			[[ "$ch" == restarted_untimed ]] && A_NOTE[k]+="no pre-window start time: the restart may predate the window; "
			;;
		replaced_*)
			old_rs="${P_RS[$p]:-${p%-*}}"
			if ((${#NEW_RS[@]})); then cur_set="${!NEW_RS[*]}"; else cur_set=""
				for n in "${!LIVE_RS[@]}"; do cur_set+="${cur_set:+ }${n}"; done
			fi
			if [[ -z "$cur_set" ]]; then A_RSC[k]=N/A
			elif [[ " ${cur_set} " == *" ${old_rs} "* ]]; then A_RSC[k]=0
			else A_RSC[k]=1
			fi
			if [[ "${P_SREASON[$p]:-}" == Evicted ]] || _istiod_diag_event "$events" "$p" '^Evicted$' '.'; then A_CAUSE[k]=evicted
			elif [[ "${P_SREASON[$p]:-}" == Preempting ]] || _istiod_diag_event "$events" "$p" '^Preempted$' '.'; then A_CAUSE[k]=preempted
			elif [[ "${P_SREASON[$p]:-}" =~ ^(NodeLost|Terminated|Shutdown|NodeShutdown)$ || "${P_PHASE[$p]:-}" == Unknown ]] \
				|| _istiod_diag_event "$events" "$p" '^(NodeNotReady|TaintManagerEviction)$' '.'; then A_CAUSE[k]=node_lost
			elif [[ "${A_RSC[k]}" == 1 ]]; then A_CAUSE[k]=rollout
			elif _istiod_diag_event "$events" "$p" '^Killing$' '.'; then A_CAUSE[k]=deleted
			elif ((!any_new)); then A_CAUSE[k]=scaled
			else A_CAUSE[k]=replaced_unknown
			fi
			[[ -n "${P_SMSG[$p]:-}" ]] && A_NOTE[k]+="${P_SMSG[$p]}; "
			;;
		new_pod)
			old_rs="${P_RS[$p]:-}"
			if ((${#PRE_RS[@]} == 0)) || [[ -z "$old_rs" ]]; then A_RSC[k]=N/A
			elif [[ -n "${PRE_RS[$old_rs]:-}" ]]; then A_RSC[k]=0
			else A_RSC[k]=1
			fi
			if [[ "${A_RSC[k]}" == 1 ]]; then A_CAUSE[k]=rollout
			elif ((any_replaced)); then A_CAUSE[k]=replacement
			else A_CAUSE[k]=scaled
			fi
			[[ "${P_RC[$p]}" =~ ^[1-9][0-9]*$ ]] && A_NOTE[k]+="the new pod restarted ${P_RC[$p]} time(s), last ${P_LREASON[$p]:-no reason} exit ${P_LEXIT[$p]:-N/A}; "
			;;
		esac
		[[ -n "${P_PANIC[$p]:-}" && "${A_CAUSE[k]}" == crash ]] && A_NOTE[k]+="${P_PANIC[$p]}; "
		[[ -n "${P_WREASON[$p]:-}" ]] && A_NOTE[k]+="waiting: ${P_WREASON[$p]}; "
		((partial)) && [[ "${A_EV[k]}" == "$folder" ]] && A_NOTE[k]+="ISTIOD_DIAG_MAX_SEC reached: partial evidence; "
	done

	# Rows (and the folder's summary.md), then the dedup keys of what was captured.
	local all_nodes=() rsc pi exit_v sig_v reason_v start_v fin_v rc_v lim_v rss heap gr xds at nr note
	for p in "${NOW[@]}"; do [[ -n "${P_NODE[$p]:-}" ]] && all_nodes+=("${P_NODE[$p]}"); done
	local -a SUMMARY=()
	for k in "${!A_POD[@]}"; do
		p="${A_POD[k]}"
		ch="${A_CH[k]}"
		pi="${A_PI[k]}"
		rc_v=N/A; exit_v=N/A; sig_v=N/A; reason_v=N/A; start_v=N/A; fin_v=N/A; lim_v=N/A; nr=N/A
		if [[ -n "${P_PHASE[$p]+x}" ]]; then
			rc_v="${P_RC[$p]}"
			lim_v="${P_LIM[$p]}"
			start_v="${P_START[$p]:-N/A}"
			nr="${NODE_READY[${P_NODE[$p]:-x}]:-N/A}"
			if [[ "$ch" != restarted_* && -n "${P_CREASON[$p]:-}" ]]; then
				reason_v="${P_CREASON[$p]}"; exit_v="${P_CEXIT[$p]:-N/A}"; fin_v="${P_CFIN[$p]:-N/A}"
			elif [[ "${P_HASLAST[$p]}" == 1 ]]; then
				reason_v="${P_LREASON[$p]:-N/A}"; exit_v="${P_LEXIT[$p]:-N/A}"; fin_v="${P_LFIN[$p]:-N/A}"
				sig_v="${P_LSIG[$p]:-}"
			fi
			if [[ -z "$sig_v" || "$sig_v" == N/A ]]; then
				if [[ "$exit_v" =~ ^[0-9]+$ ]] && ((exit_v > 128)); then sig_v=$((exit_v - 128)); else sig_v=N/A; fi
			fi
		elif [[ "$ch" == replaced_gone ]]; then
			lim_v="${RS_LIM[${p%-*}]:-N/A}"
		fi
		rss=N/A; heap=N/A; gr=N/A; xds=N/A; at=N/A
		if ((pi >= 0)); then
			rss="${PV_RSS[pi]:-N/A}"; heap="${PV_HEAP[pi]:-N/A}"; gr="${PV_GR[pi]:-N/A}"
			xds="${PV_XDS[pi]:-N/A}"; at="${PV_AT[pi]:-N/A}"
		fi
		rsc="${A_RSC[k]:-N/A}"
		note="${A_NOTE[k]%; }"
		[[ -n "$note" ]] || note=-
		note="$(_istiod_diag_text "$note" "$ctx" ${all_nodes[@]+"${all_nodes[@]}"})"
		_istiod_diag_row "$dir" "$now" "$tag" "$ctx" "$trigger" "$p" "$ch" "${A_CAUSE[k]:-unknown}" \
			"$rc_v" "$exit_v" "$sig_v" "$reason_v" "$start_v" "$fin_v" "$lim_v" "$rss" "$heap" "$gr" "$xds" \
			"$at" "$rsc" "$nr" "${A_EV[k]}" "$note"
		SUMMARY+=("| ${p} | ${ch} | ${A_CAUSE[k]:-unknown} | ${rc_v} | ${exit_v} | ${reason_v} | ${start_v} | ${fin_v} | ${lim_v} | ${rss} | ${heap} | ${rsc} | ${nr} | ${note//|//} |")
	done

	if [[ -n "$folder" ]]; then
		{
			echo "# istiod restart evidence: ${tag}"
			echo ""
			echo "- Context: \`<ctx>\` (the \`context\` column of \`../index.tsv\`)"
			echo "- Trigger: \`${trigger}\`"
			echo "- Captured at (harness clock): ${now}"
			((partial)) && echo "- ISTIOD_DIAG_MAX_SEC (${_IDG_MAX_SEC}s) ran out: the evidence is partial."
			echo ""
			echo "| pod | change | cause | restarts | exit | term_reason | started_at | finished_at | limit (Mi) | rss_pre (Mi) | heap_inuse_pre (Mi) | rs_changed | node_ready_at | note |"
			echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
			printf '%s\n' ${SUMMARY[@]+"${SUMMARY[@]}"}
			echo ""
			echo "## Memory history"
			echo ""
			echo "The pre-window values above come from the suite's own last scrape. For the"
			echo "memory curve up to the restart, run this in a Prometheus that scrapes the kubelet's"
			echo "cAdvisor metrics (on OpenShift: the console, Observe > Metrics; charts/istiod-monitor"
			echo "scrapes only istiod) at the pod's finished_at (cluster clock), per affected pod:"
			echo ""
			for k in "${!A_POD[@]}"; do
				[[ "${A_EV[k]}" == "$folder" ]] || continue
				echo "    max_over_time(container_memory_working_set_bytes{namespace=\"istio-system\",pod=\"${A_POD[k]}\",container=\"${P_CONT[${A_POD[k]}]:-discovery}\"}[15m])"
			done
			echo ""
			echo "Files: see ../README.md."
		} > "${fdir}/summary.md"
	fi
	# The dedup keys: with a folder (.seen), or a row only (.reported).
	for k in "${!A_POD[@]}"; do
		if [[ -n "$folder" && "${A_EV[k]}" == "$folder" ]]; then
			printf '%s\n' "${A_KEY[k]}" >> "$seen"
		elif [[ "${A_EV[k]}" == budget_exhausted || "${A_EV[k]}" == skipped_deadline ]]; then
			printf '%s\n' "${A_KEY[k]}" >> "$reported"
		fi
	done
	return 0
}

# istiod_diag_dir <tsv_file> <run_id>: the run's evidence folder, next to its TSV.
# shellcheck disable=SC2329
istiod_diag_dir() {
	local d t
	d="$(dirname "${1:-.}")"
	t="$(ctx_file_safe "${2:-}" "$RUN_ID_FILE_NAME_MAX")"
	printf '%s/istiod-diag-%s\n' "$d" "${t:-x}"
}

# istiod_diag_capture <diag_dir> <tag> <ctx> <trigger> <pre_podset|''> <pre_metrics_csv|''>
# <kubectl argv...>: see the header. Always returns 0 (PL40).
# shellcheck disable=SC2329
istiod_diag_capture() {
	[[ "${ISTIOD_DIAG_ENABLED:-1}" != 0 ]] || return 0
	if (($# < 7)); then
		echo "warning: istiod_diag_capture: needs <dir> <tag> <ctx> <trigger> <podset> <pre_csv> <kubectl...>; skipped" >&2
		return 0
	fi
	if ! declare -F reach_sanitize >/dev/null 2>&1; then
		echo "warning: istiod_diag_capture: tests/lib/reach.sh is not sourced (reach_sanitize); skipped" >&2
		return 0
	fi
	local dir="$1" tag ctx="$3" trigger="$4" podset="$5" pre_csv="$6"
	tag="$(ctx_file_safe "$2" "$TAG_FILE_NAME_MAX")"
	tag="${tag:-x}"
	shift 6
	if ! mkdir -p "$dir" 2>/dev/null; then
		echo "warning: istiod-diag: cannot create ${dir}; no restart evidence saved" >&2
		return 0
	fi
	_istiod_diag_settings
	local idx="${dir}/index.tsv" err="${dir}/.capture.err" before=0 last=""
	if [[ -f "$idx" ]]; then
		before="$(awk 'END { print NR }' "$idx" 2>/dev/null)" || before=0
	fi
	[[ "$before" =~ ^[0-9]+$ ]] || before=0
	echo "istiod-diag: ${ctx}: trigger ${trigger}; capturing restart evidence in ${dir}/" >&2
	if ! (_istiod_diag_run "$dir" "$tag" "$ctx" "$trigger" "$podset" "$pre_csv" "$@") 2>>"$err"; then
		last="$(tail -n 1 "$err" 2>/dev/null)" || last=""
		(_istiod_diag_fail_row "$dir" "$tag" "$ctx" "$trigger" "$last") 2>>"$err" || true
	fi
	# One stderr line per new index row.
	if [[ -f "$idx" ]]; then
		awk -F'\t' -v from="$before" 'NR > from && !/^#/ && $1 != "captured_at" {
			printf "istiod-diag: %s %s: change=%s cause=%s evidence=%s\n", $3, $5, $6, $7, $22
		}' "$idx" >&2 2>/dev/null || true
	fi
	return 0
}

# _istiod_diag_after_window_run <ts>: istiod_diag_after_window's body (in a subshell).
# shellcheck disable=SC2329
_istiod_diag_after_window_run() {
	local ts="$1" dir tag ctx trig k n podset csv
	[[ -n "$ts" && -n "${TSV_FILE:-}" && -f "${TSV_FILE:-}" && -d "${TMP_DIR:-}" ]] || return 0
	# Per context: 1 when any row of the window is 1, else unknown when any is not 0.
	local triggers
	triggers="$(awk -F'\t' -v ts="$ts" '
		/^#/ { next }
		$1 == "timestamp" { c = 0; r = 0; for (i = 1; i <= NF; i++) { if ($i == "context") c = i; if ($i == "istiod_restarted") r = i } next }
		c && r && $1 == ts && $r != "0" {
			if (!($c in t)) order[++n] = $c
			if ($r == "1" || t[$c] == "1") t[$c] = "1"; else t[$c] = "unknown"
		}
		END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], t[order[i]] }' "$TSV_FILE" 2>/dev/null)" || return 0
	[[ -n "$triggers" ]] || return 0
	dir="$(istiod_diag_dir "$TSV_FILE" "${RUN_ID:-unknown}")"
	# The window's UTC timestamp as w<YYYYMMDD>T<HHMMSS>Z (no ':' or '+' in folder names).
	tag="${ts//[-:]/}"
	tag="${tag%+0000}"
	tag="w${tag%Z}Z"
	n=0
	while IFS=$'\t' read -r ctx trig; do
		[[ -n "$ctx" ]] || continue
		n=$((n + 1))
		podset="${TMP_DIR}/diag-pre-${n}.podset"
		csv=""
		: > "$podset" || continue
		for k in "${!POD_CTXS[@]}"; do
			[[ "${POD_CTXS[k]}" == "$ctx" ]] || continue
			printf '%s\n' "${POD_NAMES[k]}" >> "$podset"
			csv+="${csv:+,}${TMP_DIR}/baseline-${k}.metrics"
		done
		if [[ -z "$csv" ]]; then
			trig=no_running_pods
			podset=""
		fi
		istiod_diag_capture "$dir" "$tag" "$ctx" "$trig" "$podset" "$csv" "${KUBECTL[@]}" </dev/null
	done <<<"$triggers"
	return 0
}

# istiod_diag_after_window <ts>: see the header. Reads the TSV only; no API call unless
# a row of the window has istiod_restarted != 0. Always returns 0.
# shellcheck disable=SC2329
istiod_diag_after_window() {
	[[ "${ISTIOD_DIAG_ENABLED:-1}" != 0 ]] || return 0
	(_istiod_diag_after_window_run "${1:-}") || echo "warning: istiod-diag: the restart evidence capture after window ${1:-?} failed" >&2
	return 0
}

# --- report -----------------------------------------------------------------------

# _istiod_diag_report_rows <results_dir>: every row of every istiod-diag-*/index.tsv
# under results_dir, after three fields: run_id (the index's `# RUN_ID=`, else its
# folder name), role and evidence. role: counted; untimed (restarted_untimed, kept out
# of the tally); repeat (another row of the same restart is listed). One row per
# restart is listed: the first with a folder, else the first timed one, else the
# first. A restart's key: context, pod, restart_count and started_at for an in-place
# restart; context and pod for a replaced pod (terminating, failed or gone) and for a
# new pod; rows without a pod are never repeats. evidence: the folder relative to
# results_dir (istiod-diag-<RUN_ID>/NNN-...), or the index value when there is none.
# A row of another width is skipped with a warning (an index of another schema).
# shellcheck disable=SC2329
_istiod_diag_report_rows() {
	local rdir="${1:-.}" f
	local -a files=()
	[[ "$rdir" == / ]] || rdir="${rdir%/}"
	while IFS= read -r f; do files+=("$f"); done < <(find -H "$rdir" -path '*/istiod-diag-*/index.tsv' -type f 2>/dev/null | LC_ALL=C sort)
	((${#files[@]})) || return 0
	awk -F'\t' -v want="${#_ISTIOD_DIAG_HEADER[@]}" -v pfx="${rdir%/}/" '
		FNR == 1 {
			nf++; rel = FILENAME
			if (index(rel, pfx) == 1) rel = substr(rel, length(pfx) + 1)
			sub(/\/index\.tsv$/, "", rel); reld[nf] = rel
			r = rel; sub(/^.*\//, "", r); sub(/^istiod-diag-/, "", r); rid[nf] = (r == "" ? "N/A" : r)
		}
		/^# RUN_ID=./ { rid[nf] = substr($0, 10); next }
		/^#/ || $1 == "captured_at" || $0 == "" { next }
		NF != want { bad++; next }
		{
			n++; line[n] = $0; file[n] = nf; ch[n] = $6; ev[n] = $22
			if ($5 == "-" || $5 == "N/A") key = ""
			else if ($6 ~ /^restarted_/) key = $3 "|" $5 "|" $8 "|" $12
			else if ($6 ~ /^replaced_/) key = $3 "|replaced|" $5
			else key = $3 "|" $6 "|" $5
			k[n] = key
			if (key == "") next
			s = (($22 ~ /^[0-9][0-9][0-9]-/) ? 2 : 0) + (($6 != "restarted_untimed") ? 1 : 0)
			if (!(key in best) || s > bs[key]) { best[key] = n; bs[key] = s }
		}
		END {
			if (bad) printf "warning: istiod-diag report: skipped %d index row(s) of another schema\n", bad > "/dev/stderr"
			for (i = 1; i <= n; i++) {
				role = "counted"
				if (k[i] != "" && best[k[i]] != i) role = "repeat"
				else if (ch[i] == "restarted_untimed") role = "untimed"
				e = ev[i]
				if (e ~ /^[0-9][0-9][0-9]-/) e = reld[file[i]] "/" e
				printf "%s\t%s\t%s\t%s\n", rid[file[i]], role, e, line[i]
			}
		}' "${files[@]}"
}

# istiod_diag_report <text|md|markdown|csv|json> <results_dir>: see the header.
# shellcheck disable=SC2329
istiod_diag_report() {
	local fmt="${1:-text}" rdir="${2:-.}" rows nfiles
	[[ "$fmt" == csv ]] && return 0
	rows="$(_istiod_diag_report_rows "$rdir")" || rows=""
	nfiles="$(find -H "$rdir" -path '*/istiod-diag-*/index.tsv' -type f 2>/dev/null | awk 'END { print NR }')" || nfiles=0
	case "$fmt" in
	json)
		# Fields after the three prefixes: index column j is .[j + 2].
		printf '%s\n' "$rows" | jq -R -s -c --argjson files "${nfiles:-0}" '
			def tally: group_by(.cause) | map({(.[0].cause): length}) | add // {};
			split("\n") | map(select(length > 0) | split("\t"))
			| map({run_id: .[0], captured_at: .[3], tag: .[4], context: .[5], trigger: .[6], pod: .[7],
				change: .[8], cause: .[9], restart_count: .[10], exit_code: .[11], term_reason: .[13],
				started_at: .[14], mem_limit_mi: .[16], rss_pre_mi: .[17], rs_changed: .[22],
				evidence: .[2], note: .[25], repeat: (.[1] == "repeat"), untimed: (.[1] == "untimed")})
			| {index_files: $files, rows: length,
			   repeat_rows: (map(select(.repeat)) | length),
			   untimed_rows: (map(select(.untimed)) | length),
			   by_cause: (map(select((.repeat or .untimed) | not)) | tally),
			   untimed_by_cause: (map(select(.untimed)) | tally),
			   captures: .}' 2>/dev/null \
			|| printf '{"index_files":0,"rows":0,"repeat_rows":0,"untimed_rows":0,"by_cause":{},"untimed_by_cause":{},"captures":[]}\n'
		;;
	text | md | markdown)
		# Every markdown cell through md_cell (MD_CELL_AWK, common.sh).
		printf '%s\n' "$rows" | awk -F'\t' -v fmt="$fmt" -v files="${nfiles:-0}" "$MD_CELL_AWK"'
			function tl(o, a, c,    i, s) {
				s = ""
				for (i = 1; i <= c; i++) s = s (i > 1 ? ", " : "") o[i] "=" a[o[i]]
				return (s == "" ? "none" : s)
			}
			NF > 1 {
				n++; rid[n] = $1; role[n] = $2; ev[n] = $3
				tag[n] = $5; ctx[n] = $6; pod[n] = $8; ch[n] = $9; cause[n] = $10; ex[n] = $12
				mem[n] = $18 "/" $17
				if ($2 == "repeat") { rep++; next }
				if ($2 == "untimed") { un++; if (!(($10) in ut)) uo[++nu] = $10; ut[$10]++; next }
				if (!(($10) in tally)) order[++no] = $10
				tally[$10]++
			}
			END {
				md = (fmt != "text")
				if (md) print "## istiod restart diagnostics\n"
				if (n == 0) {
					if (md) print "None captured: no `istiod-diag-*/index.tsv` under the results dir (no restart or `unknown` status triggered a capture, or `ISTIOD_DIAG_ENABLED=0`)."
					else print "istiod restart diagnostics: none captured"
					exit
				}
				t = tl(order, tally, no)
				u = tl(uo, ut, nu)
				if (md) {
					printf "%d row(s) from %d `istiod-diag-*/index.tsv` file(s); by cause: %s.", n, files, t
					if (un) printf " Not in the tally: %d restart(s) at an unknown time (`restarted_untimed`: the pod has restarts but no pre-window start time, so they may predate the window): %s.", un, u
					if (rep) printf " %d repeat row(s) of an already listed restart are not listed.", rep
					printf " Evidence paths are relative to the results dir. The evidence folders hold raw logs and events: never commit them.\n\n"
					print "| run_id | context | tag | pod | change | cause | exit | rss_pre / limit (Mi) | evidence |"
					print "|--------|---------|-----|-----|--------|-------|------|----------------------|----------|"
				} else {
					printf "istiod restart diagnostics: %d row(s) from %d istiod-diag-*/index.tsv file(s); by cause: %s\n", n, files, t
					if (un) printf "  not in the tally, %d restart(s) at an unknown time (restarted_untimed: no pre-window start time, may predate the window): %s\n", un, u
					if (rep) printf "  (%d repeat row(s) of an already listed restart not listed)\n", rep
				}
				for (i = 1; i <= n; i++) {
					if (role[i] == "repeat") continue
					c = cause[i] (role[i] == "untimed" ? " (untimed)" : "")
					if (md) printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", md_cell(rid[i]), md_cell(ctx[i]), md_cell(tag[i]), md_cell(pod[i]), md_cell(ch[i]), md_cell(c), md_cell(ex[i]), md_cell(mem[i]), md_cell(ev[i])
					else printf "  %s | %s | %s | %s | %s | %s | exit=%s | rss_pre/limit=%s Mi | %s\n", rid[i], ctx[i], tag[i], pod[i], ch[i], c, ex[i], mem[i], ev[i]
				}
			}' || true
		;;
	*)
		echo "warning: istiod_diag_report: unknown format ${fmt}" >&2
		;;
	esac
	return 0
}
