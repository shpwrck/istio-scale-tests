#!/usr/bin/env bash
# Harness metadata and TSV preamble helpers. Sourced, never executed.
#
# Consumers: controlplane, dataplane, propagation, churn, churn-dataplane, gateway-api (001:
# harness_sha, probe_kube_versions, tuning_baseline_state per member)
#
# Exposes:
#   harness_sha                                   -> `git -C "${ROOT:-.}" describe --always --dirty --abbrev=7` or "unknown"
#   kube_versions <ctx> <kubectl_argv...>          -> kubectl server gitVersion, "unreachable"/"unknown" semantics
#   probe_kube_versions <ctxs_csv> <kubectl_argv...>
#                                                  -> CSV of ctx=ver pairs, concurrent with 5s timeout (PL2)
#   tuning_baseline_state <ctx> <kubectl_argv...>  -> two lines (TUNING_BASELINE=, SIDECAR_EGRESS_HOSTS=)
#                                                     queried from the LIVE mesh, on|off|unknown (PL2)
#   istio_live_version <ctx> <kubectl_argv...>     -> the version the member RUNS (its active
#       IstioRevision's .spec.version, when the Istio CR `default` is settled), or unknown, plus
#       the kind of failure and why (bounded reads, never a guess)
#   istio_version_resolve [--no-stop] <ctxs_csv> <dry_run> <kubectl_argv...>
#                                                  -> R4/PL39: read the live version on every member
#       once per run, check it against the pin (ISTIO_VERSION_CHECK=fail dies, warn warns) and
#       export ISTIO_VERSION (what the results record), ISTIO_VERSION_PIN, ISTIO_VERSION_SOURCE
#       and ISTIO_VERSION_BY_CONTEXT; a no-op when a parent sweep already resolved them
#   istio_version_recheck <out_array> <kubectl_argv...>
#                                                  -> A6: read it again at the end of a sweep;
#       sweep_outcome arguments (--problem when the version or active revision changed,
#       --note when unconfirmed or only readiness is off)
#   istio_version_kv                               -> ISTIO_VERSION=, ISTIO_VERSION_PIN=,
#       ISTIO_VERSION_SOURCE=, ISTIO_VERSION_BY_CONTEXT= lines for every preamble writer (PL36)
#   istio_version_label                            -> the same for people (console, md rows)
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

