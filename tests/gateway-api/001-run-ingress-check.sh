#!/usr/bin/env bash
# Gateway API multicluster ingress check. Read-only: it deploys and changes nothing.
#
# Question: in this multi-primary, multi-network mesh, does an HTTPRoute need its backend
# Service in every member, or does a request entering ANY member's ingress reach the workload
# wherever it runs? And does the ingress member need the backend's NAMESPACE (S7-S9: a backend
# namespace that exists on the workload member only; S7b: a namespace with its ReferenceGrant on
# every member, its Service on the workload member only)? charts/mesh-verify-gateway-api, deployed
# by GitOps through charts/mesh-verify-gateway-api-appset.yaml, puts the routes on every member and
# the echo workload on one. This script reads what each member resolved, sends traffic through
# every member's ingress, and writes one TSV plus a markdown summary that leads with the answers.
# Scenarios, predictions and how to read the report: tests/gateway-api/README.md.
#
# Steps: (1) preflight: live Gateway API state, builds and preconditions per member, into the TSV
# preamble; stops when the check is not deployed or a member answers nothing. (2) A bounded wait
# for the Gateway, the echo Deployments and every route's status, then a data-plane gate (S1 and
# S3 through every ingress, GWAPI_GATE_PASSES rounds in a row) and GWAPI_SETTLE_SEC. (3)
# GWAPI_REQUESTS requests per member ingress x scenario host, and one re-probe after
# GWAPI_REPROBE_DELAY_SEC of each cell that did not answer and was predicted 200 or makes a YES
# when it fails (S7 through the other members). (4) Optional endpoint evidence (istioctl)
# and (5) Argo CD health (--hub-context); both are best effort. (6) The TSV and the summary
# under <results-dir>/run-<RUN_ID>/. A failure counts toward a "needed" answer only as the code
# of a dropped destination, repeated by the re-probe, on a route in place for the whole traffic
# window, for a scenario that works through the workload member (README, "Read the report").
#
# Usage:
#   ./tests/gateway-api/001-run-ingress-check.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
#     --workload-context <mesh-b-ctx> [--hub-context <hub-ctx>] [--dry-run]
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
# platform_probe, platform_pod_filter, platform_gitops_namespace: the platform record (operator
# build included), the builds' pod filter and the hub's Argo CD namespace.
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"

CONTEXTS_CSV="${SETUP_CONTEXTS}"
WORKLOAD_CTX="${GWAPI_WORKLOAD_CONTEXT}"
HUB_CTX="${GWAPI_HUB_CONTEXT}"
INGRESS_CSV="${GWAPI_INGRESS}"
REQUESTS="${GWAPI_REQUESTS}"
TIMEOUT_SEC="${GWAPI_TIMEOUT_SEC}"
WAIT_TIMEOUT_SEC="${GWAPI_WAIT_TIMEOUT_SEC}"
REPROBE_DELAY="${GWAPI_REPROBE_DELAY_SEC}"
RESULTS_DIR="$(config_repo_path "${GWAPI_RESULTS_DIR}")"
SKIP_PROXY_CONFIG="${GWAPI_SKIP_PROXY_CONFIG}"
NS="${GWAPI_NAMESPACE}"
NS_REMOTE="${GWAPI_REMOTE_NAMESPACE}"
NS_SHARED="${GWAPI_SHARED_NAMESPACE}"
GW_NAME="${GWAPI_GATEWAY}"
DRY_RUN=0
INGRESS_FROM_FLAG=0

# Fixed by the charts (do not override them there): the ingress gateway and its pod selector
# (charts/spoke-ingress-gateway), the echo label, the Service port (service.port) and the DNS
# domain suffix (clusterDomain) of charts/mesh-verify-gateway-api, and istiod's Gateway API
# controller name and pod label. The operators' namespaces are in tests/lib/platform.sh.
INGRESS_DEPLOY=istio-ingressgateway
INGRESS_SELECTOR=istio=ingressgateway
ECHO_SELECTOR=app=gwapi-echo
SVC_PORT=8080
GW_CONTROLLER=istio.io/gateway-controller
CLUSTER_DOMAIN=cluster.local
ISTIOD_SELECTOR=app=istiod
# Fixed by this script (not knobs: the bounds they poll within are --wait-timeout and
# GWAPI_GATE_PASSES). POLL_SEC: seconds between status polls in the wait (step 2).
# GATE_POLL_SEC: seconds between the data-plane gate's rounds per ingress (step 2), so
# DATAPLANE_READY_SEC resolves to this plus curl's latency. PC_SLOTS: ingresses whose endpoints
# are read and parsed at once (step 4): istioctl decodes Envoy's whole cluster dump and one jq pass
# over a 20k-cluster dump peaks near 0.5 GB, so 20 members at once would need about 10 GB on this
# host. A slot is held for one istioctl read and one jq pass, each bounded by
# GWAPI_ISTIOCTL_TIMEOUT_SEC, so the wait for a slot is bounded too (pc_slot).
POLL_SEC=5
GATE_POLL_SEC=1
PC_SLOTS=4
# 2: S7b, the shared backend namespace, endpoint class "direct" (was "local-pod"), the
# SVC_/SCENARIO_SET_/DATAPLANE_/RESTARTED row flags and their preamble keys. 3: a failure counts
# toward "needed" only as the code the hypothesis predicts, on a route in place for the whole
# traffic window, with the scenario working through the workload member; the gate takes S1 and S3
# GWAPI_GATE_PASSES times in a row; failed predicted-200 cells are re-probed; row flags
# STATUS_CHANGED, LATE_ENDPOINT, REPROBE_FAILED and *_UNVERIFIED; preamble DATAPLANE_GATE_HOSTS
# (was DATAPLANE_GATE_HOST), GATE_PASSES, REPROBE_CELLS; DATAPLANE_GATE_SEC no longer includes
# the settle. 4: a failure counts only when the re-probe repeats it (a fail on a re-probed cell
# whose re-probe answered otherwise is unclear); an HTTPRoute's 500 counts only with an empty body
# (Envoy's no-cluster reply); a cell that answered only on the re-probe counts as answered for a
# NO; the re-probe waits GWAPI_REPROBE_DELAY_SEC (preamble REPROBE_DELAY_SEC) and skips members
# whose gate never passed; detail always carries the re-probe's codes and, on a status change, the
# status the wait ended on. 5: S7 through the other members is re-probed too (REPROBE_CELLS counts
# it), so every YES rests on two probes; S7's failure counts only on a route that reads
# RefNotPermitted after the traffic; C1 is the 500 reference only with empty bodies; a queued cell
# whose re-probe left no record is unclear (row flag REPROBE_NO_RECORD). Same 21 columns.
GWAPI_SCHEMA=5
# The scenario set this script describes. The chart stamps its own on the namespaces and the
# Gateway (mesh-verify-gwapi/scenario-set, charts/mesh-verify-gateway-api/templates/_helpers.tpl);
# gateway-api.bats checks they are equal, and pins a sha256 of the chart's render for this set, so
# a render change without a bump fails CI. Bump both with any change to a scenario, host, route,
# backend or namespace (and the chart's version, and the pin: gateway-api.bats says how). A
# member whose deployed set differs gets SCENARIO_SET_MISMATCH rows.
SCENARIO_SET=v3
SCENARIO_SET_ANNOTATION=mesh-verify-gwapi/scenario-set

# Predicted outcomes (tests/gateway-api/README.md, "Predictions"), one row per scenario:
#   id|kind|host|route|backend kind|backend Service|backend namespace|status via W|status via O|
#   HTTP via W|HTTP via O|endpoints via W|endpoints via O|confidence|why
# W = the workload member, O = every other member; "via X" = on X / through X's ingress. Backend
# namespace: main (GWAPI_NAMESPACE, on every member; every route lives there), remote
# (GWAPI_REMOTE_NAMESPACE, on W only: the "is a local namespace needed?" scenarios) or shared
# (GWAPI_SHARED_NAMESPACE, on every member with its ReferenceGrant, the Service on W only). Status
# is the HTTPRoute's Accepted/ResolvedRefs from istio.io/gateway-controller ("present" = the
# classic VirtualService exists, "absent" = no route on that member). Endpoints: the ingress's EDS
# endpoints for the backend: direct (any port but 15443: a pod address), remote-ewgw:15443 (the
# workload member's east-west gateway) or none; "-" = not judged. Every expected 200 must carry
# the workload's echo text. On O, a main or shared backend Service must exist exactly when the
# status predicts a resolved Service-like backend there (S3's stub); the preflight reads it (M2).
# The chart (charts/mesh-verify-gateway-api/templates/_helpers.tpl) has the same ids, hosts,
# routes and backends; tests/lib/test/gateway-api.bats checks that they agree.
ST_OK="Accepted=True/ResolvedRefs=True"
ST_BNF="Accepted=True/ResolvedRefs=False:BackendNotFound"
ST_RNP="Accepted=True/ResolvedRefs=False:RefNotPermitted"
EP_DIRECT=direct
EP_REMOTE="remote-ewgw:15443"
SCENARIOS=(
	"S1|classic|s1.classic.test|s1|Service|echo-s1|main|present|present|200|200|${EP_DIRECT}|${EP_REMOTE}|high|classic Gateway + VirtualService: nothing checks that the Service exists"
	"S2|httproute|s2.gwapi.test|s2|Service|echo-s2|main|${ST_OK}|${ST_BNF}|200|200|${EP_DIRECT}|${EP_REMOTE}|high (status), medium (traffic)|BackendNotFound is a soft error: the destination is still programmed and resolved against every member's Services"
	"S3|httproute|s3.gwapi.test|s3|Service|echo-s3|main|${ST_OK}|${ST_OK}|200|200|${EP_DIRECT}|${EP_REMOTE}|high|the stub Service resolves the status and adds no endpoints"
	"S4|httproute|s4.gwapi.test|s4|Hostname|echo-s4|main|${ST_OK}|${ST_OK}|200|200|${EP_DIRECT}|${EP_REMOTE}|medium-high|the Hostname lookup uses the merged registry; it reads BackendNotFound until istiod's first push"
	"S5|httproute|s5.gwapi.test|s5|ServiceImport|echo-s5|main|${ST_OK}|${ST_BNF}|200|200|${EP_DIRECT}|${EP_REMOTE}|high|with ENABLE_MCS_HOST=false (default) a ServiceImport is handled exactly like kind Service"
	"S7|httproute|s7.gwapi.test|s7|Service|echo-s7|remote|${ST_OK}|${ST_RNP}|200|500|${EP_DIRECT}|${EP_REMOTE}|high|istiod reads ReferenceGrants from its own cluster only, and a grant can only live in the backend's namespace: without one the backendRef gets an empty destination (cluster UnknownService) and Gateway API's 500. The ingress still holds the backend's cluster with the workload member's east-west endpoint, so the 500 is the route's"
	"S7b|httproute|s7b.gwapi.test|s7b|Service|echo-s7b|shared|${ST_OK}|${ST_BNF}|200|200|${EP_DIRECT}|${EP_REMOTE}|high|the ReferenceGrant exists locally, so the grant check passes; the local Service lookup misses, and BackendNotFound is a soft error: the destination is kept (conversion.go:1143-1169) and returned with it (conversion.go:1262-1265). The positive control for S7: the namespace with its grant, not the Service"
	"S8|httproute|s8.gwapi.test|s8|Hostname|echo-s8|remote|${ST_BNF}|${ST_BNF}|200|200|${EP_DIRECT}|${EP_REMOTE}|medium-high|a Hostname backendRef has no namespace, so no grant check; its status lookup is keyed by the route's namespace, so it reads BackendNotFound on every member (istio/istio#62027), but the destination is still programmed"
	"S9|classic|s9.classic.test|s9|Service|echo-s9|remote|present|present|200|200|${EP_DIRECT}|${EP_REMOTE}|high|a classic VirtualService may name any host: no namespace or grant check"
	"C1|httproute|neg.gwapi.test|c1|Service|echo-none|main|${ST_BNF}|${ST_BNF}|500|500|none|none|high|negative control: no Service anywhere, so no Envoy cluster, and Gateway API routes answer 500"
	"C2|httproute|s6.gwapi.test|c2|Service|echo-s2|main|${ST_OK}|absent|200|404|${EP_DIRECT}|-|medium-high|route on the workload member only: routing config is per cluster, so the others answer 404"
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
  --contexts CSV          Mesh members, never the hub; at least two (default: \$SETUP_CONTEXTS).
  --workload-context CTX  The member that runs the echo workload, i.e. whose Argo CD cluster
                          name (on OpenShift: ACM ManagedCluster) is the chart's
                          workloadCluster; one of --contexts (default: \$GWAPI_WORKLOAD_CONTEXT).
  --hub-context CTX       Hub context: also read the Argo CD health of the per-member
                          Applications (best effort). Not one of --contexts.
                          (default: \$GWAPI_HUB_CONTEXT; empty = skip)
  --ingress CTX=ADDR      Ingress address of a member (host or IP, optional :PORT) when its
                          LoadBalancer status cannot be read. Repeatable, or CSV.
                          (default: \$GWAPI_INGRESS)
  --requests N            Requests per member ingress x scenario host
                          (default: \$GWAPI_REQUESTS, ${REQUESTS}).
  --timeout SEC           curl --max-time per request (default: \$GWAPI_TIMEOUT_SEC, ${TIMEOUT_SEC}).
                          A cell with a timed-out request gets one more request with
                          GWAPI_DETAIL_TIMEOUT_SEC (${GWAPI_DETAIL_TIMEOUT_SEC}): Envoy answers a dead
                          east-west hop only after 3 x 10 s connect timeouts (1 try + Istio's
                          default 2 retries).
  --wait-timeout SEC      Bound on the wait for the Gateway's Programmed condition, the echo
                          Deployments and istio's status on every route, and then on the
                          data-plane gate: S1 and S3 answering 200 through every ingress
                          GWAPI_GATE_PASSES (${GWAPI_GATE_PASSES}) times in a row (default:
                          \$GWAPI_WAIT_TIMEOUT_SEC, ${WAIT_TIMEOUT_SEC}; 0 = read once). Rows still
                          without status say STATUS_TIMEOUT; a member whose gate never passed
                          says DATAPLANE_NOT_READY.
  --results-dir DIR       Results base dir; the run writes DIR/run-<RUN_ID>/. A relative DIR
                          starts at the current directory (default: \$GWAPI_RESULTS_DIR,
                          ${GWAPI_RESULTS_DIR}).
  --skip-proxy-config     Skip the istioctl endpoint evidence (also skipped without istioctl)
                          (default: \$GWAPI_SKIP_PROXY_CONFIG=${GWAPI_SKIP_PROXY_CONFIG}).
  --dry-run               Validate the arguments and print the plan; no cluster is contacted.
  -h, --help              Show this help.

Environment:
  SETUP_CONTEXTS (--contexts), GWAPI_WORKLOAD_CONTEXT (--workload-context), GWAPI_HUB_CONTEXT
  (--hub-context), GWAPI_INGRESS (--ingress), GWAPI_REQUESTS (--requests), GWAPI_TIMEOUT_SEC
  (--timeout), GWAPI_WAIT_TIMEOUT_SEC (--wait-timeout), GWAPI_RESULTS_DIR (--results-dir; a
  relative value starts at the repo root), GWAPI_SKIP_PROXY_CONFIG (--skip-proxy-config).
  No flag: GWAPI_GATE_PASSES (rounds in a row the data-plane gate needs, ${GWAPI_GATE_PASSES}),
  GWAPI_SETTLE_SEC (pause after the gate, ${GWAPI_SETTLE_SEC} s), GWAPI_REPROBE_DELAY_SEC (pause
  after the traffic before the cells that did not answer are re-probed, ${REPROBE_DELAY} s),
  GWAPI_DETAIL_TIMEOUT_SEC, GWAPI_KUBECTL_TIMEOUT_SEC (kubectl --request-timeout,
  ${GWAPI_KUBECTL_TIMEOUT_SEC} s), GWAPI_ISTIOCTL_TIMEOUT_SEC (limit of the one istioctl dump per
  ingress, and of its parse, ${GWAPI_ISTIOCTL_TIMEOUT_SEC} s), GWAPI_NAMESPACE (${NS}),
  GWAPI_REMOTE_NAMESPACE (${NS_REMOTE}),
  GWAPI_SHARED_NAMESPACE (${NS_SHARED}), GWAPI_GATEWAY (${GW_NAME}),
  GWAPI_ARGOCD_NAMESPACE (${GWAPI_ARGOCD_NAMESPACE:-empty}; empty: the namespace of the hub's
  platform, openshift-gitops on OpenShift, else argocd), GWAPI_ARGOCD_APPSET (${GWAPI_ARGOCD_APPSET}).
  TEST_PLATFORM (${TEST_PLATFORM:-auto}): the hub's platform, for its Argo CD namespace (auto asks
  the hub; kubernetes or openshift is taken as given). The platform record asks each member what
  it serves either way, and warns when that is not TEST_PLATFORM.
