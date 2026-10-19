#!/usr/bin/env bash
# Scale-envelope + SLA-verdict rendering for the campaign deliverable.
# Sourced, never executed.
#
# Consumers: controlplane (004 report SLA verdict; campaign-end envelope render)
#
# This library is STRICTLY READ-ONLY: every kubectl call is a `get`/`top`/
# `version`, never apply/scale/delete/patch. It composes on capacity.sh for the
# cluster-capacity reads and reuses the controlplane report's own JSON output as
# the measured-metrics source, so it never re-derives aggregates (no second
# validity gate to drift from the report's n_valid filter — PL15/PL35).
#
# Two layers (mirrors capacity.sh):
#   PURE FUNCTIONS — stdin/args -> stdout, no kubectl, unit-testable with fixtures.
#   THIN WRAPPERS  — compose `<kubectl read> | <parser>`; degrade to `unknown`.
#
# Exposes (pure):
#   env_parse_istiod_resources                     -> reads deploy istiod json on stdin;
#       emits req_cpu_m=.. req_mem_mi=.. lim_cpu_m=.. lim_mem_mi=.. replicas=..
#       (capacity.sh:cap_parse_istiod_limits collapses req+lim into one; the envelope
#        needs BOTH the request and the limit, so this is a distinct parser.)
#   env_parse_network                              -> reads istiod deploy json on stdin;
#       emits the spoke's Istio network id from the discovery container's
#       PILOT-injected MESH/NETWORK env (ISTIO_META_NETWORK / NETWORK_ID), else `unknown`.
#   env_limit_drift_warning <rec_cpu_m> <rec_mem_mi> <live_cpu_m> <live_mem_mi>
#                                                  -> a warning when istiod's limit read now
#       differs from the one the sweep recorded (which the window-peak CPU and RSS % use),
#       else nothing.
#   env_pct_cell <pct> [<limit> <unit> | row]      -> a "Measured (% of limit)" cell: the %
#       and the limit it divides by ("of each row's limit" with row); a value not read stays
#       bare (unknown, never "unknown%").
#   env_pct_of_limit <used> <per_replica_limit> <replicas>
#                                                  -> integer percent of the CROSS-REPLICA
#       limit (per-replica limit * replicas), matching numerator (a cross-replica
#       `kubectl top` sum) to denominator scope (PL35). `unknown` if any arg bad.
#   env_sla_verdict [--nodes-excluded REASON] <icpu_pct> <imem_pct> <ncpu_pct> <nmem_pct> <restarts> <n_total> <n_valid> [caution_pct] [fail_pct]
#                                                  -> "VERDICT|headline" — one of
#       PASS / CAUTION / FAIL plus a one-line human headline. The verdict is computed
#       only over the validity-gated aggregates the caller passes (the report's
#       n_valid maxes), never configured axis values (PL35). The CAUTION/FAIL utilization
#       bands default from the env (SCALE_SLA_CAUTION_PCT=75 / SCALE_SLA_FAIL_PCT=90 in
#       config/options.env) but accept args 8/9 so the function stays pure/unit-testable.
#       The controlplane report (004) is the SINGLE authoritative compute site;
#       render_scale_envelope reads the verdict back from the report JSON (C1).
#   env_replicas_summary <n...>                    -> the ISTIOD_REPLICAS token for
#       per-context istiod replica counts: `3` when they agree, `1-3` when they vary,
#       `unknown` when none was read.
#   env_replicas_label <ISTIOD_REPLICAS> [ISTIOD_REPLICAS_BY_CONTEXT]
#                                                  -> display form: `3 per cluster`,
#       `1-3 per cluster (varies by cluster)`, `3 (first context only)` for a TSV
#       written before every context was read.
#
# Exposes (thin kubectl wrappers — each takes <ctx> <kubectl_argv...>):
#   env_istiod_resources <ctx> <argv...>
#   env_network          <ctx> <argv...>   (istiod env, else the istio-system
#                                           topology.istio.io/network label)
#   env_istiod_scan <contexts_csv> <argv...>
#                                         -> istiod req/lim of the first context plus
#                                            the replica count of every context
#
# Exposes (campaign-end renderer):
#   render_scale_envelope <results_dir> <report_script> <contexts_csv> <kubectl_argv...>
#       -> renders the docs/campaigns/TEMPLATE.md scale-envelope tables (mesh topology,
#          control-plane provisioning & headroom, scale verdict) as markdown to stdout.
#          Reads the report's JSON (peak-mesh row + capacity metadata) and takes a
#          read-only `kubectl top nodes` / `top pod -l app=istiod` snapshot across
#          --contexts. Per-sweep dir only (PL6); never a flat glob.
#
# Requires: tests/lib/common.sh (die, split_csv), tests/lib/capacity.sh, jq, awk;
# render_scale_envelope also tests/lib/platform.sh (platform_summary: the platform record's row).
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# env_parse_istiod_resources: `kubectl get deploy istiod -n istio-system -o json`
# on stdin. Reads the discovery/istiod container resources.requests AND .limits
# (kept distinct — the envelope's provisioning table shows "req / lim"). cpu->m,
# mem->Mi; replicas from .spec.replicas. Any missing field -> that field `unknown`.
# Emits: req_cpu_m=.. req_mem_mi=.. lim_cpu_m=.. lim_mem_mi=.. replicas=..
# shellcheck disable=SC2329
env_parse_istiod_resources() {
	local body; body="$(cat)"
	if [[ -z "${body//[[:space:]]/}" ]]; then
		printf '%s\n' "req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown"
		return 0
	fi
	# CAP_JQ_QTY (capacity.sh): the shared cpu_to_m / mem_to_mi (decimal and binary suffixes).
	printf '%s' "$body" | jq -r "${CAP_JQ_QTY}"'
		def show($v): if $v == null then "unknown" else ($v | floor) end;
		( [ .spec.template.spec.containers[]?
		    | select(.name == "discovery" or .name == "istiod") ] | first ) as $c
		| if $c == null then
			"req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown"
		  else
			(($c.resources.requests // {})) as $req
			| (($c.resources.limits // {})) as $lim
			| (.spec.replicas) as $rep
			| "req_cpu_m=\(show(cpu_to_m($req.cpu))) " +
			  "req_mem_mi=\(show(mem_to_mi($req.memory))) " +
			  "lim_cpu_m=\(show(cpu_to_m($lim.cpu))) " +
			  "lim_mem_mi=\(show(mem_to_mi($lim.memory))) " +
			  "replicas=\(if $rep == null then "unknown" else $rep end)"
		  end
	' 2>/dev/null || printf '%s\n' "req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown"
}

# env_parse_network: `kubectl get deploy istiod -n istio-system -o json` on stdin.
# The Istio network id is injected into the discovery container env by the Sail
# operator as ISTIO_META_NETWORK (preferred) or NETWORK_ID. Emits `network=<id>`
# or `network=unknown`. Multi-network is then inferred at the fleet level by the
# renderer (distinct network ids across contexts).
# shellcheck disable=SC2329
env_parse_network() {
	local body; body="$(cat)"
	if [[ -z "${body//[[:space:]]/}" ]]; then
		printf '%s\n' "network=unknown"
		return 0
	fi
	printf '%s' "$body" | jq -r '
		( [ .spec.template.spec.containers[]?
		    | select(.name == "discovery" or .name == "istiod") ] | first ) as $c
		| if $c == null then "network=unknown"
		  else
			( [ $c.env[]? | select(.name == "ISTIO_META_NETWORK" or .name == "NETWORK_ID")
			    | .value ] | map(select(. != null and . != "")) | first ) as $n
			| "network=\(if $n == null then "unknown" else $n end)"
		  end
	' 2>/dev/null || printf '%s\n' "network=unknown"
}

# env_pct_of_limit <used> <per_replica_limit> <replicas>: integer percent of the
# CROSS-REPLICA limit. The numerator (`used`) is a sum across all istiod replicas
# (a `kubectl top pod -l app=istiod` sum), so the denominator MUST be the
# per-replica limit times the replica count, NOT the per-replica limit (PL35 —
# scope numerator<->denominator or an idle R-replica plane reads ~R*100%).
# `unknown` if any arg is non-numeric or the scaled limit <= 0.
# shellcheck disable=SC2329
env_pct_of_limit() {
	local used="${1:-}" per_replica="${2:-}" replicas="${3:-}"
	awk -v u="$used" -v l="$per_replica" -v r="$replicas" '
	function isnum(x) { return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
		if (!isnum(u) || !isnum(l) || !isnum(r)) { print "unknown"; exit }
		denom = (l + 0) * (r + 0)
		if (denom <= 0) { print "unknown"; exit }
		printf "%d\n", int((100 * u / denom) + 0.5)
	}'
}

# env_sla_verdict [--nodes-excluded REASON] <icpu_pct> <imem_pct> <ncpu_pct> <nmem_pct> <restarts> <n_total> <n_valid> [caution_pct] [fail_pct]
# Computes the headline customer SLA verdict from the report's validity-gated
# aggregates (already n_valid-filtered by the caller — never configured axis
# values, PL35). The CAUTION/FAIL utilization bands default from the env
# (SCALE_SLA_CAUTION_PCT=75 / SCALE_SLA_FAIL_PCT=90, both in config/options.env) but
# can be passed in as args 8/9 so the function stays pure / unit-testable. Bands:
#   FAIL    — any istiod restart in a valid window (restarts > 0), or zero valid
#             samples (n_valid == 0 with n_total > 0), or any utilization >= fail_pct.
#   CAUTION — any utilization in [caution_pct, fail_pct), or any utilization unknown
#             (metrics API gap), or n_valid < n_total (some samples poisoned).
#   PASS    — all utilizations < caution_pct, no restarts, every sample valid.
# --nodes-excluded REASON (the nodes' figures do not measure the cluster: kind nodes report
# the shared host) leaves ncpu_pct and nmem_pct out of the bands; a PASS on istiod alone is
# then CAUTION "node figures left out: REASON; the figures: <reason>", any other verdict keeps
# its own and adds "; also node figures left out: REASON".
# Emits "<VERDICT>|<one-line headline>". Pure.
# shellcheck disable=SC2329
env_sla_verdict() {
	local _env_nodes_out=""
	if [[ "${1:-}" == --nodes-excluded ]]; then
		_env_nodes_out="${2:-the node figures do not measure the cluster}"
		shift 2
	fi
	local caution="${8:-${SCALE_SLA_CAUTION_PCT:-75}}" fail="${9:-${SCALE_SLA_FAIL_PCT:-90}}"
	awk -v icpu="${1:-}" -v imem="${2:-}" -v ncpu="${3:-}" -v nmem="${4:-}" \
	    -v restarts="${5:-0}" -v ntotal="${6:-0}" -v nvalid="${7:-0}" \
	    -v caution="$caution" -v fail="$fail" -v nodes_out="$_env_nodes_out" '
	function isnum(x) { return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
		scope = "istiod + nodes"
		if (nodes_out != "") { n_metrics = split(icpu "|" imem, m, "|"); scope = "istiod" }
		else n_metrics = split(icpu "|" imem "|" ncpu "|" nmem, m, "|")
		peak = -1; any_unknown = 0
		for (i = 1; i <= n_metrics; i++) {
			if (isnum(m[i])) { if (m[i]+0 > peak) peak = m[i]+0 }
			else any_unknown = 1
		}
		verdict = "PASS"
		reason = ""
		# Integrity gates first (FAIL dominates).
		if ((ntotal+0) > 0 && (nvalid+0) == 0) {
			verdict = "FAIL"; reason = "no valid samples survived the restart/status filter (n_valid=0)"
		} else if ((restarts+0) > 0) {
			verdict = "FAIL"; reason = sprintf("%d istiod restart(s) inside a measurement window — control plane not stable under load", restarts+0)
		} else if (peak >= fail+0) {
			verdict = "FAIL"; reason = sprintf("peak utilization %d%% >= %d%% — at/over a resource limit", peak, fail+0)
		} else if (peak >= caution+0) {
			verdict = "CAUTION"; reason = sprintf("peak utilization %d%% in [%d,%d)%% — limited headroom", peak, caution+0, fail+0)
		} else if (any_unknown) {
			verdict = "CAUTION"; reason = "one or more utilization signals unavailable (metrics API gap) — headroom not fully verified"
		} else if ((ntotal+0) > 0 && (nvalid+0) < (ntotal+0)) {
			verdict = "CAUTION"; reason = sprintf("%d of %d samples poisoned/filtered — partial coverage", (ntotal+0)-(nvalid+0), ntotal+0)
		} else if (peak < 0) {
			verdict = "CAUTION"; reason = "no utilization measured — headroom unverified"
		} else {
			verdict = "PASS"; reason = sprintf("peak utilization %d%% < %d%% across %s, no restarts, all %d samples valid", peak, caution+0, scope, nvalid+0)
		}
		if (nodes_out != "") {
			if (verdict == "PASS") { verdict = "CAUTION"; reason = "node figures left out: " nodes_out "; the figures: " reason }
			else reason = reason "; also node figures left out: " nodes_out
		}
		printf "%s|%s\n", verdict, reason
	}'
}

# env_replicas_summary <n...>: the ISTIOD_REPLICAS preamble token for per-context
# istiod replica counts. One number when every numeric value is the same (`3`, the
# form older TSVs carry), `min-max` when they differ (`1-3`), `unknown` when none is
# numeric. A context whose read failed is left out of the range;
# ISTIOD_REPLICAS_BY_CONTEXT names it. One token, no spaces. Pure.
# shellcheck disable=SC2329
env_replicas_summary() {
	local v min="" max=""
	for v in "$@"; do
		[[ "$v" =~ ^[0-9]+$ ]] || continue
		v=$((10#$v))
		if [[ -z "$min" ]] || ((v < min)); then min="$v"; fi
		if [[ -z "$max" ]] || ((v > max)); then max="$v"; fi
	done
	if [[ -z "$min" ]]; then
		echo unknown
	elif ((min == max)); then
		echo "$min"
	else
		echo "${min}-${max}"
	fi
}

# env_replicas_label <replicas> [by_context]: how reports print ISTIOD_REPLICAS.
#   3   -> "3 per cluster"; 1-3 -> "1-3 per cluster (varies by cluster)"
#   a number with no (or an `unknown`) by_context -> "3 (first context only)": a TSV
#   written before every context was read (ISTIOD_REPLICAS_BY_CONTEXT absent)
#   by_context naming a context as `unknown` adds "; not read on N of M contexts"
#   anything else (unknown) is printed as-is. Pure.
# shellcheck disable=SC2329
env_replicas_label() {
	local reps="${1:-unknown}" by="${2:-unknown}" label n_unknown n_ctx
	if [[ "$reps" =~ ^[0-9]+$ ]]; then
		if [[ "$by" == unknown || -z "$by" ]]; then
			echo "${reps} (first context only)"
			return 0
		fi
		label="${reps} per cluster"
	elif [[ "$reps" =~ ^[0-9]+-[0-9]+$ ]]; then
		label="${reps} per cluster (varies by cluster)"
	else
		echo "$reps"
		return 0
	fi
	n_ctx="$(printf '%s' "$by" | tr ',' '\n' | grep -c . || true)"
	n_unknown="$(printf '%s' "$by" | tr ',' '\n' | grep -c '=unknown$' || true)"
	if ((n_unknown > 0)); then label+="; not read on ${n_unknown} of ${n_ctx} contexts"; fi
	echo "$label"
}

# env_limit_drift_warning <rec_cpu_m> <rec_mem_mi> <live_cpu_m> <live_mem_mi>: the envelope's
# window-peak CPU and RSS figures divide by the istiod limit the sweep recorded at its start
# (ISTIOD_CPU_LIMIT_M, ISTIOD_MEM_LIMIT_MI); its kubectl top figures by each row's own limit,
# read with that row; its "Provisioned" column is read live. One warning when a limit is
# numeric on both sides and differs, else nothing. Pure.
# shellcheck disable=SC2329
env_limit_drift_warning() {
	local _env_o="" _env_rc="$1" _env_rm="$2" _env_lc="$3" _env_lm="$4"
	[[ ! "$_env_rc" =~ ^[0-9]+$ || ! "$_env_lc" =~ ^[0-9]+$ || "$_env_rc" == "$_env_lc" ]] ||
		_env_o+="CPU ${_env_rc}m recorded, ${_env_lc}m now"
	[[ ! "$_env_rm" =~ ^[0-9]+$ || ! "$_env_lm" =~ ^[0-9]+$ || "$_env_rm" == "$_env_lm" ]] ||
		_env_o+="${_env_o:+; }memory ${_env_rm}Mi recorded, ${_env_lm}Mi now"
	[[ -n "$_env_o" ]] || return 0
	printf '%s\n' "istiod's limit per replica differs from the one the sweep recorded at its start (${_env_o}): the window-peak CPU and RSS % below use the recorded one, the kubectl top % each row's own (read with it), the Provisioned column the one read now; the limit changed during or after the sweep (an Argo CD sync, a tuning profile or a hand edit)"
}

# env_pct_cell <pct> [<limit> <unit> | row]: an envelope "Measured (% of limit)" cell: "<pct>% of
# <limit><unit>" when both are numbers, "<pct>% of each row's limit" with row (the kubectl top
# figures: each row divides by its own limit, read with it), "<pct>%" without a numeric limit,
# and the value as it is (unknown, N/A) when the percentage is not a number. Pure.
# shellcheck disable=SC2329
env_pct_cell() {
	local _env_p="${1:-}" _env_l="${2:-}" _env_u="${3:-}"
	if [[ ! "$_env_p" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		printf '%s\n' "${_env_p:-unknown}"
	elif [[ "$_env_l" == row ]]; then
		printf "%s%% of each row's limit\n" "$_env_p"
	elif [[ "$_env_l" =~ ^[0-9]+$ ]]; then
		printf '%s%% of %s%s\n' "$_env_p" "$_env_l" "$_env_u"
	else
		printf '%s%%\n' "$_env_p"
	fi
}

# ---------------------------------------------------------------------------
# Thin kubectl wrappers (read-only).
# ---------------------------------------------------------------------------

# env_istiod_resources <ctx> <kubectl_argv...>
# Targets the unsuffixed `istiod` Deployment (default Sail revision) — same
# caveat as capacity.sh:cap_istiod_limits for non-default revisions.
# shellcheck disable=SC2329
env_istiod_resources() {
	local ctx="$1"; shift
	"$@" --context="$ctx" --request-timeout=5s -n istio-system get deploy istiod -o json 2>/dev/null \
		| env_parse_istiod_resources
}

# env_istiod_scan <contexts_csv> <kubectl_argv...>
# istiod req/lim from the SOURCE (first) context, which is the pin the preamble
# records, plus the replica count of EVERY context, read concurrently (one
# `get deploy istiod` each, 5 s timeout) so a 20-cluster mesh costs one read, not 20.
# Members can run different replica counts, and the per-replica proxy figure is about
# 1/R of the cluster figure, so R must not come from the first context alone. Emits:
#   req_cpu_m=.. req_mem_mi=.. lim_cpu_m=.. lim_mem_mi=.. replicas=<summary> replicas_by_context=<ctx=n,...>
# replicas is env_replicas_summary over the contexts; a failed read is `unknown` in
# replicas_by_context (`unknown` as a whole with no contexts). Never dies (PL40).
# shellcheck disable=SC2329
env_istiod_scan() {
	local contexts_csv="$1"; shift
	local -a ctxs=() rep_list=() pids=() rk=()
	split_csv "$contexts_csv" ctxs
	local req_cpu="unknown" req_mem="unknown" lim_cpu="unknown" lim_mem="unknown"
	local by="" kv i rep tmp="" p
	if ((${#ctxs[@]})) && tmp="$(mktemp -d 2>/dev/null)"; then
		# Temp files by index: context names can contain '/' (oc login style).
		for i in "${!ctxs[@]}"; do
			env_istiod_resources "${ctxs[i]}" "$@" > "${tmp}/${i}" 2>/dev/null &
			pids+=($!)
		done
		for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
		for i in "${!ctxs[@]}"; do
			rep="unknown"
			# shellcheck disable=SC2207
			rk=($(cat "${tmp}/${i}" 2>/dev/null))
			for kv in ${rk[@]+"${rk[@]}"}; do
				case "$kv" in
					replicas=*) rep="${kv#replicas=}" ;;
				esac
				if ((i == 0)); then
					case "$kv" in
						req_cpu_m=*) req_cpu="${kv#req_cpu_m=}" ;;
						req_mem_mi=*) req_mem="${kv#req_mem_mi=}" ;;
						lim_cpu_m=*) lim_cpu="${kv#lim_cpu_m=}" ;;
						lim_mem_mi=*) lim_mem="${kv#lim_mem_mi=}" ;;
					esac
				fi
			done
			[[ -n "$rep" ]] || rep="unknown"
			rep_list+=("$rep")
			by="${by:+${by},}${ctxs[i]}=${rep}"
		done
		rm -rf "$tmp"
	fi
	printf 'req_cpu_m=%s req_mem_mi=%s lim_cpu_m=%s lim_mem_mi=%s replicas=%s replicas_by_context=%s\n' \
		"$req_cpu" "$req_mem" "$lim_cpu" "$lim_mem" \
		"$(env_replicas_summary ${rep_list[@]+"${rep_list[@]}"})" "${by:-unknown}"
}

# env_network <ctx> <kubectl_argv...>
# Reads the istiod env first; when it carries no network id (Istio 1.2x+ sets the
# network only as the topology.istio.io/network label on istio-system), falls back
# to that namespace label. Emits `network=<id>` or `network=unknown`.
# shellcheck disable=SC2329
env_network() {
	local ctx="$1"; shift
	local net label
	net="$("$@" --context="$ctx" --request-timeout=5s -n istio-system get deploy istiod -o json 2>/dev/null \
		| env_parse_network)"
	if [[ "$net" == "network=unknown" ]]; then
		label="$("$@" --context="$ctx" --request-timeout=5s get namespace istio-system \
			-o jsonpath='{.metadata.labels.topology\.istio\.io/network}' 2>/dev/null)" || label=""
		[[ -n "$label" ]] && net="network=${label}"
	fi
	printf '%s\n' "$net"
}

# env_collect_infra <contexts_csv> <kubectl_argv...>
# Read-only collection of the cluster-infra values that feed the TSV preamble's
# additive infra block (preamble.sh:infra_preamble_lines). Reads:
#   - istiod req/lim from the SOURCE context and the replica count of EVERY context
#     (env_istiod_scan): ISTIOD_REPLICAS is one number when the members agree,
#     `min-max` when they differ, and ISTIOD_REPLICAS_BY_CONTEXT lists ctx=n;
#   - the network topology (single/multi-network) across ALL contexts (env_network).
# These are sweep-level scalars (the pin and mesh wiring are homogeneous across a
# coherent run — PL26). Node allocatable is NOT read here — the O9 capacity block in
# 002/003 already emits NODE_ALLOC_* (single-source per key, F4). Emits space-separated
# `KEY=value` tokens on one line; every read degrades to `unknown` independently so a
# missing metrics path never aborts the caller (mirrors capacity.sh).
# shellcheck disable=SC2329
env_collect_infra() {
	local contexts_csv="$1"; shift
	local -a ctxs=()
	split_csv "$contexts_csv" ctxs
	local req_cpu="unknown" req_mem="unknown" lim_cpu="unknown" lim_mem="unknown" reps="unknown" reps_by="unknown"
	local kv
	# shellcheck disable=SC2207
	local -a rk=($(env_istiod_scan "$contexts_csv" "$@"))
	for kv in "${rk[@]}"; do
		case "$kv" in
			req_cpu_m=*) req_cpu="${kv#req_cpu_m=}" ;;
			req_mem_mi=*) req_mem="${kv#req_mem_mi=}" ;;
			lim_cpu_m=*) lim_cpu="${kv#lim_cpu_m=}" ;;
			lim_mem_mi=*) lim_mem="${kv#lim_mem_mi=}" ;;
			replicas=*) reps="${kv#replicas=}" ;;
			replicas_by_context=*) reps_by="${kv#replicas_by_context=}" ;;
		esac
	done
	# Network topology across all contexts.
	local ctx networks_csv="" net
	for ctx in "${ctxs[@]}"; do
		net="$(env_network "$ctx" "$@")"; net="${net#network=}"
		[[ -z "$networks_csv" ]] && networks_csv="$net" || networks_csv="${networks_csv},${net}"
	done
	# F6: each distinct network is a separate context's own local istiod (multi-primary),
	# so label >1 networks "multi-primary,multi-network:N" (comma, no spaces — this is a
	# single preamble token; the report renders it verbatim).
	local n_networks topology
	n_networks="$(printf '%s' "$networks_csv" | tr ',' '\n' | grep -v '^unknown$' | sort -u | grep -c . || true)"
	if [[ "${n_networks:-0}" -gt 1 ]]; then topology="multi-primary,multi-network:${n_networks}"
	elif [[ "${n_networks:-0}" -eq 1 ]]; then topology="single-network"
	else topology="unknown"; fi
	printf 'ISTIOD_REQ_CPU_M=%s ISTIOD_REQ_MEM_MI=%s ISTIOD_LIM_CPU_M=%s ISTIOD_LIM_MEM_MI=%s ISTIOD_REPLICAS=%s ISTIOD_REPLICAS_BY_CONTEXT=%s NETWORK_TOPOLOGY=%s\n' \
		"$req_cpu" "$req_mem" "$lim_cpu" "$lim_mem" "$reps" "$reps_by" "$topology"
}

