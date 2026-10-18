#!/usr/bin/env bash
# Platform of a mesh member and the suite-chart overlay for it. Sourced, never executed.
#
# Consumers: propagation, churn, churn-dataplane, controlplane, dataplane (the 001 setup scripts:
# the chart overlay; the TSV writers and reports: the platform record), gateway-api (001: the
# platform record and the operator build), tuning (003/006: the hub's Argo CD namespace; 004: the
# record of each pass)
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
#   platform_member_value <ctx> <field>     -> one value of a member's record (operator, ...)
#   platform_preamble_lines <ctxs_csv>      -> the record's `# KEY=value` TSV preamble lines
#   platform_md_row <ctxs_csv>              -> the `| Platform | ... |` row of a run summary
#   platform_collapse <by_context value>    -> the one value every member shares, else as is
#   platform_report_values <tsv>...         -> KEY=value per record key over a report's inputs
#   platform_report_lines <style> <values>  -> those lines in a report format (comment, text,
#                                              yaml, md or json)
#   platform_merge_by_context <key> <tsv>...
#                                           -> one *_BY_CONTEXT key over a report's inputs
#   platform_report_is_key <key>            -> return 0 for a record key
#   platform_value_has <value> <word>       -> return 0 when a member's value holds <word>
#
# Requires KUBECTL (resolve_kubectl) and TEST_PLATFORM (config/options.env: auto,
# kubernetes or openshift; read at call time). With DRY_RUN=1 and TEST_PLATFORM=auto no
# cluster is asked and the Kubernetes defaults render, so a dry-run stays offline; set
# TEST_PLATFORM=openshift to preview the OpenShift render. Needs split_csv and die
# (tests/lib/common.sh); platform_probe needs reach_sanitize (tests/lib/reach.sh: its warnings
# mask addresses), platform_report_values config_report_value (tests/lib/config.sh).
#
# The platform record (PL2, PL36, PL39, PL41): what each member ran, read live and once per
# run, before any measurement window, into every TSV preamble and every report format (PL19).
# Keys, each member's value as <ctx>=<value>, comma-separated like KUBE_VERSIONS:
#   PLATFORM                  kubernetes | openshift over the members; mixed (both) or unknown
#   TEST_PLATFORM             the override (auto = asked each member; else PLATFORM_BY_CONTEXT
#                             holds that value as given, without asking)
#   PLATFORM_BY_CONTEXT       kubernetes | openshift | unknown
#   MESH_OPERATOR_BY_CONTEXT  Kubernetes: sail-operator:<tag>[@<digest>]/<Available|Unavailable>
#                             (the Deployment sail-operator in namespace sail-operator; the
#                             digest the pods run); OpenShift: servicemeshoperator3:<version>/
#                             <phase> (its CSV in openshift-operators). absent: none there (a
#                             definitive read of a kind the platform serves, on a platform asked
#                             of the member, not set by TEST_PLATFORM); unknown: not read
#   ISTIOD_IMAGE_BY_CONTEXT   the istiod pods' discovery image (app=istiod in istio-system)
#   PROXY_IMAGE_BY_CONTEXT    the ingress gateway pods' istio-proxy image (istio=ingressgateway
#                             in istio-system): the injected proxy build. A gateway not
#                             restarted since an upgrade shows the build it started with; the
#                             test pods' sidecars get the injector's current one.
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
# others, like RUN_CONFIG. A standalone step reads its own members. With DRY_RUN=1 nothing is
# read and every value is unknown.
# shellcheck shell=bash

# Fixed by the charts (do not override them there): the Sail operator's namespace and
# Deployment on Kubernetes (charts/gitops-hub-ocm-placement-appset/values-sail-operator.yaml),
# the OSSM operator's namespace and package on OpenShift (charts/spoke-ossm-operator), and the
# pod labels of istiod and of the ingress gateway in istio-system (charts/spoke-ossm,
# charts/spoke-ingress-gateway).
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

