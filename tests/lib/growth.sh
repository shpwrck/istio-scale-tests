#!/usr/bin/env bash
# Read-only cluster probes for the controlplane namespace-scaling (growth) mode.
# Sourced, never executed.
#
# Consumers: controlplane (002 gateway + root-cert columns and the sampled sidecars'
# Envoy memory; 003 memory stop guard)
#
# Exposes:
#   growth_parse_envoy_stats            -> stdin: Envoy /stats text; prints
#                                          "mem_mi=<n|unknown> clusters=<n|unknown>
#                                          physical_mi=<n|unknown>" (server.memory_allocated
#                                          and server.memory_physical_size in MiB,
#                                          cluster_manager.active_clusters). physical = the
#                                          tcmalloc heap incl. freed pages it kept (BACKLOG
#                                          9.5: after config bursts it runs well above
#                                          allocated)
#   growth_envoy_stats <ctx> <ns> <pod> <kubectl_argv...>
#                                       -> the same for one pod's istio-proxy, read with
#                                          `pilot-agent request GET stats` (bounded by
#                                          CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S)
#   growth_parse_gateway_pods           -> stdin: `get pods -o json`; prints one
#                                          "<pod>\t<istio-proxy memory limit Mi|unknown>\t<kind>"
#                                          line per Running pod (kind = the istio label:
#                                          eastwestgateway, ingressgateway)
#   growth_gateway_pods <ctx> <kubectl_argv...>
#                                       -> the same for the istio-system gateways
#                                          (istio=ingressgateway|eastwestgateway)
#   growth_parse_top_containers         -> stdin: `kubectl top pod --containers --no-headers`
#                                          (POD NAME CPU MEMORY); prints one
#                                          "<pod>\t<istio-proxy working set Mi>" line per pod
#   growth_gateway_ws <ctx> <kubectl_argv...>
#                                       -> the same for the istio-system gateways (the
#                                          container working set the OOM killer acts on;
#                                          nothing when the metrics API does not answer)
#   growth_gateway_summary <ctx> <kubectl_argv...>
#                                       -> "clusters_max=<n|N/A> mem_mi_max=<n|N/A>
#                                          physical_mi_max=<n|N/A> ws_mi_max=<n|N/A>
#                                          pods=<n>" over the context's gateways
#   growth_parse_remote_secrets         -> stdin: `get secrets -o json` of istio-system;
#                                          prints the cluster of every Istio remote secret
#                                          (networking.istio.io/cluster annotation, else
#                                          the istio-remote-secret-<cluster> name), sorted
#   growth_mesh_members <ctx> <kubectl_argv...>
#                                       -> <ctx> plus every cluster its remote secrets name
#                                          (one per line, sorted, unique); exit 1 when the
#                                          secrets cannot be listed
#   growth_test_ns_counts <ctx> <kubectl_argv...>
#                                       -> "total=<n|N/A> discovered=<n|N/A>": every
#                                          controlplane-test namespace on <ctx> (any series,
#                                          any run, Terminating included) and those still
#                                          carrying istio-discovery (BACKLOG 9.10: leftover
#                                          namespaces stay in istiod's informers)
#   growth_root_cert_count <ctx> <kubectl_argv...>
#                                       -> istio-ca-root-cert ConfigMaps on the context
#                                          (one per namespace istiod serves), or N/A
#   growth_istiod_heap_mi <metrics_file> -> go_memstats_heap_inuse_bytes in MiB, or
#                                          unknown
#   growth_discovered_ns <ctx> <selector> <kubectl_argv...>
#                                       -> namespaces matching <selector> that still carry
#                                          an istio-discovery or istio.io/rev label (names,
#                                          one per line); exit 1 when the list call fails
#   growth_retire_verified <kubectl_array> <contexts_csv> <selector> <attempts> <backoff_s>
#                          -- <cleanup command...>
#                                       -> runs the cleanup command, then checks that no
#                                          namespace of <selector> is still discovered on
#                                          any context; retries both up to <attempts> times
#                                          (backoff doubling from <backoff_s>). 0 = retired;
#                                          1 = not, with the leftover namespaces on stderr
#                                          (BACKLOG 9.3: a later series must not start on a
#                                          contaminated baseline)
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
	$1 == "server.memory_physical_size:" { phy = $2 }
	$1 == "cluster_manager.active_clusters:" { cl = $2 }
	END {
		printf "mem_mi=%s clusters=%s physical_mi=%s\n", \
			(mem ~ /^[0-9]+$/ ? sprintf("%.0f", mem / 1048576) : "unknown"), \
			(cl ~ /^[0-9]+$/ ? cl : "unknown"), \
			(phy ~ /^[0-9]+$/ ? sprintf("%.0f", phy / 1048576) : "unknown")
	}'
}

