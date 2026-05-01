#!/usr/bin/env bash
# Install north–south ingress gateway per cluster using the upstream Istio Helm chart
# `istio/gateway` (version pinned to ISTIO_GATEWAY_CHART_VERSION / ISTIO_VERSION — see config/versions.env).
# Exposes Service `istio-system/istio-ingressgateway` (LoadBalancer: 80, 443, 15021) for mesh ingress traffic.
# OSSM 3.3 multi-cluster: labels gateways with `topology.istio.io/network` = `<cluster>-<NETWORK_SUFFIX>`.
#
# Doc alignment: Red Hat OSSM 3.3 — Multi-cluster topologies; gateways attach to the mesh network per cluster.
# Chart reference: https://github.com/istio/istio/tree/master/manifests/charts/gateway (published as istio/gateway).
#
# OpenShift: the chart defaults to pod sysctls (net.ipv4.ip_unprivileged_port_start) that SCC typically denies,
# which yields a Deployment with zero Ready replicas. We set platform=openshift and a minimal pod securityContext
# so Helm omits sysctl and omits fixed runAsUser 1337 on the gateway container (see chart deployment.yaml).
#
# IMPORTANT: do not use Helm value networkGateway= for this chart — it switches the Service to east-west ports only
# (no HTTP :80 / :443). Use labels + env for topology / ISTIO_META instead (see helm template gateway/service.yaml).
#
# AWS/ROSA: optional per-context AWS_LOAD_BALANCER_*_SECURITY_GROUPS annotate the LoadBalancer (VPC-scoped SGs).
# See config/ingress-lb-security-groups.map.example and config/versions.env.
#
# Requires: Helm 3, oc
# Usage (repo root):
#   ./istio-setup/004-ossm-mc-apply-ingress-gateway.sh [--contexts CSV] [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

HELM_REPO_URL="${ISTIO_HELM_REPO_URL:-https://istio-release.storage.googleapis.com/charts}"
INGRESS_CHART_VER="${ISTIO_GATEWAY_CHART_VERSION}"

SETUP_CONTEXTS="${SETUP_CONTEXTS:-rosa-001,rosa-002,rosa-003}"
CONTEXTS_CSV=""
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV   Comma-separated kube/oc context names (default: ${SETUP_CONTEXTS}).
  --dry-run        oc apply --dry-run=client only.

Environment:
  SETUP_CONTEXTS                      Same as --contexts when the flag is omitted.
  AWS_LOAD_BALANCER_SECURITY_GROUPS     Optional global comma-separated SG IDs (replace default LB SGs).
  AWS_LOAD_BALANCER_EXTRA_SECURITY_GROUPS Optional global extra SG IDs (additive).
  Per-context overrides (VPC-scoped SGs): config/ingress-lb-security-groups.map or env vars
  AWS_LOAD_BALANCER_SECURITY_GROUPS_<SUFFIX> / AWS_LOAD_BALANCER_EXTRA_SECURITY_GROUPS_<SUFFIX>
  where SUFFIX is the context name uppercased with / : - → _ (e.g. rosa-001 → ROSA_001).

Requires Helm 3 and oc.
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

