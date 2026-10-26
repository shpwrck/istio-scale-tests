#!/usr/bin/env bash
# Preflight: is this machine, and is the mesh, ready for the test suites? Checks the local
# tools, that every member context answers and is a mesh member (not the hub), that each
# member's wiring gate is Ready with one shared root CA, and that the members run the pinned
# Istio version. Read-only, except --echo, which deploys the mesh-verify echo app from the hub,
# calls it through a member's ingress gateway until every member has answered, and removes it.
#
# Usage:
#   tests/preflight/001-check-mesh.sh [--contexts CSV] [--hub-context CTX --echo] [--dry-run]
# ci-dry-run: --contexts ci-a,ci-b --hub-context ci-hub --echo
set -euo pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
	echo "error: bash ${BASH_VERSION} is too old: the harness needs bash 4.3 or later (macOS: brew install bash, then run the scripts with that bash)" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Whether SETUP_CONTEXTS came from the operator or is versions.env's example default.
SETUP_CONTEXTS_GIVEN="${SETUP_CONTEXTS:+1}"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # istio_version_resolve

CONTEXTS_CSV=""
HUB_CTX="${PREFLIGHT_HUB_CONTEXT:-}"
GITOPS_NS="${PREFLIGHT_GITOPS_NAMESPACE:-}"
ECHO_TIMEOUT="${PREFLIGHT_ECHO_TIMEOUT_SEC:-600}"
ECHO_REQUESTS="${PREFLIGHT_ECHO_REQUESTS:-60}"
ECHO=0
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Checks that this machine and the mesh are ready for the test suites, and says how to fix
each problem it finds. Read-only, except --echo.

  --contexts CSV         Mesh members, never the hub (default: \$SETUP_CONTEXTS).
  --hub-context CTX      The hub's context, for --echo; also refused as a member
                         (default: \$PREFLIGHT_HUB_CONTEXT).
  --echo                 Also check traffic end to end: deploy the mesh-verify echo app from
                         the hub, call it through the first member's ingress gateway until
                         every member has answered, then remove it. Needs --hub-context.
  --gitops-namespace NS  The hub's Argo CD namespace (default: \$PREFLIGHT_GITOPS_NAMESPACE;
                         empty: argocd, else openshift-gitops).
  --echo-timeout SEC     Seconds to wait for the echo app on every member (default: ${ECHO_TIMEOUT}).
  --echo-requests N      Most requests to send before giving up on a member (default: ${ECHO_REQUESTS}).
  --dry-run              Print the checks without running them.
  -h, --help             Show this help.

Environment (config/options.env describes each): SETUP_CONTEXTS, PREFLIGHT_HUB_CONTEXT,
PREFLIGHT_GITOPS_NAMESPACE, PREFLIGHT_ECHO_TIMEOUT_SEC, PREFLIGHT_ECHO_REQUESTS,
ISTIO_VERSION (the pin, config/versions.env).

Exit codes: 0 every check passed (warnings may remain); 1 a check failed, or a bad flag.

See README.md, "Check the mesh".
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--hub-context)
		[[ -n "${2:-}" ]] || die "--hub-context requires a value"
		HUB_CTX="$2"
		shift 2
		;;
	--gitops-namespace)
		[[ -n "${2:-}" ]] || die "--gitops-namespace requires a value"
		GITOPS_NS="$2"
		shift 2
		;;
	--echo-timeout)
		[[ -n "${2:-}" ]] || die "--echo-timeout requires a value"
		ECHO_TIMEOUT="$2"
		shift 2
		;;
	--echo-requests)
		[[ -n "${2:-}" ]] || die "--echo-requests requires a value"
		ECHO_REQUESTS="$2"
		shift 2
		;;
	--echo)
		ECHO=1
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

is_pos_int "$ECHO_TIMEOUT" || die "--echo-timeout must be a positive number of seconds (got: ${ECHO_TIMEOUT})"
is_pos_int "$ECHO_REQUESTS" || die "--echo-requests must be a positive integer (got: ${ECHO_REQUESTS})"
((ECHO == 0)) || [[ -n "$HUB_CTX" ]] || die "--echo needs the hub's context: --hub-context <hub-ctx> (or PREFLIGHT_HUB_CONTEXT)"

if [[ -n "$CONTEXTS_CSV" ]]; then
	SETUP_CONTEXTS_GIVEN=1
else
	CONTEXTS_CSV="${SETUP_CONTEXTS:-}"