# platform_of <ctx>: TEST_PLATFORM kubernetes or openshift is used as is. auto asks the
# cluster whether it serves security.openshift.io/v1 (SecurityContextConstraints). It never
# guesses: a member it cannot ask is an error, since the wrong overlay gets pods rejected.
# shellcheck disable=SC2329
platform_of() {
	local ctx="$1" versions
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
	if ! versions="$("${KUBECTL[@]}" --context="$ctx" --request-timeout=20s api-versions 2>&1)"; then
		echo "error: cannot list the API versions of context $ctx to tell Kubernetes from OpenShift (set TEST_PLATFORM to skip the check): ${versions}" >&2
		return 1
	fi
	if grep -qx 'security.openshift.io/v1' <<<"$versions"; then
		echo openshift
	else
		echo kubernetes
	fi
}

# platform_chart_args <chart-dir> <ctx> <out_arrayname>
# shellcheck disable=SC2329
platform_chart_args() {
	local chart="$1" ctx="$2" platform
	local -n _pca_out="$3"
	_pca_out=()
	if ((${DRY_RUN:-0})) && [[ "${TEST_PLATFORM:-auto}" == auto ]]; then
		return 0
	fi
	platform="$(platform_of "$ctx")" || return 1
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
	*) die "TEST_PLATFORM must be auto, kubernetes or openshift (got: ${TEST_PLATFORM}); auto, the default, asks each cluster" ;;
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
# shellcheck disable=SC2329
_platform_probe_member() {
	local ctx="$1" w="$2" platform op=unknown istiod=unknown proxy=unknown nodes=unknown rc=0 f
	local -a val=()
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
	if ! platform="$(platform_of "$ctx" 2>"${w}/platform.err")"; then
		platform=unknown
		_platform_warn "$ctx" "the platform (so the mesh operator build is not read either)" "${w}/platform.err"
		grep -q 'Error from server' "${w}/platform.err" || rc=1
	fi
	if ((rc != 1)); then
		case "$platform" in
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
		if [[ "$platform" != unknown && ( "$rc" != 0 || -z "$op" ) ]]; then
			[[ -s "${w}/op.json.err" ]] || echo "the reply did not parse" >"${w}/op.json.err"
			_platform_warn "$ctx" "the mesh operator build" "${w}/op.json.err"
			op=unknown
		fi
		# A platform set by TEST_PLATFORM was not asked of the member: none where it looks may
		# be the other platform's operator, so that is unknown too, never absent.
		if [[ "$op" == absent && "${TEST_PLATFORM:-auto}" != auto ]]; then
			echo "warning: ${ctx}: no mesh operator where TEST_PLATFORM=${TEST_PLATFORM} looks, and the member's platform was not asked; recorded as unknown, not absent" >&2
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
			proxy="$(jq -r "{items: [.items[]? | select(.metadata.labels.istio? == \"ingressgateway\")]} | $(platform_pod_filter istio-proxy)" \
				"${w}/pods.json" 2>/dev/null | cut -f1)" || proxy=""
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
	val=("$(_platform_sanitize "$platform")" "$(_platform_sanitize "$op")" "$(_platform_sanitize "$istiod")"
		"$(_platform_sanitize "$proxy")" "$(_platform_sanitize "$nodes")")
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ctx" "${val[@]}"
}

# _platform_row <ctx>: the member's line of PLATFORM_PROBE_ROWS; return 1 when it has none.
# shellcheck disable=SC2329
_platform_row() {
	local line
	while IFS= read -r line; do
		if [[ -n "$line" && "${line%%$'\t'*}" == "$1" ]]; then
			printf '%s\n' "$line"
			return 0
		fi
	done <<<"${PLATFORM_PROBE_ROWS:-}"
	return 1
}

# platform_probe <ctxs_csv>: read the platform record of the members not in PLATFORM_PROBE_ROWS
# yet, in parallel (a member's reads one after the other, each bounded by
# PLATFORM_READ_TIMEOUT), and add them to it (exported). Call it in the script's own shell (not
# in $(...)), before any measurement window. Never fails for a member it cannot read: those
# values are unknown and each one gets a warning.
# shellcheck disable=SC2329
platform_probe() {
	local ctx i tmp row
	local -a ctxs=() todo=() pids=()
	platform_validate
	# Checked before the dry-run returns, so CI's dry-runs catch a caller that lacks it.
	declare -F reach_sanitize >/dev/null || die "platform_probe needs reach_sanitize (source tests/lib/reach.sh)"
	split_csv "$1" ctxs
	PLATFORM_PROBE_LAST="$(IFS=,; echo "${ctxs[*]}")"
	for ctx in "${ctxs[@]}"; do
		_platform_row "$ctx" >/dev/null || todo+=("$ctx")
	done
	((${#todo[@]})) || return 0
	if ((${DRY_RUN:-0})); then
		for ctx in "${todo[@]}"; do
			PLATFORM_PROBE_ROWS+="${ctx}"$'\tunknown\tunknown\tunknown\tunknown\tunknown\n'
		done
		export PLATFORM_PROBE_ROWS
		return 0
	fi
	[[ -n "${KUBECTL[*]:-}" ]] || die "neither kubectl nor oc found on PATH (platform_probe needs KUBECTL)"
	tmp="$(mktemp -d)"
	for i in "${!todo[@]}"; do
		mkdir -p "${tmp}/${i}"
		(_platform_probe_member "${todo[i]}" "${tmp}/${i}" >"${tmp}/${i}.row" 2>"${tmp}/${i}.warn") &
		pids+=("$!")
	done
	for i in "${pids[@]}"; do wait "$i" || true; done
	for i in "${!todo[@]}"; do
		cat "${tmp}/${i}.warn" >&2 2>/dev/null || true
		row="$(head -n 1 "${tmp}/${i}.row" 2>/dev/null || true)"
		if [[ "${row%%$'\t'*}" != "${todo[i]}" ]]; then
			echo "warning: ${todo[i]}: the platform record read failed; every value of it is unknown" >&2
			row="${todo[i]}"$'\tunknown\tunknown\tunknown\tunknown\tunknown'
		fi
		PLATFORM_PROBE_ROWS+="${row}"$'\n'
	done
	rm -rf "$tmp"
	export PLATFORM_PROBE_ROWS
}

# platform_member_value <ctx> <platform|operator|istiod|proxy|nodes>: one value of a member's
# record (PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ...); unknown when it was not read.
# shellcheck disable=SC2329
platform_member_value() {
	local row i
	local -a f=()
	case "$2" in
	platform) i=1 ;;
	operator) i=2 ;;
	istiod) i=3 ;;
	proxy) i=4 ;;
	nodes) i=5 ;;
	*) die "platform_member_value: unknown field '$2' (platform, operator, istiod, proxy or nodes)" ;;
	esac
	row="$(_platform_row "$1")" || row=""
	IFS=$'\t' read -r -a f <<<"$row"
	printf '%s\n' "${f[i]:-unknown}"
}