# ---------------------------------------------------------------------------
# render_scale_envelope <results_dir> <report_script> <contexts_csv> <kubectl_argv...>
# Renders the docs/campaigns/TEMPLATE.md scale-envelope tables from a COMPLETED
# sweep dir (PL6 — a specific sweep-<RUN_ID>/ dir, never a flat glob). Reads the
# report's own JSON (so the measured peaks already passed the report's n_valid
# gate) and takes a read-only `kubectl top` snapshot across --contexts.
# shellcheck disable=SC2329
render_scale_envelope() {
	local results_dir="$1" report_script="$2" contexts_csv="$3"; shift 3
	# shellcheck disable=SC2206
	local -a kubectl_argv=("$@")
	[[ -d "$results_dir" ]] || die "render_scale_envelope: results dir not found: $results_dir"
	[[ -x "$report_script" ]] || die "render_scale_envelope: report script not found/executable: $report_script"
	declare -F platform_summary >/dev/null || die "render_scale_envelope needs platform_summary (source tests/lib/platform.sh)"

	local json
	json="$("$report_script" --results-dir "$results_dir" --format json 2>/dev/null || true)"
	[[ -n "$json" ]] || die "render_scale_envelope: report produced no JSON for $results_dir"

	# Pull capacity provenance + achieved-scale maxes from the report metadata
	# (the report already applied the validity gate to these maxes — PL35).
	jq_get() { printf '%s' "$json" | jq -r "$1 // \"unknown\"" 2>/dev/null || printf 'unknown'; }

	local node_cpu_m node_mem_mi istio_version harness_sha
	node_cpu_m="$(jq_get '.metadata.capacity.node_alloc_cpu_m')"
	node_mem_mi="$(jq_get '.metadata.capacity.node_alloc_mem_mi')"
	# The per-replica istiod limit the window-peak CPU and RSS figures divide by (recorded at the
	# sweep's start); the kubectl top figures divide by each row's own.
	local _env_rec_cpu _env_rec_mem
	_env_rec_cpu="$(jq_get '.metadata.capacity.istiod_cpu_limit_m')"
	_env_rec_mem="$(jq_get '.metadata.capacity.istiod_mem_limit_mi')"
	istio_version="$(jq_get '.metadata.istio_version')"
	harness_sha="$(jq_get '.metadata.harness_sha')"

	local proxies_peak proxies_cluster_peak proxy_check istiod_cpu_pct istiod_mem_pct istiod_rss_pct node_cpu_pct node_mem_pct
	proxies_peak="$(jq_get '.metadata.achieved_scale.connected_proxies_max')"
	# Per-cluster peak (pilot_xds summed over one cluster's istiod pods at one scrape)
	# and the proxy check tally; `unknown` on a report without them. n/a and excluded
	# are printed too, so a run where most scrapes land there does not read as a pass.
	proxies_cluster_peak="$(jq_get '.metadata.achieved_scale.connected_proxies_cluster_max')"
	proxy_check="$(printf '%s' "$json" | jq -r '
		.metadata.proxy_check as $p
		| if $p == null then "unknown"
		  else "ok=\($p.ok // "unknown") low=\($p.low // "unknown") high=\($p.high // "unknown") n/a=\($p.na // "unknown") excluded=\($p.excluded // "unknown") (tolerance \($p.tolerance_pct // "unknown")%, min diff \($p.min_diff // "unknown"))"
		  end' 2>/dev/null)" || proxy_check="unknown"
	[[ -n "$proxy_check" ]] || proxy_check="unknown"
	# The window peak CPU vs the per-replica limit; the kubectl-top snapshot
	# (istiod_cpu_pct_of_limit_max) is read once at a window's end and misses bursts.
	local istiod_cpu_top_pct
	istiod_cpu_pct="$(jq_get '.metadata.achieved_scale.istiod_cpu_peak_pct_of_limit_max')"
	istiod_cpu_top_pct="$(jq_get '.metadata.achieved_scale.istiod_cpu_pct_of_limit_max')"
	istiod_mem_pct="$(jq_get '.metadata.achieved_scale.istiod_mem_pct_of_limit_max')"
	# P1-4: RSS-derived istiod mem headroom (% of per-replica mem limit). Always
	# available from the /metrics scrape, so it surfaces OOM risk even when the
	# kubectl-top mem pct above is N/A during a metrics-API gap.
	istiod_rss_pct="$(jq_get '.metadata.achieved_scale.istiod_rss_pct_of_limit_max')"
	node_cpu_pct="$(jq_get '.metadata.achieved_scale.node_cpu_pct_max')"
	node_mem_pct="$(jq_get '.metadata.achieved_scale.node_mem_pct_max')"

	# Peak mesh-size point: the row with the largest mesh_size (the peak the
	# TEMPLATE.md envelope is supposed to characterize). PL35: gate on n_valid>0 so a
	# poisoned/restarted row (which still carries its CONFIGURED service_count, e.g.
	# 999) cannot become the "peak" and misreport the topology as achieved fact. Fall
	# back to all rows only if NO row is valid (so a fully-failed sweep still renders).
	# A none and a vsdr cell at the same peak mesh size tie: prefer the none cell (the
	# baseline; a report without traffic_config reads as none). Among other ties the
	# last row wins, as max_by did.
	local peak_json
	peak_json="$(printf '%s' "$json" | jq -c '
		(.results // []) as $all
		| ([ $all[] | select((.n_valid // 0) > 0) ]) as $valid
		| (if ($valid | length) > 0 then $valid else $all end)
		| if length == 0 then null
		  else (map(.mesh_size) | max) as $m
		  | [ .[] | select(.mesh_size == $m) ] as $peak
		  | [ $peak[] | select((.traffic_config // "none") == "none") ] as $peak_none
		  | (if ($peak_none | length) > 0 then $peak_none else $peak end) | last
		  end' 2>/dev/null || printf 'null')"
	local peak_mesh peak_svc peak_reps peak_ns peak_scope peak_traffic peak_wmode peak_mpods
	if [[ -n "$peak_json" && "$peak_json" != "null" ]]; then
		peak_mesh="$(printf '%s' "$peak_json" | jq -r '.mesh_size // "unknown"')"
		peak_svc="$(printf '%s' "$peak_json" | jq -r '.service_count // "unknown"')"
		peak_reps="$(printf '%s' "$peak_json" | jq -r '.replicas // "unknown"')"
		peak_ns="$(printf '%s' "$peak_json" | jq -r '.namespace_count // "unknown"')"
		peak_scope="$(printf '%s' "$peak_json" | jq -r '.sidecar_scoping // "unknown"')"
		peak_traffic="$(printf '%s' "$peak_json" | jq -r '.traffic_config // "none"')"
		peak_wmode="$(printf '%s' "$peak_json" | jq -r '.workload_mode // "pods"')"
		peak_mpods="$(printf '%s' "$peak_json" | jq -r '.measurement_pods // "unknown"')"
	else
		peak_mesh="unknown"; peak_svc="unknown"; peak_reps="unknown"; peak_ns="unknown"; peak_scope="unknown"; peak_traffic="unknown"
		peak_wmode="pods"; peak_mpods="unknown"
	fi

	# Live read-only snapshot: istiod resources (req/lim of the source context, the
	# replica count of every context), network id, node top, across every context.
	# Networks collected to infer multi-network.
	local -a ctxs=()
	split_csv "$contexts_csv" ctxs
	local ctx kv
	local req_cpu="unknown" req_mem="unknown" lim_cpu="unknown" lim_mem="unknown" istiod_replicas="unknown" replicas_by="unknown"
	local networks_csv=""
	# shellcheck disable=SC2207
	local -a rk=($(env_istiod_scan "$contexts_csv" "${kubectl_argv[@]}"))
	for kv in "${rk[@]}"; do
		case "$kv" in
			req_cpu_m=*) req_cpu="${kv#req_cpu_m=}" ;;
			req_mem_mi=*) req_mem="${kv#req_mem_mi=}" ;;
			lim_cpu_m=*) lim_cpu="${kv#lim_cpu_m=}" ;;
			lim_mem_mi=*) lim_mem="${kv#lim_mem_mi=}" ;;
			replicas=*) istiod_replicas="${kv#replicas=}" ;;
			replicas_by_context=*) replicas_by="${kv#replicas_by_context=}" ;;
		esac
	done
	# Context names stay out of the envelope (it is pasted into campaign docs); the
	# label says whether the members differ.
	local replicas_label
	replicas_label="$(env_replicas_label "$istiod_replicas" "$replicas_by")"
	for ctx in "${ctxs[@]}"; do
		local net
		net="$(env_network "$ctx" "${kubectl_argv[@]}")"
		net="${net#network=}"
		[[ -z "$networks_csv" ]] && networks_csv="$net" || networks_csv="${networks_csv},${net}"
	done
	# Distinct non-unknown networks across the per-context istiod reads. F6: each
	# distinct network came from a SEPARATE context's own local istiod (env_collect_infra
	# iterates one istiod per context) — that per-cluster control plane IS the
	# multi-primary signal — so label >1 networks "multi-primary, multi-network".
	local n_networks topology
	n_networks="$(printf '%s' "$networks_csv" | tr ',' '\n' | grep -v '^unknown$' | sort -u | grep -c . || true)"
	if [[ "${n_networks:-0}" -gt 1 ]]; then
		topology="multi-primary, multi-network (${n_networks} networks)"
	elif [[ "${n_networks:-0}" -eq 1 ]]; then
		topology="single-network"
	else
		topology="unknown"
	fi

	# Total services / endpoints (derived; honest "unknown" if any factor unknown).
	local total_svc total_eps
	total_svc="$(awk -v n="$peak_mesh" -v s="$peak_svc" 'function num(x){return x~/^[0-9]+$/} BEGIN{ if(num(n)&&num(s)) print n*s; else print "unknown" }')"
	total_eps="$(awk -v n="$peak_mesh" -v s="$peak_svc" -v r="$peak_reps" 'function num(x){return x~/^[0-9]+$/} BEGIN{ if(num(n)&&num(s)&&num(r)) print n*s*r; else print "unknown" }')"
	# Config-only growth cells run Services without pods (plus M measurement pods), so
	# N x S x R endpoints never existed.
	local reps_label="$peak_reps"
	if [[ "$peak_wmode" == config-only ]]; then
		total_eps="N/A (config-only: Services without pods; ${peak_mpods} measurement pod(s) per cluster)"
		reps_label="N/A (config-only)"
	fi

	# Verdict: C1 — read the single authoritative verdict the REPORT already computed
	# (004 calls env_sla_verdict once with the env bands). Reading it back here removes a
	# second compute site that would have to stay in sync if the SLA bands change.
	local verdict headline
	verdict="$(jq_get '.metadata.sla.verdict')"
	headline="$(jq_get '.metadata.sla.headline')"

	# The report's data warnings (kind nodes, leftover namespaces, inputs that disagree on the
	# platform record, ...), above every figure they qualify; and the platform record without
	# member names (platform_summary).
	local _env_warnings_md="" _env_w _env_platform_row
	while IFS= read -r _env_w; do
		[[ -z "$_env_w" ]] || _env_warnings_md+="> **Warning:** ${_env_w}"$'\n\n'
	done < <(printf '%s' "$json" | jq -r '.metadata.data_warnings[]? // empty' 2>/dev/null || true)
	_env_w="$(env_limit_drift_warning "$_env_rec_cpu" "$_env_rec_mem" "$lim_cpu" "$lim_mem")"
	[[ -z "$_env_w" ]] || _env_warnings_md+="> **Warning:** ${_env_w}"$'\n\n'
	_env_platform_row="$(jq_get '.metadata.platform') (TEST_PLATFORM $(jq_get '.metadata.test_platform')); nodes $(platform_summary "$(jq_get '.metadata.node_provider_by_context')"); operator $(platform_summary "$(jq_get '.metadata.mesh_operator_by_context')"); istiod $(platform_summary "$(jq_get '.metadata.istiod_image_by_context')"); gateway proxy $(platform_summary "$(jq_get '.metadata.proxy_image_by_context')"); istiod env $(platform_summary "$(jq_get '.metadata.istiod_env_by_context')"); tuning objects $(platform_summary "$(jq_get '.metadata.tuning_objects_by_context')")"

	# ---- render ----
	cat <<MD
## Scale envelope

> Auto-generated by \`tests/lib/envelope.sh:render_scale_envelope\` from \`$(basename "$results_dir")\` (harness \`${harness_sha}\`).
> Measured columns are the report's n_valid-gated peaks (restarted/SETUP_FAILED rows excluded).

${_env_warnings_md}### 1. Mesh topology — what the peak mesh-size point actually contains

| Dimension | Value | Source |
|---|---|---|
| Clusters (multi-primary) | ${peak_mesh} | sweep peak \`mesh_size\` |
| Services / cluster | ${peak_svc} | sweep peak \`service_count\` |
| Namespaces / cluster | ${peak_ns} | sweep peak \`namespace_count\` |
| Workload replicas / service | ${reps_label} | sweep peak \`replicas\` |
| **Total services in mesh** | ${total_svc} | derived (N x S) |
| **Total endpoints in mesh** | ${total_eps} | derived (N x S x R) |
| **Connected proxies per cluster (measured peak)** | ${proxies_cluster_peak} | report achieved-scale \`connected_proxies_cluster_max\` (n_valid-gated) |
| Connected proxies per istiod replica (peak) | ${proxies_peak} | report achieved-scale \`connected_proxies_max\` (n_valid-gated) |
| Proxy check vs Running sidecar pods | ${proxy_check} | report \`proxy_check\` (cluster scrapes by result) |
| Network topology | ${topology} | istiod network env or \`istio-system\` \`topology.istio.io/network\` label, across contexts |
| Sidecar scoping | ${peak_scope} | sweep peak \`sidecar_scoping\` |
| Traffic management | ${peak_traffic} | sweep peak \`traffic_config\` (none preferred when a vsdr cell ties at the peak mesh size) |
| Istio version | ${istio_version} | sweep header \`ISTIO_VERSION\` |
| Platform / mesh build | ${_env_platform_row} | report \`platform\` and the \`*_by_context\` keys of the TSVs' platform record (gateway proxy: the ingress and east-west gateways' build; tuning objects: a tuning profile's labelled objects, none outside a tuning run; digests shortened) |

> **Connected proxies per cluster** is \`pilot_xds\` summed over one cluster's istiod replicas at one scrape. It should be about equal to that cluster's Running injected pods (gateways included), which the proxy check compares. It is still not a mesh-wide sum and not endpoints; do not expect it to equal total endpoints. **Per istiod replica** is the busiest single replica (max over the per-pod rows), about 1/R of the cluster figure with R replicas.

### 2. Control-plane provisioning & headroom — *was anything actually stressed?*

| Resource | Provisioned (req / lim, per replica) | Measured (% of limit) | Source |
|---|---|---|---|
| istiod replicas | ${replicas_label} | — | live \`deploy/istiod\` on every context |
| **istiod CPU (window peak)** | ${req_cpu}m / ${lim_cpu}m | $(env_pct_cell "$istiod_cpu_pct" "$_env_rec_cpu" m) | report \`istiod_cpu_peak_pct_of_limit_max\`: one replica's peak (the larger of a window's average and its busiest 5 s poll) / the per-replica limit the sweep recorded |
| istiod CPU (kubectl top at window end) | ${req_cpu}m / ${lim_cpu}m | $(env_pct_cell "$istiod_cpu_top_pct" row) | report \`istiod_cpu_pct_of_limit_max\`: one snapshot per window, summed over the replicas / their summed limit, read with that row; misses bursts |
| istiod memory (kubectl top) | ${req_mem}Mi / ${lim_mem}Mi | $(env_pct_cell "$istiod_mem_pct" row) | report \`istiod_mem_pct_of_limit_max\`: as the row above |
| **istiod memory (RSS — OOM headroom)** | ${req_mem}Mi / ${lim_mem}Mi | $(env_pct_cell "$istiod_rss_pct" "$_env_rec_mem" Mi) | report \`istiod_rss_pct_of_limit_max\` (\`process_resident_memory_bytes\`) / the per-replica limit the sweep recorded |
| Worker-node CPU | — | $(env_pct_cell "$node_cpu_pct") | report \`node_cpu_pct_max\` (\`kubectl top nodes\`) |
| Worker-node memory | — | $(env_pct_cell "$node_mem_pct") | report \`node_mem_pct_max\` (\`kubectl top nodes\`) |

> Node allocatable (source ctx): ${node_cpu_m}m CPU / ${node_mem_mi}Mi memory.
> istiod CPU/mem(top) % is of the **cross-replica** limit (per-replica limit x that cluster's istiod replicas), so an idle R-replica plane does not read ~Rx100% (PL35).
> The window-peak CPU and RSS rows divide by the per-replica limit the sweep recorded at its start (ISTIOD_CPU_LIMIT_M, ISTIOD_MEM_LIMIT_MI: their "of" value); the kubectl top rows by each row's own limit, read with that row, times its cluster's replicas; "Provisioned" is read live now (a warning above when it differs from the recorded limit).
> **istiod RSS %** is per-replica (peak \`process_resident_memory_bytes\` of one istiod / its per-replica mem limit) and is the OOM-risk signal: in multi-primary each istiod caches the WHOLE mesh (~N x services x replicas endpoints), so RSS grows with total mesh size. It is sourced from the /metrics scrape, so it stays populated even when \`kubectl top\` (the row above) is N/A during a metrics-API gap. An RSS % approaching 100 is OOM-mid-sweep risk.
> **istiod mem REQUEST sizing (GO gate):** the chart's istiod mem *request* (${req_mem}Mi above) must be sized to the **measured steady-state RSS** at the target mesh scale before GO — it needs a measured number from a full-scale run, NOT a guessed default. The RSS % here is the input for that sizing. This change only SURFACES the headroom; it deliberately does not change the request value.

### Customer SLA verdict — one line, up front

> **${verdict}** — ${headline}
MD
}