fi
CONTEXTS=()
split_contexts "$CONTEXTS_CSV" CONTEXTS "--contexts or SETUP_CONTEXTS"
((${#CONTEXTS[@]})) || die "no mesh members: pass --contexts <mesh-a-ctx>,<mesh-b-ctx> or export SETUP_CONTEXTS"
for ctx in "${CONTEXTS[@]}"; do
	[[ "$ctx" != "$HUB_CTX" ]] || die "--hub-context ${HUB_CTX} is also in the member list: list the mesh members only, never the hub"
done

FAILED=0
WARNED=0
ok() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$1"; [[ -z "${2:-}" ]] || printf '        %s\n' "$2"; WARNED=$((WARNED + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; [[ -z "${2:-}" ]] || printf '        fix: %s\n' "$2"; FAILED=$((FAILED + 1)); }
indent() { sed 's/^/        | /'; }

# The echo app's manifest, filled in from what the hub syncs (README, "Check the mesh").
echo_manifest() {
	sed -e "s|<repo-url>|${ECHO_REPO}|g" -e "s|<revision>|${ECHO_REV}|g" \
		-e "s|<platform>|${ECHO_PLATFORM}|g" -e "s|<gitops-namespace>|${GITOPS_NS}|g" \
		"${ROOT}/charts/mesh-verify-appset.yaml"
}

echo "Preflight: ${#CONTEXTS[@]} mesh member(s): ${CONTEXTS[*]}${HUB_CTX:+; hub ${HUB_CTX}}"
if [[ -z "${SETUP_CONTEXTS_GIVEN:-}" ]]; then
	echo "  (these are the example contexts from config/versions.env: pass --contexts or export SETUP_CONTEXTS)"
fi

if ((DRY_RUN)); then
	cat <<EOF
[dry-run] Would check:
  1. tools on this machine: kubectl or oc, helm, jq, curl, timeout (gtimeout on macOS); istioctl
     ${ISTIO_VERSION}, python3 with PyYAML (warnings only)
  2. each member context exists, answers, and has the Istio CR 'default' (the hub has none)
  3. each member's wiring gate: kubectl exec -n mesh-wiring-verify deploy/mesh-wiring-verify
     -- sh /opt/check/readiness.sh reads Ready, with the same root= on every member
  4. every member runs Istio ${ISTIO_VERSION} (ISTIO_VERSION) and is ready
EOF
	if ((ECHO)); then
		cat <<EOF
  5. end to end: apply charts/mesh-verify-appset.yaml (filled in from hub-gitops-root) on
     ${HUB_CTX}, wait up to ${ECHO_TIMEOUT}s for mesh-verify-echo on every member, curl
     http://<${CONTEXTS[0]} ingress>/ with Host mesh-verify.local up to ${ECHO_REQUESTS} times until
     every member answered, then delete the manifest again
EOF
	fi
	echo "Dry-run complete; nothing was checked."
	exit 0
fi

# --- 1. Tools ---
echo
echo "1. Tools on this machine"
KUBECTL=()
if command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
	ok "kubectl"
elif command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
	ok "oc (no kubectl; oc works the same)"
else
	fail "neither kubectl nor oc is on PATH" "install kubectl (https://kubernetes.io/docs/tasks/tools/)"
fi
for tool in helm jq curl; do
	if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else fail "$tool is not on PATH" "install ${tool} (README, \"What you need\")"; fi
done
if t="$(timeout_cmd)"; then ok "$t (GNU coreutils)"; else fail "neither timeout nor gtimeout is on PATH" "install GNU coreutils (macOS: brew install coreutils)"; fi
if command -v istioctl >/dev/null 2>&1; then
	iv="$(istioctl version --remote=false --short 2>/dev/null | head -n 1 | tr -d '\r' || true)"
	if [[ "${iv#v}" == "${ISTIO_VERSION#v}" ]]; then
		ok "istioctl ${iv}"
	else
		warn "istioctl is ${iv:-of unknown version}, not ${ISTIO_VERSION}" "only for diagnostics; put a matching istioctl first on PATH"
	fi
else
	warn "istioctl is not on PATH" "only for diagnostics (istioctl ${ISTIO_VERSION})"
fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
	ok "python3 with PyYAML"
else
	warn "python3 with PyYAML is missing" "only the tuning suite needs it (pip install pyyaml)"
fi
if ((${#KUBECTL[@]} == 0)); then
	echo
	echo "Stopped: the cluster checks need kubectl or oc."
	exit 1
fi

# --- 2. Contexts ---
echo
echo "2. Member contexts"
known="$("${KUBECTL[@]}" config get-contexts -o name 2>/dev/null || true)"
READY_CTXS=()
for ctx in "${CONTEXTS[@]}"; do
	if ! grep -qxF -- "$ctx" <<<"$known"; then
		if [[ -z "${SETUP_CONTEXTS_GIVEN:-}" ]]; then
			fail "${ctx}: no such context in your kubeconfig" "it is an example name: export SETUP_CONTEXTS=<mesh-a-ctx>,<mesh-b-ctx> (your members, from kubectl config get-contexts) or pass --contexts"
		else
			fail "${ctx}: no such context in your kubeconfig" "check the name with: ${KUBECTL[0]} config get-contexts"
		fi
		continue
	fi
	if ! err="$("${KUBECTL[@]}" --context "$ctx" --request-timeout=10s get --raw /version 2>&1 >/dev/null)"; then
		fail "${ctx}: the API server does not answer: $(head -n 1 <<<"$err")" "log in again, or check the network path to the cluster"
		continue
	fi
	if ! err="$("${KUBECTL[@]}" --context "$ctx" --request-timeout=10s get istios.sailoperator.io default -o name 2>&1)"; then
		if [[ "$err" == *"the server doesn't have a resource type"* ]]; then
			fail "${ctx}: no Sail operator here (no istios.sailoperator.io)" "is this the hub, or a cluster the mesh was not deployed to? List only mesh members"
		else
			fail "${ctx}: no Istio CR 'default': $(head -n 1 <<<"$err")" "is this the hub? Otherwise check the member's <member>-ossm Application on the hub"
		fi
		continue
	fi
	ok "${ctx}: answers, and runs the mesh's Istio CR"
	READY_CTXS+=("$ctx")
done
((${#CONTEXTS[@]} > 1)) || warn "only one member: every cross-cluster measurement needs two or more"

# --- 3. Wiring gate ---
echo
echo "3. Wiring gate (mesh-wiring-verify) on each member"
ROOTS=()
MEMBERS=""
for ctx in ${READY_CTXS[@]+"${READY_CTXS[@]}"}; do
	rc=0
	out="$(run_timeout 60s "${KUBECTL[@]}" --context "$ctx" --request-timeout=30s -n mesh-wiring-verify \
		exec deploy/mesh-wiring-verify -- sh /opt/check/readiness.sh 2>&1)" || rc=$?
	line="$(grep -m1 -E '^(Ready|NotReady):' <<<"$out" || true)"
	if ((rc == 0)) && [[ "$line" == Ready:* ]]; then
		ok "${ctx}: ${line}"
		r="$(grep -oE 'root=[^ ]+' <<<"$line" || true)"
		ROOTS+=("${r#root=}")
		m="$(grep -oE 'members=[^ ]+' <<<"$line" || true)"
		[[ -n "$MEMBERS" || "${m#members=}" == unchecked ]] || MEMBERS="${m#members=}"
	else
		fail "${ctx}: the gate is not Ready" "find its message in the README's Troubleshooting table"
		printf '%s\n' "${out:-no output (exit ${rc})}" | head -n 20 | indent
	fi
done
if ((${#ROOTS[@]} > 1)); then
	if [[ "$(printf '%s\n' "${ROOTS[@]}" | sort -u | wc -l | tr -d ' ')" == 1 ]]; then
		ok "every member reads the same root CA (root=${ROOTS[0]})"
	else
		fail "the members read different root CAs ($(printf '%s ' "${ROOTS[@]}"))" "a member's istiod started before cacerts arrived: README Troubleshooting, \"not using the shared mesh root\""
	fi
fi

# --- 4. Istio version ---
echo
echo "4. Istio version (pin ISTIO_VERSION=${ISTIO_VERSION})"
if ((${#READY_CTXS[@]})); then
	rc=0
	out="$( (ISTIO_VERSION_CHECK=fail istio_version_resolve "$(IFS=,; echo "${READY_CTXS[*]}")" 0 "${KUBECTL[@]}" \
		&& echo "Istio ${ISTIO_VERSION} on every member: ${ISTIO_VERSION_BY_CONTEXT}") 2>&1)" || rc=$?
	if ((rc == 0)); then
		ok "$(tail -n 1 <<<"$out")"
	else
		fail "the version check failed; the suites would stop on it" "upgrade the members, or bump ISTIO_VERSION in config/versions.env together with istioVersion in charts/spoke-ossm/values.yaml"
		grep -v '^warning:' <<<"$out" | sed 's/^error: //' | head -n 20 | indent
	fi
else
	warn "skipped: no member answered"
fi

# --- 5. End to end ---
if ((ECHO)); then
	echo
	echo "5. End to end: the echo app through ${CONTEXTS[0]}'s ingress gateway"
	if ((FAILED)); then
		warn "skipped: fix the failures above first"
	else
		ECHO_REPO="" ECHO_REV="" ECHO_PLATFORM=""
		for ns in ${GITOPS_NS:-argocd openshift-gitops}; do
			if out="$("${KUBECTL[@]}" --context "$HUB_CTX" --request-timeout=10s -n "$ns" get applications.argoproj.io hub-gitops-root \
				-o jsonpath='{.spec.source.repoURL} {.spec.source.targetRevision}' 2>/dev/null)" && [[ "$out" == *" "?* ]]; then
				read -r ECHO_REPO ECHO_REV <<<"$out"
				GITOPS_NS="$ns"
				break
			fi
		done
		if [[ -z "$ECHO_REPO" ]]; then
			fail "no hub-gitops-root Application on ${HUB_CTX} (looked in: ${GITOPS_NS:-argocd openshift-gitops})" "is ${HUB_CTX} the hub, and has terraform/platform been applied? Pass --gitops-namespace for another Argo CD namespace"
		else
			if [[ "$GITOPS_NS" == openshift-gitops ]]; then ECHO_PLATFORM=openshift; else ECHO_PLATFORM=kubernetes; fi
			# Removed on every exit from here on, whatever happens.
			trap 'echo_manifest | "${KUBECTL[@]}" --context "$HUB_CTX" delete --wait=false -f - >/dev/null 2>&1 || echo "warning: could not remove the echo app; on the hub: kubectl -n ${GITOPS_NS} delete application mesh-verify-appset" >&2' EXIT
			if ! err="$(echo_manifest | "${KUBECTL[@]}" --context "$HUB_CTX" apply -f - 2>&1)"; then
				fail "could not apply the echo app on ${HUB_CTX}: $(head -n 1 <<<"$err")"
			else
				ok "applied the echo app from ${ECHO_REPO} at ${ECHO_REV} (Argo CD namespace ${GITOPS_NS})"
				deadline=$((SECONDS + ECHO_TIMEOUT))
				waiting=("${CONTEXTS[@]}")
				while ((${#waiting[@]})) && ((SECONDS < deadline)); do
					still=()
					for ctx in "${waiting[@]}"; do
						"${KUBECTL[@]}" --context "$ctx" --request-timeout=10s -n mesh-verify rollout status deploy/mesh-verify-echo --timeout=5s >/dev/null 2>&1 \
							|| still+=("$ctx")
					done
					waiting=(${still[@]+"${still[@]}"})
					((${#waiting[@]} == 0)) || sleep 5
				done
				if ((${#waiting[@]})); then
					fail "the echo app is not running after ${ECHO_TIMEOUT}s on: ${waiting[*]}" "on the hub, check the mesh-verify Applications: kubectl -n ${GITOPS_NS} get applications.argoproj.io | grep mesh-verify"
				else
					ok "the echo app runs on every member"
					ingress="$("${KUBECTL[@]}" --context "${CONTEXTS[0]}" --request-timeout=10s -n istio-system get svc istio-ingressgateway \
						-o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
					if [[ -z "$ingress" ]]; then
						fail "${CONTEXTS[0]}'s ingress gateway Service has no external address" "README Troubleshooting: \"Gateway Applications stay Progressing\""
					else
						# Which answers to expect: the gate's member names, else one per context.
						expected=()
						split_csv "$MEMBERS" expected
						want=${#expected[@]}
						((want)) || want=${#CONTEXTS[@]}
						declare -A seen=()
						n=0
						while ((n < ECHO_REQUESTS && ${#seen[@]} < want)); do
							n=$((n + 1))
							body="$(curl -sS --max-time 5 -H 'Host: mesh-verify.local' "http://${ingress}/" 2>/dev/null | tr -d '\r\n' || true)"
							[[ -z "$body" ]] || seen["$body"]=1
						done
						missing=()
						for m in ${expected[@]+"${expected[@]}"}; do
							[[ -n "${seen[$m]+x}" ]] || missing+=("$m")
						done
						if ((${#seen[@]} >= want && ${#missing[@]} == 0)); then
							ok "every member answered within ${n} requests: $(printf '%s ' "${!seen[@]}")"
						else
							fail "after ${n} requests, answers came from: $(printf '%s ' "${!seen[@]}")${missing[*]:+; never from: ${missing[*]}}" "a member that never answers cannot be reached through the east-west gateways: check its gate and its east-west gateway's address"
						fi
					fi
				fi
			fi
		fi
	fi
fi

echo
warned=""
((WARNED == 0)) || warned=" (${WARNED} warning(s) above)"
if ((FAILED)); then
	echo "Preflight FAILED: ${FAILED} check(s) failed${warned}. Fix them, then run it again."
	exit 1
fi
echo "Preflight passed${warned}. Next: run a suite (README, \"Run a suite\")."
