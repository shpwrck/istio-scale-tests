#!/usr/bin/env bash
# Deploy dummy workloads for measuring istiod control-plane resource consumption.
#
# Applies one workload configuration (single point in the sweep cube) to each
# target cluster: SERVICE_COUNT services × REPLICAS pods, distributed across
# NAMESPACE_COUNT namespaces (service `i` lands in namespace `i mod N`).
#
# Backwards compat: when --namespace-count is 1 (default), the single namespace
# keeps its historical name `${NS}` (e.g. `controlplane-test`). When > 1,
# namespaces are named `${NS}-0`, `${NS}-1`, ..., `${NS}-(N-1)`.
#
# Manifests are applied with server-side apply (`--server-side
# --force-conflicts`); we use a label-selector wait per namespace instead of
# looping per Deployment.
#
# Usage:
#   ./tests/controlplane/001-setup-controlplane-test.sh [--contexts CSV] [options]
#
# Examples:
#   # Setup on all default clusters (single namespace, 10 services × 3 replicas):
#   ./tests/controlplane/001-setup-controlplane-test.sh
#
#   # Setup with custom workload size:
#   ./tests/controlplane/001-setup-controlplane-test.sh --service-count 50 --replicas 5
#
#   # Spread 100 services across 10 namespaces:
#   ./tests/controlplane/001-setup-controlplane-test.sh --service-count 100 --namespace-count 10
#
#   # Setup with namespace-scoped Sidecar CRs:
#   ./tests/controlplane/001-setup-controlplane-test.sh --sidecar-scoping namespace
# ci-dry-run-skip: needs valid kubeconfig context for kubectl apply --dry-run=client
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # O9: SCALE_SIZING_MODE / SCALE_* knobs (default-off)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # O9: read-only capacity probes (auto sizing, gated)

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT=300
NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNT="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
SIDECAR_SCOPING="${CONTROLPLANE_SIDECAR_SCOPING:-none}"
# PL37 cleanup->setup cascade fix: if a namespace from the PREVIOUS combo is still
# Terminating when this setup starts, applying the chart (which includes a
# kind: Namespace) fails — you cannot create a Terminating Namespace nor namespaced
# resources inside it — turning a slow 005 teardown into a SETUP_FAILED cascade
# (~40% data loss, deterministic odd/even). So before applying, poll-until-gone
# (PL4) for any pre-existing instance of EVERY target namespace on EVERY context.
# The wait lives in 001 so the precondition travels WITH setup (a manual 001 after
# a manual 005 benefits too). Defaults to reuse the same bound 005 uses for its own
# namespace-termination wait (same contract).
SETUP_NS_WAIT_SEC="${CONTROLPLANE_SETUP_NS_WAIT_SEC:-${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}}"
# P1-1: bounded retry on the server-side-apply path so a transient apiserver 429
# (or any non-zero apply exit) under sweep load doesn't hard-fail the combo to
# SETUP_FAILED on the first hiccup. P1-3: chunk the rendered object stream so a
# large `explicit`-scoping render (~3 objects/service) is applied in batches per
# context instead of one giant single SSA stream that throttles/partial-fails.
APPLY_ATTEMPTS="${CONTROLPLANE_APPLY_ATTEMPTS:-3}"
APPLY_BACKOFF_S="${CONTROLPLANE_APPLY_BACKOFF_S:-5}"
# Objects per server-side-apply batch (P1-3). The namespace doc(s) are always
# applied FIRST as their own batch so namespaced objects land into an existing
# namespace; the remaining Services/Deployments/Sidecars are applied in batches
# of this size. <= 0 disables chunking (single stream, legacy behaviour).
APPLY_CHUNK_OBJECTS="${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-200}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV         Kube contexts to target (default: \$SETUP_CONTEXTS).
  --service-count N      Number of dummy services per cluster (default: $SERVICE_COUNT).
  --replicas N           Replicas per service (default: $REPLICAS).
  --namespace-count N    Spread services across N namespaces (default: $NAMESPACE_COUNT).
                         N=1 -> single namespace named '$NS'.
                         N>1 -> namespaces '${NS}-0' .. '${NS}-(N-1)';
                         service i lands in namespace (i mod N).
  --sidecar-scoping MODE Sidecar CR scoping: none|namespace|explicit (default: $SIDECAR_SCOPING).
                         none      - no Sidecar CRs (baseline; worst-case config size).
                         namespace - one namespace-scoped Sidecar in the primary namespace.
                         explicit  - one Sidecar per Deployment with workloadSelector.
  --dry-run              Pass --dry-run=client to oc apply
                         (skips the --server-side path).
  --wait-timeout N       Seconds to wait for pods (default: 300).
  --ns-wait-timeout N    Seconds to wait for a pre-existing (Terminating) namespace
                         to fully disappear before applying (default: $SETUP_NS_WAIT_SEC).
                         PL37 cleanup->setup cascade guard; skipped in --dry-run.
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_SERVICE_COUNT,
  CONTROLPLANE_REPLICAS_PER_SERVICE, CONTROLPLANE_NAMESPACE_COUNT,
  CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_SETUP_NS_WAIT_SEC (pre-apply wait for a Terminating namespace to
  clear; defaults to CONTROLPLANE_NS_DELETE_TIMEOUT_SEC, then 300).
  KUBE_CLIENT_QPS / KUBE_CLIENT_BURST (client rate-limit flags appended to every
  oc/kubectl call; defaults 30/60). CONTROLPLANE_APPLY_ATTEMPTS (default 3) /
  CONTROLPLANE_APPLY_BACKOFF_S (default 5): bounded retry on the server-side-apply
  path so a transient 429 doesn't hard-fail the combo. CONTROLPLANE_APPLY_CHUNK_OBJECTS
  (default 200; <=0 disables): objects per server-side-apply batch for large
  (explicit-scoping) renders.

  O9 scale-coverage (DEFAULT-OFF — fixed/0 means behaviour is unchanged):
  SCALE_SIZING_MODE (fixed|auto; auto derives SERVICE_COUNT from cluster capacity),
  SCALE_TARGET_FRACTION, SCALE_SYSTEM_RESERVE_FRACTION, SCALE_PER_POD_CPU_M,
  SCALE_PER_POD_MEM_MI (auto-sizing inputs), SCALE_COVERAGE_MIN_FRACTION,
  SCALE_COVERAGE_ENFORCE (under-provision floor: warn by default, hard-fail when 1).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--service-count)
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		SERVICE_COUNT="$2"
		shift 2
		;;
	--replicas)
		[[ -n "${2:-}" ]] || die "--replicas requires a value"
		REPLICAS="$2"
		shift 2
		;;
	--namespace-count)
		[[ -n "${2:-}" ]] || die "--namespace-count requires a value"
		NAMESPACE_COUNT="$2"
		shift 2
		;;
	--sidecar-scoping)
		[[ -n "${2:-}" ]] || die "--sidecar-scoping requires a value"
		SIDECAR_SCOPING="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--wait-timeout)
		[[ -n "${2:-}" ]] || die "--wait-timeout requires a value"
		WAIT_TIMEOUT="$2"
		shift 2
		;;
	--ns-wait-timeout)
		[[ -n "${2:-}" ]] || die "--ns-wait-timeout requires a value"
		SETUP_NS_WAIT_SEC="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try --help)"
		;;
	esac