CLUSTERS=()
IFS=',' read -ra _raw <<<"$CONTEXTS_CSV"
for c in "${_raw[@]}"; do
	c="${c#"${c%%[![:space:]]*}"}"
	c="${c%"${c##*[![:space:]]}"}"
	[[ -n "$c" ]] && CLUSTERS+=("$c")
done
((${#CLUSTERS[@]})) || die "no contexts parsed from: ${CONTEXTS_CSV}"

if ! command -v helm >/dev/null 2>&1; then
	echo "error: helm not found (install Helm 3)" >&2
	exit 2
fi

helm_repo_ensure() {
	helm repo add istio "${HELM_REPO_URL}" >/dev/null 2>&1 || true
	helm repo update >/dev/null 2>&1 || helm repo update
}

apply=(oc apply)
((DRY_RUN)) && apply=(oc apply --dry-run=client)

helm_repo_ensure

# Helm --set-string treats commas as list separators; AWS SG lists use commas — escape per Helm docs.
helm_escape_commas_for_set() {
	printf '%s' "$1" | sed 's/,/\\,/g'
}

# Normalize kube context name for env var suffix (rosa-001 → ROSA_001).
context_to_lb_sg_env_suffix() {
	printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '/:-' '___'
}

# Sentinel: map file used "-" to omit this annotation even if globals are set.
LB_SG_OMIT="__LB_SG_OMIT__"

declare -A LB_SG_REPLACE_MAP=()
declare -A LB_SG_EXTRA_MAP=()

load_lb_sg_map_file() {
	local f line ctx rep extra
	f="${ROOT}/config/ingress-lb-security-groups.map"
	[[ -f "$f" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line//[[:space:]]/}" ]] && continue
		IFS='|' read -r ctx rep extra <<<"$line"
		ctx="${ctx#"${ctx%%[![:space:]]*}"}"
		ctx="${ctx%"${ctx##*[![:space:]]}"}"
		[[ -z "$ctx" ]] && continue
		rep="${rep#"${rep%%[![:space:]]*}"}"
		rep="${rep%"${rep##*[![:space:]]}"}"
		extra="${extra#"${extra%%[![:space:]]*}"}"
		extra="${extra%"${extra##*[![:space:]]}"}"
		if [[ -n "$rep" ]]; then
			if [[ "$rep" == "-" ]]; then
				LB_SG_REPLACE_MAP["$ctx"]="$LB_SG_OMIT"
			else
				LB_SG_REPLACE_MAP["$ctx"]="$rep"
			fi
		fi
		if [[ -n "$extra" ]]; then
			if [[ "$extra" == "-" ]]; then
				LB_SG_EXTRA_MAP["$ctx"]="$LB_SG_OMIT"
			else
				LB_SG_EXTRA_MAP["$ctx"]="$extra"
			fi
		fi
	done <"$f"
}

resolve_lb_sg_replace_for_context() {
	local ctx="$1" suf envk v
	if [[ -n "${LB_SG_REPLACE_MAP[$ctx]+x}" ]]; then
		v="${LB_SG_REPLACE_MAP[$ctx]}"
		if [[ "$v" == "$LB_SG_OMIT" ]]; then
			printf ''
			return 0
		fi
		printf '%s' "$v"
		return 0
	fi
	suf="$(context_to_lb_sg_env_suffix "$ctx")"
	envk="AWS_LOAD_BALANCER_SECURITY_GROUPS_${suf}"
	if [[ -n "${!envk+x}" ]]; then
		printf '%s' "${!envk}"
		return 0
	fi
	printf '%s' "${AWS_LOAD_BALANCER_SECURITY_GROUPS:-}"
}

resolve_lb_sg_extra_for_context() {
	local ctx="$1" suf envk v
	if [[ -n "${LB_SG_EXTRA_MAP[$ctx]+x}" ]]; then
		v="${LB_SG_EXTRA_MAP[$ctx]}"
		if [[ "$v" == "$LB_SG_OMIT" ]]; then
			printf ''
			return 0
		fi
		printf '%s' "$v"
		return 0
	fi
	suf="$(context_to_lb_sg_env_suffix "$ctx")"
	envk="AWS_LOAD_BALANCER_EXTRA_SECURITY_GROUPS_${suf}"
	if [[ -n "${!envk+x}" ]]; then
		printf '%s' "${!envk}"
		return 0
	fi
	printf '%s' "${AWS_LOAD_BALANCER_EXTRA_SECURITY_GROUPS:-}"
}

build_helm_lb_annot_for_context() {
	local ctx="$1"
	local rep extra _sg
	HELM_LB_ANNOT=()
	rep="$(resolve_lb_sg_replace_for_context "$ctx")"
	extra="$(resolve_lb_sg_extra_for_context "$ctx")"
	if [[ -n "$rep" ]]; then
		_sg="$(helm_escape_commas_for_set "$rep")"
		HELM_LB_ANNOT+=(--set-string "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-security-groups=${_sg}")
	fi
	if [[ -n "$extra" ]]; then
		_sg="$(helm_escape_commas_for_set "$extra")"
		HELM_LB_ANNOT+=(--set-string "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-extra-security-groups=${_sg}")
	fi
	if ((${#HELM_LB_ANNOT[@]})); then
		echo "[$ctx] AWS LB Service annotations: ${#HELM_LB_ANNOT[@]} (per-context map/env or global)"
	fi
}

load_lb_sg_map_file

for ctx in "${CLUSTERS[@]}"; do
	build_helm_lb_annot_for_context "$ctx"
	export CLUSTER_KEY="$ctx"
	export NETWORK="${CLUSTER_KEY}-${NETWORK_SUFFIX}"
	echo "[$ctx] Helm istio/gateway ${INGRESS_CHART_VER} (topology network=${NETWORK})"
	helm template istio-ingressgateway istio/gateway \
		--version "${INGRESS_CHART_VER}" \
		--namespace istio-system \
		--set platform="${INGRESS_GATEWAY_PLATFORM:-openshift}" \
		--set securityContext.runAsNonRoot=true \
		--set-string "env.ISTIO_META_REQUESTED_NETWORK_VIEW=${NETWORK}" \
		--set labels.topology\\.istio\\.io/network="${NETWORK}" \
		--set service.type=LoadBalancer \
		"${HELM_LB_ANNOT[@]}" |
		"${apply[@]}" --context="$ctx" -f -
	if ((DRY_RUN)); then
		echo "[$ctx] dry-run: skipping rollout wait / svc get"
		echo ""
		continue
	fi
	echo "[$ctx] waiting for istio-ingressgateway rollout (timeout 10m)"
	if oc --context="$ctx" rollout status -n istio-system deploy/istio-ingressgateway --timeout=10m 2>/dev/null; then
		:
	else
		echo "[$ctx] warn: rollout wait failed — check: oc --context=$ctx -n istio-system get deploy,pods -l app=istio-ingressgateway"
	fi
	echo "[$ctx] istio-ingressgateway Service (LoadBalancer)"
	if ! oc --context="$ctx" get svc -n istio-system istio-ingressgateway -o wide 2>/dev/null; then
		echo "[$ctx] warn: could not get Service — check context/login"
	fi
	EXIP="$(oc --context="$ctx" get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
	if [[ -z "${EXIP}" ]]; then
		echo "[$ctx] note: EXTERNAL-IP pending until cloud LB provisions (normal on fresh ROSA)."
	fi
	echo ""
done
echo "Done."
