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
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_SERVICE_COUNT,
  CONTROLPLANE_REPLICAS_PER_SERVICE, CONTROLPLANE_NAMESPACE_COUNT,
  CONTROLPLANE_SIDECAR_SCOPING.

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
validate_scoping "$SIDECAR_SCOPING"

if ((NAMESPACE_COUNT > SERVICE_COUNT)); then
	die "--namespace-count ($NAMESPACE_COUNT) > --service-count ($SERVICE_COUNT); some namespaces would be empty. Reduce --namespace-count to at most --service-count."
fi

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

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
		current=$("${KUBECTL[@]}" --context="$ctx" get pods --all-namespaces --no-headers 2>/dev/null | wc -l) || current=""
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

# Use server-side apply so partial updates and field-manager ownership are
# tracked by the API server (no client-side last-applied annotation). With
# --force-conflicts we win any field-ownership conflict from a previous
# kubectl-client-side-apply run, which is what we want for a benchmarking
# harness that owns these namespaces exclusively.
apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/controlplane/chart"

# O8 item 3: apply each context's chart concurrently — setup-only, disjoint
# contexts, fidelity-neutral. A non-zero exit in ANY context fails the join below,
# preserving the original `set -e` abort semantics.
APPLY_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "Setting up controlplane-test on context $ctx (${SERVICE_COUNT} services × ${REPLICAS} replicas across ${NAMESPACE_COUNT} namespace(s), sidecar-scoping=${SIDECAR_SCOPING})"
		helm template controlplane-test "$CHART_DIR" \
			--set clusterName="$ctx" \
			--set namespacePrefix="$NS" \
			--set namespaceCount="$NAMESPACE_COUNT" \
			--set serviceCount="$SERVICE_COUNT" \
			--set replicasPerService="$REPLICAS" \
			--set sidecarScoping="$SIDECAR_SCOPING" \
			| "${apply[@]}" --context="$ctx" -f - \
			|| { echo "error: apply failed on $ctx" >&2; exit 1; }
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