$(platform_help_lines timeout)

Writes run-<RUN_ID>/gateway-api-<RUN_ID>.tsv (one row per member x scenario: expected vs
observed status, HTTP codes, body and endpoints, verdict MATCH/DEVIATION/UNKNOWN),
summary-<RUN_ID>.md (the answers first), argocd-<RUN_ID>.tsv with --hub-context, and
run-config-<RUN_ID>.env with --config.

Exit status: 0 whenever the report is written, whatever the answers; 1 on an argument error, a
member that answers no preflight read, or a check that is not deployed (nothing is written).
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
[[ -n "$WORKLOAD_CTX" ]] || die "--workload-context (or GWAPI_WORKLOAD_CONTEXT) is required: the member whose Argo CD cluster name (on OpenShift: ACM ManagedCluster) is the chart's workloadCluster"
[[ -n "${IS_MEMBER[$WORKLOAD_CTX]:-}" ]] || die "--workload-context ${WORKLOAD_CTX} is not one of --contexts (${CONTEXTS[*]})"
if [[ -n "$HUB_CTX" && -n "${IS_MEMBER[$HUB_CTX]:-}" ]]; then
	die "--hub-context ${HUB_CTX} is also in --contexts: --contexts lists mesh members only, never the hub"
fi
is_pos_int "$REQUESTS" || die "--requests (or GWAPI_REQUESTS) must be a positive integer; got '${REQUESTS}'"
is_pos_int "$TIMEOUT_SEC" || die "--timeout (or GWAPI_TIMEOUT_SEC) must be a positive integer; got '${TIMEOUT_SEC}'"
is_nonneg_int "$WAIT_TIMEOUT_SEC" || die "--wait-timeout (or GWAPI_WAIT_TIMEOUT_SEC) must be a non-negative integer; got '${WAIT_TIMEOUT_SEC}'"
is_pos_int "$GWAPI_DETAIL_TIMEOUT_SEC" || die "GWAPI_DETAIL_TIMEOUT_SEC must be a positive integer; got '${GWAPI_DETAIL_TIMEOUT_SEC}'"
is_pos_int "$GWAPI_KUBECTL_TIMEOUT_SEC" || die "GWAPI_KUBECTL_TIMEOUT_SEC must be a positive integer; got '${GWAPI_KUBECTL_TIMEOUT_SEC}'"
is_pos_int "$GWAPI_ISTIOCTL_TIMEOUT_SEC" || die "GWAPI_ISTIOCTL_TIMEOUT_SEC must be a positive integer; got '${GWAPI_ISTIOCTL_TIMEOUT_SEC}'"
is_nonneg_int "$GWAPI_SETTLE_SEC" || die "GWAPI_SETTLE_SEC must be a non-negative integer; got '${GWAPI_SETTLE_SEC}'"
is_nonneg_int "$REPROBE_DELAY" || die "GWAPI_REPROBE_DELAY_SEC must be a non-negative integer; got '${REPROBE_DELAY}'"
is_pos_int "$GWAPI_GATE_PASSES" || die "GWAPI_GATE_PASSES must be a positive integer; got '${GWAPI_GATE_PASSES}'"
[[ "$SKIP_PROXY_CONFIG" == 0 || "$SKIP_PROXY_CONFIG" == 1 ]] || die "GWAPI_SKIP_PROXY_CONFIG must be 0 or 1; got '${SKIP_PROXY_CONFIG}'"
platform_validate
DNS_LABEL_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
for kv in "GWAPI_NAMESPACE=${NS}" "GWAPI_REMOTE_NAMESPACE=${NS_REMOTE}" "GWAPI_SHARED_NAMESPACE=${NS_SHARED}" "GWAPI_GATEWAY=${GW_NAME}" "GWAPI_ARGOCD_NAMESPACE=${GWAPI_ARGOCD_NAMESPACE:-argocd}" "GWAPI_ARGOCD_APPSET=${GWAPI_ARGOCD_APPSET}"; do
	[[ "${kv#*=}" =~ $DNS_LABEL_RE ]] || die "${kv%%=*} must be a lowercase DNS label; got '${kv#*=}'"
done
[[ "$NS_REMOTE" != "$NS" ]] || die "GWAPI_REMOTE_NAMESPACE must differ from GWAPI_NAMESPACE (${NS}): S7-S9 need a backend namespace that exists on the workload member only"
[[ "$NS_SHARED" != "$NS" && "$NS_SHARED" != "$NS_REMOTE" ]] || die "GWAPI_SHARED_NAMESPACE must differ from GWAPI_NAMESPACE (${NS}) and GWAPI_REMOTE_NAMESPACE (${NS_REMOTE}): S7b needs a backend namespace of its own"
# Every answer needs a code on every request of a cell; with 1 or 2 requests a YES rests on that few.
((REQUESTS >= 3)) || warn "--requests ${REQUESTS} (or GWAPI_REQUESTS) is below 3: a YES then rests on ${REQUESTS} request(s) per probe (two probes) per member ingress and scenario"

# Ingress overrides: CTX=ADDR[:PORT]; a context name may hold ':' and '/', so split at the last '='.
# The results record only the source and the port (override:port=N), never the address.
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
	INGRESS_SOURCE[$ctx]="override:port=${BASH_REMATCH[2]#:}"
	[[ -n "${BASH_REMATCH[2]}" ]] || INGRESS_SOURCE[$ctx]="override:port=80"
done

# role <ctx>: workload or other.
role() { if [[ "$1" == "$WORKLOAD_CTX" ]]; then echo workload; else echo other; fi; }

# bns_name <main|remote|shared>: the backend namespace of a SCENARIOS row.
bns_name() {
	case "$1" in
	remote) echo "$NS_REMOTE" ;;
	shared) echo "$NS_SHARED" ;;
	*) echo "$NS" ;;
	esac
}

# svc_wanted_other <status via O> <backend kind>: whether a scenario's backend Service must exist
# on a member other than the workload member: present exactly when the status there predicts a
# resolved Service-like backend (S3's stub), else absent. The chart contract test in
# gateway-api.bats renders the same rule.
svc_wanted_other() {
	if [[ "$1" == *ResolvedRefs=True* && "$2" != Hostname ]]; then echo present; else echo absent; fi
}

# The unique backend hosts, for the endpoint evidence (filtered from one istioctl dump per member).
FQDNS=()
declare -A SEEN_FQDN=()
for line in "${SCENARIOS[@]}"; do
	IFS='|' read -r _ _ _ _ _ backend bns _ <<<"$line"
	fqdn="${backend}.$(bns_name "$bns").svc.${CLUSTER_DOMAIN}"
	[[ -n "${SEEN_FQDN[$fqdn]:-}" ]] && continue
	SEEN_FQDN[$fqdn]=1
	FQDNS+=("$fqdn")
done
# The same list as a JSON array, for the one jq pass over each dump (DNS names: nothing to escape).
printf -v FQDNS_JSON '"%s",' "${FQDNS[@]}"
FQDNS_JSON="[${FQDNS_JSON%,}]"

# backend_label <kind> <service> <main|remote>: the backendRef as the chart writes it; a backend
# outside the routes' namespace as <namespace>/<service>.
backend_label() {
	case "$1" in
	Hostname) echo "Hostname ${2}.$(bns_name "$3").svc.${CLUSTER_DOMAIN}" ;;
	*) if [[ "$3" != main ]]; then echo "$1 $(bns_name "$3")/$2"; else echo "$1 $2"; fi ;;
	esac
}

# The data-plane gate's references, whose 200s do not depend on either question: S1 (classic
# route) and S3 (HTTPRoute with a local stub Service, ResolvedRefs=True everywhere: its 200 shows
# the Gateway API listener and routes reached that ingress).
GATE_IDS=(S1 S3)
GATE_HOSTS=()
for gid in "${GATE_IDS[@]}"; do
	for line in "${SCENARIOS[@]}"; do
		IFS='|' read -r id _ host _ <<<"$line"
		[[ "$id" != "$gid" ]] || GATE_HOSTS+=("$host")
	done
done
GATE_LABEL="$(IFS=,; echo "${GATE_HOSTS[*]}")"
GATE_DESC="${GATE_HOSTS[0]} and ${GATE_HOSTS[1]}"

# PC_SLOT_WAIT: the longest wait for an endpoint-evidence slot (step 4): every round of PC_SLOTS
# holders takes at most one istioctl read and one jq pass, each GWAPI_ISTIOCTL_TIMEOUT_SEC.
PC_ROUNDS=$(((${#CONTEXTS[@]} + PC_SLOTS - 1) / PC_SLOTS))
PC_SLOT_WAIT=$((PC_ROUNDS * 2 * GWAPI_ISTIOCTL_TIMEOUT_SEC))

if ((DRY_RUN)); then
	proxy_plan="one istioctl proxy-config endpoints dump per ingress, ${PC_SLOTS} ingresses at a time, filtered for ${#FQDNS[@]} backends in one jq pass, ${GWAPI_ISTIOCTL_TIMEOUT_SEC} s limit on the read and on the parse (at most ${PC_SLOT_WAIT} s in all)"
	((SKIP_PROXY_CONFIG)) && proxy_plan="skipped (--skip-proxy-config)"
	argo_plan="skipped (no --hub-context)"
	[[ -n "$HUB_CTX" ]] && argo_plan="hub ${HUB_CTX}: Applications of ApplicationSet ${GWAPI_ARGOCD_NAMESPACE:-<Argo CD namespace of the hub platform: openshift-gitops on OpenShift, else argocd>}/${GWAPI_ARGOCD_APPSET}"
	pc_worst=0
	((SKIP_PROXY_CONFIG)) || pc_worst=$PC_SLOT_WAIT
	echo "=== Gateway API multicluster ingress check: dry run (no cluster is contacted) ==="
	echo "Members:        ${CONTEXTS[*]} (workload: ${WORKLOAD_CTX})"
	echo "Check objects:  namespaces ${NS} and ${NS_SHARED}, Gateway istio-system/${GW_NAME}; backend namespace ${NS_REMOTE} on ${WORKLOAD_CTX} only (charts/mesh-verify-gateway-api, scenario set ${SCENARIO_SET})"
	for ctx in "${CONTEXTS[@]}"; do
		if [[ -n "${INGRESS_ADDR[$ctx]:-}" ]]; then
			echo "Ingress ${ctx}: the --ingress override"
		else
			echo "Ingress ${ctx}: LoadBalancer status of istio-system/${INGRESS_DEPLOY}"
		fi
	done
	echo "Preflight:      Gateway API CRDs, GatewayClass istio, namespace labels and scenario set, ${NS_REMOTE} on the workload member only, ${NS_SHARED} and its ReferenceGrant everywhere, the backend Services on the other members, istiod env overrides, istiod/ingress builds and pods, the echo Deployments, Istio CR version, tuning baseline (kubectl --request-timeout ${GWAPI_KUBECTL_TIMEOUT_SEC}s); the platform record (platform, operator, istiod and gateway proxy builds, node provider; tests/lib/platform.sh; TEST_PLATFORM ${TEST_PLATFORM:-auto})"
	echo "Wait:           up to ${WAIT_TIMEOUT_SEC} s for Gateway Programmed, the echo Deployments Ready and every route's status (poll ${POLL_SEC} s), then ${GATE_DESC} answering 200 with the echo text through every ingress ${GWAPI_GATE_PASSES} time(s) in a row (same deadline; a streak under way may finish), then ${GWAPI_SETTLE_SEC} s settle"
	echo "Traffic:        ${REQUESTS} requests x ${#SCENARIOS[@]} hosts x ${#CONTEXTS[@]} ingresses, curl --max-time ${TIMEOUT_SEC}; one ${GWAPI_DETAIL_TIMEOUT_SEC} s detail request per cell with a timeout; then each cell that did not answer 200 with the echo text, predicted 200 or making a YES when it fails (S7 through the other members), is re-probed once (${REQUESTS} requests) after ${REPROBE_DELAY} s (not through an ingress whose gate never passed); a failure counts toward an answer only if its re-probe repeats it"
	echo "Proxy evidence: ${proxy_plan}"
	echo "Argo CD health: ${argo_plan}"
	echo "Worst case:     about $((WAIT_TIMEOUT_SEC + GWAPI_GATE_PASSES * (${#GATE_HOSTS[@]} * TIMEOUT_SEC + GATE_POLL_SEC) + GWAPI_SETTLE_SEC + REQUESTS * TIMEOUT_SEC + GWAPI_DETAIL_TIMEOUT_SEC + REPROBE_DELAY + REQUESTS * TIMEOUT_SEC + pc_worst)) s (wait and gate + settle + traffic + re-probe + evidence; cells and members run in parallel, the endpoint evidence ${PC_SLOTS} ingresses at a time; kubectl reads not included)"
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

# pf <keys> <ctx> <jq filter> <kubectl args...>: one bounded preflight read. Prints one
# "<key>\t<value>" line per key: the filter's tab-separated fields in key order (no field is
# empty), "absent" for NotFound, "unknown" for any other failure: never a false value for a query
# that did not answer (PL39). A failed read also appends "<first key>\t<kubectl error, masked>"
# to $PF_ERR, for the warnings and the stop on a member that answers nothing (U1).
pf() {
	local keyspec="$1" ctx="$2" filter="$3" tmp rc=0 v k i=0
	local -a pf_keys=() pf_fields=()
	shift 3
	read -r -a pf_keys <<<"$keyspec"
	tmp="$(mktemp "${WORK}/pf.XXXXXX")"
	kget "$ctx" "$tmp" "$@" || rc=$?
	if ((rc == 3)); then
		v=absent
	elif ((rc != 0)); then
		v=unknown
		printf '%s\t%s\n' "${pf_keys[0]}" "$(reach_sanitize "$(head -c 300 "${tmp}.err" 2>/dev/null)")" >>"$PF_ERR"
	else
		v="$(jq -r "$filter" "$tmp" 2>/dev/null)" || v=""
		v="${v%%$'\n'*}"
		if [[ -z "$v" ]]; then
			v=unknown
			printf '%s\t%s\n' "${pf_keys[0]}" "the reply did not parse" >>"$PF_ERR"
		fi
	fi
	rm -f "$tmp" "${tmp}.err"
	IFS=$'\t' read -r -a pf_fields <<<"$v"
	for k in "${pf_keys[@]}"; do
		printf '%s\t%s\n' "$k" "${pf_fields[i]:-${pf_fields[0]}}"
		i=$((i + 1))
	done
}

# --- Step 1: preflight (live state per member, recorded in the preamble: PL39) ---

# shellcheck disable=SC2016  # jq program: $c and $n are jq variables
ISTIOD_ENV_FILTER='[.items[].spec.template.spec.containers[]? | select(.name == "discovery")] as $c
	| if ($c | length) == 0 then "no-istiod" else
	  ["PILOT_ENABLE_GATEWAY_API", "PILOT_ENABLE_GATEWAY_API_STATUS", "PILOT_GATEWAY_API_CONTROLLER_NAME",
	   "ENABLE_GATEWAY_API_MANUAL_DEPLOYMENT", "PILOT_FILTER_GATEWAY_CLUSTER_CONFIG", "PILOT_SCOPE_GATEWAY_TO_NAMESPACE",
	   "PILOT_MULTI_NETWORK_DISCOVER_GATEWAY_API", "ENABLE_MCS_HOST", "ENABLE_MCS_SERVICE_DISCOVERY", "ENABLE_MCS_CLUSTER_LOCAL"]
	  | map(. as $n | "\($n)=" + ([$c[] | ([.env[]? | select(.name == $n)][0])
	      | if . == null then "unset" elif has("value") then (.value | tostring) else "valueFrom" end] | unique | join("|")))
	  | join(";") end'
ECHO_FILTER='if (.items | length) == 0 then "absent\t-" else (.items[0]
	| "ready=\(.status.readyReplicas // 0)/\(.spec.replicas // 0)\t\(([.spec.template.spec.containers[]? | select(.name == "http-echo")
	| .args[]? | select(startswith("-text=")) | sub("^-text="; "")][0]) // "-")") end'
CRD_FILTER='"\(.metadata.annotations["gateway.networking.k8s.io/bundle-version"] // "unversioned")/\(.metadata.annotations["gateway.networking.k8s.io/channel"] // "unknown-channel")"'
NS_LABEL_FILTER='"istio-discovery=\(.metadata.labels["istio-discovery"] // "unset");istio.io/rev=\(.metadata.labels["istio.io/rev"] // "unset")"'
# The test namespace: its labels, and the scenario set the chart stamped on it (R2).
NS_FILTER="${NS_LABEL_FILTER}"' + "\t" + (.metadata.annotations["'"${SCENARIO_SET_ANNOTATION}"'"] // "unset")'
GW_FILTER='"present\t" + (.metadata.annotations["'"${SCENARIO_SET_ANNOTATION}"'"] // "unset")'
SIDECAR_FILTER='if (.items | length) == 0 then "no-pods" else ([.items[] | ((.spec.containers // []) + (.spec.initContainers // []))
	| map(.name) | index("istio-proxy") != null] | if all then "yes" elif any then "partial" else "no" end) end'
