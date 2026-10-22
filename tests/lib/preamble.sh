#!/usr/bin/env bash
# Harness metadata and TSV preamble helpers. Sourced, never executed.
#
# Consumers: controlplane, dataplane, propagation, churn, churn-dataplane, gateway-api (001:
# harness_sha, probe_kube_versions, tuning_baseline_state per member)
#
# Exposes:
#   harness_sha (in tests/lib/common.sh)          -> `git -C "${ROOT:-.}" describe --always --abbrev=7`,
#       with `-dirty` for uncommitted changes under tests/, config/, charts/ and terraform/
#       (submodules never count), or "unknown"
#   kube_versions <ctx> <kubectl_argv...>          -> kubectl server gitVersion, "unreachable"/"unknown" semantics
#   probe_kube_versions <ctxs_csv> <kubectl_argv...>
#                                                  -> CSV of ctx=ver pairs, PLATFORM_READ_PARALLEL
#                                                     at a time, each with a 5s timeout (PL2)
#   tuning_baseline_state <ctx> <kubectl_argv...>  -> two lines (TUNING_BASELINE=, SIDECAR_EGRESS_HOSTS=)
#                                                     queried from the LIVE mesh, on|off|unknown (PL2)
#   istio_live_version <ctx> <kubectl_argv...>     -> version|revision|cr_gen|rev_gen|ready|why:
#       the version the member RUNS (its active IstioRevision's), bounded reads, never a guess
#   istio_version_resolve [--no-stop] <ctxs_csv> <dry_run> <kubectl_argv...>
#                                                  -> PL39: read and check it on every member
#       once per run (ISTIO_VERSION_CHECK=fail dies, warn warns) and export what the results
#       record; a no-op in a step whose sweep already read it
#   istio_version_recheck [--no-generations] <kubectl_argv...>
#                                                  -> read it again at a sweep's end:
#       sweep_problem on a version, revision or generation change, sweep_note when unconfirmed
#   istio_generations_read <ctxs_csv> <kubectl_argv...> / istio_generations_diff <before> <after>
#                                                  -> ctx=<Istio CR gen>/<IstioRevision gen>,...
#       read now, and the members whose generations moved (tuning 001 and 002)
#   istio_version_kv                               -> the ISTIO_VERSION* lines of every preamble
#       (and ISTIO_ACTIVE_REVISIONS, ISTIO_GENERATIONS; PL36)
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
#       (NODE_ALLOC_CPU_M/NODE_ALLOC_MEM_MI) already emits them; single-source per key.
#   growth_preamble_lines <kv...>                  -> emit the controlplane namespace-scaling
#       `# KEY=value` block (SERVICES_PER_NAMESPACE, GROWTH_MODE, WORKLOAD_MODE, ...).
#       ONE shared emitter for 003's pre-create and 002's standalone preamble (PL36);
#       an omitted key reads `unknown`.
#   ns_lifecycle_init <file> <run_id> <ctxs_csv>  -> create the namespace-lifecycle TSV
#       (preamble + header) if it does not exist yet; 001, 003 and 005 all call it (PL36)
#   ns_lifecycle_row <file> <ctx> <series> <n> <action> <namespaces> <objects> <seconds>
#                    <api_429_retried> <api_429_exhausted> <client_throttle_waits> <status>
#                                                  -> append one row, with objects/s and
#       namespaces/s derived from <seconds> (N/A when <seconds> is not > 0)
#   ns_lifecycle_api_counts <stderr_file>         -> "<retried> <exhausted> <throttle_waits>"
#       from the stderr of a `kubectl -v=4` call (see the function)
#
# Requires: tests/lib/common.sh (die, split_csv, is_nonneg_int, each_bounded, sweep_problem,
# sweep_note)
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# harness_sha: tests/lib/common.sh (every sweep reads it, and not every sweep sources this
# file).

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
	if out="$("$@" --context="$ctx" --request-timeout=5s version --output=json 2>/dev/null)"; then rc=0; else rc=$?; fi
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

