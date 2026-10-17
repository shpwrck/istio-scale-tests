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

# _istio_version_errline <file>: the first line of kubectl's stderr, as a why: without a
# carriage return, without the klog prefix (M5: "E1017 10:00:00.000000   12345
# memcache.go:265] ", different in every process, so members that fail alike group
# together), at most 200 characters.
_istio_version_errline() {
	head -n 1 "$1" | tr -d '\r' | sed -E 's/^[IWEF][0-9]{4} [0-9:.]+ +[0-9]+ [^]]+\] //' | cut -c 1-200
}

# istio_live_version <ctx> <kubectl_argv...>: the Istio version a mesh member RUNS, as
# six lines: the version (or unknown), a kind, why (empty when ok), the Istio CR's
# .status.activeRevisionName (empty when not read), that revision's .spec.version as read
# (empty when not read or not an exact version; read even when the CR is not settled, so
# that istio_version_recheck can compare it) and the CR's .status.state. Never a guess.
# Each read is bounded by --request-timeout=5s:
#   1. The Sail Istio CR `default` (-o json). Its revision is settled when
#      .status.observedGeneration equals .metadata.generation, at most one revision is in
#      use (.status.revisions.inUse > 1 is a revision migration in progress), it names an
#      .status.activeRevisionName (`default` under InPlace, `default-v1-30-5` under
#      RevisionBased), and .status.state is Healthy or its Reconciled condition is True.
#      .status.state is readiness, not the version (Sail takes it from the first condition
#      of Reconciled, Ready, DependenciesHealthy that is not True: an istiod pod restarting,
#      an IstioCNI pod starting on a new node). Not settled: kind migrating (inUse > 1) or
#      state (anything else), version unknown.
#   2. That IstioRevision (-o json). Its .spec.version is the exact version it runs (the
#      Istio CR's .spec.version is what was requested, and can be an alias such as
#      v1.30-latest); only ^v?N.N.N$ counts, anything else is kind value. Its
#      .status.observedGeneration must equal its .metadata.generation, else kind state (Sail
#      copies a revision's state into the CR before the revision's own Helm upgrade runs).
#   3. The istiod Deployment Sail runs for that revision (its istiodDeploymentKey:
#      `istiod`, or `istiod-<.spec.values.revision>` when that is set, in the revision's
#      .spec.namespace), also when the state is Healthy (J3: Sail's Ready only compares
#      readyReplicas with replicas, so a Deployment whose status has not moved yet, or
#      whose old ReplicaSet is not scaled down yet, still serves old pods).
#      .status.observedGeneration below .metadata.generation, .status.updatedReplicas
#      below .status.replicas, or .status.terminatingReplicas above 0 (K12; absent on an
#      API server without it) is an istiod rollout in progress, old and new pods both
#      serving (I2): kind rolling, with the version it rolls out to (its why starts "istiod
#      pods still terminating" when every pod is updated and old ones are still
#      terminating). Otherwise kind ok when
#      the state is Healthy, else notready (a pod restart, an HPA scale-up, IstioCNI not
#      healthy): the version, with the state as why.
# Kind read: kubectl failed or answered nothing (no CR, no access, unreachable); the
# reason is the first line of its stderr, and a caller may retry it. A failed Deployment
# read still returns the revision's version (line 5), for istio_version_recheck (J1). A CR
# that is not settled and whose IstioRevision read failed is kind read too (K1: its why
# names the revision), unless it is migrating; so is a settled CR whose IstioRevision read
# failed (its why starts "IstioRevision <rev>: ").
# shellcheck disable=SC2329
istio_live_version() {
	local ctx="$1" errf out rc=0 gen ogen state inuse rev recon why="" kind=state ready="" rerr
	local rver="" rv="" rns="" rvrev="" rgen="" rogen="" dep dgen dogen dreps dupd dterm
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
		why="$(_istio_version_errline "$errf")"
		rm -f "$errf"
		printf 'unknown\nread\n%s\n\n\n\n' "${why:-kubectl exited ${rc} with no output}"
		return 0
	fi
	IFS='|' read -r gen ogen state inuse rev recon <<<"$out"
	[[ "$rev" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || rev=""
	state="${state//[^A-Za-z0-9._-]/?}"
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
	# The active revision, one JSON read: version|namespace|values.revision|generation|observedGeneration.
	if [[ -n "$rev" ]]; then
		rc=0
		out="$("$@" --context="$ctx" --request-timeout=5s get istiorevisions.sailoperator.io "$rev" -o json 2>"$errf")" || rc=$?
		if ((rc == 0)) && [[ -n "$out" ]]; then
			out="$(jq -r '[.spec.version, .spec.namespace, .spec.values.revision, .metadata.generation, .status.observedGeneration]
				| map(. // "" | tostring | gsub("[|\r\n]"; "?")) | join("|")' <<<"$out" 2>/dev/null)" || rc=1
			[[ "$out" == *"|"* ]] || { rc=1; echo "the read did not return JSON" > "$errf"; }
		fi
		if ((rc == 0)) && [[ -n "$out" ]]; then
			IFS='|' read -r rv rns rvrev rgen rogen <<<"$out"
			[[ ! "$rv" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || rver="$rv"
		else
			rc=1
		fi
	fi
	if [[ -n "$why" ]]; then
		if ((rc != 0)); then
			# K1: its IstioRevision could not be read either. Say so, and (but for a
			# migration, which is a problem whatever the revision reads) make it a failed
			# read, retried once, so a transient error does not hide the revision's version.
			rerr="$(_istio_version_errline "$errf")"
			why="${why}; IstioRevision ${rev}: ${rerr:-kubectl answered nothing}"
			[[ "$kind" != state ]] || kind="read"
		fi
		rm -f "$errf"
		printf 'unknown\n%s\nthe Istio CR default is not settled: %s\n%s\n%s\n%s\n' "$kind" "$why" "$rev" "$rver" "$state"
		return 0
	fi
	if ((rc != 0)); then
		# L3: the why names the read that failed (the CR answered).
		why="$(_istio_version_errline "$errf")"
		rm -f "$errf"
		printf 'unknown\nread\nIstioRevision %s: %s\n%s\n\n%s\n' "$rev" "${why:-kubectl answered nothing}" "$rev" "$state"
		return 0
	fi
	if [[ -z "$rver" ]]; then
		rm -f "$errf"
		rv="${rv//[^A-Za-z0-9._+-]/?}"
		printf 'unknown\nvalue\nIstioRevision %s .spec.version is %s, not an exact version\n%s\n\n%s\n' "$rev" "${rv:0:60}" "$rev" "$state"
		return 0
	fi
	if [[ "$rogen" != "$rgen" ]]; then
		rm -f "$errf"
		printf 'unknown\nstate\nthe IstioRevision %s is not settled: generation %s is not reconciled yet (observedGeneration %s)\n%s\n%s\n%s\n' \
			"$rev" "${rgen:-?}" "${rogen:-none}" "$rev" "$rver" "$state"
		return 0
	fi
	# I2/J3: an istiod rollout in progress is neither Healthy nor "only readiness".
	dep="istiod${rvrev:+-${rvrev}}"
	rns="${rns:-istio-system}"
	if [[ ! "$dep" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ || ! "$rns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
		rm -f "$errf"
		dep="${dep//[^A-Za-z0-9._-]/?}" rns="${rns//[^A-Za-z0-9._-]/?}"
		printf 'unknown\nvalue\nIstioRevision %s names no valid istiod Deployment (%s in namespace %s)\n%s\n%s\n%s\n' \
			"$rev" "${dep:0:60}" "${rns:0:60}" "$rev" "$rver" "$state"
		return 0
	fi
	rc=0
	out="$("$@" --context="$ctx" --request-timeout=5s -n "$rns" get deployments.apps "$dep" -o json 2>"$errf")" || rc=$?
	if ((rc == 0)) && [[ -n "$out" ]]; then
		out="$(jq -r '[.metadata.generation, .status.observedGeneration, .status.replicas, .status.updatedReplicas,
				.status.terminatingReplicas] | map(. // 0 | tostring) | join("|")' <<<"$out" 2>/dev/null)" || rc=1
		[[ "$out" =~ ^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$ ]] || { rc=1; echo "the read did not return JSON" > "$errf"; }
	else
		rc=1
	fi
	if ((rc != 0)); then
		why="$(_istio_version_errline "$errf")"
		rm -f "$errf"
		printf 'unknown\nread\nistiod Deployment %s/%s: %s\n%s\n%s\n%s\n' "$rns" "$dep" "${why:-kubectl answered nothing}" "$rev" "$rver" "$state"
		return 0
	fi
	rm -f "$errf"
	IFS='|' read -r dgen dogen dreps dupd dterm <<<"$out"
	if ((dogen < dgen || dupd < dreps || dterm > 0)); then
		why="istiod is rolling out ${rver} (Deployment ${rns}/${dep}: ${dupd} of ${dreps} pods updated"
		# L3: every pod updated, only old pods still terminating: say that, not "rolling out".
		((dogen < dgen || dupd < dreps)) || why="istiod pods still terminating after the rollout to ${rver} (Deployment ${rns}/${dep}: ${dupd} of ${dreps} pods updated"
		((dogen >= dgen)) || why+=", generation ${dgen} not observed yet"
		((dterm == 0)) || why+=", ${dterm} terminating"
		printf '%s\nrolling\n%s); its state is %s\n%s\n%s\n%s\n' "$rver" "$why" "$state" "$rev" "$rver" "$state"
	elif [[ -z "$ready" ]]; then
		printf '%s\nok\n\n%s\n%s\n%s\n' "$rver" "$rev" "$rver" "$state"
	else
		printf '%s\nnotready\n%s\n%s\n%s\n%s\n' "$rver" "$ready" "$rev" "$rver" "$state"
	fi
}

# _istio_version_read_all [--once] <dir> <ctxs_arrayname> <kubectl_argv...>:
# istio_live_version for every member concurrently, into <dir>/<index> (index, not name: a
# context name can hold '/'). A member whose read failed (kind read) is read once more a
# second later, unless --once (the readiness wait polls again anyway); a CR that answered
# but is not settled is not retried (that is its state, not a blip).
_istio_version_read_all() {
	local once=0
	if [[ "${1:-}" == --once ]]; then
		once=1
		shift
	fi
	local dir="$1" i p kind
	local -n _ivra_ctxs="$2"
	local -a pids=() again=()
	shift 2
	for i in "${!_ivra_ctxs[@]}"; do
		istio_live_version "${_ivra_ctxs[i]}" "$@" > "${dir}/${i}" &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
	((once == 0)) || return 0
	for i in "${!_ivra_ctxs[@]}"; do
		kind="$(sed -n 2p "${dir}/${i}" 2>/dev/null || true)"
		case "$kind" in ok | notready | rolling | migrating | state | value) ;; *) again+=("$i") ;; esac
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
# what the read saw on <ctx>. <kind> deploy:<ns>/<name> is the istiod Deployment that was
# read (J12); pods:<ns>[/<rev>] its istiod pods (L3: old pods still terminating; M7: of
# that revision, the istio.io/rev label, when known); revision:<name> the IstioRevision
# whose read failed (L3); value the IstioRevisions; anything else the Istio CR.
_istio_version_repro() {
	local kind="$1" ctx
	ctx="$(printf '%q' "$2")"
	shift 2
	case "$kind" in
	value) echo "$* --context ${ctx} get istiorevisions.sailoperator.io -o yaml" ;;
	revision:?*) echo "$* --context ${ctx} get istiorevisions.sailoperator.io ${kind#revision:} -o yaml" ;;
	pods:?*/?*)
		kind="${kind#pods:}"
		echo "$* --context ${ctx} -n ${kind%%/*} get pods -l app=istiod,istio.io/rev=${kind#*/}"
		;;
	pods:?*) echo "$* --context ${ctx} -n ${kind#pods:} get pods -l app=istiod" ;;
	deploy:*/*)
		kind="${kind#deploy:}"
		echo "$* --context ${ctx} -n ${kind%%/*} get deployments.apps ${kind#*/} -o yaml"
		;;
	*) echo "$* --context ${ctx} get istios.sailoperator.io default -o yaml" ;;
	esac
}

