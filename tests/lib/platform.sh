#!/usr/bin/env bash
# Platform of a mesh member, the suite-chart overlay for it, and the platform record. Sourced,
# never executed.
#
# Consumers: every suite script that takes TEST_PLATFORM (platform_validate; the setups:
# platform_chart_args); the TSV writers and placeholders of propagation, churn, churn-dataplane,
# controlplane and dataplane (platform_probe, platform_preamble_lines, platform_md_row), their
# reports (platform_report_values, platform_report_warnings) and sweeps (platform_probe_share,
# platform_start_warnings, platform_drift_check); gateway-api 001; tuning 001 and 003
# (platform_tuning_objects_refuse; 003: each pass's record and drift check), 004 (the passes'
# records), 005 (the profile label and kinds) and 006 (the hub's Argo CD namespace).
#
# The suite charts default to Kubernetes: their pods run as a numeric non-root UID (runAsUser),
# because the busybox and fortio images run as root and runAsNonRoot cannot start them
# otherwise. OpenShift assigns each pod a UID from its namespace range and rejects any other, so
# on OpenShift the chart's values-openshift.yaml clears runAsUser.
#
# Requires KUBECTL (resolve_kubectl) and TEST_PLATFORM (config/options.env: auto, kubernetes or
# openshift). With DRY_RUN=1 and TEST_PLATFORM=auto no cluster is asked and the Kubernetes
# defaults render; TEST_PLATFORM=openshift previews the OpenShift render. Needs common.sh
# (split_csv, die, each_bounded, file_sha256, md_cell, yaml_str, sweep_problem, sweep_note);
# platform_probe and platform_drift_check need reach_sanitize (reach.sh: their warnings mask
# addresses).
#
# The platform record (PL2, PL36, PL39, PL47): what each member ran, read live before any
# measurement window, in every TSV preamble and every report format (PL19). Per member
# (<ctx>=<value>, comma-separated like KUBE_VERSIONS):
#   PLATFORM_BY_CONTEXT       kubernetes | openshift (whether it serves security.openshift.io/v1);
#                             PLATFORM over the members (mixed: both), TEST_PLATFORM the override
#                             that picks the charts' overlay (the record asks each member anyway)
#   MESH_OPERATOR_BY_CONTEXT  sail-operator:<tag>@<digest its pods run> (the Deployment
#                             sail-operator in sail-operator; @unknown when no pod has started),
#                             or servicemeshoperator3:<version> (OpenShift: its CSV in
#                             openshift-operators); absent when there is none. No readiness state
#                             (older TSVs end in /Available or /<phase>)
#   ISTIOD_IMAGE_BY_CONTEXT   istiod's discovery image (app=istiod in istio-system)
#   PROXY_IMAGE_BY_CONTEXT    the ingress and east-west gateways' istio-proxy image
#   NODE_PROVIDER_BY_CONTEXT  the scheme of the nodes' spec.providerID (kind, aws, ...; none:
#                             empty, left out beside a provider; no-nodes)
#   ISTIOD_ENV_BY_CONTEXT     12 hex digits of the sha256 of istiod's env (sorted name=value lines,
#                             without CLUSTER_ID): a profile's spec.values.pilot.env changes it
# Images keep the name, tag and the sha256 that ran (no registry host or path); none without such
# a pod; several "+"-joined (a rollout). unknown: not read (a warning says why). Values keep only
# [A-Za-z0-9_.:/@+-]. A TSV written before a key reads unknown for it.
#
# A sweep calls platform_probe for all its members, then platform_probe_share <sweep dir>: its
# steps read platform-record.txt there (PLATFORM_PROBE_FILE) when they source this file, and read
# only the members it lacks; there is no other reuse (tuning 003 probes each pass). After its last
# step, platform_drift_check reads the record again: a value that changed is a problem of the
# sweep's outcome (exit 4), one it cannot compare a note.
# shellcheck shell=bash

# Fixed by the charts: the Sail operator's namespace and Deployment
# (charts/gitops-hub-ocm-placement-appset/values-sail-operator.yaml) and OSSM's namespace and
# package (charts/spoke-ossm-operator).
PLATFORM_SAIL_NS=sail-operator
PLATFORM_SAIL_DEPLOY=sail-operator
PLATFORM_OSSM_NS=openshift-operators
PLATFORM_OSSM_PACKAGE=servicemeshoperator3
# A tuning profile's label, the kinds it may create and its marker (a ConfigMap on each member it
# is applied to; 005-cleanup.sh restores the Istio CR from it). Keep in sync with
# tests/tuning/lib/tuning.py (LABEL, ALLOWED_KINDS, MARKER_KIND, MARKER_NAMESPACE, MARKER_PREFIX),
# which platform.bats checks.
PLATFORM_TUNING_LABEL=istio-scale-tests/tuning-profile
PLATFORM_TUNING_RESOURCE_KINDS=destinationrules.networking.istio.io,sidecars.networking.istio.io,envoyfilters.networking.istio.io,telemetries.telemetry.istio.io
PLATFORM_TUNING_MARKER_KIND=configmaps
# shellcheck disable=SC2034  # PLATFORM_TUNING_MARKER_*: read by platform.bats (the tuning.py check)
PLATFORM_TUNING_MARKER_OBJECT_KIND=ConfigMap PLATFORM_TUNING_MARKER_NS=istio-system PLATFORM_TUNING_MARKER_PREFIX=tuning-profile-
PLATFORM_TUNING_KINDS="${PLATFORM_TUNING_RESOURCE_KINDS},${PLATFORM_TUNING_MARKER_KIND}"
# "<profile>:<Kind>/<ns>/<name>" per object, sorted and "+"-joined, or none.
# shellcheck disable=SC2016  # jq program: $label is a jq variable
PLATFORM_TUNING_JQ='[.items[]? | "\(.metadata.labels[$label] // "unlabelled"):\(.kind // "unknown")/\(.metadata.namespace // "-")/\(.metadata.name // "-")"]
	| unique | if length == 0 then "none" else join("+") end'
# Each read's kubectl --request-timeout, and how many members are read at once (options.env).
PLATFORM_READ_TIMEOUT="${PLATFORM_READ_TIMEOUT:-20s}"
PLATFORM_READ_PARALLEL="${PLATFORM_READ_PARALLEL:-20}"
# The record's preamble keys, in order; the per-member ones in the order of a member's values.
PLATFORM_KEYS=(PLATFORM TEST_PLATFORM PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT
	PROXY_IMAGE_BY_CONTEXT NODE_PROVIDER_BY_CONTEXT ISTIOD_ENV_BY_CONTEXT)
PLATFORM_ROW_KEYS=("${PLATFORM_KEYS[@]:2}")
_PL_UNKNOWN=$'unknown\tunknown\tunknown\tunknown\tunknown\tunknown'
PLATFORM_RECORD_FILE="platform-record.txt"