# _kube_versions_one <ctx> <dir>: <ctx>'s kube_versions with the kubectl argv of the
# probe_kube_versions call it runs under (_pkv_argv, dynamic scope), for each_bounded.
# shellcheck disable=SC2329
_kube_versions_one() {
	kube_versions "$1" "${_pkv_argv[@]}"
}

# Probe of multiple contexts, PLATFORM_READ_PARALLEL at a time (each_bounded,
# tests/lib/common.sh). Returns ctx1=ver1,ctx2=ver2,... in the given order; a member whose read
# left no answer at all (no temp dir, say) reads unknown.
# Usage: probe_kube_versions "$ctxs_csv" <kubectl_argv...>
# shellcheck disable=SC2329
probe_kube_versions() {
	local ctxs_csv="$1"
	shift
	local -a ctxs=() _pkv_argv=("$@")
	split_csv "$ctxs_csv" ctxs
	local tmp="" i v out=""
	tmp="$(mktemp -d 2>/dev/null)" || tmp=""
	[[ -z "$tmp" ]] || each_bounded "${PLATFORM_READ_PARALLEL:-20}" _kube_versions_one "$tmp" ${ctxs[@]+"${ctxs[@]}"}
	for i in "${!ctxs[@]}"; do
		v=""
		[[ -z "$tmp" ]] || v="$(head -n 1 "${tmp}/${i}.row" 2>/dev/null || true)"
		out+="${out:+,}${ctxs[i]}=${v:-unknown}"
	done
	[[ -z "$tmp" ]] || rm -rf "$tmp"
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
	# NODE_ALLOC_* intentionally excluded — emitted by the O9 capacity block.
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
		if out="$("${k[@]}" --context="$ctx" --request-timeout=5s -n istio-system \
			get "$kind" "$name" -o name --ignore-not-found 2>/dev/null)"; then rc=0; else rc=$?; fi
		if ((rc != 0)); then printf 'unknown\n'; return 0; fi
		if [[ -n "$out" ]]; then printf 'on\n'; else printf 'off\n'; fi
	}

	sidecar="$(_tb_exists sidecar.networking.istio.io default)"
	telem="$(_tb_exists telemetry.telemetry.istio.io tuning-metrics)"
	alog="$(_tb_exists telemetry.telemetry.istio.io tuning-access-log)"

	# discoverySelectors live on the Istio CR's meshConfig.
	local dsout dsrc
	if dsout="$("${k[@]}" --context="$ctx" --request-timeout=5s \
		get istio.sailoperator.io default \
		-o jsonpath='{.spec.values.meshConfig.discoverySelectors}' 2>/dev/null)"; then dsrc=0; else dsrc=$?; fi
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
		if hout="$("${k[@]}" --context="$ctx" --request-timeout=5s -n istio-system \
			get sidecar.networking.istio.io default \
			-o jsonpath='{.spec.egress[*].hosts[*]}' 2>/dev/null)"; then hrc=0; else hrc=$?; fi
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

# The Istio version the members run (PL39): the results record the version every member
# RUNS, never only the config/versions.env pin (an existing cluster, a bumped istioVersion or
# an ISTIO_VERSION left in the shell makes the pin wrong).