done

is_pos_int "$SERVICE_COUNT" || die "--service-count must be a positive integer (got: $SERVICE_COUNT)"
is_pos_int "$REPLICAS" || die "--replicas must be a positive integer (got: $REPLICAS)"
is_pos_int "$NAMESPACE_COUNT" || die "--namespace-count must be a positive integer (got: $NAMESPACE_COUNT)"
is_nonneg_int "$WAIT_TIMEOUT" || die "--wait-timeout must be a non-negative integer (got: $WAIT_TIMEOUT)"
is_nonneg_int "$SETUP_NS_WAIT_SEC" || die "--ns-wait-timeout must be a non-negative integer (got: $SETUP_NS_WAIT_SEC)"
is_pos_int "$APPLY_ATTEMPTS" || die "CONTROLPLANE_APPLY_ATTEMPTS must be a positive integer (got: $APPLY_ATTEMPTS)"
is_nonneg_int "$APPLY_BACKOFF_S" || die "CONTROLPLANE_APPLY_BACKOFF_S must be a non-negative integer (got: $APPLY_BACKOFF_S)"
[[ "$APPLY_CHUNK_OBJECTS" =~ ^-?[0-9]+$ ]] || die "CONTROLPLANE_APPLY_CHUNK_OBJECTS must be an integer (got: $APPLY_CHUNK_OBJECTS)"
validate_scoping "$SIDECAR_SCOPING"

