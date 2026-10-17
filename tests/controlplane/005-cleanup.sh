#!/usr/bin/env bash
# Clean up all controlplane-test resources from target clusters.
#
# Deletes every namespace labelled app.kubernetes.io/instance=controlplane-test
# (the chart labels each namespace it creates, single or multi-namespace), plus
# the plain $CONTROLPLANE_TEST_NAMESPACE if present, then waits (bounded) for
# them to finish terminating. Growth mode (namespace scaling) adds:
#   --series ID   only the namespaces of one growth series;
#   --undiscover  take them out of istiod's view first (delete the measurement pods
#                 and the series' Sidecars, drop the istio-discovery and
#                 istio.io/rev labels); with --no-delete that is all it does, so
#                 thousands of namespaces leave the mesh in minutes without queueing
#                 thousands of namespace deletes;
#   --probe NAME  retire one probe namespace: delete its Services and Sidecar, drop
#                 its discovery labels, then delete the (now empty) namespace
#                 without waiting.
#
# Usage:
#   ./tests/controlplane/005-cleanup.sh [--config FILE] [--contexts CSV] [--dry-run]
#   ./tests/controlplane/005-cleanup.sh --series ID --undiscover --no-delete
#   ./tests/controlplane/005-cleanup.sh --probe NAME
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
source "${ROOT}/tests/lib/timestamp.sh"  # now_ms for the delete timings
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # tuning_baseline_state, ns_lifecycle_*

CONTEXTS_CSV=""
DRY_RUN=0
NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"
BASE_SELECTOR="app.kubernetes.io/instance=controlplane-test"
# Short grace period for deleting the workload pods first, so istio-proxy drain
# does not stretch the namespace teardown at scale.
FAST_DRAIN_GRACE_SEC="${CONTROLPLANE_CLEANUP_GRACE_SEC:-5}"
# Same bound 001 uses for its pre-apply namespace wait.
TERMINATION_TIMEOUT="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}"
SERIES=""
UNDISCOVER=0
NO_DELETE=0
NO_WAIT=0
PROBE_NAME=""
LIFECYCLE_FILE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/controlplane/README.md, "Run config"). Precedence: flag >
                     --config > environment > default.
  --contexts CSV     Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --grace-period SEC Grace period for deleting the workload pods before the
                     namespace delete (default: $FAST_DRAIN_GRACE_SEC).
  --timeout SEC      How long to wait for the namespaces to disappear (default:
                     CONTROLPLANE_NS_DELETE_TIMEOUT_SEC, $TERMINATION_TIMEOUT). At scale
                     allow about 1 s per namespace (OpenShift deletes namespaces at
                     roughly 0.3-1 per second); the deletion rate is printed.
  --series ID        Only the objects of growth series ID (label
                     controlplane-test.series=ID); the plain namespace is left alone.
  --undiscover       Before any delete, take the selected namespaces out of istiod's
                     view: delete their measurement Deployments and pods and their
                     test Sidecars, then remove the istio-discovery and istio.io/rev
                     labels. Needs discoverySelectors on the mesh (warns when the
                     live mesh has them off).
  --no-delete        With --undiscover: stop there and keep the namespaces (no
                     namespace delete is queued; delete them later, outside any
                     measurement window).
  --no-wait          Queue the namespace deletes without waiting for them.
  --probe NAME       Retire one probe namespace: delete its Services and Sidecar (and
                     wait for that), remove its discovery labels, then delete the
                     namespace without waiting. Not with --series/--undiscover.
  --lifecycle-file FILE
                     Append the delete timings and rates to this namespace-lifecycle
                     TSV (003 passes it).
  --dry-run          Print the delete commands without contacting any cluster.
  -h, --help         Show this help.