# _istio_version_marker: the resolved values as one string. istio_version_resolve exports
# it as _ISTIO_VERSION_RESOLVED; a step inherits a sweep's result only while it matches.
_istio_version_marker() {
	printf '%s|%s|%s|%s|%s|%s' "${ISTIO_VERSION_SOURCE:-}" "${ISTIO_VERSION_PIN:-}" "${ISTIO_VERSION:-}" \
		"${ISTIO_VERSION_BY_CONTEXT:-}" "${ISTIO_NOTREADY_AT_START:-}" "${ISTIO_READY_WAITED_SEC:-}"
}

# istio_version_resolve [--no-stop] [--resumed-at <utc>] <ctxs_csv> <dry_run 0|1> <kubectl_argv...>:
# R4 (PL39). The results record the Istio version the mesh runs, not only the
# config/versions.env pin (an existing cluster, a bumped istioVersion, or an ISTIO_VERSION
# left in the shell by Istio's download script would mislabel them). Call it once per run,
# before any cluster change and outside any measurement window: a sweep before its first
# step (its steps inherit the result through the private _ISTIO_VERSION_RESOLVED marker,
# never because ISTIO_VERSION_* values happen to be in the environment), a standalone probe
# before its first mutation. Reads every member concurrently (istio_live_version, one
# retry for a failed read) and exports:
#   ISTIO_VERSION_PIN         the pin (ISTIO_VERSION as versions.env / the environment set it)
#   ISTIO_VERSION_SOURCE      live, or pin under --dry-run (nothing is read)
#   ISTIO_VERSION_BY_CONTEXT  ctx=version,... (unknown where unreadable or not settled)
#   ISTIO_VERSION             what every preamble records: the live version every member
#                             runs; under ISTIO_VERSION_CHECK=warn the truth when they do not
#                             agree (unknown, or mixed:a/b, joined with / so no report splits
#                             it); the pin under --dry-run
#   ISTIO_NOTREADY_AT_START   R2: ctx=<state>,... for the members still not ready after the
#                             wait below (rolling for an istiod rollout still in progress;
#                             unreadable when one was seen and every re-read failed, K8),
#                             none when every member was ready, unchecked under --dry-run
#                             (and when the check stopped unexpectedly, M1)
#   ISTIO_READY_WAITED_SEC    how long that wait took (0 when nobody was waited for)
# and, for istio_version_recheck, the private _ISTIO_VERSION_REVS (ctx=activeRevisionName,...).
# --resumed-at <utc> (a controlplane --resume, J2): the run appends to a TSV whose preamble
# keeps the first run's ISTIO_NOTREADY_AT_START, so istio_version_recheck reports this
# start as ISTIO_NOTREADY_AT_RESUME, with that time, in the sweep outcome.
# ISTIO_VERSION_CHECK=fail (default) dies when a member's version is unknown, members
# differ, or it differs from the pin (a leading v is ignored); warn prints the same
# problem as a warning and goes on. --no-stop (gateway-api, a read-only check) always
# warns. Every unknown member is listed with why and a command that reproduces the read
# (L6: members with the same why share one entry, its command shown for the first).
# Readiness is not the version (I1): a member whose only issue is its state (istiod or
# IstioCNI not ready, kind notready) or whose istiod is rolling out (kind rolling, I2) is
# read again every ISTIO_VERSION_READY_POLL_SEC until ISTIO_VERSION_READY_WAIT_SEC have
# passed (a SECONDS deadline), or until it is settled and ready (J4: a transient unsettled
# read keeps it in the wait; one more read after a rollout ends, J3, one poll past the
# deadline when it ended on the last read before it, K2); its answer at the deadline
# counts. A re-read that fails keeps its previous answer (Y2; a CR that answers not
# settled is an answer, also when its IstioRevision read fails, K1). Still not ready:
# its version is recorded and a warning names the state, which never stops the run. Still
# rolling: its version is unknown (old and new istiod pods both serve), which stops the
# run under fail. Under fail, nothing is waited for when another member already stops the
# run (unknown, another version, or not the pin; Y3). M1: the reads and the verdict run in
# a subshell; one that ends early for any other reason (bash 4.3-5.1 abort on a bad array
# subscript) fails closed: fail stops the run, warn records unknown, never the pin.
# Needs die(), split_csv() and is_nonneg_int() from common.sh.
# shellcheck disable=SC2329
istio_version_resolve() {
	local nostop=0 resumed=""
	while (($#)); do
		case "$1" in
		--no-stop)
			nostop=1
			shift
			;;
		--resumed-at)
			(($# >= 2)) || die "istio_version_resolve: --resumed-at needs a time"
			resumed="$2"
			shift 2
			;;
		*) break ;;
		esac
	done
	# J2: this shell's own --resume start, for istio_version_recheck (never inherited).
	_ISTIO_VERSION_RESUMED_AT="$resumed"
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
		export ISTIO_NOTREADY_AT_START=unchecked ISTIO_READY_WAITED_SEC=unchecked
		export ISTIO_VERSION="$ISTIO_VERSION_PIN"
		_ISTIO_VERSION_RESOLVED="$(_istio_version_marker)"
		export _ISTIO_VERSION_RESOLVED
		return 0
	fi
	{ (($#)) && command -v "$1" >/dev/null 2>&1; } \
		|| die "neither kubectl nor oc found on PATH, so the live Istio version cannot be read"
	local -a ivr_ctxs=()
	split_csv "$ctxs_csv" ivr_ctxs
	((${#ivr_ctxs[@]})) || die "istio_version_resolve: no mesh member contexts"
	# M1: the reads and the verdict run apart (_istio_version_isolated), and only a result
	# that ends with END counts. Its own stop (fail) prints STOP before it dies. Anything
	# else that ends it early, such as bash 4.3-5.1 aborting on a bad array subscript, fails
	# closed: under fail the run stops here, under warn it records unknown, never the pin.
	local ivr_res ivr_rc=0 ivr_line ivr_why
	ivr_res="$(mktemp)"
	_istio_version_isolated ivr_rc "$ivr_res" _istio_version_resolve_live "$ctxs_csv" "$policy" "$nostop" "$resumed" "$wait_max" "$poll" "$@"
	if ((ivr_rc == 0)) && [[ "$(tail -n 1 "$ivr_res")" == END ]]; then
		while IFS= read -r ivr_line; do
			case "${ivr_line%%=*}" in
			ISTIO_VERSION_SOURCE | ISTIO_VERSION_BY_CONTEXT | _ISTIO_VERSION_REVS | ISTIO_NOTREADY_AT_START | ISTIO_READY_WAITED_SEC | ISTIO_VERSION)
				export "${ivr_line%%=*}=${ivr_line#*=}"
				;;
			esac
		done < "$ivr_res"
		rm -f "$ivr_res"
	elif grep -qx STOP "$ivr_res" 2>/dev/null; then
		rm -f "$ivr_res"
		exit 1
	else
		rm -f "$ivr_res"
		ivr_why="the Istio version check stopped unexpectedly (exit ${ivr_rc}; the error is above), so the version the members run is not known"
		[[ "$policy" != fail ]] || die "${ivr_why}."$'\n'"Nothing was changed. To go on anyway and record ISTIO_VERSION=unknown, set ISTIO_VERSION_CHECK=warn."
		ivr_line="ISTIO_VERSION_CHECK=warn"
		((nostop == 0)) || ivr_line="a read-only check never stops on this"
		echo "warning: ${ivr_why}."$'\n'"Going on (${ivr_line}): the results record ISTIO_VERSION=unknown (ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN})." >&2
		ivr_line=""
		for ivr_why in "${ivr_ctxs[@]}"; do ivr_line="${ivr_line:+${ivr_line},}${ivr_why}=unknown"; done
		export ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT="$ivr_line" _ISTIO_VERSION_REVS=""
		export ISTIO_NOTREADY_AT_START=unchecked ISTIO_READY_WAITED_SEC=unchecked ISTIO_VERSION=unknown
	fi
	_ISTIO_VERSION_RESOLVED="$(_istio_version_marker)"
	export _ISTIO_VERSION_RESOLVED
}

# _istio_version_isolated <rc_var> <out_file> <fn> <args...>: M1. Run <fn> in a subshell
# (under set -e when the caller has it), its stdout into <out_file>, and set <rc_var> to
# its exit status. An error bash cannot recover from (a bad array subscript in bash 4.3 to
# 5.1 aborts the whole command, and the run would go on) ends only the subshell, so the
# caller can fail closed. Call it as a plain command, never in a || list or a condition:
# set -e is ignored there, also inside the subshell. It always returns 0.
_istio_version_isolated() {
	local -n _ivi_rc="$1"
	local _ivi_out="$2" _ivi_e=0
	shift 2
	[[ "$-" != *e* ]] || _ivi_e=1
	set +e
	(
		((_ivi_e == 0)) || set -e
		"$@"
	) > "$_ivi_out"
	_ivi_rc=$?
	((_ivi_e == 0)) || set -e
	return 0
}

# _istio_version_resolve_live <ctxs_csv> <policy> <nostop 0|1> <resumed_at> <wait_max>
# <poll> <kubectl_argv...>: istio_version_resolve's reads, wait and verdict, run through
# _istio_version_isolated. Prints KEY=value lines (the keys it exports), then END; under
# fail, a problem prints STOP and dies.
# shellcheck disable=SC2329
_istio_version_resolve_live() {
	local ctxs_csv="$1" policy="$2" nostop="$3" resumed="$4" wait_max="$5" poll="$6"
	shift 6
	local -a ctxs=() waitfor=() wctxs=() ivr_states=()
	local -A ivr_inwait=() ivr_settle=() ivr_rerr=() ivr_rok=() ivr_nrm=() ivr_nrf=() ivr_nrc=()
	split_csv "$ctxs_csv" ctxs
	local tmp wtmp i j v kind prev why rev rver state by="" revs="" distinct="" bad=0 detail="" live problem="" fix="" envpin=""
	local n_notready=0 n_rolling=0 n_read=0 n_unsettled=0 n_revread=0 nr_at_start="" t0 deadline elapsed=0 polls=0 nap doomed="" vset=""
	local ivr_skipped=0 ivr_offpin="" ivr_stale="" allfail st rk label dre='Deployment ([a-z0-9.-]+)/([a-z0-9.-]+)'
	local ivr_over=0 ivr_rg ivr_rltail="" ivr_rlv ivr_rdg ivr_ok n_term=0 ivr_n ivr_rdep
	local -a ivr_sw=() ivr_rlk=() ivr_rdk=() ivr_opk=()
	local -A ivr_rlm=() ivr_rlf=() ivr_rlw=() ivr_rlc=() ivr_rlt=() ivr_rdm=() ivr_rdf=() ivr_rdc=() ivr_opm=()
	tmp="$(mktemp -d)"
	_istio_version_read_all "$tmp" ctxs "$@"
	# I1/I2: wait while only readiness is off or istiod is rolling out, until a SECONDS
	# deadline (Y1). J4: a member that entered the wait is read again until the deadline or
	# until it reads ok (and, right after a rollout, once more: J3; K2: also when the
	# rollout ended on the last read before the deadline, one poll past it, once).
	for i in "${!ctxs[@]}"; do
		case "$(sed -n 2p "${tmp}/${i}" 2>/dev/null || true)" in notready | rolling) ivr_inwait[$i]=1 ;; esac
	done
	t0=$SECONDS
	deadline=$((t0 + wait_max))
	while ((${#ivr_inwait[@]})); do
		waitfor=()
		for i in "${!ctxs[@]}"; do
			[[ -n "${ivr_inwait[$i]:-}" ]] || continue
			kind="$(sed -n 2p "${tmp}/${i}" 2>/dev/null || true)"
			[[ "$kind" == ok && -z "${ivr_settle[$i]:-}" ]] || waitfor+=("$i")
		done
		((${#waitfor[@]})) || break
		if ((SECONDS >= deadline)); then
			# K2: at the deadline only a rollout that just ended is read again (its J3 read),
			# one poll later, and only once; everyone else keeps their last answer.
			((ivr_over == 0)) || break
			ivr_sw=()
			for i in "${waitfor[@]}"; do [[ -z "${ivr_settle[$i]:-}" ]] || ivr_sw+=("$i"); done
			((${#ivr_sw[@]})) || break
			ivr_over=1
			waitfor=("${ivr_sw[@]}")
		fi
		if [[ "$policy" == fail ]]; then
			# Y3: under fail, a member outside the wait whose version is unknown, members on
			# different versions, or a version that is not the pin stop the run whatever
			# readiness does; do not wait (any longer) first.
			doomed="" vset=""
			for i in "${!ctxs[@]}"; do
				v="" kind=""
				{ IFS= read -r v; IFS= read -r kind; } 2>/dev/null < "${tmp}/${i}" || true
				case "$kind" in
				ok | notready | rolling) ;;
				*)
					[[ -n "${ivr_inwait[$i]:-}" ]] && continue
					doomed="the version of ${ctxs[i]} is unknown"
					break
					;;
				esac
				case "/${vset}/" in */"${v}"/*) ;; *) vset="${vset:+${vset}/}${v}" ;; esac
			done
			if [[ -z "$doomed" && "$vset" == */* ]]; then
				doomed="the members run different Istio versions"
			elif [[ -z "$doomed" && -n "$vset" && "${vset#v}" != "${ISTIO_VERSION_PIN#v}" ]]; then
				doomed="the mesh runs Istio ${vset}, not the pin ${ISTIO_VERSION_PIN}"
			fi
			if [[ -n "$doomed" ]]; then
				if ((polls == 0)); then
					ivr_skipped=1
					echo "  not waiting for istiod or IstioCNI on ${#waitfor[@]} of ${#ctxs[@]} members: ${doomed}, which stops the run under ISTIO_VERSION_CHECK=fail anyway" >&2
				else
					echo "  no longer waiting for istiod or IstioCNI after $((SECONDS - t0))s: ${doomed}, which stops the run under ISTIO_VERSION_CHECK=fail anyway" >&2
				fi
				break
			fi
		fi
		((polls)) || echo "  istiod or IstioCNI is not ready (or istiod is rolling out) on ${#waitfor[@]} of ${#ctxs[@]} members; reading them again every ${poll}s for up to ${wait_max}s (plus one poll)..." >&2
		nap=$((deadline - SECONDS))
		((nap <= poll)) || nap="$poll"
		((nap > 0)) || nap=1
		((ivr_over == 0)) || nap="$poll"
		sleep "$nap"
		polls=$((polls + 1))
		wctxs=()
		for i in "${waitfor[@]}"; do wctxs+=("${ctxs[i]}"); done
		wtmp="$(mktemp -d)"
		_istio_version_read_all --once "$wtmp" wctxs "$@"
		for j in "${!waitfor[@]}"; do
			i="${waitfor[j]}"
			kind="$(sed -n 2p "${wtmp}/${j}" 2>/dev/null || true)"
			# K1: a CR that answered "not settled" is an answer (J4), also when its
			# IstioRevision read then failed; only a read that learned nothing keeps the last one.
			if [[ "$kind" == read && "$(sed -n 3p "${wtmp}/${j}" 2>/dev/null || true)" == "the Istio CR default is not settled: "* ]]; then
				kind=unsettled
			fi
			case "$kind" in
			ok | notready | rolling | migrating | state | value | unsettled)
				# J3: a rollout that just ended may still have old istiod pods draining their
				# xDS streams (shutdownDuration): read it once more before it counts as ok.
				prev="$(sed -n 2p "${tmp}/${i}" 2>/dev/null || true)"
				if [[ "$prev" == rolling && "$kind" != rolling ]]; then ivr_settle[$i]=1; else unset 'ivr_settle[$i]'; fi
				ivr_rok[$i]=1
				unset 'ivr_rerr[$i]'
				mv -f "${wtmp}/${j}" "${tmp}/${i}"
				;;
			*)
				# Y2: a re-read that fails keeps the member's previous answer (J14 says so).
				ivr_rerr[$i]="$(sed -n 3p "${wtmp}/${j}" 2>/dev/null || true)"
				;;
			esac
		done
		rm -rf "$wtmp"
	done
	((polls == 0)) || elapsed=$((SECONDS - t0))
	for i in "${!ctxs[@]}"; do
		v="" kind="" why="" rev="" rver="" state=""
		{ IFS= read -r v; IFS= read -r kind; IFS= read -r why; IFS= read -r rev; IFS= read -r rver; IFS= read -r state; } \
			2>/dev/null < "${tmp}/${i}" || true
		[[ -n "$v" ]] || v=unknown
		allfail=0
		[[ -z "${ivr_rerr[$i]+x}" || -n "${ivr_rok[$i]:-}" ]] || allfail=1
		if [[ "$kind" == rolling ]]; then
			# I2: still rolling out: old and new istiod pods both serve, so the run would
			# not measure one version.
			v=unknown
			if ((allfail)); then
				# J14: unreachable since its first read, not known to be still rolling out
				# (K8: recorded as such, as the console says).
				nr_at_start="${nr_at_start:+${nr_at_start},}${ctxs[i]}=unreadable"
				why="every re-read during the wait failed (${ivr_rerr[$i]:-no answer}); the first read saw: ${why}"
				kind="read"
			else
				nr_at_start="${nr_at_start:+${nr_at_start},}${ctxs[i]}=rolling"
				n_rolling=$((n_rolling + 1))
				# L3: every pod updated, only old pods still terminating (K12): its own group,
				# wording and check (its pods), and it runs that version (L6, the Also clause).
				ivr_rlv="is rolling out" ivr_rltail="still rolling out"
				if [[ "$why" == "istiod pods still terminating "* ]]; then
					ivr_rlv="runs" ivr_rltail="still terminating"
					n_term=$((n_term + 1))
				fi
				# J5: say so when the wait was skipped (Y3), not "after 0s".
				if ((ivr_skipped)); then ivr_rltail="not waited for"; else ivr_rltail+=" after ${elapsed}s"; fi
				if [[ "${rver#v}" != "${ISTIO_VERSION_PIN#v}" ]]; then
					ivr_ok="${ivr_rlv}|${rver}"
					[[ -n "${ivr_opm[$ivr_ok]+x}" ]] || ivr_opk+=("$ivr_ok")
					ivr_opm[$ivr_ok]="${ivr_opm[$ivr_ok]:+${ivr_opm[$ivr_ok]}, }${ctxs[i]}"
				fi
				# K8: grouped by Deployment and version below (one line per group).
				[[ "$why" =~ $dre ]] || true
				ivr_rg="${BASH_REMATCH[1]:-?}/${BASH_REMATCH[2]:-?} ${rver}"
				[[ "$ivr_rlv" != runs ]] || ivr_rg+=" terminating"
				[[ -n "${ivr_rlc[$ivr_rg]:-}" ]] || { ivr_rlk+=("$ivr_rg"); ivr_rlf[$ivr_rg]="${ctxs[i]}"; ivr_rlw[$ivr_rg]="${why}; ${ivr_rltail}"; ivr_rlc[$ivr_rg]=0; ivr_rlt[$ivr_rg]="$ivr_rltail"; }
				ivr_n="${ivr_rlc[$ivr_rg]}" # M1: never x[$key] in arithmetic (bash 4.3-5.1 expand the key twice)
				ivr_rlc[$ivr_rg]=$((ivr_n + 1))
				ivr_rlm[$ivr_rg]="${ivr_rlm[$ivr_rg]:+${ivr_rlm[$ivr_rg]}, }${ctxs[i]}"
			fi
		fi
		by="${by:+${by},}${ctxs[i]}=${v}"
		revs="${revs:+${revs},}${ctxs[i]}=${rev}"
		if [[ "$v" == unknown ]]; then
			bad=$((bad + 1))
			case "$kind" in
			rolling) ;;
			state | migrating | value) n_unsettled=$((n_unsettled + 1)) ;;
			*) n_read=$((n_read + 1)) ;;
			esac
			if [[ "$kind" != rolling ]]; then
				# J12: a failed Deployment read's command names the Deployment that was read;
				# L3: a failed IstioRevision read's, that revision.
				rk="${kind:-read}"
				if [[ "$why" == "istiod Deployment "* && "$why" =~ $dre ]]; then
					rk="deploy:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
				elif [[ "$kind" == read && -n "$rev" && ( "$why" == "IstioRevision ${rev}: "* \
					|| ( "$why" == "the Istio CR default is not settled: "* && "$why" == *"; IstioRevision ${rev}: "* ) ) ]]; then
					rk="revision:${rev}"
					# M7: a settled CR whose IstioRevision read failed: waiting does not help.
					[[ "$why" != "IstioRevision ${rev}: "* ]] || n_revread=$((n_revread + 1))
				fi
				# L6: grouped by that command's kind and why (one entry per group).
				ivr_rdg="${rk}|${why:-no answer}"
				[[ -n "${ivr_rdc[$ivr_rdg]:-}" ]] || { ivr_rdk+=("$ivr_rdg"); ivr_rdf[$ivr_rdg]="${ctxs[i]}"; ivr_rdc[$ivr_rdg]=0; }
				ivr_n="${ivr_rdc[$ivr_rdg]}"
				ivr_rdc[$ivr_rdg]=$((ivr_n + 1))
				ivr_rdm[$ivr_rdg]="${ivr_rdm[$ivr_rdg]:+${ivr_rdm[$ivr_rdg]}, }${ctxs[i]}"
			fi
		else
			if [[ "${v#v}" != "${ISTIO_VERSION_PIN#v}" ]]; then
				ivr_ok="runs|${v}"
				[[ -n "${ivr_opm[$ivr_ok]+x}" ]] || ivr_opk+=("$ivr_ok")
				ivr_opm[$ivr_ok]="${ivr_opm[$ivr_ok]:+${ivr_opm[$ivr_ok]}, }${ctxs[i]}"
			fi
			if [[ "$kind" == notready ]]; then
				# J14: grouped by state, as the end note is.
				n_notready=$((n_notready + 1))
				st="${state:-unknown}"
				nr_at_start="${nr_at_start:+${nr_at_start},}${ctxs[i]}=${st}"
				[[ -n "${ivr_nrc[$st]:-}" ]] || { ivr_states+=("$st"); ivr_nrf[$st]="${ctxs[i]}"; ivr_nrc[$st]=0; }
				ivr_n="${ivr_nrc[$st]}"
				ivr_nrc[$st]=$((ivr_n + 1))
				ivr_nrm[$st]="${ivr_nrm[$st]:+${ivr_nrm[$st]}, }${ctxs[i]}"
				((allfail == 0)) || ivr_stale="${ivr_stale:+${ivr_stale}, }${ctxs[i]}"
			fi
		fi
		case "/${distinct}/" in */"${v}"/*) ;; *) distinct="${distinct:+${distinct}/}${v}" ;; esac
	done
	rm -rf "$tmp"
	# L6: members whose version is unknown (not rolling), one entry per command kind and why,
	# with the command that reproduces the read (shown for the first member of a group).
	for ivr_rdg in ${ivr_rdk[@]+"${ivr_rdk[@]}"}; do
		if [[ "${ivr_rdc[$ivr_rdg]}" == 1 ]]; then
			detail+=$'\n'"  ${ivr_rdf[$ivr_rdg]}: ${ivr_rdg#*|}"
			detail+=$'\n'"    reproduce: $(_istio_version_repro "${ivr_rdg%%|*}" "${ivr_rdf[$ivr_rdg]}" "$@")"
		else
			detail+=$'\n'"  ${ivr_rdm[$ivr_rdg]} (${ivr_rdc[$ivr_rdg]} members): ${ivr_rdg#*|}"
			detail+=$'\n'"    reproduce (shown for ${ivr_rdf[$ivr_rdg]}): $(_istio_version_repro "${ivr_rdg%%|*}" "${ivr_rdf[$ivr_rdg]}" "$@")"
		fi
	done
	# K8: rolling members, one line per Deployment and version, with a check command (J12:
	# a rollout's command is a check, and names the Deployment that was read; L3: for old
	# pods still terminating, the istiod pods).
	for ivr_rg in ${ivr_rlk[@]+"${ivr_rlk[@]}"}; do
		ivr_rlv="${ivr_rg#* }"
		ivr_rlv="${ivr_rlv%% *}"
		if [[ "$ivr_rg" == *" terminating" ]]; then
			# M7: the pods of that revision: Sail's istiod-<rev> (istiod: default) Deployment
			# labels them istio.io/rev=<rev>.
			ivr_rdep="${ivr_rg%% *}"
			ivr_rdep="${ivr_rdep#*/}"
			rk="pods:${ivr_rg%%/*}"
			case "$ivr_rdep" in
			istiod) rk+="/default" ;;
			istiod-?*) rk+="/${ivr_rdep#istiod-}" ;;
			esac
			label="istiod pods still terminating after the rollout to ${ivr_rlv}"
		else
			rk="deploy:${ivr_rg%% *}"
			label="istiod is rolling out ${ivr_rlv}"
		fi
		if [[ "${ivr_rlc[$ivr_rg]}" == 1 ]]; then
			detail+=$'\n'"  ${ivr_rlf[$ivr_rg]}: ${ivr_rlw[$ivr_rg]}"
			detail+=$'\n'"    check: $(_istio_version_repro "$rk" "${ivr_rlf[$ivr_rg]}" "$@")"
		else
			detail+=$'\n'"  ${label} on ${ivr_rlc[$ivr_rg]} members (Deployment ${ivr_rg%% *}; ${ivr_rlt[$ivr_rg]}): ${ivr_rlm[$ivr_rg]}"
			detail+=$'\n'"    check (shown for ${ivr_rlf[$ivr_rg]}): $(_istio_version_repro "$rk" "${ivr_rlf[$ivr_rg]}" "$@")"
		fi
	done
	# L6: members off the pin, one entry per version (and whether it is still rolling out).
	for ivr_ok in ${ivr_opk[@]+"${ivr_opk[@]}"}; do
		ivr_rlv="${ivr_ok%%|*}"
		if [[ "${ivr_opm[$ivr_ok]}" == *", "* ]]; then
			case "$ivr_rlv" in runs) ivr_rlv="run" ;; *) ivr_rlv="are rolling out" ;; esac
		fi
		ivr_offpin="${ivr_offpin:+${ivr_offpin}; }${ivr_opm[$ivr_ok]} ${ivr_rlv} ${ivr_ok#*|}"
	done
	# Where the pin came from: an ISTIO_VERSION exported in the shell, or versions.env (K5:
	# also for the advice about a member that is off the pin while another is unknown).
	# shellcheck disable=SC2016  # the sed pattern matches a literal ${ISTIO_VERSION:-...}
	envpin="$(sed -n 's/^export ISTIO_VERSION="\${ISTIO_VERSION:-\(.*\)}".*$/\1/p' \
		"${ROOT:-.}/config/versions.env" 2>/dev/null || true)"
	[[ "$envpin" != "$ISTIO_VERSION_PIN" ]] || envpin=""
	if [[ "$distinct" == */* ]]; then live="mixed:${distinct}"; else live="$distinct"; fi
	if ((bad)); then
		# J5: only the fixes that can help. L3: old istiod pods still terminating are not
		# a rollout to wait out (one stuck in Terminating stays until it is force-deleted).
		if ((n_rolling)); then
			problem="cannot confirm the running Istio version on ${bad} of ${#ctxs[@]} members:${detail}"
			if ((n_term == 0)); then
				label="their istiod rollout is complete"
			elif ((n_term == n_rolling)); then
				label="their old istiod pods are gone (a pod stuck in Terminating, on a lost node say, needs a force delete)"
			else
				label="their istiod rollout is complete and their old istiod pods are gone"
			fi
			if ((n_unsettled == 0 && n_read > 0 && n_read == n_revread)); then
				fix="Fix access to those members (kubeconfig, login, network) and to their IstioRevision, or wait until ${label}"
			elif ((n_read + n_unsettled)); then
				fix="Fix access to those members (kubeconfig, login, network), or wait until their Istio CR is settled and ${label}"
			else
				fix="Wait until ${label}"
			fi
			((ivr_skipped)) || fix+=" (or raise ISTIO_VERSION_READY_WAIT_SEC)"
		else
			problem="cannot read the running Istio version on ${bad} of ${#ctxs[@]} members:${detail}"
			fix="Fix access to those members (kubeconfig, login, network), or wait until their Istio CR is settled"
			# M7: only IstioRevision reads failed, on settled CRs: there is nothing to wait for.
			((n_unsettled || n_read != n_revread)) \
				|| fix="Fix access to those members (kubeconfig, login, network) and to their IstioRevision (their Istio CR is settled)"
		fi
		if [[ -z "$ivr_offpin" ]]; then
			fix+="; the pin is not the problem."
		elif [[ -n "$envpin" ]]; then
			fix+=". Also, ${ivr_offpin}, not ISTIO_VERSION=${ISTIO_VERSION_PIN}, which is exported in this shell (config/versions.env pins ${envpin}): unset ISTIO_VERSION (a value left in the shell, for example by Istio's download script)."
		else
			fix+=". Also, ${ivr_offpin}, not the pin ${ISTIO_VERSION_PIN}: bump ISTIO_VERSION in config/versions.env with charts/spoke-ossm istioVersion when the mesh is upgraded on purpose."
		fi
		fix=$'\n'"${fix}"
	elif [[ "$distinct" == */* ]]; then
		problem="the mesh members run different Istio versions (${by})"
		fix=$'\n'"Fix: bring every member to one version (an upgrade still rolling out?), or pass --contexts with only the members that run the same one."
	elif [[ "${live#v}" != "${ISTIO_VERSION_PIN#v}" ]]; then
		if [[ -n "$envpin" ]]; then
			problem="the mesh runs Istio ${live} (${by}), but ISTIO_VERSION is ${ISTIO_VERSION_PIN}, exported in this shell (config/versions.env pins ${envpin})"
			fix=$'\n'"Fix: unset ISTIO_VERSION (a value left in the shell, for example by Istio's download script), or run with ISTIO_VERSION=${live} to record the live version."
		else
			problem="the mesh runs Istio ${live} (${by}), but ISTIO_VERSION is ${ISTIO_VERSION_PIN} (config/versions.env)"
			fix=$'\n'"Fix: bump ISTIO_VERSION in config/versions.env with charts/spoke-ossm istioVersion when the mesh was upgraded on purpose, or run with ISTIO_VERSION=${live} for this run only."
		fi
	fi
	if [[ -n "$problem" ]]; then
		if [[ "$policy" == fail ]]; then
			echo STOP
			die "${problem}${fix}"$'\n'"Nothing was changed. To go on anyway and record ISTIO_VERSION=${live}, set ISTIO_VERSION_CHECK=warn."
		fi
		why="ISTIO_VERSION_CHECK=warn"
		((nostop == 0)) || why="a read-only check never stops on this"
		echo "warning: ${problem}${fix}"$'\n'"Going on (${why}): the results record ISTIO_VERSION=${live} (ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN})." >&2
	fi
	if ((n_notready)); then
		{
			echo "WARNING: istiod or IstioCNI is still not ready on ${n_notready} of ${#ctxs[@]} members after ${elapsed}s:"
			for st in "${ivr_states[@]}"; do
				if [[ "${ivr_nrc[$st]}" != 1 ]]; then
					echo "  ${st} on ${ivr_nrc[$st]} members (${ivr_nrm[$st]})"
					echo "    check (shown for ${ivr_nrf[$st]}): $(_istio_version_repro state "${ivr_nrf[$st]}" "$@")"
				else
					echo "  ${st} on 1 member (${ivr_nrm[$st]})"
					echo "    check: $(_istio_version_repro state "${ivr_nrf[$st]}" "$@")"
				fi
			done
			[[ -z "$ivr_stale" ]] || echo "  every re-read during the wait failed on ${ivr_stale}: the state above is what the first read saw"
			if [[ -n "$resumed" ]]; then
				echo "The run goes on: their version was read (ISTIO_VERSION=${live}). This --resume records them in sweep-outcome.txt as ISTIO_NOTREADY_AT_RESUME, with its start time (${resumed}); the TSV preamble keeps the first run's ISTIO_NOTREADY_AT_START. A control plane that is not ready can slow or skew the first measurements of the resume. Wait for the Istio CR to be Healthy, or raise ISTIO_VERSION_READY_WAIT_SEC."
			else
				echo "The run goes on: their version was read (ISTIO_VERSION=${live}), and the preambles record ISTIO_NOTREADY_AT_START, but a control plane that is not ready can slow or skew the first measurements. Wait for the Istio CR to be Healthy, or raise ISTIO_VERSION_READY_WAIT_SEC."
			fi
		} >&2
	fi
	printf '%s\n' "ISTIO_VERSION_SOURCE=live" "ISTIO_VERSION_BY_CONTEXT=${by}" "_ISTIO_VERSION_REVS=${revs}" \
		"ISTIO_NOTREADY_AT_START=${nr_at_start:-none}" "ISTIO_READY_WAITED_SEC=${elapsed}" "ISTIO_VERSION=${live}" END
}

