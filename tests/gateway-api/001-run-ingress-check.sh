#!/usr/bin/env bash
# Gateway API multicluster ingress check. Read-only: it deploys and changes nothing.
#
# Question: in this multi-primary, multi-network mesh, does an HTTPRoute need its backend
# Service in every member, or does a request entering ANY member's ingress reach the workload
# wherever it runs? And does the ingress member need the backend's NAMESPACE (S7-S9: a backend
# namespace that exists on the workload member only)? charts/mesh-verify-gateway-api, deployed by
# GitOps through charts/mesh-verify-gateway-api-appset.yaml, puts the routes on every member and
# the echo workload on one. This script reads what each member resolved, sends traffic through
# every member's ingress, and writes one TSV plus a markdown summary that leads with the answers.
# Scenarios, predictions and how to read the report: tests/gateway-api/README.md.
#
# Steps: (1) preflight: live Gateway API state per member, into the TSV preamble; stops when the
# check is not deployed. (2) A bounded wait for the Gateway, the echo Deployment and every route's
# status. (3) GWAPI_REQUESTS requests per member ingress x scenario host. (4) Optional endpoint
# evidence (istioctl) and (5) Argo CD health (--hub-context); both are best effort. (6) The TSV
# and the summary under <results-dir>/run-<RUN_ID>/.
#
# Usage:
#   ./tests/gateway-api/001-run-ingress-check.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
#     --workload-context <mesh-b-ctx> [--hub-context <acm-hub-ctx>] [--dry-run]
#   ./tests/gateway-api/001-run-ingress-check.sh --config tests/gateway-api/configs/smoke.env \
#     --contexts <mesh-a-ctx>,<mesh-b-ctx> --workload-context <mesh-b-ctx>
# ci-dry-run: --contexts ci-a,ci-b --workload-context ci-b
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload gateway-api "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# reach_sanitize: masks IPs and hostnames in the response text this script records.
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"

CONTEXTS_CSV="${SETUP_CONTEXTS}"
WORKLOAD_CTX="${GWAPI_WORKLOAD_CONTEXT}"
HUB_CTX="${GWAPI_HUB_CONTEXT}"
INGRESS_CSV="${GWAPI_INGRESS}"
REQUESTS="${GWAPI_REQUESTS}"
TIMEOUT_SEC="${GWAPI_TIMEOUT_SEC}"
WAIT_TIMEOUT_SEC="${GWAPI_WAIT_TIMEOUT_SEC}"
RESULTS_DIR="$(config_repo_path "${GWAPI_RESULTS_DIR}")"
SKIP_PROXY_CONFIG="${GWAPI_SKIP_PROXY_CONFIG}"
NS="${GWAPI_NAMESPACE}"
NS_REMOTE="${GWAPI_REMOTE_NAMESPACE}"
GW_NAME="${GWAPI_GATEWAY}"
DRY_RUN=0
INGRESS_FROM_FLAG=0

# Fixed by the charts: the ingress gateway (charts/spoke-ingress-gateway), the echo label and
# Service port (charts/mesh-verify-gateway-api), istiod's Gateway API controller name and DNS
# domain suffix (chart value clusterDomain).
INGRESS_DEPLOY=istio-ingressgateway
ECHO_SELECTOR=app=gwapi-echo
SVC_PORT=8080
GW_CONTROLLER=istio.io/gateway-controller
CLUSTER_DOMAIN=cluster.local
# Seconds between status polls in the wait (step 2); the wait's bound is --wait-timeout.
POLL_SEC=5
GWAPI_SCHEMA=1

# Predicted outcomes (tests/gateway-api/README.md, "Predictions"), one row per scenario:
#   id|kind|host|route|backend kind|backend Service|backend namespace|status via W|status via O|
#   HTTP via W|HTTP via O|endpoints via W|endpoints via O|confidence|why
# W = the workload member, O = every other member; "via X" = on X / through X's ingress. Backend
# namespace: main (GWAPI_NAMESPACE, on every member; every route lives there) or remote
# (GWAPI_REMOTE_NAMESPACE, on W only: the "is a local namespace needed?" scenarios). Status
# is the HTTPRoute's Accepted/ResolvedRefs from istio.io/gateway-controller ("present" = the
# classic VirtualService exists, "absent" = no route on that member). Endpoints: the ingress's EDS
# endpoints for the backend: local-pod, remote-ewgw:15443 (the workload member's east-west
# gateway) or none; "-" = not judged. Every expected 200 must carry the workload's echo text.
# The chart (charts/mesh-verify-gateway-api/templates/_helpers.tpl) has the same ids, hosts,
# routes and backends; tests/lib/test/gateway-api.bats checks that they agree.
ST_OK="Accepted=True/ResolvedRefs=True"
ST_BNF="Accepted=True/ResolvedRefs=False:BackendNotFound"
ST_RNP="Accepted=True/ResolvedRefs=False:RefNotPermitted"
EP_LOCAL=local-pod
EP_REMOTE="remote-ewgw:15443"
SCENARIOS=(
	"S1|classic|s1.classic.test|s1|Service|echo-s1|main|present|present|200|200|${EP_LOCAL}|${EP_REMOTE}|high|classic Gateway + VirtualService: nothing checks that the Service exists"
	"S2|httproute|s2.gwapi.test|s2|Service|echo-s2|main|${ST_OK}|${ST_BNF}|200|200|${EP_LOCAL}|${EP_REMOTE}|high|BackendNotFound is a soft error: the destination is still programmed and resolved against every member's Services"
	"S3|httproute|s3.gwapi.test|s3|Service|echo-s3|main|${ST_OK}|${ST_OK}|200|200|${EP_LOCAL}|${EP_REMOTE}|high|the stub Service resolves the status and adds no endpoints"
	"S4|httproute|s4.gwapi.test|s4|Hostname|echo-s4|main|${ST_OK}|${ST_OK}|200|200|${EP_LOCAL}|${EP_REMOTE}|medium-high|the Hostname lookup uses the merged registry; it reads BackendNotFound until istiod's first push"
	"S5|httproute|s5.gwapi.test|s5|ServiceImport|echo-s5|main|${ST_OK}|${ST_BNF}|200|200|${EP_LOCAL}|${EP_REMOTE}|high|with ENABLE_MCS_HOST=false (default) a ServiceImport is handled exactly like kind Service"
	"S7|httproute|s7.gwapi.test|s7|Service|echo-s7|remote|${ST_OK}|${ST_RNP}|200|500|${EP_LOCAL}|${EP_REMOTE}|high|istiod reads ReferenceGrants from its own cluster only, and a grant can only live in the backend's namespace: without one the backendRef gets an empty destination (cluster UnknownService) and Gateway API's 500. The ingress still holds the backend's cluster with the workload member's east-west endpoint, so the 500 is the route's"
	"S8|httproute|s8.gwapi.test|s8|Hostname|echo-s8|remote|${ST_BNF}|${ST_BNF}|200|200|${EP_LOCAL}|${EP_REMOTE}|medium-high|a Hostname backendRef has no namespace, so no grant check; its status lookup is keyed by the route's namespace, so it reads BackendNotFound on every member (istio/istio#62027), but the destination is still programmed"
	"S9|classic|s9.classic.test|s9|Service|echo-s9|remote|present|present|200|200|${EP_LOCAL}|${EP_REMOTE}|high|a classic VirtualService may name any host: no namespace or grant check"
	"C1|httproute|neg.gwapi.test|c1|Service|echo-none|main|${ST_BNF}|${ST_BNF}|500|500|none|none|high|negative control: no Service anywhere, so no Envoy cluster, and Gateway API routes answer 500"
	"C2|httproute|s6.gwapi.test|c2|Service|echo-s2|main|${ST_OK}|absent|200|404|${EP_LOCAL}|-|medium-high|route on the workload member only: routing config is per cluster, so the others answer 404"
)

usage() {
	cat <<EOF
Usage: $(basename "$0") --contexts CSV --workload-context CTX [options]

Gateway API multicluster ingress check (read-only). Answers: does an HTTPRoute need its backend
Service in every member, or does a request entering any member's ingress reach the workload? And
does the ingress member need the backend's namespace?
Deploy the check first (charts/mesh-verify-gateway-api-appset.yaml; tests/gateway-api/README.md).

  --config FILE           Run config of KEY=value lines (SETUP_CONTEXTS and the GWAPI_* keys of
                          config/options.env; tests/gateway-api/README.md, "Run config").
                          Precedence: flag > --config > environment > default.
  --contexts CSV          Mesh members, never the ACM hub; at least two (default: \$SETUP_CONTEXTS).
  --workload-context CTX  The member that runs the echo workload, i.e. whose ACM ManagedCluster
                          name is the chart's workloadCluster; one of --contexts
                          (default: \$GWAPI_WORKLOAD_CONTEXT).
  --hub-context CTX       ACM hub context: also read the Argo CD health of the per-member
                          Applications (best effort). Not one of --contexts.
                          (default: \$GWAPI_HUB_CONTEXT; empty = skip)
  --ingress CTX=ADDR      Ingress address of a member (host or IP, optional :PORT) when its
                          LoadBalancer status cannot be read. Repeatable, or CSV.
                          (default: \$GWAPI_INGRESS)
  --requests N            Requests per member ingress x scenario host (default: ${REQUESTS}).
  --timeout SEC           curl --max-time per request (default: ${TIMEOUT_SEC}). A cell with a timed-out
                          request gets one more request with GWAPI_DETAIL_TIMEOUT_SEC
                          (${GWAPI_DETAIL_TIMEOUT_SEC}): Envoy answers a dead east-west hop only after
                          3 x 10 s connect timeouts (1 try + Istio's default 2 retries).
  --wait-timeout SEC      Max wait for the Gateway's Programmed condition, the echo Deployment
                          and istio's status on every route before the traffic (default: ${WAIT_TIMEOUT_SEC};
                          0 = read once). Rows still without status say STATUS_TIMEOUT.
  --results-dir DIR       Results base dir; the run writes DIR/run-<RUN_ID>/
                          (default: ${GWAPI_RESULTS_DIR}).
  --skip-proxy-config     Skip the istioctl endpoint evidence (also skipped without istioctl).
  --dry-run               Validate the arguments and print the plan; no cluster is contacted.
  -h, --help              Show this help.

Environment (config/options.env): GWAPI_DETAIL_TIMEOUT_SEC, GWAPI_KUBECTL_TIMEOUT_SEC
(kubectl --request-timeout, default ${GWAPI_KUBECTL_TIMEOUT_SEC}), GWAPI_ISTIOCTL_TIMEOUT_SEC (limit per
istioctl call, default ${GWAPI_ISTIOCTL_TIMEOUT_SEC}), GWAPI_NAMESPACE (${NS}), GWAPI_REMOTE_NAMESPACE
(${NS_REMOTE}), GWAPI_GATEWAY (${GW_NAME}), GWAPI_ARGOCD_NAMESPACE (${GWAPI_ARGOCD_NAMESPACE}),
GWAPI_ARGOCD_APPSET (${GWAPI_ARGOCD_APPSET}).

Writes run-<RUN_ID>/gateway-api-<RUN_ID>.tsv (one row per member x scenario: expected vs
observed status, HTTP codes, body and endpoints, verdict MATCH/DEVIATION/UNKNOWN),
summary-<RUN_ID>.md (the answers first), and argocd-<RUN_ID>.tsv with --hub-context.
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
	--workload-context)
		[[ -n "${2:-}" ]] || die "--workload-context requires a value"
		WORKLOAD_CTX="$2"
		shift 2
		;;
	--hub-context)
		[[ -n "${2:-}" ]] || die "--hub-context requires a value"
		HUB_CTX="$2"
		shift 2
		;;
	--ingress)
		[[ -n "${2:-}" ]] || die "--ingress requires a value (CTX=ADDR)"
		# The first --ingress replaces GWAPI_INGRESS; later ones add to it.
		if ((!INGRESS_FROM_FLAG)); then
			INGRESS_CSV=""
			INGRESS_FROM_FLAG=1
		fi
		INGRESS_CSV="${INGRESS_CSV:+${INGRESS_CSV},}$2"
		shift 2
		;;
	--requests)
		[[ -n "${2:-}" ]] || die "--requests requires a value"
		REQUESTS="$2"
		shift 2
		;;
	--timeout)
		[[ -n "${2:-}" ]] || die "--timeout requires a value"
		TIMEOUT_SEC="$2"
		shift 2
		;;
	--wait-timeout)
		[[ -n "${2:-}" ]] || die "--wait-timeout requires a value"
		WAIT_TIMEOUT_SEC="$2"
		shift 2
		;;
	--results-dir)
		[[ -n "${2:-}" ]] || die "--results-dir requires a value"
		RESULTS_DIR="$2"
		shift 2
		;;
	--skip-proxy-config)
		SKIP_PROXY_CONFIG=1
		shift
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