# Names of a list's items (Services, ReferenceGrants), sorted; "none" for an empty list.
NAME_LIST_FILTER='[.items[]?.metadata.name] | sort | if length == 0 then "none" else join(",") end'

# preflight_member <i> <ctx>: writes key<TAB>value lines to $WORK/pre-<i>.kv and the failed
# reads to $WORK/pre-<i>.err.
preflight_member() {
	local i="$1" ctx="$2" tb
	PF_ERR="${WORK}/pre-${i}.err"
	: >"$PF_ERR"
	{
		pf "namespace scenario_set_ns" "$ctx" "$NS_FILTER" get namespace "$NS"
		pf crd "$ctx" "$CRD_FILTER" \
			get crd httproutes.gateway.networking.k8s.io
		# A member that answers neither read is misnamed or unreachable: skip the rest (they stay
		# unknown) instead of waiting out the kubectl timeout once per read; the run stops below.
		# A slow API server can miss both, so the first read is retried once before that; when it
		# answers, the CRD read is redone too (a later line wins over the earlier unknown).
		if (($(wc -l <"$PF_ERR") >= 2)); then
			: >"$PF_ERR"
			pf "namespace scenario_set_ns" "$ctx" "$NS_FILTER" get namespace "$NS"
			[[ ! -s "$PF_ERR" ]] || return 0
			pf crd "$ctx" "$CRD_FILTER" \
				get crd httproutes.gateway.networking.k8s.io
		fi
		pf gatewayclass "$ctx" '"\(.spec.controllerName);Accepted=\(([.status.conditions[]? | select(.type == "Accepted")][0].status) // "missing")"' \
			get gatewayclasses.gateway.networking.k8s.io istio
		pf "gateway scenario_set_gw" "$ctx" "$GW_FILTER" -n istio-system get gateways.gateway.networking.k8s.io "$GW_NAME"
		# S7-S9's backend namespace: expected on the workload member only ("absent" elsewhere).
		pf remote_namespace "$ctx" "$NS_LABEL_FILTER" get namespace "$NS_REMOTE"
		# S7b's backend namespace and its ReferenceGrant: expected on every member.
		pf shared_namespace "$ctx" "$NS_LABEL_FILTER" get namespace "$NS_SHARED"
		pf shared_grants "$ctx" "$NAME_LIST_FILTER" -n "$NS_SHARED" get referencegrants.gateway.networking.k8s.io
		# The backend Services the scenarios assume absent (or, S3's stub, present) on the other
		# members: read directly, not inferred from a route status (M2).
		pf svc_main "$ctx" "$NAME_LIST_FILTER" -n "$NS" get svc
		pf svc_shared "$ctx" "$NAME_LIST_FILTER" -n "$NS_SHARED" get svc
		pf istiod_env "$ctx" "$ISTIOD_ENV_FILTER" -n istio-system get deploy -l "$ISTIOD_SELECTOR"
		# The builds that ran (R1) and the pod fingerprints for restart detection (PL9). The
		# operator build comes from the platform record (platform_probe, below).
		pf "istiod_image istiod_fp" "$ctx" "$(platform_pod_filter discovery)" -n istio-system get pods -l "$ISTIOD_SELECTOR"
		pf "ingress_image ingress_fp ingress_replicas ingress_pod" "$ctx" "$(platform_pod_filter istio-proxy)" \
			-n istio-system get pods -l "$INGRESS_SELECTOR"
		pf istio_cr_version "$ctx" '.spec.version // "unset"' get istios.sailoperator.io default
		pf "echo echo_text" "$ctx" "$ECHO_FILTER" -n "$NS" get deploy -l "$ECHO_SELECTOR"
		pf echo_sidecar "$ctx" "$SIDECAR_FILTER" -n "$NS" get pods -l "$ECHO_SELECTOR"
		pf echo_remote "$ctx" "$ECHO_FILTER" -n "$NS_REMOTE" get deploy -l "$ECHO_SELECTOR"
		pf echo_remote_sidecar "$ctx" "$SIDECAR_FILTER" -n "$NS_REMOTE" get pods -l "$ECHO_SELECTOR"
		pf echo_shared "$ctx" "$ECHO_FILTER" -n "$NS_SHARED" get deploy -l "$ECHO_SELECTOR"
		pf echo_shared_sidecar "$ctx" "$SIDECAR_FILTER" -n "$NS_SHARED" get pods -l "$ECHO_SELECTOR"
		# The address stays in memory and $WORK: results record only where it came from.
		pf ingress_lb "$ctx" '.status.loadBalancer.ingress[0] // {} | .hostname // .ip // "pending"' \
			-n istio-system get svc "$INGRESS_DEPLOY"
		tb="$(tuning_baseline_state "$ctx" "${KUBECTL[@]}" 2>/dev/null)" || tb=""
		printf 'tuning_baseline\t%s\n' "$(sed -n 's/^TUNING_BASELINE=//p' <<<"$tb" | head -1)"
		printf 'sidecar_egress_hosts\t%s\n' "$(sed -n 's/^SIDECAR_EGRESS_HOSTS=//p' <<<"$tb" | head -1)"
	} >"${WORK}/pre-${i}.kv"
}

echo "Run ${RUN_ID}: preflight on ${CONTEXTS[*]} (workload: ${WORKLOAD_CTX}); results will go to ${OUT_DIR}" >&2
declare -A PRE=()
pids=()
for i in "${!CONTEXTS[@]}"; do
	(preflight_member "$i" "${CONTEXTS[i]}") 2>"${WORK}/pre-${i}.stderr" &
	pids+=("$!")
done
# The platform record (tests/lib/platform.sh), read while the preflight runs: the platform, the
# operator build (the Sail operator Deployment on Kubernetes, the OSSM CSV on OpenShift; unknown,
# with a warning, when the platform or the read is unknown, never a false absent) and the rest.
platform_probe "$(IFS=,; echo "${CONTEXTS[*]}")"
for p in "${pids[@]}"; do wait "$p" || true; done
KUBE_VERSIONS="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
PREFLIGHT_KEYS=(namespace scenario_set_ns crd gatewayclass gateway scenario_set_gw remote_namespace shared_namespace
	shared_grants svc_main svc_shared istiod_env istiod_image istiod_fp ingress_image ingress_fp ingress_replicas ingress_pod
	ossm_operator istio_cr_version echo echo_text echo_sidecar echo_remote echo_remote_sidecar echo_shared
	echo_shared_sidecar ingress_lb tuning_baseline sidecar_egress_hosts)
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	for k in "${PREFLIGHT_KEYS[@]}"; do PRE["${ctx}|${k}"]=unknown; done
	if [[ -f "${WORK}/pre-${i}.kv" ]]; then
		while IFS=$'\t' read -r k v; do
			[[ -n "$k" ]] && PRE["${ctx}|${k}"]="${v:-unknown}"
		done <"${WORK}/pre-${i}.kv"
	fi
	PRE["${ctx}|ossm_operator"]="$(platform_member_value "$ctx" operator)"
done

# A member that answered none of the reads (a mistyped context, an API server that cannot be
# reached, no access) stops the run before anything is written, with kubectl's own words (U1).
dead=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	answered=0
	for k in "${PREFLIGHT_KEYS[@]}"; do
		# The tuning baseline is the lib's own composite (never plain "unknown") and the operator
		# build the platform record's (which warned for it): not reads here.
		case "$k" in tuning_baseline | sidecar_egress_hosts | ossm_operator) continue ;; esac
		if [[ "${PRE[$ctx|$k]}" != unknown ]]; then
			answered=1
			break
		fi
	done
	((answered == 0)) || continue
	first="$(head -n 1 "${WORK}/pre-${i}.err" 2>/dev/null | cut -f2-)"
	dead+=("${ctx} answered none of the preflight reads; first kubectl error: ${first:-none recorded}")
done
if ((${#dead[@]})); then
	for p in "${dead[@]}"; do echo "error: ${p}" >&2; done
	die "check the context names (kubectl config get-contexts), each member's API server and GWAPI_KUBECTL_TIMEOUT_SEC (${GWAPI_KUBECTL_TIMEOUT_SEC} s). Nothing was written."
fi
for i in "${!CONTEXTS[@]}"; do
	while IFS=$'\t' read -r k err; do
		[[ -n "$k" ]] && warn "${CONTEXTS[i]}: could not read ${k} (recorded as unknown): ${err}"
	done <"${WORK}/pre-${i}.err"
done

# The deployed scenario set per member (R2): the chart's stamp on the test namespace and on the
# Gateway. A member whose stamp differs runs other chart content than this script describes; its
# rows say SCENARIO_SET_MISMATCH (every member's rows when it is the workload member, which
# holds every backend). An unreadable stamp is recorded as unknown, not as a match: its rows say
# SCENARIO_SET_UNVERIFIED, so a deviation or a failure there is not judged (every member's when
# it is the workload member's stamp).
declare -A DEPLOYED_SET=() SET_MISMATCH=() SET_UNVERIFIED=()
set_mismatch_wl=0 set_unverified_wl=0
for ctx in "${CONTEXTS[@]}"; do
	a="${PRE[$ctx|scenario_set_ns]}" b="${PRE[$ctx|scenario_set_gw]}"
	if [[ "$a" == "$b" ]]; then DEPLOYED_SET[$ctx]="$a"; else DEPLOYED_SET[$ctx]="namespace=${a};gateway=${b}"; fi
	case "$a/$b" in
	unknown/* | */unknown)
		SET_UNVERIFIED[$ctx]=1
		[[ "$ctx" != "$WORKLOAD_CTX" ]] || set_unverified_wl=1
		warn "${ctx}: could not read the deployed scenario set (${DEPLOYED_SET[$ctx]}); $([[ "$ctx" == "$WORKLOAD_CTX" ]] && echo "every member's rows" || echo "its rows") say SCENARIO_SET_UNVERIFIED, and a deviation or a failure there is not judged"
		continue
		;;
	absent/* | */absent) continue ;;
	esac
	[[ "$a" != "$SCENARIO_SET" || "$b" != "$SCENARIO_SET" ]] || continue
	SET_MISMATCH[$ctx]=1
	[[ "$ctx" != "$WORKLOAD_CTX" ]] || set_mismatch_wl=1
	warn "${ctx}: the deployed chart is not the version this script expects: scenario set ${DEPLOYED_SET[$ctx]}, expected ${SCENARIO_SET}. Sync the chart revision that matches this script (or run the script from the chart's revision); $([[ "$ctx" == "$WORKLOAD_CTX" ]] && echo "every member's rows" || echo "its rows") say SCENARIO_SET_MISMATCH."
done
if ((set_mismatch_wl)); then
	for ctx in "${CONTEXTS[@]}"; do SET_MISMATCH[$ctx]=1; done
fi
if ((set_unverified_wl)); then
	for ctx in "${CONTEXTS[@]}"; do SET_UNVERIFIED[$ctx]=1; done
fi

# Stop when the check is not deployed (a whole-run precondition: nothing is written).
problems=()
for ctx in "${CONTEXTS[@]}"; do
	[[ "${PRE[$ctx|crd]}" != absent ]] || problems+=("${ctx}: no Gateway API CRDs (httproutes.gateway.networking.k8s.io): install the standard channel (tests/gateway-api/README.md, Deploy)")
	[[ "${PRE[$ctx|namespace]}" != absent ]] || problems+=("${ctx}: namespace ${NS} is missing")
	[[ "${PRE[$ctx|gateway]}" != absent ]] || problems+=("${ctx}: Gateway istio-system/${GW_NAME} is missing")
	case "${PRE[$ctx|gatewayclass]}" in
	unknown | absent | "${GW_CONTROLLER};"*) ;;
	*) warn "${ctx}: GatewayClass istio is ${PRE[$ctx|gatewayclass]}, but the status reads look for ${GW_CONTROLLER}: its routes will read no-status (see ISTIOD_ENV PILOT_GATEWAY_API_CONTROLLER_NAME)" ;;
	esac
	if [[ "$ctx" == "$WORKLOAD_CTX" ]]; then
		[[ "${PRE[$ctx|echo]}" != absent ]] || problems+=("${ctx} (--workload-context): no echo Deployment (${ECHO_SELECTOR}) in ${NS}; the chart's workloadCluster must be this member's cluster name (Argo CD cluster; on OpenShift ACM ManagedCluster)")
		if [[ "${PRE[$ctx|remote_namespace]}" == absent ]]; then
			problems+=("${ctx} (--workload-context): namespace ${NS_REMOTE} (the S7-S9 backends) is missing; sync a chart revision that renders it")
		elif [[ "${PRE[$ctx|echo_remote]}" == absent ]]; then
			problems+=("${ctx} (--workload-context): no echo Deployment (${ECHO_SELECTOR}) in ${NS_REMOTE}")
		fi
		if [[ "${PRE[$ctx|shared_namespace]}" == absent ]]; then
			problems+=("${ctx} (--workload-context): namespace ${NS_SHARED} (the S7b backend) is missing; sync a chart revision that renders it")
		elif [[ "${PRE[$ctx|echo_shared]}" == absent ]]; then
			problems+=("${ctx} (--workload-context): no echo Deployment (${ECHO_SELECTOR}) in ${NS_SHARED}")
		fi
	else
		if [[ "${PRE[$ctx|echo]}" != absent && "${PRE[$ctx|echo]}" != unknown ]]; then
			problems+=("${ctx}: runs the echo Deployment, but --workload-context is ${WORKLOAD_CTX}; pass the member whose cluster name is the chart's workloadCluster")
		fi
		# Not stops: only the scenarios that depend on them, and their rows on this member say so.
		case "${PRE[$ctx|remote_namespace]}" in
		absent) ;;
		unknown) warn "${ctx}: could not read whether namespace ${NS_REMOTE} exists; its S7-S9 rows say NS_SCENARIO_UNVERIFIED" ;;
		*) warn "${ctx}: namespace ${NS_REMOTE} exists here, but S7-S9 need it on the workload member only; its S7-S9 rows say NS_SCENARIO_INVALID" ;;
		esac
		case "${PRE[$ctx|shared_namespace]}" in
		unknown) ;;
		absent) warn "${ctx}: namespace ${NS_SHARED} is missing here, but S7b needs it (with its ReferenceGrant) on every member; its S7b row says NS_SCENARIO_INVALID" ;;
		esac
	fi
