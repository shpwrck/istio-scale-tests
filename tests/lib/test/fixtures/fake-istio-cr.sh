#!/usr/bin/env bash
# Answers the reads of istio_live_version (tests/lib/preamble.sh) for the kubectl stubs of
# the bats tests: a settled InPlace Istio CR `default` (Healthy, generation reconciled, one
# revision in use) whose IstioRevision `default` (settled, -o json) runs
# STUB_ISTIO_VERSION, else the pin (ISTIO_VERSION_PIN once a run resolved it, else
# ISTIO_VERSION), with its istiod Deployment rolled out (read on the Healthy path too).
# STUB_ISTIO_VERSION=fail fails every read the way an unreachable member does.
# STUB_ISTIO_CR_GEN / STUB_ISTIO_REV_GEN set the Istio CR's / IstioRevision's generation
# (default 2, always reconciled: observedGeneration follows it). A stub calls it for those reads:
#   *" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | \
#   *" get deployments.apps istiod -o json "*)
#       exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
set -euo pipefail
v="${STUB_ISTIO_VERSION:-${ISTIO_VERSION_PIN:-${ISTIO_VERSION:-}}}"
if [[ "$v" == fail ]]; then
	echo 'error: You must be logged in to the server (Unauthorized)' >&2
	exit 1
fi
case " $* " in
*" get istios.sailoperator.io default "*)
	g="${STUB_ISTIO_CR_GEN:-2}"
	printf '%s\n' '{"metadata":{"name":"default","generation":'"$g"'},"spec":{"version":"v1.30-latest"},"status":{"state":"Healthy","observedGeneration":'"$g"',"activeRevisionName":"default","revisions":{"total":1,"ready":1,"inUse":1},"conditions":[{"type":"Reconciled","status":"True"},{"type":"Ready","status":"True"},{"type":"DependenciesHealthy","status":"True"}]}}' ;;
*" get istiorevisions.sailoperator.io default "*)
	jq -nc --arg v "$v" --argjson g "${STUB_ISTIO_REV_GEN:-2}" '{metadata: {name: "default", generation: $g}, spec: {version: $v, namespace: "istio-system", values: {revision: ""}},
		status: {observedGeneration: $g, state: "Healthy"}}' ;;
*" -n istio-system get deployments.apps istiod -o json "*)
	printf '%s\n' '{"metadata":{"name":"istiod","generation":2},"status":{"observedGeneration":2,"replicas":1,"updatedReplicas":1,"readyReplicas":1}}' ;;
*) exit 1 ;;
esac