# This shell's record: each member's values (tab-separated) in _PL_ROW, the members in order in
# _PL_MEMBERS, those from the sweep's file in _PL_SHARED (sourcing this file again keeps them).
declare -gA _PL_ROW _PL_SHARED
declare -ga _PL_MEMBERS
# shellcheck disable=SC2329
_platform_put() {
	[[ -n "${_PL_ROW[$1]+x}" ]] || _PL_MEMBERS+=("$1")
	_PL_ROW[$1]="$2"
}
if [[ -n "${PLATFORM_PROBE_FILE:-}" ]]; then
	if [[ -r "$PLATFORM_PROBE_FILE" ]]; then
		while IFS=$'\t' read -r _pl_c _pl_v; do
			[[ -z "$_pl_c" ]] || { _PL_SHARED[$_pl_c]=1; _platform_put "$_pl_c" "$_pl_v"; }
		done <"$PLATFORM_PROBE_FILE"
		unset _pl_c _pl_v
	else
		echo "warning: cannot read the sweep's platform record (PLATFORM_PROBE_FILE: ${PLATFORM_PROBE_FILE}); this step reads its own members' record" >&2
	fi
fi

# platform_of <ctx>: TEST_PLATFORM kubernetes or openshift as is; auto asks the cluster whether it
# serves security.openshift.io/v1. A member it cannot ask is an error, never a guess (the wrong
# overlay gets pods rejected).
# shellcheck disable=SC2329
platform_of() {
	case "${TEST_PLATFORM:-auto}" in
	kubernetes | openshift) echo "$TEST_PLATFORM" ;;
	auto) _platform_served "$1" " (set TEST_PLATFORM to skip the check)" ;;
	*)
		echo "error: TEST_PLATFORM must be auto, kubernetes or openshift (got: ${TEST_PLATFORM})" >&2
		return 1
		;;
	esac
}

# _platform_served <ctx> [hint]: openshift when the member serves security.openshift.io/v1, else
# kubernetes (one bounded api-versions read); return 1 with kubectl's message when it cannot.
# shellcheck disable=SC2329
_platform_served() {
	local versions
	if ! versions="$("${KUBECTL[@]}" --context="$1" --request-timeout="$PLATFORM_READ_TIMEOUT" api-versions 2>&1)"; then
		echo "error: cannot list the API versions of context $1 to tell Kubernetes from OpenShift${2:-}: ${versions}" >&2
		return 1
	fi
	if grep -qx 'security.openshift.io/v1' <<<"$versions"; then echo openshift; else echo kubernetes; fi
}

# platform_chart_args <chart-dir> <ctx> <out_arrayname>: the overlay args for <ctx>. With auto, a
# member the record holds as kubernetes or openshift is not asked again; any other is.
# shellcheck disable=SC2329
platform_chart_args() {
	local chart="$1" ctx="$2" platform=""
	local -n _pca_out="$3"
	_pca_out=()
	if ((${DRY_RUN:-0})) && [[ "${TEST_PLATFORM:-auto}" == auto ]]; then
		return 0
	fi
	if [[ "${TEST_PLATFORM:-auto}" == auto ]]; then
		platform="$(platform_member_value "$ctx" platform)"
		[[ "$platform" == kubernetes || "$platform" == openshift ]] || platform=""
	fi
	[[ -n "$platform" ]] || platform="$(platform_of "$ctx")" || return 1
	[[ "$platform" == openshift ]] || return 0
	if [[ ! -f "${chart}/values-openshift.yaml" ]]; then
		echo "error: ${chart} has no values-openshift.yaml for OpenShift member $ctx" >&2
		return 1
	fi
	_pca_out=(-f "${chart}/values-openshift.yaml")
}

# platform_validate: die unless TEST_PLATFORM is auto (or empty), kubernetes or openshift,
# PLATFORM_READ_TIMEOUT a kubectl --request-timeout above zero and PLATFORM_READ_PARALLEL a whole
# number above zero. Call it with the other argument checks.
# shellcheck disable=SC2329
platform_validate() {
	case "${TEST_PLATFORM:-auto}" in
	auto | kubernetes | openshift) ;;
	*) die "TEST_PLATFORM must be auto, kubernetes or openshift (got: ${TEST_PLATFORM}); set it in the environment, config/options.env or, in a script that takes one, the --config file (auto, the default, asks each cluster)" ;;
	esac
	if [[ ! "$PLATFORM_READ_TIMEOUT" =~ ^([0-9]+(\.[0-9]+)?(ms|s|m|h))+$|^[0-9]+$ ||
		"$PLATFORM_READ_TIMEOUT" =~ ^(0+(\.0+)?(ms|s|m|h)?)+$ ]]; then
		die "PLATFORM_READ_TIMEOUT must be a kubectl --request-timeout above zero, such as 20s or 1m (got: ${PLATFORM_READ_TIMEOUT}); set it in the environment, config/options.env or, in a script that takes one, the --config file"
	fi
	[[ "$PLATFORM_READ_PARALLEL" =~ ^[1-9][0-9]*$ ]] ||
		die "PLATFORM_READ_PARALLEL must be a whole number above zero: how many members' platform records are read at once (got: ${PLATFORM_READ_PARALLEL}); set it in the environment, config/options.env or, in a script that takes one, the --config file"
}

# platform_gitops_namespace <hub_ctx>: openshift-gitops on OpenShift, argocd otherwise (terraform
# output gitops_namespace); return 1 with platform_of's message when the hub cannot tell.
# shellcheck disable=SC2329
platform_gitops_namespace() {
	local p
	p="$(platform_of "$1")" || return 1
	if [[ "$p" == openshift ]]; then echo openshift-gitops; else echo argocd; fi
}

