#!/usr/bin/env bash
# Harness metadata and TSV preamble helpers. Sourced, never executed.
#
# Consumers: controlplane, dataplane, propagation, churn, churn-dataplane
#
# Exposes:
#   harness_sha                                   -> `git describe --always --dirty --abbrev=7` or "unknown"
#   kube_versions <ctx> <kubectl_argv...>          -> kubectl server gitVersion, "unreachable"/"unknown" semantics
#   probe_kube_versions <ctxs_csv> <kubectl_argv...>
#                                                  -> CSV of ctx=ver pairs, concurrent with 5s timeout (PL2)
#   istiod_restart_status <pre> <post>             -> "0" | "1" | "unknown" based on process_start_time_seconds (PL9)
#   istiod_start_time_seconds <port>               -> scrape process_start_time_seconds gauge
#   tuning_baseline_state <ctx> <kubectl_argv...>  -> two lines (TUNING_BASELINE=, SIDECAR_EGRESS_HOSTS=)
#                                                     queried from the LIVE mesh, on|off|unknown (PL2)
#   write_preamble <title> <tsv> <kv pairs...>     -> write `# key=value` comment lines + RUN_ID/HARNESS_SHA (PL2, PL19)
#   infra_preamble_lines <kv...>                   -> emit the cluster-infra `# KEY=value` block
#       (istiod req/lim, replicas, network topology) for the TSV preamble.
#       ONE shared emitter so the 003 pre-creator and the 002 `! -f`-guarded collector
#       cannot drift (PL36). Caller passes the already-read values as `KEY=value` args;
#       any omitted key defaults to `unknown` so a legacy/partial caller never silently
#       drops a line. Keys (additive, backward-compatible — all sweep-level scalars: the
#       pin and mesh wiring are homogeneous across a coherent run, PL26):
#         ISTIOD_REQ_CPU_M  ISTIOD_REQ_MEM_MI   (istiod resource REQUESTS, per replica)
#         ISTIOD_LIM_CPU_M  ISTIOD_LIM_MEM_MI   (istiod resource LIMITS, per replica)
#         ISTIOD_REPLICAS                       (replica count)
#         NETWORK_TOPOLOGY                      (single-network / multi-primary,multi-network:N)
#       NODE_ALLOC_* are deliberately NOT here — the O9 capacity block in 002/003
#       (NODE_ALLOC_CPU_M/NODE_ALLOC_MEM_MI) already emits them; single-source per key (F4).
#
# Requires: tests/lib/common.sh (for die(), split_csv())
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# shellcheck disable=SC2329
harness_sha() {
	local sha
	sha="$(git describe --always --dirty --abbrev=7 2>/dev/null || true)"
	[[ -n "$sha" ]] || sha="unknown"
	printf '%s\n' "$sha"
}

# Per-context Kubernetes server version probe. Honors PL2 semantics:
#  - 5s --request-timeout
#  - unreachable cluster -> "unreachable"
#  - parsable JSON missing serverVersion -> "unknown"
# Usage: kube_versions <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
kube_versions() {
	local ctx="$1"
	shift
	local out rc gitv
	out="$("$@" --context="$ctx" --request-timeout=5s version --output=json 2>/dev/null)" && rc=0 || rc=$?
	if ((rc != 0)) || [[ -z "$out" ]]; then
		printf '%s\n' "unreachable"
		return 0
	fi
	gitv="$(printf '%s' "$out" | jq -r '.serverVersion.gitVersion // empty' 2>/dev/null)"
	if [[ -z "$gitv" || "$gitv" == "null" ]]; then
		printf '%s\n' "unknown"
		return 0
	fi
	printf '%s\n' "$gitv"
}

# Concurrent probe of multiple contexts. Returns ctx1=ver1,ctx2=ver2,...
# Usage: probe_kube_versions "$ctxs_csv" <kubectl_argv...>
# shellcheck disable=SC2329
probe_kube_versions() {
	local ctxs_csv="$1"
	shift
	local -a ctxs=()
	split_csv "$ctxs_csv" ctxs
	local tmp
	tmp="$(mktemp -d)"
	local ctx pids=()
	for ctx in "${ctxs[@]}"; do
		(
			v="$(kube_versions "$ctx" "$@")"
			printf '%s=%s\n' "$ctx" "$v" > "${tmp}/${ctx}.kv"
		) &
		pids+=($!)
	done
	local p
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
	local first=1 line out=""
	for ctx in "${ctxs[@]}"; do
		if [[ -r "${tmp}/${ctx}.kv" ]]; then
			line="$(<"${tmp}/${ctx}.kv")"
			if ((first)); then out="$line"; first=0; else out+=",${line}"; fi
		fi
	done
	rm -rf "$tmp"
	printf '%s\n' "$out"
}

