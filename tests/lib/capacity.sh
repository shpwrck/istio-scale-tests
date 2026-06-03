#!/usr/bin/env bash
# Read-only cluster-capacity probes for scale-coverage legibility (O9).
# Sourced, never executed.
#
# Consumers: controlplane (Phase 1 legibility + Phase-2 auto-sizing)
#
# This library is STRICTLY READ-ONLY: every kubectl call is a `get`/`top`/
# `version`, never apply/scale/delete/patch. All reads carry
# `--request-timeout=5s` and tolerate failure by emitting `unknown` (modelled on
# preamble.sh:kube_versions), so a missing metrics-server or an unreachable node
# API degrades to a legible `unknown` rather than aborting the caller.
#
# Two layers:
#   PURE PARSERS — stdin -> stdout, no kubectl, unit-testable with fixtures.
#   THIN WRAPPERS — compose `<kubectl read> | <parser>`; on kubectl failure emit
#                   the parser's all-unknown line.
#
# Exposes (pure parsers):
#   cap_parse_node_totals                          -> cpu_m mem_mi pods nodes names (worker nodes only)
#   cap_parse_top_nodes <worker_names_csv>          -> cpu_m mem_mi (sum of named worker rows)
#   cap_parse_pod_count <worker_names_csv>          -> scheduled (pods on worker nodes, Running/Pending)
#   cap_parse_istiod_limits                        -> cpu_m mem_mi replicas (live istiod deploy limits/requests)
#   cap_parse_istiod_used                          -> cpu_m mem_mi (sum of istiod pod top)
#   cap_pct <used> <total>                          -> integer percent or `unknown`
#
# Exposes (Phase-2 sizing helper — pure, not a stdin parser):
#   cap_max_pods <...>                             -> capacity-derived pod ceiling; `unknown`-propagating
#
# Exposes (thin kubectl wrappers — each takes <ctx> <kubectl_argv...>):
#   cap_node_totals  <ctx> <argv...>
#   cap_node_used    <ctx> <worker_names_csv> <argv...>
#   cap_pod_count    <ctx> <worker_names_csv> <argv...>
#   cap_istiod_limits <ctx> <argv...>
#   cap_istiod_used  <ctx> <argv...>
#
# Requires: tests/lib/common.sh (for die(), split_csv()), jq, awk.
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Quantity helpers (pure awk; emit `unknown` on unparseable input).
# ---------------------------------------------------------------------------
# Kubernetes CPU quantity -> millicores: `8`->8000, `7900m`->7900, `0.5`->500.
# Kubernetes memory quantity -> Mi (floor): Ki/Mi/Gi/Ti suffix or plain bytes.

