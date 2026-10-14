#!/usr/bin/env bash
# Read-only cluster probes for the controlplane namespace-scaling (growth) mode.
# Sourced, never executed.
#
# Consumers: controlplane (002 gateway + root-cert columns and the sampled sidecars'
# Envoy memory; 003 memory stop guard)
#
# Exposes:
#   growth_parse_envoy_stats            -> stdin: Envoy /stats text; prints
#                                          "mem_mi=<n|unknown> clusters=<n|unknown>"
#                                          (server.memory_allocated in MiB,
#                                          cluster_manager.active_clusters)
#   growth_envoy_stats <ctx> <ns> <pod> <kubectl_argv...>
#                                       -> the same for one pod's istio-proxy, read with
#                                          `pilot-agent request GET stats` (bounded by
#                                          CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S)
#   growth_parse_gateway_pods           -> stdin: `get pods -o json`; prints one
#                                          "<pod>\t<istio-proxy memory limit Mi|unknown>"
#                                          line per Running pod
#   growth_gateway_pods <ctx> <kubectl_argv...>
#                                       -> the same for the istio-system gateways
#                                          (istio=ingressgateway|eastwestgateway)
#   growth_gateway_summary <ctx> <kubectl_argv...>
#                                       -> "clusters_max=<n|N/A> mem_mi_max=<n|N/A>
#                                          pods=<n>" over the context's gateways
#   growth_root_cert_count <ctx> <kubectl_argv...>
#                                       -> istio-ca-root-cert ConfigMaps on the context
#                                          (one per namespace istiod serves), or N/A
#   growth_istiod_heap_mi <metrics_file> -> go_memstats_heap_inuse_bytes in MiB, or
#                                          unknown
#
# Every probe degrades to unknown/N/A on failure and never dies (PL40): a missing
# gateway or a failed exec must not abort a sweep.
# Requires: tests/lib/common.sh. All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# Gateway pods: the injected ingress and east-west gateways (PL38: they carry */*).
GROWTH_GATEWAY_SELECTOR='istio in (ingressgateway,eastwestgateway)'

# shellcheck disable=SC2329
growth_parse_envoy_stats() {
	awk '
	$1 == "server.memory_allocated:" { mem = $2 }
	$1 == "cluster_manager.active_clusters:" { cl = $2 }
	END {
		printf "mem_mi=%s clusters=%s\n", \
			(mem ~ /^[0-9]+$/ ? sprintf("%.0f", mem / 1048576) : "unknown"), \
			(cl ~ /^[0-9]+$/ ? cl : "unknown")
	}'
}

# shellcheck disable=SC2329
growth_envoy_stats() {
	local ctx="$1" ns="$2" pod="$3"
	shift 3
	local out
	out="$(timeout "${CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S:-30}s" "$@" --context="$ctx" -n "$ns" exec "$pod" -c istio-proxy -- \
		pilot-agent request GET 'stats?filter=memory_allocated|active_clusters' 2>/dev/null)" || out=""
	printf '%s\n' "$out" | growth_parse_envoy_stats
}

# shellcheck disable=SC2329
growth_parse_gateway_pods() {
	jq -r '
		def mem_to_mi($q):
			if $q == null then null
			else
				($q | tostring) as $s
				| if   ($s | test("Ki$")) then (($s | rtrimstr("Ki") | tonumber) / 1024)
				  elif ($s | test("Mi$")) then  ($s | rtrimstr("Mi") | tonumber)
				  elif ($s | test("Gi$")) then (($s | rtrimstr("Gi") | tonumber) * 1024)
				  elif ($s | test("M$"))  then (($s | rtrimstr("M") | tonumber) * 1000000 / 1048576)
				  elif ($s | test("G$"))  then (($s | rtrimstr("G") | tonumber) * 1000000000 / 1048576)
				  else (($s | tonumber) / 1048576) end
			end;
		.items[]?
		| select(.status.phase == "Running")
		| ([.spec.containers[]? | select(.name == "istio-proxy")] | first) as $c
		| (if $c == null then null else mem_to_mi($c.resources.limits.memory // null) end) as $lim
		| "\(.metadata.name)\t\(if $lim == null then "unknown" else ($lim | floor) end)"
	' 2>/dev/null || true
}

# shellcheck disable=SC2329
growth_gateway_pods() {
	local ctx="$1"
	shift
	"$@" --context="$ctx" --request-timeout=10s -n istio-system get pods -l "$GROWTH_GATEWAY_SELECTOR" -o json 2>/dev/null \
		| growth_parse_gateway_pods
}

# shellcheck disable=SC2329
growth_gateway_summary() {
	local ctx="$1"
	shift
	local pod kv mem cl mem_max="" cl_max="" n=0
	while IFS=$'\t' read -r pod _; do
		[[ -n "$pod" ]] || continue
		n=$((n + 1))
		kv="$(growth_envoy_stats "$ctx" istio-system "$pod" "$@")"
		mem="${kv#mem_mi=}"; mem="${mem%% *}"
		cl="${kv##*clusters=}"
		if [[ "$mem" =~ ^[0-9]+$ ]] && { [[ -z "$mem_max" ]] || (( mem > mem_max )); }; then mem_max="$mem"; fi
		if [[ "$cl" =~ ^[0-9]+$ ]] && { [[ -z "$cl_max" ]] || (( cl > cl_max )); }; then cl_max="$cl"; fi
	done < <(growth_gateway_pods "$ctx" "$@")
	printf 'clusters_max=%s mem_mi_max=%s pods=%d\n' "${cl_max:-N/A}" "${mem_max:-N/A}" "$n"
}

# shellcheck disable=SC2329
growth_root_cert_count() {
	local ctx="$1"
	shift
	local out
	# One list call; a field selector keeps it to the one ConfigMap name.
	out="$("$@" --context="$ctx" --request-timeout=30s get configmaps -A \
		--field-selector metadata.name=istio-ca-root-cert -o name 2>/dev/null)" || { echo "N/A"; return 0; }
	grep -c . <<<"$out" || true
}

# shellcheck disable=SC2329
growth_istiod_heap_mi() {
	local f="$1"
	[[ -s "$f" ]] || { echo unknown; return 0; }
	awk '
	/^go_memstats_heap_inuse_bytes[ {]/ { v = $NF }
	END { if (v == "") print "unknown"; else printf "%.0f\n", v / 1048576 }' "$f"
}
