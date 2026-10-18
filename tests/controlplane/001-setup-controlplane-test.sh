#!/usr/bin/env bash
# Deploy dummy workloads for measuring istiod control-plane resource consumption.
#
# Applies one sweep point to each target cluster. Legacy layout: SERVICE_COUNT
# services x REPLICAS pods across NAMESPACE_COUNT namespaces (service i lands in
# namespace i mod N). One namespace is named ${NS}; more are ${NS}-0 .. ${NS}-(N-1).
# Growth mode (--services-per-namespace K > 0, the block layout used by 003's
# namespace-scaling sweep): namespaces ${NS}-<series>-<n> for n from --namespace-start
# to --namespace-count - 1, each with dummy-svc-0..K-1. --parts applies one piece
# only: the Sidecars of all N namespaces (a scoping switch), the namespaces outside
# the mesh, a probe namespace or the measurement pods.
# Manifests are applied server-side, in chunks, with a bounded retry. --dry-run only
# renders and prints the plan; it never contacts a cluster.
#
# Usage:
#   ./tests/controlplane/001-setup-controlplane-test.sh [--contexts CSV] [options]
#
# Examples:
#   # Setup on all default clusters (single namespace, 10 services x 3 replicas):
#   ./tests/controlplane/001-setup-controlplane-test.sh
#
#   # Spread 100 services across 10 namespaces:
#   ./tests/controlplane/001-setup-controlplane-test.sh --service-count 100 --namespace-count 10
#
#   # Setup with one Sidecar CR per namespace:
#   ./tests/controlplane/001-setup-controlplane-test.sh --sidecar-scoping namespace
#
#   # A VirtualService + DestinationRule (2 subsets) on every 3rd service:
#   ./tests/controlplane/001-setup-controlplane-test.sh --traffic-config vsdr --vsdr-every 3
#
#   # Growth mode: 50 namespaces x 2 Services, no pods except 4 measurement pods:
#   ./tests/controlplane/001-setup-controlplane-test.sh --services-per-namespace 2 \
#     --namespace-count 50 --workload-mode config-only --series demo --sidecar-scoping namespace
#   # ...grow it to 100 namespaces, then switch all 100 to wide scoping in place:
#   ./tests/controlplane/001-setup-controlplane-test.sh --services-per-namespace 2 \
#     --namespace-start 50 --namespace-count 100 --workload-mode config-only --series demo \
#     --sidecar-scoping namespace
#   ./tests/controlplane/001-setup-controlplane-test.sh --services-per-namespace 2 \
#     --namespace-count 100 --workload-mode config-only --series demo --sidecar-scoping wide \
#     --parts sidecars
#
#   # Everything from a run config (see tests/controlplane/README.md, "Run config"):
#   ./tests/controlplane/001-setup-controlplane-test.sh \
#     --config tests/controlplane/configs/smoke.env
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload controlplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # SCALE_* knobs
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # read-only capacity probes
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"  # now_ms for the apply timings
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # ns_lifecycle_init / _row / _api_counts

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT="${CONTROLPLANE_WAIT_TIMEOUT_SEC:-300}"
NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
SERVICE_COUNT_FLAG=0
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNT="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
SIDECAR_SCOPING="${CONTROLPLANE_SIDECAR_SCOPING:-none}"
TRAFFIC_CONFIG="${CONTROLPLANE_TRAFFIC_CONFIG:-none}"
VSDR_EVERY="${CONTROLPLANE_VSDR_EVERY:-1}"
VSDR_SUBSETS="${CONTROLPLANE_VSDR_SUBSETS:-2}"
# Namespace scaling (growth mode, the chart's block layout).
SERVICES_PER_NAMESPACE="${CONTROLPLANE_SERVICES_PER_NAMESPACE:-0}"
WORKLOAD_MODE="${CONTROLPLANE_WORKLOAD_MODE:-pods}"
MEASUREMENT_PODS="${CONTROLPLANE_MEASUREMENT_PODS:-4}"
MEASUREMENT_PROXY_MEM_LIMIT="${CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT:-2Gi}"
OUTSIDE_NAMESPACES="${CONTROLPLANE_OUTSIDE_NAMESPACES:-0}"
OUTSIDE_MODE="${CONTROLPLANE_OUTSIDE_MODE:-none}"
NAMESPACE_START=0
SERIES=""
PARTS=all
PROBE_NAME=""
LIFECYCLE_FILE=""
# How long to wait for the VirtualService/DestinationRule counts after the readiness
# wait (same bound as the Sidecar CR check).
VSDR_VERIFY_SEC=30
# A namespace still Terminating from the previous combo cannot be re-created, so
# wait for every target namespace to disappear before applying (same bound 005
# uses for its own termination wait).
SETUP_NS_WAIT_SEC="${CONTROLPLANE_SETUP_NS_WAIT_SEC:-${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}}"
# Bounded retry so a transient apiserver 429 does not fail the combo, and
# chunked apply so a large render is not one huge stream.
APPLY_ATTEMPTS="${CONTROLPLANE_APPLY_ATTEMPTS:-3}"
APPLY_BACKOFF_S="${CONTROLPLANE_APPLY_BACKOFF_S:-5}"
# Objects per apply batch; Namespace docs go first, in batches of the same size.
# <= 0 disables chunking.
APPLY_CHUNK_OBJECTS="${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-200}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE          Run config of KEY=value lines (config/options.env keys; see
                         tests/controlplane/README.md, "Run config").
                         Precedence: flag > --config > environment > default.
  --contexts CSV         Kube contexts to target (default: \$SETUP_CONTEXTS).
  --service-count N      Number of dummy services per cluster (default: $SERVICE_COUNT).
                         Growth mode ignores it (namespaces x services per namespace).
  --replicas N           Replicas per service (default: $REPLICAS).
  --namespace-count N    Spread services across N namespaces (default: $NAMESPACE_COUNT).
                         N=1 -> single namespace named '$NS'.
                         N>1 -> namespaces '${NS}-0' .. '${NS}-(N-1)';
                         service i lands in namespace (i mod N).
                         Growth mode: the series has namespaces 0..N-1.
  --sidecar-scoping MODE Sidecar CR scoping: none|namespace|wide|explicit (default: $SIDECAR_SCOPING).
                         none      - no Sidecar CRs (baseline; worst-case config size).
                         namespace - one Sidecar per workload namespace.
                         wide      - one Sidecar per workload namespace with egress */*
                                     (unscoped, without touching the root Sidecar).
                         explicit  - one Sidecar per Deployment with workloadSelector
                                     (legacy layout only).
  --traffic-config MODE  Traffic management per service: none|vsdr (default: $TRAFFIC_CONFIG).
                         none - no VirtualService/DestinationRule (baseline).
                         vsdr - a VirtualService (weighted route over the subsets,
                                timeout, retries) and a DestinationRule (subsets,
                                connectionPool, outlierDetection) per configured service.
                                Its replicas are split across one Deployment per subset
                                (version=v1..vN); the pod count is unchanged.
                                Legacy layout only.
  --vsdr-every N         vsdr: configure service i when i mod N == 0 (default: $VSDR_EVERY).
  --vsdr-subsets N       vsdr: DestinationRule subsets, at most --replicas (default: $VSDR_SUBSETS).
                         Run 005 before switching --traffic-config on the same clusters:
                         an in-place re-apply leaves the other mode's Deployments behind.

Namespace scaling (growth mode; README "Namespace scaling"):
  --services-per-namespace K
                         K > 0 selects the block layout: namespace n holds
                         dummy-svc-0..K-1 (default: $SERVICES_PER_NAMESPACE; 0 = legacy layout).
  --namespace-start N0   Apply only namespaces N0..N-1 of the series (a growth step;
                         default: 0).
  --series ID            Series id (lowercase letters, digits, '-'): namespaces are
                         '${NS}-<ID>-<n>' and every object is labelled
                         controlplane-test.series=<ID>.
  --workload-mode MODE   pods|config-only (default: $WORKLOAD_MODE). config-only: Services
                         without pods plus one measurement pod in each of namespaces
                         0..M-1 (istio-proxy limit CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT,
                         default $MEASUREMENT_PROXY_MEM_LIMIT).
  --measurement-pods M   config-only: measurement pods (default: $MEASUREMENT_PODS).
  --outside-namespaces X Namespaces outside the mesh, '${NS}-<ID>-out-<i>', each with K
                         Services and no pods (default: $OUTSIDE_NAMESPACES). Applied only
                         with --parts outside.
  --outside-mode MODE    none|unlabeled|labeled (default: $OUTSIDE_MODE): labeled adds
                         istio-discovery=enabled, so istiod discovers them.
  --parts PART           What to apply (default: all):
                         all         - the namespaces N0..N-1 with their Services,
                                       Sidecars and pods (or measurement pods).
                         sidecars    - the Sidecars of namespaces 0..N-1 for
                                       --sidecar-scoping (a scoping switch; none
                                       deletes the series' Sidecars).
                         outside     - the outside namespaces for --outside-mode.
                         probe       - one probe namespace (--probe NAME): K Services
                                       and the scoping's Sidecar, no pods.
                         measurement - the measurement Deployments of namespaces
                                       0..M-1 (raise M in place).
                         Legacy layout (no --services-per-namespace), for a two-phase
                         VS/DR apply (BACKLOG 9.11; 003 --vsdr-apply split):
                         workloads   - everything except the VirtualServices and
                                       DestinationRules (namespaces, Services,
                                       Sidecars, the per-subset Deployments).
                         traffic     - only the VirtualServices and DestinationRules
                                       (needs --traffic-config vsdr and the workloads
                                       part applied first).
  --probe NAME           Probe namespace name (with --parts probe).
  --lifecycle-file FILE  Append apply/readiness timings, objects/s, namespaces/s and API
                         429s (retried by client-go and exhausted; applies run at
                         kubectl -v=4 to see them) to this namespace-lifecycle TSV
                         (003 passes it).

  --dry-run              Render the chart and print the plan (objects per kind, apply
                         batches, the commands); never contacts a cluster.
  --wait-timeout N       Seconds to wait for pods (default: $WAIT_TIMEOUT).
  --ns-wait-timeout N    Seconds to wait for a pre-existing (Terminating) namespace
                         to disappear before applying (default: $SETUP_NS_WAIT_SEC;
                         skipped in --dry-run).
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_SERVICE_COUNT,
  CONTROLPLANE_REPLICAS_PER_SERVICE, CONTROLPLANE_NAMESPACE_COUNT,
  CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_TRAFFIC_CONFIG, CONTROLPLANE_VSDR_EVERY, CONTROLPLANE_VSDR_SUBSETS,
  CONTROLPLANE_SERVICES_PER_NAMESPACE, CONTROLPLANE_WORKLOAD_MODE,
  CONTROLPLANE_MEASUREMENT_PODS, CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT,
  CONTROLPLANE_OUTSIDE_NAMESPACES, CONTROLPLANE_OUTSIDE_MODE,
  CONTROLPLANE_SETUP_NS_WAIT_SEC (default: CONTROLPLANE_NS_DELETE_TIMEOUT_SEC, then 300),
  CONTROLPLANE_APPLY_ATTEMPTS / CONTROLPLANE_APPLY_BACKOFF_S (apply retry, default 3 / 5s),
  CONTROLPLANE_APPLY_CHUNK_OBJECTS (objects per apply batch, default 200; <=0 disables),
  CONTROLPLANE_WAIT_TIMEOUT_SEC (--wait-timeout default, 300),
  BUSYBOX_VERSION (dummy workload image tag).

  Scale coverage (off by default): SCALE_SIZING_MODE (fixed|auto; auto derives the
  service count from cluster capacity; legacy layout only), SCALE_TARGET_FRACTION,
  SCALE_SYSTEM_RESERVE_FRACTION, SCALE_PER_POD_CPU_M, SCALE_PER_POD_MEM_MI,
  SCALE_COVERAGE_MIN_FRACTION, SCALE_COVERAGE_ENFORCE (1 = fail when under-provisioned).

  Capacity preflight (always on in live runs): refuses when a member lacks pod slots, or
  when the new pods' CPU requests exceed the workers' free requests (allocatable minus
  what running pods request); SCALE_CPU_PREFLIGHT_ENFORCE=0 turns the CPU refusal into a
  warning (default 1; for clusters with a node autoscaler).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--service-count)
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		SERVICE_COUNT="$2"
		SERVICE_COUNT_FLAG=1
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
	--traffic-config)
		[[ -n "${2:-}" ]] || die "--traffic-config requires a value"
		TRAFFIC_CONFIG="$2"
		shift 2
		;;
	--vsdr-every)
		[[ -n "${2:-}" ]] || die "--vsdr-every requires a value"
		VSDR_EVERY="$2"
		shift 2
		;;
	--vsdr-subsets)
		[[ -n "${2:-}" ]] || die "--vsdr-subsets requires a value"
		VSDR_SUBSETS="$2"
		shift 2
		;;
	--services-per-namespace)
		[[ -n "${2:-}" ]] || die "--services-per-namespace requires a value"
		SERVICES_PER_NAMESPACE="$2"
		shift 2
		;;
	--namespace-start)
		[[ -n "${2:-}" ]] || die "--namespace-start requires a value"
		NAMESPACE_START="$2"
		shift 2
		;;
	--series)
		[[ -n "${2:-}" ]] || die "--series requires a value"
		SERIES="$2"
		shift 2
		;;
	--workload-mode)
		[[ -n "${2:-}" ]] || die "--workload-mode requires a value"
		WORKLOAD_MODE="$2"
		shift 2
		;;
	--measurement-pods)
		[[ -n "${2:-}" ]] || die "--measurement-pods requires a value"
		MEASUREMENT_PODS="$2"
		shift 2
		;;
	--outside-namespaces)
		[[ -n "${2:-}" ]] || die "--outside-namespaces requires a value"
		OUTSIDE_NAMESPACES="$2"
		shift 2
		;;
	--outside-mode)
		[[ -n "${2:-}" ]] || die "--outside-mode requires a value"
		OUTSIDE_MODE="$2"
		shift 2
		;;
	--parts)
		[[ -n "${2:-}" ]] || die "--parts requires a value"
		PARTS="$2"
		shift 2
		;;
	--probe)
		[[ -n "${2:-}" ]] || die "--probe requires a value"
		PROBE_NAME="$2"
		shift 2
		;;
	--lifecycle-file)
		[[ -n "${2:-}" ]] || die "--lifecycle-file requires a value"
		LIFECYCLE_FILE="$2"
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
validate_traffic_config "$TRAFFIC_CONFIG"
is_pos_int "$VSDR_EVERY" || die "--vsdr-every must be a positive integer (got: $VSDR_EVERY)"
is_pos_int "$VSDR_SUBSETS" || die "--vsdr-subsets must be a positive integer (got: $VSDR_SUBSETS)"
if [[ "$TRAFFIC_CONFIG" == vsdr ]] && ((VSDR_SUBSETS > REPLICAS)); then
	die "--vsdr-subsets ($VSDR_SUBSETS) > --replicas ($REPLICAS): each DestinationRule subset needs at least one pod. Lower --vsdr-subsets or raise --replicas."
fi
is_nonneg_int "$SERVICES_PER_NAMESPACE" || die "--services-per-namespace must be a non-negative integer (got: $SERVICES_PER_NAMESPACE)"
is_nonneg_int "$NAMESPACE_START" || die "--namespace-start must be a non-negative integer (got: $NAMESPACE_START)"
is_pos_int "$MEASUREMENT_PODS" || die "--measurement-pods must be a positive integer (got: $MEASUREMENT_PODS)"
is_nonneg_int "$OUTSIDE_NAMESPACES" || die "--outside-namespaces must be a non-negative integer (got: $OUTSIDE_NAMESPACES)"
validate_workload_mode "$WORKLOAD_MODE"
validate_outside_mode "$OUTSIDE_MODE"
case "$PARTS" in
all | sidecars | outside | probe | measurement | workloads | traffic) ;;
*) die "--parts must be one of [all, sidecars, outside, probe, measurement, workloads, traffic]; got '$PARTS'" ;;
esac
SCALE_SIZING_MODE="${SCALE_SIZING_MODE:-fixed}"
DNS_LABEL_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

GROWTH=0
((SERVICES_PER_NAMESPACE > 0)) && GROWTH=1
if ((GROWTH)); then
	[[ "$PARTS" != workloads && "$PARTS" != traffic ]] || die "--parts $PARTS is for the legacy layout (no --services-per-namespace)"
	[[ "$SIDECAR_SCOPING" != explicit ]] || die "--sidecar-scoping explicit is not supported with --services-per-namespace (use none, namespace or wide)"
	[[ "$TRAFFIC_CONFIG" == none ]] || die "--traffic-config vsdr is not supported with --services-per-namespace"
	[[ "$SCALE_SIZING_MODE" != auto ]] || die "SCALE_SIZING_MODE=auto derives --service-count, which growth mode does not use; set SCALE_SIZING_MODE=fixed"
	((NAMESPACE_START < NAMESPACE_COUNT)) || die "--namespace-start ($NAMESPACE_START) must be below --namespace-count ($NAMESPACE_COUNT)"
	[[ -z "$SERIES" || "$SERIES" =~ $DNS_LABEL_RE ]] || die "--series must be lowercase letters, digits and '-' (got: $SERIES)"
	if [[ "$PARTS" == probe ]]; then
		[[ -n "$PROBE_NAME" ]] || die "--parts probe requires --probe NAME"
		[[ "$PROBE_NAME" =~ $DNS_LABEL_RE && ${#PROBE_NAME} -le 63 ]] || die "--probe must be a DNS label of at most 63 characters (got: $PROBE_NAME)"
	else
		[[ -z "$PROBE_NAME" ]] || die "--probe is only valid with --parts probe"
	fi
	if [[ "$PARTS" == measurement && "$WORKLOAD_MODE" != config-only ]]; then
		die "--parts measurement needs --workload-mode config-only"
	fi
	if [[ "$PARTS" == outside && "$OUTSIDE_MODE" != none ]] && ((OUTSIDE_NAMESPACES == 0)); then
		die "--parts outside --outside-mode $OUTSIDE_MODE needs --outside-namespaces > 0"
	fi
	((SERVICE_COUNT_FLAG)) && echo "note: --service-count is ignored with --services-per-namespace (services = namespaces x services per namespace)" >&2
	# The services in the series' namespaces (recorded by 002 as service_count).
	SERVICE_COUNT=$((NAMESPACE_COUNT * SERVICES_PER_NAMESPACE))
else
	case "$PARTS" in
	all | workloads) ;;
	traffic) [[ "$TRAFFIC_CONFIG" == vsdr ]] || die "--parts traffic applies the VirtualServices and DestinationRules, so it needs --traffic-config vsdr" ;;
	*) die "--parts $PARTS needs --services-per-namespace > 0 (growth mode)" ;;
	esac
	[[ "$WORKLOAD_MODE" == pods ]] || die "--workload-mode $WORKLOAD_MODE needs --services-per-namespace > 0 (growth mode)"
	((NAMESPACE_START == 0)) || die "--namespace-start needs --services-per-namespace > 0 (growth mode)"
	[[ -z "$SERIES" ]] || die "--series needs --services-per-namespace > 0 (growth mode)"
	[[ -z "$PROBE_NAME" ]] || die "--probe needs --services-per-namespace > 0 (growth mode)"
	if ((NAMESPACE_COUNT > SERVICE_COUNT)); then
		die "--namespace-count ($NAMESPACE_COUNT) > --service-count ($SERVICE_COUNT); some namespaces would be empty. Reduce --namespace-count to at most --service-count."
	fi
fi

# The CLI. --dry-run never calls it, so it only needs a name to print there.
KUBECTL=()
if ((DRY_RUN)); then
	if command -v kubectl >/dev/null 2>&1; then KUBECTL=(kubectl)
	elif command -v oc >/dev/null 2>&1; then KUBECTL=(oc)
	else KUBECTL=(kubectl)
	fi
else
	resolve_kubectl KUBECTL
fi

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_contexts "$CONTEXTS_CSV" CONTEXTS --contexts
else
	split_contexts "$SETUP_CONTEXTS" CONTEXTS SETUP_CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

# Growth-mode names (mirror chart/templates/_helpers.tpl nsBase/namespaceName).
NS_BASE="$NS"
[[ -n "$SERIES" ]] && NS_BASE="${NS}-${SERIES}"
# Label selectors: every test object, the series' objects, and the series' own
# Sidecars (not a probe namespace's).
BASE_SELECTOR="app.kubernetes.io/instance=controlplane-test"
SERIES_SELECTOR="$BASE_SELECTOR"
[[ -n "$SERIES" ]] && SERIES_SELECTOR="${BASE_SELECTOR},controlplane-test.series=${SERIES}"
SERIES_SIDECAR_SELECTOR="${SERIES_SELECTOR},!controlplane-test.probe"
M_EFF=$(( MEASUREMENT_PODS < NAMESPACE_COUNT ? MEASUREMENT_PODS : NAMESPACE_COUNT ))

# Namespaces this run creates (the Terminating wait targets), the chart's namespace
# window, and the readiness selector.
NAMESPACES=()
RENDER_START=0
RENDER_OUTSIDE=0
SHOW_ONLY=""
if ((GROWTH)); then
	case "$PARTS" in
	all)
		RENDER_START="$NAMESPACE_START"
		for ((n = NAMESPACE_START; n < NAMESPACE_COUNT; n++)); do NAMESPACES+=("${NS_BASE}-${n}"); done
		;;
	sidecars) SHOW_ONLY="templates/sidecar.yaml" ;;
	outside)
		SHOW_ONLY="templates/outside.yaml"
		if [[ "$OUTSIDE_MODE" != none ]]; then
			RENDER_OUTSIDE="$OUTSIDE_NAMESPACES"
			for ((n = 0; n < OUTSIDE_NAMESPACES; n++)); do NAMESPACES+=("${NS_BASE}-out-${n}"); done
		fi
		;;
	probe)
		SHOW_ONLY="templates/probe.yaml"
		NAMESPACES=("$PROBE_NAME")
		;;
	measurement) SHOW_ONLY="templates/dummy-deployment.yaml" ;;
	esac
elif [[ "$PARTS" == traffic ]]; then
	# Only the VS/DR of namespaces the workloads part created: nothing to wait for.
	SHOW_ONLY="templates/traffic-management.yaml"
elif ((NAMESPACE_COUNT <= 1)); then
	NAMESPACES=("$NS")
else
	for ((n = 0; n < NAMESPACE_COUNT; n++)); do NAMESPACES+=("${NS}-${n}"); done
fi
# Kinds the render drops before the apply (the workloads part of a two-phase VS/DR apply).
SKIP_KINDS=""
[[ "$PARTS" == workloads ]] && SKIP_KINDS="VirtualService,DestinationRule"
# Lifecycle action name (003's ns-lifecycle TSV).
case "$PARTS" in
workloads) ACTION="apply-workloads" ;;
traffic) ACTION="apply-traffic" ;;
all) if ((GROWTH)); then ACTION=grow; else ACTION=apply; fi ;;
sidecars) ACTION="switch-${SIDECAR_SCOPING}" ;;
outside) ACTION="outside-${OUTSIDE_MODE}" ;;
probe) ACTION=probe ;;
measurement) ACTION="measurement-${MEASUREMENT_PODS}" ;;
esac

echo "=== Control-plane test setup ==="
echo "Contexts:        ${CONTEXTS[*]}"
if ((GROWTH)); then
	echo "Layout:          growth (block): ${SERVICES_PER_NAMESPACE} services per namespace, series '${SERIES:-none}'"
	echo "Namespaces:      ${NS_BASE}-0..${NS_BASE}-$((NAMESPACE_COUNT - 1)) (${NAMESPACE_COUNT}; this run applies part '${PARTS}'$([[ "$PARTS" == all ]] && echo ", namespaces ${NAMESPACE_START}..$((NAMESPACE_COUNT - 1))"))"
	if [[ "$WORKLOAD_MODE" == config-only ]]; then
		echo "Workload:        config-only (${M_EFF} measurement pod(s), istio-proxy limit ${MEASUREMENT_PROXY_MEM_LIMIT})"
	else
		echo "Workload:        pods (${REPLICAS} replica(s) per service)"
	fi
	[[ "$PARTS" == outside ]] && echo "Outside:         ${OUTSIDE_NAMESPACES} namespace(s), mode ${OUTSIDE_MODE}"
	[[ "$PARTS" == probe ]] && echo "Probe:           ${PROBE_NAME}"
else
	echo "Services:        $SERVICE_COUNT"
	echo "Replicas/svc:    $REPLICAS"
	echo "Namespace count: $NAMESPACE_COUNT"
	echo "Namespaces:      ${NAMESPACES[*]}"
fi
echo "Sidecar scoping: $SIDECAR_SCOPING"
if [[ "$TRAFFIC_CONFIG" == vsdr ]]; then
	echo "Traffic config:  vsdr (every ${VSDR_EVERY}, ${VSDR_SUBSETS} subsets; VS+DR on $(vsdr_service_count "$SERVICE_COUNT" "$VSDR_EVERY") of ${SERVICE_COUNT} services)"
else
	echo "Traffic config:  none"
fi
((DRY_RUN)) && echo "Mode:            dry-run"
[[ "$SCALE_SIZING_MODE" == auto ]] && echo "Sizing mode:     auto (capacity-derived SERVICE_COUNT)"
echo ""

# Capacity-derived sizing, only with SCALE_SIZING_MODE=auto and never in --dry-run.
#
# per_pod_cpu_m / per_pod_mem_mi: the dummy chart's container declares NO resources
# block (tests/controlplane/chart/templates/dummy-deployment.yaml), so the app
# container's request is effectively 0; the dominant cost is the injected istio-proxy
# sidecar. SCALE_PER_POD_* (config/options.env) win when set; otherwise the live Istio
# CR's sidecar requests on the source context, else Istio's defaults (100m / 128Mi)
# (BACKLOG 9.7: a 200m constant flagged 250 x 2 pods as not fitting on ROSA, where the
# sidecar requested 20m). SCALE_TARGET_FRACTION and the reserve keep the headroom.
if [[ "$SCALE_SIZING_MODE" == auto ]] && ! ((DRY_RUN)); then
	src_ctx="${CONTEXTS[0]}"
	[[ -z "${SCALE_PER_POD_CPU_M:-}" ]] || is_pos_int "$SCALE_PER_POD_CPU_M" || die "SCALE_PER_POD_CPU_M must be empty or a positive integer (got: $SCALE_PER_POD_CPU_M)"
	[[ -z "${SCALE_PER_POD_MEM_MI:-}" ]] || is_pos_int "$SCALE_PER_POD_MEM_MI" || die "SCALE_PER_POD_MEM_MI must be empty or a positive integer (got: $SCALE_PER_POD_MEM_MI)"
	ppr="$(cap_per_pod_requests "$src_ctx" "${SCALE_PER_POD_CPU_M:-}" "${SCALE_PER_POD_MEM_MI:-}" "${KUBECTL[@]}")"
	PER_POD_CPU_M="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^cpu_m=/) print substr($i, 7) }' <<<"$ppr")"
	PER_POD_MEM_MI="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^mem_mi=/) print substr($i, 8) }' <<<"$ppr")"
	echo "Auto-sizing from capacity on source context $src_ctx (target_fraction=${SCALE_TARGET_FRACTION}, reserve=${SCALE_SYSTEM_RESERVE_FRACTION})..."
	echo "  per pod: ${PER_POD_CPU_M}m CPU / ${PER_POD_MEM_MI}Mi ($(awk '{ for (i = 1; i <= NF; i++) { if ($i ~ /^cpu_src=/) c = substr($i, 9); if ($i ~ /^mem_src=/) m = substr($i, 9) } } END { gsub(/_/, " ", c); gsub(/_/, " ", m); printf "CPU: %s; memory: %s", c, m }' <<<"$ppr"))"
	a_cpu="unknown"; a_mem="unknown"; a_pods="unknown"
	# shellcheck disable=SC2207
	nt=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in ${nt[@]+"${nt[@]}"}; do
		case "$kv" in
			cpu_m=*) a_cpu="${kv#cpu_m=}" ;;
			mem_mi=*) a_mem="${kv#mem_mi=}" ;;
			pods=*) a_pods="${kv#pods=}" ;;
		esac
	done
	i_cpu="unknown"; i_mem="unknown"; i_rep="unknown"
	# shellcheck disable=SC2207
	il=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in ${il[@]+"${il[@]}"}; do
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

# root_sidecar_hosts <ctx>: the live root-Sidecar egress hosts (space-joined
# "<ns>/<dns>" entries, the query preamble.sh uses for SIDECAR_EGRESS_HOSTS), or
# __unreadable__.
root_sidecar_hosts() {
	"${KUBECTL[@]}" --context="$1" --request-timeout=5s -n istio-system \
		get sidecar.networking.istio.io default \
		-o jsonpath='{.spec.egress[*].hosts[*]}' 2>/dev/null || echo "__unreadable__"
}

# Sidecar egress-coverage precondition. With NAMESPACE_COUNT > 1 the suite creates
# ${NS}-0, ${NS}-1, ... but the root Sidecar's egress hosts match namespaces exactly
# ("controlplane-test/*" does not cover "controlplane-test-0/*"), so with scoping
# `none` each proxy would silently see only its own namespace. Fail fast instead.
# `namespace`/`explicit` scoping deploys its own Sidecar for every workload, which
# replaces the root Sidecar, so the check does not apply. Read-only, live-queried,
# skipped in --dry-run.
if ! ((DRY_RUN)) && ! ((GROWTH)) && ((NAMESPACE_COUNT > 1)) && [[ "$SIDECAR_SCOPING" == none ]]; then
	echo "Sidecar egress-coverage precondition (namespaceCount=$NAMESPACE_COUNT > 1)..."
	for ctx in "${CONTEXTS[@]}"; do
		hosts="$(root_sidecar_hosts "$ctx")"
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
			die "context $ctx: the deployed root Sidecar egress allow-list does NOT cover these controlplane-test namespaces: ${missing[*]}. egressHosts namespace parts are EXACT matches (\"controlplane-test/*\" does NOT cover \"controlplane-test-0/*\"). Add an explicit \"<ns>/*\" entry for each to charts/spoke-ossm/values.yaml tuningBaseline.sidecar.egressHosts (and re-sync the mesh), or run with --namespace-count 1 or --sidecar-scoping namespace|explicit. Current egress hosts: ${hosts}"
		fi
		echo "  $ctx: all $NAMESPACE_COUNT generated namespaces covered by the Sidecar egress allow-list — OK"
	done
	echo ""
fi

# Growth mode: `none` means "no test Sidecar", so the live root Sidecar governs each
# proxy. It cannot list thousands of namespaces, so the rule here is that it must keep
# the proxy's own namespace (./*) or everything (*/*); without a root Sidecar `none`
# is the unscoped mesh. The live hosts are recorded in the preamble (PL39).
if ! ((DRY_RUN)) && ((GROWTH)) && [[ "$SIDECAR_SCOPING" == none ]] && [[ "$PARTS" == all || "$PARTS" == sidecars || "$PARTS" == probe ]]; then
	echo "Root Sidecar check for growth-mode scoping none..."
	for ctx in "${CONTEXTS[@]}"; do
		hosts="$(root_sidecar_hosts "$ctx")"
		if [[ "$hosts" == "__unreadable__" ]]; then
			echo "  WARN: $ctx: no readable root Sidecar; scoping none is the unscoped mesh there (every proxy sees every discovered Service)." >&2
			continue
		fi
		if [[ " $hosts " != *" ./* "* && " $hosts " != *" */* "* ]]; then
			die "context $ctx: growth-mode --sidecar-scoping none relies on the root Sidecar, but its egress hosts have neither ./* nor */*, so a proxy would not see its own namespace. Current egress hosts: ${hosts}"
		fi
		echo "  $ctx: root Sidecar egress keeps the own namespace — OK (${hosts})"
	done
	echo ""