# istio_live_version <ctx> <kubectl_argv...>: the Istio version a mesh member RUNS, as
# four lines: the version (or unknown), a kind, why (empty when ok) and the Istio CR's
# .status.activeRevisionName (empty when not read). Never a guess. Two reads, each
# bounded by --request-timeout=5s:
#   1. The Sail Istio CR `default` (-o json). Its revision is settled when
#      .status.observedGeneration equals .metadata.generation, at most one revision is in
#      use (.status.revisions.inUse > 1 is a revision migration in progress), it names an
#      .status.activeRevisionName (`default` under InPlace, `default-v1-30-5` under
#      RevisionBased), and .status.state is Healthy or its Reconciled condition is True.
#      .status.state is readiness, not the version (Sail takes it from the first condition
#      of Reconciled, Ready, DependenciesHealthy that is not True: an istiod pod restarting,
#      an IstioCNI pod starting on a new node). Not settled: kind migrating (inUse > 1) or
#      state (anything else), version unknown.
#   2. That IstioRevision's .spec.version: the exact version it runs (the Istio CR's
#      .spec.version is what was requested, and can be an alias such as v1.30-latest).
#      Only ^v?N.N.N$ counts; anything else is kind value. Kind ok when the state is
#      Healthy, notready (the version, with the state as why) when only readiness is off.
# Kind read: kubectl failed or answered nothing (no CR, no access, unreachable); the
# reason is the first line of its stderr, and a caller may retry it.
# shellcheck disable=SC2329
istio_live_version() {
	local ctx="$1" errf out rc=0 gen ogen state inuse rev recon why="" kind=state ready=""
	shift
	errf="$(mktemp)"
	out="$("$@" --context="$ctx" --request-timeout=5s get istios.sailoperator.io default -o json 2>"$errf")" || rc=$?
	if ((rc == 0)) && [[ -n "$out" ]]; then
		out="$(jq -r '[(.metadata.generation // "" | tostring), (.status.observedGeneration // "" | tostring),
			(.status.state // "" | tostring), (.status.revisions.inUse // "" | tostring),
			(.status.activeRevisionName // "" | tostring),
			([.status.conditions[]? | select(.type == "Reconciled") | .status][0] // "" | tostring)]
			| join("|")' <<<"$out" 2>/dev/null)" || rc=1
		[[ "$out" == *"|"* ]] || { rc=1; echo "the Istio CR read did not return JSON" > "$errf"; }
	fi
	if ((rc != 0)) || [[ -z "$out" ]]; then
		why="$(head -n 1 "$errf" | tr -d '\r' | cut -c 1-200)"
		rm -f "$errf"
		printf 'unknown\nread\n%s\n\n' "${why:-kubectl exited ${rc} with no output}"
		return 0
	fi
	IFS='|' read -r gen ogen state inuse rev recon <<<"$out"
	[[ "$rev" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || rev=""
	if [[ "$state" != Healthy ]]; then
		ready="its state is ${state:-not set}, not Healthy"
		[[ "$recon" == True ]] || why="${ready}, and its Reconciled condition is ${recon:-not set}"
	fi
	[[ "$ogen" == "$gen" ]] || why="${why:+${why}; }generation ${gen:-?} is not reconciled yet (observedGeneration ${ogen:-none})"
	if [[ "$inuse" =~ ^[0-9]+$ ]] && ((inuse > 1)); then
		why="${why:+${why}; }${inuse} revisions are in use (a revision migration in progress)"
		kind=migrating
	fi
	[[ -n "$rev" ]] || why="${why:+${why}; }it names no activeRevisionName"
	[[ -z "$why" || -z "$ready" || "$why" == "$ready"* ]] || why="${ready}; ${why}"
	if [[ -n "$why" ]]; then
		rm -f "$errf"
		printf 'unknown\n%s\nthe Istio CR default is not settled: %s\n%s\n' "$kind" "$why" "$rev"
		return 0
	fi
	rc=0
	out="$("$@" --context="$ctx" --request-timeout=5s get istiorevisions.sailoperator.io "$rev" \
		-o 'jsonpath={.spec.version}' 2>"$errf")" || rc=$?
	if ((rc != 0)) || [[ -z "$out" ]]; then
		why="$(head -n 1 "$errf" | tr -d '\r' | cut -c 1-200)"
		rm -f "$errf"
		printf 'unknown\nread\n%s\n%s\n' "${why:-IstioRevision ${rev}: kubectl exited ${rc} with no output}" "$rev"
		return 0
	fi
	rm -f "$errf"
	if [[ ! "$out" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		out="${out//[^A-Za-z0-9._+-]/?}"
		printf 'unknown\nvalue\nIstioRevision %s .spec.version is %s, not an exact version\n%s\n' "$rev" "${out:0:60}" "$rev"
		return 0
	fi
	if [[ -n "$ready" ]]; then
		printf '%s\nnotready\n%s (istiod or IstioCNI not ready)\n%s\n' "$out" "$ready" "$rev"
	else
		printf '%s\nok\n\n%s\n' "$out" "$rev"
	fi
}

# _istio_version_read_all <dir> <ctxs_arrayname> <kubectl_argv...>: istio_live_version
# for every member concurrently, into <dir>/<index> (index, not name: a context name can
# hold '/'). A member whose read failed (kind read) is read once more a second later; a
# CR that answered but is not settled is not retried (that is its state, not a blip).
_istio_version_read_all() {
	local dir="$1" i p kind
	local -n _ivra_ctxs="$2"
	local -a pids=() again=()
	shift 2
	for i in "${!_ivra_ctxs[@]}"; do
		istio_live_version "${_ivra_ctxs[i]}" "$@" > "${dir}/${i}" &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
	for i in "${!_ivra_ctxs[@]}"; do
		kind="$(sed -n 2p "${dir}/${i}" 2>/dev/null || true)"
		case "$kind" in ok | notready | migrating | state | value) ;; *) again+=("$i") ;; esac
	done
	((${#again[@]})) || return 0
	sleep 1
	pids=()
	for i in "${again[@]}"; do
		istio_live_version "${_ivra_ctxs[i]}" "$@" > "${dir}/${i}" &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
}

# _istio_version_repro <kind> <ctx> <kubectl_argv...>: the command that shows an operator
# what the read saw on <ctx>.
_istio_version_repro() {
	local kind="$1" ctx
	ctx="$(printf '%q' "$2")"
	shift 2
	if [[ "$kind" == value ]]; then
		echo "$* --context ${ctx} get istiorevisions.sailoperator.io -o yaml"
	else
		echo "$* --context ${ctx} get istios.sailoperator.io default -o yaml"
	fi
}

# _istio_version_marker: the resolved values as one string. istio_version_resolve exports
# it as _ISTIO_VERSION_RESOLVED; a step inherits a sweep's result only while it matches.
_istio_version_marker() {
	printf '%s|%s|%s|%s' "${ISTIO_VERSION_SOURCE:-}" "${ISTIO_VERSION_PIN:-}" "${ISTIO_VERSION:-}" \
		"${ISTIO_VERSION_BY_CONTEXT:-}"
}

# istio_version_resolve [--no-stop] <ctxs_csv> <dry_run 0|1> <kubectl_argv...>: R4 (PL39).
# The results record the Istio version the mesh runs, not only the config/versions.env
# pin (an existing cluster, a bumped istioVersion, or an ISTIO_VERSION left in the shell
# by Istio's download script would mislabel them). Call it once per run, before any
# cluster change and outside any measurement window: a sweep before its first step (its
# steps inherit the result through the private _ISTIO_VERSION_RESOLVED marker, never
# because ISTIO_VERSION_* values happen to be in the environment), a standalone probe
# before its first mutation. Reads every member concurrently (istio_live_version, one
# retry for a failed read) and exports:
#   ISTIO_VERSION_PIN         the pin (ISTIO_VERSION as versions.env / the environment set it)
#   ISTIO_VERSION_SOURCE      live, or pin under --dry-run (nothing is read)
#   ISTIO_VERSION_BY_CONTEXT  ctx=version,... (unknown where unreadable or not settled)
#   ISTIO_VERSION             what every preamble records: the live version every member
#                             runs; under ISTIO_VERSION_CHECK=warn the truth when they do not
#                             agree (unknown, or mixed:a/b, joined with / so no report splits
#                             it); the pin under --dry-run
# and, for istio_version_recheck, the private _ISTIO_VERSION_REVS (ctx=activeRevisionName,...).
# ISTIO_VERSION_CHECK=fail (default) dies when a member's version is unknown, members
# differ, or it differs from the pin (a leading v is ignored); warn prints the same
# problem as a warning and goes on. --no-stop (gateway-api, a read-only check) always
# warns. Every unknown member is listed with why and a command that reproduces the read.
# Readiness is not the version (I1): a member whose only issue is its state (istiod or
# IstioCNI not ready) is read again every ISTIO_VERSION_READY_POLL_SEC for up to
# ISTIO_VERSION_READY_WAIT_SEC; still not ready, its version is recorded and a warning
# names the state. That never stops the run.
# Needs die(), split_csv() and is_nonneg_int() from common.sh.
# shellcheck disable=SC2329
istio_version_resolve() {
	local nostop=0
	if [[ "${1:-}" == --no-stop ]]; then
		nostop=1
		shift
	fi
	local ctxs_csv="$1" dry="$2" policy="${ISTIO_VERSION_CHECK:-fail}"
	local wait_max="${ISTIO_VERSION_READY_WAIT_SEC:-60}" poll="${ISTIO_VERSION_READY_POLL_SEC:-5}"
	shift 2
	if [[ -n "${_ISTIO_VERSION_RESOLVED:-}" && "$_ISTIO_VERSION_RESOLVED" == "$(_istio_version_marker)" ]]; then
		return 0
	fi
	case "$policy" in
	fail | warn) ;;
	*) die "ISTIO_VERSION_CHECK must be fail or warn (got: ${policy})" ;;
	esac
	is_nonneg_int "$wait_max" || die "ISTIO_VERSION_READY_WAIT_SEC must be a non-negative integer (got: ${wait_max})"
	{ is_nonneg_int "$poll" && ((poll > 0)); } || die "ISTIO_VERSION_READY_POLL_SEC must be a positive integer (got: ${poll})"
	((nostop)) && policy=warn
	export ISTIO_VERSION_PIN="${ISTIO_VERSION:-unknown}"
	if ((dry)); then
		export ISTIO_VERSION_SOURCE=pin ISTIO_VERSION_BY_CONTEXT=unchecked _ISTIO_VERSION_REVS=""
		export ISTIO_VERSION="$ISTIO_VERSION_PIN"
		_ISTIO_VERSION_RESOLVED="$(_istio_version_marker)"
		export _ISTIO_VERSION_RESOLVED
		return 0
	fi
	{ (($#)) && command -v "$1" >/dev/null 2>&1; } \
		|| die "neither kubectl nor oc found on PATH, so the live Istio version cannot be read"
	local -a ctxs=() waitfor=() wctxs=()
	split_csv "$ctxs_csv" ctxs
	((${#ctxs[@]})) || die "istio_version_resolve: no mesh member contexts"
	local tmp wtmp i j v kind why rev by="" revs="" distinct="" bad=0 detail="" live problem="" fix="" envpin=""
	local notready="" n_notready=0 waited=0
	tmp="$(mktemp -d)"
	_istio_version_read_all "$tmp" ctxs "$@"
	# I1: wait while readiness alone is off (bounded, polled), re-reading only those members.
	while :; do
		waitfor=()
		for i in "${!ctxs[@]}"; do
			[[ "$(sed -n 2p "${tmp}/${i}" 2>/dev/null || true)" != notready ]] || waitfor+=("$i")
		done
		((${#waitfor[@]} && waited < wait_max)) || break
		if ((waited == 0)); then
			echo "  istiod or IstioCNI is not ready on ${#waitfor[@]} of ${#ctxs[@]} members; reading them again every ${poll}s for up to ${wait_max}s..." >&2
		fi
		sleep "$poll"
		waited=$((waited + poll))
		wctxs=()
		for i in "${waitfor[@]}"; do wctxs+=("${ctxs[i]}"); done
		wtmp="$(mktemp -d)"
		_istio_version_read_all "$wtmp" wctxs "$@"
		for j in "${!waitfor[@]}"; do mv -f "${wtmp}/${j}" "${tmp}/${waitfor[j]}"; done
		rm -rf "$wtmp"
	done
	for i in "${!ctxs[@]}"; do
		v="" kind="" why="" rev=""
		{ IFS= read -r v; IFS= read -r kind; IFS= read -r why; IFS= read -r rev; } 2>/dev/null < "${tmp}/${i}" || true
		[[ -n "$v" ]] || v=unknown
		by="${by:+${by},}${ctxs[i]}=${v}"
		revs="${revs:+${revs},}${ctxs[i]}=${rev}"
		if [[ "$v" == unknown ]]; then
			bad=$((bad + 1))
			detail+=$'\n'"  ${ctxs[i]}: ${why:-no answer}"
			detail+=$'\n'"    reproduce: $(_istio_version_repro "${kind:-read}" "${ctxs[i]}" "$@")"
		elif [[ "$kind" == notready ]]; then
			n_notready=$((n_notready + 1))
			notready+=$'\n'"  ${ctxs[i]}: ${why}"
			notready+=$'\n'"    check: $(_istio_version_repro state "${ctxs[i]}" "$@")"
		fi
		case "/${distinct}/" in */"${v}"/*) ;; *) distinct="${distinct:+${distinct}/}${v}" ;; esac
	done
	rm -rf "$tmp"
	if [[ "$distinct" == */* ]]; then live="mixed:${distinct}"; else live="$distinct"; fi
	if ((bad)); then
		problem="cannot read the running Istio version on ${bad} of ${#ctxs[@]} members:${detail}"$'\n'"Fix access to those members (kubeconfig, login, network), or wait until their Istio CR is settled; the pin is not the problem."
	elif [[ "$distinct" == */* ]]; then
		problem="the mesh members run different Istio versions (${by})"
		fix=$'\n'"Fix: bring every member to one version (an upgrade still rolling out?), or pass --contexts with only the members that run the same one."
	elif [[ "${live#v}" != "${ISTIO_VERSION_PIN#v}" ]]; then
		# Where the pin came from: an ISTIO_VERSION exported in the shell, or versions.env.
		# shellcheck disable=SC2016  # the sed pattern matches a literal ${ISTIO_VERSION:-...}
		envpin="$(sed -n 's/^export ISTIO_VERSION="\${ISTIO_VERSION:-\(.*\)}".*$/\1/p' \
			"${ROOT:-.}/config/versions.env" 2>/dev/null || true)"
		if [[ -n "$envpin" && "$envpin" != "$ISTIO_VERSION_PIN" ]]; then
			problem="the mesh runs Istio ${live} (${by}), but ISTIO_VERSION is ${ISTIO_VERSION_PIN}, exported in this shell (config/versions.env pins ${envpin})"
			fix=$'\n'"Fix: unset ISTIO_VERSION (a value left in the shell, for example by Istio's download script), or run with ISTIO_VERSION=${live} to record the live version."
		else
			problem="the mesh runs Istio ${live} (${by}), but ISTIO_VERSION is ${ISTIO_VERSION_PIN} (config/versions.env)"
			fix=$'\n'"Fix: bump ISTIO_VERSION in config/versions.env with charts/spoke-ossm istioVersion when the mesh was upgraded on purpose, or run with ISTIO_VERSION=${live} for this run only."
		fi
	fi
	if [[ -n "$problem" ]]; then
		if [[ "$policy" == fail ]]; then
			die "${problem}${fix}"$'\n'"Nothing was changed. To go on anyway and record ISTIO_VERSION=${live}, set ISTIO_VERSION_CHECK=warn."
		fi
		why="ISTIO_VERSION_CHECK=warn"
		((nostop == 0)) || why="a read-only check never stops on this"
		echo "warning: ${problem}${fix}"$'\n'"Going on (${why}): the results record ISTIO_VERSION=${live} (ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN})." >&2
	fi
	if ((n_notready)); then
		echo "WARNING: istiod or IstioCNI is still not ready on ${n_notready} of ${#ctxs[@]} members after ${waited}s:${notready}"$'\n'"The run goes on: their version was read (ISTIO_VERSION=${live}), but a control plane that is not ready can slow or skew the first measurements. Wait for the Istio CR to be Healthy, or raise ISTIO_VERSION_READY_WAIT_SEC." >&2
	fi
	export ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT="$by" _ISTIO_VERSION_REVS="$revs"
	export ISTIO_VERSION="$live"
	_ISTIO_VERSION_RESOLVED="$(_istio_version_marker)"
	export _ISTIO_VERSION_RESOLVED
}

# istio_version_recheck <out_arrayname> <kubectl_argv...>: A6. Read every member's version
# again at the end of a sweep (after its last window, before its reports), read-only and
# never dying, and compare it with ISTIO_VERSION_BY_CONTEXT (and the activeRevisionName
# in _ISTIO_VERSION_REVS) from istio_version_resolve. Sets the named array to
# sweep_outcome arguments, which print them (once) on stderr:
#   --problem <msg>  a member now runs another version or another active revision, or is
#                    migrating between revisions (inUse > 1), or its revision's version is
#                    not exact: its rows are not all from one version, a failed sweep;
#   --note <msg>     the same version, but istiod or IstioCNI not ready at the end (I1:
#                    readiness, not a version change); or a member that could not be read
#                    again, whose Istio CR is not settled at the end, or that was unknown at
#                    the start (unconfirmed, not a failure).
# Empty when nothing changed, or when nothing was read live (ISTIO_VERSION_SOURCE pin, as
# under --dry-run).
# shellcheck disable=SC2329
istio_version_recheck() {
	local -n _ivrc_out="$1"
	shift
	_ivrc_out=()
	[[ "${ISTIO_VERSION_SOURCE:-pin}" == live && -n "${ISTIO_VERSION_BY_CONTEXT:-}" ]] || return 0
	{ (($#)) && command -v "$1" >/dev/null 2>&1; } || return 0
	local -a ctxs=() start_v=() pairs=()
	local -A start_rev=()
	local pair tmp i v kind why rev sv sr changed="" what="version" revonly=1 unconfirmed="" notready=""
	IFS=, read -r -a pairs <<<"$ISTIO_VERSION_BY_CONTEXT"
	for pair in "${pairs[@]}"; do
		ctxs+=("${pair%=*}")
		start_v+=("${pair##*=}")
	done
	((${#ctxs[@]})) || return 0
	IFS=, read -r -a pairs <<<"${_ISTIO_VERSION_REVS:-}"
	for pair in ${pairs[@]+"${pairs[@]}"}; do start_rev["${pair%=*}"]="${pair##*=}"; done
	tmp="$(mktemp -d)"
	_istio_version_read_all "$tmp" ctxs "$@"
	for i in "${!ctxs[@]}"; do
		v="" kind="" why="" rev=""
		{ IFS= read -r v; IFS= read -r kind; IFS= read -r why; IFS= read -r rev; } 2>/dev/null < "${tmp}/${i}" || true
		[[ -n "$v" ]] || v=unknown
		sv="${start_v[i]}" sr="${start_rev[${ctxs[i]}]:-}"
		if [[ "$sv" == unknown ]]; then
			[[ "$v" == unknown ]] || unconfirmed+="${unconfirmed:+; }${ctxs[i]} was unknown at the start and reads ${v} at the end"
			continue
		fi
		case "$kind" in
		ok | notready)
			if [[ "$v" != "$sv" ]]; then
				changed+="${changed:+; }${ctxs[i]}: ${sv} at the start, ${v} at the end"
				revonly=0
			elif [[ -n "$sr" && -n "$rev" && "$rev" != "$sr" ]]; then
				changed+="${changed:+; }${ctxs[i]}: activeRevisionName ${sr} at the start, ${rev} at the end (both ${v})"
			elif [[ "$kind" == notready ]]; then
				notready+="${notready:+; }${ctxs[i]}: ${why}"
			fi
			;;
		migrating | value)
			changed+="${changed:+; }${ctxs[i]}: ${sv} at the start, ${v} at the end (${why})"
			revonly=0
			;;
		state)
			unconfirmed+="${unconfirmed:+; }${ctxs[i]} ran ${sv} at the start, and at the end ${why}"
			;;
		*)
			unconfirmed+="${unconfirmed:+; }${ctxs[i]} could not be read again (${sv} at the start)"
			;;
		esac
	done
	rm -rf "$tmp"
	((revonly == 0)) || what="active revision"
	if [[ -n "$changed" ]]; then
		_ivrc_out+=(--problem "the Istio ${what} changed during the sweep (${changed}); its rows are not all from ISTIO_VERSION=${ISTIO_VERSION}")
	fi
	if [[ -n "$notready" ]]; then
		_ivrc_out+=(--note "istiod/CNI not ready at the end of the sweep, same Istio version (${notready})")
	fi
	if [[ -n "$unconfirmed" ]]; then
		_ivrc_out+=(--note "the Istio version at the end of the sweep is unconfirmed: ${unconfirmed}")
	fi
	return 0
}

# istio_version_kv: the Istio version keys every preamble writer records (PL36), as
# KEY=value lines: ISTIO_VERSION, ISTIO_VERSION_PIN, ISTIO_VERSION_SOURCE (pin when
# nothing resolved them: the value is then the pin, unchecked) and
# ISTIO_VERSION_BY_CONTEXT (ctx=version,...; unchecked when nothing was read).
# shellcheck disable=SC2329
istio_version_kv() {
	echo "ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
	echo "ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN:-${ISTIO_VERSION:-unknown}}"
	echo "ISTIO_VERSION_SOURCE=${ISTIO_VERSION_SOURCE:-pin}"
	echo "ISTIO_VERSION_BY_CONTEXT=${ISTIO_VERSION_BY_CONTEXT:-unchecked}"
}

# istio_version_label: ISTIO_VERSION for people (console lines, per-run markdown rows):
# "v1.30.5 (read live on every member; pin v1.30.5)", "unknown (not read on every
# member; pin ...)", "mixed:a/b (the members differ or were not all read; pin ...)", or
# "v1.30.5 (the pin; not read live)".
# shellcheck disable=SC2329
istio_version_label() {
	local v="${ISTIO_VERSION:-unknown}" pin="${ISTIO_VERSION_PIN:-unknown}"
	if [[ "${ISTIO_VERSION_SOURCE:-pin}" != live ]]; then
		echo "${v} (the pin; not read live)"
	elif [[ "$v" == unknown ]]; then
		echo "unknown (not read on every member; pin ${pin})"
	elif [[ "$v" == mixed:* ]]; then
		echo "${v} (the members differ or were not all read; pin ${pin})"
	else
		echo "${v} (read live on every member; pin ${pin})"
	fi
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
		DISCOVERY_LABEL LEFTOVER_TEST_NAMESPACES LEFTOVER_NS_WARN
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
		istio_version_kv | sed 's/^/# /'
		echo "# APPLY_CHUNK_OBJECTS=${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-unknown}"
		echo "# APPLY_ATTEMPTS=${CONTROLPLANE_APPLY_ATTEMPTS:-unknown}"
		echo "# NS_DELETE_TIMEOUT_SEC=${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-unknown}"
		echo "# NOTE=001 runs its applies and Sidecar deletes at kubectl -v=4. api_429_retried counts client-go's 'Got a Retry-After response' lines (a 429 with Retry-After that client-go retried; at the default verbosity it prints nothing); api_429_exhausted counts TooManyRequests errors that reached kubectl after its retries; client_throttle_waits counts client-side rate-limiter waits over 50 ms (kubectl 1.34 showed none on server-side apply). N/A = not measured (readiness waits and 005's deletes). leftover-check rows (003, one per context at each series start): namespaces = the controlplane-test namespaces present, objects = how many of them are still discovered, status LEFTOVER above CONTROLPLANE_LEFTOVER_NS_WARN."
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
