#!/usr/bin/env bash
# Harness metadata and TSV preamble helpers. Sourced, never executed.
#
# Consumers: controlplane, dataplane, propagation, churn, churn-dataplane, gateway-api (001:
# harness_sha, probe_kube_versions, tuning_baseline_state per member)
#
# Exposes:
#   harness_sha (in tests/lib/common.sh)          -> `git -C "${ROOT:-.}" describe --always --abbrev=7`,
#       with `-dirty.<8hex>` naming the uncommitted content of tests/, config/, charts/ and
#       terraform/ (submodules never count), or "unknown"
#   kube_versions <ctx> <kubectl_argv...>          -> kubectl server gitVersion, "unreachable"/"unknown" semantics
#   probe_kube_versions <ctxs_csv> <kubectl_argv...>
#                                                  -> CSV of ctx=ver pairs, concurrent with 5s timeout (PL2)
#   tuning_baseline_state <ctx> <kubectl_argv...>  -> two lines (TUNING_BASELINE=, SIDECAR_EGRESS_HOSTS=)
#                                                     queried from the LIVE mesh, on|off|unknown (PL2)
#   istio_live_version <ctx> <kubectl_argv...>     -> the version the member RUNS (its active
#       IstioRevision's .spec.version, when the Istio CR `default` is settled), or unknown, plus
#       the kind of failure and why (bounded reads, never a guess)
#   istio_version_resolve [--no-stop] <ctxs_csv> <dry_run> <kubectl_argv...>
#                                                  -> PL39: read the live version on every member
#       once per run, check it against the pin (ISTIO_VERSION_CHECK=fail dies, warn warns) and
#       export ISTIO_VERSION (what the results record), ISTIO_VERSION_PIN, ISTIO_VERSION_SOURCE
#       and ISTIO_VERSION_BY_CONTEXT; a no-op when a parent sweep already resolved them
#   istio_version_recheck <out_array> <kubectl_argv...>
#                                                  -> read it again at the end of a sweep;
#       sweep_outcome arguments (--problem when the version or active revision changed,
#       --note when unconfirmed or only readiness is off)
#   istio_generations_read <ctxs_csv> <kubectl_argv...>
#                                                  -> ctx=<Istio CR gen>/<IstioRevision gen>,...
#       read now, as ISTIO_GENERATIONS records them
#   istio_generations_diff [--cr-over <n>] [--unchecked] <before> <after>
#                                                  -> the members whose generations moved
#       (cr_moved<TAB>text), nothing when none did; --unchecked: those it could not compare
#   istio_generation_causes <cr_moved 0|1>         -> the likely causes of a generation change
#   istio_version_refresh <from> <ctxs_csv> <kubectl_argv...>
#                                                  -> read the generations and proxy versions
#       again after a sweep's own edit of the Istio CR (tuning), re-exported for its steps
#   istio_proxy_versions <ctxs_csv> <kubectl_argv...>
#                                                  -> ctx=<version>:<count>+...,... of the
#       proxies connected to each member's istiod (pilot_xds by version), unknown per member
#       when unreadable; istio_version_resolve exports it as ISTIO_PROXY_VERSIONS
#   istio_version_kv                               -> ISTIO_VERSION=, ISTIO_VERSION_PIN=,
#       ISTIO_VERSION_SOURCE=, ISTIO_VERSION_BY_CONTEXT=, ... ISTIO_GENERATIONS=,
#       ISTIO_PROXY_VERSIONS= lines for every preamble writer (PL36)
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

# harness_sha, harness_sha_for_sweep, harness_sha_check, report_harness_sha:
# tests/lib/common.sh (every report needs the harness it runs, and not every report sources
# this file).

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
	for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null || true; done
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
			get "$kind" "$name" -o name 2>/dev/null)"; then rc=0; else rc=$?; fi
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

# _istio_version_errline <file>: the first line of kubectl's stderr, as a why: without a
# carriage return, without the klog prefix ("E1017 10:00:00.000000   12345
# memcache.go:265] ", different in every process, so members that fail alike group
# together), with its API hosts and addresses masked (_istio_version_mask; it goes into
# the console, the outcome notes and the reports, never the host itself), at most 200
# characters.
_istio_version_errline() {
	local ivel_raw
	ivel_raw="$(head -n 1 "$1" | tr -d '\r' | sed -E 's/^[IWEF][0-9]{4} [0-9:.]+ +[0-9]+ [^]]+\] //')"
	ivel_raw="$(_istio_version_mask "${ivel_raw:0:1000}")"
	printf '%s\n' "${ivel_raw:0:200}"
}

# _istio_version_mask <text>: <text> with the hosts and addresses of kubectl's errors
# masked, for anything that records it: a URL's host (https://<api-host>/...), the host
# after "lookup" and after "dial tcp", the server of "The connection to the server
# <host>:<port> was refused", any other host.domain:port, the names of an x509 "certificate
# is valid for <names>, not <api-host>" (so members whose certificates differ group), IPv4
# addresses and IPv6 ones in brackets (with :: or eight groups, so [a:b] or a bracketed
# time stays) as <ip>. localhost and 127.0.0.1 stay as they are: "localhost:8080 was
# refused" is kubectl without a kubeconfig context, not an API host refusing. Context
# names stay (the grouping key masks them, nothing else). Who the operator is, too: the
# user of a Forbidden error (`User "<user>"`), an email address (<email>), the kubeconfig
# user a client-key error names ("for <user> due to"), and a home dir (/home/<name> and
# /Users/<name> as <home>): the placeholders redact-results.sh uses too.
_istio_version_mask() {
	sed -E -e 's#User "[^"]*"#User "<user>"#g' \
		-e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z][A-Za-z]+#<email>#g' \
		-e 's#(/home|/Users)/[^/ "'"'"':]+#<home>#g' \
		-e 's# for [^ ]+ due to # for <user> due to #g' \
		-e 's#localhost#@LOCALHOST@#g' -e 's#127\.0\.0\.1#@LOOPBACK@#g' \
		-e 's#([A-Za-z][A-Za-z0-9+.-]*://)(\[[0-9A-Fa-f:.]*\]|[^]/ "?:[]+)#\1<api-host>#g' \
		-e 's#is valid for [^"]*, not [^ ",]+#is valid for <names>, not <api-host>#g' \
		-e 's#lookup [^ :@]+#lookup <api-host>#g' \
		-e 's#the server [^ @]+ was refused#the server <api-host> was refused#g' \
		-e 's#\[[0-9A-Fa-f:.]*::[0-9A-Fa-f:.]*\](:[0-9]+)?#<ip>#g' \
		-e 's#\[([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}\](:[0-9]+)?#<ip>#g' \
		-e 's#\[([0-9A-Fa-f]{1,4}:){6}[0-9]{1,3}(\.[0-9]{1,3}){3}\](:[0-9]+)?#<ip>#g' \
		-e 's#(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?#\1<ip>#g' \
		-e 's#dial tcp [A-Za-z][^ :]*#dial tcp <api-host>#g' \
		-e 's#(^|[ ("'"'"'=])[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+:([0-9]+)#\1<api-host>:\3#g' \
		-e 's#@LOCALHOST@#localhost#g' -e 's#@LOOPBACK@#127.0.0.1#g' <<<"$1"
}

