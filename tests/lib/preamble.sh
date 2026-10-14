#!/usr/bin/env bash
# Harness metadata and TSV preamble helpers. Sourced, never executed.
#
# Consumers: controlplane, dataplane, propagation, churn, churn-dataplane
#
# Exposes:
#   harness_sha                                   -> `git -C "${ROOT:-.}" describe --always --dirty --abbrev=7` or "unknown"
#   kube_versions <ctx> <kubectl_argv...>          -> kubectl server gitVersion, "unreachable"/"unknown" semantics
#   probe_kube_versions <ctxs_csv> <kubectl_argv...>
#                                                  -> CSV of ctx=ver pairs, concurrent with 5s timeout (PL2)
#   tuning_baseline_state <ctx> <kubectl_argv...>  -> two lines (TUNING_BASELINE=, SIDECAR_EGRESS_HOSTS=)
#                                                     queried from the LIVE mesh, on|off|unknown (PL2)
#   write_preamble <title> <tsv> <k=v...>          -> write `# <title>`, `# generated_at=`, then `# k=v` per arg (PL2, PL19)
#   infra_preamble_lines <kv...>                   -> emit the cluster-infra `# KEY=value` block
#       (istiod req/lim, replicas, network topology) for the TSV preamble.
#       ONE shared emitter so the 003 pre-creator and the 002 `! -f`-guarded collector
#       cannot drift (PL36). Caller passes the already-read values as `KEY=value` args;
#       any omitted key defaults to `unknown` so a legacy/partial caller never silently
#       drops a line. Keys (additive, backward-compatible — all sweep-level scalars: the
#       pin and mesh wiring are homogeneous across a coherent run, PL26):
#         ISTIOD_REQ_CPU_M  ISTIOD_REQ_MEM_MI   (istiod resource REQUESTS, per replica)
#         ISTIOD_LIM_CPU_M  ISTIOD_LIM_MEM_MI   (istiod resource LIMITS, per replica)
#         ISTIOD_REPLICAS                       (replica count over every context: `3`, or
#                                                `1-3` when the members differ; INFRA_SCHEMA 2)
#         ISTIOD_REPLICAS_BY_CONTEXT            (ctx=n,... per context; INFRA_SCHEMA 2)
#         NETWORK_TOPOLOGY                      (single-network / multi-primary,multi-network:N)
#       NODE_ALLOC_* are deliberately NOT here — the O9 capacity block in 002/003
#       (NODE_ALLOC_CPU_M/NODE_ALLOC_MEM_MI) already emits them; single-source per key (F4).
#   growth_preamble_lines <kv...>                  -> emit the controlplane namespace-scaling
#       `# KEY=value` block (SERVICES_PER_NAMESPACE, GROWTH_MODE, WORKLOAD_MODE, ...).
#       ONE shared emitter for 003's pre-create and 002's standalone preamble (PL36);
#       an omitted key reads `unknown`.
#   ns_lifecycle_init <file> <run_id>             -> create the namespace-lifecycle TSV
#       (preamble + header) if it does not exist yet; 001, 003 and 005 all call it (PL36)
#   ns_lifecycle_row <file> <ctx> <series> <n> <action> <namespaces> <objects> <seconds>
#                    <api_429_retried> <api_429_exhausted> <client_throttle_waits> <status>
#                                                  -> append one row, with objects/s and
#       namespaces/s derived from <seconds> (N/A when <seconds> is not > 0)
#   ns_lifecycle_api_counts <stderr_file>         -> "<retried> <exhausted> <throttle_waits>"
#       from the stderr of a `kubectl -v=4` call (see the function)
#
# Requires: tests/lib/common.sh (for die(), split_csv())
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# shellcheck disable=SC2329
harness_sha() {
	local sha
	sha="$(git -C "${ROOT:-.}" describe --always --dirty --abbrev=7 2>/dev/null || true)"
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
	# Temp files are named by index: context names can contain '/' (oc login style).
	local i pids=()
	for i in "${!ctxs[@]}"; do
		(
			v="$(kube_versions "${ctxs[i]}" "$@")"
			printf '%s=%s\n' "${ctxs[i]}" "$v" > "${tmp}/${i}.kv"
		) &
		pids+=($!)
	done
	local p
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
	local first=1 line out=""
	for i in "${!ctxs[@]}"; do
		if [[ -r "${tmp}/${i}.kv" ]]; then
			line="$(<"${tmp}/${i}.kv")"
			if ((first)); then out="$line"; first=0; else out+=",${line}"; fi
		fi
	done
	rm -rf "$tmp"
	printf '%s\n' "$out"
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
		ISTIOD_REPLICAS_BY_CONTEXT
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
#   - root-ns Sidecar `default` in istio-system   (sidecar egress scoping)
#   - Telemetry `tuning-metrics` in istio-system   (client request metrics off)
#   - Telemetry `tuning-access-log` in istio-system (access log on errors only)
#   - meshConfig.discoverySelectors on the Istio CR (istiod namespace filter)
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

# Emit the controlplane namespace-scaling `# KEY=value` preamble block (PL36: one
# shared emitter for 003's pre-create and 002's standalone preamble, so a key added
# here reaches both). Same contract as infra_preamble_lines: the caller passes the
# values it has as `KEY=value` tokens; every key is always emitted, `unknown` when the
# caller omitted it. All keys are sweep-level scalars (PL26).
# Usage: growth_preamble_lines SERVICES_PER_NAMESPACE=2 WORKLOAD_MODE=config-only ...
# shellcheck disable=SC2329
growth_preamble_lines() {
	local -a keys=(
		SERVICES_PER_NAMESPACE GROWTH_MODE WORKLOAD_MODE
		MEASUREMENT_PODS MEASUREMENT_PROXY_MEM_LIMIT
		OUTSIDE_NAMESPACES OUTSIDE_MODES
		PROBE_SETTLE_SEC MEM_STOP_PCT MEM_GUARD_CONTEXTS SERIES_RETIRE
		DISCOVERY_LABEL
	)
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

# Namespace-lifecycle TSV (controlplane growth mode): one row per apply, readiness
# wait, scoping switch, probe teardown or delete, with its duration and the API
# throttling it hit, so the namespace create/delete rate is measured, not assumed.
NS_LIFECYCLE_HEADER=$'timestamp\tcontext\tseries\tnamespace_count\taction\tnamespaces\tobjects\tseconds\tobjects_per_s\tnamespaces_per_s\tapi_429_retried\tapi_429_exhausted\tclient_throttle_waits\tstatus'

# ns_lifecycle_init <file> <run_id>: write the PL2 preamble and the header once. A
# no-op when the file exists (the first writer wins; every writer uses this function).
# shellcheck disable=SC2329
ns_lifecycle_init() {
	local file="$1" run_id="${2:-unknown}"
	[[ -n "$file" ]] || return 0
	[[ -f "$file" ]] && return 0
	mkdir -p "$(dirname "$file")"
	{
		echo "# Namespace lifecycle (controlplane growth mode) — $(date -u -Iseconds)"
		echo "# NS_LIFECYCLE_SCHEMA=2"
		echo "# RUN_ID=${run_id}"
		echo "# HARNESS_SHA=$(harness_sha)"
		echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
		echo "# APPLY_CHUNK_OBJECTS=${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-unknown}"
		echo "# APPLY_ATTEMPTS=${CONTROLPLANE_APPLY_ATTEMPTS:-unknown}"
		echo "# NS_DELETE_TIMEOUT_SEC=${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-unknown}"
		echo "# NOTE=001 runs its applies and Sidecar deletes at kubectl -v=4. api_429_retried counts client-go's 'Got a Retry-After response' lines (a 429 with Retry-After that client-go retried; at the default verbosity it prints nothing); api_429_exhausted counts TooManyRequests errors that reached kubectl after its retries; client_throttle_waits counts client-side rate-limiter waits over 50 ms (kubectl 1.34 showed none on server-side apply). N/A = not measured (readiness waits and 005's deletes)."
		printf '%s\n' "$NS_LIFECYCLE_HEADER"
	} > "$file"
}

# ns_lifecycle_row: append one lifecycle row (see the header above). A no-op without
# a file, so a step run standalone records nothing.
# shellcheck disable=SC2329
ns_lifecycle_row() {
	local file="$1"
	[[ -n "$file" && -f "$file" ]] || return 0
	local ctx="$2" series="${3:-none}" n="$4" action="$5" nss="$6" objs="$7" secs="$8" r429="$9" e429="${10}" thr="${11}" status="${12}"
	local rates
	rates="$(awk -v o="$objs" -v n="$nss" -v s="$secs" '
		function isnum(x) { return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
		BEGIN {
			if (!isnum(s) || s + 0 <= 0) { print "N/A\tN/A"; exit }
			printf "%s\t%s\n", (isnum(o) ? sprintf("%.2f", o / s) : "N/A"), (isnum(n) ? sprintf("%.3f", n / s) : "N/A")
		}')"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u -Iseconds)" "$ctx" "${series:-none}" "$n" "$action" \
		"$nss" "$objs" "$secs" "$rates" "$r429" "$e429" "$thr" "$status" >> "$file"
}

# ns_lifecycle_api_counts <stderr_file>: "<retried> <exhausted> <throttle_waits>" from the
# stderr of a `kubectl -v=4` call. client-go retries a 429 that carries Retry-After (API
# Priority and Fairness sends one) without printing anything at the default verbosity;
# at -v=4 each retry logs `"Got a Retry-After response"`. A 429 left after its retries
# reaches kubectl as `Error from server (TooManyRequests)` (or an `error:` line naming it).
# Client-side rate-limiter waits log "client-side throttling" (-v=3+). Only those forms
# count: request URLs, namespace and series names, klog timestamps and PIDs, which can
# all contain "429", never do, and neither do dumped response bodies (indented lines).
# 0 0 0 when the file is missing.
# shellcheck disable=SC2329
ns_lifecycle_api_counts() {
	[[ -f "$1" ]] || { echo "0 0 0"; return 0; }
	awk '
		/Got a Retry-After/ { r++; next }
		/client-side throttling/ { t++; next }
		/^[IWEF][0-9][0-9][0-9][0-9] / || /^[[:space:]]/ { next }
		/^Error from server \(TooManyRequests\)/ { e++; next }
		/^error:/ && /TooManyRequests|[Tt]oo [Mm]any [Rr]equests/ { e++ }
		END { printf "%d %d %d\n", r, e, t }' "$1"
}