done
if ((${#problems[@]})); then
	for p in "${problems[@]}"; do echo "error: ${p}" >&2; done
	die "the check is not deployed as expected (above). Deploy it from the hub: edit and apply charts/mesh-verify-gateway-api-appset.yaml (tests/gateway-api/README.md, \"Deploy\"). Nothing was written."
fi

# --- Step 2: bounded wait for the Gateway, the echo Deployments and every route's status (PL4),
# then the data-plane gate ---

# snap_get <ctx> <out> <kubectl args...>: kget, with its return code saved in <out>.rc.
snap_get() {
	local rc=0
	kget "$@" || rc=$?
	echo "$rc" >"${2}.rc"
}

# snapshot_all <dir> [pods]: read every member's Gateway, routes, VirtualServices (and the echo
# Deployments on the workload member) into <dir>/m<i>/, members in parallel; with "pods" also
# the istiod and ingress pods (the final read, for restart detection).
snapshot_all() {
	local dir="$1" pods="${2:-}" i ctx d p
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
				snap_get "$ctx" "${d}/echo-shared.json" -n "$NS_SHARED" get deploy -l "$ECHO_SELECTOR"
			fi
			if [[ "$pods" == pods ]]; then
				snap_get "$ctx" "${d}/istiod-pods.json" -n istio-system get pods -l "$ISTIOD_SELECTOR"
				snap_get "$ctx" "${d}/ingress-pods.json" -n istio-system get pods -l "$INGRESS_SELECTOR"
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

# in_place_status <status>: whether a route_status/vs_status value means the route is in place:
# an HTTPRoute that istio Accepted, or a classic VirtualService that exists.
in_place_status() { [[ "$1" == Accepted=True* || "$1" == present ]]; }
# status_text <status>: a status for the prose; a failed read ("unknown") was unread, not absent.
status_text() { if [[ "$1" == unknown ]]; then echo unread; else echo "$1"; fi; }

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
		(($(echo_ready "${d}/echo-shared.json") >= 1)) || out="${out:+${out}, }echo in ${NS_SHARED} not Ready"
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

echo "Waiting up to ${WAIT_TIMEOUT_SEC} s for the Gateway, the echo Deployments and the route status..." >&2
WAIT_SNAP="${WORK}/snap-wait"
WAIT_START=$SECONDS
WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SEC))
WAIT_TIMED_OUT=0
last_pending=""
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
	# Progress only when it changes, with the time spent against the bound.
	[[ "$pending" == "$last_pending" ]] || echo "  [$((SECONDS - WAIT_START))/${WAIT_TIMEOUT_SEC} s] pending: ${pending}" >&2
	last_pending="$pending"
	sleep "$POLL_SEC"
done
WAIT_SEC=$((SECONDS - WAIT_START))

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

# Data-plane gate (SC1). The control plane being settled does not mean every ingress already has
# the workload member's east-west endpoint: that EDS push starts when the echo pod turns Ready
# and can take seconds per member at scale. Each round requests S1 (classic) and S3 (HTTPRoute,
# local stub Service), whose 200s depend on neither question, through every ingress, members in
# parallel. The gate passes after GWAPI_GATE_PASSES rounds in a row where both answer 200 with
# the echo text (curl may reach any ingress replica, and each istiod replica pushes on its own).
# The wait's deadline ends it at the first failed round after the deadline (at least one round
# each; a streak under way may finish). Then GWAPI_SETTLE_SEC for the other backends' pushes.
# DATAPLANE_READY_SEC: seconds from the gate's start until it passed, "timeout" when it never
# did, "unknown" for an ingress without an address; it includes the GWAPI_GATE_PASSES - 1
# confirming rounds, so an ingress ready from the start reads about that many rounds. A member
# that timed out has DATAPLANE_NOT_READY rows, so a failure there is not blamed on a scenario.
# Each member prints one line when it passes (the timeouts are warned about after the gate).
GATE_BODY="${PRE[$WORKLOAD_CTX|echo_text]}"
case "$GATE_BODY" in "" | - | unknown | absent) GATE_BODY="" ;; esac
# gate_member <i> <ctx> <start>: writes the member's DATAPLANE_READY_SEC to $WORK/gate-<i>; on a
# timeout also "<1 if any request got an HTTP answer, else 0>\t<last round's codes>" to
# $WORK/gate-<i>.last.
gate_member() {
	local i="$1" ctx="$2" start="$3" code h ok passes=0 answered=0 last b="${WORK}/gate-${1}.body"
	while :; do
		ok=1 last=""
		for h in "${GATE_HOSTS[@]}"; do
			: >"$b"
			code="$(curl -sS -o "$b" -w '%{http_code}' --max-time "$TIMEOUT_SEC" -H "Host: ${h}" "http://${ADDR[$ctx]}/" 2>/dev/null)" || true
			[[ "$code" =~ ^[0-9]{3}$ ]] || code=000
			[[ "$code" == 000 ]] || answered=1
			last="${last:+${last}, }${h} ${code}"
			if [[ "$code" != 200 ]] || { [[ -n "$GATE_BODY" ]] && [[ "$(head -n 1 "$b" 2>/dev/null | tr -d '\r')" != "$GATE_BODY" ]]; }; then
				ok=0
			fi
		done
		if ((ok)); then passes=$((passes + 1)); else passes=0; fi
		if ((passes >= GWAPI_GATE_PASSES)); then
			echo "$((SECONDS - start))" >"${WORK}/gate-${i}"
			echo "  ${ctx}: the data-plane gate passed after $((SECONDS - start)) s (${GWAPI_GATE_PASSES} round(s) in a row)" >&2
			return 0
		fi
		if ((passes == 0 && SECONDS >= WAIT_DEADLINE)); then
			echo timeout >"${WORK}/gate-${i}"
			printf '%s\t%s\n' "$answered" "$last" >"${WORK}/gate-${i}.last"
			return 0
		fi
		sleep "$GATE_POLL_SEC"
	done
}
echo "Data-plane gate: ${GATE_DESC} through every ingress, ${GWAPI_GATE_PASSES} round(s) in a row (until $((WAIT_DEADLINE > SECONDS ? WAIT_DEADLINE - SECONDS : 0)) s from now), then ${GWAPI_SETTLE_SEC} s settle..." >&2
GATE_START=$SECONDS
pids=()
for i in "${!CONTEXTS[@]}"; do
	[[ -n "${ADDR[${CONTEXTS[i]}]:-}" ]] || continue
	gate_member "$i" "${CONTEXTS[i]}" "$GATE_START" &
	pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || true; done
GATE_SEC=$((SECONDS - GATE_START))
declare -A DP_READY=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	DP_READY[$ctx]="$(cat "${WORK}/gate-${i}" 2>/dev/null || echo unknown)"
	[[ "${DP_READY[$ctx]}" == timeout ]] || continue
	IFS=$'\t' read -r answered last <"${WORK}/gate-${i}.last" || answered=1 last=""
	if ((answered == 0)); then
		warn "${ctx}: no HTTP answer from this ingress during the data-plane gate (every request timed out or was refused); its rows say DATAPLANE_NOT_READY. Check that the address is reachable from here, or pass --ingress ${ctx}=ADDR[:PORT]"
	else
		warn "${ctx}: ${GATE_DESC} did not answer 200 with the echo text through its ingress ${GWAPI_GATE_PASSES} time(s) in a row before the wait's deadline (last round: ${last}); its rows say DATAPLANE_NOT_READY (the cross-cluster path was not ready; check mesh-verify and the east-west gateways, or raise --wait-timeout)"
	fi
done
((GWAPI_SETTLE_SEC == 0)) || sleep "$GWAPI_SETTLE_SEC"

# --- Step 3: traffic through every member's ingress ---

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
TRAFFIC_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
TRAFFIC_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# An ingress where every request of every host timed out is unreachable from here, which says
# nothing about the mesh: its rows are UNKNOWN (INGRESS_UNREACHABLE), not deviations.
declare -A INGRESS_DEAD=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	[[ -n "${ADDR[$ctx]:-}" ]] || continue
	if ! grep -qsv '^000' "${WORK}/cell-${i}-"*.txt; then
		INGRESS_DEAD[$ctx]=1
		warn "${ctx}: no request through its ingress got an HTTP answer; its rows say INGRESS_UNREACHABLE. Check that the address is reachable from here, or pass --ingress ${ctx}=ADDR[:PORT]"
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

# Late endpoints: the gate covers the main namespace's echo pod only; the S7-S9 and S7b pods are
# others whose EDS pushes can land after the traffic started. Each cell that did not answer 200
# with the echo text on every request is re-probed once (REQUESTS requests) after
# GWAPI_REPROBE_DELAY_SEC, in parallel, when it was predicted 200 or its failure counts toward a
# YES although predicted (YES_IDS: S7 through the other members), so every YES rests on two
# probes; not through an ingress whose gate never passed (its rows are tainted anyway). A cell
# that passes then says LATE_ENDPOINT: predicted 200, it is UNKNOWN, never a DEVIATION, and counts
# as answered for a NO; predicted to fail (S7), it is unclear. One that fails again says so
# (REPROBE_FAILED); either way its failure counts toward a YES only when the re-probe repeats it
# (cell_state). A queued cell whose re-probe left no record is unclear (REPROBE_NO_RECORD).
# YES_IDS: the scenarios whose failure through another member makes a YES (member_answer).
YES_IDS=" S2 S7 S7b S8 S9 "
# cell_passed <cell file>: every request answered 200 with the echo text (when it is known).
cell_passed() {
	awk -F'\t' -v e="$EXPECTED_BODY" '{ n++; if ($1 != "200" || (e != "unknown" && $2 != e)) bad++ } END { exit !(n > 0 && bad == 0) }' "$1" 2>/dev/null
}
REPROBE=()
declare -A REPROBED=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	[[ -n "${ADDR[$ctx]:-}" && -z "${INGRESS_DEAD[$ctx]:-}" && "${DP_READY[$ctx]:-unknown}" != timeout ]] || continue
	for s in "${!SCENARIOS[@]}"; do
		IFS='|' read -r id _ _ _ _ _ _ _ _ code_w code_o _ <<<"${SCENARIOS[s]}"
		if [[ "$ctx" == "$WORKLOAD_CTX" ]]; then exp_code="$code_w"; else exp_code="$code_o"; fi
		[[ "$exp_code" == 200 || "$YES_IDS" == *" ${id} "* ]] || continue
		[[ -s "${WORK}/cell-${i}-${s}.txt" ]] || continue
		if ! cell_passed "${WORK}/cell-${i}-${s}.txt"; then
			REPROBE+=("${i}|${s}")
			REPROBED["${i}|${s}"]=1
		fi
	done
done
REPROBE_CELLS=${#REPROBE[@]}
if ((REPROBE_CELLS)); then
	echo "Re-probe: ${REPROBE_CELLS} cell(s) did not answer 200 with the echo text (predicted 200, or S7 through the other members); once more after ${REPROBE_DELAY} s..." >&2
	((REPROBE_DELAY == 0)) || sleep "$REPROBE_DELAY"
	pids=()
	for c in "${REPROBE[@]}"; do
		i="${c%|*}" s="${c#*|}"
		IFS='|' read -r _ _ host _ <<<"${SCENARIOS[s]}"
		probe_cell "${ADDR[${CONTEXTS[i]}]}" "$host" "${WORK}/reprobe-${i}-${s}.txt" &
		pids+=("$!")
	done
	for p in "${pids[@]}"; do wait "$p" || true; done
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

# Endpoint class per backend from an istioctl `proxy-config endpoints -o json` dump
# (ClusterStatuses), in ONE jq pass over the dump (at >=1000 Services it holds every cluster of
# the mesh): one "<fqdn>\t<class>\t<total>\t<healthy>" line per FQDN of $fqdns. Class:
# remote-ewgw:15443 (the workload member's east-west gateway), direct (any other port: a pod
# address; on another member than the workload member that means the ingress lacks the workload
# member's network metadata), mixed, or none (no such cluster, or no endpoint). The addresses
# themselves are never recorded.
# shellcheck disable=SC2016  # jq program
PC_FILTER='($fqdns | map({key: ("outbound|\($port)||" + .), value: true}) | from_entries) as $want
	| (reduce (.[]? | select($want[.name // ""] == true)) as $c ({}; .[$c.name] += ($c.hostStatuses // []))) as $idx
	| $fqdns[] as $f
	| ($idx["outbound|\($port)||" + $f] // []) as $h
	| ($h | length) as $n
	| ($h | map(select(((.healthStatus.edsHealthStatus // "UNKNOWN") as $s | $s == "HEALTHY" or $s == "UNKNOWN")
		and ((.healthStatus.failedOutlierCheck // false) | not))) | length) as $ok
	| ($h | map(if (.address.socketAddress.portValue // 0) == 15443 then "remote-ewgw:15443" else "direct" end) | unique) as $cls
	| "\($f)\t\(if $n == 0 then "none" elif ($cls | length) == 1 then $cls[0] else "mixed" end)\t\($n)\t\($ok)"'

# The ingress pod istioctl reads: the preflight's first Running pod (curl may reach any replica;
# INGRESS_REPLICAS says how many there were), else the Deployment (istioctl picks a pod).
declare -A PC_POD=()
for ctx in "${CONTEXTS[@]}"; do
	case "${PRE[$ctx|ingress_pod]}" in
	- | unknown | absent | "") PC_POD[$ctx]="deploy/${INGRESS_DEPLOY}" ;;
	*) PC_POD[$ctx]="${PRE[$ctx|ingress_pod]}" ;;
	esac
done

# pc_slot <seconds>: takes one of PC_SLOTS slots (a directory: mkdir is atomic) and prints its
# number, or returns 1 when none came free within <seconds> (PL4). The caller, a subshell, frees
# it with an EXIT trap, so a holder that dies still frees its slot.
pc_slot() {
	local k end=$((SECONDS + $1))
	while :; do
		for ((k = 1; k <= PC_SLOTS; k++)); do
			if mkdir "${WORK}/pc-slot-${k}" 2>/dev/null; then
				echo "$k"
				return 0
			fi
		done
		((SECONDS < end)) || return 1
		sleep 0.2
	done
}

# pc_unread <i> <class>: every backend of ingress <i> with that class (timeout or unknown).
pc_unread() {
	local fqdn
	for fqdn in "${FQDNS[@]}"; do printf '%s\t%s\t-\t-\n' "$fqdn" "$2"; done >"${WORK}/pc-${1}.tsv"
}

# proxy_endpoints_member <i> <ctx>: ONE bounded istioctl dump of the ingress's endpoints (not one
# per backend: each call fetches Envoy's whole clusters?format=json, which is large on a big
# mesh), filtered for every backend host in one bounded jq pass, at most PC_SLOTS ingresses at
# once; "<fqdn>\t<class>\t<total>\t<healthy>" lines in $WORK/pc-<i>.tsv. The dump is deleted
# once parsed. Runs in a subshell (its EXIT trap frees the slot).
proxy_endpoints_member() {
	local i="$1" ctx="$2" out="${WORK}/pc-${1}.json" rc=0 slot
	if ! slot="$(pc_slot "$PC_SLOT_WAIT")"; then
		echo "istioctl on ${ctx}: no turn within ${PC_SLOT_WAIT} s (${PC_SLOTS} ingresses at a time)" >&2
		pc_unread "$i" timeout
		return 0
	fi
	# shellcheck disable=SC2064  # expand the paths now: the trap runs after this function returns
	trap "rmdir $(printf '%q' "${WORK}/pc-slot-${slot}") 2>/dev/null; rm -f $(printf '%q' "$out") $(printf '%q' "${out}.err")" EXIT
	run_bounded "$GWAPI_ISTIOCTL_TIMEOUT_SEC" "$out" "${out}.err" \
		istioctl --context "$ctx" proxy-config endpoints -n istio-system "${PC_POD[$ctx]}" -o json || rc=$?
	if ((rc == 124)); then
		echo "istioctl on ${ctx}: no answer within GWAPI_ISTIOCTL_TIMEOUT_SEC (${GWAPI_ISTIOCTL_TIMEOUT_SEC} s)" >&2
		pc_unread "$i" timeout
		return 0
	elif ((rc != 0)); then
		echo "istioctl on ${ctx}: exit ${rc}: $(reach_sanitize "$(head -c 400 "${out}.err" 2>/dev/null)")" >&2
		pc_unread "$i" unknown
		return 0
	fi
	rc=0
	run_bounded "$GWAPI_ISTIOCTL_TIMEOUT_SEC" "${WORK}/pc-${i}.tsv" /dev/null \
		jq -r --argjson fqdns "$FQDNS_JSON" --arg port "$SVC_PORT" "$PC_FILTER" "$out" || rc=$?
	rm -f "$out"
	if ((rc == 124)); then
		echo "istioctl on ${ctx}: the endpoints dump was not parsed within GWAPI_ISTIOCTL_TIMEOUT_SEC (${GWAPI_ISTIOCTL_TIMEOUT_SEC} s)" >&2
		pc_unread "$i" timeout
	elif ((rc != 0)); then
		# A dump that does not parse leaves every backend unknown (the reader's default).
		echo "istioctl on ${ctx}: the endpoints dump did not parse" >&2
		: >"${WORK}/pc-${i}.tsv"
	fi
}

declare -A PC=()
if [[ "$PROXY_CONFIG_MODE" == istioctl* ]]; then
	echo "Endpoint evidence: one istioctl proxy-config endpoints dump per ingress, ${PC_SLOTS} at a time..." >&2
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
# GWAPI_ARGOCD_NAMESPACE empty: the namespace the hub's platform installs (-> $WORK/argo.ns).
argocd_health() {
	local f="${WORK}/apps.json" fs="${WORK}/appset.json" rc=0 wl ns="$GWAPI_ARGOCD_NAMESPACE"
	if [[ -z "$ns" ]]; then
		ns="$(platform_gitops_namespace "$HUB_CTX" 2>"${WORK}/argo.ns.err")" ||
			die "could not tell the hub's platform to pick its Argo CD namespace; set GWAPI_ARGOCD_NAMESPACE (argocd, or openshift-gitops on OpenShift) ($(reach_sanitize "$(head -c 400 "${WORK}/argo.ns.err" 2>/dev/null)"))"
	fi
	printf '%s\n' "$ns" >"${WORK}/argo.ns"
	kget "$HUB_CTX" "$fs" -n "$ns" get applicationsets.argoproj.io "$GWAPI_ARGOCD_APPSET" || rc=$?
	((rc == 0)) || die "could not read ApplicationSet ${ns}/${GWAPI_ARGOCD_APPSET} on ${HUB_CTX} (kubectl: $(reach_sanitize "$(head -c 300 "${fs}.err" 2>/dev/null)")); GWAPI_ARGOCD_NAMESPACE and GWAPI_ARGOCD_APPSET name it"
	wl="$(jq -r '.spec.template.spec.source.helm.valuesObject.workloadCluster // "unset"' "$fs" 2>/dev/null)" || wl=unknown
	printf '%s\n' "${wl:-unknown}" >"${WORK}/argo.workload"
	kget "$HUB_CTX" "$f" -n "$ns" get applications.argoproj.io || rc=$?
	((rc == 0)) || die "could not list Applications in ${ns} on ${HUB_CTX} (kubectl: $(reach_sanitize "$(head -c 300 "${f}.err" 2>/dev/null)")); GWAPI_ARGOCD_NAMESPACE names the namespace"
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
		argo_ns="$(cat "${WORK}/argo.ns")"
		[[ -n "$GWAPI_ARGOCD_NAMESPACE" ]] || echo "Argo CD namespace on ${HUB_CTX}: ${argo_ns} (from its platform; GWAPI_ARGOCD_NAMESPACE sets it)" >&2
		ARGO_STATE="read from ${HUB_CTX}: $(wc -l <"${WORK}/argo.rows" | tr -d ' ') Application(s) of ${argo_ns}/${GWAPI_ARGOCD_APPSET}"
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

# Argo CD syncs the chart from its own revision, which can move independently of this script
# (R2, PL39): say when it is not the commit the script runs from.
HARNESS="$(harness_sha)"
CHART_REVISION_VS_HARNESS=unknown
hc="${HARNESS%-dirty}"
if [[ "$hc" =~ -g([0-9a-f]{7,})$ ]]; then
	hc="${BASH_REMATCH[1]}"
elif [[ ! "$hc" =~ ^[0-9a-f]{7,}$ ]]; then
	hc=""
fi
if [[ -n "$hc" && "$CHART_REVISION" != unknown ]]; then
	IFS=, read -r -a revs <<<"$CHART_REVISION"
	for rev in "${revs[@]}"; do
		[[ "$rev" =~ ^[0-9a-f]{7,}$ ]] || continue
		if [[ "$rev" == "$hc"* || "$hc" == "$rev"* ]]; then
			[[ "$CHART_REVISION_VS_HARNESS" == differs ]] || CHART_REVISION_VS_HARNESS=same
		else
			CHART_REVISION_VS_HARNESS=differs
		fi
	done
	if [[ "$CHART_REVISION_VS_HARNESS" == differs ]]; then
		warn "Argo CD synced the chart from ${CHART_REVISION}, not from this script's commit ${hc} (HARNESS_SHA ${HARNESS}): the deployed check may describe other scenarios than this script (preamble SCENARIO_SET per member)"
	elif [[ "$CHART_REVISION_VS_HARNESS" == same && "$HARNESS" == *-dirty ]]; then
		# The commit matches, but the script runs from a tree with uncommitted changes.
		CHART_REVISION_VS_HARNESS=same-dirty
	fi
fi

# --- Step 6: rows, TSV, summary ---

# Final status read after the traffic: S4's status depends on istiod's push timing, so the
# rows use this later read and note when it differs from the read the wait ended on.
FINAL_SNAP="${WORK}/snap-final"
mkdir -p "$FINAL_SNAP"
snapshot_all "$FINAL_SNAP" pods

# Restart detection (PL9): the istiod and ingress pod fingerprints (name, start time, container
# restarts) at the preflight and in this final read. 1 = a pod restarted, was replaced or added
# during the run; 0 = unchanged; unknown = either read failed (never "no restart" unmeasured).
# A restart flags that member's rows: a status flip or a 5xx then says nothing about the route.
# restarted <ctx> <i> <preflight key> <snapshot file>
restarted() {
	local before="${PRE[$1|$3]}" f="${FINAL_SNAP}/m${2}/${4}" after
	[[ "$(snap_rc "$f")" == 0 && "$before" != unknown && "$before" != absent ]] || {
		echo unknown
		return 0
	}
	after="$(jq -r "$(platform_pod_filter x)" "$f" 2>/dev/null | cut -f2)" || after=""
	if [[ -z "$after" ]]; then
		echo unknown
	elif [[ "$after" == "$before" ]]; then
		echo 0
	else
		echo 1
	fi
}
declare -A ISTIOD_RESTARTED=() INGRESS_RESTARTED=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	ISTIOD_RESTARTED[$ctx]="$(restarted "$ctx" "$i" istiod_fp istiod-pods.json)"
	INGRESS_RESTARTED[$ctx]="$(restarted "$ctx" "$i" ingress_fp ingress-pods.json)"
	[[ "${ISTIOD_RESTARTED[$ctx]}" != 1 ]] || warn "${ctx}: an istiod pod restarted or was replaced during the run; its rows say ISTIOD_RESTARTED"
	[[ "${INGRESS_RESTARTED[$ctx]}" != 1 ]] || warn "${ctx}: an ingress pod restarted, was replaced or was added during the run; its rows say INGRESS_RESTARTED"
done

# cell_summary <cell file> <expected body>: "<codes>\t<n>\t<n200>\t<n000>\t<n200 with the
# expected body>\t<n with an empty body>\t<most frequent body>"; codes as code:count by count
# (e.g. 200:9,503:1).
cell_summary() {
	awk -F'\t' -v e="$2" '
		{ n++; c[$1]++; b[$2]++; if ($2 == "") ne++; if ($1 == "200") { n200++; if (e != "unknown" && $2 == e) m++ } if ($1 == "000") t++ }
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
			printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\n", (out == "" ? "-" : out), n, n200, t, m, ne, (top == "" ? "-" : top)
		}' "$1" 2>/dev/null
}

# md_safe <text>: one table cell (no | or newline).
md_safe() { printf '%s' "$1" | tr '|\n' '/ '; }

TSV_HEADER=$'run_id\tingress_ctx\trole\tscenario\tkind\thost\troute\tbackend\texpected_status\tobserved_status\texpected_code\tobserved_codes\texpected_body\tbody_match\ttop_body\texpected_endpoints\tobserved_endpoints\tendpoints_healthy\tverdict\trow_status\tdetail'
ROWS="${WORK}/rows.tsv"
: >"$ROWS"
declare -A R=() PRECOND=()
n_match=0 n_dev=0 n_unk=0 n_ep_unread=0

# row_invalid <flag> <reason>: a precondition of the current row (ctx, id) does not hold, or could
# not be read. The row is UNKNOWN whatever it observes, never MATCH or DEVIATION, and the answers
# quote <reason> (PRECOND).
row_invalid() {
	invalid=1
	flags+=("$1")
	notes+=("$2")
	PRECOND["${ctx}|${id}"]="${PRECOND[${ctx}|${id}]:+${PRECOND[${ctx}|${id}]}; }$2"
}

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
		bns_n="$(bns_name "$bns")"
		fqdn="${backend}.${bns_n}.svc.${CLUSTER_DOMAIN}"
		flags=() notes=()
		dev=0 unk=0 invalid=0 taint=""

		# The deployed chart is another scenario set than this script describes (R2).
		if [[ -n "${SET_MISMATCH[$ctx]:-}" ]]; then
			if ((set_mismatch_wl)); then
				row_invalid SCENARIO_SET_MISMATCH "the chart deployed on the workload member ${WORKLOAD_CTX} (scenario set ${DEPLOYED_SET[$WORKLOAD_CTX]}) is not the version this script expects (${SCENARIO_SET})"
			else
				row_invalid SCENARIO_SET_MISMATCH "the chart deployed on this member (scenario set ${DEPLOYED_SET[$ctx]}) is not the version this script expects (${SCENARIO_SET})"
			fi
		fi
		if [[ "$rl" != workload ]]; then
			# S7-S9 test an ingress member WITHOUT the backend namespace.
			if [[ "$bns" == remote ]]; then
				case "${PRE[$ctx|remote_namespace]}" in
				absent) ;;
				unknown) row_invalid NS_SCENARIO_UNVERIFIED "could not read whether namespace ${NS_REMOTE} exists on this member" ;;
				*) row_invalid NS_SCENARIO_INVALID "namespace ${NS_REMOTE} exists on this member (expected on the workload member only)" ;;
				esac
			fi
			# S7b tests an ingress member WITH the backend namespace and its ReferenceGrant.
			if [[ "$bns" == shared && "$bkind" == Service ]]; then
				case "${PRE[$ctx|shared_namespace]}/${PRE[$ctx|shared_grants]}" in
				absent/*) row_invalid NS_SCENARIO_INVALID "namespace ${NS_SHARED} is missing on this member (expected on every member)" ;;
				unknown/* | */unknown) row_invalid NS_SCENARIO_UNVERIFIED "could not read namespace ${NS_SHARED} or its ReferenceGrants on this member" ;;
				*)
					[[ ",${PRE[$ctx|shared_grants]}," == *",${route},"* ]] \
						|| row_invalid NS_SCENARIO_INVALID "ReferenceGrant ${NS_SHARED}/${route} is missing on this member (expected on every member)"
					;;
				esac
			fi
			# The backend Service, read directly (M2): absent where the scenario asks "without a
			# local Service", present for S3's stub. Not judged where the route itself is absent
			# (C2) or for the remote namespace (its own check above).
			if [[ "$bns" != remote && "$st_o" != absent ]]; then
				want="$(svc_wanted_other "$st_o" "$bkind")"
				list="${PRE[$ctx|svc_${bns}]}"
				if [[ "$list" == unknown ]]; then
					row_invalid SVC_SCENARIO_UNVERIFIED "could not read the Services in ${bns_n} on this member"
				else
					have=absent
					[[ ",${list}," != *",${backend},"* ]] || have=present
					[[ "$have" == "$want" ]] || row_invalid SVC_SCENARIO_INVALID "Service ${bns_n}/${backend} is ${have} on this member (the scenario needs it ${want} there)"
				fi
			fi
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
			# The route exists but istio had not processed it yet: its traffic is not judged (M1).
			taint="the route had no current status from ${GW_CONTROLLER} (${obs_status})"
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
		if [[ "$first_status" != "$obs_status" ]]; then
			# The status the wait ended on stays in detail, also on a MATCH row.
			notes+=("status changed during the run (the wait ended on $(status_text "$first_status"))")
			if ! in_place_status "$first_status" && in_place_status "$obs_status"; then
				# Not shown in place when the traffic started, so the traffic may have run without
				# the route (a 404 or a 500 then says nothing about the backend): never a deviation.
				flags+=(STATUS_CHANGED)
				if [[ "$first_status" == unknown ]]; then
					taint="${taint:+${taint}, }the route's status was unread when the wait ended, so it is not shown in place before the traffic, only by the final read (${obs_status})"
				else
					taint="${taint:+${taint}, }the route was not in place when the wait ended (status ${first_status}), only by the final read (${obs_status})"
				fi
			fi
		fi

		# Traffic.
		codes="-" body_match="-" top_body="-" nempty=0
		reprobed=0 rcodes="-" rbm="-" rnempty=0 rtop="-"
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
			IFS=$'\t' read -r codes n n200 n000 nmatch nempty top_raw <<<"$(cell_summary "${WORK}/cell-${i}-${s}.txt" "$EXPECTED_BODY")"
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
			# The re-probe of a queued cell (see "Late endpoints" above); its codes always reach
			# detail, and cell_state judges the cell by both probes. Queued is what counts: a
			# re-probe that left no record confirms nothing.
			if [[ -n "${REPROBED[${i}|${s}]:-}" && ! -s "${WORK}/reprobe-${i}-${s}.txt" ]]; then
				reprobed=1
				flags+=(REPROBE_NO_RECORD)
				notes+=("the re-probe ${REPROBE_DELAY} s after the traffic produced no result")
			elif [[ -n "${REPROBED[${i}|${s}]:-}" ]]; then
				reprobed=1
				IFS=$'\t' read -r rcodes _ rn200 _ rmatch rnempty rtop_raw <<<"$(cell_summary "${WORK}/reprobe-${i}-${s}.txt" "$EXPECTED_BODY")"
				rtop="$(reach_sanitize "${rtop_raw:--}")"
				if [[ "$EXPECTED_BODY" == unknown ]]; then
					rbm=unknown
				elif ((rn200 == 0)); then
					rbm="n/a"
				elif ((rmatch == rn200)); then
					rbm=yes
				elif ((rmatch == 0)); then
					rbm=no
				else
					rbm="partial:${rmatch}/${rn200}"
				fi
				notes+=("re-probed ${REPROBE_DELAY} s after the traffic: ${rcodes}$([[ "$rtop" == - ]] || echo " (most frequent body: ${rtop})")")
				if cell_passed "${WORK}/reprobe-${i}-${s}.txt"; then
					flags+=(LATE_ENDPOINT)
					if [[ "$EXPECTED_BODY" == unknown ]]; then
						taint="${taint:+${taint}, }it answered 200 on the re-probe, echo text unknown"
					elif [[ "$exp_code" == 200 ]]; then
						taint="${taint:+${taint}, }it answered 200 with the echo text on the re-probe: a late endpoint push, not the scenario"
					else
						taint="${taint:+${taint}, }it answered 200 with the echo text on the re-probe, where ${exp_code} was predicted"
					fi
				else
					flags+=(REPROBE_FAILED)
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

		case "$obs_ep" in skipped | unknown | timeout) n_ep_unread=$((n_ep_unread + 1)) ;; esac

		# A route istio had not processed or that came late, a data path that was not ready, a late
		# endpoint, a restart during the run, or one that could not be checked (PL9: 1 and unknown
		# alike), or an unreadable scenario set can explain a deviation: such a row is UNKNOWN
		# instead (a MATCH stays a MATCH: it was observed regardless), and a failure there does not
		# count toward an answer.
		if [[ "${DP_READY[$ctx]:-unknown}" == timeout ]]; then
			flags+=(DATAPLANE_NOT_READY)
			taint="${taint:+${taint}, }${GATE_DESC} did not answer 200 through this ingress ${GWAPI_GATE_PASSES} time(s) in a row before the wait's deadline"
		fi
		case "${ISTIOD_RESTARTED[$ctx]}" in
		1)
			flags+=(ISTIOD_RESTARTED)
			taint="${taint:+${taint}, }an istiod pod restarted during the run"
			;;
		unknown)
			flags+=(ISTIOD_RESTART_UNVERIFIED)
			taint="${taint:+${taint}, }whether an istiod pod restarted during the run could not be read"
			;;
		esac
		case "${INGRESS_RESTARTED[$ctx]}" in
		1)
			flags+=(INGRESS_RESTARTED)
			taint="${taint:+${taint}, }an ingress pod restarted, was replaced or added during the run"
			;;
		unknown)
			flags+=(INGRESS_RESTART_UNVERIFIED)
			taint="${taint:+${taint}, }whether an ingress pod restarted during the run could not be read"
			;;
		esac
		if [[ -n "${SET_UNVERIFIED[$ctx]:-}" ]]; then
			flags+=(SCENARIO_SET_UNVERIFIED)
			if ((set_unverified_wl)); then
				taint="${taint:+${taint}, }the scenario set deployed on the workload member ${WORKLOAD_CTX} could not be read"
			else
				taint="${taint:+${taint}, }the scenario set deployed on this member could not be read"
			fi
		fi

		if ((invalid)); then
			verdict=UNKNOWN
			n_unk=$((n_unk + 1))
		elif ((dev)) && [[ -n "$taint" ]]; then
			verdict=UNKNOWN
			notes+=("not judged a deviation: ${taint}")
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
		for k in kind exp_status obs_status first_status exp_code codes nempty body_match top_body reprobed rcodes rbm rnempty rtop exp_ep obs_ep ep_healthy verdict row_status detail taint; do
			R["${ctx}|${id}|${k}"]="${!k}"
		done
	done
done

# emit_preamble <title>: the one preamble writer for every TSV of this run (PL2, PL36); the
# summary's frontmatter is parsed from it (PL19), so no output can drift from the others. Not
# write_preamble (tests/lib/preamble.sh): it stamps its own generated_at per file, and this run's
# outputs must carry the same values, generated_at included.
GENERATED_AT="$(date -u -Iseconds)"
emit_preamble() {
	local ctx
	echo "# $1"
	echo "# generated_at=${GENERATED_AT}"
	echo "# GWAPI_SCHEMA=${GWAPI_SCHEMA}"
	echo "# RUN_ID=${RUN_ID}"
	echo "# HARNESS_SHA=${HARNESS}"
	echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
	config_preamble_lines
	platform_preamble_lines "$(IFS=,; echo "${CONTEXTS[*]}")"
	echo "# SCENARIO_SET=${SCENARIO_SET}"
	echo "# CONTEXTS=$(IFS=,; echo "${CONTEXTS[*]}")"
	echo "# WORKLOAD_CONTEXT=${WORKLOAD_CTX}"
	echo "# WORKLOAD_CLUSTER=${WORKLOAD_CLUSTER}"
	echo "# CHART_REVISION=${CHART_REVISION}"
	echo "# CHART_REVISION_VS_HARNESS=${CHART_REVISION_VS_HARNESS}"
	echo "# HUB_CONTEXT=${HUB_CTX:-none}"
	echo "# NAMESPACE=${NS}"
	echo "# REMOTE_NAMESPACE=${NS_REMOTE}"
	echo "# SHARED_NAMESPACE=${NS_SHARED}"
	echo "# GATEWAY=istio-system/${GW_NAME}"
	echo "# REQUESTS=${REQUESTS}"
	echo "# TIMEOUT_SEC=${TIMEOUT_SEC}"
	echo "# DETAIL_TIMEOUT_SEC=${GWAPI_DETAIL_TIMEOUT_SEC}"
	echo "# WAIT_TIMEOUT_SEC=${WAIT_TIMEOUT_SEC}"
	echo "# WAIT_SEC=${WAIT_SEC}"
	echo "# WAIT_TIMED_OUT=${WAIT_TIMED_OUT}"
	echo "# DATAPLANE_GATE_HOSTS=${GATE_LABEL}"
	echo "# GATE_PASSES=${GWAPI_GATE_PASSES}"
	echo "# DATAPLANE_GATE_SEC=${GATE_SEC}"
	echo "# SETTLE_SEC=${GWAPI_SETTLE_SEC}"
	echo "# TRAFFIC_START=${TRAFFIC_START}"
	echo "# TRAFFIC_END=${TRAFFIC_END}"
	echo "# REPROBE_DELAY_SEC=${REPROBE_DELAY}"
	echo "# REPROBE_CELLS=${REPROBE_CELLS}"
	echo "# KUBECTL_TIMEOUT_SEC=${GWAPI_KUBECTL_TIMEOUT_SEC}"
	echo "# PROXY_CONFIG=${PROXY_CONFIG_MODE}"
	echo "# ISTIOCTL_TIMEOUT_SEC=${GWAPI_ISTIOCTL_TIMEOUT_SEC}"
	echo "# ARGOCD=${ARGO_STATE}"
	echo "# EXPECTED_BODY=${EXPECTED_BODY}"
	echo "# EXPECTED_BODY_SOURCE=${EXPECTED_BODY_SOURCE}"
	echo "# KUBE_VERSIONS=${KUBE_VERSIONS:-unknown}"
	for ctx in "${CONTEXTS[@]}"; do
		echo "# SCENARIO_SET[${ctx}]=${DEPLOYED_SET[$ctx]}"
		echo "# GATEWAY_API_CRD[${ctx}]=${PRE[$ctx|crd]}"
		echo "# GATEWAYCLASS[${ctx}]=${PRE[$ctx|gatewayclass]}"
		echo "# GATEWAY_PROGRAMMED[${ctx}]=$(gw_programmed "${FINAL_SNAP}/m${GW_INDEX[$ctx]}")"
		echo "# NAMESPACE_LABELS[${ctx}]=${PRE[$ctx|namespace]}"
		echo "# REMOTE_NAMESPACE_LABELS[${ctx}]=${PRE[$ctx|remote_namespace]}"
		echo "# SHARED_NAMESPACE_LABELS[${ctx}]=${PRE[$ctx|shared_namespace]}"
		echo "# SHARED_REFERENCEGRANTS[${ctx}]=${PRE[$ctx|shared_grants]}"
		echo "# BACKEND_SERVICES[${ctx}]=${NS}:${PRE[$ctx|svc_main]};${NS_SHARED}:${PRE[$ctx|svc_shared]}"
		echo "# ISTIOD_ENV[${ctx}]=${PRE[$ctx|istiod_env]}"
		echo "# ISTIOD_IMAGE[${ctx}]=${PRE[$ctx|istiod_image]}"
		echo "# INGRESS_PROXY_IMAGE[${ctx}]=${PRE[$ctx|ingress_image]}"
		echo "# OSSM_OPERATOR[${ctx}]=${PRE[$ctx|ossm_operator]}"
		echo "# ISTIO_CR_VERSION[${ctx}]=${PRE[$ctx|istio_cr_version]}"
		echo "# ISTIOD_RESTARTED[${ctx}]=${ISTIOD_RESTARTED[$ctx]}"
		echo "# INGRESS_RESTARTED[${ctx}]=${INGRESS_RESTARTED[$ctx]}"
		echo "# INGRESS_REPLICAS[${ctx}]=${PRE[$ctx|ingress_replicas]}"
		echo "# PROXY_CONFIG_POD[${ctx}]=$([[ "$PROXY_CONFIG_MODE" == istioctl* ]] && echo "${PC_POD[$ctx]}" || echo -)"
		echo "# ECHO_DEPLOYMENT[${ctx}]=${PRE[$ctx|echo]};sidecar=${PRE[$ctx|echo_sidecar]}"
		echo "# ECHO_REMOTE_DEPLOYMENT[${ctx}]=${PRE[$ctx|echo_remote]};sidecar=${PRE[$ctx|echo_remote_sidecar]}"
		echo "# ECHO_SHARED_DEPLOYMENT[${ctx}]=${PRE[$ctx|echo_shared]};sidecar=${PRE[$ctx|echo_shared_sidecar]}"
		echo "# INGRESS_ADDRESS_SOURCE[${ctx}]=${INGRESS_SOURCE[$ctx]:-none}"
		echo "# DATAPLANE_READY_SEC[${ctx}]=${DP_READY[$ctx]}"
		echo "# TUNING_BASELINE[${ctx}]=${PRE[$ctx|tuning_baseline]}"
		echo "# SIDECAR_EGRESS_HOSTS[${ctx}]=${PRE[$ctx|sidecar_egress_hosts]}"
	done
}
declare -A GW_INDEX=()
for i in "${!CONTEXTS[@]}"; do GW_INDEX[${CONTEXTS[i]}]="$i"; done

mkdir -p "$OUT_DIR"
config_snapshot "$OUT_DIR" "$RUN_ID"
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

# --- The answers ---

OTHERS=()
for ctx in "${CONTEXTS[@]}"; do [[ "$ctx" == "$WORKLOAD_CTX" ]] || OTHERS+=("$ctx"); done
n_others=${#OTHERS[@]}
join_ticks() { local x out=""; for x in "$@"; do out="${out:+${out}, }\`${x}\`"; done; printf '%s' "$out"; }

# classify <kind> <codes> <body match> <n empty bodies> <top body>: one probe of a cell (the
# traffic's or the re-probe's), judged by what a dropped backend gives:
#   ok                every request answered 200 with the echo text;
#   fail              every request got Envoy's reply for a dropped destination, with an empty
#                     body: for an HTTPRoute 500 (no Envoy cluster for it, and Gateway API routes
#                     set ClusterNotFoundResponseCode=INTERNAL_SERVER_ERROR, route.go:617-621; C1
#                     is the reference), for a classic VirtualService 503 (Envoy's NC: no cluster
#                     for the host);
#   unclear<TAB>why   anything else, with what the codes say instead.
classify() {
	local kind="$1" codes="$2" bm="$3" ne="$4" top="$5" n="$REQUESTS" want
	if [[ "$codes" == "200:${n}" && "$bm" == yes ]]; then
		echo ok
		return 0
	fi
	if [[ "$kind" == httproute ]]; then
		want="a 500 with an empty body, Envoy's reply for a dropped destination"
		case "$codes" in
		"500:${n}")
			if [[ "$ne" == "$n" ]]; then
				echo fail
			else
				printf 'unclear\t%s\n' "500 with a body (\`${top}\`), not Envoy's empty reply for a route without a cluster"
			fi
			return 0
			;;
		"503:${n}")
			printf 'unclear\t%s\n' "503 on every request: the ingress has the backend's cluster but no healthy endpoint (EDS lag or the east-west path), so the route kept its destination"
			return 0
			;;
		"404:${n}")
			printf 'unclear\t%s\n' "404 on every request: no route for this host on the ingress (the route had not reached its Envoy)"
			return 0
			;;
		esac
	else
		want="a 503 with an empty body, the code of a missing host"
		if [[ "$codes" == "503:${n}" ]]; then
			if [[ "$ne" == "$n" ]]; then
				echo fail
			else
				printf 'unclear\t%s\n' "503 with a body (\`${top}\`): Envoy has the cluster but no healthy endpoint (\"no healthy upstream\": EDS lag or the east-west path), not a missing host"
			fi
			return 0
		fi
	fi
	case "$codes" in
	-) printf 'unclear\t%s\n' "not probed" ;;
	*000:*) printf 'unclear\t%s\n' "HTTP \`${codes}\`: requests without an answer within ${TIMEOUT_SEC} s" ;;
	"200:${n}") printf 'unclear\t%s\n' "HTTP 200, but body match \`${bm}\`" ;;
	*) printf 'unclear\t%s\n' "HTTP \`${codes}\`, not ${want} on every request" ;;
	esac
}