fi

# Pods this run adds per cluster (the capacity preflight's demand).
NEEDED_PODS=0
if ! ((GROWTH)) && [[ "$PARTS" == traffic ]]; then
	NEEDED_PODS=0
elif ! ((GROWTH)); then
	NEEDED_PODS=$((SERVICE_COUNT * REPLICAS))
elif [[ "$PARTS" == all && "$WORKLOAD_MODE" == pods ]]; then
	NEEDED_PODS=$(( (NAMESPACE_COUNT - NAMESPACE_START) * SERVICES_PER_NAMESPACE * REPLICAS ))
elif [[ "$PARTS" == all ]]; then
	NEEDED_PODS=$(( M_EFF > NAMESPACE_START ? M_EFF - NAMESPACE_START : 0 ))
elif [[ "$PARTS" == measurement ]]; then
	# Counts the measurement pods that already run too (conservative).
	NEEDED_PODS="$M_EFF"
fi

# Capacity preflight: die if a cluster lacks pod slots for the planned workload.
# Under SCALE_SIZING_MODE=auto also warn on under-provision (fail only when
# SCALE_COVERAGE_ENFORCE=1).
if ! ((DRY_RUN)) && ((NEEDED_PODS > 0)); then
	echo "Capacity preflight ($NEEDED_PODS pods needed per cluster)..."
	[[ "${SCALE_CPU_PREFLIGHT_ENFORCE:-1}" =~ ^[01]$ ]] || die "SCALE_CPU_PREFLIGHT_ENFORCE must be 0 or 1 (got: ${SCALE_CPU_PREFLIGHT_ENFORCE})"
	# Per-pod CPU request: auto-sizing's reading when it ran, else the same reader.
	if [[ -n "${PER_POD_CPU_M:-}" ]]; then
		CPU_PER_POD_M="$PER_POD_CPU_M"; CPU_PER_POD_SRC="as auto-sizing read it"
	else
		[[ -z "${SCALE_PER_POD_CPU_M:-}" ]] || is_pos_int "$SCALE_PER_POD_CPU_M" || die "SCALE_PER_POD_CPU_M must be empty or a positive integer (got: $SCALE_PER_POD_CPU_M)"
		ppr="$(cap_per_pod_requests "${CONTEXTS[0]}" "${SCALE_PER_POD_CPU_M:-}" "${SCALE_PER_POD_MEM_MI:-}" "${KUBECTL[@]}")"
		CPU_PER_POD_M="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^cpu_m=/) print substr($i, 7) }' <<<"$ppr")"
		CPU_PER_POD_SRC="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^cpu_src=/) print substr($i, 9) }' <<<"$ppr" | tr '_' ' ')"
	fi
	CPU_NEEDED_M=$(( NEEDED_PODS * CPU_PER_POD_M ))
	cpu_cores() { awk -v m="$1" 'BEGIN { printf "%.1f", m / 1000 }'; }
	for ctx in "${CONTEXTS[@]}"; do
		alloc=$("${KUBECTL[@]}" --context="$ctx" get nodes -o json 2>/dev/null \
			| jq '[.items[].status.allocatable.pods // "0" | tonumber] | add // 0' 2>/dev/null) || alloc=""
		# Cheap cluster-wide pod count: `-o name` (names only, no specs) + server-side
		# paging so a 10k-pod × 20-context preflight doesn't stream a huge table per
		# cluster on the hot path. One line per pod -> `wc -l`. Only non-terminal pods
		# hold a slot (the scheduler and kubelet ignore Succeeded/Failed pods for
		# allocatable.pods), so finished Job pods are excluded server-side.
		current=$("${KUBECTL[@]}" --context="$ctx" get pods --all-namespaces -o name \
			--field-selector=status.phase!=Succeeded,status.phase!=Failed \
			--chunk-size="${CAP_POD_CHUNK_SIZE:-500}" 2>/dev/null | wc -l) || current=""
		if [[ -n "$alloc" && -n "$current" ]] && is_nonneg_int "$alloc" && is_nonneg_int "$current"; then
			remaining=$((alloc - current))
			if ((NEEDED_PODS > remaining)); then
				die "context $ctx: need $NEEDED_PODS pods but only $remaining slots available ($alloc allocatable − $current non-terminal pods). Reduce --service-count, --replicas, --namespace-count or --measurement-pods, or add nodes."
			fi
			echo "  $ctx: $remaining pod slots available ($NEEDED_PODS needed) — OK"
			# Under-provision coverage floor (auto mode only).
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
		# CPU: a pod schedules only where its requests fit, so pods beyond the free
		# requests stay Pending and the readiness wait fails minutes later. Free = worker
		# allocatable − what every non-terminal pod already requests (summed over nodes,
		# so per-node fragmentation can still leave a few Pending).
		cpu_alloc=""; cpu_workers=""; cpu_req=""
		# shellcheck disable=SC2207
		nt=($(cap_node_totals "$ctx" "${KUBECTL[@]}"))
		for kv in ${nt[@]+"${nt[@]}"}; do
			case "$kv" in
				cpu_m=*) cpu_alloc="${kv#cpu_m=}" ;;
				names=*) cpu_workers="${kv#names=}" ;;
			esac
		done
		# shellcheck disable=SC2207
		rq=($(cap_requested "$ctx" "$cpu_workers" "" "${KUBECTL[@]}"))
		for kv in ${rq[@]+"${rq[@]}"}; do case "$kv" in cpu_m=*) cpu_req="${kv#cpu_m=}" ;; esac; done
		if [[ "$cpu_alloc" =~ ^[0-9]+$ && "$cpu_req" =~ ^[0-9]+$ ]]; then
			cpu_free=$(( cpu_alloc > cpu_req ? cpu_alloc - cpu_req : 0 ))
			cpu_line="~$(cpu_cores "$cpu_free") cores of CPU requests free on the workers ($(cpu_cores "$cpu_alloc") allocatable − $(cpu_cores "$cpu_req") requested), ~$(cpu_cores "$CPU_NEEDED_M") needed ($NEEDED_PODS pods × ${CPU_PER_POD_M}m, ${CPU_PER_POD_SRC})"
			if (( CPU_NEEDED_M > cpu_free )); then
				cpu_fit=$(( cpu_free / CPU_PER_POD_M ))
				if [[ "${SCALE_CPU_PREFLIGHT_ENFORCE:-1}" == "1" ]]; then
					die "context $ctx: ${cpu_line}; about ${cpu_fit} pods fit. Reduce --service-count, --replicas, --namespace-count or --measurement-pods, or add nodes (SCALE_CPU_PREFLIGHT_ENFORCE=0 only warns, for a node autoscaler)."
				fi
				echo "  WARN: $ctx: ${cpu_line}; about ${cpu_fit} pods fit; the rest stay Pending unless a node autoscaler adds capacity (SCALE_CPU_PREFLIGHT_ENFORCE=0)." >&2
			else
				echo "  $ctx: ${cpu_line} — OK"
			fi
		else
			echo "  $ctx: could not read node CPU or pod requests (alloc=${cpu_alloc:-unknown}, requested=${cpu_req:-unknown}) — skipping the CPU check" >&2
		fi
	done
	echo ""