# _istio_version_hostkey <why>: <why> masked (_istio_version_mask: URLs, hosts, x509
# names, IPv4 and IPv6 addresses) and with the context name kubectl does not find masked
# too (each of its messages), as a grouping key: members whose reads fail the same
# way on their own API hosts group into one entry. Never printed.
_istio_version_hostkey() {
	_istio_version_mask "$1" | sed -E \
		-e 's#context "[^"]*" does not exist#context "<ctx>" does not exist#g' \
		-e 's#no context exists with the name: "[^"]*"#no context exists with the name: "<ctx>"#g' \
		-e 's#context was not found for specified context: [^ ]+#context was not found for specified context: <ctx>#g'
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
#      .spec.namespace), also when the state is Healthy (Sail's Ready only compares
#      readyReplicas with replicas, so a Deployment whose status has not moved yet, or
#      whose old ReplicaSet is not scaled down yet, still serves old pods).
#      .status.observedGeneration below .metadata.generation, .status.updatedReplicas
#      below .status.replicas, or .status.terminatingReplicas above 0 (absent on an
#      API server without it) is an istiod rollout in progress, old and new pods both
#      serving: kind rolling, with the version it rolls out to (its why starts "istiod
#      pods still terminating" when every pod is updated and old ones are still
#      terminating). Otherwise kind ok when
#      the state is Healthy, else notready (a pod restart, an HPA scale-up, IstioCNI not
#      healthy): the version, with the state as why.
# Kind read: kubectl failed or answered nothing (no CR, no access, unreachable); the
# reason is the first line of its stderr, and a caller may retry it. A failed Deployment
# read still returns the revision's version (line 5), for istio_version_recheck. A CR
# that is not settled and whose IstioRevision read failed is kind read too (its why
# names the revision), unless it is migrating; so is a settled CR whose IstioRevision read
# failed (its why starts "IstioRevision <rev>: ").
# With --generations, two more lines: the Istio CR's .metadata.generation and its
# active IstioRevision's (empty when not read), from the same reads; a spec edit bumps
# them (Sail's status.observedGeneration follows them), so istio_version_recheck sees an
# edit that the version alone does not show (X->Y->X, a values change).
# shellcheck disable=SC2329
istio_live_version() {
	local ilv_gens=0 gen="" rgen=""
	if [[ "${1:-}" == --generations ]]; then
		ilv_gens=1
		shift
	fi
	_istio_live_version_read "$@"
	((ilv_gens == 0)) || printf '%s\n%s\n' "${gen//[^0-9]/}" "${rgen//[^0-9]/}"
}

# _istio_live_version_read <ctx> <kubectl_argv...>: istio_live_version's reads and its six
# lines; sets the caller's gen and rgen.
# shellcheck disable=SC2329
_istio_live_version_read() {
	local ctx="$1" errf out rc=0 ogen state inuse rev recon why="" kind=state ready="" rerr
	local rver="" rv="" rns="" rvrev="" rogen="" dep dgen dogen dreps dupd dterm
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
			# Its IstioRevision could not be read either. Say so, and (but for a
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
		# The why names the read that failed (the CR answered).
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
	# An istiod rollout in progress is neither Healthy nor "only readiness".
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
		# Every pod updated, only old pods still terminating: say that, not "rolling out".
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
# istio_live_version --generations for every member concurrently (its six lines, then the
# two generations), into <dir>/<index> (index, not name: a
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
		istio_live_version --generations "${_ivra_ctxs[i]}" "$@" > "${dir}/${i}" &
		pids+=($!)
	done
	for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null || true; done
	((once == 0)) || return 0
	for i in "${!_ivra_ctxs[@]}"; do
		kind="$(sed -n 2p "${dir}/${i}" 2>/dev/null || true)"
		case "$kind" in ok | notready | rolling | migrating | state | value) ;; *) again+=("$i") ;; esac
	done
	((${#again[@]})) || return 0
	sleep 1
	pids=()
	for i in ${again[@]+"${again[@]}"}; do
		istio_live_version --generations "${_ivra_ctxs[i]}" "$@" > "${dir}/${i}" &
		pids+=($!)
	done
	for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null || true; done
}

# _istio_version_repro <kind> <ctx> <kubectl_argv...>: the command that shows an operator
# what the read saw on <ctx>. <kind> deploy:<ns>/<name> is the istiod Deployment that was
# read; pods:<ns>[/<rev>] its istiod pods (old pods still terminating; of
# that revision, the istio.io/rev label, when known); revision:<name> the IstioRevision
# whose read failed; value the IstioRevisions; anything else the Istio CR.
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
	printf '%s|%s|%s|%s|%s|%s|%s|%s' "${ISTIO_VERSION_SOURCE:-}" "${ISTIO_VERSION_PIN:-}" "${ISTIO_VERSION:-}" \
		"${ISTIO_VERSION_BY_CONTEXT:-}" "${ISTIO_NOTREADY_AT_START:-}" "${ISTIO_READY_WAITED_SEC:-}" \
		"${ISTIO_GENERATIONS:-}" "${ISTIO_PROXY_VERSIONS:-}"
}

# istio_version_resolve [--no-stop] [--resumed-at <utc>] <ctxs_csv> <dry_run 0|1> <kubectl_argv...>:
# The results record the Istio version the mesh runs, not only the
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
#   ISTIO_NOTREADY_AT_START   ctx=<state>,... for the members still not ready after the
#                             wait below (rolling for an istiod rollout still in progress;
#                             unreadable when one was seen and every re-read failed),
#                             none when every member was ready, unchecked under --dry-run
#                             (and when the check stopped unexpectedly)
#   ISTIO_READY_WAITED_SEC    how long that wait took (0 when nobody was waited for)
#   ISTIO_GENERATIONS         ctx=<Istio CR .metadata.generation>/<active IstioRevision
#                             .metadata.generation>,... (unknown for a part not read;
#                             unchecked under --dry-run), for istio_version_recheck and a
#                             controlplane --resume (a spec edit bumps them)
#   ISTIO_PROXY_VERSIONS      the proxy versions connected to each member's istiod
#                             (istio_proxy_versions; unchecked under --dry-run); a member
#                             whose proxies are not all on its istiod's version gets a warning
#                             here and a note in the sweep outcome (istio_version_recheck)
# and, for istio_version_recheck, the private _ISTIO_VERSION_REVS (ctx=activeRevisionName,...).
# --resumed-at <utc> (a controlplane --resume): the run appends to a TSV whose preamble
# keeps the first run's ISTIO_NOTREADY_AT_START, so istio_version_recheck reports this
# start as ISTIO_NOTREADY_AT_RESUME, with that time, in the sweep outcome.
# ISTIO_VERSION_CHECK=fail (default) dies when a member's version is unknown, members
# differ, or it differs from the pin (a leading v is ignored); warn prints the same
# problem as a warning and goes on. --no-stop (gateway-api, a read-only check) always
# warns. Every unknown member is listed with why and a command that reproduces the read
# (members with the same why share one entry, its command shown for the first).
# Readiness is not the version: a member whose only issue is its state (istiod or
# IstioCNI not ready, kind notready) or whose istiod is rolling out (kind rolling) is
# read again every ISTIO_VERSION_READY_POLL_SEC until ISTIO_VERSION_READY_WAIT_SEC have
# passed (a SECONDS deadline), or until it is settled and ready (a transient unsettled
# read keeps it in the wait; one more read after a rollout ends, one poll past the
# deadline when it ended on the last read before it); its answer at the deadline
# counts. A re-read that fails keeps its previous answer (a CR that answers not
# settled is an answer, also when its IstioRevision read fails), except the read that
# confirms a rollout just ended: without it the member is not ready, as
# rollout-unconfirmed, its version read, never the ok before it. Still not ready:
# its version is recorded and a warning names the state, which never stops the run. Still
# rolling: its version is unknown (old and new istiod pods both serve), which stops the
# run under fail. Under fail, nothing is waited for when another member already stops the
# run (unknown, another version, or not the pin). The reads and the verdict run in
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
	# This shell's own --resume start, for istio_version_recheck (never inherited).
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
	is_pos_int "${ISTIO_PROXY_READ_PARALLEL:-20}" \
		|| die "ISTIO_PROXY_READ_PARALLEL must be a positive integer of members (got: ${ISTIO_PROXY_READ_PARALLEL:-}); see config/options.env"
	((nostop)) && policy=warn
	export ISTIO_VERSION_PIN="${ISTIO_VERSION:-unknown}"
	if ((dry)); then
		export ISTIO_VERSION_SOURCE=pin ISTIO_VERSION_BY_CONTEXT=unchecked _ISTIO_VERSION_REVS=""
		export ISTIO_NOTREADY_AT_START=unchecked ISTIO_READY_WAITED_SEC=unchecked
		export ISTIO_GENERATIONS=unchecked ISTIO_PROXY_VERSIONS=unchecked
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
	# The reads and the verdict run apart (_istio_version_isolated), and only a result
	# that ends with END counts. Its own stop (fail) prints STOP before it dies. Anything
	# else that ends it early, such as bash 4.3-5.1 aborting on a bad array subscript, fails
	# closed: under fail the run stops here, under warn it records unknown, never the pin.
	# Every temp file the check makes is under its own work dir (TMPDIR), removed when it
	# ends, also when it stopped partway or was interrupted.
	local ivr_text="" ivr_rc=0 ivr_line ivr_why
	local -a ivr_lines=()
	_istio_version_isolated ivr_rc ivr_text _istio_version_resolve_live "$ctxs_csv" "$policy" "$nostop" "$resumed" "$wait_max" "$poll" "$@"
	[[ -z "$ivr_text" ]] || mapfile -t ivr_lines <<< "$ivr_text"
	if ((ivr_rc == 0 && ${#ivr_lines[@]} > 0)) && [[ "${ivr_lines[-1]}" == END ]]; then
		for ivr_line in "${ivr_lines[@]}"; do
			case "${ivr_line%%=*}" in
			ISTIO_VERSION_SOURCE | ISTIO_VERSION_BY_CONTEXT | _ISTIO_VERSION_REVS | ISTIO_NOTREADY_AT_START | ISTIO_READY_WAITED_SEC | ISTIO_GENERATIONS | ISTIO_VERSION)
				export "${ivr_line%%=*}=${ivr_line#*=}"
				;;
			esac
		done
	elif [[ $'\n'"${ivr_text}"$'\n' == *$'\nSTOP\n'* ]]; then
		exit 1
	else
		ivr_why="the Istio version check stopped unexpectedly (exit ${ivr_rc}; the error is above), so the version the members run is not known"
		# A --resume never goes on with an unknown version, so warn would not help.
		[[ "$policy" != fail || -z "$resumed" ]] \
			|| die "${ivr_why}."$'\n'"Nothing was changed. A --resume never goes on with an unknown version (ISTIO_VERSION_CHECK=warn would not help): fix what the error above shows, then run the same --resume again."
		[[ "$policy" != fail ]] || die "${ivr_why}."$'\n'"Nothing was changed. To go on anyway and record ISTIO_VERSION=unknown, set ISTIO_VERSION_CHECK=warn."
		ivr_line="ISTIO_VERSION_CHECK=warn"
		((nostop == 0)) || ivr_line="a read-only check never stops on this"
		if [[ -n "$resumed" ]]; then
			# 003 refuses a --resume on an unknown version, whatever the policy, when its
			# TSV records ISTIO_VERSION (every TSV this harness writes does), so no "Going on".
			echo "warning: ${ivr_why}." >&2
		else
			echo "warning: ${ivr_why}."$'\n'"Going on (${ivr_line}): the results record ISTIO_VERSION=unknown (ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN})." >&2
		fi
		ivr_line=""
		for ivr_why in "${ivr_ctxs[@]}"; do ivr_line="${ivr_line:+${ivr_line},}${ivr_why}=unknown"; done
		export ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT="$ivr_line" _ISTIO_VERSION_REVS=""
		export ISTIO_NOTREADY_AT_START=unchecked ISTIO_READY_WAITED_SEC=unchecked ISTIO_VERSION=unknown
		export ISTIO_GENERATIONS="$ivr_line"
	fi
	# The proxy versions each member's istiod serves, once the run goes on (never dies).
	ISTIO_PROXY_VERSIONS="$(istio_proxy_versions "$ctxs_csv" "$@")"
	export ISTIO_PROXY_VERSIONS
	_istio_proxy_versions_warn
	_ISTIO_VERSION_RESOLVED="$(_istio_version_marker)"
	export _ISTIO_VERSION_RESOLVED
}

# _istio_version_isolated <rc_var> <out_var> <fn> <args...>: Run <fn> in a subshell
# (under set -e when the caller has it), set <out_var> to its stdout and <rc_var> to its
# exit status. An error bash cannot recover from (a bad array subscript in bash 4.3 to
# 5.1 aborts the whole command, and the run would go on) ends only the subshell, so the
# caller can fail closed. Every temp file <fn> makes is under a work dir of its own
# (TMPDIR), which a subshell around it makes and removes however it ends: also on Ctrl-C,
# SIGTERM or SIGHUP (its traps), and before the caller's own signal trap can end the run
# (that trap runs once this returns), so an interrupted sweep start or end check leaves
# nothing in TMPDIR. Call it as a plain command, never in a || list or a condition: set -e
# is ignored there, also inside the subshell. It always returns 0.
_istio_version_isolated() {
	local -n _ivi_rc="$1" _ivi_text="$2"
	local _ivi_e=0
	shift 2
	[[ "$-" != *e* ]] || _ivi_e=1
	set +e
	_ivi_text="$(
		_ivi_w="$(mktemp -d 2>/dev/null)" || exit 125
		trap 'rm -rf "$_ivi_w"' EXIT
		for _ivi_s in HUP INT TERM; do
			# shellcheck disable=SC2064  # the signal's name, now
			trap "rm -rf \"\$_ivi_w\"; trap - ${_ivi_s}; kill -s ${_ivi_s} \"\$BASHPID\"" "$_ivi_s"
		done
		# TMPDIR as the command's own environment (a function's too: bash exports it to the
		# processes the function runs), never assigned here: a TMPDIR set in a subshell reads,
		# to a one-call shellcheck, as lost by every script that sources this file (SC2031).
		(
			((_ivi_e == 0)) || set -e
			TMPDIR="$_ivi_w" "$@"
		) > "${_ivi_w}/result"
		_ivi_x=$?
		cat "${_ivi_w}/result" 2>/dev/null
		exit "$_ivi_x"
	)"
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
	local n_notready=0 n_rolling=0 n_read=0 n_unsettled=0 n_revread=0 n_depread=0 ivr_what nr_at_start="" t0 deadline elapsed=0 polls=0 nap doomed="" vset=""
	local ivr_skipped=0 ivr_offpin="" ivr_stale="" allfail st rk label dre='Deployment ([a-z0-9.-]+)/([a-z0-9.-]+)' gens="" ivr_g1 ivr_g2
	local ivr_over=0 ivr_rg ivr_rltail="" ivr_rlv ivr_rdg ivr_ok n_term=0 ivr_n ivr_rdep ivr_rdx
	local -a ivr_sw=() ivr_rlk=() ivr_rdk=() ivr_opk=()
	local -A ivr_rlm=() ivr_rlf=() ivr_rlw=() ivr_rlc=() ivr_rlt=() ivr_rdm=() ivr_rdf=() ivr_rdc=() ivr_opm=()
	local -A ivr_rdw=() ivr_rdd=()
	tmp="$(mktemp -d)"
	_istio_version_read_all "$tmp" ctxs "$@"
	# Wait while only readiness is off or istiod is rolling out, until a SECONDS
	# deadline. A member that entered the wait is read again until the deadline or
	# until it reads ok (and, right after a rollout, once more; also when the
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
			# At the deadline only a rollout that just ended is read again (its extra read),
			# one poll later, and only once; everyone else keeps their last answer.
			((ivr_over == 0)) || break
			ivr_sw=()
			for i in "${waitfor[@]}"; do [[ -z "${ivr_settle[$i]:-}" ]] || ivr_sw+=("$i"); done
			((${#ivr_sw[@]})) || break
			ivr_over=1
			waitfor=("${ivr_sw[@]}")
		fi
		if [[ "$policy" == fail ]]; then
			# Under fail, a member outside the wait whose version is unknown, members on
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
			# A CR that answered "not settled" is an answer, also when its
			# IstioRevision read then failed; only a read that learned nothing keeps the last one.
			if [[ "$kind" == read && "$(sed -n 3p "${wtmp}/${j}" 2>/dev/null || true)" == "the Istio CR default is not settled: "* ]]; then
				kind=unsettled
			fi
			case "$kind" in
			ok | notready | rolling | migrating | state | value | unsettled)
				# A rollout that just ended may still have old istiod pods draining their
				# xDS streams (shutdownDuration): read it once more before it counts as ok.
				prev="$(sed -n 2p "${tmp}/${i}" 2>/dev/null || true)"
				if [[ "$prev" == rolling && "$kind" != rolling ]]; then ivr_settle[$i]=1; else unset 'ivr_settle[$i]'; fi
				ivr_rok[$i]=1
				unset 'ivr_rerr[$i]'
				mv -f "${wtmp}/${j}" "${tmp}/${i}"
				;;
			*)
				# A re-read that fails keeps the member's previous answer (the warning says so).
				ivr_rerr[$i]="$(sed -n 3p "${wtmp}/${j}" 2>/dev/null || true)"
				;;
			esac
		done
		rm -rf "$wtmp"
	done
	((polls == 0)) || elapsed=$((SECONDS - t0))
	for i in "${!ctxs[@]}"; do
		v="" kind="" why="" rev="" rver="" state="" ivr_g1="" ivr_g2=""
		{ IFS= read -r v; IFS= read -r kind; IFS= read -r why; IFS= read -r rev; IFS= read -r rver; IFS= read -r state
			IFS= read -r ivr_g1; IFS= read -r ivr_g2; } 2>/dev/null < "${tmp}/${i}" || true
		[[ -n "$v" ]] || v=unknown
		gens="${gens:+${gens},}${ctxs[i]}=${ivr_g1:-unknown}/${ivr_g2:-unknown}"
		# A rollout that ended, whose extra read never answered, is not ready:
		# its old istiod pods may still serve; never the ok the read before it saw.
		if [[ "$kind" == ok && -n "${ivr_settle[$i]:-}" ]]; then
			kind=notready state=rollout-unconfirmed
		fi
		allfail=0
		[[ -z "${ivr_rerr[$i]+x}" || -n "${ivr_rok[$i]:-}" ]] || allfail=1
		if [[ "$kind" == rolling ]]; then
			# Still rolling out: old and new istiod pods both serve, so the run would
			# not measure one version.
			v=unknown
			if ((allfail)); then
				# Unreachable since its first read, not known to be still rolling out
				# (recorded as such, as the console says).
				nr_at_start="${nr_at_start:+${nr_at_start},}${ctxs[i]}=unreadable"
				why="every re-read during the wait failed (${ivr_rerr[$i]:-no answer}); the first read saw: ${why}"
				kind="read"
			else
				nr_at_start="${nr_at_start:+${nr_at_start},}${ctxs[i]}=rolling"
				n_rolling=$((n_rolling + 1))
				# Every pod updated, only old pods still terminating: its own group,
				# wording and check (its pods), and it runs that version (the Also clause).
				ivr_rlv="is rolling out" ivr_rltail="still rolling out"
				if [[ "$why" == "istiod pods still terminating "* ]]; then
					ivr_rlv="runs" ivr_rltail="still terminating"
					n_term=$((n_term + 1))
				fi
				# Say so when the wait was skipped, not "after 0s".
				if ((ivr_skipped)); then ivr_rltail="not waited for"; else ivr_rltail+=" after ${elapsed}s"; fi
				if [[ "${rver#v}" != "${ISTIO_VERSION_PIN#v}" ]]; then
					ivr_ok="${ivr_rlv}|${rver}"
					[[ -n "${ivr_opm[$ivr_ok]+x}" ]] || ivr_opk+=("$ivr_ok")
					ivr_opm[$ivr_ok]="${ivr_opm[$ivr_ok]:+${ivr_opm[$ivr_ok]}, }${ctxs[i]}"
				fi
				# Grouped by Deployment and version below (one line per group).
				[[ "$why" =~ $dre ]] || true
				ivr_rg="${BASH_REMATCH[1]:-?}/${BASH_REMATCH[2]:-?} ${rver}"
				[[ "$ivr_rlv" != runs ]] || ivr_rg+=" terminating"
				[[ -n "${ivr_rlc[$ivr_rg]:-}" ]] || { ivr_rlk+=("$ivr_rg"); ivr_rlf[$ivr_rg]="${ctxs[i]}"; ivr_rlw[$ivr_rg]="${why}; ${ivr_rltail}"; ivr_rlc[$ivr_rg]=0; ivr_rlt[$ivr_rg]="$ivr_rltail"; }
				ivr_n="${ivr_rlc[$ivr_rg]}" # Never x[$key] in arithmetic (bash 4.3-5.1 expand the key twice)
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
				# A failed Deployment read's command names the Deployment that was read;
				# A failed IstioRevision read's, that revision.
				rk="${kind:-read}"
				if [[ "$why" == "istiod Deployment "* && "$why" =~ $dre ]]; then
					rk="deploy:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
					# It is read only once the Istio CR and its revision are settled.
					n_depread=$((n_depread + 1))
				elif [[ "$kind" == read && -n "$rev" && ( "$why" == "IstioRevision ${rev}: "* \
					|| ( "$why" == "the Istio CR default is not settled: "* && "$why" == *"; IstioRevision ${rev}: "* ) ) ]]; then
					rk="revision:${rev}"
					# A settled CR whose IstioRevision read failed: waiting does not help.
					[[ "$why" != "IstioRevision ${rev}: "* ]] || n_revread=$((n_revread + 1))
				fi
				# Grouped by that command's kind and why (one entry per group). By the
				# why with URLs, hosts and IPs masked, so members that each name their own API
				# host group; the first member's why is the one printed.
				ivr_rdg="${rk}|$(_istio_version_hostkey "${why:-no answer}")"
				if [[ -z "${ivr_rdc[$ivr_rdg]:-}" ]]; then
					ivr_rdk+=("$ivr_rdg")
					ivr_rdf[$ivr_rdg]="${ctxs[i]}" ivr_rdc[$ivr_rdg]=0 ivr_rdw[$ivr_rdg]="${why:-no answer}"
				elif [[ "${ivr_rdw[$ivr_rdg]}" != "${why:-no answer}" ]]; then
					ivr_rdd[$ivr_rdg]=1
				fi
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
				# Grouped by state, as the end note is.
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
	# Members whose version is unknown (not rolling), one entry per command kind and why,
	# with the command that reproduces the read (shown for the first member of a group).
	for ivr_rdg in ${ivr_rdk[@]+"${ivr_rdk[@]}"}; do
		if [[ "${ivr_rdc[$ivr_rdg]}" == 1 ]]; then
			detail+=$'\n'"  ${ivr_rdf[$ivr_rdg]}: ${ivr_rdw[$ivr_rdg]}"
			detail+=$'\n'"    reproduce: $(_istio_version_repro "${ivr_rdg%%|*}" "${ivr_rdf[$ivr_rdg]}" "$@")"
		else
			ivr_rdx=""
			[[ -z "${ivr_rdd[$ivr_rdg]:-}" ]] || ivr_rdx="; shown for ${ivr_rdf[$ivr_rdg]}, the others name their own contexts"
			detail+=$'\n'"  ${ivr_rdm[$ivr_rdg]} (${ivr_rdc[$ivr_rdg]} members${ivr_rdx}): ${ivr_rdw[$ivr_rdg]}"
			detail+=$'\n'"    reproduce (shown for ${ivr_rdf[$ivr_rdg]}): $(_istio_version_repro "${ivr_rdg%%|*}" "${ivr_rdf[$ivr_rdg]}" "$@")"
		fi
	done
	# Rolling members, one line per Deployment and version, with a check command (a
	# rollout's command is a check, and names the Deployment that was read; for old
	# pods still terminating, the istiod pods).
	for ivr_rg in ${ivr_rlk[@]+"${ivr_rlk[@]}"}; do
		ivr_rlv="${ivr_rg#* }"
		ivr_rlv="${ivr_rlv%% *}"
		if [[ "$ivr_rg" == *" terminating" ]]; then
			# The pods of that revision: Sail's istiod-<rev> (istiod: default) Deployment
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
	# Members off the pin, one entry per version (and whether it is still rolling out).
	for ivr_ok in ${ivr_opk[@]+"${ivr_opk[@]}"}; do
		ivr_rlv="${ivr_ok%%|*}"
		if [[ "${ivr_opm[$ivr_ok]}" == *", "* ]]; then
			case "$ivr_rlv" in runs) ivr_rlv="run" ;; *) ivr_rlv="are rolling out" ;; esac
		fi
		ivr_offpin="${ivr_offpin:+${ivr_offpin}; }${ivr_opm[$ivr_ok]} ${ivr_rlv} ${ivr_ok#*|}"
	done
	# Where the pin came from: an ISTIO_VERSION exported in the shell, or versions.env (also
	# for the advice about a member that is off the pin while another is unknown).
	# shellcheck disable=SC2016  # the sed pattern matches a literal ${ISTIO_VERSION:-...}
	envpin="$(sed -n 's/^export ISTIO_VERSION="\${ISTIO_VERSION:-\(.*\)}".*$/\1/p' \
		"${ROOT:-.}/config/versions.env" 2>/dev/null || true)"
	[[ "$envpin" != "$ISTIO_VERSION_PIN" ]] || envpin=""
	if [[ "$distinct" == */* ]]; then live="mixed:${distinct}"; else live="$distinct"; fi
	if ((bad)); then
		# Only the fixes that can help. Old istiod pods still terminating are not
		# a rollout to wait out (one stuck in Terminating stays until it is force-deleted).
		# The reads that failed once the Istio CR was settled (nothing to wait for).
		ivr_what="IstioRevision and istiod Deployment"
		((n_depread)) || ivr_what="IstioRevision"
		((n_revread)) || ivr_what="istiod Deployment"
		if ((n_rolling)); then
			problem="cannot confirm the running Istio version on ${bad} of ${#ctxs[@]} members:${detail}"
			if ((n_term == 0)); then
				label="their istiod rollout is complete"
			elif ((n_term == n_rolling)); then
				label="their old istiod pods are gone (a pod stuck in Terminating, on a lost node say, needs a force delete)"
			else
				label="their istiod rollout is complete and their old istiod pods are gone"
			fi
			if ((n_unsettled == 0 && n_read > 0 && n_read == n_revread + n_depread)); then
				fix="Fix access to those members (kubeconfig, login, network) and to their ${ivr_what}, or wait until ${label}"
			elif ((n_read + n_unsettled)); then
				fix="Fix access to those members (kubeconfig, login, network), or wait until their Istio CR is settled and ${label}"
			else
				fix="Wait until ${label}"
			fi
			((ivr_skipped)) || fix+=" (or raise ISTIO_VERSION_READY_WAIT_SEC)"
		else
			problem="cannot read the running Istio version on ${bad} of ${#ctxs[@]} members:${detail}"
			fix="Fix access to those members (kubeconfig, login, network), or wait until their Istio CR is settled"
			# Only IstioRevision or istiod Deployment reads failed, on settled CRs:
			# there is nothing to wait for.
			((n_unsettled || n_read != n_revread + n_depread)) \
				|| fix="Fix access to those members (kubeconfig, login, network) and to their ${ivr_what} (their Istio CR is settled)"
		fi
		# The errors above are masked (they go into the results as well): say so, and
		# where the full one is.
		case "$detail" in
		*'<api-host>'* | *'<ip>'* | *'<names>'* | *'<user>'* | *'<email>'* | *'<home>'*)
			problem+=$'\n'"  (API hosts, addresses, user names and home dirs are masked above; run a reproduce line for the full error)"
			;;
		esac
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
			# A --resume never goes on with an unknown version, so warn would not help.
			case "${resumed:+r}/${live#mixed:}/" in
			r/*/unknown/* | r/unknown/*) die "${problem}${fix}"$'\n'"Nothing was changed. A --resume never goes on with an unknown version (ISTIO_VERSION_CHECK=warn would not help): once every member can be read, run the same --resume again." ;;
			esac
			die "${problem}${fix}"$'\n'"Nothing was changed. To go on anyway and record ISTIO_VERSION=${live}, set ISTIO_VERSION_CHECK=warn."
		fi
		why="ISTIO_VERSION_CHECK=warn"
		((nostop == 0)) || why="a read-only check never stops on this"
		case "${resumed:+r}/${live#mixed:}/" in
		# 003 refuses a --resume on an unknown version, whatever the policy, when its TSV
		# records ISTIO_VERSION (every TSV this harness writes does), so no "Going on".
		r/*/unknown/* | r/unknown/*) echo "warning: ${problem}${fix}" >&2 ;;
		*) echo "warning: ${problem}${fix}"$'\n'"Going on (${why}): the results record ISTIO_VERSION=${live} (ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN})." >&2 ;;
		esac
	fi
	if ((n_notready)); then
		{
			echo "WARNING: istiod or IstioCNI is still not ready on ${n_notready} of ${#ctxs[@]} members after ${elapsed}s:"
			for st in ${ivr_states[@]+"${ivr_states[@]}"}; do
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
		"ISTIO_NOTREADY_AT_START=${nr_at_start:-none}" "ISTIO_READY_WAITED_SEC=${elapsed}" "ISTIO_GENERATIONS=${gens}" "ISTIO_VERSION=${live}" END
}

# _istio_notready_notes <out_arrayname> <start|end|resume|first> <ctx=state,...>
# [<waited_sec>] [<resumed_at>]: the sweep_outcome --note arguments for members whose istiod
# or IstioCNI was not ready (the list as ISTIO_NOTREADY_AT_START holds it; rolling for an
# istiod rollout in progress): one line on what that means and what to check, then one line
# per state with its members. Appends nothing for an empty list, unchecked or unknown,
# nor for none, except at a resume: the TSV preamble keeps the first run's value, so
# the outcome records the resume's start time and its own value, none included (an --info
# line: an all-clear is not a warning). <first> is the first run's value, from the
# TSV preamble, for a resume's outcome (<resumed_at>: the preamble's DATE).
_istio_notready_notes() {
	local -n _inn_out="$1"
	local when="$2" list="$3" waited="${4:-}" at="${5:-}" pair st n label inn_at="$2"
	local -a pairs=() states=()
	local -A members=()
	case "$list" in "" | unchecked | unknown) return 0 ;; esac
	[[ "$when" != first ]] || inn_at="first run's start"
	if [[ "$when" == resume && "$list" == none ]]; then
		_inn_out+=(--info "this --resume started at ${at} with every member ready (ISTIO_NOTREADY_AT_RESUME=none, ISTIO_READY_WAITED_SEC=${waited:-0}); the TSV preamble's ISTIO_NOTREADY_AT_START is the first run's (a resume's, when the first run wrote no TSV)")
		return 0
	fi
	[[ "$list" != none ]] || return 0
	IFS=, read -r -a pairs <<<"$list"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		st="${pair##*=}"
		[[ -n "${members[$st]+set}" ]] || states+=("$st")
		members[$st]="${members[$st]:+${members[$st]}, }${pair%=*}"
	done
	case "$waited" in "" | unchecked) waited="" ;; *) waited=", after waiting ${waited}s" ;; esac
	if [[ "$when" == start ]]; then
		_inn_out+=(--note "istiod or IstioCNI was still not ready at the start of the sweep${waited} (ISTIO_NOTREADY_AT_START): the first cells may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted")
	elif [[ "$when" == first ]]; then
		_inn_out+=(--note "istiod or IstioCNI was still not ready when this sweep's first run started${at:+ at ${at}}${waited} (ISTIO_NOTREADY_AT_START, in the TSV preamble): the first cells it ran may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted")
	elif [[ "$when" == resume ]]; then
		_inn_out+=(--note "istiod or IstioCNI was still not ready when this --resume started at ${at}${waited} (ISTIO_NOTREADY_AT_RESUME=${list}; the TSV preamble's ISTIO_NOTREADY_AT_START is the first run's (a resume's, when the first run wrote no TSV)): the first cells the resume ran (rows from ${at} on) may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted")
	else
		_inn_out+=(--note "istiod or IstioCNI was not ready at the end of the sweep, on the same Istio version: the last cells may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted")
	fi
	for st in ${states[@]+"${states[@]}"}; do
		pairs=()
		IFS=, read -r -a pairs <<<"${members[$st]//, /,}"
		label="$st"
		[[ "$st" != rolling ]] || label="rolling (an istiod rollout in progress, or old istiod pods still terminating)"
		[[ "$st" != unreadable ]] || label="unreadable (an istiod rollout at the first read, then every re-read failed)"
		[[ "$st" != rollout-unconfirmed ]] || label="rollout-unconfirmed (an istiod rollout had just ended, and the read that confirms no old istiod pod still serves failed)"
		n="${#pairs[@]} members"
		((${#pairs[@]} > 1)) || n="1 member"
		_inn_out+=(--note "not ready at the ${inn_at}: ${label} on ${n} (${members[$st]})")
	done
}

# istio_generation_causes <cr_moved 0|1>: What usually bumps a generation while the
# version and the active revision stay the same, for a message that reports one: with the
# Istio CR's (1), an edit of it (a version changed and changed back, a values change);
# with only the IstioRevision's (0), Sail rendering the revision again: an OSSM operator
# upgrade (an install plan approved automatically: installPlanApproval Automatic,
# charts/spoke-ossm-operator) or a change of the cluster's TLS security profile, which Sail
# renders into istiod's values.
# shellcheck disable=SC2329
istio_generation_causes() {
	if [[ "${1:-1}" == 1 ]]; then
		printf '%s' "a version changed and changed back, or a values change (an edit of the Istio CR)"
	else
		printf '%s' "only the IstioRevision moved, which is usually Sail rendering it again: an OSSM operator upgrade (installPlanApproval Automatic on its Subscription, charts/spoke-ossm-operator) or a change of the cluster's TLS security profile"
	fi
}

# istio_generations_read <ctxs_csv> <kubectl_argv...>: One line, ctx=<Istio CR
# generation>/<active IstioRevision generation>,... (unknown for a part not read), as
# ISTIO_GENERATIONS records them, read now (every member concurrently, one retry for a
# failed read: _istio_version_read_all). Never dies.
# shellcheck disable=SC2329
istio_generations_read() {
	local ctxs_csv="$1" igr_dir i igr_g1 igr_g2 igr_x out=""
	shift
	local -a igr_ctxs=()
	split_csv "$ctxs_csv" igr_ctxs
	igr_dir="$(mktemp -d 2>/dev/null)" || igr_dir=""
	[[ -z "$igr_dir" ]] || _istio_version_read_all "$igr_dir" igr_ctxs "$@"
	for i in "${!igr_ctxs[@]}"; do
		igr_g1="" igr_g2=""
		if [[ -n "$igr_dir" ]]; then
			# istio_live_version --generations: six lines, then the two generations.
			{ for ((igr_x = 0; igr_x < 6; igr_x++)); do IFS= read -r _ || break; done
				IFS= read -r igr_g1; IFS= read -r igr_g2; } 2>/dev/null < "${igr_dir}/${i}" || true
		fi
		out="${out:+${out},}${igr_ctxs[i]}=${igr_g1:-unknown}/${igr_g2:-unknown}"
	done
	[[ -z "$igr_dir" ]] || rm -rf "$igr_dir"
	printf '%s\n' "$out"
}

# istio_generations_diff [--cr-over <n>] [--unchecked] <before> <after>: the members whose
# generations moved between two istio_generations_read lines, as one line
# "<cr_moved 0|1><TAB><ctx> (Istio CR generation 3 -> 5, IstioRevision 3 -> 4), ...",
# cr_moved 1 when an Istio CR's own generation moved (istio_generation_causes); nothing
# when none moved. A part unknown on either side, or a member one line lacks, is not
# compared. --cr-over <n>: only an Istio CR generation that rose by more than <n>, or fell
# (a CR deleted and created again), the IstioRevision's left out, for a span in which the
# caller patched each Istio CR <n> times (a merge patch that changes the spec raises it by
# exactly 1). --unchecked: the members that were not compared in full instead, as
# "<ctx> (<before> -> <after>), ..." (unknown for a member a line lacks), nothing when
# every one was, so a caller can say which comparison it could not make; with --cr-over, a
# member is compared in full when its Istio CR generations are (the IstioRevision's are
# left out). The lines reach awk through the environment (PL19). Never dies.
# shellcheck disable=SC2329
istio_generations_diff() {
	local over=-1 unchecked=0
	while [[ "${1:-}" == --cr-over || "${1:-}" == --unchecked ]]; do
		if [[ "$1" == --cr-over ]]; then
			over="${2:-0}"
			shift 2 || shift
		else
			unchecked=1
			shift
		fi
	done
	_IGD_A="${1:-}" _IGD_B="${2:-}" awk -v over="$over" -v un="$unchecked" 'BEGIN {
		n = split(ENVIRON["_IGD_A"], x, ",")
		for (i = 1; i <= n; i++) { if (x[i] !~ /=/) continue; k = x[i]; sub(/=[^=]*$/, "", k); v = x[i]; sub(/^.*=/, "", v); before[k] = v; ka[++na] = k }
		m = split(ENVIRON["_IGD_B"], y, ","); out = ""; cr = 0; nc = ""
		for (i = 1; i <= m; i++) {
			if (y[i] !~ /=/) continue
			k = y[i]; sub(/=[^=]*$/, "", k); v = y[i]; sub(/^.*=/, "", v); seen[k] = 1
			if (!(k in before)) { nc = nc (nc == "" ? "" : ", ") k " (unknown -> " v ")"; continue }
			np = split(before[k], p, "/"); nq = split(v, q, "/"); t = ""
			if (np != 2 || nq != 2 || p[1] !~ /^[0-9]+$/ || q[1] !~ /^[0-9]+$/ || (over < 0 && (p[2] !~ /^[0-9]+$/ || q[2] !~ /^[0-9]+$/)))
				nc = nc (nc == "" ? "" : ", ") k " (" before[k] " -> " v ")"
			if (p[1] ~ /^[0-9]+$/ && q[1] ~ /^[0-9]+$/ && (p[1] != q[1] && (over < 0 || q[1] - p[1] > over || q[1] < p[1]))) { t = "Istio CR generation " p[1] " -> " q[1]; cr = 1 }
			if (over < 0 && p[2] ~ /^[0-9]+$/ && q[2] ~ /^[0-9]+$/ && p[2] != q[2]) t = t (t == "" ? "" : ", ") "IstioRevision generation " p[2] " -> " q[2]
			if (t != "") out = out (out == "" ? "" : ", ") k " (" t ")"
		}
		for (i = 1; i <= na; i++) if (!(ka[i] in seen)) nc = nc (nc == "" ? "" : ", ") ka[i] " (" before[ka[i]] " -> unknown)"
		if (un) { if (nc != "") print nc }
		else if (out != "") printf "%d\t%s\n", cr, out
	}'
}

# istio_version_refresh [--generations-only | --proxies-only] <from> <ctxs_csv>
# <kubectl_argv...>: For a sweep that edits the Istio CR itself (a tuning profile's apply
# and revert): read every member's generations (istio_generations_read) and proxy
# versions (istio_proxy_versions) again and export them as ISTIO_GENERATIONS and
# ISTIO_PROXY_VERSIONS with a new _ISTIO_VERSION_RESOLVED marker, so the steps that follow
# record what they run on, and istio_version_recheck compares the end with this read, not
# with the start (<from> names it in its messages, as "after the revert of pass 02-x":
# _ISTIO_GENERATIONS_FROM for the generations, _ISTIO_PROXY_VERSIONS_FROM for the
# proxies). --generations-only reads only the generations (a checkpoint right after an
# apply or a revert, while old istiod pods may still be terminating), --proxies-only only
# the proxies (once a pass has settled, before its probes). The version, the active
# revisions and the start-of-run readiness keys stay as istio_version_resolve read them.
# Nothing is read when the version was not read live (--dry-run). Never dies.
# shellcheck disable=SC2329
istio_version_refresh() {
	local gens=1 proxies=1
	case "${1:-}" in
	--generations-only) proxies=0; shift ;;
	--proxies-only) gens=0; shift ;;
	esac
	local from="$1" ctxs_csv="$2"
	shift 2
	[[ "${ISTIO_VERSION_SOURCE:-}" == live ]] || return 0
	if ((gens)); then
		ISTIO_GENERATIONS="$(istio_generations_read "$ctxs_csv" "$@")"
		export ISTIO_GENERATIONS
		_ISTIO_GENERATIONS_FROM="$from"
	fi
	if ((proxies)); then
		ISTIO_PROXY_VERSIONS="$(istio_proxy_versions "$ctxs_csv" "$@")"
		export ISTIO_PROXY_VERSIONS
		_ISTIO_PROXY_VERSIONS_FROM="$from"
	fi
	_ISTIO_VERSION_RESOLVED="$(_istio_version_marker)"
	export _ISTIO_VERSION_RESOLVED
}

# istio_version_recheck <out_arrayname> <kubectl_argv...>: Read every member's version
# again at the end of a sweep (after its last window, before its reports), read-only and
# never dying, and compare it with ISTIO_VERSION_BY_CONTEXT (and the activeRevisionName
# in _ISTIO_VERSION_REVS) from istio_version_resolve. Sets the named array to
# sweep_outcome arguments, which print them (once; --info on stdout, the rest on stderr):
#   --problem <msg>  a member now runs another version or another active revision (also
#                    when its Istio CR is not settled at the end but the active revision
#                    reads another version: a version bump whose upgrade failed partway),
#                    or is migrating between revisions (inUse > 1), or its revision's
#                    version is not exact: its rows are not all from one version, a failed
#                    sweep; or its Istio CR's or active IstioRevision's
#                    .metadata.generation went up although the version and the revision
#                    read the same (ISTIO_GENERATIONS at the start: a spec edit, also
#                    X->Y->X);
#   --note <msg>     members still not ready (or rolling out) at the start, from
#                    ISTIO_NOTREADY_AT_START (at a --resume, its start time and its
#                    own value as ISTIO_NOTREADY_AT_RESUME); the same version, but istiod
#                    or IstioCNI not ready (or istiod rolling out) at the end, grouped by
#                    state (readiness, not a version change); or a member that
#                    could not be read again (with why, when its Istio CR answered),
#                    whose Istio CR is not settled at the end, or that was unknown at the
#                    start (unconfirmed, not a failure; members are grouped by start
#                    version and why: an istiod Deployment that alone could not be read
#                    apart from the rest); proxies connected at the start on another
#                    version than their istiod (ISTIO_PROXY_VERSIONS);
#   --info <msg>     a --resume whose members were all ready when it started
#                    (ISTIO_NOTREADY_AT_RESUME=none, with its start time).
# Nothing more when nothing was read live (ISTIO_VERSION_SOURCE pin, as under --dry-run).
# The check runs apart (_istio_version_isolated); one that stops unexpectedly (bash 4.3
# to 5.1 abort on a bad array subscript) is a --problem, never silence.
# shellcheck disable=SC2329
istio_version_recheck() {
	local -n _ivrc_res="$1"
	shift
	local ivrc_text="" ivrc_rc=0
	local -a ivrc_lines=()
	_ivrc_res=()
	# Every temp file the check makes is under its own work dir (TMPDIR), removed when it
	# ends (_istio_version_isolated).
	_istio_version_isolated ivrc_rc ivrc_text _istio_version_recheck_emit "$@"
	[[ -z "$ivrc_text" ]] || mapfile -t ivrc_lines <<< "$ivrc_text"
	if ((ivrc_rc == 0 && ${#ivrc_lines[@]} > 0)) && [[ "${ivrc_lines[-1]}" == END ]]; then
		unset 'ivrc_lines[-1]'
		_ivrc_res=(${ivrc_lines[@]+"${ivrc_lines[@]}"})
	else
		_ivrc_res=(--problem "the end-of-sweep Istio version check failed: it stopped unexpectedly (exit ${ivrc_rc}; its error is in the sweep's stderr), so whether the Istio version or the active revision changed during the sweep is not known; check each member by hand: kubectl --context <ctx> get istios.sailoperator.io default -o jsonpath='{.status.activeRevisionName}', then kubectl --context <ctx> get istiorevisions.sailoperator.io <that revision> -o jsonpath='{.spec.version}'")
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
	local -A start_rev=() start_gen=()
	local pair tmp i v kind why rev rver state sv sr changed="" what="version" revonly=1 unconfirmed="" nr_end=""
	local ivrc_g1 ivrc_g2 ivrc_sg ivrc_c0 ivrc_gch gchanged="" ivrc_off ivrc_crmv=0 ivrc_from="${_ISTIO_GENERATIONS_FROM:-at the start}" ivrc_pfrom
	local ivrc_k ivrc_m ivrc_w
	local -a ivrc_dk=() ivrc_uk=()
	local -A ivrc_dm=() ivrc_dw=() ivrc_dd=() ivrc_um=()
	# A --resume compares with its own start (its resolve), a tuning sweep with its last
	# refresh after a revert (istio_version_refresh); the proxies, with their last read.
	[[ -n "${_ISTIO_GENERATIONS_FROM:-}" || -z "${_ISTIO_VERSION_RESUMED_AT:-}" ]] \
		|| ivrc_from="when this --resume started at ${_ISTIO_VERSION_RESUMED_AT}"
	ivrc_pfrom="${_ISTIO_PROXY_VERSIONS_FROM:-}"
	if [[ -z "$ivrc_pfrom" ]]; then
		ivrc_pfrom="at the start"
		[[ -z "${_ISTIO_VERSION_RESUMED_AT:-}" ]] || ivrc_pfrom="when this --resume started at ${_ISTIO_VERSION_RESUMED_AT}"
	fi
	IFS=, read -r -a pairs <<<"$ISTIO_VERSION_BY_CONTEXT"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		ctxs+=("${pair%=*}")
		start_v+=("${pair##*=}")
	done
	((${#ctxs[@]})) || return 0
	IFS=, read -r -a pairs <<<"${_ISTIO_VERSION_REVS:-}"
	for pair in ${pairs[@]+"${pairs[@]}"}; do start_rev["${pair%=*}"]="${pair##*=}"; done
	IFS=, read -r -a pairs <<<"${ISTIO_GENERATIONS:-}"
	for pair in ${pairs[@]+"${pairs[@]}"}; do [[ "$pair" != *=*/* ]] || start_gen["${pair%=*}"]="${pair##*=}"; done
	tmp="$(mktemp -d)"
	_istio_version_read_all "$tmp" ctxs "$@"
	for i in "${!ctxs[@]}"; do
		v="" kind="" why="" rev="" rver="" state="" ivrc_g1="" ivrc_g2=""
		{ IFS= read -r v; IFS= read -r kind; IFS= read -r why; IFS= read -r rev; IFS= read -r rver; IFS= read -r state
			IFS= read -r ivrc_g1; IFS= read -r ivrc_g2; } 2>/dev/null < "${tmp}/${i}" || true
		[[ -n "$v" ]] || v=unknown
		sv="${start_v[i]}" sr="${start_rev[${ctxs[i]}]:-}" ivrc_sg="${start_gen[${ctxs[i]}]:-}" ivrc_c0="$changed"
		if [[ "$sv" == unknown ]]; then
			# Grouped by the version they read at the end (one entry per version).
			if [[ "$v" != unknown ]]; then
				[[ -n "${ivrc_um[$v]+x}" ]] || ivrc_uk+=("$v")
				ivrc_um[$v]="${ivrc_um[$v]:+${ivrc_um[$v]}, }${ctxs[i]}"
			fi
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
			# a later read failed (the istiod Deployment), but the active revision was
			# read: another version is a change all the same (a mid-sweep upgrade).
			if [[ -n "$rver" && "$rver" != "$sv" ]]; then
				changed+="${changed:+; }${ctxs[i]}: ${sv} at the start, ${rver} at the end, its active revision's version (${why})"
				revonly=0
			elif [[ -n "$sr" && -n "$rev" && "$rev" != "$sr" ]]; then
				changed+="${changed:+; }${ctxs[i]}: activeRevisionName ${sr} at the start, ${rev} at the end (${why})"
			else
				# Grouped below by kind, start version and why (every Deployment
				# read failing, RBAC say; every Istio CR not settled). The Istio CR
				# answered (it names a revision), so say what failed.
				# Keyed by the why with URLs, hosts and IPs masked; the first member's
				# why is the one printed.
				ivrc_w="$why"
				[[ "$kind" == state || -n "$rver" || -n "$rev" ]] || ivrc_w=""
				if [[ "$kind" == state ]]; then
					ivrc_k="st|${sv}||"
				elif [[ -n "$rver" ]]; then
					ivrc_k="dep|${sv}|${rver}|"
				else
					ivrc_k="rd|${sv}||"
				fi
				ivrc_k+="$(_istio_version_hostkey "$ivrc_w")"
				if [[ -z "${ivrc_dm[$ivrc_k]+x}" ]]; then
					ivrc_dk+=("$ivrc_k")
					ivrc_dw[$ivrc_k]="$ivrc_w"
				elif [[ "${ivrc_dw[$ivrc_k]:-}" != "$ivrc_w" ]]; then
					ivrc_dd[$ivrc_k]=1
				fi
				ivrc_dm[$ivrc_k]="${ivrc_dm[$ivrc_k]:+${ivrc_dm[$ivrc_k]}, }${ctxs[i]}"
			fi
			;;
		*)
			ivrc_k="rd|${sv}||"
			[[ -n "${ivrc_dm[$ivrc_k]+x}" ]] || ivrc_dk+=("$ivrc_k")
			ivrc_dm[$ivrc_k]="${ivrc_dm[$ivrc_k]:+${ivrc_dm[$ivrc_k]}, }${ctxs[i]}"
			;;
		esac
		# The same version and active revision at both ends, but a spec edited between
		# them (X->Y->X, a values change): its generation went up. A member already counted
		# as changed, or a generation not read at either end, is not compared.
		if [[ "$changed" == "$ivrc_c0" && "$ivrc_sg" == */* ]]; then
			ivrc_gch=""
			if [[ "${ivrc_sg%%/*}" =~ ^[0-9]+$ && "$ivrc_g1" =~ ^[0-9]+$ && "${ivrc_sg%%/*}" != "$ivrc_g1" ]]; then
				ivrc_gch="its Istio CR default (generation ${ivrc_sg%%/*} ${ivrc_from}, ${ivrc_g1} at the end)"
				ivrc_crmv=1
			fi
			if [[ -n "$sr" && "$rev" == "$sr" && "${ivrc_sg#*/}" =~ ^[0-9]+$ && "$ivrc_g2" =~ ^[0-9]+$ && "${ivrc_sg#*/}" != "$ivrc_g2" ]]; then
				ivrc_gch+="${ivrc_gch:+ and }its IstioRevision ${rev} (generation ${ivrc_sg#*/} ${ivrc_from}, ${ivrc_g2} at the end)"
			fi
			[[ -z "$ivrc_gch" ]] || gchanged+="${gchanged:+; }${ctxs[i]}: ${ivrc_gch}"
		fi
	done
	rm -rf "$tmp"
	for v in ${ivrc_uk[@]+"${ivrc_uk[@]}"}; do
		if [[ "${ivrc_um[$v]}" == *", "* ]]; then
			unconfirmed+="${unconfirmed:+; }${ivrc_um[$v]} were unknown at the start and read ${v} at the end"
		else
			unconfirmed+="${unconfirmed:+; }${ivrc_um[$v]} was unknown at the start and reads ${v} at the end"
		fi
	done
	for ivrc_k in ${ivrc_dk[@]+"${ivrc_dk[@]}"}; do
		kind="${ivrc_k%%|*}" why="${ivrc_k#*|}"
		sv="${why%%|*}" why="${why#*|}"
		rver="${why%%|*}" why="${ivrc_dw[$ivrc_k]:-}" ivrc_m="${ivrc_dm[$ivrc_k]}"
		[[ -z "${ivrc_dd[$ivrc_k]:-}" ]] || why+=" (shown for ${ivrc_m%%, *}; the others name their own contexts)"
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
	if [[ -n "$gchanged" ]]; then
		_ivrc_out+=(--problem "the Istio CR or its IstioRevision was edited during the sweep, though the version and active revision read the same at the end (${gchanged}; ISTIO_GENERATIONS): $(istio_generation_causes "$ivrc_crmv"), so its rows may not all come from one control-plane configuration")
	fi
	# Proxies on another version than their istiod at the start (a NOTE, never a stop).
	ivrc_off="$(_istio_proxy_versions_off)"
	if [[ -n "$ivrc_off" ]]; then
		_ivrc_out+=(--note "proxies on another Istio version than their istiod were connected ${ivrc_pfrom} (${ivrc_off}; ISTIO_PROXY_VERSIONS): a sidecar keeps the version it was injected with until its pod restarts, so part of the traffic and xDS load came from it")
	fi
	_istio_notready_notes _ivrc_out end "$nr_end"
	if [[ -n "$unconfirmed" ]]; then
		_ivrc_out+=(--note "the Istio version at the end of the sweep is unconfirmed: ${unconfirmed}")
	fi
	return 0
}

# istio_proxy_versions <ctxs_csv> <kubectl_argv...>: The proxy (Envoy: sidecar and
# gateway) versions connected to each member's istiod, as one line
# ctx=<version>:<count>+<version>:<count>,... (most proxies first), the value of
# ISTIO_PROXY_VERSIONS. Source: istiod's pilot_xds gauge, labelled version (istio/istio
# 1.30.5 pilot/pkg/xds/monitoring.go: versionTag = monitoring.CreateLabel("version"),
# xdsClients = monitoring.NewGauge("pilot_xds", ...); ads.go records it per connection with
# the proxy's ISTIO_VERSION metadata, +1 on connect, -1 on close), summed over the member's
# Running istiod pods (`-l app=istiod` in istio-system: a proxy connects to one replica;
# every revision's istiod), each read through the API server's pod proxy (`kubectl get
# --raw /api/v1/namespaces/istio-system/pods/<pod>:15014/proxy/metrics`, no port-forward)
# bounded by --request-timeout (METRICS_SCRAPE_TIMEOUT, the pod list 5s). Series at 0 (their
# proxies left) are left out; a proxy that reported no version counts as unset. A pod being
# deleted (a deletionTimestamp: Terminating, though still phase Running, after a rollout
# when the settle was short) is left out, with a note on stderr: its proxies are moving to
# the other pods. A member reads none when no proxy is connected, unknown when its istiod
# pods could not be listed, it has none Running (and not being deleted), or one pod's
# metrics could not be read (a partial sum could hide a version). Members are read
# concurrently, ISTIO_PROXY_READ_PARALLEL at a time (config/options.env, default 20: every
# member of the 20-member campaign at once), and each member's pods one after another (one
# pod list, then one read per pod, each body folded into the member's sums and deleted as
# it arrives), so at most that many multi-MB /metrics bodies are read, or on disk, at once
# (a tuning sweep reads them before every pass). Because the pods are read in turn, the
# per-version counts are approximate: a proxy that moves to another istiod pod between two
# reads (PILOT_MAX_CONNECTION_AGE rebalancing, a restart) is counted twice or not at all;
# the versions present are what the check is for. Never dies. The reads run in a subshell
# whose traps remove its temp dir and stop its readers however it ends, so a Ctrl-C (or
# another signal) during the read at a sweep's start leaves nothing behind.
# shellcheck disable=SC2329
istio_proxy_versions() {
	( _istio_proxy_versions_run "$@" )
}

# _istio_proxy_versions_run <ctxs_csv> <kubectl_argv...>: istio_proxy_versions' body, in
# its subshell (it sets traps there).
# shellcheck disable=SC2329
_istio_proxy_versions_run() {
	local ctxs_csv="$1" ipv_to="${METRICS_SCRAPE_TIMEOUT:-30}" ipv_par="${ISTIO_PROXY_READ_PARALLEL:-20}" i p v out="" sig
	shift
	local -a ipv_ctxs=()
	_IPV_DIR="" _IPV_PIDS=()
	trap '_istio_proxy_versions_cleanup' EXIT
	for sig in HUP INT TERM; do
		# shellcheck disable=SC2064  # the signal's name, now
		trap "_istio_proxy_versions_cleanup; trap - ${sig}; kill -s ${sig} \"\$BASHPID\"" "$sig"
	done
	split_csv "$ctxs_csv" ipv_ctxs
	is_pos_int "$ipv_to" || ipv_to=30
	is_pos_int "$ipv_par" || ipv_par=20
	if ! _IPV_DIR="$(mktemp -d 2>/dev/null)"; then
		_IPV_DIR=""
		for i in "${!ipv_ctxs[@]}"; do out="${out:+${out},}${ipv_ctxs[i]}=unknown"; done
		printf '%s\n' "$out"
		return 0
	fi
	# In waves of ipv_par members.
	for i in "${!ipv_ctxs[@]}"; do
		_istio_proxy_versions_one "${ipv_ctxs[i]}" "$ipv_to" "${_IPV_DIR}/${i}.d" "$@" > "${_IPV_DIR}/${i}" 2>/dev/null &
		_IPV_PIDS+=($!)
		((${#_IPV_PIDS[@]} >= ipv_par)) || continue
		for p in "${_IPV_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
		_IPV_PIDS=()
	done
	for p in ${_IPV_PIDS[@]+"${_IPV_PIDS[@]}"}; do wait "$p" 2>/dev/null || true; done
	_IPV_PIDS=()
	for i in "${!ipv_ctxs[@]}"; do
		v="$(head -n 1 "${_IPV_DIR}/${i}" 2>/dev/null || true)"
		[[ "$v" =~ ^(none|unknown|[A-Za-z0-9._-]+:[0-9]+(\+[A-Za-z0-9._-]+:[0-9]+)*)$ ]] || v=unknown
		out="${out:+${out},}${ipv_ctxs[i]}=${v}"
		p="$(sed -n 's/^terminating=\([0-9][0-9]*\)$/\1/p' "${_IPV_DIR}/${i}" 2>/dev/null || true)"
		[[ -z "$p" ]] || echo "note: ${ipv_ctxs[i]}: ${p} istiod pod(s) being deleted (Terminating) left out of its proxy-version read (ISTIO_PROXY_VERSIONS): their proxies are moving to the other pods" >&2
	done
	printf '%s\n' "$out"
}

# _istio_proxy_versions_cleanup: stop the member reads still running and remove the temp
# dir (the EXIT and signal traps of _istio_proxy_versions_run).
# shellcheck disable=SC2329
_istio_proxy_versions_cleanup() {
	local p
	for p in ${_IPV_PIDS[@]+"${_IPV_PIDS[@]}"}; do kill -s TERM "$p" 2>/dev/null || true; done
	_IPV_PIDS=()
	[[ -z "${_IPV_DIR:-}" ]] || rm -rf "$_IPV_DIR"
	_IPV_DIR=""
}

# _istio_proxy_versions_one <ctx> <timeout_sec> <workdir> <kubectl_argv...>: one member's
# value for istio_proxy_versions, then, when it left pods being deleted out, a second line
# "terminating=<n>" (_istio_proxy_versions_run notes it).
# shellcheck disable=SC2329
_istio_proxy_versions_one() {
	local ctx="$1" to="$2" d="$3" pods p del n=0 bad=0 term=0
	shift 3
	local -a pids=()
	# Stopped by istio_proxy_versions, or by Ctrl-C (it gets SIGINT, its read does not): stop
	# its own read too. Each read runs in the background and is waited for at once, so the
	# trap runs without waiting for it.
	trap 'kill -s TERM ${pids[@]+"${pids[@]}"} 2>/dev/null; exit 143' HUP INT TERM
	pods="$("$@" --context="$ctx" --request-timeout=5s -n istio-system get pods -l app=istiod \
		--field-selector=status.phase=Running --no-headers \
		-o custom-columns=NAME:.metadata.name,DELETING:.metadata.deletionTimestamp 2>/dev/null)" \
		|| { echo unknown; return 0; }
	mkdir -p "$d" 2>/dev/null || { echo unknown; return 0; }
	while read -r p del _; do
		p="${p#pod/}"
		[[ -n "$p" ]] || continue
		[[ "$p" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || { bad=1; continue; }
		if [[ -n "$del" && "$del" != "<none>" ]]; then
			term=$((term + 1))
			continue
		fi
		n=$((n + 1))
		"$@" --context="$ctx" --request-timeout="${to}s" get --raw "/api/v1/namespaces/istio-system/pods/${p}:15014/proxy/metrics" > "${d}/body" 2>/dev/null &
		pids=($!)
		# One failed read makes the member unknown: the rest are not read.
		wait "${pids[0]}" 2>/dev/null || { bad=1; pids=(); break; }
		pids=()
		# Every body must be Prometheus text (an istiod with no proxy may export no
		# pilot_xds). Its pilot_xds series go into the member's sums, and the body is deleted,
		# before the next pod is read.
		grep -q '^# TYPE ' "${d}/body" 2>/dev/null || { bad=1; break; }
		awk '
			/^pilot_xds[{ ]/ {
				v = "unset"
				if (match($0, /version="[^"]*"/)) v = substr($0, RSTART + 9, RLENGTH - 10)
				if (v == "" || v !~ /^[A-Za-z0-9._-]+$/) v = (v == "" ? "unset" : "invalid")
				line = $0
				sub(/^[^ ]*\} */, "", line)
				sub(/^pilot_xds +/, "", line)
				split(line, f, " ")
				print v, f[1] + 0
			}' "${d}/body" >> "${d}/sums" 2>/dev/null || { bad=1; break; }
		rm -f "${d}/body"
	done <<<"$pods"
	if ((n == 0 || bad)); then
		echo unknown
		((term == 0)) || echo "terminating=${term}"
		return 0
	fi
	awk '
		{
			v = $1
			if (!(v in sum)) order[++nv] = v
			sum[v] += $2 + 0
		}
		END {
			for (i = 1; i <= nv; i++) if (sum[order[i]] >= 0.5) { k[++m] = order[i] }
			for (i = 2; i <= m; i++) { x = k[i]; for (j = i - 1; j >= 1 && (sum[k[j]] < sum[x] || (sum[k[j]] == sum[x] && k[j] > x)); j--) k[j + 1] = k[j]; k[j + 1] = x }
			if (m == 0) { print "none"; exit }
			for (i = 1; i <= m; i++) printf "%s%s:%d", (i > 1 ? "+" : ""), k[i], sum[k[i]] + 0.5
			printf "\n"
		}' "${d}/sums" 2>/dev/null || echo unknown
	((term == 0)) || echo "terminating=${term}"
}

# _istio_proxy_versions_off: The members whose connected proxies are not all on the
# version their istiod runs (ISTIO_PROXY_VERSIONS against ISTIO_VERSION_BY_CONTEXT, a
# leading v ignored), as "ctx (istiod v): <count> on <version>, ...; ...", or nothing.
# Members whose version or proxies are unknown are left out.
# shellcheck disable=SC2329
_istio_proxy_versions_off() {
	awk -v pv="${ISTIO_PROXY_VERSIONS:-}" -v by="${ISTIO_VERSION_BY_CONTEXT:-}" 'BEGIN {
		n = split(by, p, ",")
		for (i = 1; i <= n; i++) if (match(p[i], /=[^=]*$/)) { v = substr(p[i], RSTART + 1); sub(/^v/, "", v); mv[substr(p[i], 1, RSTART - 1)] = v }
		n = split(pv, p, ",")
		for (i = 1; i <= n; i++) {
			if (!match(p[i], /=[^=]*$/)) continue
			c = substr(p[i], 1, RSTART - 1); l = substr(p[i], RSTART + 1)
			if (!(c in mv) || mv[c] == "unknown" || mv[c] ~ /^mixed:/ || l == "none" || l == "unknown") continue
			m = split(l, e, "+"); o = ""
			for (j = 1; j <= m; j++) {
				q = e[j]; k = q; sub(/:[0-9]+$/, "", k); cnt = substr(q, length(k) + 2)
				kk = k; sub(/^v/, "", kk)
				if (kk != mv[c]) o = o (o == "" ? "" : ", ") cnt " on " k
			}
			if (o != "") out = out (out == "" ? "" : "; ") c " (istiod " mv[c] "): " o
		}
		print out
	}'
}

# _istio_proxy_versions_warn: At the start, a warning (never a stop) for members whose
# proxies are not all on their istiod's version.
# shellcheck disable=SC2329
_istio_proxy_versions_warn() {
	local off
	off="$(_istio_proxy_versions_off)"
	[[ -z "$off" ]] || echo "warning: proxies on another Istio version than their istiod are connected (${off}; ISTIO_PROXY_VERSIONS): a sidecar keeps the version it was injected with until its pod restarts. The run goes on; the sweep outcome notes it, and the preambles record ISTIO_PROXY_VERSIONS." >&2
}

# istio_version_kv: the Istio version keys every preamble writer records (PL36), as
# KEY=value lines: ISTIO_VERSION, ISTIO_VERSION_PIN, ISTIO_VERSION_SOURCE (pin when
# nothing resolved them: the value is then the pin, unchecked), ISTIO_VERSION_BY_CONTEXT
# (ctx=version,...; unchecked when nothing was read), ISTIO_NOTREADY_AT_START
# (ctx=<state>,... still not ready after the start's wait, rolling for an istiod rollout;
# none; unchecked), ISTIO_READY_WAITED_SEC (how long the start waited; unchecked) and
# ISTIO_ACTIVE_REVISIONS (ctx=<activeRevisionName>,... as read at the start, empty
# for a member whose Istio CR did not name one; unknown when nothing was read on a live
# check that stopped unexpectedly; unchecked when not read live), ISTIO_GENERATIONS
# (ctx=<Istio CR generation>/<active IstioRevision generation>,...) and ISTIO_PROXY_VERSIONS
# (ctx=<version>:<count>+...,..., none or unknown per member; istio_proxy_versions),
# both unchecked when not read live.
# shellcheck disable=SC2329
istio_version_kv() {
	local ivk_revs=unchecked ivk_gens=unchecked ivk_pv=unchecked
	if [[ "${ISTIO_VERSION_SOURCE:-pin}" == live ]]; then
		ivk_revs="${_ISTIO_VERSION_REVS:-unknown}" ivk_gens="${ISTIO_GENERATIONS:-unknown}" ivk_pv="${ISTIO_PROXY_VERSIONS:-unknown}"
	fi
	echo "ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
	echo "ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN:-${ISTIO_VERSION:-unknown}}"
	echo "ISTIO_VERSION_SOURCE=${ISTIO_VERSION_SOURCE:-pin}"
	echo "ISTIO_VERSION_BY_CONTEXT=${ISTIO_VERSION_BY_CONTEXT:-unchecked}"
	echo "ISTIO_NOTREADY_AT_START=${ISTIO_NOTREADY_AT_START:-unchecked}"
	echo "ISTIO_READY_WAITED_SEC=${ISTIO_READY_WAITED_SEC:-unchecked}"
	echo "ISTIO_ACTIVE_REVISIONS=${ivk_revs}"
	echo "ISTIO_GENERATIONS=${ivk_gens}"
	echo "ISTIO_PROXY_VERSIONS=${ivk_pv}"
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
	local file="$1" run_id="${2:-unknown}" dir hs hk
	[[ -n "$file" ]] || return 0
	[[ -f "$file" ]] && return 0
	dir="$(dirname "$file")"
	mkdir -p "$dir"
	# The harness without the results dir this file lives in (they would read dirty).
	harness_read hs hk --exclude "$dir"
	{
		echo "# Namespace lifecycle (controlplane growth mode) — $(date -u -Iseconds)"
		echo "# NS_LIFECYCLE_SCHEMA=2"
		echo "# RUN_ID=${run_id}"
		echo "# HARNESS_SHA=${hs}"
		echo "# HARNESS_CONTENT_KEY=${hk}"
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