if ((NAMESPACE_COUNT > SERVICE_COUNT)); then
	die "--namespace-count ($NAMESPACE_COUNT) > --service-count ($SERVICE_COUNT); some namespaces would be empty. Reduce --namespace-count to at most --service-count."
fi

# P1-1: resolve_kubectl appends the shared --qps/--burst client rate-limit flags
# (KUBE_CLIENT_QPS/BURST) so the 20-context apply path doesn't throttle at the
# client-go 5/10 default.
KUBECTL=()
resolve_kubectl KUBECTL

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

# Compute the list of namespaces to wait against. Mirror the chart's
# backwards-compat rule (N=1 -> single namespace = $NS; N>1 -> $NS-i).
NAMESPACES=()
if ((NAMESPACE_COUNT <= 1)); then
	NAMESPACES=("$NS")
else
	for ((n = 0; n < NAMESPACE_COUNT; n++)); do
		NAMESPACES+=("${NS}-${n}")
	done
fi

echo "=== Control-plane test setup ==="
echo "Contexts:        ${CONTEXTS[*]}"
echo "Services:        $SERVICE_COUNT"
echo "Replicas/svc:    $REPLICAS"
echo "Namespace count: $NAMESPACE_COUNT"
echo "Namespaces:      ${NAMESPACES[*]}"
echo "Sidecar scoping: $SIDECAR_SCOPING"
((DRY_RUN)) && echo "Mode:            dry-run"
SCALE_SIZING_MODE="${SCALE_SIZING_MODE:-fixed}"
[[ "$SCALE_SIZING_MODE" == auto ]] && echo "Sizing mode:     auto (O9 capacity-derived SERVICE_COUNT)"
echo ""

