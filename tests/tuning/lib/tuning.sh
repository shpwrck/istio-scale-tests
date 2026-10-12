#!/usr/bin/env bash
# Helpers shared by tests/tuning/001-apply-profile.sh and 002-revert-profile.sh.
# Sourced, never executed. Expects a KUBECTL array (see resolve_kubectl).
#
#   ctx_key <ctx>                     -> file-name-safe form of a context name
#   wait_for_istiod <ctx> <timeout>   -> wait for the Sail operator to reconcile the
#                                        Istio CR and its active IstioRevision, then
#                                        for the istiod Deployment rollout
# shellcheck shell=bash

# shellcheck disable=SC2329
ctx_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# shellcheck disable=SC2329
wait_for_istiod() {
	local ctx="$1" timeout="$2" deadline line gen obs rec rev deploy
	deadline=$(($(date +%s) + timeout))
	while :; do
		line="$("${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default \
			-o jsonpath='{.metadata.generation} {.status.observedGeneration} {.status.conditions[?(@.type=="Reconciled")].status} {.status.activeRevisionName}' 2>/dev/null)" || line=""
		read -r gen obs rec rev <<<"$line"
		if [[ -n "${rev:-}" && "${gen:-}" == "${obs:-}" && "${rec:-}" == "True" ]]; then
			line="$("${KUBECTL[@]}" --context="$ctx" get istiorevision.sailoperator.io "$rev" \
				-o jsonpath='{.metadata.generation} {.status.observedGeneration} {.status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null)" || line=""
			read -r gen obs rec <<<"$line"
			[[ -n "${gen:-}" && "$gen" == "${obs:-}" && "${rec:-}" == "True" ]] && break
		fi
		if (($(date +%s) >= deadline)); then
			echo "  ${ctx}: Sail operator did not reconcile within ${timeout}s" >&2
			return 1
		fi
		sleep 5
	done
	deploy="istiod"
	[[ "$rev" != "default" ]] && deploy="istiod-${rev}"
	"${KUBECTL[@]}" --context="$ctx" -n istio-system rollout status "deployment/${deploy}" \
		--timeout="${timeout}s"
}