# platform_probed_contexts: the members of this shell's last platform_probe call, comma-separated
# (PLATFORM_PROBE_LAST, not exported: a sweep step's own members, not every member the sweep
# read), else every member in PLATFORM_PROBE_ROWS. A reach TSV records the record of these.
# shellcheck disable=SC2329
platform_probed_contexts() {
	local line out=""
	if [[ -n "${PLATFORM_PROBE_LAST+set}" ]]; then
		printf '%s\n' "$PLATFORM_PROBE_LAST"
		return 0
	fi
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

# platform_probe_load <file>: add the members of a saved record that PLATFORM_PROBE_ROWS lacks
# (an inherited record wins); a missing file adds nothing.
# shellcheck disable=SC2329
platform_probe_load() {
	local line
	[[ -f "$1" ]] || return 0
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		_platform_row "${line%%$'\t'*}" >/dev/null || PLATFORM_PROBE_ROWS+="${line}"$'\n'
	done <"$1"
	export PLATFORM_PROBE_ROWS
}

# _platform_values <ctxs_csv>: the record as KEY=value lines (PLATFORM_KEYS order) for these
# members; a member platform_probe did not read warns and reads unknown.
# shellcheck disable=SC2329
_platform_values() {
	local ctx row agg sk=0 so=0 su=0 c j
	local -a ctxs=() f=() by=("" "" "" "" "")
	split_csv "$1" ctxs
	for ctx in "${ctxs[@]}"; do
		if ! row="$(_platform_row "$ctx")"; then
			echo "warning: ${ctx}: no platform record was read (platform_probe was not called for it); its values read unknown" >&2
			row="${ctx}"$'\tunknown\tunknown\tunknown\tunknown\tunknown'
		fi
		IFS=$'\t' read -r -a f <<<"$row"
		case "${f[1]}" in
		kubernetes) sk=1 ;;
		openshift) so=1 ;;
		*) su=1 ;;
		esac
		c="$(_platform_sanitize "$ctx")"
		for j in 0 1 2 3 4; do
			by[j]+="${by[j]:+,}${c}=${f[j + 1]:-unknown}"
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
	echo "PLATFORM_BY_CONTEXT=${by[0]:-unknown}"
	echo "MESH_OPERATOR_BY_CONTEXT=${by[1]:-unknown}"
	echo "ISTIOD_IMAGE_BY_CONTEXT=${by[2]:-unknown}"
	echo "PROXY_IMAGE_BY_CONTEXT=${by[3]:-unknown}"
	echo "NODE_PROVIDER_BY_CONTEXT=${by[4]:-unknown}"
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
	local -A v=()
	while IFS= read -r line; do
		v["${line%%=*}"]="${line#*=}"
	done < <(_platform_values "$1" 2>/dev/null)
	printf '| Platform | %s (TEST_PLATFORM %s); nodes %s; operator %s; istiod %s; proxy %s |\n' "${v[PLATFORM]}" \
		"${v[TEST_PLATFORM]}" "$(platform_collapse "${v[NODE_PROVIDER_BY_CONTEXT]}")" \
		"$(platform_collapse "${v[MESH_OPERATOR_BY_CONTEXT]}")" "$(platform_collapse "${v[ISTIOD_IMAGE_BY_CONTEXT]}")" \
		"$(platform_collapse "${v[PROXY_IMAGE_BY_CONTEXT]}")"
}

