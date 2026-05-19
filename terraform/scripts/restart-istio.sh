#!/usr/bin/env bash
set -euo pipefail

# Restart the Istio control plane and data plane on one or more clusters.
# Useful after cacerts secrets are created/rotated so istiod picks up the
# plugged-in CA and all sidecars get new certificates.
#
# Usage:
#   restart-istio.sh [--kubeconfig PATH] [--prefix NAME --range START-END] [CONTEXT ...]
#
# Examples:
#   restart-istio.sh istio-001 istio-002
#   restart-istio.sh --prefix istio --range 001-002
#   restart-istio.sh --kubeconfig ~/.kube/config --prefix istio --range 001-050
#   restart-istio.sh --prefix istio --range 001-010 hub-001

KUBECONFIG_PATH=""
PREFIX=""
RANGE=""
CONTEXTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --range)
      RANGE="$2"
      shift 2
      ;;
    *)
      CONTEXTS+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$PREFIX" && -n "$RANGE" ]]; then
  IFS='-' read -r range_start range_end <<< "$RANGE"
  width=${#range_start}
  for (( i = 10#$range_start; i <= 10#$range_end; i++ )); do
    CONTEXTS+=("${PREFIX}-$(printf "%0${width}d" "$i")")
  done
fi

if [[ ${#CONTEXTS[@]} -eq 0 ]]; then
  echo "Usage: $0 [--kubeconfig PATH] [--prefix NAME --range START-END] [CONTEXT ...]" >&2
  exit 1
fi

kubectl_cmd() {
  local ctx="$1"; shift
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    kubectl --kubeconfig="$KUBECONFIG_PATH" --context="$ctx" "$@"
  else
    kubectl --context="$ctx" "$@"
  fi
}

for ctx in "${CONTEXTS[@]}"; do
  echo "=== $ctx: restarting istiod ==="
  kubectl_cmd "$ctx" rollout restart deployment/istiod -n istio-system
  kubectl_cmd "$ctx" rollout status deployment/istiod -n istio-system --timeout=120s

  echo "=== $ctx: restarting gateways ==="
  for deploy in istio-ingressgateway istio-eastwestgateway; do
    if kubectl_cmd "$ctx" get deployment/"$deploy" -n istio-system &>/dev/null; then
      kubectl_cmd "$ctx" rollout restart deployment/"$deploy" -n istio-system
      kubectl_cmd "$ctx" rollout status deployment/"$deploy" -n istio-system --timeout=120s
    fi
  done

  echo "=== $ctx: restarting injected workloads ==="
  namespaces=$(kubectl_cmd "$ctx" get namespaces -l istio.io/rev -o jsonpath='{.items[*].metadata.name}')
  for ns in $namespaces; do
    deployments=$(kubectl_cmd "$ctx" get deployments -n "$ns" -o jsonpath='{.items[*].metadata.name}')
    for dep in $deployments; do
      echo "  $ns/$dep"
      kubectl_cmd "$ctx" rollout restart deployment/"$dep" -n "$ns"
    done
  done

  echo "=== $ctx: done ==="
  echo
done
