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
#                                                     sidecars (Running, not terminating, injected:
#                                                     sidecar.istio.io/status annotation; any node)
#   cap_parse_requested <worker_names_csv> [label=value]
#                                                  -> cpu_m mem_mi pods (requests already scheduled on
#                                                     worker nodes; pods with the label skipped)
#   cap_parse_istiod_limits                        -> cpu_m mem_mi replicas (live istiod deploy limits/requests)
#   cap_parse_istiod_used                          -> cpu_m mem_mi (sum of istiod pod top)
#   cap_pct <used> <total>                          -> integer percent or `unknown`
#   cap_proxy_check <connected> <expected> <tol_pct> [min_diff]
#                                                  -> OK | LOW | HIGH | N/A (connected proxies vs
#                                                     expected sidecar pods; pure, not a stdin parser)
#   cap_parse_proxy_requests                       -> cpu_m mem_mi source (`get istios.sailoperator.io
#                                                     -o json`: the first Istio CR's
#                                                     spec.values.global.proxy.resources.requests;
#                                                     source=istio-cr, or istio-default (100m / 128Mi,
#                                                     Istio's injection defaults) when the CR sets none;
#                                                     unknown + source=unreadable without a CR)
#
# Exposes (Phase-2 sizing helper — pure, not a stdin parser):
#   cap_max_pods <...>                             -> capacity-derived pod ceiling; `unknown`-propagating
#
# Exposes (thin kubectl wrappers — each takes <ctx> <kubectl_argv...>):
#   cap_node_totals  <ctx> <argv...>
#   cap_node_used    <ctx> <worker_names_csv> <argv...>
#   cap_pod_count    <ctx> <worker_names_csv> <argv...>
#   cap_requested    <ctx> <worker_names_csv> <exclude_label|""> <argv...>
#   cap_istiod_limits <ctx> <argv...>
#   cap_istiod_used  <ctx> <argv...>
#   cap_metrics_ready <ctx> <argv...>   -> ready | unavailable (kubectl top probe)
#   cap_proxy_requests <ctx> <argv...>  -> the sidecar requests every injected pod
#                                           schedules with (BACKLOG 9.7: the capacity plan
#                                           and auto-sizing use them instead of a constant)
#   cap_per_pod_requests <ctx> <cpu_m> <mem_mi> <argv...>
#                                        -> per-pod CPU/memory: explicit value, else live
#                                           Istio CR, else Istio's defaults, with the source
#
# The three `kubectl top` reads (cap_node_used, cap_istiod_used, cap_metrics_ready)
# use a longer request timeout (CAP_TOP_TIMEOUT, default 15s) than the etcd `get`
# reads (5s): the aggregated metrics API is slower and, under the sweep's concurrent
# multi-context load, a 5s `top` exceeded the timeout while `get` stayed under it —
# the root cause of #44's all-N/A run (metrics-server itself was healthy throughout).
# cap_node_used / cap_istiod_used additionally retry a brief empty result
# CAP_TOP_ATTEMPTS times (CAP_TOP_BACKOFF_S apart) before degrading to `unknown`.
#
# Requires: tests/lib/common.sh (for die(), split_csv()), jq, awk.
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Quantity helpers, shared by every parser below (one definition per language so a
# limit written as `8G` or `512M` parses the same everywhere).
# ---------------------------------------------------------------------------
# Kubernetes CPU quantity -> millicores: `8`->8000, `7900m`->7900, `0.5`->500,
# `250000u`->250, `2500000n`->2.5.
# Kubernetes memory quantity -> Mi: binary Ki/Mi/Gi/Ti/Pi, decimal k/M/G/T/P, or plain
# bytes (`8G` = 8e9 bytes = 7629.4 Mi). Callers floor.
# shellcheck disable=SC2016
CAP_JQ_QTY='
def cpu_to_m($q):
	if $q == null then null
	else (if ($q | type) != "string" then ($q | tostring) else $q end)
		| if test("m$") then (rtrimstr("m") | tonumber)
		  elif test("u$") then ((rtrimstr("u") | tonumber) / 1000)
		  elif test("n$") then ((rtrimstr("n") | tonumber) / 1000000)
		  else (tonumber * 1000) end
	end;
def mem_to_mi($q):
	if $q == null then null
	else ($q | tostring) as $s
		| ({"Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776, "Pi": 1125899906842624,
		    "k": 1000, "M": 1000000, "G": 1000000000, "T": 1000000000000, "P": 1000000000000000}) as $u
		| ($s | capture("^(?<v>[0-9.eE+-]+)(?<s>[A-Za-z]*)$")) as $p
		| if $p.s == "" then ($p.v | tonumber) / 1048576
		  elif ($u | has($p.s)) then ($p.v | tonumber) * $u[$p.s] / 1048576
		  else error("unknown memory suffix \($p.s)") end
	end;
'
# CAP_AWK_QTY: the same two in awk (-1 = unparseable). A bare memory number is bytes,
# except where a caller documents otherwise (kubectl top prints Mi with a suffix).
# shellcheck disable=SC2016
CAP_AWK_QTY='
function cpu_to_m(q) {
	if (q ~ /m$/) { sub(/m$/, "", q); return q + 0 }
	if (q ~ /u$/) { sub(/u$/, "", q); return (q + 0) / 1000 }
	if (q ~ /n$/) { sub(/n$/, "", q); return (q + 0) / 1000000 }
	if (q ~ /^[0-9.]+$/) return (q + 0) * 1000
	return -1
}
function mem_to_mi(q,    v, s) {
	if (!match(q, /^[0-9.]+/)) return -1
	v = substr(q, 1, RLENGTH) + 0; s = substr(q, RLENGTH + 1)
	if (s == "") return v / 1048576
	if (s == "Ki") return v / 1024
	if (s == "Mi") return v
	if (s == "Gi") return v * 1024
	if (s == "Ti") return v * 1048576
	if (s == "k") return v * 1000 / 1048576
	if (s == "M") return v * 1000000 / 1048576
	if (s == "G") return v * 1000000000 / 1048576
	if (s == "T") return v * 1000000000000 / 1048576
	return -1
}
'

# ---------------------------------------------------------------------------
# cap_parse_node_totals: `kubectl get nodes -o json` on stdin.
# Sums allocatable cpu/memory/pods across WORKER nodes only. A worker is a node
# labelled node-role.kubernetes.io/worker that is not infra (so single-node and
# compact clusters, whose nodes carry control-plane + master + worker, count), or a
# node with no control-plane / master / infra label at all. Emits:
#   cpu_m=<int> mem_mi=<int> pods=<int> nodes=<int> names=<csv>
# Zero workers or unparseable -> cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names=
# shellcheck disable=SC2329
cap_parse_node_totals() {
	jq -r "${CAP_JQ_QTY}"'
		def is_worker:
			(.metadata.labels // {}) as $l
			| ($l | has("node-role.kubernetes.io/control-plane")) as $cp
			| ($l | has("node-role.kubernetes.io/master")) as $mas
			| ($l | has("node-role.kubernetes.io/infra")) as $inf
			| ($l | has("node-role.kubernetes.io/worker")) as $wrk
			| ($wrk and ($inf | not)) or (($cp or $mas or $inf) | not);
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
	awk -v workers="$worker_csv" "${CAP_AWK_QTY}"'
	# kubectl top prints Mi with a suffix; a bare number is read as Mi here.
	function top_mi(q) { return (q ~ /^[0-9.]+$/) ? q + 0 : mem_to_mi(q) }
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
		c = cpu_to_m($2); m = top_mi($4)
		if (c < 0 || m < 0) next
		cpu_m += c
		mem_mi += m
		rows++
	}
	END {
		if (rows == 0) { print "cpu_m=unknown mem_mi=unknown"; exit }
		printf "cpu_m=%d mem_mi=%d\n", cpu_m, mem_mi
	}'
}

# cap_parse_pod_count <worker_names_csv>: `kubectl get pods -A -o json` on stdin.
# One jq pass emits two counts:
#   scheduled  pods on worker nodes (.spec.nodeName in the worker set) whose phase is
#              Running or Pending. An empty worker list -> scheduled=unknown (nothing
#              to count against; not a real zero).
#   sidecars   pods on ANY node that are Running, have no deletionTimestamp, and carry
#              the sidecar.istio.io/status annotation (set by injection). This is the
#              expected connected-proxy count: injected gateways carry the annotation
#              too, and each injected proxy holds one istiod connection (pilot_xds).
# Emits `scheduled=<int|unknown> sidecars=<int|unknown>`; unparseable or empty input
# -> both unknown.
# shellcheck disable=SC2329
cap_parse_pod_count() {
	local worker_csv="${1:-}" out
	out="$(jq -r --arg workers "$worker_csv" '
		($workers | split(",") | map(select(length > 0))) as $w
		| ($w | reduce .[] as $n ({}; .[$n] = true)) as $set
		| [ .items[]? ] as $pods
		| (if ($w | length) == 0 then "unknown"
		   else ([ $pods[]
		           | select((.spec.nodeName // "") | in($set))
		           | select((.status.phase // "") == "Running" or (.status.phase // "") == "Pending")
		         ] | length)
		   end) as $sched
		| ([ $pods[]
		     | select((.status.phase // "") == "Running")
		     | select(.metadata.deletionTimestamp == null)
		     | select((.metadata.annotations // {}) | has("sidecar.istio.io/status"))
		   ] | length) as $sidecars
		| "scheduled=\($sched) sidecars=\($sidecars)"
	' 2>/dev/null)" || out=""
	[[ -n "$out" ]] || out="scheduled=unknown sidecars=unknown"
	printf '%s\n' "$out"
}

# cap_parse_requested <worker_names_csv> [exclude_label=value]: `kubectl get pods -A
# -o json` on stdin. Sums the CPU and memory requests the scheduler has already handed
# out on the worker nodes: pods whose .spec.nodeName is a worker, not Succeeded/Failed.
# A pod's request follows the scheduler's rule: app containers plus restartable
# (native sidecar) init containers, or the largest init-phase request if that is
# higher, plus .spec.overhead. Pods carrying the exclude label are skipped (the test's
# own pods, when the caller counts them separately). Emits
#   cpu_m=<int|unknown> mem_mi=<int|unknown> pods=<int|unknown>
# An empty worker list or unparseable input -> all unknown.
# shellcheck disable=SC2329
cap_parse_requested() {
	local worker_csv="${1:-}" exclude="${2:-}" out
	out="$(jq -r --arg workers "$worker_csv" --arg ex "$exclude" "${CAP_JQ_QTY}"'
		def req($f): (if $f == "cpu" then cpu_to_m(.resources.requests.cpu // null)
		              else mem_to_mi(.resources.requests.memory // null) end) // 0;
		def pod_req($f):
			(reduce (.spec.initContainers // [])[] as $c ({side: 0, init: 0};
				($c | req($f)) as $r
				| if ($c.restartPolicy // "") == "Always"
				  then .side += $r | .init = ([.init, .side] | max)
				  else .init = ([.init, .side + $r] | max) end)) as $i
			| ([ (.spec.containers // [])[] | req($f) ] | add // 0) as $main
			| ([$main + $i.side, $i.init] | max)
			  + ((if $f == "cpu" then cpu_to_m(.spec.overhead.cpu // null)
			      else mem_to_mi(.spec.overhead.memory // null) end) // 0);
		($workers | split(",") | map(select(length > 0))) as $w
		| ($w | reduce .[] as $n ({}; .[$n] = true)) as $set
		| ($ex | split("=")) as $kv
		| ($kv[0] // "") as $ek
		| ($kv[1:] | join("=")) as $ev
		| if ($w | length) == 0 then "cpu_m=unknown mem_mi=unknown pods=unknown"
		  else
			[ .items[]?
			  | select((.spec.nodeName // "") | in($set))
			  | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")
			  | select($ex == "" or ((.metadata.labels // {})[$ek] // "") != $ev)
			] as $p
			| "cpu_m=\([ $p[] | pod_req("cpu") ] | add // 0 | floor) mem_mi=\([ $p[] | pod_req("mem") ] | add // 0 | floor) pods=\($p | length)"
		  end
	' 2>/dev/null)" || out=""
	[[ -n "$out" ]] || out="cpu_m=unknown mem_mi=unknown pods=unknown"
	printf '%s\n' "$out"
}

# cap_parse_istiod_limits: `kubectl get deploy istiod -n istio-system -o json` on
# stdin. Reads the istiod/discovery container .resources.limits (falls back to
# .requests if no limits) cpu->m, mem->Mi; replicas from .spec.replicas. Emits:
#   cpu_m=<int|unknown> mem_mi=<int|unknown> replicas=<int|unknown>
# Reads the LIVE deployment (the istiod resource pin is CR-patched live).
# shellcheck disable=SC2329
cap_parse_istiod_limits() {
	jq -r "${CAP_JQ_QTY}"'
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
	awk "${CAP_AWK_QTY}"'
	# kubectl top prints Mi with a suffix; a bare number is read as Mi here.
	function top_mi(q) { return (q ~ /^[0-9.]+$/) ? q + 0 : mem_to_mi(q) }
	/^[ \t]*$/ { next }
	NF >= 3 { c = cpu_to_m($2); m = top_mi($3); if (c >= 0 && m >= 0) { cpu_m += c; mem_mi += m; rows++ } }
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

# cap_proxy_check <connected> <expected> <tol_pct> [min_diff]: compare a cluster's
# connected proxies (pilot_xds summed over its istiod pods) with the proxies it should
# have (Running injected pods). Flags only when |connected - expected| is strictly
# greater than max(tol_pct% of expected, min_diff); min_diff (default 0) keeps small
# clusters from flagging a one-proxy gap. Emits OK, LOW (fewer connected than
# expected), HIGH (more), or N/A when any input is non-numeric. Pure.
# shellcheck disable=SC2329
cap_proxy_check() {
	awk -v c="${1:-}" -v e="${2:-}" -v t="${3:-}" -v m="${4:-0}" '
	function isnum(x) { return x ~ /^([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
		if (!isnum(c) || !isnum(e) || !isnum(t) || !isnum(m)) { print "N/A"; exit }
		d = c - e
		ad = (d < 0) ? -d : d
		thr = t * e / 100
		if (m + 0 > thr) thr = m + 0
		if (ad > thr) print (d < 0) ? "LOW" : "HIGH"
		else print "OK"
	}'
}

# cap_parse_proxy_requests: `kubectl get istios.sailoperator.io -o json` on stdin.
# The test charts' app containers request nothing, so a test pod schedules with its
# sidecar's requests: the Istio CR's global proxy requests, else Istio's injection
# defaults (100m CPU, 128Mi memory). Emits
#   cpu_m=<int|unknown> mem_mi=<int|unknown> source=istio-cr|istio-default|unreadable
# (istio-cr when the CR sets either request; the other then takes the default).
# shellcheck disable=SC2329
cap_parse_proxy_requests() {
	local out
	out="$(jq -r "${CAP_JQ_QTY}"'
		[.items[]?] | sort_by(.metadata.name) | first as $i
		| if $i == null then "cpu_m=unknown mem_mi=unknown source=unreadable"
		  else ($i.spec.values.global.proxy.resources.requests // {}) as $r
			| "cpu_m=\((if $r.cpu == null then 100 else cpu_to_m($r.cpu) end) | floor) mem_mi=\((if $r.memory == null then 128 else mem_to_mi($r.memory) end) | floor) source=\(if ($r.cpu == null and $r.memory == null) then "istio-default" else "istio-cr" end)"
		  end
	' 2>/dev/null)" || out=""
	[[ -n "$out" ]] || out="cpu_m=unknown mem_mi=unknown source=unreadable"
	printf '%s\n' "$out"
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
# the first stage of the pipe and an empty body parses to unknown) and the wrapper
# returns 0, so `arr=($(cap_...))` under `set -e -o pipefail` does not end the caller.
# ---------------------------------------------------------------------------

# cap_node_totals <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
cap_node_totals() {
	local ctx="$1"; shift
	{ "$@" --context="$ctx" --request-timeout=5s get nodes -o json 2>/dev/null || true; } \
		| cap_parse_node_totals
}

# _cap_retry_nonempty <cmd...>: run cmd up to CAP_TOP_ATTEMPTS times (CAP_TOP_BACKOFF_S
# apart) until its stdout is non-empty, then echo that stdout. Rides through a BRIEF
# metrics-API blip so a single bad moment doesn't N/A a combo. On persistent
# failure it echoes the last (empty) output so the downstream parser still yields
# `unknown` — never fails the pipeline. Used only for the `kubectl top` reads, which
# run OUTSIDE the scrape measurement window, so the retry latency is measurement-neutral.
# shellcheck disable=SC2329
_cap_retry_nonempty() {
	local attempts="${CAP_TOP_ATTEMPTS:-2}" backoff="${CAP_TOP_BACKOFF_S:-2}" i out=""
	for (( i = 1; i <= attempts; i++ )); do
		out="$("$@" 2>/dev/null)" || out=""
		if [[ -n "$out" ]]; then printf '%s\n' "$out"; return 0; fi
		if (( i < attempts )); then sleep "$backoff" 2>/dev/null || true; fi
	done
	printf '%s\n' "$out"
	return 0
}

# cap_node_used <ctx> <worker_names_csv> <kubectl_argv...>
# shellcheck disable=SC2329
cap_node_used() {
	local ctx="$1" workers="$2"; shift 2
	_cap_retry_nonempty "$@" --context="$ctx" --request-timeout="${CAP_TOP_TIMEOUT:-15}s" top nodes --no-headers \
		| cap_parse_top_nodes "$workers"
}

# cap_pod_count <ctx> <worker_names_csv> <kubectl_argv...>
# Counts pods scheduled on worker nodes that are Running/Pending, and Running
# injected (sidecar) pods on any node, from the same list (see cap_parse_pod_count;
# emits `scheduled=.. sidecars=..`). At 10k pods ×
# 20 contexts a full `-A -o json` is a hundreds-of-MB serial response on the hot
# path, so we (a) drop terminal pods server-side with a field selector (the parse
# only counts Running/Pending anyway, so this is semantics-preserving) and (b)
# page the list with --chunk-size so kubectl never buffers the whole set at once.
# shellcheck disable=SC2329
cap_pod_count() {
	local ctx="$1" workers="$2"; shift 2
	{ "$@" --context="$ctx" --request-timeout=5s get pods -A -o json \
		--field-selector=status.phase!=Succeeded,status.phase!=Failed \
		--chunk-size="${CAP_POD_CHUNK_SIZE:-500}" 2>/dev/null || true; } \
		| cap_parse_pod_count "$workers"
}

# cap_requested <ctx> <worker_names_csv> <exclude_label|""> <kubectl_argv...>: CPU and
# memory already requested on the worker nodes (cap_parse_requested), read the same
# paged way as cap_pod_count.
# shellcheck disable=SC2329
cap_requested() {
	local ctx="$1" workers="$2" exclude="$3"; shift 3
	{ "$@" --context="$ctx" --request-timeout=5s get pods -A -o json \
		--field-selector=status.phase!=Succeeded,status.phase!=Failed \
		--chunk-size="${CAP_POD_CHUNK_SIZE:-500}" 2>/dev/null || true; } \
		| cap_parse_requested "$workers" "$exclude"
}

# cap_istiod_limits <ctx> <kubectl_argv...>
# NOTE: targets the unsuffixed `istiod` Deployment — correct for a Sail
# IstioRevision/default install (the default revision produces an unsuffixed
# `istiod`, label app=istiod). A NON-default revision (e.g. default-v1-24) names
# it `istiod-<rev>`, so `get deploy istiod` would 404 -> unknown limit.
# shellcheck disable=SC2329
cap_istiod_limits() {
	local ctx="$1"; shift
	{ "$@" --context="$ctx" --request-timeout=5s -n istio-system get deploy istiod -o json 2>/dev/null || true; } \
		| cap_parse_istiod_limits
}

# cap_istiod_used <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
cap_istiod_used() {
	local ctx="$1"; shift
	_cap_retry_nonempty "$@" --context="$ctx" --request-timeout="${CAP_TOP_TIMEOUT:-15}s" -n istio-system top pod -l app=istiod --no-headers \
		| cap_parse_istiod_used
}

# cap_proxy_requests <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
cap_proxy_requests() {
	local ctx="$1"; shift
	{ "$@" --context="$ctx" --request-timeout=5s get istios.sailoperator.io -o json 2>/dev/null || true; } \
		| cap_parse_proxy_requests
}

# cap_per_pod_requests <ctx|""> <explicit_cpu_m> <explicit_mem_mi> <kubectl_argv...>:
# the per-pod CPU and memory a test pod schedules with, for the capacity plan and
# auto-sizing. An explicit value (SCALE_PER_POD_*) wins; otherwise the live Istio CR
# (cap_proxy_requests); without a context or a readable CR, Istio's defaults. Emits
#   cpu_m=<int> mem_mi=<int> cpu_src=<text> mem_src=<text> live=<cpu_m>/<mem_mi>|none
# (the *_src values use '_' for spaces).
# shellcheck disable=SC2329
cap_per_pod_requests() {
	local ctx="$1" ecpu="$2" emem="$3"
	shift 3
	local live="cpu_m=unknown mem_mi=unknown source=unreadable" lc lm ls cpu mem csrc msrc
	[[ -n "$ctx" ]] && (($#)) && live="$(cap_proxy_requests "$ctx" "$@")"
	lc="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^cpu_m=/) print substr($i, 7) }' <<<"$live")"
	lm="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^mem_mi=/) print substr($i, 8) }' <<<"$live")"
	ls="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^source=/) print substr($i, 8) }' <<<"$live")"
	if [[ -n "$ecpu" ]]; then cpu="$ecpu"; csrc="SCALE_PER_POD_CPU_M"
	elif [[ "$lc" =~ ^[0-9]+$ ]]; then cpu="$lc"; csrc="${ls}_on_${ctx}"
	else cpu=100; csrc="istio_default_(no_live_read)"; fi
	if [[ -n "$emem" ]]; then mem="$emem"; msrc="SCALE_PER_POD_MEM_MI"
	elif [[ "$lm" =~ ^[0-9]+$ ]]; then mem="$lm"; msrc="${ls}_on_${ctx}"
	else mem=128; msrc="istio_default_(no_live_read)"; fi
	local lv="none"
	[[ "$lc" =~ ^[0-9]+$ && "$lm" =~ ^[0-9]+$ ]] && lv="${lc}/${lm}"
	printf 'cpu_m=%s mem_mi=%s cpu_src=%s mem_src=%s live=%s\n' "$cpu" "$mem" "$csrc" "$msrc" "$lv"
}

# cap_metrics_ready <ctx> <kubectl_argv...>: "ready" if the metrics API serves
# `top nodes` (>=1 row) within --request-timeout=${CAP_TOP_TIMEOUT:-15}s, else "unavailable". Single
# attempt — the preflight gate (003 metrics_preflight) does its own poll-until-ready
# loop, and this is also the predicate that loop checks each round. Node-level by
# design: `top nodes` and `top pod` share one aggregated metrics API, so node
# readiness implies pod readiness; a just-scheduled istiod pod's first-scrape lag is
# covered by the per-read retry on cap_istiod_used, not this gate.
# shellcheck disable=SC2329
cap_metrics_ready() {
	local ctx="$1"; shift
	local out
	out="$("$@" --context="$ctx" --request-timeout="${CAP_TOP_TIMEOUT:-15}s" top nodes --no-headers 2>/dev/null)" || out=""
	if [[ -n "$out" ]]; then echo "ready"; else echo "unavailable"; fi
}
