#!/usr/bin/env bash
# Helpers shared by tests/tuning/001-apply-profile.sh, 002-revert-profile.sh,
# 003-run-tuning-sweep.sh and 005-cleanup.sh. Sourced, never executed. Expects a KUBECTL
# array (see resolve_kubectl).
#
#   ctx_key <ctx>                     -> file-name-safe form of a context name
#   ctx_keys_distinct <ctx>...        -> die when a context is listed twice, or two
#                                        contexts have one ctx_key (their state files
#                                        would be one file)
#   wait_for_istiod <ctx> <timeout> [<deadline>]
#                                     -> wait for the Sail operator to reconcile the
#                                        Istio CR and its active IstioRevision, then
#                                        for the istiod Deployment rollout, until
#                                        <deadline> (epoch seconds; default: now +
#                                        <timeout>). The members of one round, patched
#                                        before it waits for any, share one deadline, so
#                                        a round costs one timeout, not one per member.
# shellcheck shell=bash

# shellcheck disable=SC2329
ctx_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# shellcheck disable=SC2329
ctx_keys_distinct() {
	local ctx k
	local -A seen=()
	for ctx in "$@"; do
		k="$(ctx_key "$ctx")"
		if [[ -n "${seen[$k]+x}" ]]; then
			[[ "${seen[$k]}" != "$ctx" ]] || die "context ${ctx} is listed twice; list each member once"
			die "contexts ${seen[$k]} and ${ctx} have one state file name (${k}: a context name keeps only letters, digits, '.', '_' and '-' there); list each member once, under names that differ there"
		fi
		seen[$k]="$ctx"
	done
}

# shellcheck disable=SC2329
wait_for_istiod() {
	local ctx="$1" timeout="$2" deadline="${3:-}" line gen obs rec rev deploy left
	[[ -n "$deadline" ]] || deadline=$(($(date +%s) + timeout))
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
	# What is left of the deadline (at least 1s: a rollout that is done passes at once).
	left=$((deadline - $(date +%s)))
	((left >= 1)) || left=1
	"${KUBECTL[@]}" --context="$ctx" -n istio-system rollout status "deployment/${deploy}" \
		--timeout="${left}s"
}