Behavior:
  Default: deletes the workload pods with a short grace period, then every namespace
  labelled '${BASE_SELECTOR}' plus '\$CONTROLPLANE_TEST_NAMESPACE' (default
  'controlplane-test'), and waits up to the timeout for them to disappear. A context
  that times out or cannot be reached fails.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_NS_DELETE_TIMEOUT_SEC
  (default 300), CONTROLPLANE_CLEANUP_GRACE_SEC (default 5).
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
	--grace-period)
		[[ -n "${2:-}" ]] || die "--grace-period requires a value"
		FAST_DRAIN_GRACE_SEC="$2"
		shift 2
		;;
	--timeout)
		[[ -n "${2:-}" ]] || die "--timeout requires a value"
		TERMINATION_TIMEOUT="$2"
		shift 2
		;;
	--series)
		[[ -n "${2:-}" ]] || die "--series requires a value"
		SERIES="$2"
		shift 2
		;;
	--undiscover)
		UNDISCOVER=1
		shift
		;;
	--no-delete)
		NO_DELETE=1
		shift
		;;
	--no-wait)
		NO_WAIT=1
		shift
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
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try --help)"
		;;
	esac
done

KUBECTL=()
resolve_kubectl KUBECTL

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_contexts "$CONTEXTS_CSV" CONTEXTS --contexts
else
	split_contexts "$SETUP_CONTEXTS" CONTEXTS SETUP_CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

is_pos_int "$TERMINATION_TIMEOUT" || die "--timeout / CONTROLPLANE_NS_DELETE_TIMEOUT_SEC must be a positive integer (got: $TERMINATION_TIMEOUT)"
# kubectl allows --grace-period=0 only with --force, so require >= 1.
is_pos_int "$FAST_DRAIN_GRACE_SEC" || die "--grace-period / CONTROLPLANE_CLEANUP_GRACE_SEC must be a positive integer (got: $FAST_DRAIN_GRACE_SEC)"
DNS_LABEL_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
[[ -z "$SERIES" || "$SERIES" =~ $DNS_LABEL_RE ]] || die "--series must be lowercase letters, digits and '-' (got: $SERIES)"
if ((NO_DELETE)) && ! ((UNDISCOVER)); then
	die "--no-delete needs --undiscover (without it there is nothing left to do)"
fi
if [[ -n "$PROBE_NAME" ]]; then
	[[ "$PROBE_NAME" =~ $DNS_LABEL_RE ]] || die "--probe must be a DNS label (got: $PROBE_NAME)"
	if [[ -n "$SERIES" ]] || ((UNDISCOVER)); then
		die "--probe retires one probe namespace; it does not combine with --series or --undiscover"
	fi
fi

LABEL_SELECTOR="$BASE_SELECTOR"
[[ -n "$SERIES" ]] && LABEL_SELECTOR="${BASE_SELECTOR},controlplane-test.series=${SERIES}"
# The plain namespace belongs to the legacy layout only.
INCLUDE_PLAIN_NS=1
[[ -n "$SERIES" ]] && INCLUDE_PLAIN_NS=0
# Sidecars, Deployments and pods of the selection that undiscover deletes (a probe
# namespace's Sidecar goes with --probe).
MODE="delete"
((UNDISCOVER)) && MODE="undiscover"
((UNDISCOVER)) && ! ((NO_DELETE)) && MODE="undiscover+delete"
[[ -n "$PROBE_NAME" ]] && MODE="probe"

echo "=== Control-plane test cleanup ==="
echo "Contexts:        ${CONTEXTS[*]}"
if [[ -n "$PROBE_NAME" ]]; then
	echo "Probe namespace: $PROBE_NAME"
else
	echo "Label selector:  $LABEL_SELECTOR"
	((INCLUDE_PLAIN_NS)) && echo "Namespace:       $NS"
fi
echo "Mode:            ${MODE}$( ((NO_WAIT)) && echo ' (no wait)')"
echo "Pod grace:       ${FAST_DRAIN_GRACE_SEC}s"
echo "Timeout:         ${TERMINATION_TIMEOUT}s"
((DRY_RUN)) && echo "Dry-run:         yes"
echo ""

