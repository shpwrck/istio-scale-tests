#!/usr/bin/env bash
# Platform of a mesh member and the suite-chart overlay for it. Sourced, never executed.
#
# Consumers: every suite script that takes TEST_PLATFORM (platform_validate, with its argument
# checks; the setups through platform_chart_args); propagation, churn, churn-dataplane,
# controlplane, dataplane (the 001 setup scripts: the chart overlay; the TSV writers and reports:
# the platform record; the sweeps: its drift check, and controlplane 003 --resume its resume
# check), gateway-api (001: the platform record and the operator build), tuning (004: the record
# of each pass; 006: the hub's Argo CD namespace)
#
# The suite charts default to Kubernetes: their pods run as a numeric non-root UID
# (runAsUser), because the busybox and fortio images run as root and runAsNonRoot cannot
# start them otherwise. OpenShift assigns each pod a UID from its namespace range and
# rejects any other, so on OpenShift the chart's values-openshift.yaml clears runAsUser.
#
# Exposes:
#   platform_of <ctx>                       -> print kubernetes or openshift; return 1
#                                              (with a message) when it cannot tell
#   platform_chart_args <chart> <ctx> <out> -> set the named array to the helm args for
#                                              <ctx> (-f <chart>/values-openshift.yaml on
#                                              openshift, none on kubernetes)
#   platform_validate                       -> die unless TEST_PLATFORM is auto (or empty),
#                                              kubernetes or openshift
#   platform_gitops_namespace <hub_ctx>     -> the hub's Argo CD namespace: openshift-gitops on
#                                              OpenShift, argocd otherwise; return 1 (with a
#                                              message) when the hub cannot tell
#   platform_pod_filter <container>         -> jq program over a pod list: images, restart
#                                              fingerprint, Running count, first Running pod
#   platform_probe <ctxs_csv>               -> read each member's platform and mesh builds once
#                                              (see "The platform record" below)
#   platform_probe_save <file>, platform_probe_load <file>
#                                           -> keep the record between two phases of one run
#   platform_probed_contexts                -> the members of this shell's last platform_probe
#   platform_recorded_contexts              -> every member of the record (PLATFORM_PROBE_ROWS)
#   platform_member_value <ctx> <field>     -> one value of a member's record (operator, ...)
#   platform_preamble_lines <ctxs_csv>      -> the record's `# KEY=value` TSV preamble lines
#   platform_md_row <ctxs_csv>              -> the `| Platform | ... |` row of a run summary
#   platform_collapse <by_context value>    -> the one value every member shares, else as is
#   platform_report_values <tsv>...         -> KEY=value per record key over a report's inputs
#   platform_report_lines <style> <values>  -> those lines in a report format (comment, text,
#                                              yaml, md or json)
#   platform_merge_by_context <key> <tsv>...
#                                           -> one *_BY_CONTEXT key over a report's inputs
#   platform_report_warnings [--with KEY]... <tsv>...
#                                           -> those merges' warnings, one per line, for the
#                                              report's body (platform_warning_lines)
#   platform_warning_lines <style> <lines>  -> warnings in a report format (md, text, comment
#                                              or json)
#   platform_kind_path_warning <values> <consequence>
#                                           -> the kind cross-cluster-path data warning, or nothing
#   platform_resume_check <tsv> <ctxs_csv> [<tuning_ctx>]
#                                           -> die when a --resume would append rows measured on
#                                              other builds than the TSV's preamble records
#   platform_drift_check <sweep_dir> <ctxs_csv>
#                                           -> after a sweep's last step: read the record again;
#                                              a build that changed warns and is written to
#                                              <sweep_dir>/platform-drift.txt for its reports
#   platform_compare_values <ref> <values>  -> KEY<TAB>same|differs|unknown per record key of two
#                                              platform_report_values outputs
#   platform_summary <by_context value>     -> the value without member names, digests shortened
#   platform_short_digests <text>           -> sha256 digests shortened to 12 hex digits
#   platform_report_is_key <key>            -> return 0 for a record key
#   platform_value_has <value> <word>       -> return 0 when a member's value holds <word>
#
# Requires KUBECTL (resolve_kubectl) and TEST_PLATFORM (config/options.env: auto,
# kubernetes or openshift; read at call time). With DRY_RUN=1 and TEST_PLATFORM=auto no
# cluster is asked and the Kubernetes defaults render, so a dry-run stays offline; set
# TEST_PLATFORM=openshift to preview the OpenShift render. Needs split_csv and die
# (tests/lib/common.sh); platform_probe and platform_drift_check need reach_sanitize
# (tests/lib/reach.sh: their warnings mask addresses), platform_resume_check with a tuning
# context tuning_baseline_state (tests/lib/preamble.sh).
#
# The platform record (PL2, PL36, PL39, PL41): what each member ran, read live and once per
# run, before any measurement window, into every TSV preamble and every report format (PL19).
# Keys, each member's value as <ctx>=<value>, comma-separated like KUBE_VERSIONS:
#   PLATFORM                  kubernetes | openshift over the members; mixed (both) or unknown
#   TEST_PLATFORM             the override: the platform the suite charts' overlay is picked for
#                             (auto = asked of each member). The record asks each member either
#                             way, and warns when a member serves another platform than it says
#   PLATFORM_BY_CONTEXT       kubernetes | openshift (what the member serves: whether it serves
#                             security.openshift.io/v1) | unknown (it could not be asked)
#   MESH_OPERATOR_BY_CONTEXT  Kubernetes: sail-operator:<tag>[@<digest>]/<Available|Unavailable>
#                             (the Deployment sail-operator in namespace sail-operator; the
#                             digest the pods run); OpenShift: servicemeshoperator3:<version>/
#                             <phase> (its CSV in openshift-operators). Read on the platform the
#                             member serves, on TEST_PLATFORM's when that could not be asked.
#                             absent: none there (a definitive read of a kind the platform
#                             serves, on the platform the member serves); unknown: not read, or
#                             none where TEST_PLATFORM looked for a member that could not be asked.
#                             The state after the last "/" is kept, but no comparison counts a
#                             value that differs only in it as another build (_platform_build)
#   ISTIOD_IMAGE_BY_CONTEXT   the istiod pods' discovery image (app=istiod in istio-system)
#   PROXY_IMAGE_BY_CONTEXT    the istio-proxy image of the gateway pods in istio-system (istio in
#                             (ingressgateway, eastwestgateway): the ingress and the east-west
#                             gateway, on the remote path). A gateway not restarted since an
#                             upgrade shows the build it started with; the test pods' sidecars
#                             get the injector's current one (normally istiod's release,
#                             ISTIOD_IMAGE_BY_CONTEXT)
#   NODE_PROVIDER_BY_CONTEXT  the scheme of the nodes' spec.providerID (kind, aws, gce, ...;
#                             none when empty, no-nodes without nodes), deduplicated; never
#                             the full providerID
# Images drop the registry host and path (a mirror can name an internal host) and carry the
# sha256 the pods run (the imageID after "@", or a bare sha256:... imageID, as kind gives a
# loaded image). Several values on one member are "+"-joined. Every value keeps only
# [A-Za-z0-9_.:/@+-] (anything else becomes _), so it holds no tab, newline, comma, = or |.
# A file written before the record has none of these keys (the suites supported only OpenShift
# with OSSM then), and its values read unknown in a report.
#
# A sweep calls platform_probe once with all its members, before its first step; the record
# is exported (PLATFORM_PROBE_ROWS: one line per member, <ctx> and the five values
# tab-separated), so the steps it runs reuse it for the members it covers and read only the
# others, like RUN_CONFIG, and those whose platform it recorded unknown (a transient failure at
# the sweep's start; a phase that reuses a saved record reads nothing: platform_probe_load). A
# standalone step reads its own members. With DRY_RUN=1 nothing is read and every value is
# unknown. After its last step a sweep reads its members again (platform_drift_check): a build
# that changed while it ran goes to platform-drift.txt in the sweep dir, which every report of the
# sweep merges as a second value (mixed:). controlplane 003 --resume compares the record with the
# one its TSV holds (platform_resume_check).
# shellcheck shell=bash

# Fixed by the charts (do not override them there): the Sail operator's namespace and
# Deployment on Kubernetes (charts/gitops-hub-ocm-placement-appset/values-sail-operator.yaml),
# the OSSM operator's namespace and package on OpenShift (charts/spoke-ossm-operator), and the
# pod labels of istiod and of the gateways in istio-system (charts/spoke-ossm,
# charts/spoke-ingress-gateway, charts/spoke-east-west-gateway).
PLATFORM_SAIL_NS=sail-operator
PLATFORM_SAIL_DEPLOY=sail-operator
PLATFORM_OSSM_NS=openshift-operators
PLATFORM_OSSM_PACKAGE=servicemeshoperator3
# kubectl --request-timeout of each platform-record read.
PLATFORM_READ_TIMEOUT=20s
# The record's preamble keys, in order; the reports print the same list.
# shellcheck disable=SC2034  # read by the reports
PLATFORM_KEYS=(PLATFORM TEST_PLATFORM PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT
	PROXY_IMAGE_BY_CONTEXT NODE_PROVIDER_BY_CONTEXT)