fi

WORKDIR_ROOT="$(mktemp -d -t controlplane-001.XXXXXX)"
trap 'rm -rf "$WORKDIR_ROOT"' EXIT
TARGETS_FILE="${WORKDIR_ROOT}/targets"
printf '%s\n' "${NAMESPACES[@]}" | grep . > "$TARGETS_FILE" || true

# Wait until no target namespace is Terminating on this context (an Active one is
# re-applied in place); return 1 if one is still Terminating after SETUP_NS_WAIT_SEC
# (the apply would fail anyway). One namespace list per poll covers every target, so
# the wait costs the same at 4000 namespaces as at one.
wait_ns_gone() {
	local ctx="$1" deadline snap counts term active first=1
	deadline=$(( $(date +%s) + SETUP_NS_WAIT_SEC ))
	while :; do
		if ! snap="$("${KUBECTL[@]}" --context="$ctx" --request-timeout=30s get namespaces \
			-o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null)"; then
			echo "  [$ctx] WARN: could not list namespaces; applying without the Terminating check" >&2
			return 0
		fi
		counts="$(awk -F'\t' 'NR == FNR { t[$1] = 1; next } ($1 in t) { if ($2 == "Terminating") term++; else act++ } END { printf "%d %d\n", term, act }' \
			"$TARGETS_FILE" <(printf '%s\n' "$snap"))"
		term="${counts% *}"; active="${counts#* }"
		if ((first)) && ((active > 0)); then
			echo "  [$ctx] note: ${active} target namespace(s) already exist; applying in place (run 005 first for a clean start)" >&2
		fi
		((term == 0)) && { ((first)) || echo "  [$ctx] Terminating namespaces cleared; proceeding with apply." >&2; return 0; }
		if ((first)); then
			echo "  [$ctx] ${term} target namespace(s) Terminating; waiting up to ${SETUP_NS_WAIT_SEC}s for them to clear before apply..." >&2
		fi
		first=0
		if (( $(date +%s) > deadline )); then
			echo "  [$ctx] ${term} target namespace(s) did not clear within ${SETUP_NS_WAIT_SEC}s; cannot apply into a Terminating namespace; check stuck finalizers: ${KUBECTL[*]} --context=$ctx get ns -l ${BASE_SELECTOR} --field-selector=status.phase=Terminating" >&2
			return 1
		fi
		sleep 2
	done
}

