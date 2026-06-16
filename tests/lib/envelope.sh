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
#   env_pct_of_limit <used> <per_replica_limit> <replicas>
#                                                  -> integer percent of the CROSS-REPLICA
#       limit (per-replica limit * replicas), matching numerator (a cross-replica
#       `kubectl top` sum) to denominator scope (PL35). `unknown` if any arg bad.
#   env_sla_verdict <icpu_pct> <imem_pct> <ncpu_pct> <nmem_pct> <restarts> <n_total> <n_valid>
#                                                  -> "VERDICT|headline" — one of
#       PASS / CAUTION / FAIL plus a one-line human headline. The verdict is computed
#       only over the validity-gated aggregates the caller passes (the report's
#       n_valid maxes), never configured axis values (PL35).
#
# Exposes (thin kubectl wrappers — each takes <ctx> <kubectl_argv...>):
#   env_istiod_resources <ctx> <argv...>
#   env_network          <ctx> <argv...>
#
# Exposes (campaign-end renderer):
#   render_scale_envelope <results_dir> <report_script> <contexts_csv> <kubectl_argv...>
#       -> renders the docs/campaigns/TEMPLATE.md scale-envelope tables (mesh topology,
#          control-plane provisioning & headroom, scale verdict) as markdown to stdout.
#          Reads the report's JSON (peak-mesh row + capacity metadata) and takes a
#          read-only `kubectl top nodes` / `top pod -l app=istiod` snapshot across
#          --contexts. Per-sweep dir only (PL6); never a flat glob.
#
# Requires: tests/lib/common.sh (die, split_csv), tests/lib/capacity.sh, jq, awk.
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
	printf '%s' "$body" | jq -r '
		def cpu_to_m($q):
			if $q == null then null
			else
				(if ($q | type) != "string" then ($q | tostring) else $q end)
				| if test("m$") then (rtrimstr("m") | tonumber)
				  else (tonumber * 1000) end
			end;
		def mem_to_mi($q):
			if $q == null then null
			else
				($q | tostring) as $s
				| if   ($s | test("Ki$")) then (($s | rtrimstr("Ki") | tonumber) / 1024)
				  elif ($s | test("Mi$")) then  ($s | rtrimstr("Mi") | tonumber)
				  elif ($s | test("Gi$")) then (($s | rtrimstr("Gi") | tonumber) * 1024)
				  elif ($s | test("Ti$")) then (($s | rtrimstr("Ti") | tonumber) * 1024 * 1024)
				  else (($s | tonumber) / 1048576) end
			end;
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

# env_sla_verdict <icpu_pct> <imem_pct> <ncpu_pct> <nmem_pct> <restarts> <n_total> <n_valid>
# Computes the headline customer SLA verdict from the report's validity-gated
# aggregates (already n_valid-filtered by the caller — never configured axis
# values, PL35). Thresholds (utilization headroom + integrity):
#   FAIL    — any istiod restart in a valid window (restarts > 0), or zero valid
#             samples (n_valid == 0 with n_total > 0), or any utilization >= 90%.
#   CAUTION — any utilization in [75,90), or any utilization unknown (metrics API
#             gap), or n_valid < n_total (some samples poisoned).
#   PASS    — all utilizations < 75%, no restarts, every sample valid.
# Emits "<VERDICT>|<one-line headline>". Pure.
# shellcheck disable=SC2329
env_sla_verdict() {
	awk -v icpu="${1:-}" -v imem="${2:-}" -v ncpu="${3:-}" -v nmem="${4:-}" \
	    -v restarts="${5:-0}" -v ntotal="${6:-0}" -v nvalid="${7:-0}" '
	function isnum(x) { return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
		split(icpu SUBSEP imem SUBSEP ncpu SUBSEP nmem, _, SUBSEP)
		n_metrics = split(icpu "|" imem "|" ncpu "|" nmem, m, "|")
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
		} else if (peak >= 90) {
			verdict = "FAIL"; reason = sprintf("peak utilization %d%% >= 90%% — at/over a resource limit", peak)
		} else if (peak >= 75) {
			verdict = "CAUTION"; reason = sprintf("peak utilization %d%% in [75,90)%% — limited headroom", peak)
		} else if (any_unknown) {
			verdict = "CAUTION"; reason = "one or more utilization signals unavailable (metrics API gap) — headroom not fully verified"
		} else if ((ntotal+0) > 0 && (nvalid+0) < (ntotal+0)) {
			verdict = "CAUTION"; reason = sprintf("%d of %d samples poisoned/filtered — partial coverage", (ntotal+0)-(nvalid+0), ntotal+0)
		} else if (peak < 0) {
			verdict = "CAUTION"; reason = "no utilization measured — headroom unverified"
		} else {
			verdict = "PASS"; reason = sprintf("peak utilization %d%% < 75%% across istiod + nodes, no restarts, all %d samples valid", peak, nvalid+0)
		}
		printf "%s|%s\n", verdict, reason
	}'
}

