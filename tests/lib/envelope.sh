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
#   env_sla_verdict <icpu_pct> <imem_pct> <ncpu_pct> <nmem_pct> <restarts> <n_total>
#                   <n_valid> [caution_pct] [fail_pct] [not_run] [incomplete] [problems]
#                   [problems_src] [cautions]
#                                                  -> "VERDICT|headline" — one of
#       PASS / CAUTION / FAIL plus a one-line human headline. The verdict is computed
#       only over the validity-gated aggregates the caller passes (the report's
#       n_valid maxes), never configured axis values (PL35). The CAUTION/FAIL utilization
#       bands default from the env (SCALE_SLA_CAUTION_PCT=75 / SCALE_SLA_FAIL_PCT=90 in
#       config/options.env) but accept args 8/9 so the function stays pure/unit-testable.
#       Arg 10: planned cells that never ran (NOT_RUN); arg 11: cells cut short while
#       their member rows were written (INCOMPLETE); arg 12: the PROBLEM lines of the
#       sweep outcome (arg 13: the records that hold them); arg 14: other conditions, one
#       clause per line: each turns a PASS into CAUTION.
#       The controlplane report (004) is the SINGLE authoritative compute site;
#       render_scale_envelope reads the verdict back from the report JSON.
#   env_replicas_summary <n...>                    -> the ISTIOD_REPLICAS token for
#       per-context istiod replica counts: `3` when they agree, `1-3` when they vary,
#       `unknown` when none was read.
#   env_replicas_label <ISTIOD_REPLICAS> [ISTIOD_REPLICAS_BY_CONTEXT]
#                                                  -> display form: `3 per cluster`,
#       `1-3 per cluster (varies by cluster)`, `3 (first context only)` for a TSV
#       written before every context was read.
#   env_proxy_versions_summary <ISTIO_PROXY_VERSIONS>
#                                                  -> the proxy versions summed over the
#       members, no context names: `1.30.5: 2400, 1.30.4: 3 (20 members; 1 unknown)`.
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
#          Reads the report's JSON (peak-mesh row + capacity metadata; its provenance
#          warning, attempts and data warnings lead the block) and takes a read-only
#          `kubectl top nodes` / `top pod -l app=istiod` snapshot across --contexts.
#          Per-sweep dir only (PL6); never a flat glob.
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