# The file platform_drift_check writes into a sweep dir and platform_merge_by_context reads
# next to each input (not *.tsv, so no report or tuning glob takes it for data).
PLATFORM_DRIFT_FILE="platform-drift.txt"

# platform_of <ctx>: TEST_PLATFORM kubernetes or openshift is used as is. auto asks the
# cluster whether it serves security.openshift.io/v1 (SecurityContextConstraints). It never
# guesses: a member it cannot ask is an error, since the wrong overlay gets pods rejected.
# shellcheck disable=SC2329
platform_of() {
	local ctx="$1"
	case "${TEST_PLATFORM:-auto}" in
	kubernetes | openshift)
		echo "$TEST_PLATFORM"
		return 0
		;;
	auto) ;;
	*)
		echo "error: TEST_PLATFORM must be auto, kubernetes or openshift (got: ${TEST_PLATFORM})" >&2
		return 1
		;;
	esac
	_platform_served "$ctx" " (set TEST_PLATFORM to skip the check)"
}

# _platform_served <ctx> [hint]: what the member serves, whatever TEST_PLATFORM says: openshift
# when it serves security.openshift.io/v1, else kubernetes (one api-versions read, bounded by
# PLATFORM_READ_TIMEOUT). Return 1 with kubectl's message (and the hint) when it cannot be asked.
# shellcheck disable=SC2329
_platform_served() {
	local versions
	if ! versions="$("${KUBECTL[@]}" --context="$1" --request-timeout="$PLATFORM_READ_TIMEOUT" api-versions 2>&1)"; then
		echo "error: cannot list the API versions of context $1 to tell Kubernetes from OpenShift${2:-}: ${versions}" >&2
		return 1
	fi
	if grep -qx 'security.openshift.io/v1' <<<"$versions"; then
		echo openshift
	else
		echo kubernetes
	fi
}

# platform_chart_args <chart-dir> <ctx> <out_arrayname>: with TEST_PLATFORM auto, a member the
# record (PLATFORM_PROBE_ROWS: a sweep's, inherited) already holds as kubernetes or openshift is
# not asked again (the record asked it the way platform_of does); any other is.
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

# platform_validate: die unless TEST_PLATFORM is auto (empty means auto), kubernetes or
# openshift. Call it with the other argument checks, before anything is read.
# shellcheck disable=SC2329
platform_validate() {
	case "${TEST_PLATFORM:-auto}" in
	auto | kubernetes | openshift) ;;
	*) die "TEST_PLATFORM must be auto, kubernetes or openshift (got: ${TEST_PLATFORM}); set it in the environment, the --config file or config/options.env (auto, the default, asks each cluster)" ;;
	esac
}

# platform_gitops_namespace <hub_ctx>: the Argo CD namespace the platform installs on the hub
# (terraform/platform output gitops_namespace): openshift-gitops on OpenShift, argocd otherwise.
# Its caller prefers an explicit setting and logs what it uses. Returns 1 with platform_of's
# message when the hub cannot tell.
# shellcheck disable=SC2329
platform_gitops_namespace() {
	local p
	p="$(platform_of "$1")" || return 1
	if [[ "$p" == openshift ]]; then echo openshift-gitops; else echo argocd; fi
}