warn() { echo "warning: $*" >&2; }

# --- Validation (before --dry-run returns, so the CI dry-run checks it too) ---

CONTEXTS=()
split_csv "$CONTEXTS_CSV" CONTEXTS
((${#CONTEXTS[@]} >= 2)) || die "--contexts (or SETUP_CONTEXTS) needs at least two mesh members (one runs the workload, the others show the cross-cluster path); got '${CONTEXTS_CSV}'"
declare -A IS_MEMBER=()
for ctx in "${CONTEXTS[@]}"; do
	[[ -z "${IS_MEMBER[$ctx]:-}" ]] || die "--contexts lists ${ctx} twice"
	IS_MEMBER[$ctx]=1
done
[[ -n "$WORKLOAD_CTX" ]] || die "--workload-context (or GWAPI_WORKLOAD_CONTEXT) is required: the member whose ACM ManagedCluster name is the chart's workloadCluster"
[[ -n "${IS_MEMBER[$WORKLOAD_CTX]:-}" ]] || die "--workload-context ${WORKLOAD_CTX} is not one of --contexts (${CONTEXTS[*]})"
if [[ -n "$HUB_CTX" && -n "${IS_MEMBER[$HUB_CTX]:-}" ]]; then
	die "--hub-context ${HUB_CTX} is also in --contexts: --contexts lists mesh members only, never the ACM hub"
fi
is_pos_int "$REQUESTS" || die "--requests (or GWAPI_REQUESTS) must be a positive integer; got '${REQUESTS}'"
is_pos_int "$TIMEOUT_SEC" || die "--timeout (or GWAPI_TIMEOUT_SEC) must be a positive integer; got '${TIMEOUT_SEC}'"
is_nonneg_int "$WAIT_TIMEOUT_SEC" || die "--wait-timeout (or GWAPI_WAIT_TIMEOUT_SEC) must be a non-negative integer; got '${WAIT_TIMEOUT_SEC}'"
is_pos_int "$GWAPI_DETAIL_TIMEOUT_SEC" || die "GWAPI_DETAIL_TIMEOUT_SEC must be a positive integer; got '${GWAPI_DETAIL_TIMEOUT_SEC}'"
is_pos_int "$GWAPI_KUBECTL_TIMEOUT_SEC" || die "GWAPI_KUBECTL_TIMEOUT_SEC must be a positive integer; got '${GWAPI_KUBECTL_TIMEOUT_SEC}'"
is_pos_int "$GWAPI_ISTIOCTL_TIMEOUT_SEC" || die "GWAPI_ISTIOCTL_TIMEOUT_SEC must be a positive integer; got '${GWAPI_ISTIOCTL_TIMEOUT_SEC}'"
[[ "$SKIP_PROXY_CONFIG" == 0 || "$SKIP_PROXY_CONFIG" == 1 ]] || die "GWAPI_SKIP_PROXY_CONFIG must be 0 or 1; got '${SKIP_PROXY_CONFIG}'"
DNS_LABEL_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
for kv in "GWAPI_NAMESPACE=${NS}" "GWAPI_REMOTE_NAMESPACE=${NS_REMOTE}" "GWAPI_GATEWAY=${GW_NAME}" "GWAPI_ARGOCD_NAMESPACE=${GWAPI_ARGOCD_NAMESPACE}" "GWAPI_ARGOCD_APPSET=${GWAPI_ARGOCD_APPSET}"; do
	[[ "${kv#*=}" =~ $DNS_LABEL_RE ]] || die "${kv%%=*} must be a lowercase DNS label; got '${kv#*=}'"
done
[[ "$NS_REMOTE" != "$NS" ]] || die "GWAPI_REMOTE_NAMESPACE must differ from GWAPI_NAMESPACE (${NS}): S7-S9 need a backend namespace that exists on the workload member only"

# Ingress overrides: CTX=ADDR[:PORT]; a context name may hold ':' and '/', so split at the last '='.
declare -A INGRESS_ADDR=() INGRESS_SOURCE=()
INGRESS_ITEMS=()
split_csv "$INGRESS_CSV" INGRESS_ITEMS
ADDR_RE='^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?$'
for item in "${INGRESS_ITEMS[@]}"; do
	[[ "$item" == *=* ]] || die "--ingress (or GWAPI_INGRESS) takes CTX=ADDR[:PORT]; got '${item}'"
	ctx="${item%=*}"
	addr="${item##*=}"
	[[ -n "${IS_MEMBER[$ctx]:-}" ]] || die "--ingress ${ctx}=...: ${ctx} is not one of --contexts"
	[[ "$addr" =~ $ADDR_RE ]] || die "--ingress ${ctx}=...: not a host name or IP address with an optional :PORT"
	[[ -z "${INGRESS_ADDR[$ctx]:-}" ]] || die "--ingress names ${ctx} twice"
	INGRESS_ADDR[$ctx]="$addr"
	INGRESS_SOURCE[$ctx]=override
done

# role <ctx>: workload or other.
role() { if [[ "$1" == "$WORKLOAD_CTX" ]]; then echo workload; else echo other; fi; }

# bns_name <main|remote>: the backend namespace of a SCENARIOS row.
bns_name() { if [[ "$1" == remote ]]; then echo "$NS_REMOTE"; else echo "$NS"; fi; }

# The unique backend hosts, for the endpoint evidence (one istioctl call each per member).
FQDNS=()
declare -A SEEN_FQDN=()
for line in "${SCENARIOS[@]}"; do
	IFS='|' read -r _ _ _ _ _ backend bns _ <<<"$line"
	fqdn="${backend}.$(bns_name "$bns").svc.${CLUSTER_DOMAIN}"
	[[ -n "${SEEN_FQDN[$fqdn]:-}" ]] && continue
	SEEN_FQDN[$fqdn]=1
	FQDNS+=("$fqdn")
done

# backend_label <kind> <service> <main|remote>: the backendRef as the chart writes it; a backend
# outside the routes' namespace as <namespace>/<service>.
backend_label() {
	case "$1" in
	Hostname) echo "Hostname ${2}.$(bns_name "$3").svc.${CLUSTER_DOMAIN}" ;;
	*) if [[ "$3" == remote ]]; then echo "$1 ${NS_REMOTE}/$2"; else echo "$1 $2"; fi ;;
	esac
}

if ((DRY_RUN)); then
	proxy_plan="istioctl proxy-config endpoints on each ingress, ${#FQDNS[@]} backends, ${GWAPI_ISTIOCTL_TIMEOUT_SEC} s limit per call"
	((SKIP_PROXY_CONFIG)) && proxy_plan="skipped (--skip-proxy-config)"
	argo_plan="skipped (no --hub-context)"
	[[ -n "$HUB_CTX" ]] && argo_plan="hub ${HUB_CTX}: Applications of ApplicationSet ${GWAPI_ARGOCD_NAMESPACE}/${GWAPI_ARGOCD_APPSET}"
	pc_worst=0
	((SKIP_PROXY_CONFIG)) || pc_worst=$((${#FQDNS[@]} * GWAPI_ISTIOCTL_TIMEOUT_SEC))
	echo "=== Gateway API multicluster ingress check: dry run (no cluster is contacted) ==="
	echo "Members:        ${CONTEXTS[*]} (workload: ${WORKLOAD_CTX})"
	echo "Check objects:  namespace ${NS}, Gateway istio-system/${GW_NAME}; backend namespace ${NS_REMOTE} on ${WORKLOAD_CTX} only (charts/mesh-verify-gateway-api)"
	for ctx in "${CONTEXTS[@]}"; do
		if [[ -n "${INGRESS_ADDR[$ctx]:-}" ]]; then
			echo "Ingress ${ctx}: the --ingress override"
		else
			echo "Ingress ${ctx}: LoadBalancer status of istio-system/${INGRESS_DEPLOY}"
		fi
	done
	echo "Preflight:      Gateway API CRDs, GatewayClass istio, namespace labels, ${NS_REMOTE} on the workload member only, istiod env overrides, both echo Deployments, Istio CR version, tuning baseline (kubectl --request-timeout ${GWAPI_KUBECTL_TIMEOUT_SEC}s)"
	echo "Wait:           up to ${WAIT_TIMEOUT_SEC} s for Gateway Programmed, both echo Deployments Ready and every route's status (poll ${POLL_SEC} s)"
	echo "Traffic:        ${REQUESTS} requests x ${#SCENARIOS[@]} hosts x ${#CONTEXTS[@]} ingresses, curl --max-time ${TIMEOUT_SEC}; one ${GWAPI_DETAIL_TIMEOUT_SEC} s detail request per cell with a timeout"
	echo "Proxy evidence: ${proxy_plan}"
	echo "Argo CD health: ${argo_plan}"
	echo "Worst case:     about $((WAIT_TIMEOUT_SEC + REQUESTS * TIMEOUT_SEC + GWAPI_DETAIL_TIMEOUT_SEC + pc_worst)) s (wait + traffic + evidence; cells and members run in parallel; kubectl reads not included)"
	echo "Output:         ${RESULTS_DIR}/run-<RUN_ID>/gateway-api-<RUN_ID>.tsv, summary-<RUN_ID>.md"
	echo ""
	echo "Predictions (W = via the workload member ${WORKLOAD_CTX}, O = via every other member):"
	printf '  %-3s %-16s %-49s %-49s %-8s %-30s %s\n' ID HOST "STATUS W" "STATUS O" "HTTP W/O" "ENDPOINTS W / O" BACKEND
	for line in "${SCENARIOS[@]}"; do
		IFS='|' read -r id _ host _ bkind backend bns st_w st_o code_w code_o ep_w ep_o _ _ <<<"$line"
		printf '  %-3s %-16s %-49s %-49s %-8s %-30s %s\n' "$id" "$host" "$st_w" "$st_o" "${code_w}/${code_o}" "${ep_w} / ${ep_o}" "$(backend_label "$bkind" "$backend" "$bns")"
	done
	echo ""
	echo "Dry-run complete: nothing was contacted or written."
	exit 0
fi

# --- Run ---

KUBECTL=()
resolve_kubectl KUBECTL
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUT_DIR="${RESULTS_DIR}/run-${RUN_ID}"
TSV="${OUT_DIR}/gateway-api-${RUN_ID}.tsv"
SUMMARY="${OUT_DIR}/summary-${RUN_ID}.md"
ARGO_TSV="${OUT_DIR}/argocd-${RUN_ID}.tsv"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run_bounded <sec> <stdout> <stderr> <cmd...>: run cmd with a wall-clock limit (bash only:
# no `timeout` binary on macOS). Returns cmd's status, or 124 when it was stopped.
run_bounded() {
	local sec="$1" out="$2" err="$3" pid i
	shift 3
	"$@" >"$out" 2>"$err" &
	pid=$!
	for ((i = 0; i < sec * 10; i++)); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		return 124
	fi
	wait "$pid"
}

# kget <ctx> <out_json> <kubectl args...>: one bounded read (-o json) into <out_json>, stderr in
# <out_json>.err. Returns 0, 3 when the server says NotFound or lacks the resource type (a CRD
# that is not installed), or 1 for any other failure (unreachable, forbidden, timeout, unknown
# context).
kget() {
	local ctx="$1" out="$2" rc=0
	shift 2
	"${KUBECTL[@]}" --context="$ctx" --request-timeout="${GWAPI_KUBECTL_TIMEOUT_SEC}s" "$@" -o json >"$out" 2>"${out}.err" || rc=$?
	if ((rc == 0)); then return 0; fi
	if grep -qE "Error from server \(NotFound\)|doesn't have a resource type" "${out}.err" 2>/dev/null; then return 3; fi
	return 1
}

# kval <ctx> <jq filter> <kubectl args...>: one bounded read through a jq filter. Prints the
# filter's output, "absent" for NotFound, "unknown" for any other failure: never a false value
# for a query that did not answer (PL39).
kval() {
	local ctx="$1" filter="$2" tmp rc=0 v
	shift 2
	tmp="$(mktemp "${WORK}/kval.XXXXXX")"
	kget "$ctx" "$tmp" "$@" || rc=$?
	if ((rc == 3)); then
		v=absent
	elif ((rc != 0)); then
		v=unknown
	else
		v="$(jq -r "$filter" "$tmp" 2>/dev/null)" || v=unknown
	fi
	rm -f "$tmp" "${tmp}.err"
	[[ -n "$v" ]] || v=unknown
	printf '%s\n' "$v"
}

# --- Step 1: preflight (live state per member, recorded in the preamble: PL39) ---

# shellcheck disable=SC2016  # jq program: $c and $n are jq variables
ISTIOD_ENV_FILTER='[.items[].spec.template.spec.containers[]? | select(.name == "discovery")] as $c
	| if ($c | length) == 0 then "no-istiod" else
	  ["PILOT_ENABLE_GATEWAY_API", "ENABLE_GATEWAY_API_MANUAL_DEPLOYMENT", "PILOT_FILTER_GATEWAY_CLUSTER_CONFIG",
	   "ENABLE_MCS_HOST", "ENABLE_MCS_SERVICE_DISCOVERY"]
	  | map(. as $n | "\($n)=" + ([$c[] | ([.env[]? | select(.name == $n)][0])
	      | if . == null then "unset" elif has("value") then (.value | tostring) else "valueFrom" end] | unique | join("|")))
	  | join(";") end'
ECHO_FILTER='if (.items | length) == 0 then "absent\t-" else (.items[0]
	| "ready=\(.status.readyReplicas // 0)/\(.spec.replicas // 0)\t\(([.spec.template.spec.containers[]? | select(.name == "http-echo")
	| .args[]? | select(startswith("-text=")) | sub("^-text="; "")][0]) // "-")") end'
NS_LABEL_FILTER='"istio-discovery=\(.metadata.labels["istio-discovery"] // "unset");istio.io/rev=\(.metadata.labels["istio.io/rev"] // "unset")"'
SIDECAR_FILTER='if (.items | length) == 0 then "no-pods" else ([.items[] | ((.spec.containers // []) + (.spec.initContainers // []))
	| map(.name) | index("istio-proxy") != null] | if all then "yes" elif any then "partial" else "no" end) end'

# preflight_member <i> <ctx>: writes key<TAB>value lines to $WORK/pre-<i>.kv.
preflight_member() {
	local i="$1" ctx="$2" echo_line tb
	{
		printf 'crd\t%s\n' "$(kval "$ctx" '"\(.metadata.annotations["gateway.networking.k8s.io/bundle-version"] // "unversioned")/\(.metadata.annotations["gateway.networking.k8s.io/channel"] // "unknown-channel")"' \
			get crd httproutes.gateway.networking.k8s.io)"
		printf 'gatewayclass\t%s\n' "$(kval "$ctx" '"\(.spec.controllerName);Accepted=\(([.status.conditions[]? | select(.type == "Accepted")][0].status) // "missing")"' \
			get gatewayclasses.gateway.networking.k8s.io istio)"
		printf 'namespace\t%s\n' "$(kval "$ctx" "$NS_LABEL_FILTER" get namespace "$NS")"
		# S7-S9's backend namespace: expected on the workload member only ("absent" elsewhere).
		printf 'remote_namespace\t%s\n' "$(kval "$ctx" "$NS_LABEL_FILTER" get namespace "$NS_REMOTE")"
		printf 'gateway\t%s\n' "$(kval "$ctx" '"present"' -n istio-system get gateways.gateway.networking.k8s.io "$GW_NAME")"
		printf 'istiod_env\t%s\n' "$(kval "$ctx" "$ISTIOD_ENV_FILTER" -n istio-system get deploy -l app=istiod)"
		printf 'istio_cr_version\t%s\n' "$(kval "$ctx" '.spec.version // "unset"' get istios.sailoperator.io default)"
		echo_line="$(kval "$ctx" "$ECHO_FILTER" -n "$NS" get deploy -l "$ECHO_SELECTOR")"
		if [[ "$echo_line" == *$'\t'* ]]; then
			printf 'echo\t%s\n' "${echo_line%%$'\t'*}"
			printf 'echo_text\t%s\n' "${echo_line#*$'\t'}"
		else
			printf 'echo\t%s\n' "$echo_line"
			printf 'echo_text\t-\n'
		fi
		printf 'echo_sidecar\t%s\n' "$(kval "$ctx" "$SIDECAR_FILTER" -n "$NS" get pods -l "$ECHO_SELECTOR")"
		echo_line="$(kval "$ctx" "$ECHO_FILTER" -n "$NS_REMOTE" get deploy -l "$ECHO_SELECTOR")"
		printf 'echo_remote\t%s\n' "${echo_line%%$'\t'*}"
		printf 'echo_remote_sidecar\t%s\n' "$(kval "$ctx" "$SIDECAR_FILTER" -n "$NS_REMOTE" get pods -l "$ECHO_SELECTOR")"
		# The address stays in memory and $WORK: results record only where it came from.
		printf 'ingress_lb\t%s\n' "$(kval "$ctx" '.status.loadBalancer.ingress[0] // {} | .hostname // .ip // "pending"' \
			-n istio-system get svc "$INGRESS_DEPLOY")"
		tb="$(tuning_baseline_state "$ctx" "${KUBECTL[@]}" 2>/dev/null)" || tb=""
		printf 'tuning_baseline\t%s\n' "$(sed -n 's/^TUNING_BASELINE=//p' <<<"$tb" | head -1)"
		printf 'sidecar_egress_hosts\t%s\n' "$(sed -n 's/^SIDECAR_EGRESS_HOSTS=//p' <<<"$tb" | head -1)"
	} >"${WORK}/pre-${i}.kv"
}

echo "Run ${RUN_ID}: preflight on ${CONTEXTS[*]} (workload: ${WORKLOAD_CTX})" >&2
declare -A PRE=()
pids=()
for i in "${!CONTEXTS[@]}"; do
	(preflight_member "$i" "${CONTEXTS[i]}") 2>"${WORK}/pre-${i}.stderr" &
	pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || true; done
KUBE_VERSIONS="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
PREFLIGHT_KEYS=(crd gatewayclass namespace remote_namespace gateway istiod_env istio_cr_version echo echo_text echo_sidecar echo_remote echo_remote_sidecar ingress_lb tuning_baseline sidecar_egress_hosts)
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	for k in "${PREFLIGHT_KEYS[@]}"; do PRE["${ctx}|${k}"]=unknown; done
	if [[ -f "${WORK}/pre-${i}.kv" ]]; then
		while IFS=$'\t' read -r k v; do
			[[ -n "$k" ]] && PRE["${ctx}|${k}"]="${v:-unknown}"
		done <"${WORK}/pre-${i}.kv"
	fi
done

# Stop when the check is not deployed (a whole-run precondition: nothing is written).
problems=()
readable=0
for ctx in "${CONTEXTS[@]}"; do
	[[ "${PRE[$ctx|namespace]}" == unknown ]] || readable=$((readable + 1))
	[[ "${PRE[$ctx|crd]}" != absent ]] || problems+=("${ctx}: no Gateway API CRDs (httproutes.gateway.networking.k8s.io)")
	[[ "${PRE[$ctx|namespace]}" != absent ]] || problems+=("${ctx}: namespace ${NS} is missing")
	[[ "${PRE[$ctx|gateway]}" != absent ]] || problems+=("${ctx}: Gateway istio-system/${GW_NAME} is missing")
	if [[ "$ctx" == "$WORKLOAD_CTX" ]]; then
		[[ "${PRE[$ctx|echo]}" != absent ]] || problems+=("${ctx} (--workload-context): no echo Deployment (${ECHO_SELECTOR}) in ${NS}; the chart's workloadCluster must be this member's ACM ManagedCluster name")
		if [[ "${PRE[$ctx|remote_namespace]}" == absent ]]; then
			problems+=("${ctx} (--workload-context): namespace ${NS_REMOTE} (the S7-S9 backends) is missing; sync a chart revision that renders it")
		elif [[ "${PRE[$ctx|echo_remote]}" == absent ]]; then
			problems+=("${ctx} (--workload-context): no echo Deployment (${ECHO_SELECTOR}) in ${NS_REMOTE}")
		fi
	else
		if [[ "${PRE[$ctx|echo]}" != absent && "${PRE[$ctx|echo]}" != unknown ]]; then
			problems+=("${ctx}: runs the echo Deployment, but --workload-context is ${WORKLOAD_CTX}; pass the member whose ManagedCluster name is the chart's workloadCluster")
		fi
		# Not a stop: only S7-S9 depend on it, and their rows on this member say so.
		case "${PRE[$ctx|remote_namespace]}" in
		absent) ;;
		unknown) warn "${ctx}: could not read whether namespace ${NS_REMOTE} exists; its S7-S9 rows say NS_SCENARIO_UNVERIFIED" ;;
		*) warn "${ctx}: namespace ${NS_REMOTE} exists here, but S7-S9 need it on the workload member only; its S7-S9 rows say NS_SCENARIO_INVALID" ;;
		esac
	fi
	for k in crd gatewayclass namespace gateway istiod_env echo; do
		[[ "${PRE[$ctx|$k]}" != unknown ]] || warn "${ctx}: could not read ${k} (recorded as unknown)"
	done
