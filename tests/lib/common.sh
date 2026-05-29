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