# O9 Phase 2 (DEFAULT-OFF): capacity-derived sizing. ONLY runs when the operator
# opts in with SCALE_SIZING_MODE=auto. With the default `fixed` this whole block is
# skipped and SERVICE_COUNT keeps its CLI/env value — behaviour is byte-identical to
# pre-O9. Never runs in --dry-run (would touch the cluster).
#
# per_pod_cpu_m / per_pod_mem_mi: the dummy chart's container declares NO resources
# block (tests/controlplane/chart/templates/dummy-deployment.yaml), so the app
# container's request is effectively 0; the dominant cost is the injected istio-proxy
# sidecar. We use a documented conservative constant (sidecar default ~100m / ~128Mi
# plus headroom) until calibrated against a real cluster on the clean re-run. These
# are intentionally generous so auto-sizing under-provisions rather than over-provisions.
# Centralized in config/options.env (SCALE_PER_POD_*) for calibration consistency.
PER_POD_CPU_M="${SCALE_PER_POD_CPU_M:-200}"
PER_POD_MEM_MI="${SCALE_PER_POD_MEM_MI:-256}"
if [[ "$SCALE_SIZING_MODE" == auto ]] && ! ((DRY_RUN)); then
	src_ctx="${CONTEXTS[0]}"
	echo "Auto-sizing from capacity on source context $src_ctx (target_fraction=${SCALE_TARGET_FRACTION}, reserve=${SCALE_SYSTEM_RESERVE_FRACTION})..."
	a_cpu="unknown"; a_mem="unknown"; a_pods="unknown"
	# shellcheck disable=SC2207
	nt=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${nt[@]}"; do
		case "$kv" in
			cpu_m=*) a_cpu="${kv#cpu_m=}" ;;
			mem_mi=*) a_mem="${kv#mem_mi=}" ;;
			pods=*) a_pods="${kv#pods=}" ;;
		esac
	done
	i_cpu="unknown"; i_mem="unknown"; i_rep="unknown"
	# shellcheck disable=SC2207
	il=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${il[@]}"; do
		case "$kv" in
			cpu_m=*) i_cpu="${kv#cpu_m=}" ;;
			mem_mi=*) i_mem="${kv#mem_mi=}" ;;
			replicas=*) i_rep="${kv#replicas=}" ;;
		esac
	done
	max_pods=$(cap_max_pods "$a_cpu" "$a_mem" "$a_pods" "$i_cpu" "$i_mem" "$i_rep" \
		"$PER_POD_CPU_M" "$PER_POD_MEM_MI" "$SCALE_TARGET_FRACTION" "$SCALE_SYSTEM_RESERVE_FRACTION")
	if [[ "$max_pods" == unknown ]]; then
		echo "  WARN: capacity unreadable on $src_ctx; auto-sizing falls back to fixed SERVICE_COUNT=$SERVICE_COUNT" >&2
	else
		derived=$(( max_pods / REPLICAS ))
		(( derived < 1 )) && derived=1
		echo "  capacity-derived max_pods=$max_pods / replicas=$REPLICAS -> SERVICE_COUNT=$derived (was $SERVICE_COUNT)"
		SERVICE_COUNT="$derived"
		if ((NAMESPACE_COUNT > SERVICE_COUNT)); then
			echo "  note: clamping --namespace-count $NAMESPACE_COUNT down to derived SERVICE_COUNT $SERVICE_COUNT" >&2
			NAMESPACE_COUNT="$SERVICE_COUNT"
			NAMESPACES=()
			if ((NAMESPACE_COUNT <= 1)); then NAMESPACES=("$NS")
			else for ((n = 0; n < NAMESPACE_COUNT; n++)); do NAMESPACES+=("${NS}-${n}"); done
			fi
		fi
	fi
	echo ""
fi