if ((DRY_RUN)) && [[ -s "$TARGETS_FILE" ]]; then
	# Mirror the live wait's plan style; the actual wait below is DRY_RUN-gated so
	# no cluster call happens in --dry-run.
	echo "  [dry-run] would wait up to ${SETUP_NS_WAIT_SEC}s for any of the $(grep -c . "$TARGETS_FILE") target namespace(s) still Terminating on each context before apply" >&2
fi

if ! ((DRY_RUN)) && [[ -s "$TARGETS_FILE" ]]; then
	NS_WAIT_PIDS=()
	for ctx in "${CONTEXTS[@]}"; do
		wait_ns_gone "$ctx" &
		NS_WAIT_PIDS+=($!)
	done
	for pid in "${NS_WAIT_PIDS[@]}"; do
		wait "$pid" || die "a pre-existing namespace did not clear within ${SETUP_NS_WAIT_SEC}s on one or more contexts; refusing to apply into a Terminating namespace"
	done
fi

if [[ -n "$LIFECYCLE_FILE" ]] && ! ((DRY_RUN)); then
	ns_lifecycle_init "$LIFECYCLE_FILE" "standalone-001"
fi

# Use server-side apply so partial updates and field-manager ownership are
# tracked by the API server (no client-side last-applied annotation). With
# --force-conflicts we win any field-ownership conflict from a previous
# kubectl-client-side-apply run, which is what we want for a benchmarking
# harness that owns these namespaces exclusively.
# -v=4: client-go retries an API 429 (with Retry-After) silently at the default
# verbosity; at -v=4 it logs each retry, which count_throttle counts (stderr only).
apply=("${KUBECTL[@]}" apply --server-side --force-conflicts -v=4)

