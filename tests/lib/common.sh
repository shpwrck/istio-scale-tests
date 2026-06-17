#!/usr/bin/env bash
# Shared utility functions sourced by all test suites.
# Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane, dataplane, propagation, tuning
#
# Exposes:
#   die <msg>                         -> exit 1 with stderr message
#   split_csv <csv> <out_arrayname>   -> trim+split CSV into named array
#   is_pos_int <val>                  -> return 0 if val is a positive integer
#   is_nonneg_int <val>               -> return 0 if val is a non-negative integer
#   validate_scoping <val>            -> die if val is not none|namespace|explicit
#   kube_client_flags                 -> echo shared client rate-limit flags
#                                        (--qps/--burst from KUBE_CLIENT_QPS/BURST)
#   resolve_kubectl <out_arrayname>   -> resolve oc|kubectl into the named array,
#                                        appended with kube_client_flags (P1-1)
#
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# shellcheck disable=SC2329
die() { echo "error: $*" >&2; exit 1; }

# shellcheck disable=SC2329
split_csv() {
	local csv="$1"
	local -n _out="$2"
	_out=()
	local x
	IFS=',' read -ra _raw <<<"$csv"
	for x in "${_raw[@]}"; do
		x="${x#"${x%%[![:space:]]*}"}"
		x="${x%"${x##*[![:space:]]}"}"
		[[ -n "$x" ]] && _out+=("$x")
	done
}

# shellcheck disable=SC2329
is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# shellcheck disable=SC2329
is_nonneg_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

# shellcheck disable=SC2329
validate_scoping() {
	case "$1" in
	none | namespace | explicit) return 0 ;;
	*) die "--sidecar-scoping must be one of [none, namespace, explicit]; got '$1'" ;;
	esac
}

# kube_client_flags: echo the shared client-go rate-limit flags (P1-1) so every
# oc/kubectl in the suites raises the default QPS=5/Burst=10 ceiling that becomes
# the dominant client-side apiserver throttle at ~20 contexts. Reads
# KUBE_CLIENT_QPS / KUBE_CLIENT_BURST (config/options.env; defaults 30/60). A
# value <= 0 (or non-integer) OMITS that flag so an old oc/kubectl that lacks
# --qps/--burst still works (operator can disable per-flag). request-timeout is
# applied per-call by the scrape/get helpers, so it is intentionally NOT added
# here (would double up with the existing per-call --request-timeout).
# shellcheck disable=SC2329
kube_client_flags() {
	local qps="${KUBE_CLIENT_QPS:-30}" burst="${KUBE_CLIENT_BURST:-60}"
	if [[ "$qps" =~ ^[1-9][0-9]*$ ]]; then printf -- '--qps=%s ' "$qps"; fi
	if [[ "$burst" =~ ^[1-9][0-9]*$ ]]; then printf -- '--burst=%s ' "$burst"; fi
}

# resolve_kubectl <out_arrayname>: resolve the cluster CLI (prefer oc, then
# kubectl) into the named bash array, with the shared client rate-limit flags
# appended (kube_client_flags). Centralizes the `KUBECTL=(oc)`/`(kubectl)`
# construction repeated across every suite so the QPS/Burst raise lands on every
# invocation in ONE place (P1-1). Dies if neither CLI is found. Callers that
# tolerate a missing CLI (dry-run-only plan paths) should keep their own guarded
# construction instead of calling this.
# shellcheck disable=SC2329
resolve_kubectl() {
	local -n _kc="$1"
	local -a _flags=()
	# shellcheck disable=SC2046
	read -ra _flags <<<"$(kube_client_flags)"
	if command -v oc >/dev/null 2>&1; then
		_kc=(oc "${_flags[@]}")
	elif command -v kubectl >/dev/null 2>&1; then
		_kc=(kubectl "${_flags[@]}")
	else
		die "neither oc nor kubectl found on PATH"
	fi
}