# cell_state <ctx> <id>: the cell judged by its traffic and, when it was queued for the re-probe
# (it did not answer, and was predicted 200 or is S7 through another member), by the re-probe too:
#   ok                the traffic answered (classify);
#   late<TAB>why      the traffic did not, the re-probe answered 200 with the echo text on every
#                     request, and 200 was predicted: a late endpoint push (answered, for a NO;
#                     never a failure);
#   fail              the traffic failed (classify), and so did the re-probe, by the same rule;
#   unclear<TAB>why   anything else: a re-probe that answered otherwise makes the failure
#                     unstable (a 500 and then a 503: the cluster appeared, i.e. the remote
#                     Service was discovered late, not dropped), and one that left no record
#                     confirms nothing.
cell_state() {
	local c="$1|$2" st rst why rdesc tdesc
	st="$(classify "${R[$c|kind]}" "${R[$c|codes]}" "${R[$c|body_match]}" "${R[$c|nempty]}" "${R[$c|top_body]}")"
	# A failure is always empty-bodied (classify).
	tdesc="\`${R[$c|codes]}\` with an empty body during the traffic"
	if [[ "$st" == fail && "${R[$c|reprobed]}" != 1 ]]; then
		# Every failure that can count was queued (an ingress whose gate never passed is not, and
		# its rows never count), so this is a guard: a failure needs both probes.
		printf 'unclear\t%s\n' "${tdesc}, but it was not re-probed: the failure is not confirmed"
		return 0
	fi
	if [[ "$st" != fail && "${R[$c|reprobed]}" != 1 ]] || [[ "$st" == ok ]]; then
		printf '%s\n' "$st"
		return 0
	fi
	if [[ "${R[$c|rcodes]}" == - ]]; then
		if [[ "$st" == fail ]]; then
			printf 'unclear\t%s\n' "${tdesc}, but the re-probe produced no result: the failure is not confirmed"
		else
			printf '%s\n' "${st}; the re-probe produced no result"
		fi
		return 0
	fi
	rst="$(classify "${R[$c|kind]}" "${R[$c|rcodes]}" "${R[$c|rbm]}" "${R[$c|rnempty]}" "${R[$c|rtop]}")"
	case "$rst" in
	ok)
		if [[ "${R[$c|exp_code]}" == 200 ]]; then
			printf 'late\t%s\n' "HTTP \`${R[$c|codes]}\` during the traffic, \`${R[$c|rcodes]}\` with the echo text on the re-probe ${REPROBE_DELAY} s later: a late endpoint push"
		else
			printf 'unclear\t%s\n' "HTTP \`${R[$c|codes]}\` during the traffic, but \`${R[$c|rcodes]}\` with the echo text on the re-probe ${REPROBE_DELAY} s later, where ${R[$c|exp_code]} was predicted: the failure was not stable"
		fi
		;;
	fail)
		if [[ "$st" == fail ]]; then
			echo fail
		else
			printf '%s\n' "${st}; the re-probe got \`${R[$c|rcodes]}\`"
		fi
		;;
	*)
		if [[ "$st" != fail ]]; then
			printf '%s\n' "${st}; the re-probe got \`${R[$c|rcodes]}\`"
			return 0
		fi
		why="${rst#*$'\t'}"
		if [[ "${R[$c|rcodes]}" == "503:${REQUESTS}" ]]; then
			why="503: the backend's cluster was there by then, without a healthy endpoint, so its Service was discovered late, not dropped"
		elif [[ "${R[$c|rcodes]}" == "200:${REQUESTS}" && "${R[$c|rbm]}" == unknown ]]; then
			why="answered 200, echo text unknown"
		fi
		rdesc="\`${R[$c|rcodes]}\`"
		[[ "${R[$c|rtop]}" == - ]] || rdesc="${rdesc} (body \`${R[$c|rtop]}\`)"
		printf 'unclear\t%s\n' "${tdesc}, but the re-probe ${REPROBE_DELAY} s later answered ${rdesc}: the failure was not stable (${why})"
		;;
	esac
}