CHART_DIR="${ROOT}/tests/controlplane/chart"

# Per-context counters, set inside each context's subshell.
APPLIED_OBJECTS=0
API_429_RETRIED=0
API_429_EXHAUSTED=0
CLIENT_THROTTLE=0

# count_throttle <stderr_file>: add a kubectl -v=4 call's retried 429s, exhausted 429s
# and client-side throttling waits to the counters (ns_lifecycle_api_counts).
count_throttle() {
	local r e t
	read -r r e t < <(ns_lifecycle_api_counts "$1")
	API_429_RETRIED=$((API_429_RETRIED + ${r:-0}))
	API_429_EXHAUSTED=$((API_429_EXHAUSTED + ${e:-0}))
	CLIENT_THROTTLE=$((CLIENT_THROTTLE + ${t:-0}))
}

# kubectl_errors <stderr_file>: the stderr of a -v=4 call without its klog info lines.
kubectl_errors() { grep -vE '^I[0-9]{4} ' "$1" || true; }

# Apply a manifest with a bounded retry. <manifest_file> <ctx> <label>.
apply_with_retry() {
	local manifest="$1" ctx="$2" label="$3" attempt=1 out err n
	out="${manifest}.out"; err="${manifest}.err"
	while :; do
		if "${apply[@]}" --context="$ctx" -f "$manifest" >"$out" 2>"$err"; then
			count_throttle "$err"
			n=$(grep -c . "$out" || true)
			APPLIED_OBJECTS=$((APPLIED_OBJECTS + ${n:-0}))
			echo "  [$ctx] ${label}: ${n:-0} object(s) applied"
			return 0
		fi
		count_throttle "$err"
		if (( attempt >= APPLY_ATTEMPTS )); then
			echo "error: apply failed on $ctx (${label}) after ${attempt} attempt(s):" >&2
			kubectl_errors "$err" | tail -n 20 >&2
			return 1
		fi
		echo "warn: apply hiccup on $ctx (${label}), attempt ${attempt}/${APPLY_ATTEMPTS}; retrying in ${APPLY_BACKOFF_S}s (transient 429?): $(kubectl_errors "$err" | tail -n 1)" >&2
		attempt=$((attempt + 1))
		(( APPLY_BACKOFF_S > 0 )) && sleep "$APPLY_BACKOFF_S"
	done
}