# istio_live_version <ctx> <kubectl_argv...>: one line version|revision|cr_generation|
# rev_generation|ready|why (unknown for a part not read; ready yes or no; why a short
# phrase). Each read is bounded (--request-timeout=5s); one that fails leaves the version
# unknown, kubectl's first stderr line on the console only (it can name the API host). The
# version is the active IstioRevision's .spec.version (exact, ^v?N.N.N$: the Istio CR's can be
# an alias). Ready: state Healthy, one revision in use, both generations observed, and that
# revision's istiod Deployment rolled out with no pod terminating (Sail's Healthy counts
# ready pods only, so old pods can still serve).
# shellcheck disable=SC2329
istio_live_version() {
	local ctx="$1" out gen ogen state inuse rev ver rgen rogen rns rvrev dep dgen dogen dreps dupd dterm
	local why="" nr="" ready=yes j='map(. // "" | tostring | gsub("[|\r\n]"; "?")) | join("|")'
	shift
	local -a _ilv_k=("$@")
	out="$(_istio_read "$ctx" "[.metadata.generation, .status.observedGeneration, .status.state, .status.revisions.inUse, .status.activeRevisionName] | ${j}" get istios.sailoperator.io default)" \
		|| { echo "unknown|unknown|unknown|unknown|no|the Istio CR could not be read (${out})"; return 0; }
	IFS='|' read -r gen ogen state inuse rev <<<"$out"
	[[ -n "$rev" ]] || { echo "unknown|unknown|${gen:-unknown}|unknown|no|the Istio CR names no active revision"; return 0; }
	out="$(_istio_read "$ctx" "[.spec.version, .metadata.generation, .status.observedGeneration, .spec.namespace, .spec.values.revision] | ${j}" get istiorevisions.sailoperator.io "$rev")" \
		|| { echo "unknown|${rev}|${gen:-unknown}|unknown|no|the IstioRevision ${rev} could not be read (${out})"; return 0; }
	IFS='|' read -r ver rgen rogen rns rvrev <<<"$out"
	if [[ ! "$ver" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		why="the IstioRevision ${rev} names no exact version (${ver:0:40})"
		ver=unknown
	fi
	if [[ "$state" != Healthy ]]; then
		nr="Istio CR state is ${state:-not set}"
	elif [[ "$inuse" =~ ^[0-9]+$ ]] && ((inuse > 1)); then
		nr="a revision migration is in progress"
	elif [[ "$ogen" != "$gen" || "$rogen" != "$rgen" ]]; then
		nr="the Istio CR or its IstioRevision is not reconciled yet"
	else
		rns="${rns:-istio-system}" dep="istiod${rvrev:+-${rvrev}}"
		out="$(_istio_read "$ctx" '[.metadata.generation, .status.observedGeneration, .status.replicas, .status.updatedReplicas, .status.terminatingReplicas] | map(. // 0 | tostring) | join("|")' -n "$rns" get deployments.apps "$dep")" \
			|| { echo "unknown|${rev}|${gen}|${rgen}|no|the istiod Deployment ${rns}/${dep} could not be read (${out})"; return 0; }
		IFS='|' read -r dgen dogen dreps dupd dterm <<<"$out"
		if [[ ! "${dgen}|${dogen}|${dreps}|${dupd}|${dterm}" =~ ^[0-9]+(\|[0-9]+){4}$ ]] || ((dogen < dgen || dupd != dreps || dterm > 0)); then
			nr="istiod is rolling out (${dupd} of ${dreps} pods updated"
			[[ "$dterm" == 0 ]] || nr+=", ${dterm} terminating"
			nr+=")"
		fi
	fi
	[[ -z "$nr" ]] || ready=no why="${why}${why:+; }${nr}"
	printf '%s|%s|%s|%s|%s|%s\n' "$ver" "$rev" "${gen:-unknown}" "${rgen:-unknown}" "$ready" "$why"
}

# _istio_read <ctx> <jq_filter> <kubectl_args...>: one read of istio_live_version (its kubectl
# argv _ilv_k, dynamic scope): the fields <jq_filter> joins with |. A failed one prints what
# failed instead and returns 1, kubectl's first stderr line on stderr.
# shellcheck disable=SC2329
_istio_read() {
	local ctx="$1" filter="$2" out rc=0 err
	shift 2
	err="$(mktemp 2>/dev/null)" || { echo "no temp file"; return 1; }
	out="$("${_ilv_k[@]}" --context="$ctx" --request-timeout=5s "$@" -o json 2>"$err")" || rc=$?
	if ((rc == 0)) && out="$(jq -r "$filter" <<<"$out" 2>/dev/null)" && [[ "$out" == *"|"* ]]; then
		rm -f "$err"
		printf '%s\n' "$out"
		return 0
	fi
	echo "warning: ${ctx}: kubectl $* failed (exit ${rc}): $(head -n 1 "$err" | tr -d '\r')" >&2
	rm -f "$err"
	if ((rc)); then echo "kubectl exit ${rc}"; else echo "its answer is not the JSON expected"; fi
	return 1
}

# _istio_read_all <ctxs_csv> <kubectl_argv...>: istio_live_version on every member,
# PLATFORM_READ_PARALLEL at a time (each_bounded), one line each in <ctxs_csv> order (empty
# for a member that left none: its callers read it as unknown), warnings on stderr.
# shellcheck disable=SC2329
_istio_read_all() {
	local -a _ira_ctxs=() _ira_k=("${@:2}")
	local tmp i
	split_csv "$1" _ira_ctxs
	tmp="$(mktemp -d 2>/dev/null)" || return 0
	each_bounded "${PLATFORM_READ_PARALLEL:-20}" _istio_read_one "$tmp" ${_ira_ctxs[@]+"${_ira_ctxs[@]}"}
	for i in "${!_ira_ctxs[@]}"; do
		cat "${tmp}/${i}.warn" >&2 2>/dev/null || true
		printf '%s\n' "$(head -n 1 "${tmp}/${i}.row" 2>/dev/null || true)"
	done
	rm -rf "$tmp"
}

# For each_bounded (<ctx> <dir>): one member's read, its temp files in <dir>; one member's
# kubectl wait for its Istio CR's Ready condition, until _iwr_end (SECONDS).
# shellcheck disable=SC2329
_istio_read_one() { TMPDIR="$2" istio_live_version "$1" "${_ira_k[@]}"; }
# shellcheck disable=SC2329
_istio_wait_one() {
	local left=$((_iwr_end - SECONDS))
	((left > 0)) || left=0
	"${_ira_k[@]}" --context="$1" wait --for=condition=Ready istios.sailoperator.io/default --timeout="${left}s" >/dev/null 2>&1 || true
}

# istio_version_resolve [--no-stop] <ctxs_csv> <dry_run 0|1> <kubectl_argv...>: read and check
# the version every member runs, once per run (a sweep's steps reuse its read:
# _ISTIO_VERSION_RESOLVED=1), before any change; dry_run 1 reads nothing (the pin, the other
# keys unchecked). Members not ready get one kubectl wait for their Istio CR's Ready condition
# (ISTIO_VERSION_READY_WAIT_SEC in all) and one more read. A member unknown or still not
# ready, members that differ, or a version not the pin (a leading v aside) fail the check:
# ISTIO_VERSION_CHECK=fail (the default) dies naming each; warn (always under --no-stop, for
# a read-only check) warns, records the live value and makes each finding a sweep_note (call
# it before sweep_start). Exports what istio_version_kv prints.
# shellcheck disable=SC2329
istio_version_resolve() {
	local nostop=0
	[[ "${1:-}" != --no-stop ]] || { nostop=1; shift; }
	local ctxs_csv="$1" dry="$2" policy="${ISTIO_VERSION_CHECK:-fail}" wait_sec="${ISTIO_VERSION_READY_WAIT_SEC:-60}"
	shift 2
	[[ "$policy" == fail || "$policy" == warn ]] || die "ISTIO_VERSION_CHECK must be fail or warn (got: ${policy})"
	is_nonneg_int "$wait_sec" || die "ISTIO_VERSION_READY_WAIT_SEC must be a non-negative integer of seconds (got: ${wait_sec})"
	[[ "${_ISTIO_VERSION_RESOLVED:-}" != 1 ]] || return 0
	((nostop == 0)) || policy=warn
	export ISTIO_VERSION_PIN="${ISTIO_VERSION:-unknown}" _ISTIO_VERSION_RESOLVED=1
	if ((dry)); then
		export ISTIO_VERSION_SOURCE=pin ISTIO_VERSION_BY_CONTEXT=unchecked ISTIO_ACTIVE_REVISIONS=unchecked \
			ISTIO_GENERATIONS=unchecked ISTIO_VERSION="$ISTIO_VERSION_PIN"
		return 0
	fi
	{ (($#)) && command -v "$1" >/dev/null 2>&1; } || die "neither kubectl nor oc found on PATH, so the live Istio version cannot be read"
	local -a ivr_ctxs=() ivr_lines=() ivr_again=() ivr_wctxs=() ivr_relines=() ivr_bad=() _ira_k=("$@")
	local i n=0 v rev cg rg ready why tmp csv="" by="" revs="" gens="" seen="/" live="" known="" how _iwr_end
	split_csv "$ctxs_csv" ivr_ctxs
	((${#ivr_ctxs[@]})) || die "istio_version_resolve: no mesh member contexts"
	mapfile -t ivr_lines < <(_istio_read_all "$ctxs_csv" "$@")
	for i in "${!ivr_ctxs[@]}"; do
		IFS='|' read -r _ _ _ _ ready _ <<<"${ivr_lines[i]:-}"
		[[ "$ready" == yes ]] || { ivr_again+=("$i"); ivr_wctxs+=("${ivr_ctxs[i]}"); }
	done
	if ((${#ivr_again[@]} && wait_sec > 0)); then
		echo "Istio: waiting up to ${wait_sec}s (ISTIO_VERSION_READY_WAIT_SEC) for ${#ivr_again[@]} member(s) not ready" >&2
		_iwr_end=$((SECONDS + wait_sec))
		if tmp="$(mktemp -d 2>/dev/null)"; then
			each_bounded "${PLATFORM_READ_PARALLEL:-20}" _istio_wait_one "$tmp" "${ivr_wctxs[@]}"
			rm -rf "$tmp"
		fi
		csv="$(IFS=,; echo "${ivr_wctxs[*]}")"
		mapfile -t ivr_relines < <(_istio_read_all "$csv" "$@")
		for i in "${ivr_again[@]}"; do
			ivr_lines[i]="${ivr_relines[n]:-}"
			n=$((n + 1))
		done
	fi
	for i in "${!ivr_ctxs[@]}"; do
		IFS='|' read -r v rev cg rg ready why <<<"${ivr_lines[i]:-}"
		v="${v:-unknown}"
		by+="${by:+,}${ivr_ctxs[i]}=${v}" revs+="${revs:+,}${ivr_ctxs[i]}=${rev:-unknown}"
		gens+="${gens:+,}${ivr_ctxs[i]}=${cg:-unknown}/${rg:-unknown}"
		if [[ "$seen" != */"$v"/* ]]; then
			seen+="${v}/" live+="${live:+/}${v}"
			[[ "$v" == unknown ]] || known+="${known:+/}${v}"
		fi
		if [[ "$v" == unknown ]]; then
			ivr_bad+=("${ivr_ctxs[i]}: the version it runs is unknown: ${why:-not read}")
		elif [[ "$ready" != yes ]]; then
			ivr_bad+=("${ivr_ctxs[i]}: not ready (${why:-not read}) after a wait of up to ${wait_sec}s")
		fi
	done
	[[ "$live" != */* ]] || live="mixed:${live}"
	if [[ "$known" == */* ]]; then
		ivr_bad+=("the members run different Istio versions (${by})")
	elif [[ -n "$known" && "${known#v}" != "${ISTIO_VERSION_PIN#v}" ]]; then
		ivr_bad+=("the members run Istio ${known}, not the pin ISTIO_VERSION=${ISTIO_VERSION_PIN} (after an upgrade, bump it in config/versions.env with charts/spoke-ossm istioVersion; or unset an ISTIO_VERSION left in the shell)")
	fi
	export ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT="$by" ISTIO_ACTIVE_REVISIONS="$revs" \
		ISTIO_GENERATIONS="$gens" ISTIO_VERSION="$live"
	((${#ivr_bad[@]})) || return 0
	why="the Istio version check failed:$(printf '\n  %s' "${ivr_bad[@]}")"$'\n'"Check a member with: kubectl --context <ctx> get istios.sailoperator.io default -o yaml"
	[[ "$policy" == warn ]] || die "${why}"$'\n'"Nothing was changed. ISTIO_VERSION_CHECK=warn goes on anyway, and records ISTIO_VERSION=${live}."
	how="ISTIO_VERSION_CHECK=warn"
	((nostop == 0)) || how="a read-only check never stops on this"
	echo "warning: ${why}"$'\n'"Going on (${how}): the results record ISTIO_VERSION=${live} (pin ${ISTIO_VERSION_PIN})." >&2
	for why in "${ivr_bad[@]}"; do sweep_note "Istio version check at the start: ${why}"; done
}

# istio_version_recheck [--no-generations] <kubectl_argv...>: at a sweep's end (after its last
# step, before sweep_finish) read every member again; nothing when the start was not read
# live. Read-only, never dies. Another version or active revision is a sweep_problem, and so
# are generations that moved (an edit of the Istio CR, or Sail rendering it again; not
# compared under --no-generations: tuning's profiles edit it); a member not confirmed, or not
# ready at the end, is a sweep_note.
# shellcheck disable=SC2329
istio_version_recheck() {
	local gens=1 by="${ISTIO_VERSION_BY_CONTEXT:-}" revs="${ISTIO_ACTIVE_REVISIONS:-}" gs="${ISTIO_GENERATIONS:-}"
	[[ "${1:-}" != --no-generations ]] || { gens=0; shift; }
	[[ "${ISTIO_VERSION_SOURCE:-}" == live ]] || return 0
	local -a ivrc_ctxs=() ivrc_lines=() ivrc_pairs=()
	local p ctx i v rev cg rg ready why was was_rev was_gen
	split_csv "$by" ivrc_pairs
	for p in ${ivrc_pairs[@]+"${ivrc_pairs[@]}"}; do ivrc_ctxs+=("${p%=*}"); done
	((${#ivrc_ctxs[@]})) || return 0
	mapfile -t ivrc_lines < <(_istio_read_all "$(IFS=,; echo "${ivrc_ctxs[*]}")" "$@")
	for i in "${!ivrc_ctxs[@]}"; do
		ctx="${ivrc_ctxs[i]}"
		IFS='|' read -r v rev cg rg ready why <<<"${ivrc_lines[i]:-}"
		was="$(kv_value "$ctx" "${by//,/ }")" was_rev="$(kv_value "$ctx" "${revs//,/ }")" was_gen="$(kv_value "$ctx" "${gs//,/ }")"
		if [[ "$was" == unknown || "${v:-unknown}" == unknown ]]; then
			[[ "$was" != unknown ]] || why="it was unknown at the start"
			sweep_note "could not confirm that ${ctx} ran one Istio version during the sweep: ${why:-not read}"
		elif [[ "$v" != "$was" || "$rev" != "$was_rev" ]]; then
			sweep_problem "${ctx} ran ${was} (revision ${was_rev}) at the start and ${v} (revision ${rev}) at the end: its rows are not all from one Istio version"
		elif ((gens)) && [[ "$was_gen" =~ ^[0-9]+/[0-9]+$ && "${cg}/${rg}" =~ ^[0-9]+/[0-9]+$ && "$was_gen" != "${cg}/${rg}" ]]; then
			sweep_problem "the Istio CR or its active IstioRevision on ${ctx} changed during the sweep (generations ${was_gen} -> ${cg}/${rg}): an edit of the Istio CR or Sail rendering it again; rows after it may measure another configuration"
		elif [[ "$ready" != yes ]]; then
			sweep_note "${ctx} was not ready at the end of the sweep: ${why}"
		fi
	done
}

# istio_generations_read <ctxs_csv> <kubectl_argv...>: ctx=<Istio CR generation>/<active
# IstioRevision generation>,... read now (unknown for a part not read), as ISTIO_GENERATIONS
# records them (tuning 001 and 002). Never dies.
# shellcheck disable=SC2329
istio_generations_read() {
	local -a igr_ctxs=() igr_lines=()
	local i cg rg out=""
	split_csv "$1" igr_ctxs
	mapfile -t igr_lines < <(_istio_read_all "$@")
	for i in "${!igr_ctxs[@]}"; do
		IFS='|' read -r _ _ cg rg _ _ <<<"${igr_lines[i]:-}"
		out+="${out:+,}${igr_ctxs[i]}=${cg:-unknown}/${rg:-unknown}"
	done
	printf '%s\n' "$out"
}

# istio_generations_diff <before> <after>: the members whose generations moved between two
# istio_generations_read lines, as "<ctx> (<a> -> <b>), ..."; nothing when none did. A member
# with a part unknown on either side is not compared.
# shellcheck disable=SC2329
istio_generations_diff() {
	local -a igd_af=()
	local p g out=""
	split_csv "$2" igd_af
	for p in ${igd_af[@]+"${igd_af[@]}"}; do
		g="$(kv_value "${p%=*}" "${1//,/ }")"
		[[ "$g" =~ ^[0-9]+/[0-9]+$ && "${p##*=}" =~ ^[0-9]+/[0-9]+$ && "$g" != "${p##*=}" ]] || continue
		out+="${out:+, }${p%=*} (${g} -> ${p##*=})"
	done
	[[ -z "$out" ]] || printf '%s\n' "$out"
}

# istio_version_kv: the lines every preamble writer records (PL36): ISTIO_VERSION,
# ISTIO_VERSION_PIN, ISTIO_VERSION_SOURCE, then ISTIO_VERSION_BY_CONTEXT, ISTIO_ACTIVE_REVISIONS
# and ISTIO_GENERATIONS (ctx=<value>,...), these three unchecked when not read live.
# shellcheck disable=SC2329
istio_version_kv() {
	local by=unchecked revs=unchecked gens=unchecked
	if [[ "${ISTIO_VERSION_SOURCE:-pin}" == live ]]; then
		by="${ISTIO_VERSION_BY_CONTEXT:-unknown}" revs="${ISTIO_ACTIVE_REVISIONS:-unknown}" gens="${ISTIO_GENERATIONS:-unknown}"
	fi
	echo "ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
	echo "ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN:-${ISTIO_VERSION:-unknown}}"
	echo "ISTIO_VERSION_SOURCE=${ISTIO_VERSION_SOURCE:-pin}"
	echo "ISTIO_VERSION_BY_CONTEXT=${by}"
	echo "ISTIO_ACTIVE_REVISIONS=${revs}"
	echo "ISTIO_GENERATIONS=${gens}"
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

# ns_lifecycle_init <file> <run_id> <ctxs_csv>: write the PL2 preamble and the header once. A
# no-op when the file exists (the first writer wins; every writer uses this function).
# The preamble carries the run config and the platform record of <ctxs_csv> (platform_probe
# read it: a sweep's, or the one a standalone 001 or 005 reads when it creates the file); the
# caller sources tests/lib/config.sh and tests/lib/platform.sh.
# shellcheck disable=SC2329
ns_lifecycle_init() {
	local file="$1" run_id="${2:-unknown}" nsl_ctxs="${3:-}" dir hs
	[[ -n "$file" ]] || return 0
	declare -F config_preamble_lines >/dev/null || die "ns_lifecycle_init needs config_preamble_lines (source tests/lib/config.sh)"
	declare -F platform_preamble_lines >/dev/null || die "ns_lifecycle_init needs platform_preamble_lines (source tests/lib/platform.sh)"
	[[ -f "$file" ]] && return 0
	dir="$(dirname "$file")"
	mkdir -p "$dir"
	# The harness without the results dir this file lives in (they would read dirty).
	hs="$(harness_sha --exclude "$dir")"
	{
		echo "# Namespace lifecycle (controlplane growth mode) — $(date -u -Iseconds)"
		echo "# NS_LIFECYCLE_SCHEMA=2"
		echo "# RUN_ID=${run_id}"
		echo "# HARNESS_SHA=${hs}"
		istio_version_kv | sed 's/^/# /'
		echo "# APPLY_CHUNK_OBJECTS=${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-unknown}"
		echo "# APPLY_ATTEMPTS=${CONTROLPLANE_APPLY_ATTEMPTS:-unknown}"
		echo "# NS_DELETE_TIMEOUT_SEC=${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-unknown}"
		config_preamble_lines
		platform_preamble_lines "$nsl_ctxs"
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