# fail_meaning <id>: what a "fail" code means, for the YES text.
fail_meaning() {
	if [[ "${R[$WORKLOAD_CTX|$1|kind]}" == httproute ]]; then
		echo "500: Envoy had no cluster for the route's destination, i.e. istiod dropped it, as for C1"
	else
		echo "503 with an empty body: Envoy had no cluster for the host"
	fi
}

# blocking_reason <ctx> <id>: why the <id> row on <ctx> cannot count for or against an answer at
# all (an unmet or unread precondition, another chart version, an ingress without an answer), or
# nothing.
blocking_reason() {
	case "${R[$1|$2|row_status]}" in
	*SCENARIO_SET_MISMATCH* | *NS_SCENARIO_* | *SVC_SCENARIO_*) echo "${2} on \`${1}\`: ${PRECOND[$1|$2]:-a precondition does not hold}" ;;
	*NO_INGRESS_ADDR*) echo "\`${1}\` has no ingress address" ;;
	*INGRESS_UNREACHABLE*) echo "\`${1}\`'s ingress never answered from here" ;;
	esac
}

# route_in_place <ctx> <id>: whether the scenario's route was in place on <ctx> for the whole
# traffic window: an HTTPRoute whose istio status starts with Accepted=True, or a classic
# VirtualService that exists, both when the wait ended (before the traffic) and in the final read
# (after it), with no STATUS_* flag on the row. Only then can a failure through that ingress be
# the backend's (M1, F2): a route that reached the ingress late says nothing about the Service.
route_in_place() {
	[[ "${R[$1|$2|row_status]}" != *STATUS_* ]] || return 1
	in_place_status "${R[$1|$2|first_status]}" && in_place_status "${R[$1|$2|obs_status]}"
}