# ---------------------------------------------------------------------------
# Thin kubectl wrappers (read-only).
# ---------------------------------------------------------------------------

# env_istiod_resources <ctx> <kubectl_argv...>
# Targets the unsuffixed `istiod` Deployment (default Sail revision) — same
# caveat as capacity.sh:cap_istiod_limits for non-default revisions (#44).
# shellcheck disable=SC2329
env_istiod_resources() {
	local ctx="$1"; shift
	"$@" --context="$ctx" --request-timeout=5s -n istio-system get deploy istiod -o json 2>/dev/null \
		| env_parse_istiod_resources
}

# env_network <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
env_network() {
	local ctx="$1"; shift
	"$@" --context="$ctx" --request-timeout=5s -n istio-system get deploy istiod -o json 2>/dev/null \
		| env_parse_network
}

# env_collect_infra <contexts_csv> <kubectl_argv...>
# Read-only collection of the cluster-infra values that feed the TSV preamble's
# additive infra block (preamble.sh:infra_preamble_lines). Reads:
#   - node allocatable cpu/mem from the SOURCE context (capacity.sh:cap_node_totals);
#   - istiod req/lim/replicas from the SOURCE context (env_istiod_resources);
#   - the network topology (single/multi-network) across ALL contexts (env_network).
# istiod req/lim/replicas + network topology are sweep-level scalars (the pin and the
# mesh wiring are homogeneous across a coherent run — PL26); node allocatable is the
# source-context fleet read (per-iteration in spirit, recorded once here). Emits
# space-separated `KEY=value` tokens on one line; every read degrades to `unknown`
# independently so a missing metrics path never aborts the caller (mirrors capacity.sh).
# shellcheck disable=SC2329
env_collect_infra() {
	local contexts_csv="$1"; shift
	local -a ctxs=()
	split_csv "$contexts_csv" ctxs
	local src_ctx="${ctxs[0]:-}"
	local node_cpu="unknown" node_mem="unknown"
	local req_cpu="unknown" req_mem="unknown" lim_cpu="unknown" lim_mem="unknown" reps="unknown"
	local kv
	if [[ -n "$src_ctx" ]]; then
		# shellcheck disable=SC2207
		local -a nt=($(cap_node_totals "$src_ctx" "$@"))
		for kv in "${nt[@]}"; do
			case "$kv" in
				cpu_m=*) node_cpu="${kv#cpu_m=}" ;;
				mem_mi=*) node_mem="${kv#mem_mi=}" ;;
			esac
		done
		# shellcheck disable=SC2207
		local -a rk=($(env_istiod_resources "$src_ctx" "$@"))
		for kv in "${rk[@]}"; do
			case "$kv" in
				req_cpu_m=*) req_cpu="${kv#req_cpu_m=}" ;;
				req_mem_mi=*) req_mem="${kv#req_mem_mi=}" ;;
				lim_cpu_m=*) lim_cpu="${kv#lim_cpu_m=}" ;;
				lim_mem_mi=*) lim_mem="${kv#lim_mem_mi=}" ;;
				replicas=*) reps="${kv#replicas=}" ;;
			esac
		done
	fi
	# Network topology across all contexts.
	local ctx networks_csv="" net
	for ctx in "${ctxs[@]}"; do
		net="$(env_network "$ctx" "$@")"; net="${net#network=}"
		[[ -z "$networks_csv" ]] && networks_csv="$net" || networks_csv="${networks_csv},${net}"
	done
	local n_networks topology
	n_networks="$(printf '%s' "$networks_csv" | tr ',' '\n' | grep -v '^unknown$' | sort -u | grep -c . || true)"
	if [[ "${n_networks:-0}" -gt 1 ]]; then topology="multi-network:${n_networks}"
	elif [[ "${n_networks:-0}" -eq 1 ]]; then topology="single-network"
	else topology="unknown"; fi
	printf 'NODE_ALLOC_CPU_M=%s NODE_ALLOC_MEM_MI=%s ISTIOD_REQ_CPU_M=%s ISTIOD_REQ_MEM_MI=%s ISTIOD_LIM_CPU_M=%s ISTIOD_LIM_MEM_MI=%s ISTIOD_REPLICAS=%s NETWORK_TOPOLOGY=%s\n' \
		"$node_cpu" "$node_mem" "$req_cpu" "$req_mem" "$lim_cpu" "$lim_mem" "$reps" "$topology"
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

	local json
	json="$("$report_script" --results-dir "$results_dir" --format json 2>/dev/null || true)"
	[[ -n "$json" ]] || die "render_scale_envelope: report produced no JSON for $results_dir"

	# Pull capacity provenance + achieved-scale maxes from the report metadata
	# (the report already applied the validity gate to these maxes — PL35).
	jq_get() { printf '%s' "$json" | jq -r "$1 // \"unknown\"" 2>/dev/null || printf 'unknown'; }

	local node_cpu_m node_mem_mi istio_version
	node_cpu_m="$(jq_get '.metadata.capacity.node_alloc_cpu_m')"
	node_mem_mi="$(jq_get '.metadata.capacity.node_alloc_mem_mi')"
	istio_version="$(jq_get '.metadata.istio_version')"

	local proxies_peak istiod_cpu_pct istiod_mem_pct node_cpu_pct node_mem_pct
	proxies_peak="$(jq_get '.metadata.achieved_scale.connected_proxies_max')"
	istiod_cpu_pct="$(jq_get '.metadata.achieved_scale.istiod_cpu_pct_of_limit_max')"
	istiod_mem_pct="$(jq_get '.metadata.achieved_scale.istiod_mem_pct_of_limit_max')"
	node_cpu_pct="$(jq_get '.metadata.achieved_scale.node_cpu_pct_max')"
	node_mem_pct="$(jq_get '.metadata.achieved_scale.node_mem_pct_max')"

	# Peak mesh-size point: the row with the largest mesh_size (the peak the
	# TEMPLATE.md envelope is supposed to characterize). PL35: gate on n_valid>0 so a
	# poisoned/restarted row (which still carries its CONFIGURED service_count, e.g.
	# 999) cannot become the "peak" and misreport the topology as achieved fact. Fall
	# back to all rows only if NO row is valid (so a fully-failed sweep still renders).
	local peak_json
	peak_json="$(printf '%s' "$json" | jq -c '
		(.results // []) as $all
		| ([ $all[] | select((.n_valid // 0) > 0) ]) as $valid
		| (if ($valid | length) > 0 then $valid else $all end)
		| if length == 0 then null else (max_by(.mesh_size)) end' 2>/dev/null || printf 'null')"
	local peak_mesh peak_svc peak_reps peak_ns peak_scope
	if [[ -n "$peak_json" && "$peak_json" != "null" ]]; then
		peak_mesh="$(printf '%s' "$peak_json" | jq -r '.mesh_size // "unknown"')"
		peak_svc="$(printf '%s' "$peak_json" | jq -r '.service_count // "unknown"')"
		peak_reps="$(printf '%s' "$peak_json" | jq -r '.replicas // "unknown"')"
		peak_ns="$(printf '%s' "$peak_json" | jq -r '.namespace_count // "unknown"')"
		peak_scope="$(printf '%s' "$peak_json" | jq -r '.sidecar_scoping // "unknown"')"
	else
		peak_mesh="unknown"; peak_svc="unknown"; peak_reps="unknown"; peak_ns="unknown"; peak_scope="unknown"
	fi

	# Live read-only snapshot: istiod resources (req/lim/replicas), network id,
	# node top, across every context. Networks collected to infer multi-network.
	local -a ctxs=()
	split_csv "$contexts_csv" ctxs
	local ctx kv
	local req_cpu="unknown" req_mem="unknown" lim_cpu="unknown" lim_mem="unknown" istiod_replicas="unknown"
	local networks_csv="" src_ctx="${ctxs[0]:-}"
	if [[ -n "$src_ctx" ]]; then
		# shellcheck disable=SC2207
		local -a rk=($(env_istiod_resources "$src_ctx" "${kubectl_argv[@]}"))
		for kv in "${rk[@]}"; do
			case "$kv" in
				req_cpu_m=*) req_cpu="${kv#req_cpu_m=}" ;;
				req_mem_mi=*) req_mem="${kv#req_mem_mi=}" ;;
				lim_cpu_m=*) lim_cpu="${kv#lim_cpu_m=}" ;;
				lim_mem_mi=*) lim_mem="${kv#lim_mem_mi=}" ;;
				replicas=*) istiod_replicas="${kv#replicas=}" ;;
			esac
		done
	fi
	for ctx in "${ctxs[@]}"; do
		local net
		net="$(env_network "$ctx" "${kubectl_argv[@]}")"
		net="${net#network=}"
		[[ -z "$networks_csv" ]] && networks_csv="$net" || networks_csv="${networks_csv},${net}"
	done
	# Distinct non-unknown networks > 1 -> multi-network.
	local n_networks topology
	n_networks="$(printf '%s' "$networks_csv" | tr ',' '\n' | grep -v '^unknown$' | sort -u | grep -c . || true)"
	if [[ "${n_networks:-0}" -gt 1 ]]; then
		topology="multi-network (${n_networks} networks)"
	elif [[ "${n_networks:-0}" -eq 1 ]]; then
		topology="single-network"
	else
		topology="unknown"
	fi

	# Total services / endpoints (derived; honest "unknown" if any factor unknown).
	local total_svc total_eps
	total_svc="$(awk -v n="$peak_mesh" -v s="$peak_svc" 'function num(x){return x~/^[0-9]+$/} BEGIN{ if(num(n)&&num(s)) print n*s; else print "unknown" }')"
	total_eps="$(awk -v n="$peak_mesh" -v s="$peak_svc" -v r="$peak_reps" 'function num(x){return x~/^[0-9]+$/} BEGIN{ if(num(n)&&num(s)&&num(r)) print n*s*r; else print "unknown" }')"

	# Verdict (over the report's validity-gated maxes; restarts/n_* from report).
	local restarts n_total n_valid
	restarts="$(printf '%s' "$json" | jq -r '[(.results // [])[].istiod_restarted_rows] | add // 0' 2>/dev/null || echo 0)"
	n_total="$(printf '%s' "$json" | jq -r '[(.results // [])[].n_total] | add // 0' 2>/dev/null || echo 0)"
	n_valid="$(printf '%s' "$json" | jq -r '[(.results // [])[].n_valid] | add // 0' 2>/dev/null || echo 0)"
	local verdict_raw verdict headline
	verdict_raw="$(env_sla_verdict "$istiod_cpu_pct" "$istiod_mem_pct" "$node_cpu_pct" "$node_mem_pct" "$restarts" "$n_total" "$n_valid")"
	verdict="${verdict_raw%%|*}"
	headline="${verdict_raw#*|}"

	# ---- render ----
	cat <<MD