# env_sla_verdict <icpu_pct> <imem_pct> <ncpu_pct> <nmem_pct> <restarts> <n_total> <n_valid>
#                 [caution_pct] [fail_pct] [not_run] [incomplete] [problems] [problems_src]
#                 [cautions]
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
# <not_run> (arg 10, default 0): planned cells of the sweep that never ran (NOT_RUN: no
# row, so no sample of theirs is in n_total). The figures cover only the cells that ran, so
# a PASS reads CAUTION "N planned cell(s) never ran (NOT_RUN)", and a CAUTION or FAIL
# headline adds it. <incomplete> (arg 11, default 0): cells whose latest attempt has rows of
# fewer members than its mesh size, or a member fewer rows than its window wrote
# (INCOMPLETE: cut short while they were written), whose figures cover only those members:
# the same, as "N cell(s) are INCOMPLETE". <problems> (arg 12, default 0): the PROBLEM
# lines of the sweep's outcome (sweep-outcome.txt: the harness or Istio changed during the
# sweep, ...), which the figures cannot show: the same, as "the sweep outcome records N
# PROBLEM(s) (<problems_src>)"; <problems_src> (arg 13, default sweep-outcome.txt) names
# the records counted (several, "<file>: <n>; <file>: <n>", read "the sweep outcomes
# record"). <cautions> (arg 14, default none): other conditions the figures cannot show
# (the rows ran on more than one harness, a cell ran on fewer istiod pods than wanted), one
# clause per line, each the same: a PASS reads CAUTION "<clause>; the figures: <reason>",
# and a CAUTION or FAIL headline adds "; also <clause>". Pass "" for args 8/9 to keep
# their defaults.
# Emits "<VERDICT>|<one-line headline>". Pure.
# shellcheck disable=SC2329
env_sla_verdict() {
	local caution="${8:-${SCALE_SLA_CAUTION_PCT:-75}}" fail="${9:-${SCALE_SLA_FAIL_PCT:-90}}" not_run="${10:-0}" incomplete="${11:-0}"
	local problems="${12:-0}" problems_src="${13:-sweep-outcome.txt}" cautions="${14:-}"
	[[ "$not_run" =~ ^[0-9]+$ ]] || not_run=0
	[[ "$incomplete" =~ ^[0-9]+$ ]] || incomplete=0
	[[ "$problems" =~ ^[0-9]+$ ]] || problems=0
	# The texts through the environment: awk -v would unescape a backslash in them.
	_ESV_SRC="$problems_src" _ESV_CAUTIONS="$cautions" awk -v icpu="${1:-}" -v imem="${2:-}" -v ncpu="${3:-}" -v nmem="${4:-}" \
	    -v restarts="${5:-0}" -v ntotal="${6:-0}" -v nvalid="${7:-0}" \
	    -v caution="$caution" -v fail="$fail" -v notrun="$not_run" -v incomplete="$incomplete" \
	    -v problems="$problems" '
	function isnum(x) { return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
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
			verdict = "PASS"; reason = sprintf("peak utilization %d%% < %d%% across istiod + nodes, no restarts, all %d samples valid", peak, caution+0, nvalid+0)
		}
		# Planned cells that never ran: the figures cover only the cells that did.
		if (notrun + 0 > 0) {
			if (verdict == "PASS") { verdict = "CAUTION"; reason = sprintf("%d planned cell(s) never ran (NOT_RUN), so the sweep covers only part of its plan; the cells that ran: %s", notrun, reason) }
			else reason = sprintf("%s; also %d planned cell(s) never ran (NOT_RUN)", reason, notrun)
		}
		# Cells cut short while their member rows were written: their figures cover part of
		# the mesh.
		if (incomplete + 0 > 0) {
			if (verdict == "PASS") { verdict = "CAUTION"; reason = sprintf("%d cell(s) are INCOMPLETE (rows of fewer members than their mesh size, or a member with fewer rows than its window wrote: cut short while they were written), so their figures cover part of the mesh; the figures, these cells included: %s", incomplete, reason) }
			else reason = sprintf("%s; also %d cell(s) are INCOMPLETE (rows of fewer members than their mesh size, or a member with fewer rows than its window wrote)", reason, incomplete)
		}
		# The sweep outcome'"'"'s PROBLEMs (the harness or Istio changed during it, ...): no
		# figure shows them.
		if (problems + 0 > 0) {
			src = ENVIRON["_ESV_SRC"]
			# Several records ("<file>: <n>; <file>: <n>", a pooled report): plural.
			rec = index(src, "; ") ? "the sweep outcomes record" : "the sweep outcome records"
			if (verdict == "PASS") { verdict = "CAUTION"; reason = sprintf("%s %d PROBLEM(s) (%s), so the figures may not measure what they seem to; the figures: %s", rec, problems, src, reason) }
			else reason = sprintf("%s; also %s %d PROBLEM(s) (%s)", reason, rec, problems, src)
		}
		# Other conditions no figure shows, one clause per line.
		nc = split(ENVIRON["_ESV_CAUTIONS"], cl, "\n")
		for (i = 1; i <= nc; i++) {
			if (cl[i] == "") continue
			if (verdict == "PASS") { verdict = "CAUTION"; reason = cl[i] "; the figures: " reason }
			else reason = reason "; also " cl[i]
		}
		printf "%s|%s\n", verdict, reason
	}'
}