# split_render <rendered_file> <workdir>: one awk pass splits the render into apply
# batches of APPLY_CHUNK_OBJECTS objects each: Namespace docs into ns_NNNNN.yaml,
# everything else into obj_NNNNN.yaml (every output file is close()d, so no awk keeps
# thousands of files open). Writes "<kind> <count>" lines and the batch counts to
# <workdir>/counts.
split_render() {
	local rendered="$1" workdir="$2" chunk="$APPLY_CHUNK_OBJECTS"
	(( chunk <= 0 )) && chunk=1000000000
	# SKIP_KINDS (CSV): kinds left out of every batch (the workloads part).
	awk -v dir="$workdir" -v chunk="$chunk" -v skip="$SKIP_KINDS" '
		BEGIN { ns = split(skip, sk, ","); for (i = 1; i <= ns; i++) if (sk[i] != "") SKIP[sk[i]] = 1 }
		function flush() {
			if (kind in SKIP) { buf = ""; kind = ""; return }
			if (buf ~ /[^[:space:]]/ && kind != "") {
				kinds[kind]++
				if (kind == "Namespace") {
					if (nsn % chunk == 0) { if (nsf != "") close(nsf); nsb++; nsf = sprintf("%s/ns_%05d.yaml", dir, nsb) }
					nsn++; printf "%s---\n", buf > nsf
				} else {
					if (objn % chunk == 0) { if (objf != "") close(objf); ob++; objf = sprintf("%s/obj_%05d.yaml", dir, ob) }
					objn++; printf "%s---\n", buf > objf
				}
			}
			buf = ""; kind = ""
		}
		/^---[[:space:]]*$/ { flush(); next }
		/^kind:[[:space:]]*[A-Za-z]+[[:space:]]*$/ { k = $0; sub(/^kind:[[:space:]]*/, "", k); sub(/[[:space:]]*$/, "", k); kind = k }
		{ buf = buf $0 "\n" }
		END {
			flush()
			if (nsf != "") close(nsf)
			if (objf != "") close(objf)
			out = dir "/counts"
			for (k in kinds) printf "kind %s %d\n", k, kinds[k] > out
			printf "batches %d %d %d %d\n", nsn + 0, nsb + 0, objn + 0, ob + 0 > out
			close(out)
		}
	' "$rendered"
}

# kind_count <workdir> <kind>: objects of that kind in the split render.
kind_count() {
	awk -v k="$2" '$1 == "kind" && $2 == k { print $3; f = 1 } END { if (!f) print 0 }' "$1/counts"
}

# apply_split <workdir> <ctx>: the Namespace batches first, then the other objects.
apply_split() {
	local workdir="$1" ctx="$2" f total_ns total_obj nb ob i=0
	read -r _ total_ns nb total_obj ob < <(grep '^batches ' "$workdir/counts")
	for f in "$workdir"/ns_*.yaml; do
		[[ -e "$f" ]] || continue
		i=$((i + 1))
		apply_with_retry "$f" "$ctx" "namespace batch ${i}/${nb} (${total_ns} namespaces)" || return 1
	done
	i=0
	for f in "$workdir"/obj_*.yaml; do
		[[ -e "$f" ]] || continue
		i=$((i + 1))
		apply_with_retry "$f" "$ctx" "object batch ${i}/${ob} (${total_obj} objects)" || return 1
	done
	return 0
}