# shellcheck disable=SC2329
growth_envoy_stats() {
	local ctx="$1" ns="$2" pod="$3"
	shift 3
	local out
	out="$(timeout "${CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S:-30}s" "$@" --context="$ctx" -n "$ns" exec "$pod" -c istio-proxy -- \
		pilot-agent request GET 'stats?filter=memory_allocated|memory_physical_size|active_clusters' 2>/dev/null)" || out=""
	printf '%s\n' "$out" | growth_parse_envoy_stats
}

# shellcheck disable=SC2329
growth_parse_top_containers() {
	awk '
	function mem_to_mi(q) {
		if (q ~ /Ki$/) { sub(/Ki$/, "", q); return (q + 0) / 1024 }
		if (q ~ /Mi$/) { sub(/Mi$/, "", q); return q + 0 }
		if (q ~ /Gi$/) { sub(/Gi$/, "", q); return (q + 0) * 1024 }
		if (q ~ /^[0-9]+$/) return q / 1048576
		return -1
	}
	NF >= 4 && $2 == "istio-proxy" { v = mem_to_mi($4); if (v >= 0) printf "%s\t%.0f\n", $1, v }'
}

# shellcheck disable=SC2329
growth_gateway_ws() {
	local ctx="$1" i out=""
	shift
	for ((i = 1; i <= ${CAP_TOP_ATTEMPTS:-2}; i++)); do
		out="$("$@" --context="$ctx" --request-timeout="${CAP_TOP_TIMEOUT:-15}s" -n istio-system top pod \
			-l "$GROWTH_GATEWAY_SELECTOR" --containers --no-headers 2>/dev/null)" || out=""
		[[ -z "$out" ]] || break
		((i < ${CAP_TOP_ATTEMPTS:-2})) && sleep "${CAP_TOP_BACKOFF_S:-2}"
	done
	printf '%s\n' "$out" | growth_parse_top_containers
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
		| "\(.metadata.name)\t\(if $lim == null then "unknown" else ($lim | floor) end)\t\(.metadata.labels.istio // "unknown")"
	' 2>/dev/null || true
}

# shellcheck disable=SC2329
growth_gateway_pods() {
	local ctx="$1"
	shift
	"$@" --context="$ctx" --request-timeout=10s -n istio-system get pods -l "$GROWTH_GATEWAY_SELECTOR" -o json 2>/dev/null \
		| growth_parse_gateway_pods
}

# _growth_kv <key> <"k=v k=v" line>: the value of key, or unknown.
_growth_kv() {
	local tok
	for tok in $2; do
		[[ "$tok" == "${1}="* ]] && { echo "${tok#"${1}="}"; return 0; }
	done
	echo unknown
}

# shellcheck disable=SC2329
growth_gateway_summary() {
	local ctx="$1"
	shift
	local pod kv mem cl phy ws mem_max="" cl_max="" phy_max="" ws_max="" n=0
	while IFS=$'\t' read -r pod _; do
		[[ -n "$pod" ]] || continue
		n=$((n + 1))
		kv="$(growth_envoy_stats "$ctx" istio-system "$pod" "$@")"
		mem="$(_growth_kv mem_mi "$kv")"
		cl="$(_growth_kv clusters "$kv")"
		phy="$(_growth_kv physical_mi "$kv")"
		if [[ "$mem" =~ ^[0-9]+$ ]] && { [[ -z "$mem_max" ]] || (( mem > mem_max )); }; then mem_max="$mem"; fi
		if [[ "$cl" =~ ^[0-9]+$ ]] && { [[ -z "$cl_max" ]] || (( cl > cl_max )); }; then cl_max="$cl"; fi
		if [[ "$phy" =~ ^[0-9]+$ ]] && { [[ -z "$phy_max" ]] || (( phy > phy_max )); }; then phy_max="$phy"; fi
	done < <(growth_gateway_pods "$ctx" "$@")
	while IFS=$'\t' read -r pod ws; do
		if [[ "$ws" =~ ^[0-9]+$ ]] && { [[ -z "$ws_max" ]] || (( ws > ws_max )); }; then ws_max="$ws"; fi
	done < <(growth_gateway_ws "$ctx" "$@")
	printf 'clusters_max=%s mem_mi_max=%s physical_mi_max=%s ws_mi_max=%s pods=%d\n' \
		"${cl_max:-N/A}" "${mem_max:-N/A}" "${phy_max:-N/A}" "${ws_max:-N/A}" "$n"
}