# Sidecar egress-coverage precondition (P0-d). When NAMESPACE_COUNT > 1 the suite
# mints controlplane-test-0, controlplane-test-1, … but the campaign's root Sidecar
# (spoke-ossm tuningBaseline) carries an egress allow-list whose namespace parts are
# EXACT matches — "controlplane-test/*" does NOT cover "controlplane-test-0/*". An
# uncovered namespace silently strips those proxies' egress to the workloads (no
# endpoints), which reads downstream as a dead measurement, not a config error. So
# fail FAST here, pointing the operator at the egressHosts list to fix, instead of
# proceeding into a silently-broken mesh. Read-only, live-queried per source context
# (the deployed graph, not chart defaults — cf PL39); skipped in --dry-run.
# Auto-generating the egress entries is out of scope; this is the GO-safe guard.
if ! ((DRY_RUN)) && ((NAMESPACE_COUNT > 1)); then
	echo "Sidecar egress-coverage precondition (namespaceCount=$NAMESPACE_COUNT > 1)..."
	for ctx in "${CONTEXTS[@]}"; do
		# Live root-Sidecar egress hosts (space-joined "<ns>/<dns>" entries), same
		# query preamble.sh uses for SIDECAR_EGRESS_HOSTS.
		hosts="$("${KUBECTL[@]}" --context="$ctx" --request-timeout=5s -n istio-system \
			get sidecar.networking.istio.io default \
			-o jsonpath='{.spec.egress[*].hosts[*]}' 2>/dev/null)" || hosts="__unreadable__"
		if [[ "$hosts" == "__unreadable__" ]]; then
			# No narrowing Sidecar (or it can't be read) -> egress is not restricted by
			# this guard's target; cannot assert a problem we couldn't measure.
			echo "  WARN: $ctx: could not read the root Sidecar egress hosts; cannot verify egress coverage for the $NAMESPACE_COUNT generated namespaces. If a narrowed egress allow-list IS deployed, confirm it lists each ${NS}-<i>/* before relying on this run." >&2
			continue
		fi
		# A "*/*" entry (or an exact "<ns>/*"/"<ns>/<dns>") covers a namespace. Collect
		# the namespace parts (before the first "/") of every egress host.
		declare -A _covered_ns=()
		global_egress=0
		for h in $hosts; do
			ns_part="${h%%/*}"
			[[ "$ns_part" == "*" ]] && global_egress=1
			_covered_ns["$ns_part"]=1
		done
		if ((global_egress)); then
			unset _covered_ns
			continue  # "*/*" egress covers everything
		fi
		missing=()
		for ns in "${NAMESPACES[@]}"; do
			[[ -n "${_covered_ns[$ns]:-}" ]] || missing+=("$ns")
		done
		unset _covered_ns
		if ((${#missing[@]})); then
			die "context $ctx: the deployed root Sidecar egress allow-list does NOT cover these controlplane-test namespaces: ${missing[*]}. egressHosts namespace parts are EXACT matches (\"controlplane-test/*\" does NOT cover \"controlplane-test-0/*\"). Add an explicit \"<ns>/*\" entry for each to charts/spoke-ossm/values.yaml tuningBaseline.discoverySelectors.egressHosts (and re-sync the mesh), or run with --namespace-count 1. Current egress hosts: ${hosts}"
		fi
		echo "  $ctx: all $NAMESPACE_COUNT generated namespaces covered by the Sidecar egress allow-list — OK"
	done
	echo ""
fi

# Capacity preflight: verify each cluster can schedule the planned pods before
# deploying anything. Queries node allocatable.pods and current pod count; fails
# early with an actionable message instead of hanging at the wait timeout. This is
# the single ceiling-and-floor gate: it DIES on over-provision (O5) and, under
# SCALE_SIZING_MODE=auto, additionally WARNs on under-provision (O9 coverage floor)
# — hard-failing only when SCALE_COVERAGE_ENFORCE=1.
if ! ((DRY_RUN)); then
	NEEDED_PODS=$((SERVICE_COUNT * REPLICAS))
	echo "Capacity preflight ($NEEDED_PODS pods needed per cluster)..."
	for ctx in "${CONTEXTS[@]}"; do
		alloc=$("${KUBECTL[@]}" --context="$ctx" get nodes -o json 2>/dev/null \
			| jq '[.items[].status.allocatable.pods // "0" | tonumber] | add // 0' 2>/dev/null) || alloc=""
		# Cheap cluster-wide pod count: `-o name` (names only, no specs) + server-side
		# paging so a 10k-pod × 20-context preflight doesn't stream a huge table per
		# cluster on the hot path. One line per pod -> `wc -l` is identical to the old
		# --no-headers count (all phases, matching the allocatable.pods slot model).
		current=$("${KUBECTL[@]}" --context="$ctx" get pods --all-namespaces -o name \
			--chunk-size="${CAP_POD_CHUNK_SIZE:-500}" 2>/dev/null | wc -l) || current=""
		if [[ -n "$alloc" && -n "$current" ]] && is_nonneg_int "$alloc" && is_nonneg_int "$current"; then
			remaining=$((alloc - current))
			if ((NEEDED_PODS > remaining)); then
				die "context $ctx: need $NEEDED_PODS pods (${SERVICE_COUNT} svc × ${REPLICAS} replicas) but only $remaining slots available ($alloc allocatable − $current running). Reduce --service-count or --replicas, or add nodes."
			fi
			echo "  $ctx: $remaining pod slots available ($NEEDED_PODS needed) — OK"
			# O9 under-provision coverage floor (auto mode only; informational unless
			# SCALE_COVERAGE_ENFORCE=1). Achieved fraction = needed / allocatable.
			if [[ "$SCALE_SIZING_MODE" == auto ]] && (( alloc > 0 )); then
				min_frac="${SCALE_COVERAGE_MIN_FRACTION:-0.25}"
				under=$(awk -v n="$NEEDED_PODS" -v a="$alloc" -v m="$min_frac" \
					'BEGIN{ print ((n/a) < (m+0)) ? 1 : 0 }')
				if (( under )); then
					frac=$(awk -v n="$NEEDED_PODS" -v a="$alloc" 'BEGIN{ printf "%.3f", n/a }')
					# This fires INSIDE auto mode (auto-sizing already ran and still landed
					# under the floor), so the remediation must NOT say "set auto" — the real
					# levers are more nodes / a higher target fraction / a lower reserve.
					fix_hint="add cluster nodes, raise SCALE_TARGET_FRACTION (currently ${SCALE_TARGET_FRACTION}), or lower SCALE_SYSTEM_RESERVE_FRACTION (currently ${SCALE_SYSTEM_RESERVE_FRACTION})"
					if [[ "${SCALE_COVERAGE_ENFORCE:-0}" == "1" ]]; then
						die "context $ctx: SCALE_COVERAGE: UNDER ($NEEDED_PODS/$alloc pods = $frac < min $min_frac) and SCALE_COVERAGE_ENFORCE=1 — to fix: ${fix_hint}, or lower SCALE_COVERAGE_MIN_FRACTION / unset SCALE_COVERAGE_ENFORCE"
					fi
					echo "  WARN: $ctx: SCALE_COVERAGE: UNDER ($NEEDED_PODS/$alloc pods = $frac < min $min_frac) — under-scaled; to raise coverage: ${fix_hint}" >&2
				fi
			fi
		else
			echo "  $ctx: could not query capacity (alloc=$alloc, current=$current) — skipping preflight" >&2
		fi
	done
	echo ""
fi

# PL37 cleanup->setup cascade fix: poll-until-gone (PL4) for any pre-existing
# instance of EVERY target namespace before applying. A slow 005 teardown of the
# previous combo must DELAY this setup, never DESTROY its data. Returns 0 once all
# this context's target namespaces are absent (or never existed); returns 1 if any
# is still present after SETUP_NS_WAIT_SEC — at which point applying the chart's
# kind: Namespace would fail anyway, so the caller (die below -> 003's PL32
# SETUP_FAILED wrap) records a legitimate, now-rare, failure rather than hanging.
wait_ns_gone() {
	local ctx="$1" ns deadline now
	for ns in "${NAMESPACES[@]}"; do
		"${KUBECTL[@]}" --context="$ctx" get namespace "$ns" >/dev/null 2>&1 || continue
		echo "  [$ctx] namespace $ns still present (Terminating?); waiting up to ${SETUP_NS_WAIT_SEC}s for it to clear before apply..." >&2
		deadline=$(( $(date +%s) + SETUP_NS_WAIT_SEC ))
		while "${KUBECTL[@]}" --context="$ctx" get namespace "$ns" >/dev/null 2>&1; do
			now=$(date +%s)
			if (( now > deadline )); then
				echo "  [$ctx] namespace $ns did not clear within ${SETUP_NS_WAIT_SEC}s; cannot apply into a Terminating namespace; check stuck finalizers: ${KUBECTL[*]} --context=$ctx get ns $ns -o jsonpath='{.spec.finalizers}'" >&2
				return 1
			fi
			sleep 2
		done
		echo "  [$ctx] namespace $ns cleared; proceeding with apply." >&2
	done
	return 0
}

if ((DRY_RUN)); then
	# Mirror the live wait's plan style; the actual wait below is DRY_RUN-gated so
	# no cluster call happens in --dry-run.
	echo "  [dry-run] would wait up to ${SETUP_NS_WAIT_SEC}s for any pre-existing Terminating namespace (${NAMESPACES[*]}) on each context before apply" >&2
fi

if ! ((DRY_RUN)); then
	NS_WAIT_PIDS=()
	for ctx in "${CONTEXTS[@]}"; do
		wait_ns_gone "$ctx" &
		NS_WAIT_PIDS+=($!)
	done
	for pid in "${NS_WAIT_PIDS[@]}"; do
		wait "$pid" || die "a pre-existing namespace did not clear within ${SETUP_NS_WAIT_SEC}s on one or more contexts; refusing to apply into a Terminating namespace"
	done
fi

# Use server-side apply so partial updates and field-manager ownership are
# tracked by the API server (no client-side last-applied annotation). With
# --force-conflicts we win any field-ownership conflict from a previous
# kubectl-client-side-apply run, which is what we want for a benchmarking
# harness that owns these namespaces exclusively.
apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/controlplane/chart"

# P1-1: apply a manifest file with a bounded retry so a transient apiserver 429
# (or any non-zero apply exit) under sweep load retries with a short backoff
# before failing the combo. <manifest_file> <ctx> <label>.
apply_with_retry() {
	local manifest="$1" ctx="$2" label="$3" attempt=1
	while :; do
		if "${apply[@]}" --context="$ctx" -f "$manifest"; then
			return 0
		fi
		if (( attempt >= APPLY_ATTEMPTS )); then
			echo "error: apply failed on $ctx (${label}) after ${attempt} attempt(s)" >&2
			return 1
		fi
		echo "warn: apply hiccup on $ctx (${label}), attempt ${attempt}/${APPLY_ATTEMPTS}; retrying in ${APPLY_BACKOFF_S}s (transient 429?)" >&2
		attempt=$((attempt + 1))
		(( APPLY_BACKOFF_S > 0 )) && sleep "$APPLY_BACKOFF_S"
	done
}

# P1-3: split a rendered chart stream into per-document temp files, apply the
# Namespace doc(s) FIRST (so namespaced objects land into an existing namespace),
# then apply the remaining objects in batches of APPLY_CHUNK_OBJECTS — one giant
# SSA stream of ~3 objects/service (explicit scoping × 500 svc ≈ 1500 objects)
# throttles/partial-fails per context at scale. Each batch carries the P1-1 retry.
# <rendered_file> <ctx> <workdir>.
apply_chunked() {
	local rendered="$1" ctx="$2" workdir="$3"
	# Split on YAML document separators into one object per file (NNNNN.yaml),
	# skipping empty docs. csplit-free awk so no new tool dependency.
	awk -v dir="$workdir" '
		function flush() {
			if (buf ~ /[^[:space:]]/) { printf "%s", buf > sprintf("%s/%05d.yaml", dir, ++n) }
			buf = ""
		}
		/^---[[:space:]]*$/ { flush(); next }
		{ buf = buf $0 "\n" }
		END { flush() }
	' "$rendered"
	local -a ns_docs=() obj_docs=() f
	for f in "$workdir"/*.yaml; do
		[[ -e "$f" ]] || continue
		if grep -qE '^kind:[[:space:]]*Namespace[[:space:]]*$' "$f"; then
			ns_docs+=("$f")
		else
			obj_docs+=("$f")
		fi
	done
	# Namespace batch first (idempotent; ensures the ns exists before objects).
	if ((${#ns_docs[@]})); then
		cat "${ns_docs[@]}" > "$workdir/_batch_ns.yaml"
		apply_with_retry "$workdir/_batch_ns.yaml" "$ctx" "namespaces" || return 1
	fi
	# Remaining objects in chunks. APPLY_CHUNK_OBJECTS <= 0 -> single batch.
	local chunk="$APPLY_CHUNK_OBJECTS" total="${#obj_docs[@]}" i=0 b=0
	(( chunk <= 0 )) && chunk="$total"
	(( chunk <= 0 )) && return 0   # nothing to apply
	while (( i < total )); do
		b=$((b + 1))
		local batch="$workdir/_batch_${b}.yaml"
		: > "$batch"
		local j=0
		while (( j < chunk && i < total )); do
			cat "${obj_docs[i]}" >> "$batch"
			printf -- '---\n' >> "$batch"
			i=$((i + 1)); j=$((j + 1))
		done
		apply_with_retry "$batch" "$ctx" "objects batch ${b} ($((i<total?i:total))/${total})" || return 1
	done
	return 0
}

# O8 item 3: apply each context's chart concurrently — setup-only, disjoint
# contexts, fidelity-neutral. A non-zero exit in ANY context fails the join below,
# preserving the original `set -e` abort semantics.
APPLY_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "Setting up controlplane-test on context $ctx (${SERVICE_COUNT} services × ${REPLICAS} replicas across ${NAMESPACE_COUNT} namespace(s), sidecar-scoping=${SIDECAR_SCOPING})"
		rendered="$(mktemp)"
		workdir="$(mktemp -d)"
		trap 'rm -rf "$workdir" "$rendered"' EXIT
		helm template controlplane-test "$CHART_DIR" \
			--set clusterName="$ctx" \
			--set namespacePrefix="$NS" \
			--set namespaceCount="$NAMESPACE_COUNT" \
			--set serviceCount="$SERVICE_COUNT" \
			--set replicasPerService="$REPLICAS" \
			--set sidecarScoping="$SIDECAR_SCOPING" \
			> "$rendered" \
			|| { echo "error: helm template failed on $ctx" >&2; exit 1; }
		if ((DRY_RUN)); then
			# Dry-run never touches the cluster: a single client-side dry-run of the
			# whole render is sufficient (no throttle, no retry needed).
			"${apply[@]}" --context="$ctx" -f "$rendered" \
				|| { echo "error: dry-run apply failed on $ctx" >&2; exit 1; }
		else
			apply_chunked "$rendered" "$ctx" "$workdir" \
				|| { echo "error: apply failed on $ctx" >&2; exit 1; }
		fi
	) &
	APPLY_PIDS+=($!)
done
for pid in "${APPLY_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed the controlplane-test apply"
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

# Wait per-namespace using a label selector — one kubectl call covers every
# dummy-svc-* Deployment in that namespace, regardless of count. Much faster
# than per-Deployment loops, and survives missing-name races during rollout.
# O8 item 3: parallelize the per-context readiness wait (the per-namespace waits
# stay serial within each context's subshell). Setup-only, fidelity-neutral.
echo "Waiting for dummy deployments to be ready (timeout: ${WAIT_TIMEOUT}s)..."
WAIT_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "  Waiting on context $ctx..."
		for svc_ns in "${NAMESPACES[@]}"; do
			"${KUBECTL[@]}" --context="$ctx" -n "$svc_ns" wait \
				--for=condition=Available deployment \
				-l app.kubernetes.io/instance=controlplane-test \
				--timeout="${WAIT_TIMEOUT}s" \
				|| { echo "error: deployments in namespace $svc_ns on $ctx not Available within ${WAIT_TIMEOUT}s" >&2; exit 1; }
		done
		echo "  All deployments ready on $ctx."
	) &
	WAIT_PIDS+=($!)
done
for pid in "${WAIT_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed deployment readiness check"
done

# Verify Sidecar CRs landed when scoping is enabled.
if [[ "$SIDECAR_SCOPING" != "none" ]]; then
	echo "Verifying Sidecar CRs (sidecar-scoping=${SIDECAR_SCOPING})..."
	for ctx in "${CONTEXTS[@]}"; do
		deadline=$(( $(date +%s) + 30 ))
		count=0
		while (( $(date +%s) < deadline )); do
			count=$("${KUBECTL[@]}" --context="$ctx" -n "$NS" get sidecars.networking.istio.io \
				--no-headers --ignore-not-found 2>/dev/null | wc -l | tr -d ' ') || count=0
			[[ -z "$count" ]] && count=0
			(( count > 0 )) && break
			sleep 1
		done
		(( count > 0 )) || die "no Sidecar CRs found on $ctx after 30s (expected >=1 for scoping=$SIDECAR_SCOPING)"
		echo "  [$ctx] Sidecar CR count: $count"
	done
fi

echo "Setup complete. ${SERVICE_COUNT} services × ${REPLICAS} replicas across ${NAMESPACE_COUNT} namespace(s) (sidecar-scoping=${SIDECAR_SCOPING}) on: ${CONTEXTS[*]}"