# helm template arguments for this run.
HELM_ARGS=(
	--set namespace="$NS"
	--set image.tag="$BUSYBOX_VERSION"
	--set namespaceCount="$NAMESPACE_COUNT"
	--set serviceCount="$SERVICE_COUNT"
	--set replicasPerService="$REPLICAS"
	--set sidecarScoping="$SIDECAR_SCOPING"
	--set trafficConfig.mode="$TRAFFIC_CONFIG"
	--set trafficConfig.every="$VSDR_EVERY"
	--set trafficConfig.subsets="$VSDR_SUBSETS"
)
if ((GROWTH)); then
	HELM_ARGS+=(
		--set servicesPerNamespace="$SERVICES_PER_NAMESPACE"
		--set namespaceStart="$RENDER_START"
		--set-string series="$SERIES"
		--set workload.mode="$WORKLOAD_MODE"
		--set workload.measurementPods="$MEASUREMENT_PODS"
		--set-string workload.proxyMemoryLimit="$MEASUREMENT_PROXY_MEM_LIMIT"
		--set outside.count="$RENDER_OUTSIDE"
		--set outside.mode="$OUTSIDE_MODE"
		--set-string probe.name="$PROBE_NAME"
	)
fi
[[ -n "$SHOW_ONLY" ]] && HELM_ARGS+=(--show-only "$SHOW_ONLY")

# A growth-mode switch to scoping none and an outside part with mode none render
# nothing: the first deletes the series' Sidecars, the second is a no-op.
DELETE_SIDECARS=0
SKIP_APPLY=0
if ((GROWTH)) && [[ "$PARTS" == sidecars && "$SIDECAR_SCOPING" == none ]]; then
	DELETE_SIDECARS=1
elif ((GROWTH)) && [[ "$PARTS" == outside && "$OUTSIDE_MODE" == none ]]; then
	SKIP_APPLY=1
	echo "Outside mode none: nothing to apply."
fi

# Deployments the readiness wait expects (from the render); set per context below
# and identical across contexts.
EXPECTED_DEPLOYS_FILE="${WORKDIR_ROOT}/expected-deploys"
echo 0 > "$EXPECTED_DEPLOYS_FILE"

# Apply each context concurrently; any failure fails the join below.
APPLY_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	((SKIP_APPLY)) && break
	(
		ctx_dir="${WORKDIR_ROOT}/ctx-${#APPLY_PIDS[@]}"
		mkdir -p "$ctx_dir"
		t0="$(now_ms)"
		if ((DELETE_SIDECARS)); then
			echo "Switching series '${SERIES:-none}' to scoping none on $ctx: deleting its Sidecars (${SERIES_SIDECAR_SELECTOR})"
			if ((DRY_RUN)); then
				echo "  [dry-run] ${KUBECTL[*]} --context=$ctx delete sidecars.networking.istio.io -A -l '${SERIES_SIDECAR_SELECTOR}' --wait=true --timeout=${WAIT_TIMEOUT}s -v=4"
				exit 0
			fi
			if "${KUBECTL[@]}" --context="$ctx" delete sidecars.networking.istio.io -A -l "$SERIES_SIDECAR_SELECTOR" \
				--wait=true --timeout="${WAIT_TIMEOUT}s" -v=4 >"${ctx_dir}/out" 2>"${ctx_dir}/err"; then
				status=OK
			else
				status=FAILED
				kubectl_errors "${ctx_dir}/err" | tail -n 20 >&2
			fi
			count_throttle "${ctx_dir}/err"
			n=$(grep -c 'deleted' "${ctx_dir}/out" || true)
			echo "  [$ctx] deleted ${n:-0} Sidecar(s) (API 429s retried: ${API_429_RETRIED}, exhausted: ${API_429_EXHAUSTED})"
			secs=$(awk -v a="$t0" -v b="$(now_ms)" 'BEGIN { printf "%.1f", (b - a) / 1000 }')
			ns_lifecycle_row "$LIFECYCLE_FILE" "$ctx" "$SERIES" "$NAMESPACE_COUNT" "$ACTION" 0 "${n:-0}" "$secs" \
				"$API_429_RETRIED" "$API_429_EXHAUSTED" "$CLIENT_THROTTLE" "$status"
			[[ "$status" == OK ]] || exit 1
			exit 0
		fi
		echo "Setting up controlplane-test on context $ctx (part ${PARTS}, sidecar-scoping=${SIDECAR_SCOPING}, traffic-config=${TRAFFIC_CONFIG})"
		rendered="${ctx_dir}/rendered.yaml"
		helm template controlplane-test "$CHART_DIR" --set clusterName="$ctx" "${HELM_ARGS[@]}" > "$rendered" \
			|| { echo "error: helm template failed on $ctx" >&2; exit 1; }
		# Under a sweep, a chart file changed for this render reaches its outcome (harness_read).
		harness_read _hs _hk
		split_render "$rendered" "$ctx_dir"
		read -r _ n_ns nsb _ ob < <(grep '^batches ' "${ctx_dir}/counts")
		kind_count "$ctx_dir" Deployment > "$EXPECTED_DEPLOYS_FILE"
		echo "  [$ctx] render: $(awk '$1 == "kind"' "${ctx_dir}/counts" | sort -k2,2 | awk '{ printf "%s%s %s", sep, $3, $2; sep = ", " }') (${nsb} namespace batch(es), ${ob} object batch(es) of up to ${APPLY_CHUNK_OBJECTS})"
		if ((DRY_RUN)); then
			# Dry-run never touches the cluster: the render above already ran every chart
			# validation; print what the live run would do.
			echo "  [dry-run] ${apply[*]} --context=$ctx -f <batch> for each of the $((nsb + ob)) batch(es), namespaces first"
			exit 0
		fi
		if apply_split "$ctx_dir" "$ctx"; then status=OK; else status=FAILED; fi
		secs=$(awk -v a="$t0" -v b="$(now_ms)" 'BEGIN { printf "%.1f", (b - a) / 1000 }')
		echo "  [$ctx] applied ${APPLIED_OBJECTS} object(s) incl. ${n_ns} namespace(s) in ${secs}s (API 429s retried by client-go: ${API_429_RETRIED}, exhausted: ${API_429_EXHAUSTED}; client-side throttling waits: ${CLIENT_THROTTLE})"
		ns_lifecycle_row "$LIFECYCLE_FILE" "$ctx" "$SERIES" "$NAMESPACE_COUNT" "$ACTION" "$n_ns" "$APPLIED_OBJECTS" "$secs" \
			"$API_429_RETRIED" "$API_429_EXHAUSTED" "$CLIENT_THROTTLE" "$status"
		[[ "$status" == OK ]] || { echo "error: apply failed on $ctx" >&2; exit 1; }
	) &
	APPLY_PIDS+=($!)
done
for pid in "${APPLY_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed the controlplane-test apply"
done
EXPECTED_DEPLOYS="$(<"$EXPECTED_DEPLOYS_FILE")"

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

# One label-selector wait per context covers every dummy Deployment of the run;
# contexts are waited on concurrently. Skipped when the render has no Deployment
# (a config-only step past the measurement namespaces, a switch, outside, probe).
WAIT_SELECTOR="$BASE_SELECTOR"
((GROWTH)) && WAIT_SELECTOR="$SERIES_SELECTOR"
if ((EXPECTED_DEPLOYS > 0)); then
	echo "Waiting for ${EXPECTED_DEPLOYS} dummy deployment(s) per cluster to be ready (timeout: ${WAIT_TIMEOUT}s)..."
	WAIT_PIDS=()
	for ctx in "${CONTEXTS[@]}"; do
		(
			echo "  Waiting on context $ctx..."
			t0="$(now_ms)"
			if "${KUBECTL[@]}" --context="$ctx" wait --all-namespaces \
				--for=condition=Available deployment \
				-l "$WAIT_SELECTOR" \
				--timeout="${WAIT_TIMEOUT}s" >/dev/null; then
				status=OK
			else
				status=FAILED
			fi
			secs=$(awk -v a="$t0" -v b="$(now_ms)" 'BEGIN { printf "%.1f", (b - a) / 1000 }')
			ns_lifecycle_row "$LIFECYCLE_FILE" "$ctx" "$SERIES" "$NAMESPACE_COUNT" ready N/A "$EXPECTED_DEPLOYS" "$secs" N/A N/A N/A "$status"
			[[ "$status" == OK ]] || { echo "error: deployments ($WAIT_SELECTOR) on $ctx not Available within ${WAIT_TIMEOUT}s" >&2; exit 1; }
			echo "  All deployments ready on $ctx (${secs}s)."
		) &
		WAIT_PIDS+=($!)
	done
	for pid in "${WAIT_PIDS[@]}"; do
		wait "$pid" || die "one or more contexts failed deployment readiness check"
	done