# member_answer <ctx> <id> <reference id...>: one line:
#   ok               <id> answered 200 with the echo text on every request;
#   late             it did so only on the re-probe (a late endpoint push): answered, for a NO;
#   fail             <id> got the code of a dropped destination, and its re-probe again
#                    (cell_state), on a route in place for the whole traffic window, on a ready,
#                    stable and verified path; where RefNotPermitted is predicted (S7), the route
#                    reads RefNotPermitted after the traffic; it answered 200 through the workload
#                    member; for an HTTPRoute, C1 answered an empty-bodied 500 through the same
#                    ingress; and a reference (a scenario whose 200 shows the same path works)
#                    answered;
#   broken           the same, but no reference answered;
#   unclear<TAB>why  anything else, with the reason.
member_answer() {
	local ctx="$1" id="$2" r why blocked="" rs st w late_refs=""
	shift 2
	why="$(blocking_reason "$ctx" "$id")"
	if [[ -n "$why" ]]; then
		printf 'unclear\t%s\n' "$why"
		return 0
	fi
	st="$(cell_state "$ctx" "$id")"
	case "$st" in
	ok | late*)
		echo "${st%%$'\t'*}"
		return 0
		;;
	esac
	rs="${R[$ctx|$id|row_status]}"
	if ! route_in_place "$ctx" "$id"; then
		printf 'unclear\t%s\n' "${id}'s route on \`${ctx}\` was not in place for the whole traffic window (status when the wait ended \`$(status_text "${R[$ctx|$id|first_status]}")\`, after the traffic \`${R[$ctx|$id|obs_status]}\`, row status \`${rs}\`), so its HTTP \`${R[$ctx|$id|codes]}\` says nothing about the backend"
		return 0
	fi
	case "$rs" in
	*DATAPLANE_NOT_READY*)
		printf 'unclear\t%s\n' "the cross-cluster path through \`${ctx}\` was not ready (${GATE_DESC} did not answer 200 there ${GWAPI_GATE_PASSES} time(s) in a row within the wait), so ${id}'s \`${R[$ctx|$id|codes]}\` is not blamed on the scenario"
		return 0
		;;
	*_RESTARTED*)
		printf 'unclear\t%s\n' "istiod or the ingress on \`${ctx}\` restarted during the run (row status \`${rs}\`)"
		return 0
		;;
	esac
	if [[ -n "${R[$ctx|$id|taint]}" ]]; then
		printf 'unclear\t%s\n' "${id} through \`${ctx}\` is not judged: ${R[$ctx|$id|taint]}"
		return 0
	fi
	if [[ "$st" != fail ]]; then
		printf 'unclear\t%s\n' "${id} through \`${ctx}\`: ${st#*$'\t'} (row status \`${rs}\`)"
		return 0
	fi
	# S7's 500 is the missing ReferenceGrant's only while its route says so.
	if [[ "${R[$ctx|$id|exp_status]}" == *RefNotPermitted* && "${R[$ctx|$id|obs_status]}" != *RefNotPermitted* ]]; then
		printf 'unclear\t%s\n' "${id} failed through \`${ctx}\`, but its route there reads \`${R[$ctx|$id|obs_status]}\` after the traffic, not RefNotPermitted, so the 500 is not shown to be the missing ReferenceGrant's"
		return 0
	fi
	# F3: "needed on the ingress member" only follows when the scenario works through the
	# workload member itself; else its backend is broken everywhere.
	why="$(blocking_reason "$WORKLOAD_CTX" "$id")"
	if [[ -n "$why" ]]; then
		printf 'unclear\t%s\n' "${id} failed through \`${ctx}\`, but its row on the workload member cannot count (${why})"
		return 0
	fi
	w="$(cell_state "$WORKLOAD_CTX" "$id")"
	case "$w" in
	ok) ;;
	late*)
		printf 'unclear\t%s\n' "${id} answered through the workload member \`${WORKLOAD_CTX}\` only on the re-probe (${w#*$'\t'}), so it is not shown to work there during the traffic, and its failure through \`${ctx}\` is not shown to be the ingress member's"
		return 0
		;;
	*)
		printf 'unclear\t%s\n' "${id} also fails through the workload member \`${WORKLOAD_CTX}\` (HTTP \`${R[$WORKLOAD_CTX|$id|codes]}\`), so its failure through \`${ctx}\` is not the ingress member's"
		return 0
		;;
	esac
	# An HTTPRoute's 500 is a dropped destination where C1 (no backend anywhere) answers the same
	# empty-bodied 500 (classify's rule).
	if [[ "${R[$ctx|$id|kind]}" == httproute ]]; then
		why="$(blocking_reason "$ctx" C1)"
		if [[ -n "$why" || "${R[$ctx|C1|codes]}" != "500:${REQUESTS}" ]]; then
			printf 'unclear\t%s\n' "C1 (no backend anywhere) answered \`${R[$ctx|C1|codes]}\` through \`${ctx}\`, not 500 on every request${why:+ (${why})}, so ${id}'s 500 there is not shown to be a dropped destination"
			return 0
		fi
		if [[ "$(classify httproute "${R[$ctx|C1|codes]}" "${R[$ctx|C1|body_match]}" "${R[$ctx|C1|nempty]}" "${R[$ctx|C1|top_body]}")" != fail ]]; then
			printf 'unclear\t%s\n' "C1 (no backend anywhere) answered 500 through \`${ctx}\` with a body (\`${R[$ctx|C1|top_body]}\`), not Envoy's empty reply, so ${id}'s 500 there is not shown to be a dropped destination"
			return 0
		fi
	fi
	for r in "$@"; do
		why="$(blocking_reason "$ctx" "$r")"
		if [[ -n "$why" ]]; then
			blocked="${blocked:+${blocked}; }${why}"
			continue
		fi
		w="$(cell_state "$ctx" "$r")"
		case "$w" in
		ok)
			echo fail
			return 0
			;;
		late*) late_refs="${late_refs:+${late_refs}, }${r} (${w#*$'\t'})" ;;
		esac
	done
	# A reference that answered only on the re-probe shows the path came up late, not that it was
	# broken during the traffic: the failure is not shown to be the scenario's either.
	if [[ -n "$late_refs" ]]; then
		printf 'unclear\t%s\n' "${id} failed through \`${ctx}\`, but its reference answered there only on the re-probe: ${late_refs}; the path through \`${ctx}\` is not shown ready during the traffic"
		return 0
	fi
	if [[ -n "$blocked" ]]; then
		printf 'unclear\t%s\n' "${id} failed through \`${ctx}\`, but its reference cannot count: ${blocked}"
		return 0
	fi
	echo broken
}

# answer_lists <id> <reference id...>: sorts the other members into ANS_OK (ANS_LATE: those that
# answered only on the re-probe), ANS_FAIL, ANS_BROKEN and ANS_UNCLEAR (reasons in ANS_WHY, same
# order) by member_answer.
answer_lists() {
	local o a
	ANS_OK=() ANS_LATE=() ANS_FAIL=() ANS_BROKEN=() ANS_UNCLEAR=() ANS_WHY=()
	for o in "${OTHERS[@]}"; do
		a="$(member_answer "$o" "$@")"
		case "$a" in
		ok) ANS_OK+=("$o") ;;
		late)
			ANS_OK+=("$o")
			ANS_LATE+=("$o")
			;;
		fail) ANS_FAIL+=("$o") ;;
		broken) ANS_BROKEN+=("$o") ;;
		*)
			ANS_UNCLEAR+=("$o")
			ANS_WHY+=("${a#*$'\t'}")
			;;
		esac
	done
}

# contradicted_by <id> <ref> <what ref shares with id>: moves every ANS_FAIL member where <ref>
# (a counting row) answered 200 with the echo text, during the traffic or only on the re-probe
# (the safe side), to ANS_UNCLEAR: the two run the same code path, so one failing where the other
# answers contradicts itself.
contradicted_by() {
	local id="$1" ref="$2" what="$3" o st
	local -a keep=()
	for o in "${ANS_FAIL[@]}"; do
		st="$(cell_state "$o" "$ref")"
		if [[ -z "$(blocking_reason "$o" "$ref")" ]] && [[ "$st" == ok || "$st" == late* ]]; then
			ANS_UNCLEAR+=("$o")
			ANS_WHY+=("${id} failed through \`${o}\` while ${ref} (${what}) answered 200 there$([[ "$st" == ok ]] || echo " on the re-probe"): this contradicts ${ref}")
		else
			keep+=("$o")
		fi
	done
	ANS_FAIL=("${keep[@]}")
}

# codes_through <id> <ctx...>: "`<codes>` through `a`, `b`'s ingress", one group per distinct code
# set ("; "-separated), so a YES lists what every member returned.
codes_through() {
	local id="$1" o c out=""
	local -a order=()
	local -A grp=()
	shift
	for o in "$@"; do
		c="${R[$o|$id|codes]}"
		[[ -n "${grp[$c]+x}" ]] || order+=("$c")
		grp[$c]="${grp[$c]:+${grp[$c]}, }\`${o}\`"
	done
	for c in "${order[@]}"; do out="${out:+${out}; }\`${c}\` through ${grp[$c]}'s ingress"; done
	printf '%s' "$out"
}

# again_note <id> <ctx...>: for a YES, that the re-probe repeated the failure on those members:
# " and again on the re-probe N s later (`<codes>`)", every distinct code set once.
again_note() {
	local id="$1" o c out=""
	local -A seen=()
	shift
	for o in "$@"; do
		c="${R[$o|$id|rcodes]}"
		[[ -z "${seen[$c]+x}" ]] || continue
		seen[$c]=1
		out="${out:+${out}, }\`${c}\`"
	done
	printf ' and again on the re-probe %s s later (%s)' "$REPROBE_DELAY" "$out"
}