## Scale envelope

> Auto-generated by \`tests/lib/envelope.sh:render_scale_envelope\` from \`$(basename "$results_dir")\`.
> Measured columns are the report's n_valid-gated peaks (restarted/SETUP_FAILED rows excluded).

### 1. Mesh topology — what the peak mesh-size point actually contains

| Dimension | Value | Source |
|---|---|---|
| Clusters (multi-primary) | ${peak_mesh} | sweep peak \`mesh_size\` |
| Services / cluster | ${peak_svc} | sweep peak \`service_count\` |
| Namespaces / cluster | ${peak_ns} | sweep peak \`namespace_count\` |
| Workload replicas / service | ${peak_reps} | sweep peak \`replicas\` |
| **Total services in mesh** | ${total_svc} | derived (N x S) |
| **Total endpoints in mesh** | ${total_eps} | derived (N x S x R) |
| **Connected proxies (measured peak)** | ${proxies_peak} | report achieved-scale \`connected_proxies_max\` (n_valid-gated) |
| Network topology | ${topology} | istiod \`ISTIO_META_NETWORK\` across contexts |
| Sidecar scoping | ${peak_scope} | sweep peak \`sidecar_scoping\` |
| Istio version | ${istio_version} | sweep header \`ISTIO_VERSION\` |

### 2. Control-plane provisioning & headroom — *was anything actually stressed?*

| Resource | Provisioned (req / lim) | Measured peak (% of cross-replica limit) | Source |
|---|---|---|---|
| istiod replicas | ${istiod_replicas} per cluster | — | live \`deploy/istiod\` |
| istiod CPU | ${req_cpu}m / ${lim_cpu}m | ${istiod_cpu_pct}% | report \`istiod_cpu_pct_of_limit_max\` |
| istiod memory | ${req_mem}Mi / ${lim_mem}Mi | ${istiod_mem_pct}% | report \`istiod_mem_pct_of_limit_max\` |
| Worker-node CPU | — | ${node_cpu_pct}% | report \`node_cpu_pct_max\` (\`kubectl top nodes\`) |
| Worker-node memory | — | ${node_mem_pct}% | report \`node_mem_pct_max\` (\`kubectl top nodes\`) |

> Node allocatable (source ctx): ${node_cpu_m}m CPU / ${node_mem_mi}Mi memory.
> istiod % is of the **cross-replica** limit (per-replica limit x ${istiod_replicas} replicas), so an idle R-replica plane does not read ~Rx100% (PL35).

### Scale verdict — one line, up front

> **${verdict}** — ${headline}
MD
}