# platform_pod_filter <container>: jq program over a pod list, "<images>\t<fingerprint>\t
# <running>\t<pod>". images: per pod, the container's image without its registry host and path
# plus the sha256 that ran (the imageID's, after "@" or a bare sha256:...); unique, "+"-joined;
# "none" without such a pod. fingerprint: name@startTime#restarts per pod, sorted: a restart, a
# replaced pod or an added pod changes it (PL9). running: Running pods. pod: the first Running pod.
# shellcheck disable=SC2329
platform_pod_filter() {
	# shellcheck disable=SC2016  # jq program
	printf '%s' '. as $l
	| ([$l.items[]? | . as $p
	    | ([$p.spec.containers[]? | select(.name == "'"$1"'")][0].image // "") as $img
	    | ([$p.status.containerStatuses[]? | select(.name == "'"$1"'")][0].imageID // "") as $id
	    | select($img != "")
	    | ($id | if test("@sha256:") then sub("^.*@"; "") elif test("^sha256:") then . else "" end) as $dig
	    | ($img | sub("^.*/"; "")) + (if ($img | test("@")) or $dig == "" then "" else "@" + $dig end)]
	   | unique | if length == 0 then "none" else join("+") end) as $images
	| ([$l.items[]? | "\(.metadata.name)@\(.status.startTime // "-")#\([.status.containerStatuses[]?.restartCount // 0] | add // 0)"]
	   | sort | if length == 0 then "none" else join(",") end) as $fp
	| [$l.items[]? | select(.status.phase == "Running") | .metadata.name] as $run
	| "\($images)\t\($fp)\t\($run | length)\t\($run[0] // "-")"'
}

# _platform_sanitize <value>: one record value: [A-Za-z0-9_.:/@+-] only, unknown when empty.
# shellcheck disable=SC2329
_platform_sanitize() {
	local v="${1//[^A-Za-z0-9_.:\/@+-]/_}"
	printf '%s\n' "${v:-unknown}"
}

# _platform_read <ctx> <out> <kubectl args...>: one bounded read (-o json) into <out>, stderr in
# <out>.err. Returns 0; 3 when the server says NotFound or does not serve the kind; 2 for any
# other answer of the server (Forbidden, ...); 1 when the member did not answer.
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

# _platform_warn <ctx> <what> <err file>: one warning for values recorded as unknown, with the
# first 300 bytes of the read's stderr, addresses and host names masked (reach_sanitize).
# shellcheck disable=SC2329
_platform_warn() {
	local why
	why="$(head -c 300 "$3" 2>/dev/null)" || why=""
	why="$(reach_sanitize "${why:-no answer}")"
	echo "warning: ${1}: could not read ${2}; recorded as unknown: ${why}" >&2
}

# _platform_probe_member <ctx> <workdir>: "<ctx>\t<platform>\t<operator>\t<istiod>\t<proxy>\t
# <nodes>" on stdout, a warning per value it could not read on stderr. After a read the member
# did not answer, the rest are not tried (each would wait out the timeout) and read unknown.
# The platform is what the member serves, whatever TEST_PLATFORM says (a disagreement warns);
# the operator is looked for on it, or on TEST_PLATFORM's when the member could not be asked.
# shellcheck disable=SC2329
_platform_probe_member() {
	local ctx="$1" w="$2" platform look op=unknown istiod=unknown proxy=unknown nodes=unknown rc=0 f
	local tp="${TEST_PLATFORM:-auto}"
	local -a _pl_val=()
	# shellcheck disable=SC2016  # jq programs: $d, $sel, $img, ... are jq variables
	local sail_jq='([.items[]? | select(.kind == "Deployment" and .metadata.name == $name)][0]) as $d
		| if $d == null then "absent" else
		  ([$d.spec.template.spec.containers[]? | select(.name == $name) | .image][0] // "") as $img
		  | ($d.spec.selector.matchLabels // {}) as $sel
		  | ([.items[]? | select(.kind == "Pod") | select((.metadata.labels // {}) as $l | $sel | to_entries | all(.value == $l[.key]))
		      | ([.status.containerStatuses[]? | select(.name == $name) | .imageID][0] // "")
		      | if test("@sha256:") then sub("^.*@"; "") elif test("^sha256:") then . else empty end] | unique) as $digs
		  | ($img | split("/") | last // "" | split("@")) as $ref
		  | ($ref[0] | split(":")) as $nt
		  | "sail-operator"
		    + (if $img == "" then ":unknown" elif ($nt | length) > 1 then ":" + $nt[1] elif ($ref | length) > 1 then "" else ":latest" end)
		    + (if ($ref | length) > 1 then "@" + $ref[1] elif ($digs | length) > 0 then "@" + ($digs | join("+")) else "" end)
		    + "/" + (if ($d.status.availableReplicas // 0) > 0 then "Available" else "Unavailable" end)
		  end'
	# shellcheck disable=SC2016  # jq program: $pkg is a jq variable
	local csv_jq='[.items[]? | select(.metadata.name | startswith($pkg + "."))
		| "\($pkg):\(.spec.version // "unknown")/\(.status.phase // "unknown")"] | unique
		| if length == 0 then "absent" else join("+") end'
	local nodes_jq='[.items[]? | (.spec.providerID // "")
		| if . == "" then "none" elif test("^[A-Za-z][A-Za-z0-9.-]*://") then sub("://.*$"; "") else "unrecognized" end]
		| unique | if length == 0 then "no-nodes" else join("+") end'
	if ! platform="$(_platform_served "$ctx" 2>"${w}/platform.err")"; then
		platform=unknown
		if [[ "$tp" == auto ]]; then
			_platform_warn "$ctx" "the platform (so the mesh operator build is not read either)" "${w}/platform.err"
		else
			_platform_warn "$ctx" "the platform it serves (its mesh operator is looked for where TEST_PLATFORM=${tp} says)" "${w}/platform.err"
		fi
		grep -q 'Error from server' "${w}/platform.err" || rc=1
	elif [[ "$tp" != auto && "$tp" != "$platform" ]]; then
		echo "warning: ${ctx}: TEST_PLATFORM=${tp}, but the member serves ${platform}: the record keeps ${platform} (PLATFORM_BY_CONTEXT), while the suite charts get the ${tp} overlay; set TEST_PLATFORM to auto or ${platform} unless that overlay is what you want" >&2
	fi
	look="$platform"
	[[ "$look" != unknown || "$tp" == auto ]] || look="$tp"
	if ((rc != 1)); then
		case "$look" in
		kubernetes)
			_platform_read "$ctx" "${w}/op.json" -n "$PLATFORM_SAIL_NS" get deployments.apps,pods || rc=$?
			((rc != 0)) || op="$(jq -r --arg name "$PLATFORM_SAIL_DEPLOY" "$sail_jq" "${w}/op.json" 2>/dev/null)" || op=""
			;;
		openshift)
			_platform_read "$ctx" "${w}/op.json" -n "$PLATFORM_OSSM_NS" get clusterserviceversions.operators.coreos.com || rc=$?
			((rc != 0)) || op="$(jq -r --arg pkg "$PLATFORM_OSSM_PACKAGE" "$csv_jq" "${w}/op.json" 2>/dev/null)" || op=""
			;;
		esac
		# A kind that is not served (no OLM on an "OpenShift" member) is unknown, never absent.
		if [[ "$look" != unknown && ( "$rc" != 0 || -z "$op" ) ]]; then
			[[ -s "${w}/op.json.err" ]] || echo "the reply did not parse" >"${w}/op.json.err"
			_platform_warn "$ctx" "the mesh operator build" "${w}/op.json.err"
			op=unknown
		fi
		# Looked for where TEST_PLATFORM says, on a member that could not be asked what it
		# serves: none there may be the other platform's operator, so unknown, never absent.
		if [[ "$op" == absent && "$platform" == unknown ]]; then
			echo "warning: ${ctx}: no mesh operator where TEST_PLATFORM=${tp} looks, and the platform the member serves could not be read; recorded as unknown, not absent" >&2
			op=unknown
		fi
	fi
	if ((rc != 1)); then
		rc=0
		_platform_read "$ctx" "${w}/pods.json" -n istio-system get pods || rc=$?
		if ((rc != 0)); then
			_platform_warn "$ctx" "the istiod and proxy builds" "${w}/pods.json.err"
		else
			istiod="$(jq -r "{items: [.items[]? | select(.metadata.labels.app? == \"istiod\")]} | $(platform_pod_filter discovery)" \
				"${w}/pods.json" 2>/dev/null | cut -f1)" || istiod=""
			proxy="$(jq -r "{items: [.items[]? | select(.metadata.labels.istio? == \"ingressgateway\" or .metadata.labels.istio? == \"eastwestgateway\")]}
				| $(platform_pod_filter istio-proxy)" "${w}/pods.json" 2>/dev/null | cut -f1)" || proxy=""
			for f in istiod proxy; do
				[[ -z "${!f}" ]] || continue
				echo "the reply did not parse" >"${w}/pods.json.err"
				_platform_warn "$ctx" "the ${f} build" "${w}/pods.json.err"
				printf -v "$f" unknown
			done
		fi
	fi
	if ((rc != 1)); then
		rc=0
		_platform_read "$ctx" "${w}/nodes.json" get nodes || rc=$?
		((rc != 0)) || nodes="$(jq -r "$nodes_jq" "${w}/nodes.json" 2>/dev/null)" || nodes=""
		if [[ "$rc" != 0 || -z "$nodes" ]]; then
			[[ -s "${w}/nodes.json.err" ]] || echo "the reply did not parse" >"${w}/nodes.json.err"
			_platform_warn "$ctx" "the node provider" "${w}/nodes.json.err"
			nodes=unknown
		fi
	fi
	if ((rc == 1)); then
		echo "warning: ${ctx}: did not answer; its platform record stops here (the values not read are unknown)" >&2
	fi
	_pl_val=("$(_platform_sanitize "$platform")" "$(_platform_sanitize "$op")" "$(_platform_sanitize "$istiod")"
		"$(_platform_sanitize "$proxy")" "$(_platform_sanitize "$nodes")")
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ctx" "${_pl_val[@]}"
}

# _platform_rows_find <rows> <ctx>: the member's line of a record (PLATFORM_PROBE_ROWS lines);
# return 1 when it has none.
# shellcheck disable=SC2329
_platform_rows_find() {
	local line
	while IFS= read -r line; do
		if [[ -n "$line" && "${line%%$'\t'*}" == "$2" ]]; then
			printf '%s\n' "$line"
			return 0
		fi
	done <<<"$1"
	return 1
}

# _platform_row <ctx>: the member's line of PLATFORM_PROBE_ROWS; return 1 when it has none.
# shellcheck disable=SC2329
_platform_row() {
	_platform_rows_find "${PLATFORM_PROBE_ROWS:-}" "$1"
}

# _platform_row_set <row>: put <row> in PLATFORM_PROBE_ROWS in place of its member's line (at the
# end when it has none).
# shellcheck disable=SC2329
_platform_row_set() {
	local line out="" done=0
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		if [[ "${line%%$'\t'*}" == "${1%%$'\t'*}" ]]; then
			((done)) || out+="${1}"$'\n'
			done=1
		else
			out+="${line}"$'\n'
		fi
	done <<<"${PLATFORM_PROBE_ROWS:-}"
	((done)) || out+="${1}"$'\n'
	PLATFORM_PROBE_ROWS="$out"
}

# _platform_row_has_unknown <row>: return 0 when one of the row's five values is unknown.
# shellcheck disable=SC2329
_platform_row_has_unknown() {
	[[ $'\t'"${1#*$'\t'}"$'\t' == *$'\tunknown\t'* ]]
}

# _platform_read_members <ctx>...: read each member's record in parallel (_platform_probe_member;
# a member's reads one after the other, each bounded by PLATFORM_READ_TIMEOUT): the rows on
# stdout and the warnings on stderr, both in argument order. A member whose read fails outright
# gets a row of unknowns and a warning. Return 1 without KUBECTL or a temp dir.
# shellcheck disable=SC2329
_platform_read_members() {
	local i tmp row
	local -a _pl_pids=() _pl_m=("$@")
	((${#_pl_m[@]})) || return 0
	[[ -n "${KUBECTL[*]:-}" ]] || return 1
	tmp="$(mktemp -d)" || return 1
	for i in "${!_pl_m[@]}"; do
		mkdir -p "${tmp}/${i}"
		(_platform_probe_member "${_pl_m[i]}" "${tmp}/${i}" >"${tmp}/${i}.row" 2>"${tmp}/${i}.warn") &
		_pl_pids+=("$!")
	done
	for i in "${_pl_pids[@]}"; do wait "$i" || true; done
	for i in "${!_pl_m[@]}"; do
		cat "${tmp}/${i}.warn" >&2 2>/dev/null || true
		row="$(head -n 1 "${tmp}/${i}.row" 2>/dev/null || true)"
		if [[ "${row%%$'\t'*}" != "${_pl_m[i]}" ]]; then
			echo "warning: ${_pl_m[i]}: the platform record read failed; every value of it is unknown" >&2
			row="${_pl_m[i]}"$'\tunknown\tunknown\tunknown\tunknown\tunknown'
		fi
		printf '%s\n' "$row"
	done
	rm -rf "$tmp"
}

# _platform_row_merge <inherited row> <new row>: per value, the new read's unless it is unknown;
# a value only the inherited row knows is kept, with a note that it was read earlier.
# shellcheck disable=SC2329
_platform_row_merge() {
	local j out
	local -a _pl_o=() _pl_n=()
	local -a _pl_names=(platform "mesh operator build" "istiod build" "gateway proxy build" "node provider")
	IFS=$'\t' read -r -a _pl_o <<<"$1"
	IFS=$'\t' read -r -a _pl_n <<<"$2"
	out="${_pl_o[0]}"
	for j in 1 2 3 4 5; do
		if [[ "${_pl_n[j]:-unknown}" != unknown || "${_pl_o[j]:-unknown}" == unknown ]]; then
			out+=$'\t'"${_pl_n[j]:-unknown}"
		else
			echo "warning: ${_pl_o[0]}: keeps the ${_pl_names[j - 1]} of the record it inherited (${_pl_o[j]}), read before this step; this read could not get it" >&2
			out+=$'\t'"${_pl_o[j]}"
		fi
	done
	printf '%s\n' "$out"
}

# platform_probe <ctxs_csv>: read the platform record of the members not in PLATFORM_PROBE_ROWS
# yet, and again of those whose inherited line holds an unknown value (a member that did not
# answer at the sweep's start; not after platform_probe_load, not in a dry-run), in parallel, and
# put them in it (exported). Call it in the script's own shell (not in $(...)), before any
# measurement window. Never fails for a member it cannot read: those values are unknown and
# each one gets a warning.
# shellcheck disable=SC2329
platform_probe() {
	local ctx row rows old
	local -a ctxs=() todo=() _pl_again=()
	platform_validate
	# Checked before the dry-run returns, so a caller that lacks it fails CI's dry-runs too.
	declare -F reach_sanitize >/dev/null || die "platform_probe needs reach_sanitize (source tests/lib/reach.sh)"
	split_csv "$1" ctxs
	PLATFORM_PROBE_LAST="$(IFS=,; echo "${ctxs[*]}")"
	for ctx in "${ctxs[@]}"; do
		if ! row="$(_platform_row "$ctx")"; then
			todo+=("$ctx")
		elif ! ((${DRY_RUN:-0} || ${PLATFORM_PROBE_LOADED:-0})) && _platform_row_has_unknown "$row"; then
			_pl_again+=("$ctx")
		fi
	done
	((${#todo[@]} + ${#_pl_again[@]})) || return 0
	if ((${DRY_RUN:-0})); then
		for ctx in "${todo[@]}"; do
			PLATFORM_PROBE_ROWS+="${ctx}"$'\tunknown\tunknown\tunknown\tunknown\tunknown\n'
		done
		export PLATFORM_PROBE_ROWS
		return 0
	fi
	[[ -n "${KUBECTL[*]:-}" ]] || die "neither kubectl nor oc found on PATH (platform_probe needs KUBECTL)"
	if ((${#_pl_again[@]})); then
		echo "Platform record: reading again ${_pl_again[*]} (an unknown value in the record this step inherited)" >&2
	fi
	rows="$(_platform_read_members ${todo[@]+"${todo[@]}"} ${_pl_again[@]+"${_pl_again[@]}"})" ||
		die "platform_probe: cannot read the platform record (no temp dir)"
	while IFS= read -r row; do
		[[ -n "$row" ]] || continue
		if old="$(_platform_row "${row%%$'\t'*}")"; then
			_platform_row_set "$(_platform_row_merge "$old" "$row")"
		else
			PLATFORM_PROBE_ROWS+="${row}"$'\n'
		fi
	done <<<"$rows"
	export PLATFORM_PROBE_ROWS
}

# platform_member_value <ctx> <platform|operator|istiod|proxy|nodes>: one value of a member's
# record (PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ...); unknown when it was not read.
# shellcheck disable=SC2329
platform_member_value() {
	local row i
	local -a _pl_f=()
	case "$2" in
	platform) i=1 ;;
	operator) i=2 ;;
	istiod) i=3 ;;
	proxy) i=4 ;;
	nodes) i=5 ;;
	*) die "platform_member_value: unknown field '$2' (platform, operator, istiod, proxy or nodes)" ;;
	esac
	row="$(_platform_row "$1")" || row=""
	IFS=$'\t' read -r -a _pl_f <<<"$row"
	printf '%s\n' "${_pl_f[i]:-unknown}"
}

# platform_probed_contexts: the members of this shell's last platform_probe call, comma-separated
# (PLATFORM_PROBE_LAST, not exported: a sweep step's own members, not every member the sweep
# read), else platform_recorded_contexts. A reach TSV records the record of these.
# shellcheck disable=SC2329
platform_probed_contexts() {
	if [[ -n "${PLATFORM_PROBE_LAST+set}" ]]; then
		printf '%s\n' "$PLATFORM_PROBE_LAST"
		return 0
	fi
	platform_recorded_contexts
}

# platform_recorded_contexts: every member in PLATFORM_PROBE_ROWS (inherited ones included),
# comma-separated.
# shellcheck disable=SC2329
platform_recorded_contexts() {
	local line out=""
	while IFS= read -r line; do
		[[ -z "$line" ]] || out+="${out:+,}${line%%$'\t'*}"
	done <<<"${PLATFORM_PROBE_ROWS:-}"
	printf '%s\n' "$out"
}

# platform_probe_save <file>: keep the record for a later phase of the same run (controlplane
# 002 --phase baseline, so --phase final reads nothing inside its scrape window).
# shellcheck disable=SC2329
platform_probe_save() {
	printf '%s' "${PLATFORM_PROBE_ROWS:-}" >"$1"
}

# platform_probe_load <file>: add the members of a saved record that PLATFORM_PROBE_ROWS lacks;
# an inherited line wins unless it holds an unknown value the saved one does not (the earlier
# phase read it again). A missing file adds nothing. Either way platform_probe reads nothing
# again in this shell (PLATFORM_PROBE_LOADED): the later phase runs inside a window.
# shellcheck disable=SC2329
platform_probe_load() {
	local line old
	PLATFORM_PROBE_LOADED=1
	[[ -f "$1" ]] || return 0
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		if ! old="$(_platform_row "${line%%$'\t'*}")"; then
			PLATFORM_PROBE_ROWS+="${line}"$'\n'
		elif _platform_row_has_unknown "$old" && ! _platform_row_has_unknown "$line"; then
			_platform_row_set "$line"
		fi
	done <"$1"
	export PLATFORM_PROBE_ROWS
}

# _platform_values <ctxs_csv>: the record as KEY=value lines (PLATFORM_KEYS order) for these
# members; a member platform_probe did not read warns and reads unknown.
# shellcheck disable=SC2329
_platform_values() {
	local ctx row agg sk=0 so=0 su=0 c j
	local -a ctxs=() _pl_f=() _pl_by=("" "" "" "" "")
	split_csv "$1" ctxs
	for ctx in ${ctxs[@]+"${ctxs[@]}"}; do
		if ! row="$(_platform_row "$ctx")"; then
			echo "warning: ${ctx}: no platform record was read (platform_probe was not called for it); its values read unknown" >&2
			row="${ctx}"$'\tunknown\tunknown\tunknown\tunknown\tunknown'
		fi
		IFS=$'\t' read -r -a _pl_f <<<"$row"
		case "${_pl_f[1]}" in
		kubernetes) sk=1 ;;
		openshift) so=1 ;;
		*) su=1 ;;
		esac
		c="$(_platform_sanitize "$ctx")"
		for j in 0 1 2 3 4; do
			_pl_by[j]+="${_pl_by[j]:+,}${c}=${_pl_f[j + 1]:-unknown}"
		done
	done
	if ((sk && so)); then
		agg=mixed
	elif ((su || !(sk || so))); then
		agg=unknown
	elif ((sk)); then
		agg=kubernetes
	else
		agg=openshift
	fi
	echo "PLATFORM=${agg}"
	echo "TEST_PLATFORM=$(_platform_sanitize "${TEST_PLATFORM:-auto}")"
	echo "PLATFORM_BY_CONTEXT=${_pl_by[0]:-unknown}"
	echo "MESH_OPERATOR_BY_CONTEXT=${_pl_by[1]:-unknown}"
	echo "ISTIOD_IMAGE_BY_CONTEXT=${_pl_by[2]:-unknown}"
	echo "PROXY_IMAGE_BY_CONTEXT=${_pl_by[3]:-unknown}"
	echo "NODE_PROVIDER_BY_CONTEXT=${_pl_by[4]:-unknown}"
}

# platform_preamble_lines <ctxs_csv>: the record's `# KEY=value` preamble lines for these
# members, from platform_probe (the one emitter of every TSV writer and placeholder: PL36).
# shellcheck disable=SC2329
platform_preamble_lines() {
	local line
	while IFS= read -r line; do
		printf '# %s\n' "$line"
	done < <(_platform_values "$1")
}

# platform_collapse <by_context value>: the one value every member shares, else the value as is.
# shellcheck disable=SC2329
platform_collapse() {
	local v="$1" pair first="" one=1
	local -a pairs=()
	IFS=',' read -r -a pairs <<<"$v"
	for pair in "${pairs[@]}"; do
		[[ "$pair" == *=* ]] || { one=0; break; }
		if [[ -z "$first" ]]; then first="${pair#*=}"; elif [[ "${pair#*=}" != "$first" ]]; then one=0; fi
	done
	if ((one)) && [[ -n "$first" ]]; then printf '%s\n' "$first"; else printf '%s\n' "$v"; fi
}

# platform_md_row <ctxs_csv>: the `| Platform | ... |` row of a run's markdown summary, next to
# its `| Run config | ... |` row; a value every member shares is shown once.
# shellcheck disable=SC2329
platform_md_row() {
	local line
	local -A _pl_rec=()
	while IFS= read -r line; do
		_pl_rec["${line%%=*}"]="${line#*=}"
	done < <(_platform_values "$1" 2>/dev/null)
	printf '| Platform | %s (TEST_PLATFORM %s); nodes %s; operator %s; istiod %s; gateway proxy %s |\n' "${_pl_rec[PLATFORM]}" \
		"${_pl_rec[TEST_PLATFORM]}" "$(platform_collapse "${_pl_rec[NODE_PROVIDER_BY_CONTEXT]}")" \
		"$(platform_collapse "${_pl_rec[MESH_OPERATOR_BY_CONTEXT]}")" "$(platform_collapse "${_pl_rec[ISTIOD_IMAGE_BY_CONTEXT]}")" \
		"$(platform_collapse "${_pl_rec[PROXY_IMAGE_BY_CONTEXT]}")"
}

# _platform_build <value>: a member's value without the state each "+"-part may end in
# ("/Available", "/Succeeded", ...): two values compare as the same build when this is equal.
# shellcheck disable=SC2329
_platform_build() {
	local part out=""
	local -a _pl_parts=()
	IFS='+' read -r -a _pl_parts <<<"$1"
	for part in ${_pl_parts[@]+"${_pl_parts[@]}"}; do
		out+="${out:++}${part%/*}"
	done
	printf '%s\n' "$out"
}

# _platform_unread <key> <value>: return 0 for a value that says it was not read: unknown (and
# unreachable for KUBE_VERSIONS).
# shellcheck disable=SC2329
_platform_unread() {
	[[ "$2" == unknown || ( "$1" == KUBE_VERSIONS && "$2" == unreachable ) ]]
}

# _platform_noun <key>: what a key's values are, for a warning ("istiod builds").
# shellcheck disable=SC2329
_platform_noun() {
	case "$1" in
	PLATFORM | PLATFORM_BY_CONTEXT) echo platforms ;;
	MESH_OPERATOR_BY_CONTEXT) echo "mesh operator builds" ;;
	ISTIOD_IMAGE_BY_CONTEXT) echo "istiod builds" ;;
	PROXY_IMAGE_BY_CONTEXT) echo "gateway proxy builds" ;;
	NODE_PROVIDER_BY_CONTEXT) echo "node providers" ;;
	KUBE_VERSIONS) echo "Kubernetes versions" ;;
	TEST_PLATFORM) echo "TEST_PLATFORM overrides (the suite charts' overlay)" ;;
	*) echo values ;;
	esac
}

# _platform_names <name>...: the first five, comma-separated, then "and N more".
# shellcheck disable=SC2329
_platform_names() {
	local out="" i=0 n
	for n in "$@"; do
		i=$((i + 1))
		((i > 5)) || out+="${out:+, }${n}"
	done
	((i <= 5)) || out+=" and $((i - 5)) more"
	printf '%s\n' "$out"
}

# _platform_drift_values <key> <tsv>...: the "<ctx>=<value>" pairs platform_drift_check wrote
# for <key> into the PLATFORM_DRIFT_FILE next to the inputs (each dir read once), one per line.
# shellcheck disable=SC2329
_platform_drift_values() {
	local key="$1" f d line pair
	local -a _pl_p=()
	local -A _pl_dirs=()
	shift
	for f in "$@"; do
		d="$(dirname "$f")"
		[[ -z "${_pl_dirs[$d]+x}" ]] || continue
		_pl_dirs[$d]=1
		[[ -f "${d}/${PLATFORM_DRIFT_FILE}" ]] || continue
		while IFS= read -r line; do
			IFS=',' read -r -a _pl_p <<<"${line#*=}"
			for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$pair" != *=* ]] || printf '%s\n' "$pair"
			done
		done < <(grep "^# ${key}=" "${d}/${PLATFORM_DRIFT_FILE}" 2>/dev/null || true)
	done
}

# platform_merge_by_context <key> <tsv>...: one *_BY_CONTEXT key (or KUBE_VERSIONS) over a
# report's inputs, member by member (PL26). One build -> that value (values that differ only in
# their state, ";"-joined); two builds, or a known value and one not read (unknown), or a build
# platform_drift_check found changed during the sweep -> <ctx>=mixed:<a>;<b> with a warning
# that says which. unknown when no input has the key; mixed:unknown,<members> when only some
# have it (the legacy warning of platform_report_values names those).
# shellcheck disable=SC2329
platform_merge_by_context() {
	local key="$1" f line pair c x v out="" n=0 missing=0 noun b builds known unread dis="" drf="" unr=""
	local -a order=() pairs=() _pl_dis=() _pl_drf=() _pl_unr=()
	local -A _pl_vals=() _pl_drift=() _pl_unread_in=()
	shift
	for f in "$@"; do
		n=$((n + 1))
		line="$(grep -m1 "^# ${key}=" "$f" 2>/dev/null || true)"
		line="${line#*=}"
		if [[ "$line" != *=* ]]; then
			missing=$((missing + 1))
			continue
		fi
		IFS=',' read -r -a pairs <<<"$line"
		for pair in "${pairs[@]}"; do
			c="${pair%%=*}"
			x="${pair#*=}"
			if [[ -z "${_pl_vals[$c]+set}" ]]; then
				order+=("$c")
				_pl_vals[$c]="$x"
			else
				case ";${_pl_vals[$c]};" in *";${x};"*) ;; *) _pl_vals[$c]+=";${x}" ;; esac
			fi
			if _platform_unread "$key" "$x"; then
				v="${_pl_unread_in[$c]:-0}"
				_pl_unread_in[$c]=$((v + 1))
			fi
		done
	done
	if ((n == 0 || missing == n)); then
		echo unknown
		return 0
	fi
	while IFS= read -r pair; do
		[[ -n "$pair" ]] || continue
		c="${pair%%=*}"
		x="${pair#*=}"
		[[ -n "${_pl_vals[$c]+set}" ]] || continue
		_pl_drift[$c]=1
		case ";${_pl_vals[$c]};" in *";${x};"*) ;; *) _pl_vals[$c]+=";${x}" ;; esac
	done < <(_platform_drift_values "$key" "$@")
	for c in "${order[@]}"; do
		known="" unread=0 builds=""
		IFS=';' read -r -a pairs <<<"${_pl_vals[$c]}"
		for x in "${pairs[@]}"; do
			if _platform_unread "$key" "$x"; then
				unread=1
				continue
			fi
			known+="${known:+;}${x}"
			b="$(_platform_build "$x")"
			case ";${builds};" in *";${b};"*) ;; *) builds+="${builds:+;}${b}" ;; esac
		done
		if [[ -z "$known" || ( "$builds" != *";"* && "$unread" == 0 && -z "${_pl_drift[$c]+x}" ) ]]; then
			out+="${out:+,}${c}=${_pl_vals[$c]}"
			continue
		fi
		out+="${out:+,}${c}=mixed:${_pl_vals[$c]}"
		if [[ -n "${_pl_drift[$c]+x}" ]]; then
			_pl_drf+=("$c")
		elif [[ "$builds" == *";"* ]]; then
			_pl_dis+=("${c} ($(platform_short_digests "${_pl_vals[$c]}"))")
		fi
		if ((unread)); then _pl_unr+=("${c} in ${_pl_unread_in[$c]:-0} of ${n}"); fi
	done
	noun="$(_platform_noun "$key")"
	# Without member names (platform_report_warnings --no-members): "2 of 3 members".
	if ((${_pl_no_members:-0})); then
		((${#_pl_dis[@]} == 0)) || dis="${#_pl_dis[@]} of ${#order[@]} members"
		((${#_pl_drf[@]} == 0)) || drf="${#_pl_drf[@]} of ${#order[@]} members"
		((${#_pl_unr[@]} == 0)) || unr="${#_pl_unr[@]} of ${#order[@]} members in some of the ${n}"
	else
		((${#_pl_dis[@]} == 0)) || dis="$(_platform_names "${_pl_dis[@]}")"
		((${#_pl_drf[@]} == 0)) || drf="$(_platform_names "${_pl_drf[@]}")"
		((${#_pl_unr[@]} == 0)) || unr="$(_platform_names "${_pl_unr[@]}")"
	fi
	if [[ -n "$dis" ]]; then
		echo "warning: input TSVs disagree on ${key} for ${dis}: the report mixes runs on different ${noun}; compare like with like" >&2
	fi
	if [[ -n "$drf" ]]; then
		echo "warning: ${key} changed during the sweep for ${drf} (${PLATFORM_DRIFT_FILE} next to its TSVs): the TSVs record the value at the sweep's start, but rows measured after the change ran on other ${noun}, and the report cannot tell which rows those are; compare like with like" >&2
	fi
	if [[ -n "$unr" ]]; then
		echo "warning: ${key} could not be read for ${unr} input TSV(s) (recorded unknown$([[ "$key" != KUBE_VERSIONS ]] || echo " or unreachable")), while other inputs have a value: the report cannot tell whether those runs had the same ${noun} as the others" >&2
	fi
	((missing == 0)) || out="mixed:unknown,${out}"
	printf '%s\n' "$out"
}

# _platform_merge_scalar <key> <tsv>...: PLATFORM or TEST_PLATFORM over a report's inputs: one
# value; mixed:<a>,<b> with a warning when two inputs disagree, or when one recorded unknown and
# another a value. A file without the line counts as unknown (the legacy warning names those).
# shellcheck disable=SC2329
_platform_merge_scalar() {
	local key="$1" f v vals="" known=0 unread=0 n=0 consequence
	shift
	for f in "$@"; do
		n=$((n + 1))
		v="$(grep -m1 "^# ${key}=" "$f" 2>/dev/null || true)"
		if [[ -n "$v" ]]; then
			v="${v#*=}"
			[[ "$v" != unknown ]] || unread=$((unread + 1))
		else
			v=unknown
		fi
		case ",${vals}," in *",${v},"*) ;; *) vals="${vals:+${vals},}${v}" ;; esac
	done
	[[ -n "$vals" ]] || { echo unknown; return 0; }
	v=",${vals},"
	v="${v//,unknown,/,}"
	v="${v#,}"
	v="${v%,}"
	[[ -z "$v" ]] || known=1
	if [[ "$vals" != *,* ]]; then
		echo "$vals"
		return 0
	fi
	case "$key" in
	TEST_PLATFORM) consequence="the report mixes runs with different TEST_PLATFORM overrides, which pick the suite charts' overlay" ;;
	*) consequence="the report mixes runs on different platforms; compare like with like" ;;
	esac
	if [[ "$v" == *,* ]]; then
		echo "warning: input TSVs disagree on ${key} (${v}); ${consequence}" >&2
	fi
	if ((known && unread)); then
		echo "warning: ${key} could not be read in ${unread} of ${n} input TSV(s) (recorded unknown), while other inputs have a value: the report cannot tell whether those runs had the same $(_platform_noun "$key") as the others" >&2
	fi
	echo "mixed:${vals}"
}

# _platform_legacy_warning [--when-mixed] <tsv>...: one warning when inputs predate the record (no
# PLATFORM line); with --when-mixed only when others have it (the merged values are then mixed:).
# shellcheck disable=SC2329
_platform_legacy_warning() {
	local f n=0 missing=0 when_mixed=0
	if [[ "${1:-}" == --when-mixed ]]; then
		when_mixed=1
		shift
	fi
	for f in "$@"; do
		n=$((n + 1))
		grep -q '^# PLATFORM=' "$f" 2>/dev/null || missing=$((missing + 1))
	done
	((when_mixed == 0 || missing < n)) || return 0
	if ((missing)); then
		echo "warning: ${missing} of ${n} input TSV(s) have no PLATFORM line: they predate the platform record (the suites supported only OpenShift with OSSM then); their platform and builds read unknown" >&2
	fi
	return 0
}

# platform_report_values <tsv>...: KEY=value for every record key (PLATFORM_KEYS order) over a
# report's inputs: _platform_merge_scalar for PLATFORM and TEST_PLATFORM,
# platform_merge_by_context for the rest. Their warnings, and one when inputs predate the
# record, go to stderr; platform_report_warnings gives the same ones for the report's body.
# shellcheck disable=SC2329
platform_report_values() {
	local k
	_platform_legacy_warning "$@"
	for k in "${PLATFORM_KEYS[@]}"; do
		case "$k" in
		PLATFORM | TEST_PLATFORM) printf '%s=%s\n' "$k" "$(_platform_merge_scalar "$k" "$@")" ;;
		*) printf '%s=%s\n' "$k" "$(platform_merge_by_context "$k" "$@")" ;;
		esac
	done
}

# platform_report_warnings [--no-members] [--with KEY]... <tsv>...: the warnings
# platform_report_values (and platform_merge_by_context of each --with key, such as
# KUBE_VERSIONS) prints for these inputs, one per line without "warning: ", for the report's
# body (platform_warning_lines): a report whose inputs disagree says so where its figures are
# read, not only on stderr (PL26). The one for inputs from before the record only when others
# have it (all of them before it: every value reads unknown, nothing is mixed). --no-members
# counts the members instead of naming them, for text that goes where context names may not
# (the scale envelope, pasted into campaign docs).
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
			continue
		fi
		[[ -n "${2:-}" ]] || die "platform_report_warnings: --with needs a key"
		_pl_with+=("$2")
		shift 2
	done
	{
		_platform_legacy_warning --when-mixed "$@"
		for k in "${PLATFORM_KEYS[@]}" ${_pl_with[@]+"${_pl_with[@]}"}; do
			case "$k" in
			PLATFORM | TEST_PLATFORM) _platform_merge_scalar "$k" "$@" >/dev/null ;;
			*) platform_merge_by_context "$k" "$@" >/dev/null ;;
			esac
		done
	} 2>&1 | sed 's/^warning: //'
}

# platform_warning_lines <md|text|comment|json> <lines>: warnings (one per line) in a report's
# format: "> **Warning:** w" blocks (markdown), "WARNING: w" (text), "# WARNING: w" (csv and
# TSV-style headers), or one compact JSON array of strings (an empty array without any).
# Nothing for the other styles when there is none.
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

# platform_report_lines <comment|text|yaml|md|json> <values>: print KEY=value lines (from
# platform_report_values) in a report's format: "# KEY=value" (csv and TSV-style headers),
# "# key: value" (text), key: "value" (markdown front matter), "| KEY | `value` |" (a markdown
# table row), or one compact JSON object with lowercase keys.
# shellcheck disable=SC2329
platform_report_lines() {
	local style="$1" kv k
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
		yaml) printf '%s: "%s"\n' "${k,,}" "${kv#*=}" ;;
		md) printf '| %s | %s |\n' "$k" "\`${kv#*=}\`" ;;
		*) die "platform_report_lines: unknown style '${style}' (comment, text, yaml, md or json)" ;;
		esac
	done <<<"$2"
}

# platform_report_is_key <key>: return 0 when <key> is one of PLATFORM_KEYS.
# shellcheck disable=SC2329
platform_report_is_key() {
	local k
	for k in "${PLATFORM_KEYS[@]}"; do [[ "$1" != "$k" ]] || return 0; done
	return 1
}

# platform_value_has <value> <word>: return 0 when any member's value (mixed, ";" and "+" lists
# included) is exactly <word>, e.g. platform_value_has "$NODE_PROVIDER_BY_CONTEXT" kind.
# shellcheck disable=SC2329
platform_value_has() {
	local flat="${1//mixed:/}" item
	local -a items=()
	IFS=',;+' read -r -a items <<<"$flat"
	for item in "${items[@]}"; do [[ "${item#*=}" != "$2" ]] || return 0; done
	return 1
}

# platform_kind_path_warning <node_provider_by_context value> <consequence>: the data warning of
# a report with cross-cluster (remote) figures when a member's nodes are kind's, else nothing.
# On kind the east-west gateway's LoadBalancer is cloud-provider-kind's userspace Envoy
# (ipMode: Proxy) on the host every kind cluster shares, not a cloud load balancer.
# shellcheck disable=SC2329
platform_kind_path_warning() {
	platform_value_has "$1" kind || return 0
	printf '%s\n' "Nodes on kind (NODE_PROVIDER_BY_CONTEXT): the cross-cluster path runs through cloud-provider-kind's userspace Envoy (the east-west gateway's LoadBalancer, ipMode: Proxy) on the host all kind clusters share, so ${2}"
}

# platform_short_digests <text>: every sha256:<64 hex> shortened to its first 12 hex digits,
# for a table or a summary (the record and the TSVs keep the full digest).
# shellcheck disable=SC2329
platform_short_digests() {
	printf '%s\n' "$1" | sed -E 's/(sha256:[0-9a-f]{12})[0-9a-f]{52}/\1/g'
}

# platform_summary <by_context value>: the value without member names (the scale envelope is
# pasted into campaign docs): the one value every member shares, else each distinct value with
# its member count ("pilot:1.30.5 (2 members); pilot:1.30.6 (1 member)"); digests shortened.
# A token without a member (mixed:unknown: some inputs predate the record) comes first.
# shellcheck disable=SC2329
platform_summary() {
	local pair v out="" i
	local -a _pl_p=() _pl_order=()
	local -A _pl_cnt=()
	IFS=',' read -r -a _pl_p <<<"$1"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		if [[ "$pair" != *=* ]]; then
			out+="${out:+; }${pair}"
			continue
		fi
		v="${pair#*=}"
		if [[ -z "${_pl_cnt[$v]+x}" ]]; then
			_pl_order+=("$v")
			_pl_cnt[$v]=0
		fi
		i="${_pl_cnt[$v]}"
		_pl_cnt[$v]=$((i + 1))
	done
	if ((${#_pl_order[@]} == 1)) && [[ -z "$out" ]]; then
		out="${_pl_order[0]}"
	else
		for v in ${_pl_order[@]+"${_pl_order[@]}"}; do
			i="${_pl_cnt[$v]}"
			out+="${out:+; }${v} (${i} member$( ((i == 1)) || echo s))"
		done
	fi
	platform_short_digests "${out:-unknown}"
}

# _platform_build_set <key> <member value>: the builds a (merged) member value holds, sorted and
# ";"-joined, without "mixed:" and the values not read; "?" appended when one was not read.
# shellcheck disable=SC2329
_platform_build_set() {
	local x unread=0
	local -a _pl_a=() _pl_b=()
	IFS=';' read -r -a _pl_a <<<"${2#mixed:}"
	for x in ${_pl_a[@]+"${_pl_a[@]}"}; do
		if _platform_unread "$1" "$x"; then
			unread=1
		else
			_pl_b+=("$(_platform_build "$x")")
		fi
	done
	x="$(printf '%s\n' ${_pl_b[@]+"${_pl_b[@]}"} | LC_ALL=C sort -u | paste -sd ';' -)"
	((unread == 0)) || x+="?"
	printf '%s\n' "$x"
}

# _platform_compare_key <key> <ref value> <value>: same, differs or unknown for one record key
# of two platform_report_values outputs. Member by member for *_BY_CONTEXT: a member whose known
# builds differ makes it differs; else a member not read on a side, or on one side only, makes
# it unknown. A state-only difference is the same build.
# shellcheck disable=SC2329
_platform_compare_key() {
	local key="$1" pair c a b res=same
	local -a _pl_p=() _pl_all=()
	local -A _pl_r=() _pl_v=() _pl_in=()
	if [[ "$key" != *_BY_CONTEXT ]]; then
		a="$(_platform_build_set "$key" "${2//,/;}")"
		b="$(_platform_build_set "$key" "${3//,/;}")"
		if [[ -z "${a%\?}" || -z "${b%\?}" ]]; then echo unknown
		elif [[ "${a%\?}" != "${b%\?}" ]]; then echo differs
		elif [[ "$a" == *"?" || "$b" == *"?" ]]; then echo unknown
		else echo same; fi
		return 0
	fi
	IFS=',' read -r -a _pl_p <<<"$2"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		if [[ "$pair" != *=* ]]; then res=unknown; continue; fi
		c="${pair%%=*}"
		_pl_r[$c]="${pair#*=}"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done
	IFS=',' read -r -a _pl_p <<<"$3"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		if [[ "$pair" != *=* ]]; then res=unknown; continue; fi
		c="${pair%%=*}"
		_pl_v[$c]="${pair#*=}"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done
	((${#_pl_all[@]})) || res=unknown
	for c in ${_pl_all[@]+"${_pl_all[@]}"}; do
		if [[ -z "${_pl_r[$c]+x}" || -z "${_pl_v[$c]+x}" ]]; then res=unknown; continue; fi
		a="$(_platform_build_set "$key" "${_pl_r[$c]}")"
		b="$(_platform_build_set "$key" "${_pl_v[$c]}")"
		if [[ -n "${a%\?}" && -n "${b%\?}" && "${a%\?}" != "${b%\?}" ]]; then
			echo differs
			return 0
		fi
		if [[ "$a" != "$b" || "$a" == *"?" || -z "$a" ]]; then res=unknown; fi
	done
	echo "$res"
}

# platform_compare_values <ref values> <values>: "KEY\tsame|differs|unknown" per record key
# (PLATFORM_KEYS order) of two platform_report_values outputs, such as a tuning pass against
# the baseline (_platform_compare_key).
# shellcheck disable=SC2329
platform_compare_values() {
	local k a b
	for k in "${PLATFORM_KEYS[@]}"; do
		a="$(sed -n "s/^${k}=//p" <<<"$1" | head -n 1)"
		b="$(sed -n "s/^${k}=//p" <<<"$2" | head -n 1)"
		printf '%s\t%s\n' "$k" "$(_platform_compare_key "$k" "${a:-unknown}" "${b:-unknown}")"
	done
}

# _platform_rows_of <ctxs_csv>: these members' lines of PLATFORM_PROBE_ROWS, in order (a member
# without one gets a line of unknowns).
# shellcheck disable=SC2329
_platform_rows_of() {
	local ctx row
	local -a _pl_c=()
	split_csv "$1" _pl_c
	for ctx in ${_pl_c[@]+"${_pl_c[@]}"}; do
		row="$(_platform_row "$ctx")" || row="${ctx}"$'\tunknown\tunknown\tunknown\tunknown\tunknown'
		printf '%s\n' "$row"
	done
}

# _platform_file_rows <tsv>: the record a TSV's preamble holds (the `# ` lines before its
# header), as PLATFORM_PROBE_ROWS lines; a member a key does not list reads unknown there.
# Nothing for a file without PLATFORM_BY_CONTEXT (it predates the record).
# shellcheck disable=SC2329
_platform_file_rows() {
	local line k pair c j row
	local -a _pl_keys=(PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT PROXY_IMAGE_BY_CONTEXT
		NODE_PROVIDER_BY_CONTEXT)
	local -a _pl_order=() _pl_p=()
	local -A _pl_fv=() _pl_seen=() _pl_in=()
	while IFS= read -r line; do
		[[ "$line" == '#'* ]] || break
		line="${line#\#}"
		line="${line# }"
		k="${line%%=*}"
		for j in 0 1 2 3 4; do
			[[ "$k" == "${_pl_keys[j]}" && -z "${_pl_seen[$k]+x}" ]] || continue
			_pl_seen[$k]=1
			IFS=',' read -r -a _pl_p <<<"${line#*=}"
			for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$pair" == *=* ]] || continue
				c="${pair%%=*}"
				[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_order+=("$c"); }
				_pl_fv["${j}|${c}"]="${pair#*=}"
			done
		done
	done <"$1"
	[[ -n "${_pl_seen[PLATFORM_BY_CONTEXT]+x}" ]] || return 0
	for c in ${_pl_order[@]+"${_pl_order[@]}"}; do
		row="$c"
		for j in 0 1 2 3 4; do row+=$'\t'"${_pl_fv["${j}|${c}"]:-unknown}"; done
		printf '%s\n' "$row"
	done
}

# _platform_diff <old rows> <new rows> <ctxs_csv>: two records compared member by member (the
# members of <ctxs_csv>, then those only <old rows> has): "<kind>\t<ctx>\t<key>\t<old>\t<new>"
# per finding. differs: two known values of another build (_platform_build: a state-only
# difference is none); unknown: a value not read on either side; missing: a member one side
# does not have (key "-", the side without it "-").
# shellcheck disable=SC2329
_platform_diff() {
	local c o n j ov nv
	local -a _pl_c=() _pl_all=() _pl_o=() _pl_n=()
	local -a _pl_keys=(PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT PROXY_IMAGE_BY_CONTEXT
		NODE_PROVIDER_BY_CONTEXT)
	local -A _pl_in=()
	split_csv "$3" _pl_c
	for c in ${_pl_c[@]+"${_pl_c[@]}"}; do
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done
	while IFS= read -r o; do
		[[ -n "$o" ]] || continue
		c="${o%%$'\t'*}"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done <<<"$1"
	for c in ${_pl_all[@]+"${_pl_all[@]}"}; do
		o="$(_platform_rows_find "$1" "$c")" || o=""
		n="$(_platform_rows_find "$2" "$c")" || n=""
		if [[ -z "$o" || -z "$n" ]]; then
			printf 'missing\t%s\t-\t%s\t%s\n' "$c" "${o:+recorded}${o:--}" "${n:+read}${n:--}"
			continue
		fi
		IFS=$'\t' read -r -a _pl_o <<<"$o"
		IFS=$'\t' read -r -a _pl_n <<<"$n"
		for j in 0 1 2 3 4; do
			ov="${_pl_o[j + 1]:-unknown}"
			nv="${_pl_n[j + 1]:-unknown}"
			if [[ "$ov" == unknown || "$nv" == unknown ]]; then
				printf 'unknown\t%s\t%s\t%s\t%s\n' "$c" "${_pl_keys[j]}" "$ov" "$nv"
			elif [[ "$(_platform_build "$ov")" != "$(_platform_build "$nv")" ]]; then
				printf 'differs\t%s\t%s\t%s\t%s\n' "$c" "${_pl_keys[j]}" "$ov" "$nv"
			fi
		done
	done
}

# _platform_preamble_value <tsv> <key>: the first `# <key>=` value of a TSV's preamble; return 1
# when it has none.
# shellcheck disable=SC2329
_platform_preamble_value() {
	awk -v k="# ${2}=" '!/^#/ { exit 1 } index($0, k) == 1 { print substr($0, length(k) + 1); found = 1; exit } END { exit !found }' "$1"
}

# platform_resume_check <tsv> <ctxs_csv> [<tuning_ctx>]: before --resume appends rows to <tsv>
# (which keeps the preamble the sweep started with), compare the record platform_probe just
# read for these members with the one that preamble holds; with <tuning_ctx> (the sweep's first
# context), also its TUNING_BASELINE and SIDECAR_EGRESS_HOSTS with a fresh tuning_baseline_state
# read of the member the TSV read them on (its record's first member, when it is in this run;
# else <tuning_ctx>, with a warning). A definite difference dies: the new rows would be credited to
# builds or levers that did not produce them. A value not read on either side, a member on one
# side only, an older TSV without the record and another TEST_PLATFORM warn. Nothing in a
# dry-run, or when <tsv> has no header yet (it is written anew).
# shellcheck disable=SC2329
platform_resume_check() {
	local tsv="$1" _pl_ctxs="$2" tctx="${3:-}" old new kind c key o n dies="" line tb_old eh_old tb_new="" eh_new="" lv
	local again tp_old snap
	local -a _pl_lv=() _pl_uo=() _pl_lo=()
	local -A _pl_unk=() _pl_ov=() _pl_nv=()
	[[ -z "$tctx" ]] || declare -F tuning_baseline_state >/dev/null ||
		die "platform_resume_check needs tuning_baseline_state (source tests/lib/preamble.sh)"
	! ((${DRY_RUN:-0})) || return 0
	[[ -f "$tsv" ]] && grep -q '^timestamp' "$tsv" 2>/dev/null || return 0
	again="Start a new sweep instead: run $(printf '%q' "$0") again with this sweep's flags (and --config) but without --resume; it writes a new sweep-<RUN_ID>/ in its results dir and leaves this one as it is."
	# The run-config snapshot config_snapshot keeps in the sweep dir (a sweep run with --config).
	for snap in "$(dirname "$tsv")"/run-config-*.env; do
		[[ -f "$snap" ]] || continue
		again+=" This sweep's config snapshot replays its --config values: $(printf '%q' "$0") --config $(printf '%q' "$snap") (plus the flags it ran with besides --config)."
		break
	done
	again+=" Or put the members back on what the TSV records and resume."
	old="$(_platform_file_rows "$tsv")"
	new="$(_platform_rows_of "$_pl_ctxs")"
	if [[ -z "$old" ]]; then
		echo "warning: --resume: ${tsv} predates the platform record (no PLATFORM_BY_CONTEXT line), so this run cannot tell whether the members still run the builds its rows were measured on; its report reads them unknown" >&2
	else
		while IFS=$'\t' read -r kind c key o n; do
			case "$kind" in
			differs) dies+=$'\n'"  ${c}: ${key} recorded ${o}, now ${n}" ;;
			unknown)
				[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
				_pl_unk[$c]+="${_pl_unk[$c]:+, }${key}"
				;;
			missing)
				if [[ "$o" == - ]]; then
					echo "warning: --resume: ${c} is a member of this run but not of the record in ${tsv}; its rows will be the only ones with its builds" >&2
				else
					echo "warning: --resume: ${c} is in the record of ${tsv} but not a member of this run" >&2
				fi
				;;
			esac
		done < <(_platform_diff "$old" "$new" "$_pl_ctxs")
		for c in ${_pl_uo[@]+"${_pl_uo[@]}"}; do
			echo "warning: --resume: ${c}: ${_pl_unk[$c]} not read in the record of ${tsv} or now, so this run cannot tell whether they changed since its rows were measured" >&2
		done
	fi
	tp_old="$(_platform_preamble_value "$tsv" TEST_PLATFORM)" || tp_old=""
	if [[ -n "$tp_old" && "$tp_old" != "${TEST_PLATFORM:-auto}" ]]; then
		echo "warning: --resume: ${tsv} was started with TEST_PLATFORM=${tp_old}, this run has TEST_PLATFORM=${TEST_PLATFORM:-auto}: its suite charts may get another overlay than the recorded rows had" >&2
	fi
	# The TSV read TUNING_BASELINE on its first member (the sweep's first context then): read it
	# there again when that member is in this run, whatever order --contexts lists them in now.
	if [[ -n "$tctx" && -n "$old" && "${old%%$'\t'*}" != "$tctx" ]]; then
		if [[ ",${_pl_ctxs}," == *",${old%%$'\t'*},"* ]]; then
			echo "--resume: reading TUNING_BASELINE on ${old%%$'\t'*}, the member ${tsv} read it on (this run lists ${tctx} first)" >&2
			tctx="${old%%$'\t'*}"
		else
			echo "warning: --resume: ${tsv} read TUNING_BASELINE on ${old%%$'\t'*}, which is not a member of this run; comparing it with ${tctx}'s levers" >&2
		fi
	fi
	if [[ -n "$tctx" ]]; then
		tb_old="$(_platform_preamble_value "$tsv" TUNING_BASELINE)" || tb_old=""
		eh_old="$(_platform_preamble_value "$tsv" SIDECAR_EGRESS_HOSTS)" || eh_old=""
		while IFS= read -r line; do
			case "$line" in
			TUNING_BASELINE=*) tb_new="${line#*=}" ;;
			SIDECAR_EGRESS_HOSTS=*) eh_new="${line#*=}" ;;
			esac
		done < <(tuning_baseline_state "$tctx" "${KUBECTL[@]}")
		if [[ -z "$tb_old" || "$tb_old" == unknown || -z "$tb_new" ]]; then
			echo "warning: --resume: TUNING_BASELINE ${tb_old:+recorded ${tb_old}}${tb_old:-is not recorded in ${tsv}}${tb_new:+, now ${tb_new}}: this run cannot tell whether the tuning levers on ${tctx} changed since its rows were measured" >&2
		else
			IFS=',' read -r -a _pl_lv <<<"$tb_old"
			for lv in ${_pl_lv[@]+"${_pl_lv[@]}"}; do
				_pl_lo+=("${lv%%=*}")
				_pl_ov[${lv%%=*}]="${lv#*=}"
			done
			IFS=',' read -r -a _pl_lv <<<"$tb_new"
			for lv in ${_pl_lv[@]+"${_pl_lv[@]}"}; do _pl_nv[${lv%%=*}]="${lv#*=}"; done
			for lv in ${_pl_lo[@]+"${_pl_lo[@]}"}; do
				o="${_pl_ov[$lv]}"
				n="${_pl_nv[$lv]:-unknown}"
				if [[ "$o" == unknown || "$n" == unknown ]]; then
					echo "warning: --resume: TUNING_BASELINE ${lv} recorded ${o}, now ${n} on ${tctx}: this run cannot tell whether that lever changed since its rows were measured" >&2
				elif [[ "$o" != "$n" ]]; then
					dies+=$'\n'"  ${tctx}: TUNING_BASELINE ${lv} recorded ${o}, now ${n}"
				fi
			done
			if [[ -n "$eh_old" && "$eh_old" != unknown && -n "$eh_new" && "$eh_new" != unknown ]]; then
				[[ "$eh_old" == "$eh_new" ]] || dies+=$'\n'"  ${tctx}: SIDECAR_EGRESS_HOSTS recorded ${eh_old}, now ${eh_new}"
			else
				echo "warning: --resume: SIDECAR_EGRESS_HOSTS ${eh_old:+recorded ${eh_old}}${eh_old:-is not recorded in ${tsv}}${eh_new:+, now ${eh_new}}: this run cannot tell whether the root Sidecar's egress hosts on ${tctx} changed since its rows were measured" >&2
			fi
		fi
	fi
	[[ -z "$dies" ]] || die "--resume: ${tsv} was started on other builds or tuning levers than the members have now:${dies}
The rows this run appends would be credited to what its preamble records. ${again}"
}

# platform_drift_check <sweep_dir> <ctxs_csv>: after a sweep's last step (outside every window;
# nothing in a dry-run), read these members' record again and compare it with the one the sweep
# started with (PLATFORM_PROBE_ROWS). A build that changed warns, naming the member, key and
# both values, and goes into <sweep_dir>/platform-drift.txt (PLATFORM_DRIFT_FILE: "# <KEY>=
# <ctx>=<value at the end>,..." lines), which each report of the sweep merges as a second
# value (platform_merge_by_context: mixed:, with a warning in its body). A value not read at
# either end warns only. It never fails the sweep (PL40: its reports run next): a check it
# cannot make is a warning.
# shellcheck disable=SC2329
platform_drift_check() {
	local dir="$1" _pl_ctxs="$2" start now kind c key o n marker found="" k fresh=0
	local -a _pl_c=() _pl_uo=()
	local -A _pl_end=() _pl_unk=()
	! ((${DRY_RUN:-0})) || return 0
	split_csv "$_pl_ctxs" _pl_c
	((${#_pl_c[@]})) || return 0
	if ! declare -F reach_sanitize >/dev/null || [[ -z "${KUBECTL[*]:-}" ]]; then
		echo "warning: platform_drift_check needs reach_sanitize (source tests/lib/reach.sh) and KUBECTL; not checked, so the reports cannot tell whether a build changed during the sweep" >&2
		return 0
	fi
	start="$(_platform_rows_of "$_pl_ctxs")"
	echo "Platform record: reading ${_pl_c[*]} again, to check that no build changed during the sweep"
	if ! now="$(_platform_read_members "${_pl_c[@]}")"; then
		echo "warning: the platform record could not be read again (no temp dir), so the reports cannot tell whether a build changed during the sweep" >&2
		return 0
	fi
	while IFS=$'\t' read -r kind c key o n; do
		case "$kind" in
		differs)
			echo "warning: ${c}: ${key} changed during the sweep: ${o} at its start, ${n} at its end; rows measured after the change ran on the new build (written to ${dir}/${PLATFORM_DRIFT_FILE}, so its reports read ${key} mixed)" >&2
			_pl_end[$key]+="${_pl_end[$key]:+,}${c}=${n}"
			found=1
			;;
		unknown)
			[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
			_pl_unk[$c]+="${_pl_unk[$c]:+, }${key}"
			;;
		esac
	done < <(_platform_diff "$start" "$now" "$_pl_ctxs")
	for c in ${_pl_uo[@]+"${_pl_uo[@]}"}; do
		echo "warning: ${c}: ${_pl_unk[$c]} not read at the sweep's start or end, so whether they changed during the sweep is not known" >&2
	done
	[[ -n "$found" ]] || return 0
	marker="${dir}/${PLATFORM_DRIFT_FILE}"
	[[ -f "$marker" ]] || fresh=1
	if ! {
		((fresh == 0)) || echo "# Platform builds that changed during this sweep: the value at its end, per member (tests/lib/platform.sh platform_drift_check; the TSVs record the value at its start)"
		echo "# DRIFT_READ_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		for k in "${PLATFORM_KEYS[@]}"; do
			[[ -z "${_pl_end[$k]+x}" ]] || echo "# ${k}=${_pl_end[$k]}"
		done
	} >>"$marker"; then
		echo "warning: could not write ${marker}: the reports of this sweep will not show that a build changed during it" >&2
	fi
	return 0
}