if ((DRY_RUN)); then
	for ctx in "${CONTEXTS[@]}"; do
		k="${KUBECTL[*]} --context=$ctx"
		if [[ -n "$PROBE_NAME" ]]; then
			echo "  [dry-run] $k -n $PROBE_NAME delete services,sidecars.networking.istio.io -l $BASE_SELECTOR --wait=true --timeout=${TERMINATION_TIMEOUT}s"
			echo "  [dry-run] $k label namespace $PROBE_NAME istio-discovery- istio.io/rev-"
			echo "  [dry-run] $k delete namespace $PROBE_NAME --ignore-not-found=true --wait=false"
			continue
		fi
		if ((UNDISCOVER)); then
			echo "  [dry-run] read the live discoverySelectors (warn when off: unlabelling would not hide the namespaces)"
			echo "  [dry-run] $k delete deployments -A -l $LABEL_SELECTOR --wait=false"
			echo "  [dry-run] $k delete pods -A -l $LABEL_SELECTOR --grace-period=$FAST_DRAIN_GRACE_SEC --wait=false"
			echo "  [dry-run] $k delete sidecars.networking.istio.io -A -l $LABEL_SELECTOR --wait=false"
			echo "  [dry-run] $k label namespace -l $LABEL_SELECTOR istio-discovery- istio.io/rev-"
			if ((NO_DELETE)); then
				echo "  [dry-run] keep the namespaces (--no-delete): no namespace delete is queued"
				continue
			fi
		else
			echo "  [dry-run] $k delete pods -A -l $LABEL_SELECTOR --grace-period=$FAST_DRAIN_GRACE_SEC --wait=false"
		fi
		echo "  [dry-run] $k delete namespace -l $LABEL_SELECTOR --wait=false"
		((INCLUDE_PLAIN_NS)) && echo "  [dry-run] $k delete namespace $NS --ignore-not-found=true --wait=false"
		if ((NO_WAIT)); then
			echo "  [dry-run] do not wait for the namespaces to disappear (--no-wait)"
		else
			echo "  [dry-run] wait up to ${TERMINATION_TIMEOUT}s for those namespaces to disappear, then print the deletion rate"
			echo "  [dry-run] warn on any Sidecar, VirtualService or DestinationRule still labelled $LABEL_SELECTOR"
		fi
	done
	exit 0
fi

if [[ -n "$LIFECYCLE_FILE" ]]; then
	ns_lifecycle_init "$LIFECYCLE_FILE" "standalone-005"
fi

# count_lines <text>: non-empty lines.
count_lines() { grep -c . <<<"$1" || true; }

# remaining_ns <ctx>: the selected namespaces still present (names, one per line).
remaining_ns() {
	local ctx="$1" left
	left=$("${KUBECTL[@]}" --context="$ctx" get ns -l "$LABEL_SELECTOR" -o name 2>/dev/null || true)
	if ((INCLUDE_PLAIN_NS)) && [[ $'\n'"$left"$'\n' != *$'\n'"namespace/$NS"$'\n'* ]] \
		&& "${KUBECTL[@]}" --context="$ctx" get ns "$NS" -o name >/dev/null 2>&1; then
		left+=$'\n'"namespace/$NS"
	fi
	printf '%s' "$left"
}

# 0 when no selected namespace remains; 1 on timeout. One list call per poll.
wait_ns_terminated() {
	local ctx="$1" waited=0 left n
	while :; do
		left="$(remaining_ns "$ctx")"
		n="$(count_lines "$left")"
		(( n == 0 )) && return 0
		if (( waited >= TERMINATION_TIMEOUT )); then
			echo "  [$ctx] namespace termination timeout after ${TERMINATION_TIMEOUT}s: ${n} left, e.g. $(head -n 5 <<<"$left" | tr '\n' ' ')" >&2
			return 1
		fi
		sleep 2
		waited=$(( waited + 2 ))
	done
}

# secs_since <ms>: seconds since a now_ms stamp, one decimal.
secs_since() { awk -v a="$1" -v b="$(now_ms)" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }

PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		set -e
		if [[ -n "$PROBE_NAME" ]]; then
			echo "--- Retiring probe namespace $PROBE_NAME on $ctx ---"
			t0="$(now_ms)"
			status=OK
			# Explicit deletes first, so istiod processes them now rather than whenever the
			# namespace controller gets to them (inside the next window). The probe has no
			# pods; its OpenShift-created objects (service accounts, secrets, the
			# istio-ca-root-cert ConfigMap) go with the namespace after it leaves discovery.
			"${KUBECTL[@]}" --context="$ctx" -n "$PROBE_NAME" delete services,sidecars.networking.istio.io \
				-l "$BASE_SELECTOR" --ignore-not-found=true --wait=true --timeout="${TERMINATION_TIMEOUT}s" >/dev/null || status=FAILED
			"${KUBECTL[@]}" --context="$ctx" label namespace "$PROBE_NAME" istio-discovery- istio.io/rev- >/dev/null 2>&1 || true
			"${KUBECTL[@]}" --context="$ctx" delete namespace "$PROBE_NAME" --ignore-not-found=true --wait=false >/dev/null || status=FAILED
			secs="$(secs_since "$t0")"
			echo "  [$ctx] probe ${PROBE_NAME}: objects deleted, labels removed, namespace delete queued (${secs}s, ${status})"
			ns_lifecycle_row "$LIFECYCLE_FILE" "$ctx" none N/A probe-teardown 1 N/A "$secs" N/A N/A N/A "$status"
			[[ "$status" == OK ]] || exit 1
			exit 0
		fi

		echo "--- Cleaning up context: $ctx ---"
		# Reachability check: a failed get means the context is unusable.
		matches=$("${KUBECTL[@]}" --context="$ctx" get namespace -l "$LABEL_SELECTOR" -o name) \
			|| { echo "  [$ctx] error: cannot list namespaces" >&2; exit 1; }
		n_ns="$(count_lines "$matches")"
		echo "  [$ctx] ${n_ns} labelled namespace(s)"

		if ((UNDISCOVER)); then
			t0="$(now_ms)"
			status=OK
			# Without discoverySelectors istiod watches every namespace, so removing the
			# label hides nothing; only deleting the namespaces does.
			ds="unknown"
			while IFS= read -r kv; do
				[[ "$kv" == TUNING_BASELINE=* ]] && ds="$(sed -nE 's/.*discoverySelectors=([a-z]+).*/\1/p' <<<"$kv")"
			done < <(tuning_baseline_state "$ctx" "${KUBECTL[@]}")
			if [[ "$ds" != on ]]; then
				echo "  [$ctx] WARNING: discoverySelectors=${ds:-unknown} on the live mesh: removing the istio-discovery label may not hide these namespaces from istiod; only deleting them does." >&2
			fi
			# Measurement Deployments first (their pods would come back), then a fast pod
			# drain, then the series' Sidecars, then the labels.
			"${KUBECTL[@]}" --context="$ctx" delete deployments -A -l "$LABEL_SELECTOR" --wait=false >/dev/null 2>&1 || true
			"${KUBECTL[@]}" --context="$ctx" delete pods -A -l "$LABEL_SELECTOR" \
				--grace-period="$FAST_DRAIN_GRACE_SEC" --wait=false >/dev/null 2>&1 || true
			"${KUBECTL[@]}" --context="$ctx" delete sidecars.networking.istio.io -A -l "$LABEL_SELECTOR" --wait=false >/dev/null || status=FAILED
			if ((n_ns > 0)); then
				"${KUBECTL[@]}" --context="$ctx" label namespace -l "$LABEL_SELECTOR" istio-discovery- istio.io/rev- >/dev/null || status=FAILED
			fi
			secs="$(secs_since "$t0")"
			echo "  [$ctx] undiscovered ${n_ns} namespace(s) in ${secs}s (${status})"
			ns_lifecycle_row "$LIFECYCLE_FILE" "$ctx" "${SERIES:-none}" N/A undiscover "$n_ns" N/A "$secs" N/A N/A N/A "$status"
			[[ "$status" == OK ]] || exit 1
			if ((NO_DELETE)); then
				echo "  [$ctx] keeping the namespaces (--no-delete); delete them later with 005${SERIES:+ --series $SERIES}."
				exit 0
			fi
		elif [[ -n "$matches" ]]; then
			# Best-effort fast pod drain; the namespace delete below is authoritative.
			"${KUBECTL[@]}" --context="$ctx" delete pods -A -l "$LABEL_SELECTOR" \
				--grace-period="$FAST_DRAIN_GRACE_SEC" --wait=false >/dev/null 2>&1 || true
		fi

		t0="$(now_ms)"
		if [[ -n "$matches" ]]; then
			"${KUBECTL[@]}" --context="$ctx" delete namespace -l "$LABEL_SELECTOR" --ignore-not-found=true --wait=false >/dev/null
		else
			echo "  [$ctx] No labelled namespaces found."
		fi
		# The plain namespace, only if the labelled delete did not already cover it.
		if ((INCLUDE_PLAIN_NS)) && [[ $'\n'"$matches"$'\n' != *$'\n'"namespace/$NS"$'\n'* ]]; then
			if "${KUBECTL[@]}" --context="$ctx" get namespace "$NS" -o name >/dev/null 2>&1; then
				n_ns=$((n_ns + 1))
			fi
			"${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true --wait=false
		fi

		if ((NO_WAIT)); then
			echo "  [$ctx] ${n_ns} namespace delete(s) queued; not waiting (--no-wait)."
			ns_lifecycle_row "$LIFECYCLE_FILE" "$ctx" "${SERIES:-none}" N/A delete-queued "$n_ns" N/A "$(secs_since "$t0")" N/A N/A N/A OK
			exit 0
		fi
		echo "  [$ctx] Waiting for namespace termination (timeout ${TERMINATION_TIMEOUT}s)..."
		if wait_ns_terminated "$ctx"; then status=OK; else status=CLEANUP_TIMEOUT; fi
		secs="$(secs_since "$t0")"
		rate="$(awk -v n="$n_ns" -v s="$secs" 'BEGIN { if (s + 0 > 0) printf "%.2f", n / s; else print "N/A" }')"
		echo "  [$ctx] deleted ${n_ns} namespace(s) in ${secs}s (${rate} namespaces/s; ${status})"
		ns_lifecycle_row "$LIFECYCLE_FILE" "$ctx" "${SERIES:-none}" N/A delete "$n_ns" N/A "$secs" N/A N/A N/A "$status"
		[[ "$status" == OK ]] || exit 1
		# Sidecar CRs are namespaced; warn if any survived outside the deleted namespaces.
		sc_left=$("${KUBECTL[@]}" --context="$ctx" get sidecars.networking.istio.io \
			-A -l "$LABEL_SELECTOR" --no-headers --ignore-not-found 2>/dev/null | wc -l | tr -d ' ')
		[[ -z "$sc_left" ]] && sc_left=0
		if (( sc_left > 0 )); then
			echo "  [$ctx] WARNING: ${sc_left} Sidecar CR(s) still present" >&2
		fi
		# Same for the --traffic-config vsdr VirtualServices/DestinationRules.
		vsdr_left=$("${KUBECTL[@]}" --context="$ctx" get \
			virtualservices.networking.istio.io,destinationrules.networking.istio.io \
			-A -l "$LABEL_SELECTOR" --no-headers --ignore-not-found 2>/dev/null | wc -l | tr -d ' ')
		[[ -z "$vsdr_left" ]] && vsdr_left=0
		if (( vsdr_left > 0 )); then
			echo "  [$ctx] WARNING: ${vsdr_left} VirtualService/DestinationRule(s) still present" >&2
		fi
		echo "  [$ctx] Done."
	) &
	PIDS+=($!)
done

FAILED=0
for pid in "${PIDS[@]}"; do
	wait "$pid" || FAILED=$((FAILED + 1))
done

echo ""
if ((FAILED > 0)); then
	echo "Cleanup finished with $FAILED failed context(s)."
	exit 1
fi
echo "Cleanup complete."