# _istio_notready_notes <out_arrayname> <start|end|resume> <ctx=state,...> [<waited_sec>]
# [<resumed_at>]: the sweep_outcome --note arguments for members whose istiod or IstioCNI
# was not ready (the list as ISTIO_NOTREADY_AT_START holds it; rolling for an istiod
# rollout in progress): one line on what that means and what to check, then one line per
# state with its members (Y4). Appends nothing for an empty list or unchecked, nor for
# none, except at a resume (J2): the TSV preamble keeps the first run's value, so the
# outcome records the resume's start time and its own value, none included (an --info
# line, K6: an all-clear is not a warning).
_istio_notready_notes() {
	local -n _inn_out="$1"
	local when="$2" list="$3" waited="${4:-}" at="${5:-}" pair st n label
	local -a pairs=() states=()
	local -A members=()
	case "$list" in "" | unchecked) return 0 ;; esac
	if [[ "$when" == resume && "$list" == none ]]; then
		_inn_out+=(--info "this --resume started at ${at} with every member ready (ISTIO_NOTREADY_AT_RESUME=none, ISTIO_READY_WAITED_SEC=${waited:-0}); the TSV preamble's ISTIO_NOTREADY_AT_START is the first run's")
		return 0
	fi
	[[ "$list" != none ]] || return 0
	IFS=, read -r -a pairs <<<"$list"
	for pair in "${pairs[@]}"; do
		st="${pair##*=}"
		[[ -n "${members[$st]+set}" ]] || states+=("$st")
		members[$st]="${members[$st]:+${members[$st]}, }${pair%=*}"
	done
	case "$waited" in "" | unchecked) waited="" ;; *) waited=", after waiting ${waited}s" ;; esac
	if [[ "$when" == start ]]; then
		_inn_out+=(--note "istiod or IstioCNI was still not ready at the start of the sweep${waited} (ISTIO_NOTREADY_AT_START): the first cells may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted")
	elif [[ "$when" == resume ]]; then
		_inn_out+=(--note "istiod or IstioCNI was still not ready when this --resume started at ${at}${waited} (ISTIO_NOTREADY_AT_RESUME=${list}; the TSV preamble's ISTIO_NOTREADY_AT_START is the first run's): the first cells the resume ran (rows from ${at} on) may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted")
	else
		_inn_out+=(--note "istiod or IstioCNI was not ready at the end of the sweep, on the same Istio version: the last cells may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted")
	fi
	for st in "${states[@]}"; do
		pairs=()
		IFS=, read -r -a pairs <<<"${members[$st]//, /,}"
		label="$st"
		[[ "$st" != rolling ]] || label="rolling (an istiod rollout in progress, or old istiod pods still terminating)"
		[[ "$st" != unreadable ]] || label="unreadable (an istiod rollout at the first read, then every re-read failed)"
		n="${#pairs[@]} members"
		((${#pairs[@]} > 1)) || n="1 member"
		_inn_out+=(--note "not ready at the ${when}: ${label} on ${n} (${members[$st]})")
	done
}

# istio_version_recheck <out_arrayname> <kubectl_argv...>: A6. Read every member's version
# again at the end of a sweep (after its last window, before its reports), read-only and
# never dying, and compare it with ISTIO_VERSION_BY_CONTEXT (and the activeRevisionName
# in _ISTIO_VERSION_REVS) from istio_version_resolve. Sets the named array to
# sweep_outcome arguments, which print them (once; --info on stdout, the rest on stderr):
#   --problem <msg>  a member now runs another version or another active revision (also
#                    when its Istio CR is not settled at the end but the active revision
#                    reads another version: a version bump whose upgrade failed partway),
#                    or is migrating between revisions (inUse > 1), or its revision's
#                    version is not exact: its rows are not all from one version, a failed
#                    sweep;
#   --note <msg>     R2: members still not ready (or rolling out) at the start, from
#                    ISTIO_NOTREADY_AT_START (J2: at a --resume, its start time and its
#                    own value as ISTIO_NOTREADY_AT_RESUME); the same version, but istiod
#                    or IstioCNI not ready (or istiod rolling out) at the end, grouped by
#                    state (I1, Y4: readiness, not a version change); or a member that
#                    could not be read again (K1: with why, when its Istio CR answered),
#                    whose Istio CR is not settled at the end, or that was unknown at the
#                    start (unconfirmed, not a failure; members are grouped by start
#                    version and why: K8 for an istiod Deployment that alone could not be
#                    read, L6 for the rest);
#   --info <msg>     a --resume whose members were all ready when it started
#                    (ISTIO_NOTREADY_AT_RESUME=none, with its start time; K6).
# Nothing more when nothing was read live (ISTIO_VERSION_SOURCE pin, as under --dry-run).
# M1: the check runs apart (_istio_version_isolated); one that stops unexpectedly (bash 4.3
# to 5.1 abort on a bad array subscript) is a --problem, never silence.
# shellcheck disable=SC2329
istio_version_recheck() {
	local -n _ivrc_res="$1"
	shift
	local ivrc_file ivrc_rc=0
	local -a ivrc_lines=()
	_ivrc_res=()
	ivrc_file="$(mktemp)"
	_istio_version_isolated ivrc_rc "$ivrc_file" _istio_version_recheck_emit "$@"
	mapfile -t ivrc_lines < "$ivrc_file"
	rm -f "$ivrc_file"
	if ((ivrc_rc == 0 && ${#ivrc_lines[@]} > 0)) && [[ "${ivrc_lines[-1]}" == END ]]; then
		unset 'ivrc_lines[-1]'
		_ivrc_res=(${ivrc_lines[@]+"${ivrc_lines[@]}"})
	else
		_ivrc_res=(--problem "the end-of-sweep Istio version check failed: it stopped unexpectedly (exit ${ivrc_rc}; the error is on stderr above), so whether the Istio version or the active revision changed during the sweep is not known")
	fi
	return 0
}

# _istio_version_recheck_emit <kubectl_argv...>: run through _istio_version_isolated, prints
# _istio_version_recheck_live's arguments one per line (a newline in one becomes a
# space), then END.
# shellcheck disable=SC2329
_istio_version_recheck_emit() {
	local -a ivre_out=()
	local ivre_a
	_istio_version_recheck_live ivre_out "$@"
	for ivre_a in ${ivre_out[@]+"${ivre_out[@]}"}; do printf '%s\n' "${ivre_a//$'\n'/ }"; done
	echo END
}

# _istio_version_recheck_live <out_arrayname> <kubectl_argv...>: istio_version_recheck's
# reads and comparison.
# shellcheck disable=SC2329
_istio_version_recheck_live() {
	local -n _ivrc_out="$1"
	shift
	_ivrc_out=()
	if [[ -n "${_ISTIO_VERSION_RESUMED_AT:-}" ]]; then
		_istio_notready_notes _ivrc_out resume "${ISTIO_NOTREADY_AT_START:-}" "${ISTIO_READY_WAITED_SEC:-}" "$_ISTIO_VERSION_RESUMED_AT"
	else
		_istio_notready_notes _ivrc_out start "${ISTIO_NOTREADY_AT_START:-}" "${ISTIO_READY_WAITED_SEC:-}"
	fi
	[[ "${ISTIO_VERSION_SOURCE:-pin}" == live && -n "${ISTIO_VERSION_BY_CONTEXT:-}" ]] || return 0
	{ (($#)) && command -v "$1" >/dev/null 2>&1; } || return 0
	local -a ctxs=() start_v=() pairs=()
	local -A start_rev=()
	local pair tmp i v kind why rev rver state sv sr changed="" what="version" revonly=1 unconfirmed="" nr_end=""
	local ivrc_k ivrc_m
	local -a ivrc_dk=()
	local -A ivrc_dm=()
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
		v="" kind="" why="" rev="" rver="" state=""
		{ IFS= read -r v; IFS= read -r kind; IFS= read -r why; IFS= read -r rev; IFS= read -r rver; IFS= read -r state; } \
			2>/dev/null < "${tmp}/${i}" || true
		[[ -n "$v" ]] || v=unknown
		sv="${start_v[i]}" sr="${start_rev[${ctxs[i]}]:-}"
		if [[ "$sv" == unknown ]]; then
			[[ "$v" == unknown ]] || unconfirmed+="${unconfirmed:+; }${ctxs[i]} was unknown at the start and reads ${v} at the end"
			continue
		fi
		case "$kind" in
		ok | notready | rolling)
			if [[ "$v" != "$sv" ]]; then
				changed+="${changed:+; }${ctxs[i]}: ${sv} at the start, ${v} at the end"
				revonly=0
			elif [[ -n "$sr" && -n "$rev" && "$rev" != "$sr" ]]; then
				changed+="${changed:+; }${ctxs[i]}: activeRevisionName ${sr} at the start, ${rev} at the end (both ${v})"
			elif [[ "$kind" == rolling ]]; then
				nr_end="${nr_end:+${nr_end},}${ctxs[i]}=rolling"
			elif [[ "$kind" == notready ]]; then
				nr_end="${nr_end:+${nr_end},}${ctxs[i]}=${state:-unknown}"
			fi
			;;
		migrating | value)
			changed+="${changed:+; }${ctxs[i]}: ${sv} at the start, ${v} at the end (${why})"
			revonly=0
			;;
		state | read)
			# Not settled at the end (a ReconcileError, a generation not reconciled yet), or
			# a later read failed (the istiod Deployment, J1), but the active revision was
			# read: another version is a change all the same (a mid-sweep upgrade).
			if [[ -n "$rver" && "$rver" != "$sv" ]]; then
				changed+="${changed:+; }${ctxs[i]}: ${sv} at the start, ${rver} at the end, its active revision's version (${why})"
				revonly=0
			elif [[ -n "$sr" && -n "$rev" && "$rev" != "$sr" ]]; then
				changed+="${changed:+; }${ctxs[i]}: activeRevisionName ${sr} at the start, ${rev} at the end (${why})"
			else
				# K8, L6: grouped below by kind, start version and why (every Deployment
				# read failing, RBAC say; every Istio CR not settled). K1: the Istio CR
				# answered (it names a revision), so say what failed.
				if [[ "$kind" == state ]]; then
					ivrc_k="st|${sv}||${why}"
				elif [[ -n "$rver" ]]; then
					ivrc_k="dep|${sv}|${rver}|${why}"
				else
					ivrc_k="rd|${sv}||${rev:+${why}}"
				fi
				[[ -n "${ivrc_dm[$ivrc_k]+x}" ]] || ivrc_dk+=("$ivrc_k")
				ivrc_dm[$ivrc_k]="${ivrc_dm[$ivrc_k]:+${ivrc_dm[$ivrc_k]}, }${ctxs[i]}"
			fi
			;;
		*)
			ivrc_k="rd|${sv}||"
			[[ -n "${ivrc_dm[$ivrc_k]+x}" ]] || ivrc_dk+=("$ivrc_k")
			ivrc_dm[$ivrc_k]="${ivrc_dm[$ivrc_k]:+${ivrc_dm[$ivrc_k]}, }${ctxs[i]}"
			;;
		esac
	done
	rm -rf "$tmp"
	for ivrc_k in ${ivrc_dk[@]+"${ivrc_dk[@]}"}; do
		kind="${ivrc_k%%|*}" why="${ivrc_k#*|}"
		sv="${why%%|*}" why="${why#*|}"
		rver="${why%%|*}" why="${why#*|}" ivrc_m="${ivrc_dm[$ivrc_k]}"
		if [[ "$kind" == st ]]; then
			unconfirmed+="${unconfirmed:+; }${ivrc_m} ran ${sv} at the start, and at the end ${why}"
		elif [[ "$kind" == rd ]]; then
			unconfirmed+="${unconfirmed:+; }${ivrc_m} could not be read again (${sv} at the start)${why:+: ${why}}"
		elif [[ "$ivrc_m" == *", "* ]]; then
			unconfirmed+="${unconfirmed:+; }${ivrc_m} ran ${sv} at the start, and their active revisions read ${rver} at the end, but ${why}"
		else
			unconfirmed+="${unconfirmed:+; }${ivrc_m} ran ${sv} at the start, and its active revision reads ${rver} at the end, but ${why}"
		fi
	done
	((revonly == 0)) || what="active revision"
	if [[ -n "$changed" ]]; then
		_ivrc_out+=(--problem "the Istio ${what} changed during the sweep (${changed}); its rows are not all from ISTIO_VERSION=${ISTIO_VERSION}")
	fi
	_istio_notready_notes _ivrc_out end "$nr_end"
	if [[ -n "$unconfirmed" ]]; then
		_ivrc_out+=(--note "the Istio version at the end of the sweep is unconfirmed: ${unconfirmed}")
	fi
	return 0
}

# istio_version_kv: the Istio version keys every preamble writer records (PL36), as
# KEY=value lines: ISTIO_VERSION, ISTIO_VERSION_PIN, ISTIO_VERSION_SOURCE (pin when
# nothing resolved them: the value is then the pin, unchecked), ISTIO_VERSION_BY_CONTEXT
# (ctx=version,...; unchecked when nothing was read), ISTIO_NOTREADY_AT_START (R2:
# ctx=<state>,... still not ready after the start's wait, rolling for an istiod rollout;
# none; unchecked) and ISTIO_READY_WAITED_SEC (how long the start waited; unchecked).
# shellcheck disable=SC2329
istio_version_kv() {
	echo "ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
	echo "ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN:-${ISTIO_VERSION:-unknown}}"
	echo "ISTIO_VERSION_SOURCE=${ISTIO_VERSION_SOURCE:-pin}"
	echo "ISTIO_VERSION_BY_CONTEXT=${ISTIO_VERSION_BY_CONTEXT:-unchecked}"
	echo "ISTIO_NOTREADY_AT_START=${ISTIO_NOTREADY_AT_START:-unchecked}"
	echo "ISTIO_READY_WAITED_SEC=${ISTIO_READY_WAITED_SEC:-unchecked}"
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
