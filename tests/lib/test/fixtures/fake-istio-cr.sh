#!/usr/bin/env bash
# Answers the reads of istio_live_version (tests/lib/preamble.sh) for the kubectl stubs of
# the bats tests: a settled InPlace Istio CR `default` (Healthy, generation reconciled, one
# revision in use) whose IstioRevision `default` (settled, -o json) runs
# STUB_ISTIO_VERSION, else the pin (ISTIO_VERSION_PIN once a run resolved it, else
# ISTIO_VERSION). STUB_ISTIO_VERSION=fail fails both reads the way an unreachable member
# does. The CR is Healthy, so the istiod Deployment is never read. A stub calls it for
# those reads:
#   *" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "*)
#       exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
set -euo pipefail
v="${STUB_ISTIO_VERSION:-${ISTIO_VERSION_PIN:-${ISTIO_VERSION:-}}}"
if [[ "$v" == fail ]]; then
	echo 'error: You must be logged in to the server (Unauthorized)' >&2
	exit 1
fi
case " $* " in
*" get istios.sailoperator.io default "*)
	printf '%s\n' '{"metadata":{"name":"default","generation":2},"spec":{"version":"v1.30-latest"},"status":{"state":"Healthy","observedGeneration":2,"activeRevisionName":"default","revisions":{"total":1,"ready":1,"inUse":1},"conditions":[{"type":"Reconciled","status":"True"},{"type":"Ready","status":"True"},{"type":"DependenciesHealthy","status":"True"}]}}' ;;
*" get istiorevisions.sailoperator.io default "*)
	jq -nc --arg v "$v" '{metadata: {name: "default", generation: 2}, spec: {version: $v, namespace: "istio-system", values: {revision: ""}},
		status: {observedGeneration: 2, state: "Healthy"}}' ;;
*) exit 1 ;;
esac