done
((readable > 0)) || die "no member answered the preflight reads (${CONTEXTS[*]}); check the contexts and GWAPI_KUBECTL_TIMEOUT_SEC. Nothing was written."
if ((${#problems[@]})); then
	for p in "${problems[@]}"; do echo "error: ${p}" >&2; done
	die "the check is not deployed as expected (above). Deploy it from the ACM hub: edit and apply charts/mesh-verify-gateway-api-appset.yaml (tests/gateway-api/README.md, \"Deploy\"). Nothing was written."
fi

# --- Step 2: bounded wait for the Gateway, the echo Deployment and every route's status (PL4) ---

# snap_get <ctx> <out> <kubectl args...>: kget, with its return code saved in <out>.rc.
snap_get() {
	local rc=0
	kget "$@" || rc=$?
	echo "$rc" >"${2}.rc"
}

# snapshot_all <dir>: read every member's Gateway, routes, VirtualServices (and both echo
# Deployments on the workload member) into <dir>/m<i>/, members in parallel.
snapshot_all() {
	local dir="$1" i ctx d p
	local -a spids=()
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		d="${dir}/m${i}"
		mkdir -p "$d"
		(
			snap_get "$ctx" "${d}/gw.json" -n istio-system get gateways.gateway.networking.k8s.io "$GW_NAME"
			snap_get "$ctx" "${d}/routes.json" -n "$NS" get httproutes.gateway.networking.k8s.io
			snap_get "$ctx" "${d}/vs.json" -n "$NS" get virtualservices.networking.istio.io
			if [[ "$ctx" == "$WORKLOAD_CTX" ]]; then
				snap_get "$ctx" "${d}/echo.json" -n "$NS" get deploy -l "$ECHO_SELECTOR"
				snap_get "$ctx" "${d}/echo-remote.json" -n "$NS_REMOTE" get deploy -l "$ECHO_SELECTOR"
			fi
		) 2>/dev/null &
		spids+=("$!")
	done
	for p in "${spids[@]}"; do wait "$p" || true; done
}

# snap_rc <file>: kget's return code for a snapshot file (1 when it is missing).
snap_rc() { cat "${1}.rc" 2>/dev/null || echo 1; }

# gw_programmed <member dir>: True, <status>:<reason>, no-status, stale, absent or unknown.
gw_programmed() {
	local f="$1/gw.json" rc
	rc="$(snap_rc "$f")"
	case "$rc" in
	0) ;;
	3) echo absent; return 0 ;;
	*) echo unknown; return 0 ;;
	esac
	jq -r '(.metadata.generation // 0) as $g
		| ([.status.conditions[]? | select(.type == "Programmed")][0]) as $c
		| if $c == null then "no-status"
		  elif ($c.observedGeneration // $g) < $g then "stale"
		  elif $c.status == "True" then "True"
		  else "\($c.status):\($c.reason // "-")" end' "$f" 2>/dev/null || echo unknown
}

# route_status <member dir> <route>: Accepted=<s>[:<reason>]/ResolvedRefs=<s>[:<reason>] from the
# parent entry of istio's controller for our Gateway; or absent, no-status, stale, unknown.
route_status() {
	local f="$1/routes.json" rc
	rc="$(snap_rc "$f")"
	case "$rc" in
	0) ;;
	3) echo absent; return 0 ;;
	*) echo unknown; return 0 ;;
	esac
	jq -r --arg n "$2" --arg gw "$GW_NAME" --arg ctl "$GW_CONTROLLER" '
		([.items[]? | select(.metadata.name == $n)][0]) as $r
		| if $r == null then "absent" else
		  ($r.metadata.generation // 0) as $g
		  | ([$r.status.parents[]? | select(.controllerName == $ctl and .parentRef.name == $gw)][0]) as $p
		  | if $p == null then "no-status"
		    elif ([$p.conditions[]? | select((.observedGeneration // $g) < $g)] | length) > 0 then "stale"
		    else ["Accepted", "ResolvedRefs"] | map(. as $t
		      | ([$p.conditions[]? | select(.type == $t)][0]) as $c
		      | if $c == null then "\($t)=missing"
		        elif $c.status == "True" then "\($t)=True"
		        else "\($t)=\($c.status):\($c.reason // "-")" end) | join("/")
		    end
		  end' "$f" 2>/dev/null || echo unknown
}

# vs_status <member dir> <name>: present, absent or unknown (a VirtualService has no status).
vs_status() {
	local f="$1/vs.json" rc
	rc="$(snap_rc "$f")"
	case "$rc" in
	0) ;;
	3) echo absent; return 0 ;;
	*) echo unknown; return 0 ;;
	esac
	jq -r --arg n "$2" 'if any(.items[]?; .metadata.name == $n) then "present" else "absent" end' "$f" 2>/dev/null || echo unknown
}

# echo_ready <snapshot file>: readyReplicas of an echo Deployment (0 when unreadable).
echo_ready() {
	jq -r '[.items[]?.status.readyReplicas // 0] | add // 0' "$1" 2>/dev/null || echo 0
}

# route_expected <ctx> <scenario line>: the route's expected status on that member.
route_expected() {
	local st_w st_o
	IFS='|' read -r _ _ _ _ _ _ _ st_w st_o _ <<<"$2"
	if [[ "$1" == "$WORKLOAD_CTX" ]]; then echo "$st_w"; else echo "$st_o"; fi
}

# member_pending <i> <ctx> <dir>: what is not settled yet on that member, empty when all is.
member_pending() {
	local ctx="$2" d="$3/m$1" out="" st line kind route exp
	st="$(gw_programmed "$d")"
	[[ "$st" == True ]] || out="Gateway Programmed=${st}"
	if [[ "$ctx" == "$WORKLOAD_CTX" ]]; then
		(($(echo_ready "${d}/echo.json") >= 1)) || out="${out:+${out}, }echo not Ready"
		(($(echo_ready "${d}/echo-remote.json") >= 1)) || out="${out:+${out}, }echo in ${NS_REMOTE} not Ready"
	fi
	for line in "${SCENARIOS[@]}"; do
		IFS='|' read -r _ kind _ route _ <<<"$line"
		exp="$(route_expected "$ctx" "$line")"
		[[ "$exp" == absent ]] && continue
		if [[ "$kind" == classic ]]; then
			st="$(vs_status "$d" "$route")"
			[[ "$st" == present ]] || out="${out:+${out}, }VirtualService ${route} ${st}"
		else
			st="$(route_status "$d" "$route")"
			case "$st" in
			absent | no-status | stale | unknown | *=missing*) out="${out:+${out}, }route ${route} ${st}" ;;
			esac
		fi
	done
	[[ -z "$out" ]] || printf '%s: %s\n' "$ctx" "$out"
}

