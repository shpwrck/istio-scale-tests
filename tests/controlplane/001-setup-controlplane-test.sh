#!/usr/bin/env bash
# Deploy dummy workloads for measuring istiod control-plane resource consumption.
#
# Applies one sweep point to each target cluster: SERVICE_COUNT services x
# REPLICAS pods across NAMESPACE_COUNT namespaces (service i lands in namespace
# i mod N). One namespace is named ${NS}; more are ${NS}-0 .. ${NS}-(N-1).
# Manifests are applied server-side, in chunks, with a bounded retry.
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
# ci-dry-run-skip: needs valid kubeconfig context for kubectl apply --dry-run=client
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # SCALE_* knobs
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # read-only capacity probes

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT=300
NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNT="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
SIDECAR_SCOPING="${CONTROLPLANE_SIDECAR_SCOPING:-none}"
# A namespace still Terminating from the previous combo cannot be re-created, so
# wait for every target namespace to disappear before applying (same bound 005
# uses for its own termination wait).
SETUP_NS_WAIT_SEC="${CONTROLPLANE_SETUP_NS_WAIT_SEC:-${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}}"
# Bounded retry so a transient apiserver 429 does not fail the combo, and
# chunked apply so a large explicit-scoping render is not one huge stream.
APPLY_ATTEMPTS="${CONTROLPLANE_APPLY_ATTEMPTS:-3}"
APPLY_BACKOFF_S="${CONTROLPLANE_APPLY_BACKOFF_S:-5}"
# Objects per apply batch; Namespace docs always go first. <= 0 disables chunking.
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
                         namespace - one Sidecar per workload namespace.
                         explicit  - one Sidecar per Deployment with workloadSelector.
  --dry-run              Pass --dry-run=client to oc apply
                         (skips the --server-side path).
  --wait-timeout N       Seconds to wait for pods (default: 300).
  --ns-wait-timeout N    Seconds to wait for a pre-existing (Terminating) namespace
                         to disappear before applying (default: $SETUP_NS_WAIT_SEC;
                         skipped in --dry-run).
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_SERVICE_COUNT,
  CONTROLPLANE_REPLICAS_PER_SERVICE, CONTROLPLANE_NAMESPACE_COUNT,
  CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_SETUP_NS_WAIT_SEC (default: CONTROLPLANE_NS_DELETE_TIMEOUT_SEC, then 300),
  CONTROLPLANE_APPLY_ATTEMPTS / CONTROLPLANE_APPLY_BACKOFF_S (apply retry, default 3 / 5s),
  CONTROLPLANE_APPLY_CHUNK_OBJECTS (objects per apply batch, default 200; <=0 disables),
  BUSYBOX_VERSION (dummy workload image tag).

  Scale coverage (off by default): SCALE_SIZING_MODE (fixed|auto; auto derives the
  service count from cluster capacity), SCALE_TARGET_FRACTION,
  SCALE_SYSTEM_RESERVE_FRACTION, SCALE_PER_POD_CPU_M, SCALE_PER_POD_MEM_MI,
  SCALE_COVERAGE_MIN_FRACTION, SCALE_COVERAGE_ENFORCE (1 = fail when under-provisioned).
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

# Namespaces the chart creates (mirrors chart/templates/_helpers.tpl).
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
[[ "$SCALE_SIZING_MODE" == auto ]] && echo "Sizing mode:     auto (capacity-derived SERVICE_COUNT)"
echo ""

# Capacity-derived sizing, only with SCALE_SIZING_MODE=auto and never in --dry-run.
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

# Sidecar egress-coverage precondition. With NAMESPACE_COUNT > 1 the suite creates
# ${NS}-0, ${NS}-1, ... but the root Sidecar's egress hosts match namespaces exactly
# ("controlplane-test/*" does not cover "controlplane-test-0/*"), so with scoping
# `none` each proxy would silently see only its own namespace. Fail fast instead.
# `namespace`/`explicit` scoping deploys its own Sidecar for every workload, which
# replaces the root Sidecar, so the check does not apply. Read-only, live-queried,
# skipped in --dry-run.
if ! ((DRY_RUN)) && ((NAMESPACE_COUNT > 1)) && [[ "$SIDECAR_SCOPING" == none ]]; then
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
			die "context $ctx: the deployed root Sidecar egress allow-list does NOT cover these controlplane-test namespaces: ${missing[*]}. egressHosts namespace parts are EXACT matches (\"controlplane-test/*\" does NOT cover \"controlplane-test-0/*\"). Add an explicit \"<ns>/*\" entry for each to charts/spoke-ossm/values.yaml tuningBaseline.sidecar.egressHosts (and re-sync the mesh), or run with --namespace-count 1 or --sidecar-scoping namespace|explicit. Current egress hosts: ${hosts}"
		fi
		echo "  $ctx: all $NAMESPACE_COUNT generated namespaces covered by the Sidecar egress allow-list — OK"
	done
	echo ""
fi