else
	echo "No Deployment in this render; skipping the readiness wait."
fi

# sidecar_ns_counts <ctx> <selector> <expected_ns_file> <scope>: one Sidecar list, then
# a set difference: prints "<sidecars> <expected namespaces with one> <total sidecars
# in expected namespaces with the scope label <scope> (any when empty)>".
sidecar_ns_counts() {
	local ctx="$1" sel="$2" expected="$3" scope="$4" listing
	listing=$("${KUBECTL[@]}" --context="$ctx" get sidecars.networking.istio.io -A -l "$sel" -o json 2>/dev/null \
		| jq -r '.items[]? | [.metadata.namespace, (.metadata.labels["controlplane-test.scope"] // "")] | @tsv' 2>/dev/null) || listing=""
	awk -F'\t' -v scope="$scope" '
		NR == FNR { if ($1 != "") want[$1] = 1; next }
		$1 == "" { next }
		{ total++ }
		($1 in want) && (scope == "" || $2 == scope) { if (!($1 in got)) { got[$1] = 1; ns_with++ } }
		END { printf "%d %d\n", total, ns_with }' "$expected" <(printf '%s\n' "$listing")
}

# Verify the Sidecar CRs landed. Legacy: one per namespace (namespace/wide) or one
# per service (explicit), and at least one in every target namespace. Growth: every
# namespace this run scoped has a Sidecar with the scoping's label (none: no series
# Sidecar is left after a switch to none).
VERIFY_SIDECARS=0
EXPECTED_NS_FILE="${WORKDIR_ROOT}/sidecar-namespaces"
if ! ((GROWTH)); then
	[[ "$SIDECAR_SCOPING" != none && "$PARTS" != traffic ]] && VERIFY_SIDECARS=1
	printf '%s\n' "${NAMESPACES[@]}" > "$EXPECTED_NS_FILE"
	expected_sidecars="$NAMESPACE_COUNT"
	[[ "$SIDECAR_SCOPING" == explicit ]] && expected_sidecars="$SERVICE_COUNT"
	expected_ns="$NAMESPACE_COUNT"
	SC_SELECTOR="$BASE_SELECTOR"
	SC_SCOPE=""
elif [[ "$PARTS" == all || "$PARTS" == sidecars ]]; then
	VERIFY_SIDECARS=1
	sc_from=0
	[[ "$PARTS" == all ]] && sc_from="$NAMESPACE_START"
	: > "$EXPECTED_NS_FILE"
	for ((n = sc_from; n < NAMESPACE_COUNT; n++)); do echo "${NS_BASE}-${n}"; done >> "$EXPECTED_NS_FILE"
	expected_ns=$((NAMESPACE_COUNT - sc_from))
	expected_sidecars="$expected_ns"
	SC_SELECTOR="$SERIES_SIDECAR_SELECTOR"
	SC_SCOPE="$SIDECAR_SCOPING"
	if [[ "$SIDECAR_SCOPING" == none ]]; then
		expected_ns=0
		expected_sidecars=0
	fi
fi
if ((VERIFY_SIDECARS)); then
	echo "Verifying Sidecar CRs (sidecar-scoping=${SIDECAR_SCOPING}, expecting ${expected_sidecars} across ${expected_ns} namespace(s) per cluster)..."
	for ctx in "${CONTEXTS[@]}"; do
		deadline=$(( $(date +%s) + 30 ))
		count=0
		ns_with=0
		while :; do
			read -r count ns_with < <(sidecar_ns_counts "$ctx" "$SC_SELECTOR" "$EXPECTED_NS_FILE" "$SC_SCOPE")
			if [[ "$SIDECAR_SCOPING" == none ]]; then
				# Growth switch to none: the namespaces of this run hold no series Sidecar.
				(( ns_with == 0 )) && break
			else
				(( count >= expected_sidecars && ns_with == expected_ns )) && break
			fi
			(( $(date +%s) >= deadline )) && break
			sleep 1
		done
		if [[ "$SIDECAR_SCOPING" == none ]]; then
			(( ns_with == 0 )) || die "found Sidecars in $ns_with namespace(s) of series '${SERIES}' on $ctx after 30s (expected none for scoping none)"
			echo "  [$ctx] no series Sidecar left in the ${NAMESPACE_COUNT} namespace(s)"
		else
			(( count >= expected_sidecars && ns_with == expected_ns )) \
				|| die "found $count Sidecar CRs, ${ns_with}/${expected_ns} target namespace(s) covered${SC_SCOPE:+ with scope ${SC_SCOPE}}, on $ctx after 30s (expected $expected_sidecars for scoping=$SIDECAR_SCOPING)"
			echo "  [$ctx] Sidecar CRs: $count; ${ns_with}/${expected_ns} target namespace(s) covered"
		fi
	done
fi

# Verify the VirtualServices and DestinationRules landed: one of each per configured
# service. A shortfall dies, so a sweep records the combo as SETUP_FAILED instead of
# measuring a vsdr cell that is missing part of its config.
if [[ "$TRAFFIC_CONFIG" == vsdr && "$PARTS" != workloads ]]; then
	expected_vsdr="$(vsdr_service_count "$SERVICE_COUNT" "$VSDR_EVERY")"
	vsdr_selector="app.kubernetes.io/instance=controlplane-test,controlplane-test.traffic=vsdr"
	echo "Verifying VirtualServices and DestinationRules (expecting ${expected_vsdr} of each per cluster)..."
	for ctx in "${CONTEXTS[@]}"; do
		deadline=$(( $(date +%s) + VSDR_VERIFY_SEC ))
		n_vs=0
		n_dr=0
		while :; do
			n_vs=$("${KUBECTL[@]}" --context="$ctx" get virtualservices.networking.istio.io -A \
				-l "$vsdr_selector" -o name 2>/dev/null | grep -c .) || n_vs=0
			n_dr=$("${KUBECTL[@]}" --context="$ctx" get destinationrules.networking.istio.io -A \
				-l "$vsdr_selector" -o name 2>/dev/null | grep -c .) || n_dr=0
			(( n_vs >= expected_vsdr && n_dr >= expected_vsdr )) && break
			(( $(date +%s) >= deadline )) && break
			sleep 1
		done
		echo "  [$ctx] VirtualServices: ${n_vs}/${expected_vsdr}, DestinationRules: ${n_dr}/${expected_vsdr}"
		(( n_vs >= expected_vsdr && n_dr >= expected_vsdr )) \
			|| die "found ${n_vs} VirtualService(s) and ${n_dr} DestinationRule(s) on $ctx after ${VSDR_VERIFY_SEC}s (expected ${expected_vsdr} of each for --traffic-config vsdr --vsdr-every ${VSDR_EVERY})"
	done
fi

if ((GROWTH)); then
	echo "Setup complete. Series '${SERIES:-none}' part ${PARTS}: ${NAMESPACE_COUNT} namespace(s) x ${SERVICES_PER_NAMESPACE} service(s) (sidecar-scoping=${SIDECAR_SCOPING}, workload=${WORKLOAD_MODE}) on: ${CONTEXTS[*]}"
else
	echo "Setup complete (part ${PARTS}). ${SERVICE_COUNT} services × ${REPLICAS} replicas across ${NAMESPACE_COUNT} namespace(s) (sidecar-scoping=${SIDECAR_SCOPING}, traffic-config=${TRAFFIC_CONFIG}) on: ${CONTEXTS[*]}"
fi