echo "Waiting up to ${WAIT_TIMEOUT_SEC} s for the Gateway, the echo Deployment and the route status..." >&2
WAIT_SNAP="${WORK}/snap-wait"
WAIT_START=$SECONDS
WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SEC))
WAIT_TIMED_OUT=0
while :; do
	rm -rf "$WAIT_SNAP"
	mkdir -p "$WAIT_SNAP"
	snapshot_all "$WAIT_SNAP"
	pending=""
	for i in "${!CONTEXTS[@]}"; do
		p="$(member_pending "$i" "${CONTEXTS[i]}" "$WAIT_SNAP")"
		[[ -z "$p" ]] || pending="${pending:+${pending}; }${p}"
	done
	[[ -n "$pending" ]] || break
	if ((SECONDS >= WAIT_DEADLINE)); then
		WAIT_TIMED_OUT=1
		warn "the wait timed out after ${WAIT_TIMEOUT_SEC} s; going on (rows without status say STATUS_TIMEOUT). Still pending: ${pending}"
		break
	fi
	echo "  pending: ${pending}" >&2
	sleep "$POLL_SEC"
done
WAIT_SEC=$((SECONDS - WAIT_START))

# --- Step 3: traffic through every member's ingress ---

declare -A ADDR=()
for ctx in "${CONTEXTS[@]}"; do
	if [[ -n "${INGRESS_ADDR[$ctx]:-}" ]]; then
		ADDR[$ctx]="${INGRESS_ADDR[$ctx]}"
	else
		case "${PRE[$ctx|ingress_lb]}" in
		pending | absent | unknown)
			INGRESS_SOURCE[$ctx]="none:${PRE[$ctx|ingress_lb]}"
			warn "${ctx}: no ingress address (LoadBalancer status: ${PRE[$ctx|ingress_lb]}); pass --ingress ${ctx}=ADDR. Its rows say NO_INGRESS_ADDR."
			;;
		*)
			ADDR[$ctx]="${PRE[$ctx|ingress_lb]}"
			INGRESS_SOURCE[$ctx]=lb-status
			;;
		esac
	fi
done

