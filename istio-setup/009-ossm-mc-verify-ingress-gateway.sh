#!/usr/bin/env bash
# Deploy a minimal echo workload + Gateway / VirtualService and curl the ingress LoadBalancer
# to confirm north–south traffic through istio-system/istio-ingressgateway.
#
# Manifests: manifests/ossm-multi-cluster/ingress-verify/ingress-verify.yaml
#
# Requires: oc, curl
# Usage (repo root):
#   ./istio-setup/009-ossm-mc-verify-ingress-gateway.sh [--contexts CSV] [--dry-run] [--cleanup]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

MANIFEST="${ROOT}/manifests/ossm-multi-cluster/ingress-verify/ingress-verify.yaml"
SETUP_CONTEXTS="${SETUP_CONTEXTS:-rosa-001,rosa-002,rosa-003}"
CONTEXTS_CSV=""
DRY_RUN=0
CLEANUP=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV   Comma-separated kube/oc context names (default: ${SETUP_CONTEXTS}).
  --dry-run        Print actions only; apply uses oc apply --dry-run=client where applicable.
  --cleanup        After a successful HTTP check on a context, delete namespace ingress-verify there.

Environment:
  SETUP_CONTEXTS   Default for --contexts when omitted.

Requires istio-system/istio-ingressgateway (istio-setup/004) and curl on PATH.

If checks fail: namespace must label sidecar injection (istio.io/rev) — see manifest comments;
mesh STRICT mTLS requires a proxy on the workload pod (2/2 Ready).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--cleanup)
		CLEANUP=1
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

[[ -z "$CONTEXTS_CSV" ]] && CONTEXTS_CSV="$SETUP_CONTEXTS"

if [[ ! -f "$MANIFEST" ]]; then
	die "missing ${MANIFEST}"
fi

if ! command -v curl >/dev/null 2>&1; then
	die "curl not found on PATH"
fi

CLUSTERS=()
IFS=',' read -ra _raw <<<"$CONTEXTS_CSV"
for c in "${_raw[@]}"; do
	c="${c#"${c%%[![:space:]]*}"}"
	c="${c%"${c##*[![:space:]]}"}"
	[[ -n "$c" ]] && CLUSTERS+=("$c")
done
((${#CLUSTERS[@]})) || die "no contexts parsed from: ${CONTEXTS_CSV}"

diagnose_ingress() {
	local ctx=$1
	echo "--- [${ctx}] ingress-verify Pod (expect istio-proxy + echo if injection works) ---"
	oc --context="$ctx" get pods -n ingress-verify -o wide 2>/dev/null || true
	echo "--- [${ctx}] describe pod (events) ---"
	oc --context="$ctx" describe pod -n ingress-verify -l app=ingress-verify-echo 2>/dev/null | tail -40 || true
	echo "--- [${ctx}] Gateway / VirtualService ---"
	oc --context="$ctx" get gateway,virtualservice -n ingress-verify 2>/dev/null || true
	echo "--- [${ctx}] istio-ingressgateway endpoints ---"
	oc --context="$ctx" get endpoints -n istio-system istio-ingressgateway -o wide 2>/dev/null || true
}

apply=(oc apply)
((DRY_RUN)) && apply=(oc apply --dry-run=client)

for ctx in "${CLUSTERS[@]}"; do
	echo "==================== ${ctx} ===================="
	echo "[${ctx}] applying ingress-verify manifests"
	"${apply[@]}" --context="$ctx" -f "$MANIFEST"
	if ((DRY_RUN)); then
		echo "[${ctx}] dry-run: skipping wait / curl"
		echo ""
		continue
	fi
	echo "[${ctx}] waiting for rollout"
	if ! oc --context="$ctx" rollout status deploy/ingress-verify-echo -n ingress-verify --timeout=240s 2>/dev/null; then
		echo "[${ctx}] warn: rollout failed or deploy missing"
		diagnose_ingress "$ctx"
		echo ""
		continue
	fi
	HOST=""
	HOST=$(oc --context="$ctx" get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
	if [[ -z "$HOST" ]]; then
		HOST=$(oc --context="$ctx" get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
	fi
	if [[ -z "$HOST" ]]; then
		echo "[${ctx}] error: istio-ingressgateway has no EXTERNAL hostname/ip yet — rerun after LB provisions."
		diagnose_ingress "$ctx"
		echo ""
		continue
	fi

	# Confirm workload has sidecar when mesh expects mTLS (common failure without istio.io/rev on namespace).
	n_containers="$(oc --context="$ctx" get pod -n ingress-verify -l app=ingress-verify-echo -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null | wc -w | tr -d '[:space:]')"
	if [[ "${n_containers:-0}" -lt 2 ]]; then
		echo "[${ctx}] warn: pod has ${n_containers:-0} container(s); expected 2+ with istio-proxy — check namespace labels istio.io/rev (OSSM/Sail) and re-apply this manifest."
		diagnose_ingress "$ctx"
	fi

	echo "[${ctx}] curling http://${HOST}/ (via ingress; IPv4; permissive Host)"
	# NLB/DNS: force IPv4; some meshes need an explicit Host header for "*" routing
	out=""
	exit_c=0
	out=$(curl -4fsS --max-time 25 -H 'Host: ingress-verify.local' "http://${HOST}/" 2>/dev/null) || exit_c=$?
	if [[ "$exit_c" != "0" ]] || ! echo "$out" | grep -q 'ingress-ok'; then
		out=$(curl -4fsS --max-time 25 "http://${HOST}/" 2>/dev/null) || exit_c=$?
	fi

	if [[ "$exit_c" == "0" ]] && echo "$out" | grep -q 'ingress-ok'; then
		echo "[${ctx}] OK: response contains ingress-ok"
		if ((CLEANUP)); then
			echo "[${ctx}] cleanup: deleting namespace ingress-verify"
			oc --context="$ctx" delete namespace ingress-verify --wait=false 2>/dev/null || true
		fi
	else
		echo "[${ctx}] FAIL: curl did not return body containing ingress-ok (exit=${exit_c:-?})."
		echo "[${ctx}] Last response snippet: ${out:0:300}"
		diagnose_ingress "$ctx"
	fi
	echo ""
done

echo "Done."