# Inspect istiod's process_start_time_seconds gauge to decide whether the
# control plane restarted during the measurement window.
# PL9: emit one of "0" / "1" / "unknown".
# shellcheck disable=SC2329
istiod_restart_status() {
	local pre="$1" post="$2"
	if [[ -z "$pre" || -z "$post" || "$pre" == "unknown" || "$post" == "unknown" ]]; then
		printf '%s\n' "unknown"
		return 0
	fi
	awk -v a="$pre" -v b="$post" 'BEGIN {
		if (a+0 == 0 || b+0 == 0) { print "unknown"; exit }
		if (a+0 == b+0)            { print "0"; exit }
		print "1"
	}'
}

# Scrape process_start_time_seconds once.
# Usage: istiod_start_time_seconds <port>
# shellcheck disable=SC2329
istiod_start_time_seconds() {
	local port="$1" tmpfile
	tmpfile="$(mktemp)"
	# Shared, centralized scrape timeout (config/options.env METRICS_SCRAPE_TIMEOUT);
	# inline default keeps this lib correct when sourced standalone (bats). MUST be
	# raised at 10k scale — the /metrics body is MB-class and a 5s curl drops it.
	if ! curl -fsS --max-time "${METRICS_SCRAPE_TIMEOUT:-30}" "http://localhost:${port}/metrics" -o "$tmpfile" 2>/dev/null; then
		rm -f "$tmpfile"
		printf '%s\n' "unknown"
		return 0
	fi
	awk '
	/^process_start_time_seconds[ {]/ && !/^#/ { v=$NF; found=1 }
	END {
		if (found) printf "%s\n", v
		else        printf "unknown\n"
	}' "$tmpfile"
	rm -f "$tmpfile"
}

# Emit the additive cluster-infra `# KEY=value` preamble block (PL36: ONE shared
# emitter for both the 003 pre-creator and the 002 `! -f`-guarded collector, so a
# key added to one writer can never silently vanish from the other). The caller
# passes whatever it has already read as `KEY=value` tokens; every infra key the
# downstream report expects is ALWAYS emitted, defaulting to `unknown` when the
# caller omitted it — so a required-but-missing infra key reads as a legible
# `unknown` (distinguishable from a never-defined key, PL36) rather than absent.
# Writes to stdout (caller redirects/appends into the TSV preamble).
# Usage: infra_preamble_lines ISTIOD_LIM_CPU_M=4000 ISTIOD_REPLICAS=5 ...
# shellcheck disable=SC2329
infra_preamble_lines() {
	# Canonical, ordered key set. Adding a key here propagates to BOTH writers.
	# NODE_ALLOC_* intentionally excluded — emitted by the O9 capacity block (F4).
	local -a keys=(
		ISTIOD_REQ_CPU_M ISTIOD_REQ_MEM_MI
		ISTIOD_LIM_CPU_M ISTIOD_LIM_MEM_MI
		ISTIOD_REPLICAS
		NETWORK_TOPOLOGY
	)
	# Seed all to unknown, then overlay caller-supplied values.
	declare -A vals=()
	local k kv
	for k in "${keys[@]}"; do vals[$k]="unknown"; done
	for kv in "$@"; do
		k="${kv%%=*}"
		[[ -n "${vals[$k]+set}" ]] && vals[$k]="${kv#*=}"
	done
	for k in "${keys[@]}"; do
		printf '# %s=%s\n' "$k" "${vals[$k]}"
	done
}

# Query the LIVE deployed tuning-baseline state on ONE context (the source
# context) and emit two preamble values describing which campaign levers are
# actually live on the mesh, NOT what the chart default says (chart default and
# deployed state can diverge via a live/Argo override or `--set`). PL2 class:
# these probes (four tuning levers + the live sidecar egress host graph) change
# measurable mesh behaviour but are otherwise invisible in a TSV row, so a run with
# an identical HARNESS_SHA but a hand-patched mesh would be silently non-comparable.
#
# Probed (all read-only `get`, each bounded by --request-timeout=5s):
#   - root-ns Sidecar `default` in istio-system   (Profile 01 sidecar-scoping)
#   - Telemetry `tuning-metrics` in istio-system   (Profile 07 telemetry-filtering)
#   - Telemetry `tuning-access-log` in istio-system (Profile 08 access-log-filtering)
#   - meshConfig.discoverySelectors on the Istio CR (Profile 02 discovery-selectors)
#   - the live egress hosts on the root Sidecar     (the egress GRAPH that was applied)
#
# Emits two lines on stdout (the caller adds the leading "# "):
#   TUNING_BASELINE=sidecar=on|off,discoverySelectors=on|off,telemetryFiltering=on|off,accessLogFiltering=on|off
#   SIDECAR_EGRESS_HOSTS=<space-joined hosts | none>
#
# Degrades gracefully: if the cluster is unreachable / kubectl unavailable / a
# query fails, the affected lever resolves to `unknown` (per the existing
# unreachable/unknown preamble idioms) rather than a false "off".
# Usage: tuning_baseline_state <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
tuning_baseline_state() {
	local ctx="$1"
	shift
	local -a k=("$@")
	local sidecar="unknown" ds="unknown" telem="unknown" alog="unknown" hosts="unknown"

	# Helper: does a named resource exist? echoes on|off, or unknown on query
	# failure (so "unreachable" is never mistaken for "lever is off").
	_tb_exists() {
		local kind="$1" name="$2" out rc
		out="$("${k[@]}" --context="$ctx" --request-timeout=5s -n istio-system \
			get "$kind" "$name" -o name 2>/dev/null)" && rc=0 || rc=$?
		if ((rc != 0)); then printf 'unknown\n'; return 0; fi
		[[ -n "$out" ]] && printf 'on\n' || printf 'off\n'
	}

	sidecar="$(_tb_exists sidecar.networking.istio.io default)"
	telem="$(_tb_exists telemetry.telemetry.istio.io tuning-metrics)"
	alog="$(_tb_exists telemetry.telemetry.istio.io tuning-access-log)"

	# discoverySelectors live on the Istio CR's meshConfig.
	local dsout dsrc
	dsout="$("${k[@]}" --context="$ctx" --request-timeout=5s \
		get istio.sailoperator.io default \
		-o jsonpath='{.spec.values.meshConfig.discoverySelectors}' 2>/dev/null)" && dsrc=0 || dsrc=$?
	if ((dsrc != 0)); then
		ds="unknown"
	elif [[ -n "$dsout" && "$dsout" != "null" && "$dsout" != "[]" ]]; then
		ds="on"
	else
		ds="off"
	fi

	# Live egress hosts on the root Sidecar (the actual applied graph). Only
	# meaningful when the Sidecar exists; otherwise "none" (off) or "unknown".
	if [[ "$sidecar" == "on" ]]; then
		local hout hrc
		hout="$("${k[@]}" --context="$ctx" --request-timeout=5s -n istio-system \
			get sidecar.networking.istio.io default \
			-o jsonpath='{.spec.egress[*].hosts[*]}' 2>/dev/null)" && hrc=0 || hrc=$?
		if ((hrc != 0)); then
			hosts="unknown"
		elif [[ -n "$hout" ]]; then
			hosts="$hout"
		else
			hosts="none"
		fi
	elif [[ "$sidecar" == "off" ]]; then
		hosts="none"
	else
		hosts="unknown"
	fi

	unset -f _tb_exists
	printf 'TUNING_BASELINE=sidecar=%s,discoverySelectors=%s,telemetryFiltering=%s,accessLogFiltering=%s\n' \
		"$sidecar" "$ds" "$telem" "$alog"
	printf 'SIDECAR_EGRESS_HOSTS=%s\n' "$hosts"
}

# Write the TSV preamble required by PL2 + PL19. Every comment line is `# key=value`.
# Usage: write_preamble <title> <tsv_file> <key1=val1> <key2=val2> ...
# shellcheck disable=SC2329
write_preamble() {
	local title="$1" tsv="$2"
	shift 2
	local kv
	{
		echo "# ${title}"
		echo "# generated_at=$(date -u -Iseconds)"
		for kv in "$@"; do
			echo "# ${kv}"
		done
	} > "$tsv"
}