# platform_merge_by_context <key> <tsv>...: one *_BY_CONTEXT key over a report's inputs: each
# member's value, or <ctx>=mixed:<a>;<b> with a warning when the inputs disagree on it (PL26).
# unknown when no input has the key; mixed:unknown,<members> when only some have it.
# shellcheck disable=SC2329
platform_merge_by_context() {
	local key="$1" f line pair c x out="" n=0 missing=0
	local -a order=() pairs=()
	local -A vals=()
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
			if [[ -z "${vals[$c]+set}" ]]; then
				order+=("$c")
				vals[$c]="$x"
			else
				case ";${vals[$c]};" in *";${x};"*) ;; *) vals[$c]+=";${x}" ;; esac
			fi
		done
	done
	if ((n == 0 || missing == n)); then
		echo unknown
		return 0
	fi
	for c in "${order[@]}"; do
		if [[ "${vals[$c]}" == *";"* ]]; then
			echo "warning: input TSVs disagree on ${key} for ${c} (${vals[$c]}): the report mixes runs on different platforms or mesh builds; compare like with like" >&2
			out+="${out:+,}${c}=mixed:${vals[$c]}"
		else
			out+="${out:+,}${c}=${vals[$c]}"
		fi
	done
	((missing == 0)) || out="mixed:unknown,${out}"
	printf '%s\n' "$out"
}

# platform_report_values <tsv>...: KEY=value for every record key (PLATFORM_KEYS order) over a
# report's inputs: config_report_value for PLATFORM and TEST_PLATFORM, platform_merge_by_context
# for the rest. One warning when inputs predate the record (no PLATFORM line).
# shellcheck disable=SC2329
platform_report_values() {
	local f k n=0 missing=0
	for f in "$@"; do
		n=$((n + 1))
		grep -q '^# PLATFORM=' "$f" 2>/dev/null || missing=$((missing + 1))
	done
	if ((missing)); then
		echo "warning: ${missing} of ${n} input TSV(s) have no PLATFORM line: they predate the platform record (the suites supported only OpenShift with OSSM then); their platform and builds read unknown" >&2
	fi
	for k in "${PLATFORM_KEYS[@]}"; do
		case "$k" in
		*_BY_CONTEXT) printf '%s=%s\n' "$k" "$(platform_merge_by_context "$k" "$@")" ;;
		TEST_PLATFORM) printf '%s=%s\n' "$k" "$(config_report_value --consequence "the report mixes runs with different TEST_PLATFORM overrides" "$k" "$@")" ;;
		*) printf '%s=%s\n' "$k" "$(config_report_value --consequence "the report mixes runs on different platforms; compare like with like" "$k" "$@")" ;;
		esac
	done
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