# ans_counts: how the other members split, for an INCONCLUSIVE answer at scale.
ans_counts() {
	local late=""
	((${#ANS_LATE[@]} == 0)) || late=" (${#ANS_LATE[@]} only on the re-probe)"
	printf '%s of %s other members answered%s, %s failed, %s with a broken path, %s unclear' \
		"${#ANS_OK[@]}" "$n_others" "$late" "${#ANS_FAIL[@]}" "${#ANS_BROKEN[@]}" "${#ANS_UNCLEAR[@]}"
}

# late_note <id>: for a NO, the members where <id> answered only on the re-probe, or nothing.
late_note() {
	((${#ANS_LATE[@]})) || return 0
	printf ' %s of the %s other members (%s) answered %s only on the re-probe %s s after the traffic (a late endpoint push), not during it.' \
		"${#ANS_LATE[@]}" "$n_others" "$(join_ticks "${ANS_LATE[@]}")" "$1" "$REPROBE_DELAY"
}

# broken_note <service|namespace> <ctx>: what a member where a scenario and its references all
# failed says about the path, from the path references: S1 (classic) for the Service answer;
# S7b and S1 (other namespaces) for the namespace answers.
broken_note() {
	if [[ "$1" == service ]]; then
		if [[ "$(cell_state "$2" S1)" == ok ]]; then
			echo "S1 (classic) answered there, so the Gateway API path is broken, not the Service"
		else
			echo "S1 (classic) failed there too: the cross-cluster path itself is broken (check mesh-verify and the east-west gateways)"
		fi
	elif [[ "$(cell_state "$2" S7b)" == ok || "$(cell_state "$2" S1)" == ok ]]; then
		echo "S7b or S1 answered there, so the path to \`${NS_REMOTE}\` is broken (check its istio-discovery label on the workload member, whether the echo pod there has a sidecar, and whether its EDS was pushed yet)"
	else
		echo "S7b and S1 failed there too: the cross-cluster path itself is broken (check mesh-verify and the east-west gateways)"
	fi
}

# inconclusive_why <id> <references label> <service|namespace>: the reasons, from the ANS_* lists.
inconclusive_why() {
	local id="$1" refs="$2" o k why=""
	((${#ANS_OK[@]} == 0)) || why="${why}${id} answered 200 through $(join_ticks "${ANS_OK[@]}"); "
	((${#ANS_FAIL[@]} == 0)) || why="${why}${id} failed while ${refs} answered through $(join_ticks "${ANS_FAIL[@]}"); "
	for o in "${ANS_BROKEN[@]}"; do
		why="${why}${id} and ${refs} all failed through \`${o}\`: $(broken_note "$3" "$o"); "
	done
	for k in "${!ANS_UNCLEAR[@]}"; do why="${why}${ANS_WHY[k]}; "; done
	printf '%s' "${why%; }"
}

BODY_NOTE=""
if [[ "$EXPECTED_BODY_SOURCE" == local-answer ]]; then
	BODY_NOTE=" The expected body is the workload ingress's own most frequent answer in this run (the echo Deployment's -text could not be read)."
fi

# Answer 1: is the Service needed? S2 (no Service on the ingress member) against S3 (the same
# route plus a stub Service there); S1 tells a broken Gateway API path from a broken mesh path.
# S7b runs S2's code path (its grant passes, the local Service lookup misses, a soft error), so a
# member where S7b answered cannot say YES for S2. ANSWER1 (no, yes, inconclusive) lets the
# kind: Service line say when S7b failed the same way.
L1="Service needed in every cluster for HTTPRoute traffic"
answer_lists S2 S3
contradicted_by S2 S7b "the same code path: its grant passes, the local Service lookup misses, a soft error"
if ((${#ANS_OK[@]} == n_others)); then
	ANSWER1=no
	HEADLINE="**${L1}: NO** — S2 answered 200 (${REQUESTS}/${REQUESTS}, body \`${EXPECTED_BODY}\`) from the workload member \`${WORKLOAD_CTX}\` through $(join_ticks "${ANS_OK[@]}")'s ingress, with no \`echo-s2\` Service there (read in the preflight).$(late_note S2)${BODY_NOTE}"
elif ((${#ANS_FAIL[@]} == n_others)); then
	ANSWER1=yes
	HEADLINE="**${L1}: YES** — S2 (its route in place for the whole traffic window, no \`echo-s2\` Service on the ingress member) returned $(codes_through S2 "${ANS_FAIL[@]}") ($(fail_meaning S2))$(again_note S2 "${ANS_FAIL[@]}"), while S3 (the same route plus a stub Service there) answered 200 from the workload member \`${WORKLOAD_CTX}\` and S2 answered 200 through \`${WORKLOAD_CTX}\` itself.${BODY_NOTE}"
else
	ANSWER1=inconclusive
	why="$(inconclusive_why S2 S3 service)"
	((WAIT_TIMED_OUT == 0)) || why="${why}; the wait timed out"
	[[ "$EXPECTED_BODY" != unknown ]] || why="${why}; the workload's echo text is unknown"
	HEADLINE="**${L1}: INCONCLUSIVE** — $(ans_counts): ${why#; }. See the matrix and the deviations below."
fi

# Answer 2, one line per backend kind: is the backend's namespace needed on the ingress member?
# S7 (kind Service: the ReferenceGrant can only live in that namespace) with S7b as its positive
# control (namespace and grant there, no Service), S8 (Hostname) and S9 (classic). The
# references of each are the scenarios with the backend in the same namespace.
NS_HEADLINE="**Local namespace needed on the ingress cluster** (backend namespace \`${NS_REMOTE}\` only on \`${WORKLOAD_CTX}\`):"

# ns_line <label> <id> <reference id...>: the Hostname and classic lines.
ns_line() {
	local label="$1" id="$2" refs
	shift 2
	refs="$(IFS=/; echo "$*")"
	answer_lists "$id" "$@"
	if ((${#ANS_OK[@]} == n_others)); then
		echo "- ${label} — **NO**: ${id} answered 200 from \`${WORKLOAD_CTX}\` through $(join_ticks "${ANS_OK[@]}")'s ingress, without \`${NS_REMOTE}\` there.$(late_note "$id")"
	elif ((${#ANS_FAIL[@]} == n_others)); then
		echo "- ${label} — **YES**: ${id} returned $(codes_through "$id" "${ANS_FAIL[@]}") ($(fail_meaning "$id"))$(again_note "$id" "${ANS_FAIL[@]}"), while ${refs}, with the backend in the same namespace, answered 200 there and ${id} answered 200 through \`${WORKLOAD_CTX}\` itself."
	else
		echo "- ${label} — **INCONCLUSIVE** ($(ans_counts)): $(inconclusive_why "$id" "$refs" namespace)."
	fi
}

# ns_line_service: the kind Service line, S7 judged against S9/S8, then S7b for "not the Service"
# (when S7b failed like S2 under a YES first answer, the two answers agree: the Service too).
ns_line_service() {
	local label="kind: Service" s7_codes
	answer_lists S7 S9 S8
	if ((${#ANS_OK[@]} == n_others)); then
		echo "- ${label} — **NO**: S7 answered 200 from \`${WORKLOAD_CTX}\` through $(join_ticks "${ANS_OK[@]}")'s ingress, without \`${NS_REMOTE}\` (or a ReferenceGrant) there.$(late_note S7)"
		return 0
	fi
	if ((${#ANS_FAIL[@]} != n_others)); then
		echo "- ${label} — **INCONCLUSIVE** ($(ans_counts)): $(inconclusive_why S7 S9/S8 namespace)."
		return 0
	fi
	s7_codes="S7 (no \`${NS_REMOTE}\` there) returned $(codes_through S7 "${ANS_FAIL[@]}") ($(fail_meaning S7))$(again_note S7 "${ANS_FAIL[@]}"), while S9/S8, with the backend in the same namespace, answered 200 there and S7 answered 200 through \`${WORKLOAD_CTX}\` itself"
	answer_lists S7b S1
	if ((${#ANS_OK[@]} == n_others)); then
		echo "- ${label} — **YES**, it needs the namespace (for the ReferenceGrant) but not the Service: ${s7_codes}; S7b (namespace \`${NS_SHARED}\` and its ReferenceGrant there, no Service) answered 200 from \`${WORKLOAD_CTX}\`.$(late_note S7b)"
	elif [[ "$ANSWER1" == yes ]] && ((${#ANS_FAIL[@]} == n_others)); then
		echo "- ${label} — **YES**, it needs the namespace (for the ReferenceGrant): ${s7_codes}. S7b (namespace \`${NS_SHARED}\` and its ReferenceGrant there, no Service) failed like S2, $(codes_through S7b "${ANS_FAIL[@]}")$(again_note S7b "${ANS_FAIL[@]}"), while S1 answered there: consistent with the first answer, so it needs the Service too."
	else
		echo "- ${label} — **YES**, it needs the namespace (for the ReferenceGrant): ${s7_codes}. Whether it needs the Service too is **INCONCLUSIVE** ($(ans_counts)): $(inconclusive_why S7b S1 namespace)."
	fi
}

NS_LINES=("$(ns_line_service)" "$(ns_line Hostname S8 S9)" "$(ns_line "classic VirtualService" S9 S8)")

PRED_COUNTS="${n_match} MATCH$( ((n_ep_unread == 0)) || echo " (endpoints not read: ${n_ep_unread} rows)"), ${n_dev} DEVIATION, ${n_unk} UNKNOWN of $((n_match + n_dev + n_unk)) rows"

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
	printf '%s\n' "${NS_LINES[@]}"
	echo ""
	for o in "${OTHERS[@]}"; do
		echo "- HTTPRoute status on \`${o}\` for S2, whose Service exists only on the workload member: \`${R[$o|S2|obs_status]}\` (predicted \`${R[$o|S2|exp_status]}\`)."
		echo "- Through \`${o}\`'s ingress, backend namespace \`${NS_REMOTE}\` $([[ "${PRE[$o|remote_namespace]}" == absent ]] && echo "absent there" || echo "state there: \`${PRE[$o|remote_namespace]}\`"): S7 HTTP \`${R[$o|S7|codes]}\`, status \`${R[$o|S7|obs_status]}\` (predicted \`${R[$o|S7|exp_status]}\`); S8 HTTP \`${R[$o|S8|codes]}\`, status \`${R[$o|S8|obs_status]}\`; S9 HTTP \`${R[$o|S9|codes]}\`. S7b (namespace \`${NS_SHARED}\` and its ReferenceGrant expected there, no Service): HTTP \`${R[$o|S7b|codes]}\`, status \`${R[$o|S7b|obs_status]}\` (predicted \`${R[$o|S7b|exp_status]}\`)."
	done
	echo "- Predictions: ${PRED_COUNTS}."
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
			echo "- **${R[$ctx|$id|verdict]}** \`$(md_safe "$ctx")\` ($(role "$ctx")) ${id} \`${host}\`: $(md_safe "${R[$ctx|$id|detail]}") (row status ${R[$ctx|$id|row_status]}). Prediction (confidence: ${conf}): ${why}."
		done
	done
	((nd > 0)) || echo "None: every checked observation matched the prediction."
	echo ""
	echo "## Preflight (live, per member)"
	echo ""
	echo "| Member | Role | Scenario set | Gateway API CRD (bundle/channel) | GatewayClass istio | Gateway Programmed | Namespace labels | Echo Deployment | Backend namespace (S7-S9) | Echo there | S7b namespace / ReferenceGrants | Echo there | Backend Services | Ingress address |"
	echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		echo "| \`$(md_safe "$ctx")\` | $(role "$ctx") | $(md_safe "${DEPLOYED_SET[$ctx]}") | ${PRE[$ctx|crd]} | ${PRE[$ctx|gatewayclass]} | $(gw_programmed "${FINAL_SNAP}/m${i}") | ${PRE[$ctx|namespace]} | ${PRE[$ctx|echo]}; sidecar=${PRE[$ctx|echo_sidecar]} | ${PRE[$ctx|remote_namespace]} | ${PRE[$ctx|echo_remote]}; sidecar=${PRE[$ctx|echo_remote_sidecar]} | ${PRE[$ctx|shared_namespace]} / ${PRE[$ctx|shared_grants]} | ${PRE[$ctx|echo_shared]}; sidecar=${PRE[$ctx|echo_shared_sidecar]} | ${NS}: ${PRE[$ctx|svc_main]}; ${NS_SHARED}: ${PRE[$ctx|svc_shared]} | ${INGRESS_SOURCE[$ctx]:-none} |"
	done
	echo ""
	echo "Builds, pods and readiness (\`restarted\` 1 = a pod restarted, was replaced or added during the run; \`unknown\` = not measured):"
	echo ""
	echo "| Member | istiod image | Ingress istio-proxy image | Operator build | Istio CR version | Ingress replicas (pod read by istioctl) | istiod / ingress restarted | Data-plane gate passed after (s) |"
	echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
	for ctx in "${CONTEXTS[@]}"; do
		echo "| \`$(md_safe "$ctx")\` | \`$(md_safe "${PRE[$ctx|istiod_image]}")\` | \`$(md_safe "${PRE[$ctx|ingress_image]}")\` | ${PRE[$ctx|ossm_operator]} | ${PRE[$ctx|istio_cr_version]} | ${PRE[$ctx|ingress_replicas]} ($([[ "$PROXY_CONFIG_MODE" == istioctl* ]] && echo "\`${PC_POD[$ctx]}\`" || echo "not read")) | ${ISTIOD_RESTARTED[$ctx]} / ${INGRESS_RESTARTED[$ctx]} | ${DP_READY[$ctx]} |"
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
	platform_md_row "$(IFS=,; echo "${CONTEXTS[*]}")"
	echo "| Members | $(join_ticks "${CONTEXTS[@]}") (workload \`${WORKLOAD_CTX}\`) |"
	echo "| Requests per cell | ${REQUESTS}, curl --max-time ${TIMEOUT_SEC} s (detail ${GWAPI_DETAIL_TIMEOUT_SEC} s) |"
	echo "| Scenario set | \`${SCENARIO_SET}\` (chart revision \`${CHART_REVISION}\`, $([[ "$CHART_REVISION_VS_HARNESS" == differs ]] && echo "not the script's commit" || echo "vs the script's commit: ${CHART_REVISION_VS_HARNESS}")) |"
	echo "| Wait | ${WAIT_SEC} s of at most ${WAIT_TIMEOUT_SEC} s (timed out: ${WAIT_TIMED_OUT}); then the data-plane gate (${GATE_DESC}, ${GWAPI_GATE_PASSES} round(s) in a row) ${GATE_SEC} s; then settle ${GWAPI_SETTLE_SEC} s |"
	echo "| Traffic | ${TRAFFIC_START} to ${TRAFFIC_END} (UTC); ${REPROBE_CELLS} cell(s) that did not answer (predicted 200, or S7 through the other members) re-probed ${REPROBE_DELAY} s later |"
	echo "| Endpoint evidence | ${PROXY_CONFIG_MODE} |"
	echo "| Expected body | \`${EXPECTED_BODY}\` (${EXPECTED_BODY_SOURCE}) |"
	echo "| Data | \`$(basename "$TSV")\`$([[ -f "$ARGO_TSV" ]] && echo ", \`$(basename "$ARGO_TSV")\`")$([[ -f "${OUT_DIR}/run-config-${RUN_ID}.env" ]] && echo ", \`run-config-${RUN_ID}.env\`") |"
} >"$SUMMARY"

echo ""
echo "${HEADLINE//\*\*/}"
echo "${NS_HEADLINE//\*\*/}"
for line in "${NS_LINES[@]}"; do echo "  ${line//\*\*/}"; done
echo "Predictions: ${PRED_COUNTS}."
echo "TSV:     ${TSV}"
echo "Summary: ${SUMMARY}"
[[ ! -f "$ARGO_TSV" ]] || echo "Argo CD: ${ARGO_TSV}"
