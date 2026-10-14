#!/usr/bin/env bash
# Shared utility functions sourced by all test suites.
# Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane, dataplane, propagation, tuning, gateway-api
#
# Exposes:
#   die <msg>                         -> exit 1 with stderr message
#   split_csv <csv> <out_arrayname>   -> trim+split CSV into named array; empty items
#                                        (",", "a,,b", "a, ") are dropped; always returns 0
#   is_pos_int <val>                  -> return 0 if val is a positive integer
#   is_nonneg_int <val>               -> return 0 if val is a non-negative integer
#   validate_scoping <val>            -> die if val is not none|namespace|explicit|wide
#   resolve_kubectl <out_arrayname>   -> set the named array to (kubectl) or (oc)
#   validate_traffic_config <val>     -> die if val is not none|vsdr
#   vsdr_service_count <svc> <every>  -> services that get a VS+DR (i mod every == 0)
#   validate_workload_mode <val>      -> die if val is not pods|config-only
#   validate_outside_mode <val>       -> die if val is not none|unlabeled|labeled
#   resume_preamble_scalar <tsv> <KEY> <var> <flag> <explicit>
#                                     -> on --resume, set var from the preamble's KEY;
#                                        die if an explicit flag conflicts with it
#   is_ratio <val>                    -> return 0 if val is a decimal in (0, 1]
#   is_dns_label_for <prefix> <ctx>   -> return 0 if ctx is a lowercase DNS-1035 label
#                                        and <prefix><ctx> fits a 63-char Service name
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
	# The loop's last test fails when the last item is empty ("a,,", "a, ", ","):
	# return 0 so a stray comma never kills a caller under set -e. A caller that
	# needs at least one item checks the array length itself.
	return 0
}

# shellcheck disable=SC2329
is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# shellcheck disable=SC2329
is_nonneg_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

# shellcheck disable=SC2329
validate_scoping() {
	case "$1" in
	none | namespace | wide | explicit) return 0 ;;
	*) die "--sidecar-scoping must be one of [none, namespace, explicit, wide]; got '$1'" ;;
	esac
}

# resolve_kubectl <out_arrayname>: set the named array to (kubectl), or (oc) if
# kubectl is not on PATH. Dies if neither is found. Callers that must work
# without a CLI (dry-run plan paths) should build their own array instead.
# shellcheck disable=SC2329
resolve_kubectl() {
	local -n _kc="$1"
	if command -v kubectl >/dev/null 2>&1; then
		_kc=(kubectl)
	elif command -v oc >/dev/null 2>&1; then
		_kc=(oc)
	else
		die "neither kubectl nor oc found on PATH"
	fi
}

# --- VirtualService/DestinationRule load axis (controlplane) ---

# validate_traffic_config <val>: the controlplane traffic-management mode.
# shellcheck disable=SC2329
validate_traffic_config() {
	case "$1" in
	none | vsdr) return 0 ;;
	*) die "--traffic-config must be one of [none, vsdr]; got '$1'" ;;
	esac
}

# vsdr_service_count <service_count> <every>: how many of services 0..N-1 get a
# VirtualService + DestinationRule, i.e. the i with i mod every == 0: ceil(N / every).
# Mirrors controlplane-test.vsdrFor in tests/controlplane/chart/templates/_helpers.tpl.
# shellcheck disable=SC2329
vsdr_service_count() {
	local sc="$1" every="$2"
	is_nonneg_int "$sc" || die "vsdr_service_count: service count must be a non-negative integer; got '$sc'"
	is_pos_int "$every" || die "vsdr_service_count: every must be a positive integer; got '$every'"
	echo $(( (sc + every - 1) / every ))
}

# --- namespace scaling (controlplane growth mode) ---

# validate_workload_mode <val>: pods (a Deployment per Service) or config-only
# (Services without pods plus a few measurement pods).
# shellcheck disable=SC2329
validate_workload_mode() {
	case "$1" in
	pods | config-only) return 0 ;;
	*) die "--workload-mode must be one of [pods, config-only]; got '$1'" ;;
	esac
}

# validate_outside_mode <val>: namespaces outside the mesh: none, unlabeled (not
# discovered) or labeled (istio-discovery=enabled, discovered but not injected).
# shellcheck disable=SC2329
validate_outside_mode() {
	case "$1" in
	none | unlabeled | labeled) return 0 ;;
	*) die "--outside-mode must be one of [none, unlabeled, labeled]; got '$1'" ;;
	esac
}

# resume_preamble_scalar <tsv> <KEY> <var> <flag> <explicit>: reconcile a sweep-level
# scalar on --resume. Such a scalar is recorded once, as `# KEY=value` in the TSV
# preamble, not in each row, so every row of one TSV must share it. Sets the variable
# named <var> to the recorded value, with a note on stderr when it held another value
# the operator did not pass explicitly (explicit=0). Dies when they passed <flag> with
# another value (explicit=1), or when the preamble has no `# KEY=` line.
# shellcheck disable=SC2329
resume_preamble_scalar() {
	local _rps_tsv="$1" _rps_key="$2" _rps_flag="$4" _rps_explicit="$5" _rps_rec
	local -n _rps_val="$3"
	# Preamble only: stop at the header row.
	_rps_rec="$(awk -v k="# ${_rps_key}=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_rps_tsv")"
	[[ -n "$_rps_rec" ]] || die "--resume: ${_rps_tsv} has no '# ${_rps_key}=' preamble line, so ${_rps_flag} cannot be checked against it. Start a new sweep."
	[[ "$_rps_rec" == "$_rps_val" ]] && return 0
	if [[ "$_rps_explicit" == 1 ]]; then
		die "--resume: ${_rps_flag} ${_rps_val} differs from ${_rps_key}=${_rps_rec} in the resumed sweep's preamble; every row of one TSV shares it. Pass ${_rps_flag} ${_rps_rec} (or leave it out), or start a new sweep."
	fi
	echo "note: --resume: using ${_rps_key}=${_rps_rec} from the resumed sweep's preamble (this run had ${_rps_val})" >&2
	_rps_val="$_rps_rec"
}

# --- dataplane local baseline: ratio flags (--min-qps-ratio, DATAPLANE_MIN_PCT_200) ---

# is_ratio <val>: true for a plain decimal in (0, 1], e.g. 0.95, .5, 1, 1.0.
# shellcheck disable=SC2329
is_ratio() {
	[[ "$1" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || return 1
	awk -v v="$1" 'BEGIN { exit !(v + 0 > 0 && v + 0 <= 1) }'
}

# --- remote reachability: per-cluster Service names (dataplane-server-<ctx>, fortio-server-<ctx>) ---

# is_dns_label_for <prefix> <ctx>: true when <ctx> is a lowercase DNS-1035 label
# (a letter first, then letters, digits and '-', no '-' last) and <prefix><ctx>
# is at most 63 characters, so it can name a per-cluster Service.
# shellcheck disable=SC2329
is_dns_label_for() {
	local prefix="$1" ctx="$2"
	[[ "$ctx" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] && (( ${#prefix} + ${#ctx} <= 63 ))
}