# probe_cell <addr> <host> <out>: REQUESTS requests, one "<code>\t<first body line>" line each
# (code 000 = no HTTP answer within --timeout). curl's stderr is dropped: it names addresses.
probe_cell() {
	local addr="$1" host="$2" out="$3" body code n
	body="$(mktemp "${WORK}/body.XXXXXX")"
	: >"$out"
	for ((n = 0; n < REQUESTS; n++)); do
		: >"$body"
		code="$(curl -sS -o "$body" -w '%{http_code}' --max-time "$TIMEOUT_SEC" -H "Host: ${host}" "http://${addr}/" 2>/dev/null)" || true
		[[ "$code" =~ ^[0-9]{3}$ ]] || code=000
		printf '%s\t%s\n' "$code" "$(head -n 1 "$body" 2>/dev/null | tr -d '\r\t')" >>"$out"
	done
	rm -f "$body"
}

echo "Traffic: ${REQUESTS} requests x ${#SCENARIOS[@]} hosts through ${#ADDR[@]} ingress(es)..." >&2
pids=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	[[ -n "${ADDR[$ctx]:-}" ]] || continue
	for s in "${!SCENARIOS[@]}"; do
		IFS='|' read -r _ _ host _ <<<"${SCENARIOS[s]}"
		probe_cell "${ADDR[$ctx]}" "$host" "${WORK}/cell-${i}-${s}.txt" &
		pids+=("$!")
	done
done
for p in "${pids[@]}"; do wait "$p" || true; done

# A cell with a timed-out request gets one detail request with the long timeout (PL42), so
# Envoy's own verdict (503 and its reason) is recorded instead of a client timeout. Off the
# hot path: one request per such cell, in parallel.
pids=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	[[ -n "${ADDR[$ctx]:-}" ]] || continue
	for s in "${!SCENARIOS[@]}"; do
		grep -q '^000' "${WORK}/cell-${i}-${s}.txt" 2>/dev/null || continue
		IFS='|' read -r _ _ host _ <<<"${SCENARIOS[s]}"
		(
			b="${WORK}/detail-${i}-${s}.body"
			c="$(curl -sS -o "$b" -w '%{http_code}' --max-time "$GWAPI_DETAIL_TIMEOUT_SEC" -H "Host: ${host}" "http://${ADDR[$ctx]}/" 2>/dev/null)" || true
			[[ "$c" =~ ^[0-9]{3}$ ]] || c=000
			printf '%s\t%s\n' "$c" "$(head -n 1 "$b" 2>/dev/null | tr -d '\r\t')" >"${WORK}/detail-${i}-${s}.txt"
		) &
		pids+=("$!")
	done
done
for p in "${pids[@]}"; do wait "$p" || true; done

# An ingress where every request of every host timed out is unreachable from here, which says
# nothing about the mesh: its rows are UNKNOWN (INGRESS_UNREACHABLE), not deviations.
declare -A INGRESS_DEAD=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	[[ -n "${ADDR[$ctx]:-}" ]] || continue
	if ! grep -qsv '^000' "${WORK}/cell-${i}-"*.txt; then
		INGRESS_DEAD[$ctx]=1
		warn "${ctx}: no request through its ingress got an HTTP answer; its rows say INGRESS_UNREACHABLE"
	fi
done