# Capacity preflight: die if a cluster lacks pod slots for the planned workload.
# Under SCALE_SIZING_MODE=auto also warn on under-provision (fail only when
# SCALE_COVERAGE_ENFORCE=1).
if ! ((DRY_RUN)); then
	NEEDED_PODS=$((SERVICE_COUNT * REPLICAS))
	echo "Capacity preflight ($NEEDED_PODS pods needed per cluster)..."
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
				die "context $ctx: need $NEEDED_PODS pods (${SERVICE_COUNT} svc × ${REPLICAS} replicas) but only $remaining slots available ($alloc allocatable − $current non-terminal pods). Reduce --service-count or --replicas, or add nodes."
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
	done
	echo ""
fi

# Wait until no target namespace is Terminating on this context (an Active one is
# re-applied in place); return 1 if one is still Terminating after SETUP_NS_WAIT_SEC
# (the apply would fail anyway).
ns_terminating() {
	local phase
	phase=$("${KUBECTL[@]}" --context="$1" get namespace "$2" -o jsonpath='{.status.phase}' 2>/dev/null) || return 1
	[[ "$phase" == Terminating ]]
}
wait_ns_gone() {
	local ctx="$1" ns deadline now
	for ns in "${NAMESPACES[@]}"; do
		if ! ns_terminating "$ctx" "$ns"; then
			"${KUBECTL[@]}" --context="$ctx" get namespace "$ns" >/dev/null 2>&1 \
				&& echo "  [$ctx] note: namespace $ns already exists; applying in place (run 005 first for a clean start)" >&2
			continue
		fi
		echo "  [$ctx] namespace $ns is Terminating; waiting up to ${SETUP_NS_WAIT_SEC}s for it to clear before apply..." >&2
		deadline=$(( $(date +%s) + SETUP_NS_WAIT_SEC ))
		while ns_terminating "$ctx" "$ns"; do
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

# Apply a manifest with a bounded retry. <manifest_file> <ctx> <label>.
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

# Split a rendered stream into one file per object, apply the Namespace docs
# first, then the rest in batches of APPLY_CHUNK_OBJECTS (each with retry).
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
		# Separate the docs: a bare concatenation merges them into one YAML doc
		# (only the last Namespace would be created).
		: > "$workdir/_batch_ns.yaml"
		for f in "${ns_docs[@]}"; do
			cat "$f" >> "$workdir/_batch_ns.yaml"
			printf -- '---\n' >> "$workdir/_batch_ns.yaml"
		done
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

# Apply each context concurrently; any failure fails the join below.
APPLY_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "Setting up controlplane-test on context $ctx (${SERVICE_COUNT} services × ${REPLICAS} replicas across ${NAMESPACE_COUNT} namespace(s), sidecar-scoping=${SIDECAR_SCOPING})"
		rendered="$(mktemp)"
		workdir="$(mktemp -d)"
		trap 'rm -rf "$workdir" "$rendered"' EXIT
		helm template controlplane-test "$CHART_DIR" \
			--set clusterName="$ctx" \
			--set namespace="$NS" \
			--set image.tag="$BUSYBOX_VERSION" \
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

# One label-selector wait per namespace covers every dummy Deployment in it;
# contexts are waited on concurrently.
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

# Verify the Sidecar CRs landed: one per namespace (namespace) or one per
# service (explicit), and at least one in every target namespace.
if [[ "$SIDECAR_SCOPING" != "none" ]]; then
	expected_sidecars="$NAMESPACE_COUNT"
	[[ "$SIDECAR_SCOPING" == explicit ]] && expected_sidecars="$SERVICE_COUNT"
	echo "Verifying Sidecar CRs (sidecar-scoping=${SIDECAR_SCOPING}, expecting ${expected_sidecars} per cluster across ${NAMESPACE_COUNT} namespace(s))..."
	for ctx in "${CONTEXTS[@]}"; do
		deadline=$(( $(date +%s) + 30 ))
		count=0
		ns_with=0
		while :; do
			# One line per labelled Sidecar: its namespace.
			sc_ns=$("${KUBECTL[@]}" --context="$ctx" get sidecars.networking.istio.io -A \
				-l app.kubernetes.io/instance=controlplane-test \
				-o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null) || sc_ns=""
			count=$(grep -c . <<<"$sc_ns" || true)
			ns_with=0
			for svc_ns in "${NAMESPACES[@]}"; do
				grep -qxF "$svc_ns" <<<"$sc_ns" && ns_with=$((ns_with + 1))
			done
			(( count >= expected_sidecars && ns_with == NAMESPACE_COUNT )) && break
			(( $(date +%s) >= deadline )) && break
			sleep 1
		done
		(( count >= expected_sidecars && ns_with == NAMESPACE_COUNT )) \
			|| die "found $count Sidecar CRs in $ns_with/$NAMESPACE_COUNT namespace(s) on $ctx after 30s (expected $expected_sidecars across all ${NAMESPACE_COUNT} for scoping=$SIDECAR_SCOPING)"
		echo "  [$ctx] Sidecar CRs: $count in $ns_with/$NAMESPACE_COUNT namespace(s)"
	done
fi

echo "Setup complete. ${SERVICE_COUNT} services × ${REPLICAS} replicas across ${NAMESPACE_COUNT} namespace(s) (sidecar-scoping=${SIDECAR_SCOPING}) on: ${CONTEXTS[*]}"