# ---------------------------------------------------------------------------
# cap_parse_node_totals: `kubectl get nodes -o json` on stdin.
# Sums allocatable cpu/memory/pods across WORKER nodes only (excludes any node
# labelled control-plane / master / infra). Emits:
#   cpu_m=<int> mem_mi=<int> pods=<int> nodes=<int> names=<csv>
# Zero workers or unparseable -> cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names=
# shellcheck disable=SC2329
cap_parse_node_totals() {
	jq -r '
		def cpu_to_m($q):
			if ($q | type) != "string" then ($q | tostring) else $q end
			| if test("m$") then (rtrimstr("m") | tonumber)
			  else (tonumber * 1000)
			  end;
		def mem_to_mi($q):
			($q | tostring) as $s
			| if   ($s | test("Ki$")) then (($s | rtrimstr("Ki") | tonumber) / 1024)
			  elif ($s | test("Mi$")) then  ($s | rtrimstr("Mi") | tonumber)
			  elif ($s | test("Gi$")) then (($s | rtrimstr("Gi") | tonumber) * 1024)
			  elif ($s | test("Ti$")) then (($s | rtrimstr("Ti") | tonumber) * 1024 * 1024)
			  else (($s | tonumber) / 1048576)
			  end;
		def is_worker:
			(.metadata.labels // {}) as $l
			| ($l | has("node-role.kubernetes.io/control-plane")) as $cp
			| ($l | has("node-role.kubernetes.io/master")) as $mas
			| ($l | has("node-role.kubernetes.io/infra")) as $inf
			| ($cp or $mas or $inf) | not;
		[ .items[]? | select(is_worker) ] as $w
		| ($w | length) as $n
		| if $n == 0 then
			"cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names="
		  else
			($w | map(cpu_to_m(.status.allocatable.cpu)) | add // 0 | floor) as $cpu
			| ($w | map(mem_to_mi(.status.allocatable.memory)) | add // 0 | floor) as $mem
			| ($w | map((.status.allocatable.pods // "0") | tonumber) | add // 0 | floor) as $pods
			| ($w | map(.metadata.name) | join(",")) as $names
			| "cpu_m=\($cpu) mem_mi=\($mem) pods=\($pods) nodes=\($n) names=\($names)"
		  end
	' 2>/dev/null || printf '%s\n' "cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names="
}

# cap_parse_top_nodes <worker_names_csv>: `kubectl top nodes --no-headers` on
# stdin (cols: NAME CPU(cores) CPU% MEM(bytes) MEM%). Sums CPU+MEM only for rows
# whose NAME is in worker_names_csv. CPU `1234m`/`1`->millicores; MEM `1234Mi`/
# `5Gi`->Mi. Empty stdin (metrics-server absent) -> cpu_m=unknown mem_mi=unknown.
# shellcheck disable=SC2329
cap_parse_top_nodes() {
	local worker_csv="${1:-}"
	awk -v workers="$worker_csv" '
	function cpu_to_m(q,   v) {
		if (q ~ /m$/) { sub(/m$/, "", q); return q + 0 }
		return (q + 0) * 1000
	}
	function mem_to_mi(q,   v) {
		if (q ~ /Ki$/) { sub(/Ki$/, "", q); return (q + 0) / 1024 }
		if (q ~ /Mi$/) { sub(/Mi$/, "", q); return (q + 0) }
		if (q ~ /Gi$/) { sub(/Gi$/, "", q); return (q + 0) * 1024 }
		if (q ~ /Ti$/) { sub(/Ti$/, "", q); return (q + 0) * 1024 * 1024 }
		# kubectl top emits Mi for node memory; treat a bare number as Mi.
		return (q + 0)
	}
	BEGIN {
		n = split(workers, parts, ",")
		for (i = 1; i <= n; i++) {
			name = parts[i]
			gsub(/^[ \t]+|[ \t]+$/, "", name)
			if (name != "") want[name] = 1
		}
		rows = 0
	}
	/^[ \t]*$/ { next }
	{
		if (!(($1) in want)) next
		cpu_m += cpu_to_m($2)
		mem_mi += mem_to_mi($4)
		rows++
	}
	END {
		if (rows == 0) { print "cpu_m=unknown mem_mi=unknown"; exit }
		printf "cpu_m=%d mem_mi=%d\n", cpu_m, mem_mi
	}'
}

# cap_parse_pod_count <worker_names_csv>: `kubectl get pods -A -o json` on stdin.
# Counts pods scheduled onto worker nodes (.spec.nodeName in worker set) whose
# phase is Running or Pending. Emits scheduled=<int>; unparseable -> scheduled=unknown.
# shellcheck disable=SC2329
cap_parse_pod_count() {
	local worker_csv="${1:-}"
	jq -r --arg workers "$worker_csv" '
		($workers | split(",") | map(select(length > 0))) as $w
		| ($w | reduce .[] as $n ({}; .[$n] = true)) as $set
		| [ .items[]?
		    | select((.spec.nodeName // "") | in($set))
		    | select((.status.phase // "") == "Running" or (.status.phase // "") == "Pending")
		  ] | length
		| "scheduled=\(.)"
	' 2>/dev/null || printf '%s\n' "scheduled=unknown"
}

# cap_parse_istiod_limits: `kubectl get deploy istiod -n istio-system -o json` on
# stdin. Reads the istiod/discovery container .resources.limits (falls back to
# .requests if no limits) cpu->m, mem->Mi; replicas from .spec.replicas. Emits:
#   cpu_m=<int|unknown> mem_mi=<int|unknown> replicas=<int|unknown>
# Reads the LIVE deployment (the istiod resource pin is CR-patched live).
# shellcheck disable=SC2329
cap_parse_istiod_limits() {
	jq -r '
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
		( [ .spec.template.spec.containers[]?
		    | select(.name == "discovery" or .name == "istiod") ] | first ) as $c
		| if $c == null then
			"cpu_m=unknown mem_mi=unknown replicas=unknown"
		  else
			(($c.resources.limits // {}) ) as $lim
			| (($c.resources.requests // {})) as $req
			| (if ($lim.cpu // null) != null then $lim.cpu else $req.cpu end) as $cpu_q
			| (if ($lim.memory // null) != null then $lim.memory else $req.memory end) as $mem_q
			| (cpu_to_m($cpu_q)) as $cpu
			| (mem_to_mi($mem_q)) as $mem
			| (.spec.replicas) as $rep
			| "cpu_m=\(if $cpu == null then "unknown" else ($cpu | floor) end) " +
			  "mem_mi=\(if $mem == null then "unknown" else ($mem | floor) end) " +
			  "replicas=\(if $rep == null then "unknown" else $rep end)"
		  end
	' 2>/dev/null || printf '%s\n' "cpu_m=unknown mem_mi=unknown replicas=unknown"
}

# cap_parse_istiod_used: `kubectl top pod -n istio-system -l app=istiod
# --no-headers` on stdin (cols: NAME CPU(cores) MEM(bytes)). Sums CPU+MEM across
# istiod pods. CPU `1234m`/`1`->m; MEM `1234Mi`/`5Gi`->Mi. Empty -> unknown.
# shellcheck disable=SC2329
cap_parse_istiod_used() {
	awk '
	function cpu_to_m(q) {
		if (q ~ /m$/) { sub(/m$/, "", q); return q + 0 }
		return (q + 0) * 1000
	}
	function mem_to_mi(q) {
		if (q ~ /Ki$/) { sub(/Ki$/, "", q); return (q + 0) / 1024 }
		if (q ~ /Mi$/) { sub(/Mi$/, "", q); return (q + 0) }
		if (q ~ /Gi$/) { sub(/Gi$/, "", q); return (q + 0) * 1024 }
		if (q ~ /Ti$/) { sub(/Ti$/, "", q); return (q + 0) * 1024 * 1024 }
		return (q + 0)
	}
	/^[ \t]*$/ { next }
	NF >= 3 { cpu_m += cpu_to_m($2); mem_mi += mem_to_mi($3); rows++ }
	END {
		if (rows == 0) { print "cpu_m=unknown mem_mi=unknown"; exit }
		printf "cpu_m=%d mem_mi=%d\n", cpu_m, mem_mi
	}'
}

# cap_pct <used> <total>: integer percent round(100*used/total), or `unknown` if
# either arg is unknown / non-numeric or total <= 0. Pure.
# shellcheck disable=SC2329
cap_pct() {
	local used="${1:-}" total="${2:-}"
	awk -v u="$used" -v t="$total" '
	function isnum(x) { return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
		if (!isnum(u) || !isnum(t) || (t + 0) <= 0) { print "unknown"; exit }
		printf "%d\n", int((100 * u / t) + 0.5)
	}'
}

# ---------------------------------------------------------------------------
# Phase 2 (sizing) — pure; only CALLED behind SCALE_SIZING_MODE=auto.
# ---------------------------------------------------------------------------
# cap_max_pods <alloc_cpu_m> <alloc_mem_mi> <alloc_pods> \
#              <istiod_cpu_m> <istiod_mem_mi> <istiod_replicas> \
#              <per_pod_cpu_m> <per_pod_mem_mi> \
#              <target_fraction> <system_reserve_fraction>
#
# Derives how many workload pods a worker fleet can host at the configured
# target utilization. Assumptions (calibrated against a real cluster later):
#   - istiod consumes its full per-replica limit on every replica (worst case).
#   - SCALE_SYSTEM_RESERVE_FRACTION is held back for kube-system / daemonsets /
#     gateways and other non-workload overhead.
#   - SCALE_TARGET_FRACTION is the headroom we deliberately leave unused (the
#     explicit O9<->O8 throttle).
#   - per_pod_cpu_m / per_pod_mem_mi are the cost of ONE workload pod
#     (app container + injected sidecar); a documented conservative constant
#     until calibrated.
#
#   target_cpu = (alloc_cpu_m - istiod_cpu_m*istiod_replicas) * (1-reserve) * fraction
#   target_mem = (alloc_mem_mi - istiod_mem_mi*istiod_replicas) * (1-reserve) * fraction
#   max_pods   = floor(min(target_cpu/per_pod_cpu, target_mem/per_pod_mem,
#                          alloc_pods*fraction))
#
# Emits <int> (>=1) or `unknown` if ANY input is unknown / non-numeric.
# shellcheck disable=SC2329
cap_max_pods() {
	awk -v acpu="${1:-}" -v amem="${2:-}" -v apods="${3:-}" \
	    -v icpu="${4:-}" -v imem="${5:-}" -v irep="${6:-}" \
	    -v pcpu="${7:-}" -v pmem="${8:-}" \
	    -v frac="${9:-}" -v reserve="${10:-}" '
	function isnum(x) { return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
		if (!isnum(acpu) || !isnum(amem) || !isnum(apods) ||
		    !isnum(icpu) || !isnum(imem) || !isnum(irep) ||
		    !isnum(pcpu) || !isnum(pmem) ||
		    !isnum(frac) || !isnum(reserve)) { print "unknown"; exit }
		if ((pcpu + 0) <= 0 || (pmem + 0) <= 0) { print "unknown"; exit }
		avail = (1 - reserve) * frac
		target_cpu = (acpu - icpu * irep) * avail
		target_mem = (amem - imem * irep) * avail
		by_cpu  = target_cpu / pcpu
		by_mem  = target_mem / pmem
		by_pods = apods * frac
		m = by_cpu
		if (by_mem  < m) m = by_mem
		if (by_pods < m) m = by_pods
		m = int(m)
		if (m < 1) m = 1
		print m
	}'
}

# ---------------------------------------------------------------------------
# Thin kubectl wrappers (read-only). Each composes a kubectl read | a parser;
# on kubectl failure the parser still emits its all-unknown line (the read is
# the first stage of the pipe and an empty body parses to unknown).
# ---------------------------------------------------------------------------

# cap_node_totals <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
cap_node_totals() {
	local ctx="$1"; shift
	"$@" --context="$ctx" --request-timeout=5s get nodes -o json 2>/dev/null \
		| cap_parse_node_totals
}

# cap_node_used <ctx> <worker_names_csv> <kubectl_argv...>
# shellcheck disable=SC2329
cap_node_used() {
	local ctx="$1" workers="$2"; shift 2
	"$@" --context="$ctx" --request-timeout=5s top nodes --no-headers 2>/dev/null \
		| cap_parse_top_nodes "$workers"
}

# cap_pod_count <ctx> <worker_names_csv> <kubectl_argv...>
# shellcheck disable=SC2329
cap_pod_count() {
	local ctx="$1" workers="$2"; shift 2
	"$@" --context="$ctx" --request-timeout=5s get pods -A -o json 2>/dev/null \
		| cap_parse_pod_count "$workers"
}

# cap_istiod_limits <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
cap_istiod_limits() {
	local ctx="$1"; shift
	"$@" --context="$ctx" --request-timeout=5s -n istio-system get deploy istiod -o json 2>/dev/null \
		| cap_parse_istiod_limits
}

# cap_istiod_used <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
cap_istiod_used() {
	local ctx="$1"; shift
	"$@" --context="$ctx" --request-timeout=5s -n istio-system top pod -l app=istiod --no-headers 2>/dev/null \
		| cap_parse_istiod_used
}