# The workload's echo text: the Deployment's -text= argument (live), else the most frequent body
# of the workload ingress's own 200 answers for the scenarios that expect one.
EXPECTED_BODY="${PRE[$WORKLOAD_CTX|echo_text]}"
EXPECTED_BODY_SOURCE=deployment-arg
if [[ -z "$EXPECTED_BODY" || "$EXPECTED_BODY" == - || "$EXPECTED_BODY" == unknown ]]; then
	EXPECTED_BODY=unknown
	EXPECTED_BODY_SOURCE=unknown
	for i in "${!CONTEXTS[@]}"; do
		[[ "${CONTEXTS[i]}" == "$WORKLOAD_CTX" ]] || continue
		files=()
		for s in "${!SCENARIOS[@]}"; do
			IFS='|' read -r _ _ _ _ _ _ _ _ _ code_w _ <<<"${SCENARIOS[s]}"
			[[ "$code_w" == 200 && -f "${WORK}/cell-${i}-${s}.txt" ]] && files+=("${WORK}/cell-${i}-${s}.txt")
		done
		((${#files[@]})) || continue
		local_body="$(awk -F'\t' '$1 == "200" && $2 != "" { n[$2]++ }
			END { for (b in n) if (n[b] > best || (n[b] == best && b < top)) { best = n[b]; top = b } print top }' "${files[@]}")"
		if [[ -n "$local_body" ]]; then
			EXPECTED_BODY="$local_body"
			EXPECTED_BODY_SOURCE=local-answer
		fi
	done
fi

# --- Step 4: endpoint evidence (best effort; subshell-isolated, PL40) ---

PROXY_CONFIG_MODE="istioctl"
if ((SKIP_PROXY_CONFIG)); then
	PROXY_CONFIG_MODE="skipped (--skip-proxy-config)"
elif ! command -v istioctl >/dev/null 2>&1; then
	PROXY_CONFIG_MODE="skipped (istioctl not on PATH)"
else
	iv=""
	if run_bounded "$GWAPI_ISTIOCTL_TIMEOUT_SEC" "${WORK}/istioctl-version.json" /dev/null istioctl version --remote=false -o json; then
		iv="$(jq -r '.clientVersion.version // empty' "${WORK}/istioctl-version.json" 2>/dev/null)" || iv=""
	fi
	PROXY_CONFIG_MODE="istioctl ${iv:-unknown}"
fi

# Endpoint class of an istioctl `proxy-config endpoints -o json` reply (Envoy ClusterStatuses):
# "<class>\t<total>\t<healthy>"; port 15443 = the workload member's east-west gateway. The
# addresses themselves are never recorded.
# shellcheck disable=SC2016  # jq program
PC_FILTER='[.[]? | .hostStatuses[]?] as $h
	| ($h | length) as $n
	| ($h | map(select(((.healthStatus.edsHealthStatus // "UNKNOWN") as $s | $s == "HEALTHY" or $s == "UNKNOWN")
		and ((.healthStatus.failedOutlierCheck // false) | not))) | length) as $ok
	| ($h | map(if (.address.socketAddress.portValue // 0) == 15443 then "remote-ewgw:15443" else "local-pod" end) | unique) as $cls
	| "\(if $n == 0 then "none" elif ($cls | length) == 1 then $cls[0] else "mixed" end)\t\($n)\t\($ok)"'

# proxy_endpoints_member <i> <ctx>: one bounded istioctl call per backend host; appends
# "<fqdn>\t<class>\t<total>\t<healthy>" lines to $WORK/pc-<i>.tsv.
proxy_endpoints_member() {
	local i="$1" ctx="$2" fqdn out rc v
	for fqdn in "${FQDNS[@]}"; do
		out="${WORK}/pc-${i}-${fqdn%%.*}.json"
		rc=0
		run_bounded "$GWAPI_ISTIOCTL_TIMEOUT_SEC" "$out" "${out}.err" \
			istioctl --context "$ctx" proxy-config endpoints -n istio-system "deploy/${INGRESS_DEPLOY}" \
			--cluster "outbound|${SVC_PORT}||${fqdn}" -o json || rc=$?
		if ((rc == 0)); then
			v="$(jq -r "$PC_FILTER" "$out" 2>/dev/null)" || v=""
			[[ "$v" == *$'\t'*$'\t'* ]] || v=$'unknown\t-\t-'
		elif ((rc == 124)); then
			v=$'timeout\t-\t-'
		else
			v=$'unknown\t-\t-'
			echo "istioctl on ${ctx} for ${fqdn%%.*}: exit ${rc}: $(reach_sanitize "$(head -c 400 "${out}.err" 2>/dev/null)")" >&2
		fi
		printf '%s\t%s\n' "$fqdn" "$v" >>"${WORK}/pc-${i}.tsv"
	done
}

declare -A PC=()
if [[ "$PROXY_CONFIG_MODE" == istioctl* ]]; then
	echo "Endpoint evidence: istioctl proxy-config endpoints on every ingress..." >&2
	pids=()
	for i in "${!CONTEXTS[@]}"; do
		(proxy_endpoints_member "$i" "${CONTEXTS[i]}") 2>"${WORK}/pc-${i}.stderr" &
		pids+=("$!")
	done
	for i in "${!pids[@]}"; do
		if ! wait "${pids[i]}"; then
			warn "${CONTEXTS[i]}: the endpoint evidence step failed (the run goes on; its rows say PROXY_CONFIG_FAILED):"
		fi
		if [[ -s "${WORK}/pc-${i}.stderr" ]]; then sed 's/^/  /' "${WORK}/pc-${i}.stderr" >&2; fi
		if [[ -f "${WORK}/pc-${i}.tsv" ]]; then
			while IFS=$'\t' read -r fqdn cls tot ok; do
				PC["${CONTEXTS[i]}|${fqdn}"]="${cls}"$'\t'"${tot}"$'\t'"${ok}"
			done <"${WORK}/pc-${i}.tsv"
		fi
	done
fi

# --- Step 5: Argo CD health on the hub (best effort; subshell-isolated, PL40) ---

ARGO_STATE="not read (no --hub-context)"
WORKLOAD_CLUSTER=unknown
# The git revision Argo CD synced the chart from: chart content is GitOps-deployed, so the
# harness's HARNESS_SHA does not describe it (PL39). Known only with --hub-context.
CHART_REVISION=unknown
# argocd_health: Applications of the ApplicationSet -> $WORK/argo.rows
# (application, destination, role, health, sync, synced revision, HTTPRoute health); the
# workload cluster -> $WORK/argo.workload. Calls die on a failed read: run it in a subshell.
argocd_health() {
	local f="${WORK}/apps.json" fs="${WORK}/appset.json" rc=0 wl
	kget "$HUB_CTX" "$fs" -n "$GWAPI_ARGOCD_NAMESPACE" get applicationsets.argoproj.io "$GWAPI_ARGOCD_APPSET" || rc=$?
	((rc == 0)) || die "could not read ApplicationSet ${GWAPI_ARGOCD_NAMESPACE}/${GWAPI_ARGOCD_APPSET} on ${HUB_CTX} (kubectl: $(reach_sanitize "$(head -c 300 "${fs}.err" 2>/dev/null)"))"
	wl="$(jq -r '.spec.template.spec.source.helm.valuesObject.workloadCluster // "unset"' "$fs" 2>/dev/null)" || wl=unknown
	printf '%s\n' "${wl:-unknown}" >"${WORK}/argo.workload"
	kget "$HUB_CTX" "$f" -n "$GWAPI_ARGOCD_NAMESPACE" get applications.argoproj.io || rc=$?
	((rc == 0)) || die "could not list Applications in ${GWAPI_ARGOCD_NAMESPACE} on ${HUB_CTX} (kubectl: $(reach_sanitize "$(head -c 300 "${f}.err" 2>/dev/null)"))"
	jq -r --arg appset "$GWAPI_ARGOCD_APPSET" --arg wl "$wl" '.items[]
		| select(any(.metadata.ownerReferences[]?; .kind == "ApplicationSet" and .name == $appset))
		| (.spec.destination.name // "-") as $dst
		| [.metadata.name, $dst, (if $dst == $wl then "workload" else "other" end),
		   (.status.health.status // "unknown"), (.status.sync.status // "unknown"),
		   ((.status.sync.revision // "unknown") | .[0:12]),
		   ([.status.resources[]? | select(.kind == "HTTPRoute") | "\(.name)=\(.health.status // "none")"]
		    | if length == 0 then "-" else join(",") end)]
		| @tsv' "$f" >"${WORK}/argo.rows" || die "could not parse the Application list"
}

if [[ -n "$HUB_CTX" ]]; then
	echo "Argo CD health on ${HUB_CTX}..." >&2
	if (argocd_health) 2>"${WORK}/argo.stderr"; then
		ARGO_STATE="read from ${HUB_CTX}: $(wc -l <"${WORK}/argo.rows" | tr -d ' ') Application(s) of ${GWAPI_ARGOCD_NAMESPACE}/${GWAPI_ARGOCD_APPSET}"
		WORKLOAD_CLUSTER="$(cat "${WORK}/argo.workload" 2>/dev/null || echo unknown)"
		CHART_REVISION="$(awk -F'\t' '!seen[$6]++ { printf "%s%s", (n++ ? "," : ""), $6 }' "${WORK}/argo.rows")"
		[[ -n "$CHART_REVISION" ]] || CHART_REVISION=unknown
	else
		rm -f "${WORK}/argo.rows"
		ARGO_STATE="failed on ${HUB_CTX} (see the run's stderr)"
		warn "the Argo CD health read failed (the run goes on; the traffic data is unaffected):"
		sed 's/^/  /' "${WORK}/argo.stderr" >&2
	fi
fi

# --- Step 6: rows, TSV, summary ---

# Final status read after the traffic: S4's status depends on istiod's push timing, so the
# rows use this later read and note when it differs from the read the wait ended on.
FINAL_SNAP="${WORK}/snap-final"
mkdir -p "$FINAL_SNAP"
snapshot_all "$FINAL_SNAP"

# cell_summary <cell file> <expected body>: "<codes>\t<n>\t<n200>\t<n000>\t<n200 with the
# expected body>\t<most frequent body>"; codes as code:count by count (e.g. 200:9,503:1).
cell_summary() {
	awk -F'\t' -v e="$2" '
		{ n++; c[$1]++; b[$2]++; if ($1 == "200") { n200++; if (e != "unknown" && $2 == e) m++ } if ($1 == "000") t++ }
		END {
			k = 0
			for (x in c) keys[++k] = x
			for (i = 2; i <= k; i++) {
				v = keys[i]; j = i - 1
				while (j > 0 && (c[keys[j]] < c[v] || (c[keys[j]] == c[v] && keys[j] > v))) { keys[j + 1] = keys[j]; j-- }
				keys[j + 1] = v
			}
			out = ""
			for (i = 1; i <= k; i++) out = out (i > 1 ? "," : "") keys[i] ":" c[keys[i]]
			top = ""; tc = 0
			for (x in b) if (b[x] > tc || (b[x] == tc && x < top)) { top = x; tc = b[x] }
			printf "%s\t%d\t%d\t%d\t%d\t%s\n", (out == "" ? "-" : out), n, n200, t, m, (top == "" ? "-" : top)
		}' "$1" 2>/dev/null
}

# md_safe <text>: one table cell (no | or newline).
md_safe() { printf '%s' "$1" | tr '|\n' '/ '; }

TSV_HEADER=$'run_id\tingress_ctx\trole\tscenario\tkind\thost\troute\tbackend\texpected_status\tobserved_status\texpected_code\tobserved_codes\texpected_body\tbody_match\ttop_body\texpected_endpoints\tobserved_endpoints\tendpoints_healthy\tverdict\trow_status\tdetail'
ROWS="${WORK}/rows.tsv"
: >"$ROWS"
declare -A R=()
n_match=0 n_dev=0 n_unk=0
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	rl="$(role "$ctx")"
	for s in "${!SCENARIOS[@]}"; do
		IFS='|' read -r id kind host route bkind backend bns st_w st_o code_w code_o ep_w ep_o _ _ <<<"${SCENARIOS[s]}"
		if [[ "$rl" == workload ]]; then
			exp_status="$st_w" exp_code="$code_w" exp_ep="$ep_w"
		else
			exp_status="$st_o" exp_code="$code_o" exp_ep="$ep_o"
		fi
		fqdn="${backend}.$(bns_name "$bns").svc.${CLUSTER_DOMAIN}"
		flags=() notes=()
		dev=0 unk=0 ns_invalid=0

		# S7-S9 test an ingress member WITHOUT the backend namespace. Where it exists, or could not
		# be read, the row cannot answer that, whatever it observes: UNKNOWN, never MATCH/DEVIATION.
		if [[ "$bns" == remote && "$rl" != workload ]]; then
			case "${PRE[$ctx|remote_namespace]}" in
			absent) ;;
			unknown)
				ns_invalid=1
				flags+=(NS_SCENARIO_UNVERIFIED)
				notes+=("could not read whether namespace ${NS_REMOTE} exists on this member, so this row cannot show whether a local namespace is needed")
				;;
			*)
				ns_invalid=1
				flags+=(NS_SCENARIO_INVALID)
				notes+=("namespace ${NS_REMOTE} exists on this member (expected on the workload member only), so this row cannot show whether a local namespace is needed")
				;;
			esac
		fi

		# Status.
		if [[ "$kind" == classic ]]; then
			obs_status="$(vs_status "${FINAL_SNAP}/m${i}" "$route")"
			first_status="$(vs_status "${WAIT_SNAP}/m${i}" "$route")"
		else
			obs_status="$(route_status "${FINAL_SNAP}/m${i}" "$route")"
			first_status="$(route_status "${WAIT_SNAP}/m${i}" "$route")"
		fi
		case "$obs_status" in
		no-status | stale | *=missing*)
			if ((WAIT_TIMED_OUT)); then flags+=(STATUS_TIMEOUT); else flags+=(STATUS_PENDING); fi
			unk=1
			;;
		unknown)
			flags+=(STATUS_UNREADABLE)
			unk=1
			;;
		*)
			if [[ "$obs_status" != "$exp_status" ]]; then
				dev=1
				notes+=("status: expected ${exp_status}, got ${obs_status}")
			fi
			;;
		esac
		[[ "$first_status" == "$obs_status" ]] || notes+=("status changed during the run (the wait ended on ${first_status})")

		# Traffic.
		codes="-" body_match="-" top_body="-"
		if [[ -z "${ADDR[$ctx]:-}" ]]; then
			flags+=(NO_INGRESS_ADDR)
			unk=1
		elif [[ -n "${INGRESS_DEAD[$ctx]:-}" ]]; then
			flags+=(INGRESS_UNREACHABLE)
			unk=1
		elif [[ ! -s "${WORK}/cell-${i}-${s}.txt" ]]; then
			flags+=(NOT_PROBED)
			unk=1
		else
			IFS=$'\t' read -r codes n n200 n000 nmatch top_raw <<<"$(cell_summary "${WORK}/cell-${i}-${s}.txt" "$EXPECTED_BODY")"
			top_body="$(reach_sanitize "${top_raw:--}")"
			if ((n000 > 0)); then
				flags+=(CURL_TIMEOUT)
				if [[ -f "${WORK}/detail-${i}-${s}.txt" ]]; then
					IFS=$'\t' read -r dcode dbody <"${WORK}/detail-${i}-${s}.txt" || true
					notes+=("${n000}/${n} requests got no answer in ${TIMEOUT_SEC} s; one ${GWAPI_DETAIL_TIMEOUT_SEC} s request got ${dcode:-000}: $(reach_sanitize "${dbody:-}")")
				fi
			fi
			if [[ "$codes" != "${exp_code}:${n}" ]]; then
				dev=1
				if [[ "$top_body" == - ]]; then
					notes+=("HTTP: expected ${exp_code} on all ${n}, got ${codes}")
				else
					notes+=("HTTP: expected ${exp_code} on all ${n}, got ${codes} (most frequent body: ${top_body})")
				fi
			fi
			# Every 200 is matched against the echo text, also an unexpected one (S7 answering
			# through another member is the namespace answer "no"); only an expected 200 can make
			# the body a deviation of its own.
			if [[ "$exp_code" == 200 ]] || ((n200 > 0)); then
				if [[ "$EXPECTED_BODY" == unknown ]]; then
					body_match=unknown
					[[ "$exp_code" != 200 ]] || unk=1
				elif ((n200 == 0)); then
					body_match="n/a"
				elif ((nmatch == n200)); then
					body_match=yes
				else
					if ((nmatch == 0)); then body_match=no; else body_match="partial:${nmatch}/${n200}"; fi
					[[ "$exp_code" != 200 ]] || dev=1
					notes+=("body: ${nmatch}/${n200} of the 200s carry the workload's echo text (most frequent: ${top_body})")
				fi
			fi
		fi

		# Endpoints.
		ep_healthy="-"
		if [[ "$PROXY_CONFIG_MODE" != istioctl* ]]; then
			obs_ep=skipped
		else
			pc="${PC[$ctx|$fqdn]:-}"
			if [[ -z "$pc" ]]; then
				obs_ep=unknown
			else
				IFS=$'\t' read -r obs_ep pc_tot pc_ok <<<"$pc"
				[[ "$pc_tot" == - ]] || ep_healthy="${pc_ok}/${pc_tot}"
			fi
			case "$obs_ep" in
			unknown | timeout) flags+=(PROXY_CONFIG_FAILED) ;;
			*)
				if [[ "$exp_ep" != - && "$obs_ep" != "$exp_ep" ]]; then
					dev=1
					notes+=("endpoints: expected ${exp_ep}, got ${obs_ep}")
				fi
				;;
			esac
		fi

		if ((ns_invalid)); then
			verdict=UNKNOWN
			n_unk=$((n_unk + 1))
		elif ((dev)); then
			verdict=DEVIATION
			n_dev=$((n_dev + 1))
		elif ((unk)); then
			verdict=UNKNOWN
			n_unk=$((n_unk + 1))
		else
			verdict=MATCH
			n_match=$((n_match + 1))
		fi
		row_status=OK
		((${#flags[@]} == 0)) || row_status="$(IFS=,; echo "${flags[*]}")"
		detail="-"
		((${#notes[@]} == 0)) || detail="$(printf '%s; ' "${notes[@]}" | sed 's/; $//' | tr '\t\n' '  ')"
		exp_body="-"
		[[ "$exp_code" != 200 ]] || exp_body="$EXPECTED_BODY"
		backend_l="$(backend_label "$bkind" "$backend" "$bns")"
		printf '%s\n' "${RUN_ID}"$'\t'"${ctx}"$'\t'"${rl}"$'\t'"${id}"$'\t'"${kind}"$'\t'"${host}"$'\t'"${route}"$'\t'"${backend_l}"$'\t'"${exp_status}"$'\t'"${obs_status}"$'\t'"${exp_code}"$'\t'"${codes}"$'\t'"${exp_body}"$'\t'"${body_match}"$'\t'"${top_body}"$'\t'"${exp_ep}"$'\t'"${obs_ep}"$'\t'"${ep_healthy}"$'\t'"${verdict}"$'\t'"${row_status}"$'\t'"${detail}" >>"$ROWS"
		for k in exp_status obs_status exp_code codes body_match top_body exp_ep obs_ep ep_healthy verdict row_status detail; do
			R["${ctx}|${id}|${k}"]="${!k}"
		done
	done
done

# emit_preamble <title>: the one preamble writer for every TSV of this run (PL2, PL36). The
# summary's frontmatter is parsed from it (PL19), so no output can drift from the others.
emit_preamble() {
	local ctx
	echo "# $1"
	echo "# generated_at=$(date -u -Iseconds)"
	echo "# GWAPI_SCHEMA=${GWAPI_SCHEMA}"
	echo "# RUN_ID=${RUN_ID}"
	echo "# HARNESS_SHA=$(harness_sha)"
	echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
	config_preamble_lines
	echo "# CONTEXTS=$(IFS=,; echo "${CONTEXTS[*]}")"
	echo "# WORKLOAD_CONTEXT=${WORKLOAD_CTX}"
	echo "# WORKLOAD_CLUSTER=${WORKLOAD_CLUSTER}"
	echo "# CHART_REVISION=${CHART_REVISION}"
	echo "# HUB_CONTEXT=${HUB_CTX:-none}"
	echo "# NAMESPACE=${NS}"
	echo "# REMOTE_NAMESPACE=${NS_REMOTE}"
	echo "# GATEWAY=istio-system/${GW_NAME}"
	echo "# REQUESTS=${REQUESTS}"
	echo "# TIMEOUT_SEC=${TIMEOUT_SEC}"
	echo "# DETAIL_TIMEOUT_SEC=${GWAPI_DETAIL_TIMEOUT_SEC}"
	echo "# WAIT_TIMEOUT_SEC=${WAIT_TIMEOUT_SEC}"
	echo "# WAIT_SEC=${WAIT_SEC}"
	echo "# WAIT_TIMED_OUT=${WAIT_TIMED_OUT}"
	echo "# KUBECTL_TIMEOUT_SEC=${GWAPI_KUBECTL_TIMEOUT_SEC}"
	echo "# PROXY_CONFIG=${PROXY_CONFIG_MODE}"
	echo "# ISTIOCTL_TIMEOUT_SEC=${GWAPI_ISTIOCTL_TIMEOUT_SEC}"
	echo "# ARGOCD=${ARGO_STATE}"
	echo "# EXPECTED_BODY=${EXPECTED_BODY}"
	echo "# EXPECTED_BODY_SOURCE=${EXPECTED_BODY_SOURCE}"
	echo "# KUBE_VERSIONS=${KUBE_VERSIONS:-unknown}"
	for ctx in "${CONTEXTS[@]}"; do
		echo "# GATEWAY_API_CRD[${ctx}]=${PRE[$ctx|crd]}"
		echo "# GATEWAYCLASS[${ctx}]=${PRE[$ctx|gatewayclass]}"
		echo "# GATEWAY_PROGRAMMED[${ctx}]=$(gw_programmed "${FINAL_SNAP}/m${GW_INDEX[$ctx]}")"
		echo "# NAMESPACE_LABELS[${ctx}]=${PRE[$ctx|namespace]}"
		echo "# REMOTE_NAMESPACE_LABELS[${ctx}]=${PRE[$ctx|remote_namespace]}"
		echo "# ISTIOD_ENV[${ctx}]=${PRE[$ctx|istiod_env]}"
		echo "# ISTIO_CR_VERSION[${ctx}]=${PRE[$ctx|istio_cr_version]}"
		echo "# ECHO_DEPLOYMENT[${ctx}]=${PRE[$ctx|echo]};sidecar=${PRE[$ctx|echo_sidecar]}"
		echo "# ECHO_REMOTE_DEPLOYMENT[${ctx}]=${PRE[$ctx|echo_remote]};sidecar=${PRE[$ctx|echo_remote_sidecar]}"
		echo "# INGRESS_ADDRESS_SOURCE[${ctx}]=${INGRESS_SOURCE[$ctx]:-none}"
		echo "# TUNING_BASELINE[${ctx}]=${PRE[$ctx|tuning_baseline]}"
		echo "# SIDECAR_EGRESS_HOSTS[${ctx}]=${PRE[$ctx|sidecar_egress_hosts]}"
	done
}
declare -A GW_INDEX=()
for i in "${!CONTEXTS[@]}"; do GW_INDEX[${CONTEXTS[i]}]="$i"; done

mkdir -p "$OUT_DIR"
{
	emit_preamble "Gateway API multicluster ingress check (tests/gateway-api/001-run-ingress-check.sh)"
	printf '%s\n' "$TSV_HEADER"
	cat "$ROWS"
} >"$TSV"
if [[ -f "${WORK}/argo.rows" ]]; then
	{
		emit_preamble "Gateway API multicluster ingress check: Argo CD health (tests/gateway-api/001-run-ingress-check.sh)"
		printf 'run_id\tapplication\tdestination\trole\thealth\tsync\trevision\thttproute_health\n'
		sed "s/^/${RUN_ID}"$'\t'"/" "${WORK}/argo.rows"
	} >"$ARGO_TSV"
fi

# --- The answer ---

OTHERS=()
for ctx in "${CONTEXTS[@]}"; do [[ "$ctx" == "$WORKLOAD_CTX" ]] || OTHERS+=("$ctx"); done

# cell_state <ctx> <id>: ok (every request 200 with the echo text), fail (no request
# answered 200 and none timed out), or unclear.
cell_state() {
	local codes="${R[$1|$2|codes]}" bm="${R[$1|$2|body_match]}" rs="${R[$1|$2|row_status]}"
	case "$rs" in *NO_INGRESS_ADDR* | *INGRESS_UNREACHABLE* | *NS_SCENARIO_*) echo unclear; return 0 ;; esac
	if [[ "$codes" == "200:${REQUESTS}" && "$bm" == yes ]]; then
		echo ok
	elif [[ "$codes" != "-" && "$codes" != *200:* && "$codes" != *000:* ]]; then
		echo fail
	else
		echo unclear
	fi
}

# member_answer <ctx> <id> <reference id...>: ok (<id> answered), fail (<id> failed while a
# reference scenario answered through the same ingress, so the failure is <id>'s own), broken
# (<id> failed and no reference answered: the cross-cluster path itself), or unclear.
member_answer() {
	local ctx="$1" id="$2" r
	shift 2
	case "$(cell_state "$ctx" "$id")" in
	ok) echo ok ;;
	fail)
		for r in "$@"; do
			if [[ "$(cell_state "$ctx" "$r")" == ok ]]; then
				echo fail
				return 0
			fi
		done
		echo broken
		;;
	*) echo unclear ;;
	esac
}

# answer_lists <id> <reference id...>: sorts the other members into ANS_OK, ANS_FAIL, ANS_BROKEN
# and ANS_UNCLEAR by member_answer.
answer_lists() {
	local o
	ANS_OK=() ANS_FAIL=() ANS_BROKEN=() ANS_UNCLEAR=()
	for o in "${OTHERS[@]}"; do
		case "$(member_answer "$o" "$@")" in
		ok) ANS_OK+=("$o") ;;
		fail) ANS_FAIL+=("$o") ;;
		broken) ANS_BROKEN+=("$o") ;;
		*) ANS_UNCLEAR+=("$o") ;;
		esac
	done
}
join_ticks() { local x out=""; for x in "$@"; do out="${out:+${out}, }\`${x}\`"; done; printf '%s' "$out"; }
n_others=${#OTHERS[@]}

# Answer 1: is the Service needed? S2 (no Service on the ingress member) against S3 (a stub there).
answer_lists S2 S3
if ((${#ANS_OK[@]} == n_others)); then
	HEADLINE="**Service needed in every cluster for HTTPRoute traffic: NO** — S2 answered 200 (${REQUESTS}/${REQUESTS}, body \`${EXPECTED_BODY}\`) from the workload member \`${WORKLOAD_CTX}\` through $(join_ticks "${ANS_OK[@]}")'s ingress, with no \`echo-s2\` Service there."
elif ((${#ANS_FAIL[@]} == n_others)); then
	o="${ANS_FAIL[0]}"
	HEADLINE="**Service needed in every cluster for HTTPRoute traffic: YES** — S2 (no \`echo-s2\` Service on the ingress member) returned \`${R[$o|S2|codes]}\` through $(join_ticks "${ANS_FAIL[@]}")'s ingress, while S3 (the same route plus a stub Service) answered 200 from the workload member \`${WORKLOAD_CTX}\`."
elif ((${#ANS_BROKEN[@]} == n_others)); then
	o="${ANS_BROKEN[0]}"
	HEADLINE="**INCONCLUSIVE** — S2 and S3 both failed through $(join_ticks "${ANS_BROKEN[@]}")'s ingress (S2 \`${R[$o|S2|codes]}\`, S3 \`${R[$o|S3|codes]}\`): the cross-cluster path itself is broken, Service or not. Check S1, mesh-verify and the east-west gateways first."
else
	why=""
	((${#ANS_OK[@]} == 0)) || why="${why}S2 answered 200 through $(join_ticks "${ANS_OK[@]}"); "
	((${#ANS_FAIL[@]} == 0)) || why="${why}S2 failed (S3 answered) through $(join_ticks "${ANS_FAIL[@]}"); "
	((${#ANS_BROKEN[@]} == 0)) || why="${why}S2 and S3 both failed through $(join_ticks "${ANS_BROKEN[@]}"); "
	for o in "${ANS_UNCLEAR[@]}"; do
		why="${why}S2 through \`${o}\`: HTTP \`${R[$o|S2|codes]}\`, body match \`${R[$o|S2|body_match]}\`, row status \`${R[$o|S2|row_status]}\`; "
	done
	((WAIT_TIMED_OUT == 0)) || why="${why}the wait timed out; "
	[[ "$EXPECTED_BODY" != unknown ]] || why="${why}the workload's echo text is unknown; "
	HEADLINE="**INCONCLUSIVE** — ${why%; }. See the matrix and the deviations below."
fi

# ns_part <label> <id> <reference id...>: one answer of the namespace line. <id>'s backend
# namespace exists on the workload member only; a reference is a scenario whose backend is in
# the same namespace, so "<id> failed while a reference answered" pins the failure on <id>'s kind.
ns_part() {
	local label="$1" id="$2" refs o why="" rs
	shift 2
	refs="$(IFS=/; echo "$*")"
	answer_lists "$id" "$@"
	if ((${#ANS_OK[@]} == n_others)); then
		echo "${label} — **NO** (${id} answered 200 from \`${WORKLOAD_CTX}\` through $(join_ticks "${ANS_OK[@]}")'s ingress, without \`${NS_REMOTE}\` there)"
		return 0
	fi
	if ((${#ANS_FAIL[@]} == n_others)); then
		o="${ANS_FAIL[0]}"
		echo "${label} — **YES** (${id} returned \`${R[$o|$id|codes]}\` through $(join_ticks "${ANS_FAIL[@]}")'s ingress, while ${refs}, with the backend in the same namespace, answered 200)"
		return 0
	fi
	((${#ANS_OK[@]} == 0)) || why="${why}${id} answered 200 through $(join_ticks "${ANS_OK[@]}"); "
	((${#ANS_FAIL[@]} == 0)) || why="${why}${id} failed (${refs} answered) through $(join_ticks "${ANS_FAIL[@]}"); "
	((${#ANS_BROKEN[@]} == 0)) || why="${why}${id} and ${refs} all failed through $(join_ticks "${ANS_BROKEN[@]}"): the path to \`${NS_REMOTE}\` itself is broken (its istio-discovery label on the workload member?); "
	for o in "${ANS_UNCLEAR[@]}"; do
		rs="${R[$o|$id|row_status]}"
		case "$rs" in
		*NS_SCENARIO_INVALID*) why="${why}\`${o}\` has a \`${NS_REMOTE}\` namespace itself; " ;;
		*NS_SCENARIO_UNVERIFIED*) why="${why}could not read whether \`${o}\` has a \`${NS_REMOTE}\` namespace; " ;;
		*) why="${why}${id} through \`${o}\`: HTTP \`${R[$o|$id|codes]}\`, body match \`${R[$o|$id|body_match]}\`, row status \`${rs}\`; " ;;
		esac
	done
	echo "${label} — **INCONCLUSIVE** (${why%; })"
}

# Answer 2: is the backend's namespace needed on the ingress member? S7 (kind Service + a
# ReferenceGrant that can only live in that namespace), S8 (Hostname) and S9 (classic).
NS_HEADLINE="**Local namespace needed on the ingress cluster** (backend namespace \`${NS_REMOTE}\` only on \`${WORKLOAD_CTX}\`): $(ns_part "kind: Service" S7 S8 S9); $(ns_part "Hostname" S8 S9); $(ns_part "classic VirtualService" S9 S8)."

PREAMBLE_KV_RE='^# ([A-Za-z_][^=]*)=(.*)$'
{
	echo "---"
	# Frontmatter: every `# KEY=value` preamble line of the TSV (PL19), keys and values quoted.
	while IFS= read -r line; do
		[[ "$line" =~ $PREAMBLE_KV_RE ]] || continue
		k="${BASH_REMATCH[1]}"
		v="${BASH_REMATCH[2]}"
		v="${v//\\/\\\\}"
		v="${v//\"/\\\"}"
		printf '"%s": "%s"\n' "$k" "$v"
	done < <(awk '/^run_id\t/ { exit } { print }' "$TSV")
	echo "---"
	echo ""
	echo "# Gateway API multicluster ingress check — ${RUN_ID}"
	echo ""
	echo "$HEADLINE"
	echo ""
	echo "$NS_HEADLINE"
	echo ""
	for o in "${OTHERS[@]}"; do
		echo "- HTTPRoute status on \`${o}\` for S2, whose Service exists only on the workload member: \`${R[$o|S2|obs_status]}\` (predicted \`${R[$o|S2|exp_status]}\`)."
		echo "- Through \`${o}\`'s ingress, backend namespace \`${NS_REMOTE}\` $([[ "${PRE[$o|remote_namespace]}" == absent ]] && echo "absent there" || echo "state there: \`${PRE[$o|remote_namespace]}\`"): S7 HTTP \`${R[$o|S7|codes]}\`, status \`${R[$o|S7|obs_status]}\` (predicted \`${R[$o|S7|exp_status]}\`); S8 HTTP \`${R[$o|S8|codes]}\`, status \`${R[$o|S8|obs_status]}\`; S9 HTTP \`${R[$o|S9|codes]}\`."
	done
	echo "- Predictions: ${n_match} MATCH, ${n_dev} DEVIATION, ${n_unk} UNKNOWN of $((n_match + n_dev + n_unk)) rows."
	if [[ -f "${WORK}/argo.rows" ]]; then
		while IFS=$'\t' read -r app dst arole health sync _ hr; do
			echo "- Argo CD \`${app}\` (${arole}): health \`${health}\`, sync \`${sync}\`, HTTPRoutes \`$(md_safe "$hr")\`."
		done <"${WORK}/argo.rows"
	else
		echo "- Argo CD health: ${ARGO_STATE}."
	fi
	echo ""
	echo "## Matrix"
	echo ""
	echo "W = workload member. Status is the HTTPRoute's Accepted/ResolvedRefs (S1, S9: the classic VirtualService exists). HTTP is code:count over ${REQUESTS} requests. S7-S9's backends are in \`${NS_REMOTE}\`, which only the workload member has."
	echo ""
	echo "| Ingress | Role | Scenario | Host | Backend | Status: expected → observed | HTTP: expected → observed | Body | Endpoints: expected → observed (healthy) | Verdict |"
	echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
	for ctx in "${CONTEXTS[@]}"; do
		for line in "${SCENARIOS[@]}"; do
			IFS='|' read -r id _ host _ bkind backend bns _ <<<"$line"
			echo "| \`$(md_safe "$ctx")\` | $(role "$ctx") | ${id} | \`${host}\` | $(backend_label "$bkind" "$backend" "$bns") | \`${R[$ctx|$id|exp_status]}\` → \`${R[$ctx|$id|obs_status]}\` | ${R[$ctx|$id|exp_code]} → \`${R[$ctx|$id|codes]}\` | ${R[$ctx|$id|body_match]} | ${R[$ctx|$id|exp_ep]} → ${R[$ctx|$id|obs_ep]} (${R[$ctx|$id|ep_healthy]}) | **${R[$ctx|$id|verdict]}** |"
		done
	done
	echo ""
	echo "## Deviations from the predictions"
	echo ""
	nd=0
	for ctx in "${CONTEXTS[@]}"; do
		for line in "${SCENARIOS[@]}"; do
			IFS='|' read -r id _ host _ _ _ _ _ _ _ _ _ _ conf why <<<"$line"
			[[ "${R[$ctx|$id|verdict]}" != MATCH ]] || continue
			nd=$((nd + 1))
			echo "- **${R[$ctx|$id|verdict]}** \`$(md_safe "$ctx")\` ($(role "$ctx")) ${id} \`${host}\`: $(md_safe "${R[$ctx|$id|detail]}") (row status ${R[$ctx|$id|row_status]}). Prediction, ${conf} confidence: ${why}."
		done
	done
	((nd > 0)) || echo "None: every checked observation matched the prediction."
	echo ""
	echo "## Preflight (live, per member)"
	echo ""
	echo "| Member | Role | Gateway API CRD (bundle/channel) | GatewayClass istio | Gateway Programmed | Namespace labels | Echo Deployment | Backend namespace (S7-S9) | Echo there | Ingress address | Istio CR version |"
	echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		echo "| \`$(md_safe "$ctx")\` | $(role "$ctx") | ${PRE[$ctx|crd]} | ${PRE[$ctx|gatewayclass]} | $(gw_programmed "${FINAL_SNAP}/m${i}") | ${PRE[$ctx|namespace]} | ${PRE[$ctx|echo]}; sidecar=${PRE[$ctx|echo_sidecar]} | ${PRE[$ctx|remote_namespace]} | ${PRE[$ctx|echo_remote]}; sidecar=${PRE[$ctx|echo_remote_sidecar]} | ${INGRESS_SOURCE[$ctx]:-none} | ${PRE[$ctx|istio_cr_version]} |"
	done
	echo ""
	echo "istiod env overrides (\`unset\` = the Istio default):"
	echo ""
	for ctx in "${CONTEXTS[@]}"; do
		echo "- \`$(md_safe "$ctx")\`: \`${PRE[$ctx|istiod_env]}\`"
	done
	if [[ -f "${WORK}/argo.rows" ]]; then
		echo ""
		echo "## Argo CD health"
		echo ""
		echo "Workload cluster in the ApplicationSet: \`${WORKLOAD_CLUSTER}\`."
		echo ""
		echo "| Application | Destination | Role | Health | Sync | Revision | HTTPRoute health |"
		echo "| --- | --- | --- | --- | --- | --- | --- |"
		while IFS=$'\t' read -r app dst arole health sync rev hr; do
			echo "| \`${app}\` | \`${dst}\` | ${arole} | ${health} | ${sync} | \`${rev}\` | $(md_safe "$hr") |"
		done <"${WORK}/argo.rows"
	fi
	echo ""
	echo "## Run"
	echo ""
	echo "| Key | Value |"
	echo "| --- | --- |"
	echo "| Run ID | \`${RUN_ID}\` |"
	echo "| Run config | \`${RUN_CONFIG:-none}\` (sha256 \`${RUN_CONFIG_SHA256:-none}\`) |"
	echo "| Members | $(join_ticks "${CONTEXTS[@]}") (workload \`${WORKLOAD_CTX}\`) |"
	echo "| Requests per cell | ${REQUESTS}, curl --max-time ${TIMEOUT_SEC} s (detail ${GWAPI_DETAIL_TIMEOUT_SEC} s) |"
	echo "| Wait | ${WAIT_SEC} s of at most ${WAIT_TIMEOUT_SEC} s (timed out: ${WAIT_TIMED_OUT}) |"
	echo "| Endpoint evidence | ${PROXY_CONFIG_MODE} |"
	echo "| Expected body | \`${EXPECTED_BODY}\` (${EXPECTED_BODY_SOURCE}) |"
	echo "| Data | \`$(basename "$TSV")\`$([[ -f "$ARGO_TSV" ]] && echo ", \`$(basename "$ARGO_TSV")\`") |"
} >"$SUMMARY"

echo ""
echo "${HEADLINE//\*\*/}"
echo "${NS_HEADLINE//\*\*/}"
echo "Predictions: ${n_match} MATCH, ${n_dev} DEVIATION, ${n_unk} UNKNOWN."
echo "TSV:     ${TSV}"
echo "Summary: ${SUMMARY}"
