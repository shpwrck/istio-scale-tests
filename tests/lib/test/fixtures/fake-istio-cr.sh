#!/usr/bin/env bash
# Answers the reads of istio_live_version (tests/lib/preamble.sh) for the kubectl stubs of
# the bats tests: the Sail Istio CR `default` (its .spec.version the alias v1.30-latest), its
# active IstioRevision and that revision's istiod Deployment, settled and rolled out unless
# set otherwise:
#   STUB_ISTIO_VERSION  the IstioRevision's .spec.version (default: ISTIO_VERSION_PIN once a
#                       run resolved it, else ISTIO_VERSION); fail: every read fails, as an
#                       unreachable member's does
#   STUB_ISTIO_STATE    the Istio CR's .status.state (default Healthy)
#   STUB_ISTIO_REV      its active revision (default `default`, InPlace; another name is
#                       RevisionBased, whose istiod Deployment is istiod-<rev>)
#   STUB_ISTIO_CR_GEN / STUB_ISTIO_REV_GEN   the generations (default 2, always observed)
#   STUB_ISTIOD_STATUS  the istiod Deployment's .status (default 2 replicas, all updated)
# A stub calls it for those reads:
#   *" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | \
#   *" get deployments.apps istiod -o json "*)
#       exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
set -euo pipefail
v="${STUB_ISTIO_VERSION:-${ISTIO_VERSION_PIN:-${ISTIO_VERSION:-}}}"
rev="${STUB_ISTIO_REV:-default}" vrev="" st='{"replicas":2,"updatedReplicas":2}'
[[ "$rev" == default ]] || vrev="$rev"
if [[ "$v" == fail ]]; then
	echo 'error: You must be logged in to the server (Unauthorized)' >&2
	exit 1
fi
case " $* " in
*" get istios.sailoperator.io default "*)
	jq -nc --arg s "${STUB_ISTIO_STATE:-Healthy}" --arg rev "$rev" --argjson g "${STUB_ISTIO_CR_GEN:-2}" \
		'{metadata: {name: "default", generation: $g}, spec: {version: "v1.30-latest"},
		  status: {state: $s, observedGeneration: $g, activeRevisionName: $rev, revisions: {inUse: 1}}}' ;;
*" get istiorevisions.sailoperator.io ${rev} "*)
	jq -nc --arg v "$v" --arg rev "$rev" --arg vrev "$vrev" --argjson g "${STUB_ISTIO_REV_GEN:-2}" \
		'{metadata: {name: $rev, generation: $g}, spec: {version: $v, namespace: "istio-system", values: {revision: $vrev}},
		  status: {observedGeneration: $g}}' ;;
*" -n istio-system get deployments.apps istiod${vrev:+-${vrev}} -o json "*)
	jq -nc --argjson st "${STUB_ISTIOD_STATUS:-$st}" \
		'{metadata: {name: "istiod", generation: 2}, status: ({observedGeneration: 2} + $st)}' ;;
*) exit 1 ;;
esac