# platform_pod_filter <container>: jq program over a pod list, "<images>\t<fingerprint>\t
# <running>\t<pod>". images: the container's image without registry host and path, plus the
# sha256 that ran (from the imageID), of the pods whose container started or whose spec pins a
# digest, those not terminated first; when none started, each spec image @unknown; unique,
# "+"-joined; none without such a pod. fingerprint: name@startTime#restarts per pod, sorted (a
# restart or a replaced pod changes it: PL9). running: Running pods. pod: the first Running one.
# shellcheck disable=SC2329
platform_pod_filter() {
	# shellcheck disable=SC2016  # jq program
	printf '%s' '. as $l
	| ([$l.items[]? | . as $p
	    | ([$p.spec.containers[]? | select(.name == "'"$1"'")][0].image // "") as $img
	    | ([$p.status.containerStatuses[]? | select(.name == "'"$1"'")][0].imageID // "") as $id
	    | select($img != "")
	    | {ref: ($img | sub("^.*/"; "")), pin: ($img | test("@")),
	       end: (($p.status.phase // "") | test("^(Failed|Succeeded)$")),
	       dig: ([$id | capture("(?<d>sha256:[0-9a-f]{64})")][0].d // "")}]
	   | (map(select(.pin or .dig != "")) as $ran | [$ran[] | select(.end | not)] as $live
	      | if ($live | length) > 0 then $live elif ($ran | length) > 0 then $ran else . end)
	   | map(.ref + (if .pin then "" elif .dig != "" then "@" + .dig else "@unknown" end))
	   | unique | if length == 0 then "none" else join("+") end) as $images
	| ([$l.items[]? | "\(.metadata.name)@\(.status.startTime // "-")#\([.status.containerStatuses[]?.restartCount // 0] | add // 0)"]
	   | sort | if length == 0 then "none" else join(",") end) as $fp
	| [$l.items[]? | select(.status.phase == "Running") | .metadata.name] as $run
	| "\($images)\t\($fp)\t\($run | length)\t\($run[0] // "-")"'
}

# _platform_sanitize_to <name> <value>: [A-Za-z0-9_.:/@+-] only, unknown when empty.
# shellcheck disable=SC2329
_platform_sanitize_to() {
	local _pl_st="${2//[^A-Za-z0-9_.:\/@+-]/_}"
	printf -v "$1" '%s' "${_pl_st:-unknown}"
}

# _platform_read <ctx> <out> <kubectl args...>: one bounded read (-o json) into <out>, stderr in
# <out>.err. Returns 0; 3 for NotFound or a kind not served; 2 for any other server answer
# (Forbidden, ...); 1 when the member did not answer.
# shellcheck disable=SC2329
_platform_read() {
	local ctx="$1" out="$2" rc=0
	shift 2
	"${KUBECTL[@]}" --context="$ctx" --request-timeout="$PLATFORM_READ_TIMEOUT" "$@" -o json >"$out" 2>"${out}.err" || rc=$?
	((rc != 0)) || return 0
	if grep -qE "Error from server \(NotFound\)|doesn't have a resource type" "${out}.err"; then return 3; fi
	if grep -q 'Error from server' "${out}.err"; then return 2; fi
	return 1
}

# _platform_why <err file>: the first 300 bytes of a read's stderr (or "the reply did not parse"),
# addresses masked when reach_sanitize is there, and the knob to raise when it ran out of time.
# shellcheck disable=SC2329
_platform_why() {
	local why
	why="$(head -c 300 "$1" 2>/dev/null)" || why=""
	why="${why:-the reply did not parse}"
	! declare -F reach_sanitize >/dev/null || why="$(reach_sanitize "$why")"
	if grep -qiE 'Client\.Timeout|deadline exceeded|i/o timeout|timeout exceeded|\(Timeout\)|timed out' "$1" 2>/dev/null; then
		why+="; no answer within PLATFORM_READ_TIMEOUT (${PLATFORM_READ_TIMEOUT}): raise it in the environment, config/options.env or the --config file, for a large or slow member"
	fi
	printf '%s\n' "$why"
}

# _platform_env_digest <pods.json> <workdir>: ISTIOD_ENV_BY_CONTEXT from the istio-system pod list:
# per istiod pod (those whose discovery container started, not terminated first), its env as
# sorted name=value lines (a valueFrom as its JSON, keys sorted) without CLUSTER_ID; the first 12
# hex digits of each distinct list's sha256, sorted and "+"-joined. none without an istiod pod;
# unknown when the list does not parse or no sha256 tool works.
# shellcheck disable=SC2329
_platform_env_digest() {
	local line d out="" i=0
	local -a _pl_dg=()
	# shellcheck disable=SC2016  # jq program: $c, $ran, ... are jq variables
	local env_jq='def canon: if type == "object" then "{" + ([to_entries | sort_by(.key)[] | (.key | tojson) + ":" + (.value | canon)] | join(",")) + "}"
			elif type == "array" then "[" + (map(canon) | join(",")) + "]" else tojson end;
		[.items[]? | select(.metadata.labels.app? == "istiod") | . as $p
		 | ([$p.spec.containers[]? | select(.name == "discovery")][0]) as $c
		 | select($c != null)
		 | {run: ([$p.status.containerStatuses[]? | select(.name == "discovery")][0].imageID // "" | test("sha256:[0-9a-f]{64}")),
		    end: (($p.status.phase // "") | test("^(Failed|Succeeded)$")),
		    env: ([$c.env[]? | select(.name != "CLUSTER_ID")
		      | .name + "=" + (if .valueFrom != null then (.valueFrom | canon) else (.value // "") end)] | sort)}]
		| (map(select(.run)) as $ran | [$ran[] | select(.end | not)] as $live
		   | if ($live | length) > 0 then $live elif ($ran | length) > 0 then $ran else . end)
		| map(.env | tojson) | unique | .[]'
	out="$(jq -r "$env_jq" "$1" 2>/dev/null)" || { echo unknown; return 0; }
	[[ -n "$out" ]] || { echo none; return 0; }
	while IFS= read -r line; do
		i=$((i + 1))
		printf '%s\n' "$line" >"${2}/env.${i}"
		d="$(file_sha256 "${2}/env.${i}")"
		[[ "$d" != unknown ]] || { echo unknown; return 0; }
		_pl_dg+=("${d:0:12}")
	done <<<"$out"
	printf '%s\n' "${_pl_dg[@]}" | LC_ALL=C sort -u | paste -sd '+' -
}

# _platform_probe_member <ctx> <workdir>: "<ctx>\t<value>..." (PLATFORM_ROW_KEYS) on stdout, a
# warning per value not read on stderr. After a read the member did not answer, the rest are not
# tried (each would wait out the timeout). The platform is what the member serves, whatever
# TEST_PLATFORM says (a disagreement warns); the operator is looked for on it (on TEST_PLATFORM's
# when it could not be asked: none there is then unknown, never absent).
# shellcheck disable=SC2329
_platform_probe_member() {
	local ctx="$1" w="$2" tp="${TEST_PLATFORM:-auto}" platform look op=unknown istiod=unknown proxy=unknown
	local nodes=unknown ienv=unknown rc=0 f v err
	local -a _pl_val=()
	# shellcheck disable=SC2016  # jq programs: $d, $sel, $img, ... are jq variables
	local sail_jq='([.items[]? | select(.kind == "Deployment" and .metadata.name == $name)][0]) as $d
		| if $d == null then "absent" else
		  ([$d.spec.template.spec.containers[]? | select(.name == $name) | .image][0] // "") as $img
		  | ($d.spec.selector.matchLabels // {}) as $sel
		  | ([.items[]? | select(.kind == "Pod") | select((.metadata.labels // {}) as $l | $sel | to_entries | all(.value == $l[.key]))
		      | {end: ((.status.phase // "") | test("^(Failed|Succeeded)$")),
		         dig: ([.status.containerStatuses[]? | select(.name == $name) | .imageID][0] // ""
		           | [capture("(?<d>sha256:[0-9a-f]{64})")][0].d // "")}
		      | select(.dig != "")]) as $ran
		  | ((if any($ran[]; .end | not) then [$ran[] | select(.end | not)] else $ran end) | map(.dig) | unique) as $digs
		  | ($img | split("/") | last // "" | split("@")) as $ref
		  | ($ref[0] | split(":")) as $nt
		  | ("sail-operator"
		    + (if $img == "" then ":unknown" elif ($nt | length) > 1 then ":" + $nt[1] elif ($ref | length) > 1 then "" else ":latest" end)) as $nm
		  | if ($ref | length) > 1 then $nm + "@" + $ref[1]
		    elif ($digs | length) > 0 then [$digs[] | $nm + "@" + .] | join("+")
		    else $nm + "@unknown" end
		  end'
	# shellcheck disable=SC2016  # jq program: $pkg is a jq variable
	local csv_jq='[.items[]? | select(.metadata.name | startswith($pkg + ".")) | "\($pkg):\(.spec.version // "unknown")"]
		| unique | if length == 0 then "absent" else join("+") end'
	local nodes_jq='[.items[]? | (.spec.providerID // "")
		| if . == "" then "none" elif test("^[A-Za-z][A-Za-z0-9.-]*://") then sub("://.*$"; "") else "unrecognized" end]
		| unique | (if length > 1 then map(select(. != "none")) else . end) | if length == 0 then "no-nodes" else join("+") end'
	err="${w}/platform.err"
	if ! platform="$(_platform_served "$ctx" 2>"$err")"; then
		platform=unknown v="the platform (so the mesh operator build is not read either)"
		[[ "$tp" == auto ]] || v="the platform it serves (its mesh operator is looked for where TEST_PLATFORM=${tp} says)"
		echo "warning: ${ctx}: could not read ${v}; recorded as unknown: $(_platform_why "$err")" >&2
		grep -q 'Error from server' "$err" || rc=1
	elif [[ "$tp" != auto && "$tp" != "$platform" ]]; then
		echo "warning: ${ctx}: TEST_PLATFORM=${tp}, but the member serves ${platform}: the record keeps ${platform} (PLATFORM_BY_CONTEXT), while the suite charts get the ${tp} overlay; set TEST_PLATFORM to auto or ${platform} unless that overlay is what you want" >&2
	fi
	look="$platform"
	[[ "$look" != unknown ]] || look="$tp"
	if ((rc == 0)) && [[ "$look" != auto ]]; then
		err="${w}/op.json.err"
		if [[ "$look" == kubernetes ]]; then
			_platform_read "$ctx" "${w}/op.json" -n "$PLATFORM_SAIL_NS" get deployments.apps,pods || rc=$?
			((rc != 0)) || op="$(jq -r --arg name "$PLATFORM_SAIL_DEPLOY" "$sail_jq" "${w}/op.json" 2>/dev/null)" || op=""
		else
			_platform_read "$ctx" "${w}/op.json" -n "$PLATFORM_OSSM_NS" get clusterserviceversions.operators.coreos.com || rc=$?
			((rc != 0)) || op="$(jq -r --arg pkg "$PLATFORM_OSSM_PACKAGE" "$csv_jq" "${w}/op.json" 2>/dev/null)" || op=""
		fi
		# A kind that is not served (no OLM on an "OpenShift" member) is unknown, never absent.
		if [[ "$rc" != 0 || -z "$op" ]]; then
			echo "warning: ${ctx}: could not read the mesh operator build; recorded as unknown: $(_platform_why "$err")" >&2
			op=unknown
		elif [[ "$op" == absent && "$platform" == unknown ]]; then
			echo "warning: ${ctx}: no mesh operator where TEST_PLATFORM=${tp} looks, and the platform the member serves could not be read; recorded as unknown, not absent" >&2
			op=unknown
		fi
		((rc == 1)) || rc=0
	fi
	if ((rc == 0)); then
		err="${w}/pods.json.err"
		if _platform_read "$ctx" "${w}/pods.json" -n istio-system get pods; then
			istiod="$(jq -r "{items: [.items[]? | select(.metadata.labels.app? == \"istiod\")]} | $(platform_pod_filter discovery)" \
				"${w}/pods.json" 2>/dev/null | cut -f1)" || istiod=""
			proxy="$(jq -r "{items: [.items[]? | select(.metadata.labels.istio? == \"ingressgateway\" or .metadata.labels.istio? == \"eastwestgateway\")]}
				| $(platform_pod_filter istio-proxy)" "${w}/pods.json" 2>/dev/null | cut -f1)" || proxy=""
			ienv="$(_platform_env_digest "${w}/pods.json" "$w")"
			[[ "$ienv" != unknown ]] || echo "the reply did not parse, or no sha256 tool (sha256sum, shasum) ran" >"$err"
		else
			rc=$?
		fi
		for f in istiod proxy ienv; do
			[[ -z "${!f}" || "${!f}" == unknown ]] || continue
			echo "warning: ${ctx}: could not read the ${f/ienv/istiod env} build; recorded as unknown: $(_platform_why "$err")" >&2
			printf -v "$f" unknown
		done
		((rc == 1)) || rc=0
	fi
	if ((rc == 0)); then
		err="${w}/nodes.json.err"
		_platform_read "$ctx" "${w}/nodes.json" get nodes || rc=$?
		((rc != 0)) || nodes="$(jq -r "$nodes_jq" "${w}/nodes.json" 2>/dev/null)" || nodes=""
		if [[ "$rc" != 0 || -z "$nodes" ]]; then
			echo "warning: ${ctx}: could not read the node provider; recorded as unknown: $(_platform_why "$err")" >&2
			nodes=unknown
		fi
	fi
	((rc != 1)) || echo "warning: ${ctx}: did not answer; its platform record stops here (the values not read are unknown)" >&2
	for v in "$platform" "$op" "$istiod" "$proxy" "$nodes" "$ienv"; do
		_platform_sanitize_to v "$v"
		_pl_val+=("$v")
	done
	printf '%s' "$ctx"
	printf '\t%s' "${_pl_val[@]}"
	printf '\n'
}

# _platform_read_members <tmp> <ctx>...: each member's values (_platform_probe_member,
# PLATFORM_READ_PARALLEL at a time), one line each in argument order (_PL_UNKNOWN for a read that
# failed outright); the warnings on stderr unless _pl_quiet=1 (dynamic scope).
# shellcheck disable=SC2329
_platform_read_members() {
	local tmp="$1" i row
	shift
	each_bounded "$PLATFORM_READ_PARALLEL" _platform_probe_member "$tmp" "$@"
	for ((i = 0; i < $#; i++)); do
		((${_pl_quiet:-0})) || cat "${tmp}/${i}.warn" >&2 2>/dev/null || true
		row="$(head -n 1 "${tmp}/${i}.row" 2>/dev/null || true)"
		[[ "$row" == *$'\t'* ]] || row=$'-\t'"$_PL_UNKNOWN"
		printf '%s\n' "${row#*$'\t'}"
	done
}

# platform_members_check <ctx>...: die when a member is listed twice, or when two members would be
# recorded under one name (_platform_sanitize_to): their values would be recorded as one member's.
# No cluster call: every script that probes calls it with its argument checks, so its --dry-run
# refuses what its run would.
# shellcheck disable=SC2329
platform_members_check() {
	local ctx c
	local -A _pl_seen=() _pl_name=()
	for ctx in "$@"; do
		[[ -n "$ctx" ]] || continue
		[[ -z "${_pl_seen[$ctx]+x}" ]] ||
			die "${ctx} is listed twice among the mesh members: list each member once (--contexts or SETUP_CONTEXTS; a probe's --source-context is not one of its --remote-contexts)"
		_pl_seen[$ctx]=1
		_platform_sanitize_to c "$ctx"
		[[ -z "${_pl_name[$c]+x}" ]] ||
			die "${_pl_name[$c]} and ${ctx} would be recorded under one name, ${c} (the record writes a member's name with A-Z, a-z, 0-9 and _.:/@+- only): rename one of the two contexts"
		_pl_name[$c]="$ctx"
	done
}

# platform_probe <ctxs_csv>: read the record of these members but those the sweep's file holds,
# in this shell (not in $(...)), before any measurement window. A value it cannot read is unknown
# with a warning; under DRY_RUN=1 every value is (nothing is read).
# shellcheck disable=SC2329
platform_probe() {
	local ctx i tmp
	local -a ctxs=() todo=() _pl_rows=()
	platform_validate
	declare -F reach_sanitize >/dev/null || die "platform_probe needs reach_sanitize (source tests/lib/reach.sh)"
	split_csv "$1" ctxs
	platform_members_check ${ctxs[@]+"${ctxs[@]}"}
	for ctx in ${ctxs[@]+"${ctxs[@]}"}; do
		[[ -z "$ctx" || -n "${_PL_SHARED[$ctx]+x}" ]] || todo+=("$ctx")
	done
	((${#todo[@]})) || return 0
	if ((${DRY_RUN:-0} == 0)); then
		[[ -n "${KUBECTL[*]:-}" ]] || die "neither kubectl nor oc found on PATH (platform_probe needs KUBECTL)"
		tmp="$(mktemp -d)" || die "platform_probe: no temp dir to read the platform record in"
		mapfile -t _pl_rows < <(_platform_read_members "$tmp" "${todo[@]}")
		rm -rf "$tmp"
	fi
	for i in "${!todo[@]}"; do _platform_put "${todo[i]}" "${_pl_rows[i]:-$_PL_UNKNOWN}"; done
}

# platform_probe_share <dir>: write this shell's record to <dir>/platform-record.txt and export
# its path (PLATFORM_PROBE_FILE) for the steps the sweep runs. Nothing under DRY_RUN=1.
# shellcheck disable=SC2329
platform_probe_share() {
	local f="${1}/${PLATFORM_RECORD_FILE}" ctx
	((${DRY_RUN:-0} == 0)) || return 0
	mkdir -p "$1" || die "platform_probe_share: cannot create $1"
	for ctx in ${_PL_MEMBERS[@]+"${_PL_MEMBERS[@]}"}; do
		printf '%s\t%s\n' "$ctx" "${_PL_ROW[$ctx]}"
	done >"$f" || die "platform_probe_share: cannot write ${f}: the steps of this sweep need the record it read"
	export PLATFORM_PROBE_FILE="$f"
}

# platform_recorded_contexts: every member of this shell's record, comma-separated.
# shellcheck disable=SC2329
platform_recorded_contexts() {
	local IFS=,
	printf '%s\n' "${_PL_MEMBERS[*]:-}"
}

# platform_member_value <ctx> <platform|operator|istiod|proxy|nodes|istiod_env>: one value of a
# member's record; unknown when it was not read.
# shellcheck disable=SC2329
platform_member_value() {
	local i
	local -a _pl_f=()
	case "$2" in
	platform) i=0 ;;
	operator) i=1 ;;
	istiod) i=2 ;;
	proxy) i=3 ;;
	nodes) i=4 ;;
	istiod_env) i=5 ;;
	*) die "platform_member_value: unknown field '$2' (platform, operator, istiod, proxy, nodes or istiod_env)" ;;
	esac
	[[ -z "$1" ]] || IFS=$'\t' read -r -a _pl_f <<<"${_PL_ROW[$1]:-}"
	printf '%s\n' "${_pl_f[i]:-unknown}"
}

# _platform_values <ctxs_csv>: the record as KEY=value lines (PLATFORM_KEYS order) for these
# members; a member never probed warns and reads unknown.
# shellcheck disable=SC2329
_platform_values() {
	local ctx v c j kinds=""
	local -a ctxs=() _pl_f=() _pl_by=()
	split_csv "$1" ctxs
	for ctx in ${ctxs[@]+"${ctxs[@]}"}; do
		[[ -n "$ctx" ]] || continue
		v="${_PL_ROW[$ctx]:-}"
		if [[ -z "$v" ]]; then
			echo "warning: ${ctx}: no platform record was read (platform_probe was not called for it); its values read unknown" >&2
			v="$_PL_UNKNOWN"
		fi
		IFS=$'\t' read -r -a _pl_f <<<"$v"
		[[ " ${kinds} " == *" ${_pl_f[0]} "* ]] || kinds+="${kinds:+ }${_pl_f[0]}"
		_platform_sanitize_to c "$ctx"
		for j in "${!PLATFORM_ROW_KEYS[@]}"; do _pl_by[j]="${_pl_by[j]:-}${_pl_by[j]:+,}${c}=${_pl_f[j]:-unknown}"; done
	done
	# mixed when the members run both platforms, else unknown when one of them could not be asked.
	if [[ " ${kinds} " == *" kubernetes "* && " ${kinds} " == *" openshift "* ]]; then
		echo "PLATFORM=mixed"
	elif [[ "$kinds" == kubernetes || "$kinds" == openshift ]]; then
		echo "PLATFORM=${kinds}"
	else
		echo "PLATFORM=unknown"
	fi
	_platform_sanitize_to v "${TEST_PLATFORM:-auto}"
	echo "TEST_PLATFORM=${v}"
	for j in "${!PLATFORM_ROW_KEYS[@]}"; do echo "${PLATFORM_ROW_KEYS[j]}=${_pl_by[j]:-unknown}"; done
}

# platform_preamble_lines <ctxs_csv>: the record's `# KEY=value` preamble lines for these
# members (the one emitter of every TSV writer and placeholder: PL36).
# shellcheck disable=SC2329
platform_preamble_lines() {
	local line
	while IFS= read -r line; do printf '# %s\n' "$line"; done < <(_platform_values "$1")
}

# platform_collapse <by_context value>: the one value every member shares, else the value as is.
# shellcheck disable=SC2329
platform_collapse() {
	local pair first=""
	local -a pairs=()
	IFS=',' read -r -a pairs <<<"$1"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		[[ "$pair" == *=* && ( -z "$first" || "${pair#*=}" == "$first" ) ]] || { printf '%s\n' "$1"; return 0; }
		first="${pair#*=}"
	done
	printf '%s\n' "${first:-$1}"
}

# platform_md_row <ctxs_csv>: the `| Platform | ... |` row of a run's markdown summary, next to
# its `| Run config | ... |` row; a value every member shares is shown once.
# shellcheck disable=SC2329
platform_md_row() {
	local line
	local -A _pl_rec=()
	while IFS= read -r line; do _pl_rec["${line%%=*}"]="$(platform_collapse "${line#*=}")"; done < <(_platform_values "$1" 2>/dev/null)
	printf '| Platform | %s (TEST_PLATFORM %s); nodes %s; operator %s; istiod %s; gateway proxy %s; istiod env %s |\n' \
		"${_pl_rec[PLATFORM]}" "${_pl_rec[TEST_PLATFORM]}" "${_pl_rec[NODE_PROVIDER_BY_CONTEXT]}" "${_pl_rec[MESH_OPERATOR_BY_CONTEXT]}" \
		"${_pl_rec[ISTIOD_IMAGE_BY_CONTEXT]}" "${_pl_rec[PROXY_IMAGE_BY_CONTEXT]}" "${_pl_rec[ISTIOD_ENV_BY_CONTEXT]}"
}

# platform_drift_check <ctxs_csv> [<what>]: after a sweep's last step (tuning 003: after each
# pass's probes; <what>: sweep, or the pass), read these members' record again and compare it
# with this shell's, key by key and member by member: a value that changed is a sweep_problem (the
# TSVs record the start's, and rows measured after the change ran on another build or setting); a
# value not read at either end is a sweep_note. Nothing in a dry-run; never dies.
# shellcheck disable=SC2329
platform_drift_check() {
	local what="${2:-sweep}" ctx i j a b tmp nc
	# shellcheck disable=SC2034  # read by _platform_read_members (dynamic scope)
	local _pl_quiet=1
	local -a ctxs=() _pl_rows=() _pl_a=() _pl_b=()
	((${DRY_RUN:-0} == 0)) || return 0
	split_csv "$1" ctxs
	((${#ctxs[@]})) || return 0
	if [[ -z "${KUBECTL[*]:-}" ]] || ! declare -F reach_sanitize >/dev/null || ! tmp="$(mktemp -d)"; then
		sweep_note "the platform record was not read again at the end of the ${what} (no kubectl, reach.sh or temp dir): a build that changed during it would go unseen"
		return 0
	fi
	mapfile -t _pl_rows < <(_platform_read_members "$tmp" "${ctxs[@]}")
	rm -rf "$tmp"
	for i in "${!ctxs[@]}"; do
		ctx="${ctxs[i]}"
		IFS=$'\t' read -r -a _pl_a <<<"${_PL_ROW[$ctx]:-$_PL_UNKNOWN}"
		IFS=$'\t' read -r -a _pl_b <<<"${_pl_rows[i]:-$_PL_UNKNOWN}"
		nc=""
		for j in "${!PLATFORM_ROW_KEYS[@]}"; do
			a="${_pl_a[j]:-unknown}" b="${_pl_b[j]:-unknown}"
			if [[ "$a" == *unknown* || "$b" == *unknown* ]]; then
				nc+="${nc:+, }${PLATFORM_ROW_KEYS[j]}"
			elif [[ "$a" != "$b" ]]; then
				sweep_problem "$(platform_short_digests "${PLATFORM_ROW_KEYS[j]} on ${ctx} changed during the ${what}: ${a} at its start, ${b} at its end: its rows are not all from one build")"
			fi
		done
		[[ -z "$nc" ]] ||
			sweep_note "${ctx}: ${nc} not compared between the start and the end of the ${what} (not read at one of them: unknown); a change there would go unseen"
	done
}

# platform_tuning_objects <ctx> [<dir>]: the tuning profile objects on the member
# (PLATFORM_TUNING_JQ), from one bounded read in <dir> (else a temp dir); return 1 with why on
# stderr when they cannot be listed.
# shellcheck disable=SC2329
platform_tuning_objects() {
	local w="${2:-}" own=0 rc=0 out=""
	if [[ -z "$w" ]]; then
		w="$(mktemp -d)" || { echo "no temp dir" >&2; return 1; }
		own=1
	fi
	_platform_read "$1" "${w}/tuning.json" get "$PLATFORM_TUNING_KINDS" -A -l "$PLATFORM_TUNING_LABEL" || rc=$?
	((rc != 0)) || out="$(jq -r --arg label "$PLATFORM_TUNING_LABEL" "$PLATFORM_TUNING_JQ" "${w}/tuning.json" 2>/dev/null)" || out=""
	if [[ -z "$out" ]]; then
		((rc != 0)) || : >"${w}/tuning.json.err"
		_platform_why "${w}/tuning.json.err" >&2
	fi
	((own == 0)) || rm -rf "$w"
	[[ -n "$out" ]] || return 1
	printf '%s\n' "$out"
}

# _platform_tuning_held <ctxs_csv>: platform_tuning_objects of each member, PLATFORM_READ_PARALLEL
# at a time, into _PL_HELD (the members that hold some), _PL_OBJS (those objects, each once),
# _PL_UNLISTED (the members whose cannot be listed) and _PL_WHY (those with why), ", "-joined.
# shellcheck disable=SC2329
_platform_tuning_held() {
	local i tmp v part
	local -a _pl_c=() _pl_parts=()
	local -A _pl_o=()
	_PL_HELD="" _PL_OBJS="" _PL_UNLISTED="" _PL_WHY=""
	split_csv "$1" _pl_c
	((${#_pl_c[@]})) || return 0
	tmp="$(mktemp -d)" || die "no temp dir to list the tuning profile objects in"
	each_bounded "$PLATFORM_READ_PARALLEL" platform_tuning_objects "$tmp" "${_pl_c[@]}"
	for i in "${!_pl_c[@]}"; do
		v="$(head -n 1 "${tmp}/${i}.row" 2>/dev/null || true)"
		if [[ -z "$v" ]]; then
			_PL_UNLISTED+="${_PL_UNLISTED:+, }${_pl_c[i]}"
			_PL_WHY+="${_PL_WHY:+, }${_pl_c[i]} ($(head -n 1 "${tmp}/${i}.warn" 2>/dev/null || true))"
		elif [[ "$v" != none ]]; then
			_PL_HELD+="${_PL_HELD:+, }${_pl_c[i]}"
			IFS=+ read -r -a _pl_parts <<<"$v"
			for part in "${_pl_parts[@]}"; do
				[[ -n "${_pl_o[$part]+x}" ]] || { _pl_o[$part]=1; _PL_OBJS+="${_PL_OBJS:+, }${part}"; }
			done
		fi
	done
	rm -rf "$tmp"
}

# _platform_cleanup_hint <ctxs_csv>: the tests/tuning/005-cleanup.sh command that undoes a profile
# left applied on these members (its marker restores each member's Istio CR from any checkout).
# shellcheck disable=SC2329
_platform_cleanup_hint() {
	local v="--contexts ${1}"
	((${#v} <= 200)) || v="the same --contexts"
	echo "./tests/tuning/005-cleanup.sh ${v} (add --results-dir <that run's --output-dir> if it had one, and --gitops-context <hub> to resume Argo CD if it paused it)"
}

# platform_tuning_objects_refuse <ctxs_csv> <what>: die when a member holds a tuning profile's
# objects or marker, or when a member's cannot be listed: <what> (tuning 001: "this profile";
# 003: "every pass of this sweep (the baseline included)") would be measured with them. Nothing
# in a dry-run.
# shellcheck disable=SC2329
platform_tuning_objects_refuse() {
	! ((${DRY_RUN:-0})) || return 0
	[[ -n "${KUBECTL[*]:-}" ]] || die "platform_tuning_objects_refuse needs KUBECTL (resolve_kubectl)"
	_platform_tuning_held "$1"
	[[ -z "$_PL_WHY" ]] ||
		die "the tuning profile objects (label ${PLATFORM_TUNING_LABEL}) could not be listed on ${_PL_WHY}: a member that cannot be asked may hold a profile's objects, and ${2} would be measured with them; fix the access (or raise PLATFORM_READ_TIMEOUT) and start again"
	[[ -z "$_PL_HELD" ]] ||
		die "a tuning profile's objects (label ${PLATFORM_TUNING_LABEL}) are on ${_PL_HELD} already: ${_PL_OBJS}. ${2^} would be measured with them. They are a tuning run still in progress on these members (wait for it to end), a profile left applied (a run stopped before its revert, in any checkout) or objects applied by hand; undo those with $(_platform_cleanup_hint "$1"), which also restores each member's Istio CR from the profile's marker, then start again"
}

# platform_start_warnings <ctxs_csv>: a sweep's warning as it starts (right after
# platform_probe_share) when a member holds a tuning profile's objects or marker, which every step
# would measure with, or when a member's cannot be listed; each also a sweep_note, which its
# reports print. Nothing in a dry-run.
# shellcheck disable=SC2329
platform_start_warnings() {
	((${DRY_RUN:-0} == 0)) && [[ -n "${KUBECTL[*]:-}" ]] || return 0
	_platform_tuning_held "$1"
	if [[ -n "$_PL_HELD" ]]; then
		echo "warning: a tuning profile's objects (label ${PLATFORM_TUNING_LABEL}) are on ${_PL_HELD}: ${_PL_OBJS}; this sweep would measure that profile's configuration, not the charts'. Unless that is the point, stop it now (Ctrl-C); then, unless a tuning run is still in progress on these members (wait for it to end), undo them with $(_platform_cleanup_hint "$1")" >&2
		sweep_note "a tuning profile's objects were on ${_PL_HELD} at the sweep's start (${_PL_OBJS}): its results measure that profile's configuration, not the charts'"
	fi
	if [[ -n "$_PL_UNLISTED" ]]; then
		echo "warning: the tuning profile objects (label ${PLATFORM_TUNING_LABEL}) could not be listed on ${_PL_WHY}" >&2
		sweep_note "the tuning profile objects could not be listed on ${_PL_UNLISTED} at the sweep's start: a profile left applied there would go unseen"
	fi
}

# platform_unread <key> <value>: return 0 for a value not read, in whole or in part (unknown, a
# digest @unknown; unreachable for KUBE_VERSIONS): never compared as another value (PL61).
# shellcheck disable=SC2329
platform_unread() {
	[[ "$2" == *unknown* || ( "$1" == KUBE_VERSIONS && "$2" == unreachable ) ]]
}

# platform_merge_by_context <key> <tsv>...: one *_BY_CONTEXT key (or KUBE_VERSIONS) over a
# report's inputs, member by member (PL26): a member's one value, or <ctx>=mixed:<a>;<b> when its
# inputs hold more; unknown when no input has the key, mixed:unknown,<members> when only some do.
# On stderr, one warning when two values read disagree (the members and their values), one when a
# value is unknown in some inputs beside a read one. With _pl_no_members=1 (dynamic scope) they
# count the members instead of naming them.
# shellcheck disable=SC2329
platform_merge_by_context() {
	local key="$1" f line pair c x v n=0 missing=0 out="" k u dis="" unr="" ndis=0 nunr=0
	local -a order=() pairs=() _pl_x=()
	local -A _pl_vals=()
	shift
	for f in "$@"; do
		n=$((n + 1))
		line="$(grep -m1 "^# ${key}=" "$f" 2>/dev/null || true)"
		line="${line#*=}"
		[[ "$line" == *=* ]] || { missing=$((missing + 1)); continue; }
		IFS=',' read -r -a pairs <<<"$line"
		for pair in "${pairs[@]}"; do
			c="${pair%%=*}" x="${pair#*=}"
			if [[ -z "${_pl_vals[$c]+x}" ]]; then
				order+=("$c")
				_pl_vals[$c]="$x"
			elif [[ ";${_pl_vals[$c]};" != *";${x};"* ]]; then
				_pl_vals[$c]+=";${x}"
			fi
		done
	done
	((n > missing)) || { echo unknown; return 0; }
	for c in "${order[@]}"; do
		v="${_pl_vals[$c]}"
		[[ "$v" == *";"* ]] || { out+="${out:+,}${c}=${v}"; continue; }
		out+="${out:+,}${c}=mixed:${v}"
		k=0 u=0
		IFS=';' read -r -a _pl_x <<<"$v"
		for x in "${_pl_x[@]}"; do
			if platform_unread "$key" "$x"; then u=1; else k=$((k + 1)); fi
		done
		((k < 2)) || { ndis=$((ndis + 1)); dis+="${dis:+, }${c} (${v//;/ or })"; }
		((u == 0)) || { nunr=$((nunr + 1)); unr+="${unr:+, }${c}"; }
	done
	if ((${_pl_no_members:-0})); then
		((ndis == 0)) || dis="${ndis} of ${#order[@]} members"
		((nunr == 0)) || unr="${nunr} of ${#order[@]} members"
	fi
	[[ -z "$dis" ]] ||
		platform_short_digests "warning: input TSVs disagree on ${key} for ${dis}: the report mixes runs with different values of it; compare like with like" >&2
	if [[ -n "$unr" ]] || ((missing)); then
		v="${unr:+not read for ${unr}}"
		((missing == 0)) || v+="${v:+; }not recorded in ${missing} of ${n} (written before the record had it)"
		echo "warning: ${key} is unknown in some input TSVs (${v}), while others have a value: the report cannot tell whether those runs had the same one" >&2
		((missing == 0)) || out="mixed:unknown,${out}"
	fi
	printf '%s\n' "$out"
}

# _platform_merge_scalar <key> <tsv>...: PLATFORM or TEST_PLATFORM over a report's inputs: one
# value, or mixed:<a>,<b> in file order (a file without the line reads unknown); a warning when
# two values read disagree, one when unknown stands beside a value.
# shellcheck disable=SC2329
_platform_merge_scalar() {
	local key="$1" f v vals="" known="" n=0 unread=0 why="on different platforms; compare like with like"
	shift
	[[ "$key" != TEST_PLATFORM ]] || why="whose suite charts got different overlays"
	for f in "$@"; do
		n=$((n + 1))
		v="$(grep -m1 "^# ${key}=" "$f" 2>/dev/null || true)"
		v="${v#*=}"
		[[ -n "$v" && "$v" != unknown ]] || { v=unknown; unread=$((unread + 1)); }
		[[ "$v" == unknown || ",${known}," == *",${v},"* ]] || known+="${known:+,}${v}"
		[[ ",${vals}," == *",${v},"* ]] || vals+="${vals:+,}${v}"
	done
	[[ "$known" != *,* ]] || echo "warning: input TSVs disagree on ${key} (${known}): the report mixes runs ${why}" >&2
	if [[ -n "$known" ]] && ((unread)); then
		echo "warning: ${key} is unknown in ${unread} of ${n} input TSV(s) (not read, or written before the record), while others have a value: the report cannot tell whether those runs had the same one" >&2
	fi
	if [[ "$vals" == *,* ]]; then echo "mixed:${vals}"; else echo "${vals:-unknown}"; fi
}

# platform_report_values <tsv>...: KEY=value for every record key (PLATFORM_KEYS order) over a
# report's inputs; the merges' warnings go to stderr (platform_report_warnings: for the body).
# shellcheck disable=SC2329
platform_report_values() {
	local k
	for k in "${PLATFORM_KEYS[@]}"; do
		case "$k" in
		PLATFORM | TEST_PLATFORM) printf '%s=%s\n' "$k" "$(_platform_merge_scalar "$k" "$@")" ;;
		*) printf '%s=%s\n' "$k" "$(platform_merge_by_context "$k" "$@")" ;;
		esac
	done
}

# platform_report_warnings [--no-members] [--with KEY]... <tsv>...: the warnings of
# platform_report_values (and of platform_merge_by_context for each --with key, such as
# KUBE_VERSIONS), one per line without "warning: ", for the report's body (PL26). --no-members
# counts the members instead of naming them (the scale envelope, pasted into campaign docs).
# shellcheck disable=SC2329
platform_report_warnings() {
	local k
	# shellcheck disable=SC2034  # read by platform_merge_by_context (dynamic scope)
	local _pl_no_members=0
	local -a _pl_with=()
	while [[ "${1:-}" == --with || "${1:-}" == --no-members ]]; do
		if [[ "$1" == --no-members ]]; then
			_pl_no_members=1
			shift
		else
			[[ -n "${2:-}" ]] || die "platform_report_warnings: --with needs a key"
			_pl_with+=("$2")
			shift 2
		fi
	done
	{
		for k in "${PLATFORM_KEYS[@]}" ${_pl_with[@]+"${_pl_with[@]}"}; do
			case "$k" in
			PLATFORM | TEST_PLATFORM) _platform_merge_scalar "$k" "$@" >/dev/null ;;
			*) platform_merge_by_context "$k" "$@" >/dev/null ;;
			esac
		done
	} 2>&1 | sed 's/^warning: //'
}

# platform_warning_lines <md|text|comment|json> <lines>: warnings (one per line) as "> **Warning:**
# w" blocks (markdown), "WARNING: w" (text), "# WARNING: w" (csv and TSV-style headers), or one
# compact JSON array of strings ([] without any).
# shellcheck disable=SC2329
platform_warning_lines() {
	local style="$1" w
	if [[ "$style" == json ]]; then
		jq -R -s -c 'split("\n") | map(select(length > 0))' <<<"$2"
		return
	fi
	while IFS= read -r w; do
		[[ -n "$w" ]] || continue
		case "$style" in
		md) printf '> **Warning:** %s\n\n' "$w" ;;
		text) printf 'WARNING: %s\n' "$w" ;;
		comment) printf '# WARNING: %s\n' "$w" ;;
		*) die "platform_warning_lines: unknown style '${style}' (md, text, comment or json)" ;;
		esac
	done <<<"$2"
}

# platform_report_lines <comment|text|yaml|md|json> <values>: KEY=value lines as "# KEY=value",
# "# key: value" (text), key: "value" (front matter, yaml_str), "| KEY | `value` |" (md_cell), or
# one compact JSON object with lowercase keys; a hand-edited value keeps each format whole.
# shellcheck disable=SC2329
platform_report_lines() {
	local style="$1" kv k v
	if [[ "$style" == json ]]; then
		jq -R -s -c 'split("\n") | map(select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k | ascii_downcase): .v}) | add // {}' <<<"$2"
		return
	fi
	while IFS= read -r kv; do
		[[ -n "$kv" ]] || continue
		k="${kv%%=*}"
		case "$style" in
		comment) printf '# %s\n' "$kv" ;;
		text) printf '# %s: %s\n' "${k,,}" "${kv#*=}" ;;
		yaml)
			yaml_str -v v "${kv#*=}"
			printf '%s: %s\n' "${k,,}" "$v"
			;;
		md)
			md_cell -v v "${kv#*=}"
			printf '| %s | %s |\n' "$k" "\`${v}\`"
			;;
		*) die "platform_report_lines: unknown style '${style}' (comment, text, yaml, md or json)" ;;
		esac
	done <<<"$2"
}

# platform_report_is_key <key>: return 0 when <key> is one of PLATFORM_KEYS.
# shellcheck disable=SC2329
platform_report_is_key() {
	[[ " ${PLATFORM_KEYS[*]} " == *" ${1} "* ]]
}

# platform_value_has <value> <word>: return 0 when any member's value (mixed, ";" and "+" lists
# included) is exactly <word>, e.g. platform_value_has "$NODE_PROVIDER_BY_CONTEXT" kind.
# shellcheck disable=SC2329
platform_value_has() {
	local item
	local -a items=()
	IFS=',;+' read -r -a items <<<"${1//mixed:/}"
	for item in ${items[@]+"${items[@]}"}; do [[ "${item#*=}" != "$2" ]] || return 0; done
	return 1
}

# platform_unread_members <by_context value>: how many members' value was unknown, in every input
# or in some (mixed:a;unknown); a token without a member (mixed:unknown) counts none.
# shellcheck disable=SC2329
platform_unread_members() {
	local pair n=0
	local -a _pl_p=()
	IFS=',' read -r -a _pl_p <<<"$1"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		[[ "$pair" != *=* || ";${pair#*=};" != *[:\;]unknown\;* ]] || n=$((n + 1))
	done
	echo "$n"
}

# platform_kind_path_warning <node_provider_by_context value> <consequence>: the data warning of a
# report with cross-cluster figures when a member's nodes are kind's, or when a member's node
# provider was not read (they may be), else nothing: on kind the east-west gateway's LoadBalancer
# is cloud-provider-kind's userspace Envoy on the host every kind cluster shares. k3d and
# minikube clusters that share one host are not detected.
# shellcheck disable=SC2329
platform_kind_path_warning() {
	local n
	if platform_value_has "$1" kind; then
		printf '%s\n' "Nodes on kind (NODE_PROVIDER_BY_CONTEXT): the cross-cluster path runs through cloud-provider-kind's userspace Envoy (the east-west gateway's LoadBalancer, ipMode: Proxy) on the host all kind clusters share, so ${2}"
		return 0
	fi
	n="$(platform_unread_members "$1")"
	((n)) || return 0
	printf '%s\n' "Node provider not read on ${n} member(s) (NODE_PROVIDER_BY_CONTEXT unknown): if their nodes are kind's, the cross-cluster path runs through cloud-provider-kind's userspace Envoy (the east-west gateway's LoadBalancer, ipMode: Proxy) on the host all kind clusters share, so ${2}"
}

# platform_short_digests <text>: every sha256:<64 hex> cut to its first 12 hex digits.
# shellcheck disable=SC2329
platform_short_digests() {
	printf '%s\n' "$1" | sed -E 's/(sha256:[0-9a-f]{12})[0-9a-f]{52}/\1/g'
}

# platform_summary <by_context value>: the value without member names (the scale envelope is
# pasted into campaign docs): the one value every member shares, else each with its member count
# ("pilot:1.30.5 (2 members), pilot:1.30.6 (1 member)"); mixed:<a>;<b> reads "mixed: <a> and <b>";
# a token without a member (inputs from before the record) first; digests shortened.
# shellcheck disable=SC2329
platform_summary() {
	local pair v out="" i
	local -a _pl_p=() _pl_order=()
	local -A _pl_cnt=()
	IFS=',' read -r -a _pl_p <<<"$1"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		if [[ "$pair" != *=* ]]; then
			out+="${out:+, }${pair}"
			continue
		fi
		v="${pair#*=}"
		[[ "$v" != mixed:* ]] || { v="${v#mixed:}"; v="mixed: ${v//;/ and }"; }
		[[ -n "${_pl_cnt[$v]+x}" ]] || { _pl_order+=("$v"); _pl_cnt[$v]=0; }
		i="${_pl_cnt[$v]}"
		_pl_cnt[$v]=$((i + 1))
	done
	if ((${#_pl_order[@]} == 1)) && [[ -z "$out" ]]; then
		out="${_pl_order[0]}"
	else
		for v in ${_pl_order[@]+"${_pl_order[@]}"}; do
			i="${_pl_cnt[$v]}"
			out+="${out:+, }${v} (${i} member$( ((i == 1)) || echo s))"
		done
	fi
	platform_short_digests "${out:-unknown}"
}