# shellcheck disable=SC2329
growth_parse_remote_secrets() {
	jq -r '
		.items[]?
		| select((.metadata.labels // {})["istio/multiCluster"] == "true"
			or (.metadata.name // "" | startswith("istio-remote-secret-")))
		| (.metadata.annotations // {})["networking.istio.io/cluster"]
			// (.metadata.name | ltrimstr("istio-remote-secret-"))
		| select(. != "")
	' 2>/dev/null | sort -u
}

# shellcheck disable=SC2329
growth_mesh_members() {
	local ctx="$1" json
	shift
	json="$("$@" --context="$ctx" --request-timeout=30s -n istio-system get secrets -l istio/multiCluster=true -o json 2>/dev/null)" || return 1
	{ printf '%s\n' "$ctx"; printf '%s\n' "$json" | growth_parse_remote_secrets; } | grep -v '^$' | sort -u
}

# shellcheck disable=SC2329
growth_test_ns_counts() {
	local ctx="$1" json
	shift
	json="$("$@" --context="$ctx" --request-timeout=60s get namespaces -l app.kubernetes.io/instance=controlplane-test \
		-o json 2>/dev/null)" || { echo "total=N/A discovered=N/A"; return 0; }
	jq -r '"total=\([.items[]?] | length) discovered=\([.items[]? | select((.metadata.labels // {}) | has("istio-discovery"))] | length)"' \
		<<<"$json" 2>/dev/null || echo "total=N/A discovered=N/A"
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

# shellcheck disable=SC2329
growth_discovered_ns() {
	local ctx="$1" sel="$2" out all="" lbl
	shift 2
	for lbl in istio-discovery istio.io/rev; do
		out="$("$@" --context="$ctx" --request-timeout=30s get namespaces -l "${sel},${lbl}" -o name 2>/dev/null)" || return 1
		[[ -z "$out" ]] || all+="${out}"$'\n'
	done
	[[ -z "$all" ]] || printf '%s' "$all" | sort -u
}

# shellcheck disable=SC2329
growth_retire_verified() {
	local -n _grv_k="$1"
	local ctxs_csv="$2" sel="$3" attempts="$4" delay="$5" i ctx left bad
	shift 5
	[[ "${1:-}" == -- ]] && shift
	local -a ctxs=()
	split_csv "$ctxs_csv" ctxs
	for ((i = 1; i <= attempts; i++)); do
		bad=""
		if ! "$@"; then
			bad="the cleanup command failed"
		else
			for ctx in "${ctxs[@]}"; do
				if ! left="$(growth_discovered_ns "$ctx" "$sel" "${_grv_k[@]}")"; then
					bad="${bad:+${bad}; }${ctx}: namespaces not listable"
				elif [[ -n "$left" ]]; then
					bad="${bad:+${bad}; }${ctx}: $(grep -c . <<<"$left") namespace(s) still discovered, e.g. $(head -n 3 <<<"$left" | tr '\n' ' ')"
				fi
			done
		fi
		[[ -n "$bad" ]] || return 0
		echo "warn: series retire attempt ${i}/${attempts}: ${bad}" >&2
		((i < attempts)) || break
		sleep "$delay"
		delay=$((delay * 2))
	done
	echo "error: series retire failed after ${attempts} attempt(s): ${bad}" >&2
	return 1
}