# env_proxy_versions_summary <ISTIO_PROXY_VERSIONS>: The proxies connected to istiod
# at the start, by Istio version, summed over the members and without their names (the
# envelope is pasted into campaign docs; one line for 20 members), most first:
# "1.30.5: 2400, 1.30.4: 3 (20 members; 1 unknown)". A member with no proxy counts as
# "with none", one whose read failed as unknown; a value that is not per member (unknown,
# unchecked, a pooled mixed:a,b) is printed as it is. A pooled value whose runs
# connected the same versions with different counts carries no counts
# (config_merged_preamble): its versions are listed without them, "1.30.5, 1.30.4 (20
# members; proxy counts differ between the pooled runs)". Pure.
# shellcheck disable=SC2329
env_proxy_versions_summary() {
	awk -v v="${1:-}" 'BEGIN {
		if (v == "" || v == "unknown" || v == "unchecked" || v ~ /^mixed:/) { print (v == "" ? "unknown" : v); exit }
		n = split(v, p, ",")
		for (i = 1; i <= n; i++) {
			if (!match(p[i], /=[^=]*$/)) { unk++; nm++; continue }
			nm++
			l = substr(p[i], RSTART + 1)
			if (l == "none") { none++; continue }
			if (l == "unknown" || l !~ /^[^:+]+(:[0-9]+)?(\+[^:+]+(:[0-9]+)?)*$/) { unk++; continue }
			m = split(l, e, "+")
			for (j = 1; j <= m; j++) {
				k = e[j]
				if (k ~ /:[0-9]+$/) { c = substr(k, match(k, /:[0-9]+$/) + 1); sub(/:[0-9]+$/, "", k) } else { c = 0; nocount = 1 }
				if (!(k in s)) o[++no] = k
				s[k] += c
			}
		}
		if (!nocount) for (i = 2; i <= no; i++) { x = o[i]; for (j = i - 1; j >= 1 && (s[o[j]] < s[x] || (s[o[j]] == s[x] && o[j] > x)); j--) o[j + 1] = o[j]; o[j + 1] = x }
		out = ""
		for (i = 1; i <= no; i++) out = out (i > 1 ? ", " : "") o[i] (nocount ? "" : ": " s[o[i]])
		if (out == "") out = (unk ? "unknown" : "no proxy connected")
		t = nm " member" (nm == 1 ? "" : "s")
		if (none) t = t "; " none " with none"
		if (unk) t = t "; " unk " unknown"
		if (nocount) t = t "; proxy counts differ between the pooled runs"
		print out " (" t ")"
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
#   req_cpu_m=.. req_mem_mi=.. lim_cpu_m=.. lim_mem_mi=.. replicas=<summary>
#   replicas_by_context=<ctx=n,...>
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
# 002/003 already emits NODE_ALLOC_* (single-source per key). Emits space-separated
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
	for kv in ${rk[@]+"${rk[@]}"}; do
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
		networks_csv="${networks_csv:+${networks_csv},}${net}"
	done
	# Each distinct network is a separate context's own local istiod (multi-primary),
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

	local json
	json="$("$report_script" --results-dir "$results_dir" --format json 2>/dev/null || true)"
	[[ -n "$json" ]] || die "render_scale_envelope: report produced no JSON for $results_dir"

	# Pull capacity provenance + achieved-scale maxes from the report metadata
	# (the report already applied the validity gate to these maxes — PL35).
	jq_get() { printf '%s' "$json" | jq -r "$1 // \"unknown\"" 2>/dev/null || printf 'unknown'; }

	local node_cpu_m node_mem_mi istio_version istio_version_src harness_sha harness_key
	node_cpu_m="$(jq_get '.metadata.capacity.node_alloc_cpu_m')"
	node_mem_mi="$(jq_get '.metadata.capacity.node_alloc_mem_mi')"
	istio_version="$(jq_get '.metadata.istio_version')"
	# Live = each member's active IstioRevision .spec.version, read before the first
	# step; pin = config only (a dry run, or a TSV written before the live read: unknown).
	# The sweep reads it again at the end and appends its outcome below this envelope.
	istio_version_src="$(jq_get '.metadata.istio_version_source') (pin $(jq_get '.metadata.istio_version_pin'); by member $(jq_get '.metadata.istio_version_by_context'))"
	harness_sha="$(jq_get '.metadata.harness_sha')"
	harness_key="$(jq_get '.metadata.harness_content_key')"
	# The harness the report ran, and its provenance warning (the rows come from runs on
	# other harnesses), as every report format shows them.
	local report_harness prov_warn prov_line=""
	report_harness="$(jq_get '.metadata.report_harness_sha')"
	prov_warn="$(printf '%s' "$json" | jq -r '.metadata.provenance_warning // empty' 2>/dev/null || true)"
	[[ -z "$prov_warn" ]] || prov_line="> **Provenance warning:** ${prov_warn//$'\n'/ }"
	# The report's data warnings (an istiod pod not Ready in a window, a member that ran
	# fewer istiod replicas than wanted, ...): they qualify the figures below, so one line
	# each, as every report format prints them. They can name members, as the "by member"
	# list below does: paste a redacted copy (redact-results.sh maps them).
	local dw_lines=""
	dw_lines="$(printf '%s' "$json" | jq -r '(.metadata.data_warnings // [])[] | "> **Data warning:** " + (split("\n") | join(" "))' 2>/dev/null || true)"
	# The attempts behind it, when a --resume ran or the harness changed during a run: each
	# run's or change's HARNESS_SHA and rows, as 004 prints them (no KUBE_VERSIONS: they
	# name the members).
	local att_line=""
	att_line="$(printf '%s' "$json" | jq -r '(.metadata.attempts // []) | if length > 1 then "> **Attempts:** " + (map("\(.run) HARNESS_SHA=\(.harness_sha) (\(.rows) row(s), \(.rows_kept // .rows) in the figures)") | join("; ")) else empty end' 2>/dev/null || true)"
	# The proxy versions at the start, summed over the members (no context names).
	local proxy_versions earlier_rows earlier_cells earlier_line=""
	proxy_versions="$(env_proxy_versions_summary "$(jq_get '.metadata.istio_proxy_versions')")"
	# The report reads each cell's latest attempt; say how many rows that left out.
	earlier_rows="$(jq_get '.metadata.earlier_attempt_rows_left_out')"
	earlier_cells="$(jq_get '.metadata.earlier_attempt_cells')"
	if [[ "$earlier_rows" =~ ^[1-9][0-9]*$ ]]; then
		earlier_line="> Each cell's latest attempt only: ${earlier_rows} row(s) of earlier attempts of ${earlier_cells} cell(s) (failed, then run again by a --resume) are left out of every figure here."
	fi
	# While the sweep renders this, its outcome is not written yet: the same line the
	# markdown report gets, which sweep_outcome --md replaces with the outcome (a sweep
	# that dies before it leaves the line, so the envelope says it is not finished).
	local pending_line=""
	if [[ "${_SWEEP_OUTCOME_PENDING:-0}" == 1 ]] && sweep_outcome_unfinished "${results_dir}/sweep-outcome.txt"; then
		pending_line="$(sweep_outcome_recorded "$results_dir" md)"
	fi

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
	# RSS-derived istiod mem headroom (% of per-replica mem limit). Always
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
	for kv in ${rk[@]+"${rk[@]}"}; do
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
		networks_csv="${networks_csv:+${networks_csv},}${net}"
	done
	# Distinct non-unknown networks across the per-context istiod reads. Each
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

	# Table cells: a pooled or per-member value can hold " | " (a merged preamble value,
	# config_merged_preamble), which would split the cell (md_cell, PL19).
	local _cell
	for _cell in proxy_versions istio_version istio_version_src replicas_label proxy_check \
		topology peak_scope peak_traffic peak_mesh peak_svc peak_ns reps_label total_svc total_eps; do
		md_cell -v "$_cell" "${!_cell}"
	done

	# ---- render ----
	cat <<MD
## Scale envelope

> Auto-generated by \`tests/lib/envelope.sh:render_scale_envelope\` from \`$(basename "$results_dir")\` (harness \`${harness_sha}\`, HARNESS_CONTENT_KEY \`${harness_key}\`; report harness \`${report_harness}\`: REPORT_HARNESS_SHA, the harness that rendered it).
> Measured columns are the report's n_valid-gated peaks (restarted/SETUP_FAILED rows excluded).
${prov_line:+${prov_line}
}${att_line:+${att_line}
}${earlier_line:+${earlier_line}
}${dw_lines:+${dw_lines}
}${pending_line:+
${pending_line}
}
### 1. Mesh topology — what the peak mesh-size point actually contains

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
| Proxy (Envoy) versions at the start | ${proxy_versions} | sweep header \`ISTIO_PROXY_VERSIONS\` (istiod \`pilot_xds\` by \`version\`, summed over the members; a sidecar keeps its version until its pod restarts) |
| Istio version | ${istio_version}, source ${istio_version_src} | sweep header \`ISTIO_VERSION\` (\`ISTIO_VERSION_SOURCE\` live: each member's active IstioRevision \`.spec.version\` at the start; the end-of-sweep read is under "Sweep outcome" below when it found a change) |

> **Connected proxies per cluster** is \`pilot_xds\` summed over one cluster's istiod replicas at one scrape. It should be about equal to that cluster's Running injected pods (gateways included), which the proxy check compares. It is still not a mesh-wide sum and not endpoints; do not expect it to equal total endpoints. **Per istiod replica** is the busiest single replica (max over the per-pod rows), about 1/R of the cluster figure with R replicas.

### 2. Control-plane provisioning & headroom — *was anything actually stressed?*

| Resource | Provisioned (req / lim, per replica) | Measured (% of limit) | Source |
|---|---|---|---|
| istiod replicas | ${replicas_label} | — | live \`deploy/istiod\` on every context |
| **istiod CPU (window peak)** | ${req_cpu}m / ${lim_cpu}m | ${istiod_cpu_pct}% | report \`istiod_cpu_peak_pct_of_limit_max\`: one replica's peak (the larger of a window's average and its busiest 5 s poll) / the per-replica limit |
| istiod CPU (kubectl top at window end) | ${req_cpu}m / ${lim_cpu}m | ${istiod_cpu_top_pct}% | report \`istiod_cpu_pct_of_limit_max\`: one snapshot per window, summed over the replicas / their summed limit; misses bursts |
| istiod memory (kubectl top) | ${req_mem}Mi / ${lim_mem}Mi | ${istiod_mem_pct}% | report \`istiod_mem_pct_of_limit_max\` |
| **istiod memory (RSS — OOM headroom)** | ${req_mem}Mi / ${lim_mem}Mi | ${istiod_rss_pct}% | report \`istiod_rss_pct_of_limit_max\` (\`process_resident_memory_bytes\`) |
| Worker-node CPU | — | ${node_cpu_pct}% | report \`node_cpu_pct_max\` (\`kubectl top nodes\`) |
| Worker-node memory | — | ${node_mem_pct}% | report \`node_mem_pct_max\` (\`kubectl top nodes\`) |

> Node allocatable (source ctx): ${node_cpu_m}m CPU / ${node_mem_mi}Mi memory.
> istiod CPU/mem(top) % is of the **cross-replica** limit (per-replica limit x that cluster's istiod replicas), so an idle R-replica plane does not read ~Rx100% (PL35).
> **istiod RSS %** is per-replica (peak \`process_resident_memory_bytes\` of one istiod / its per-replica mem limit) and is the OOM-risk signal: in multi-primary each istiod caches the WHOLE mesh (~N x services x replicas endpoints), so RSS grows with total mesh size. It is sourced from the /metrics scrape, so it stays populated even when \`kubectl top\` (the row above) is N/A during a metrics-API gap. An RSS % approaching 100 is OOM-mid-sweep risk.
> **istiod mem REQUEST sizing (GO gate):** the chart's istiod mem *request* (${req_mem}Mi above) must be sized to the **measured steady-state RSS** at the target mesh scale before GO — it needs a measured number from a full-scale run, NOT a guessed default. The RSS % here is the input for that sizing. This change only SURFACES the headroom; it deliberately does not change the request value.

### Customer SLA verdict — one line, up front

> **${verdict}** — ${headline}
MD
}
