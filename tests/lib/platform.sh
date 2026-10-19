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
#   platform_pod_filter <container>         -> jq program over a pod list: images (of the pods
#                                              that started), restart fingerprint, Running
#                                              count, first Running pod
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
#   platform_unread_members <by_context value>
#                                           -> how many members' value was not read (unknown),
#                                              in every input or in some
#   platform_resume_check <tsv> <ctxs_csv> [<source_ctx>]
#                                           -> die when a --resume would append rows measured on
#                                              other builds, istiod settings, Kubernetes versions,
#                                              tuning levers or istiod limits than the TSV's
#                                              preamble records
#   platform_drift_check <sweep_dir> <ctxs_csv>
#                                           -> after a sweep's last step: read the record, the
#                                              tuning levers and the Kubernetes versions again; a
#                                              value that changed warns and is written to
#                                              <sweep_dir>/platform-drift.txt for its reports
#   platform_compare_values <ref> <values> [<key>...]
#                                           -> KEY<TAB>same|differs|unknown per record key (or per
#                                              <key>) of two platform_report_values outputs
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
# (tests/lib/reach.sh: their warnings mask addresses) and _config_sha256 (tests/lib/config.sh:
# the istiod env digest); platform_resume_check with a source context tuning_baseline_state and
# probe_kube_versions (tests/lib/preamble.sh), cap_istiod_limits and cap_node_totals
# (tests/lib/capacity.sh) and env_collect_infra (tests/lib/envelope.sh); platform_drift_check
# reads the levers and Kubernetes versions again with preamble.sh's (without it, a warning).
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
#   MESH_OPERATOR_BY_CONTEXT  Kubernetes: sail-operator:<tag>@<digest>/<Available|Unavailable>
#                             (the Deployment sail-operator in namespace sail-operator; the
#                             digest its pods run, @unknown when none has started: scaled to 0,
#                             Pending; the Deployment's own when it pins one; several
#                             "+"-joined); OpenShift: servicemeshoperator3:<version>/
#                             <phase> (its CSV in openshift-operators). Read on the platform the
#                             member serves, on TEST_PLATFORM's when that could not be asked.
#                             absent: none there (a definitive read of a kind the platform
#                             serves, on the platform the member serves); unknown: not read, or
#                             none where TEST_PLATFORM looked for a member that could not be asked.
#                             The state after the last "/" is kept, but no comparison counts a
#                             value that differs only in it as another build (_platform_build)
#   ISTIOD_IMAGE_BY_CONTEXT   the istiod pods' discovery image (app=istiod in istio-system); none
#                             without such a pod
#   PROXY_IMAGE_BY_CONTEXT    the istio-proxy image of the gateway pods in istio-system (istio in
#                             (ingressgateway, eastwestgateway): the ingress and the east-west
#                             gateway, on the remote path); none without such a pod. A gateway
#                             not restarted since an upgrade shows the build it started with; the
#                             test pods' sidecars get the injector's current one (normally
#                             istiod's release, ISTIOD_IMAGE_BY_CONTEXT)
#   NODE_PROVIDER_BY_CONTEXT  the scheme of the nodes' spec.providerID (kind, aws, gce, ...;
#                             none when empty, no-nodes without nodes), deduplicated; never
#                             the full providerID. k3d (k3s://) and minikube clusters that share
#                             one host are not told apart from cloud nodes
#   ISTIOD_ENV_BY_CONTEXT     istiod's settings: the first 12 hex digits of the sha256 of its
#                             discovery container's env (name=value lines, name= plus the
#                             valueFrom's JSON, sorted), without CLUSTER_ID (the one variable that
#                             differs by member); a tuning profile's spec.values.pilot.env or a
#                             hand edit changes it. none without an istiod pod (_platform_env_digest)
# Images drop the registry host and path (a mirror can name an internal host) and carry the
# sha256 the pods run (the imageID after "@", or a bare sha256:... imageID, as kind gives a
# loaded image). Only the pods whose container started (it reports a digest) count, those not
# terminated (an evicted pod) first; when none has, each pod's spec image with @unknown, or with
# the digest the spec pins. Every comparison takes @unknown as not read (a warning), never as
# another build. Several values on one member are "+"-joined (a rollout). Every value keeps only
# [A-Za-z0-9_.:/@+-] (anything else becomes _), so it holds no tab, newline, comma, = or |.
# A file written before the record has none of these keys (the suites supported only OpenShift
# with OSSM then), and its values read unknown in a report; one written before
# ISTIOD_ENV_BY_CONTEXT has the others.
#
# A sweep calls platform_probe once with all its members, before its first step; the record
# is exported (PLATFORM_PROBE_ROWS: one line per member, <ctx> and the six values
# (PLATFORM_ROW_KEYS) tab-separated), so the steps it runs reuse it for the members it covers
# and read only the others, like RUN_CONFIG, and those whose platform it recorded unknown (a
# transient failure at the sweep's start; a phase that reuses a saved record reads nothing:
# platform_probe_load). A standalone step reads its own members. With DRY_RUN=1 nothing is read
# and every value is unknown. After its last step a sweep reads its members again
# (platform_drift_check): a build, istiod setting, tuning lever or Kubernetes version that
# changed while it ran goes to platform-drift.txt in the sweep dir, which every report of the
# sweep says in its body (the record's keys and KUBE_VERSIONS merged as a second value, mixed:).
# controlplane 003 --resume compares the record, and the once-recorded values its report applies
# to every row, with what its TSV holds (platform_resume_check).
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
# kubectl --request-timeout of each platform-record read (config/options.env; the same default
# for a caller that did not source it). platform_validate checks it.
PLATFORM_READ_TIMEOUT="${PLATFORM_READ_TIMEOUT:-20s}"
# The record's preamble keys, in order; the reports print the same list.
# shellcheck disable=SC2034  # read by the reports
PLATFORM_KEYS=(PLATFORM TEST_PLATFORM PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT
	PROXY_IMAGE_BY_CONTEXT NODE_PROVIDER_BY_CONTEXT ISTIOD_ENV_BY_CONTEXT)
# The per-member keys, in the order of a PLATFORM_PROBE_ROWS line's values (after <ctx>).
PLATFORM_ROW_KEYS=(PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT PROXY_IMAGE_BY_CONTEXT
	NODE_PROVIDER_BY_CONTEXT ISTIOD_ENV_BY_CONTEXT)
# The keys a tuning pass is compared on (tuning 004): every record key but istiod's settings,
# which a profile changes on purpose (spec.values.pilot.env).
# shellcheck disable=SC2034  # read by tuning 004
PLATFORM_PASS_KEYS=(PLATFORM TEST_PLATFORM PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT
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
# openshift, and PLATFORM_READ_TIMEOUT a kubectl --request-timeout above zero (20s, 1.5m, 1m30s,
# or seconds). Call it with the other argument checks, before anything is read.
# shellcheck disable=SC2329
platform_validate() {
	case "${TEST_PLATFORM:-auto}" in
	auto | kubernetes | openshift) ;;
	*) die "TEST_PLATFORM must be auto, kubernetes or openshift (got: ${TEST_PLATFORM}); set it in the environment, the --config file or config/options.env (auto, the default, asks each cluster)" ;;
	esac
	if [[ ! "$PLATFORM_READ_TIMEOUT" =~ ^([0-9]+(\.[0-9]+)?(ms|s|m|h))+$|^[0-9]+$ ||
		"$PLATFORM_READ_TIMEOUT" =~ ^(0+(\.0+)?(ms|s|m|h)?)+$ ]]; then
		die "PLATFORM_READ_TIMEOUT must be a kubectl --request-timeout above zero, such as 20s or 1m (got: ${PLATFORM_READ_TIMEOUT}); set it in the environment, the --config file or config/options.env"
	fi
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
# <running>\t<pod>". images: the container's image without its registry host and path plus the
# sha256 that ran (the imageID's, after "@" or a bare sha256:...), of the pods whose container
# started (it reports one) or whose spec pins a digest, those not terminated (Failed or
# Succeeded: an evicted pod) when there are any; when none started, every pod's spec image with
# @unknown (or the digest it pins); unique, "+"-joined; "none" without such a pod. A Pending or
# ContainerCreating replica, or an evicted one with an empty imageID, next to a running one is
# not another build. fingerprint: name@startTime#restarts per pod, sorted: a restart, a replaced
# pod or an added pod changes it (PL9). running: Running pods. pod: the first Running pod.
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
	       dig: ($id | if test("@sha256:") then sub("^.*@"; "") elif test("^sha256:") then . else "" end)}]
	   | (map(select(.pin or .dig != "")) as $ran | [$ran[] | select(.end | not)] as $live
	      | if ($live | length) > 0 then $live elif ($ran | length) > 0 then $ran else . end)
	   | map(.ref + (if .pin then "" elif .dig != "" then "@" + .dig else "@unknown" end))
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

# _platform_env_digest <pods.json> <workdir>: a member's ISTIOD_ENV_BY_CONTEXT from the istio-system
# pod list the probe read: per istiod pod (app=istiod; the pods whose discovery container started,
# those not terminated first, as for its image), the discovery container's env as sorted
# name=value lines (a valueFrom as name= plus its JSON, keys sorted; neither: name=), without
# CLUSTER_ID; the first 12 hex digits of each distinct list's sha256 (_config_sha256), sorted and
# "+"-joined (two during a rollout). none without an istiod pod; unknown when the list does not
# parse or no sha256 tool works.
# shellcheck disable=SC2329
_platform_env_digest() {
	local f="$1" w="$2" line d out="" i=0
	local -a _pl_dg=()
	# shellcheck disable=SC2016  # jq program: $c, $ran, ... are jq variables
	local env_jq='def canon: if type == "object" then "{" + ([to_entries | sort_by(.key)[] | (.key | tojson) + ":" + (.value | canon)] | join(",")) + "}"
			elif type == "array" then "[" + (map(canon) | join(",")) + "]" else tojson end;
		[.items[]? | select(.metadata.labels.app? == "istiod") | . as $p
		 | ([$p.spec.containers[]? | select(.name == "discovery")][0]) as $c
		 | select($c != null)
		 | {run: ([$p.status.containerStatuses[]? | select(.name == "discovery")][0].imageID // "" | test("sha256:")),
		    end: (($p.status.phase // "") | test("^(Failed|Succeeded)$")),
		    env: ([$c.env[]? | select(.name != "CLUSTER_ID")
		      | .name + "=" + (if .valueFrom != null then (.valueFrom | canon) else (.value // "") end)] | sort)}]
		| (map(select(.run)) as $ran | [$ran[] | select(.end | not)] as $live
		   | if ($live | length) > 0 then $live elif ($ran | length) > 0 then $ran else . end)
		| map(.env | tojson) | unique | .[]'
	if ! out="$(jq -r "$env_jq" "$f" 2>/dev/null)"; then
		echo unknown
		return 0
	fi
	if [[ -z "$out" ]]; then
		echo none
		return 0
	fi
	while IFS= read -r line; do
		i=$((i + 1))
		printf '%s\n' "$line" >"${w}/env.${i}"
		d="$(_config_sha256 "${w}/env.${i}")"
		if [[ "$d" == unknown ]]; then
			echo unknown
			return 0
		fi
		_pl_dg+=("${d:0:12}")
	done <<<"$out"
	printf '%s\n' "${_pl_dg[@]}" | LC_ALL=C sort -u | paste -sd '+' -
}

# _platform_probe_member <ctx> <workdir>: "<ctx>\t<platform>\t<operator>\t<istiod>\t<proxy>\t
# <nodes>\t<istiod env>" on stdout, a warning per value it could not read on stderr. After a read
# the member did not answer, the rest are not tried (each would wait out the timeout) and read
# unknown. The platform is what the member serves, whatever TEST_PLATFORM says (a disagreement
# warns); the operator is looked for on it, or on TEST_PLATFORM's when the member could not be
# asked. istiod's env comes from the same pod list as the images (no other read).
# shellcheck disable=SC2329
_platform_probe_member() {
	local ctx="$1" w="$2" platform look op=unknown istiod=unknown proxy=unknown nodes=unknown ienv=unknown rc=0 f
	local tp="${TEST_PLATFORM:-auto}"
	local -a _pl_val=()
	# The digests of the operator's pods that started (those not terminated first); @unknown when
	# none has (scaled to 0, Pending), unless the Deployment pins one; one "+"-part per digest.
	# shellcheck disable=SC2016  # jq programs: $d, $sel, $img, ... are jq variables
	local sail_jq='([.items[]? | select(.kind == "Deployment" and .metadata.name == $name)][0]) as $d
		| if $d == null then "absent" else
		  ([$d.spec.template.spec.containers[]? | select(.name == $name) | .image][0] // "") as $img
		  | ($d.spec.selector.matchLabels // {}) as $sel
		  | ([.items[]? | select(.kind == "Pod") | select((.metadata.labels // {}) as $l | $sel | to_entries | all(.value == $l[.key]))
		      | {end: ((.status.phase // "") | test("^(Failed|Succeeded)$")),
		         dig: ([.status.containerStatuses[]? | select(.name == $name) | .imageID][0] // ""
		           | if test("@sha256:") then sub("^.*@"; "") elif test("^sha256:") then . else "" end)}
		      | select(.dig != "")]) as $ran
		  | ((if any($ran[]; .end | not) then [$ran[] | select(.end | not)] else $ran end) | map(.dig) | unique) as $digs
		  | ($img | split("/") | last // "" | split("@")) as $ref
		  | ($ref[0] | split(":")) as $nt
		  | ("sail-operator"
		    + (if $img == "" then ":unknown" elif ($nt | length) > 1 then ":" + $nt[1] elif ($ref | length) > 1 then "" else ":latest" end)) as $nm
		  | ("/" + (if ($d.status.availableReplicas // 0) > 0 then "Available" else "Unavailable" end)) as $st
		  | if ($ref | length) > 1 then $nm + "@" + $ref[1] + $st
		    elif ($digs | length) > 0 then [$digs[] | $nm + "@" + . + $st] | join("+")
		    else $nm + "@unknown" + $st end
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
			ienv="$(_platform_env_digest "${w}/pods.json" "$w")"
			if [[ "$ienv" == unknown ]]; then
				echo "the reply did not parse, or no sha256 tool (sha256sum, shasum) ran" >"${w}/pods.json.err"
				_platform_warn "$ctx" "istiod's settings (its discovery container env)" "${w}/pods.json.err"
			fi
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
		"$(_platform_sanitize "$proxy")" "$(_platform_sanitize "$nodes")" "$(_platform_sanitize "$ienv")")
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ctx" "${_pl_val[@]}"
}

# _platform_unknown_row <ctx>: a record line with every value unknown.
# shellcheck disable=SC2329
_platform_unknown_row() {
	local out="$1" k
	for k in "${PLATFORM_ROW_KEYS[@]}"; do out+=$'\tunknown'; done
	printf '%s\n' "$out"
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

# _platform_row_has_unknown <row>: return 0 when one of the row's values is unknown.
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
			row="$(_platform_unknown_row "${_pl_m[i]}")"
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
	local -a _pl_names=(platform "mesh operator build" "istiod build" "gateway proxy build" "node provider"
		"istiod settings (its discovery container env)")
	IFS=$'\t' read -r -a _pl_o <<<"$1"
	IFS=$'\t' read -r -a _pl_n <<<"$2"
	out="${_pl_o[0]}"
	for ((j = 1; j <= ${#PLATFORM_ROW_KEYS[@]}; j++)); do
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
	# Checked before the dry-run returns, though the probes (dataplane 002, controlplane 002) exit
	# their dry-run before they call this: platform.bats's static test is what checks every caller.
	declare -F reach_sanitize >/dev/null || die "platform_probe needs reach_sanitize (source tests/lib/reach.sh)"
	declare -F _config_sha256 >/dev/null || die "platform_probe needs _config_sha256 (source tests/lib/config.sh)"
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
			PLATFORM_PROBE_ROWS+="$(_platform_unknown_row "$ctx")"$'\n'
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

# platform_member_value <ctx> <platform|operator|istiod|proxy|nodes|istiod_env>: one value of a
# member's record (PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ...); unknown when it was not read.
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
	istiod_env) i=6 ;;
	*) die "platform_member_value: unknown field '$2' (platform, operator, istiod, proxy, nodes or istiod_env)" ;;
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
	local -a ctxs=() _pl_f=() _pl_by=()
	split_csv "$1" ctxs
	for ctx in ${ctxs[@]+"${ctxs[@]}"}; do
		if ! row="$(_platform_row "$ctx")"; then
			echo "warning: ${ctx}: no platform record was read (platform_probe was not called for it); its values read unknown" >&2
			row="$(_platform_unknown_row "$ctx")"
		fi
		IFS=$'\t' read -r -a _pl_f <<<"$row"
		case "${_pl_f[1]}" in
		kubernetes) sk=1 ;;
		openshift) so=1 ;;
		*) su=1 ;;
		esac
		c="$(_platform_sanitize "$ctx")"
		for j in "${!PLATFORM_ROW_KEYS[@]}"; do
			_pl_by[j]="${_pl_by[j]:-}${_pl_by[j]:+,}${c}=${_pl_f[j + 1]:-unknown}"
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
	for j in "${!PLATFORM_ROW_KEYS[@]}"; do
		echo "${PLATFORM_ROW_KEYS[j]}=${_pl_by[j]:-unknown}"
	done
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
	printf '| Platform | %s (TEST_PLATFORM %s); nodes %s; operator %s; istiod %s; gateway proxy %s; istiod env %s |\n' \
		"${_pl_rec[PLATFORM]}" "${_pl_rec[TEST_PLATFORM]}" "$(platform_collapse "${_pl_rec[NODE_PROVIDER_BY_CONTEXT]}")" \
		"$(platform_collapse "${_pl_rec[MESH_OPERATOR_BY_CONTEXT]}")" "$(platform_collapse "${_pl_rec[ISTIOD_IMAGE_BY_CONTEXT]}")" \
		"$(platform_collapse "${_pl_rec[PROXY_IMAGE_BY_CONTEXT]}")" "$(platform_collapse "${_pl_rec[ISTIOD_ENV_BY_CONTEXT]}")"
}

# _platform_parts <key> <value>: the builds a value holds, one per line: without "mixed:", split
# at ";" (a merged value) and "+" (not for KUBE_VERSIONS, whose versions can hold one:
# v1.30.4+k3s1), each without the state after its last "/" ("/Available", "/Succeeded", ...: a
# value that differs only in it is the same build); "?" for a value not read (_platform_unread).
# shellcheck disable=SC2329
_platform_parts() {
	local x seps=';+'
	local -a _pl_xs=()
	[[ "$1" != KUBE_VERSIONS ]] || seps=';'
	IFS="$seps" read -r -a _pl_xs <<<"${2#mixed:}"
	for x in ${_pl_xs[@]+"${_pl_xs[@]}"}; do
		[[ -n "$x" ]] || continue
		if _platform_unread "$1" "$x"; then echo '?'; else printf '%s\n' "${x%/*}"; fi
	done
}

# _platform_part_match <part> <part>: two builds (_platform_parts): return 0 when they are the
# same, 1 when it cannot tell (a digest @unknown, or one without a digest: its pod had not
# started), 2 when they differ. An image (a value with "@") compares by name, then by tag when
# both have one, then by digest when both have one; any other value as it is.
# shellcheck disable=SC2329
_platform_part_match() {
	local p="$1" q="$2" pn qn pt="" qt="" pd="" qd=""
	[[ "$p" != "$q" || "$p" == *@unknown ]] || return 0
	[[ "$p" == *@* || "$q" == *@* ]] || return 2
	pn="${p%%@*}"
	qn="${q%%@*}"
	[[ "${pn%%:*}" == "${qn%%:*}" ]] || return 2
	[[ "$pn" != *:* ]] || pt="${pn#*:}"
	[[ "$qn" != *:* ]] || qt="${qn#*:}"
	if [[ -n "$pt" && "$pt" != unknown && -n "$qt" && "$qt" != unknown && "$pt" != "$qt" ]]; then return 2; fi
	[[ "$p" != *@* ]] || pd="${p#*@}"
	[[ "$q" != *@* ]] || qd="${q#*@}"
	if [[ -n "$pd" && "$pd" != unknown && -n "$qd" && "$qd" != unknown ]]; then
		[[ "$pd" != "$qd" ]] || return 0
		return 2
	fi
	return 1
}

# _platform_build_cmp <key> <value> <value>: same, differs or unknown for two values of one key
# (a member's, or merged ones). Every build of each side needs the same build on the other
# (_platform_part_match): one without any differs; else one that only may match, or a value
# not read on a side, makes it unknown. A side with nothing read is unknown.
# shellcheck disable=SC2329
_platform_build_cmp() {
	local key="$1" x y m best res=same
	local -a _pl_xa=() _pl_xb=() _pl_ka=() _pl_kb=()
	mapfile -t _pl_xa < <(_platform_parts "$key" "$2")
	mapfile -t _pl_xb < <(_platform_parts "$key" "$3")
	for x in ${_pl_xa[@]+"${_pl_xa[@]}"}; do
		if [[ "$x" == '?' ]]; then res=unknown; else _pl_ka+=("$x"); fi
	done
	for x in ${_pl_xb[@]+"${_pl_xb[@]}"}; do
		if [[ "$x" == '?' ]]; then res=unknown; else _pl_kb+=("$x"); fi
	done
	if ((${#_pl_ka[@]} == 0 || ${#_pl_kb[@]} == 0)); then
		echo unknown
		return 0
	fi
	for x in "${_pl_ka[@]}"; do
		best=2
		for y in "${_pl_kb[@]}"; do
			_platform_part_match "$x" "$y" && m=0 || m=$?
			((m >= best)) || best=$m
		done
		if ((best == 2)); then echo differs; return 0; fi
		((best == 0)) || res=unknown
	done
	for y in "${_pl_kb[@]}"; do
		best=2
		for x in "${_pl_ka[@]}"; do
			_platform_part_match "$y" "$x" && m=0 || m=$?
			((m >= best)) || best=$m
		done
		if ((best == 2)); then echo differs; return 0; fi
		((best == 0)) || res=unknown
	done
	echo "$res"
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
	ISTIOD_ENV_BY_CONTEXT) echo "istiod settings (its discovery container env)" ;;
	KUBE_VERSIONS) echo "Kubernetes versions" ;;
	TUNING_BASELINE) echo "tuning levers" ;;
	SIDECAR_EGRESS_HOSTS) echo "root Sidecar egress hosts" ;;
	TEST_PLATFORM) echo "TEST_PLATFORM overrides (the suite charts' overlay)" ;;
	*) echo values ;;
	esac
}

# _platform_drift_cause <key>: the usual cause of a value that changed during a sweep, and what
# to do for figures that can be published.
# shellcheck disable=SC2329
_platform_drift_cause() {
	case "$1" in
	MESH_OPERATOR_BY_CONTEXT) echo "the usual cause is an operator upgrade during the sweep (an Argo CD sync of a new chart revision, or a new OLM CSV); for publishable figures, run the sweep again on one build" ;;
	ISTIOD_IMAGE_BY_CONTEXT | PROXY_IMAGE_BY_CONTEXT) echo "the usual cause is an Argo CD sync of a new revision or an operator upgrade during the sweep; for publishable figures, run the sweep again on one build" ;;
	ISTIOD_ENV_BY_CONTEXT) echo "the usual cause is a tuning profile left applied, or a sync or hand edit of the Istio CR's spec.values.pilot.env, during the sweep; for publishable figures, run the sweep again with istiod's settings fixed" ;;
	KUBE_VERSIONS) echo "the usual cause is a managed control-plane upgrade during the sweep; for publishable figures, run the sweep again on one Kubernetes version" ;;
	TUNING_BASELINE | SIDECAR_EGRESS_HOSTS) echo "the usual cause is a GitOps sync or self-heal that put a lever back, a tuning profile left applied, or a hand edit, during the sweep; for publishable figures, run the sweep again with the levers fixed" ;;
	*) echo "the usual cause is a context that now points at a rebuilt or another cluster; for publishable figures, run the sweep again on fixed members" ;;
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

# _platform_drift_values <key> <tsv>...: "<dir>\t<ctx>=<value>" per pair platform_drift_check
# wrote for <key> into the PLATFORM_DRIFT_FILE next to the inputs (each dir read once), one per
# line; <dir> is that directory's name (sweep-<RUN_ID>), never its path.
# shellcheck disable=SC2329
_platform_drift_values() {
	local key="$1" f d line pair name
	local -a _pl_p=()
	local -A _pl_dirs=()
	shift
	for f in "$@"; do
		d="$(dirname "$f")"
		[[ -z "${_pl_dirs[$d]+x}" ]] || continue
		_pl_dirs[$d]=1
		[[ -f "${d}/${PLATFORM_DRIFT_FILE}" ]] || continue
		name="$(cd "$d" 2>/dev/null && basename "$PWD")" || name="$(basename "$d")"
		while IFS= read -r line; do
			IFS=',' read -r -a _pl_p <<<"${line#*=}"
			for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$pair" != *=* ]] || printf '%s\t%s\n' "$name" "$pair"
			done
		done < <(grep "^# ${key}=" "${d}/${PLATFORM_DRIFT_FILE}" 2>/dev/null || true)
	done
}

# platform_merge_by_context <key> <tsv>...: one *_BY_CONTEXT key (or KUBE_VERSIONS) over a
# report's inputs, member by member (PL26). The values a member has in the inputs (and in the
# drift marker next to them) -> that value when they are one build (values that differ only in
# their state ";"-joined); else <ctx>=mixed:<a>;<b> with a warning that says which: two builds
# (_platform_build_cmp), a value not read (unknown, or a digest @unknown: no pod had started)
# next to a known one, or a value platform_drift_check found changed during the sweep. unknown
# when no input has the key; mixed:unknown,<members> when only some have it (the legacy warning
# of platform_report_values names those that predate the record; a warning here counts those
# that have the record but predate the key, such as ISTIOD_ENV_BY_CONTEXT). With
# _pl_drift_only=1 (dynamic scope: from platform_report_warnings, for a key the report does not
# merge) only the drift warning.
# shellcheck disable=SC2329
platform_merge_by_context() {
	local key="$1" f line pair c x v out="" n=0 missing=0 noun dis="" drf="" unr="" d i j unread partial differ atu=0 nokey=0
	local -a order=() pairs=() _pl_dis=() _pl_drf=() _pl_unr=() _pl_kn=() _pl_dd=()
	local -A _pl_vals=() _pl_drift=() _pl_unread_in=() _pl_ddir=()
	shift
	for f in "$@"; do
		n=$((n + 1))
		line="$(grep -m1 "^# ${key}=" "$f" 2>/dev/null || true)"
		line="${line#*=}"
		if [[ "$line" != *=* ]]; then
			missing=$((missing + 1))
			# It has the record but not this key (written before the key was added).
			! grep -q '^# PLATFORM_BY_CONTEXT=' "$f" 2>/dev/null || nokey=$((nokey + 1))
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
			if _platform_unread "$key" "$x" || [[ "$x" == *@unknown* ]]; then
				v="${_pl_unread_in[$c]:-0}"
				_pl_unread_in[$c]=$((v + 1))
			fi
		done
	done
	if ((n == 0 || missing == n)); then
		echo unknown
		return 0
	fi
	while IFS=$'\t' read -r d pair; do
		[[ -n "$pair" ]] || continue
		c="${pair%%=*}"
		x="${pair#*=}"
		[[ -n "${_pl_vals[$c]+set}" ]] || continue
		_pl_drift[$c]=1
		[[ -n "${_pl_ddir[$d]+x}" ]] || { _pl_ddir[$d]=1; _pl_dd+=("$d"); }
		case ";${_pl_vals[$c]};" in *";${x};"*) ;; *) _pl_vals[$c]+=";${x}" ;; esac
	done < <(_platform_drift_values "$key" "$@")
	for c in "${order[@]}"; do
		unread=0 partial=0 differ=0
		_pl_kn=()
		IFS=';' read -r -a pairs <<<"${_pl_vals[$c]}"
		for x in "${pairs[@]}"; do
			if _platform_unread "$key" "$x"; then unread=1; else _pl_kn+=("$x"); fi
			[[ "$x" != *@unknown* ]] || atu=1
		done
		for ((i = 0; i < ${#_pl_kn[@]}; i++)); do
			for ((j = i + 1; j < ${#_pl_kn[@]}; j++)); do
				case "$(_platform_build_cmp "$key" "${_pl_kn[i]}" "${_pl_kn[j]}")" in
				differs) differ=1 ;;
				unknown) partial=1 ;;
				esac
			done
		done
		if ((${#_pl_kn[@]} == 0)) || { ((differ + partial + unread == 0)) && [[ -z "${_pl_drift[$c]+x}" ]]; }; then
			out+="${out:+,}${c}=${_pl_vals[$c]}"
			continue
		fi
		out+="${out:+,}${c}=mixed:${_pl_vals[$c]}"
		if [[ -n "${_pl_drift[$c]+x}" ]]; then
			_pl_drf+=("$c")
		elif ((differ)); then
			_pl_dis+=("${c} ($(platform_short_digests "${_pl_vals[$c]}"))")
		fi
		if ((unread || partial)); then
			v="${_pl_unread_in[$c]:-0}"
			if ((v)); then _pl_unr+=("${c} in ${v} of ${n}"); else _pl_unr+=("${c} (a value recorded without its digest)"); fi
		fi
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
	if [[ -n "$drf" ]]; then
		echo "warning: ${key} changed during the sweep for ${drf} (${PLATFORM_DRIFT_FILE} in $(_platform_names "${_pl_dd[@]}")): the TSVs record the value at the sweep's start, but rows measured after the change ran on other ${noun}, and the report cannot tell which rows those are; $(_platform_drift_cause "$key")" >&2
	fi
	((missing == 0)) || out="mixed:unknown,${out}"
	if ((${_pl_drift_only:-0})); then
		printf '%s\n' "$out"
		return 0
	fi
	if [[ -n "$dis" ]]; then
		echo "warning: input TSVs disagree on ${key} for ${dis}: the report mixes runs on different ${noun}; compare like with like" >&2
	fi
	if [[ -n "$unr" ]]; then
		echo "warning: ${key} could not be read for ${unr} input TSV(s) (recorded unknown$([[ "$key" != KUBE_VERSIONS ]] || echo " or unreachable")$( ((atu == 0)) || echo ", or with a digest @unknown: no pod had started")), while other inputs have a value: the report cannot tell whether those runs had the same ${noun} as the others" >&2
	fi
	if ((nokey)); then
		echo "warning: ${key} is not recorded in ${nokey} of ${n} input TSV(s) (written before the platform record had the key), while other inputs have it: the report cannot tell whether those runs had the same ${noun} as the others" >&2
	fi
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
# record, go to stderr; platform_report_warnings gives the same ones (and the drift marker's
# KUBE_VERSIONS and tuning lines) for the report's body.
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
# have it (all of them before it: every value reads unknown, nothing is mixed). Also the drift
# marker's other values (platform_drift_check): KUBE_VERSIONS when it is not a --with key, and
# TUNING_BASELINE and SIDECAR_EGRESS_HOSTS, each only when the inputs record it. --no-members
# counts the members instead of naming them, for text that goes where context names may not
# (the scale envelope, pasted into campaign docs).
# shellcheck disable=SC2329
platform_report_warnings() {
	local k
	# shellcheck disable=SC2034  # read by platform_merge_by_context (dynamic scope)
	local _pl_no_members=0 _pl_drift_only=0
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
		if [[ " ${_pl_with[*]:-} " != *" KUBE_VERSIONS "* ]]; then
			_pl_drift_only=1
			platform_merge_by_context KUBE_VERSIONS "$@" >/dev/null
			_pl_drift_only=0
		fi
		_platform_drift_scalar_warnings "$@"
	} 2>&1 | sed 's/^warning: //'
}

# _platform_drift_scalar_warnings <tsv>...: a warning per TUNING_BASELINE or SIDECAR_EGRESS_HOSTS
# line of the PLATFORM_DRIFT_FILE next to the inputs, for a key one of them records: its value
# at the sweep's end (each drift check's, " then "-joined), against what that input recorded at
# its start.
# shellcheck disable=SC2329
_platform_drift_scalar_warnings() {
	local f d key start end name
	local -a _pl_sd=()
	local -A _pl_sf=() _pl_start=()
	for f in "$@"; do
		d="$(dirname "$f")"
		[[ -n "${_pl_sf[$d]+x}" ]] || { _pl_sf[$d]=1; _pl_sd+=("$d"); }
		for key in TUNING_BASELINE SIDECAR_EGRESS_HOSTS; do
			[[ -z "${_pl_start["${key}|${d}"]+x}" ]] || continue
			start="$(_platform_preamble_value "$f" "$key")" || continue
			_pl_start["${key}|${d}"]="$start"
		done
	done
	for d in ${_pl_sd[@]+"${_pl_sd[@]}"}; do
		[[ -f "${d}/${PLATFORM_DRIFT_FILE}" ]] || continue
		name="$(cd "$d" 2>/dev/null && basename "$PWD")" || name="$(basename "$d")"
		for key in TUNING_BASELINE SIDECAR_EGRESS_HOSTS; do
			[[ -n "${_pl_start["${key}|${d}"]+x}" ]] || continue
			end="$(sed -n "s/^# ${key}=//p" "${d}/${PLATFORM_DRIFT_FILE}" | awk 'NR > 1 { printf " then " } { printf "%s", $0 }')"
			[[ -n "$end" ]] || continue
			echo "warning: ${key} changed during the sweep in ${name} (${PLATFORM_DRIFT_FILE}): ${_pl_start["${key}|${d}"]} at its start, ${end} at its end; rows measured after the change ran with other $(_platform_noun "$key"), and the report cannot tell which rows those are; $(_platform_drift_cause "$key")" >&2
		done
	done
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
# a report with cross-cluster (remote) figures when a member's nodes are kind's, or when a
# member's node provider was not read (they may be), else nothing. On kind the east-west
# gateway's LoadBalancer is cloud-provider-kind's userspace Envoy (ipMode: Proxy) on the host
# every kind cluster shares, not a cloud load balancer. k3d (k3s://) and minikube clusters that
# share one host are not detected.
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

# platform_unread_members <by_context value>: how many members' value was not read (unknown),
# in every input or in some (mixed:a;unknown); a token without a member (mixed:unknown: inputs
# from before the record) counts none.
# shellcheck disable=SC2329
platform_unread_members() {
	local pair x n=0
	local -a _pl_p=() _pl_x=()
	IFS=',' read -r -a _pl_p <<<"$1"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		[[ "$pair" == *=* ]] || continue
		IFS=';' read -r -a _pl_x <<<"${pair#*=}"
		for x in ${_pl_x[@]+"${_pl_x[@]}"}; do
			if [[ "${x#mixed:}" == unknown ]]; then
				n=$((n + 1))
				break
			fi
		done
	done
	echo "$n"
}

# platform_short_digests <text>: every sha256:<64 hex> shortened to its first 12 hex digits,
# for a table or a summary (the record and the TSVs keep the full digest).
# shellcheck disable=SC2329
platform_short_digests() {
	printf '%s\n' "$1" | sed -E 's/(sha256:[0-9a-f]{12})[0-9a-f]{52}/\1/g'
}

# platform_summary <by_context value>: the value without member names (the scale envelope is
# pasted into campaign docs): the one value every member shares, else each distinct value with
# its member count, ", "-separated ("pilot:1.30.5 (2 members), pilot:1.30.6 (1 member)"); a
# member whose inputs disagree reads "mixed: <a> and <b>"; digests shortened. A token without
# a member (mixed:unknown: some inputs predate the record) comes first.
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
		if [[ "$v" == mixed:* ]]; then
			v="${v#mixed:}"
			v="mixed: ${v//;/ and }"
		fi
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
			out+="${out:+, }${v} (${i} member$( ((i == 1)) || echo s))"
		done
	fi
	platform_short_digests "${out:-unknown}"
}

# _platform_compare_key <key> <ref value> <value>: same, differs or unknown for one record key
# of two platform_report_values outputs (_platform_build_cmp). Member by member for
# *_BY_CONTEXT: a member whose builds differ makes it differs; else a member not read on a side
# (unknown, or a digest @unknown), or on one side only, makes it unknown. A state-only
# difference is the same build.
# shellcheck disable=SC2329
_platform_compare_key() {
	local key="$1" pair c res=same r
	local -a _pl_p=() _pl_all=()
	local -A _pl_r=() _pl_v=() _pl_in=()
	if [[ "$key" != *_BY_CONTEXT ]]; then
		_platform_build_cmp "$key" "${2//,/;}" "${3//,/;}"
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
		r="$(_platform_build_cmp "$key" "${_pl_r[$c]}" "${_pl_v[$c]}")"
		if [[ "$r" == differs ]]; then
			echo differs
			return 0
		fi
		[[ "$r" == same ]] || res=unknown
	done
	echo "$res"
}

# platform_compare_values <ref values> <values> [<key>...]: "KEY\tsame|differs|unknown" per record
# key (PLATFORM_KEYS order), or per <key>, of two platform_report_values outputs, such as a
# tuning pass against the reference pass (_platform_compare_key; tuning 004 passes
# PLATFORM_PASS_KEYS).
# shellcheck disable=SC2329
platform_compare_values() {
	local k a b
	local -a _pl_k=("${@:3}")
	((${#_pl_k[@]})) || _pl_k=("${PLATFORM_KEYS[@]}")
	for k in "${_pl_k[@]}"; do
		a="$(sed -n "s/^${k}=//p" <<<"$1" | head -n 1)"
		b="$(sed -n "s/^${k}=//p" <<<"$2" | head -n 1)"
		printf '%s\t%s\n' "$k" "$(_platform_compare_key "$k" "${a:-unknown}" "${b:-unknown}")"
	done
}

# _platform_rows_of <ctxs_csv>: these members' lines of PLATFORM_PROBE_ROWS, in order, each
# member's name as the TSVs record it (_platform_sanitize); a member without a line gets one of
# unknowns.
# shellcheck disable=SC2329
_platform_rows_of() {
	local ctx row
	local -a _pl_c=()
	split_csv "$1" _pl_c
	for ctx in ${_pl_c[@]+"${_pl_c[@]}"}; do
		row="$(_platform_row "$ctx")" || row="$(_platform_unknown_row "$ctx")"
		printf '%s\t%s\n' "$(_platform_sanitize "$ctx")" "${row#*$'\t'}"
	done
}

# _platform_file_rows <tsv>: the record a TSV's preamble holds (the `# ` lines before its
# header), as PLATFORM_PROBE_ROWS lines; a member a key does not list reads unknown there (so
# does a key the TSV predates). Nothing for a file without PLATFORM_BY_CONTEXT (it predates the
# record).
# shellcheck disable=SC2329
_platform_file_rows() {
	local line k pair c j row
	local -a _pl_order=() _pl_p=()
	local -A _pl_fv=() _pl_seen=() _pl_in=()
	while IFS= read -r line; do
		[[ "$line" == '#'* ]] || break
		line="${line#\#}"
		line="${line# }"
		k="${line%%=*}"
		for j in "${!PLATFORM_ROW_KEYS[@]}"; do
			[[ "$k" == "${PLATFORM_ROW_KEYS[j]}" && -z "${_pl_seen[$k]+x}" ]] || continue
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
		for j in "${!PLATFORM_ROW_KEYS[@]}"; do row+=$'\t'"${_pl_fv["${j}|${c}"]:-unknown}"; done
		printf '%s\n' "$row"
	done
}

# _platform_diff <old rows> <new rows> <ctxs_csv>: two records compared member by member, by the
# names the TSVs record (_platform_sanitize; the members of <ctxs_csv>, then those only <old
# rows> has): "<kind>\t<ctx>\t<key>\t<old>\t<new>" per finding (_platform_build_cmp). differs:
# another build (a state-only difference is none); unknown: a value not read on a side, or one
# that can be compared only in part (a digest @unknown); missing: a member one side does not
# have (key "-", the side without it "-").
# shellcheck disable=SC2329
_platform_diff() {
	local c o n j ov nv line res
	local -a _pl_c=() _pl_all=() _pl_o=() _pl_n=()
	local -A _pl_in=() _pl_or=() _pl_nr=()
	split_csv "$3" _pl_c
	for c in ${_pl_c[@]+"${_pl_c[@]}"}; do
		c="$(_platform_sanitize "$c")"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		c="$(_platform_sanitize "${line%%$'\t'*}")"
		[[ -n "${_pl_or[$c]+x}" ]] || _pl_or[$c]="$line"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done <<<"$1"
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		c="$(_platform_sanitize "${line%%$'\t'*}")"
		[[ -n "${_pl_nr[$c]+x}" ]] || _pl_nr[$c]="$line"
	done <<<"$2"
	for c in ${_pl_all[@]+"${_pl_all[@]}"}; do
		o="${_pl_or[$c]:-}"
		n="${_pl_nr[$c]:-}"
		if [[ -z "$o" || -z "$n" ]]; then
			ov=- nv=-
			[[ -z "$o" ]] || ov=recorded
			[[ -z "$n" ]] || nv='read'
			printf 'missing\t%s\t-\t%s\t%s\n' "$c" "$ov" "$nv"
			continue
		fi
		IFS=$'\t' read -r -a _pl_o <<<"$o"
		IFS=$'\t' read -r -a _pl_n <<<"$n"
		for j in "${!PLATFORM_ROW_KEYS[@]}"; do
			ov="${_pl_o[j + 1]:-unknown}"
			nv="${_pl_n[j + 1]:-unknown}"
			res="$(_platform_build_cmp "${PLATFORM_ROW_KEYS[j]}" "$ov" "$nv")"
			[[ "$res" == same ]] || printf '%s\t%s\t%s\t%s\t%s\n' "$res" "$c" "${PLATFORM_ROW_KEYS[j]}" "$ov" "$nv"
		done
	done
}

# _platform_preamble_value <tsv> <key>: the first `# <key>=` value of a TSV's preamble; return 1
# when it has none.
# shellcheck disable=SC2329
_platform_preamble_value() {
	awk -v k="# ${2}=" '!/^#/ { exit 1 } index($0, k) == 1 { print substr($0, length(k) + 1); found = 1; exit } END { exit !found }' "$1"
}

# _platform_unread_why <tsv> <key> <recorded> <now> [<hint>]: for a resume's warning, which side
# of one comparison was not read: not in the record (the TSV predates the key: <recorded> empty),
# unknown in it, recorded with a digest @unknown, not read now (<hint> says why), read now with a
# digest @unknown; else comparable only in part (a value recorded without its digest).
# shellcheck disable=SC2329
_platform_unread_why() {
	local tsv="$1" key="$2" o="$3" n="$4" hint="${5:-}" why=""
	if [[ -z "$o" ]]; then
		why="not in the record of ${tsv} (it predates the key)"
	elif _platform_unread "$key" "$o"; then
		why="${o} in the record of ${tsv} (not read at the sweep's start)"
	elif [[ "$o" == *@unknown* ]]; then
		why="recorded with a digest @unknown in ${tsv} (no pod had started)"
	fi
	if [[ -z "$n" ]] || _platform_unread "$key" "$n"; then
		why+="${why:+, and }could not be read now${hint}"
	elif [[ "$n" == *@unknown* ]]; then
		why+="${why:+, and }read with a digest @unknown now (no pod has started)"
	fi
	[[ -n "$why" ]] || why="comparable only in part (recorded $(platform_short_digests "$o"), now $(platform_short_digests "$n"))"
	printf '%s\n' "$why"
}

# _platform_kv <tokens> <key>: the value of <key>=... among space-separated tokens (cap_* and
# env_collect_infra output); unknown without one.
# shellcheck disable=SC2329
_platform_kv() {
	local t
	for t in $1; do
		if [[ "$t" == "${2}="* ]]; then
			printf '%s\n' "${t#*=}"
			return 0
		fi
	done
	echo unknown
}

# platform_resume_check <tsv> <ctxs_csv> [<source_ctx>]: before --resume appends rows to <tsv>,
# whose preamble keeps what the sweep recorded at its start, compare that with what these members
# have now: each member's record (PLATFORM_ROW_KEYS; platform_probe just read it). With
# <source_ctx> (the run's first context; controlplane 003) also the values the report applies to
# every row: each member's KUBE_VERSIONS (probe_kube_versions) and, on the member the TSV read
# them on (its record's first member when it is in this run, else <source_ctx>, with a warning),
# TUNING_BASELINE and SIDECAR_EGRESS_HOSTS (tuning_baseline_state) and ISTIOD_CPU_LIMIT_M and
# ISTIOD_MEM_LIMIT_MI (cap_istiod_limits: the denominators of the report's istiod limit figures).
# A definite difference in any of them dies: the new rows would be credited to builds, settings
# or limits that did not produce them. Only warns: a value not read on either side (the warning
# says which side), a member on one side only, a TSV from before the record or a key, another
# TEST_PLATFORM, and the values the report only shows: NODE_ALLOC_CPU_M and NODE_ALLOC_MEM_MI
# (cap_node_totals; a cluster autoscaler moves them), ISTIOD_REQ_*, ISTIOD_LIM_*,
# ISTIOD_REPLICAS_BY_CONTEXT (an HPA moves it; ISTIOD_REPLICAS is its summary) and
# NETWORK_TOPOLOGY (env_collect_infra). METRICS_API is not compared: the resumed run's own
# preflight checks the metrics API. One line on stdout says the comparison ran. Nothing in a
# dry-run, or when <tsv> has no header yet (it is written anew).
# shellcheck disable=SC2329
platform_resume_check() {
	local tsv="$1" _pl_ctxs="$2" tctx="${3:-}" old new kind c key o n dies="" line tb_old eh_old tb_new="" eh_new="" lv
	local again tp_old snap src unr="" g keys kv_old kv_new lim nt infra note csv _pl_tn _pl_gall=""
	local -a _pl_lv=() _pl_lo=() _pl_rc=() _pl_gk=() _pl_p=()
	local -A _pl_ov=() _pl_nv=() _pl_raw=() _pl_gkeys=() _pl_rko=() _pl_rkn=()
	if [[ -n "$tctx" ]]; then
		declare -F tuning_baseline_state >/dev/null ||
			die "platform_resume_check needs tuning_baseline_state (source tests/lib/preamble.sh)"
		declare -F probe_kube_versions >/dev/null ||
			die "platform_resume_check needs probe_kube_versions (source tests/lib/preamble.sh)"
		declare -F cap_istiod_limits >/dev/null ||
			die "platform_resume_check needs cap_istiod_limits (source tests/lib/capacity.sh)"
		declare -F cap_node_totals >/dev/null ||
			die "platform_resume_check needs cap_node_totals (source tests/lib/capacity.sh)"
		declare -F env_collect_infra >/dev/null ||
			die "platform_resume_check needs env_collect_infra (source tests/lib/envelope.sh)"
	fi
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
	# The run's members by the names the TSV records (_platform_sanitize).
	split_csv "$_pl_ctxs" _pl_rc
	for c in ${_pl_rc[@]+"${_pl_rc[@]}"}; do
		g="$(_platform_sanitize "$c")"
		[[ -n "${_pl_raw[$g]+x}" ]] || _pl_raw[$g]="$c"
	done
	# The TSV read its once-recorded values on its first member (the sweep's first context then):
	# read them there again when that member is in this run, whatever order --contexts lists now.
	if [[ -n "$tctx" && -n "$old" ]]; then
		src="${old%%$'\t'*}"
		if [[ -n "${_pl_raw[$src]+x}" ]]; then
			[[ "${_pl_raw[$src]}" == "$tctx" ]] ||
				echo "--resume: reading TUNING_BASELINE and istiod's limits on ${_pl_raw[$src]}, the member ${tsv} read them on (this run lists ${tctx} first)" >&2
			tctx="${_pl_raw[$src]}"
		else
			echo "warning: --resume: ${tsv} read TUNING_BASELINE and istiod's limits on ${src}, which is not a member of this run; comparing them with ${tctx}'s" >&2
		fi
	fi
	echo "Platform record: comparing what ${_pl_ctxs//,/ } run now with what ${tsv} recorded at the sweep's start (--resume)"
	if [[ -z "$old" ]]; then
		echo "warning: --resume: ${tsv} predates the platform record (no PLATFORM_BY_CONTEXT line), so this run cannot tell whether the members still run the builds its rows were measured on; its report reads them unknown" >&2
	else
		while IFS=$'\t' read -r kind c key o n; do
			case "$kind" in
			differs) dies+=$'\n'"  ${c}: ${key} recorded ${o}, now ${n}" ;;
			unknown)
				[[ "$o" != unknown ]] || _platform_preamble_value "$tsv" "$key" >/dev/null || o=""
				unr+="${c}"$'\t'"$(_platform_unread_why "$tsv" "$key" "$o" "$n" " (the warnings above say why)")"$'\t'"${key}"$'\n'
				;;
			missing)
				if [[ "$o" == - ]]; then
					echo "warning: --resume: ${c} is a member of this run but not of the record in ${tsv}: the preamble is not rewritten on --resume, so its builds are never recorded and the report does not list it; start a new sweep to record it" >&2
				else
					echo "warning: --resume: ${c} is in the record of ${tsv} but not a member of this run" >&2
				fi
				;;
			esac
		done < <(_platform_diff "$old" "$new" "$_pl_ctxs")
	fi
	tp_old="$(_platform_preamble_value "$tsv" TEST_PLATFORM)" || tp_old=""
	if [[ -n "$tp_old" && "$tp_old" != "${TEST_PLATFORM:-auto}" ]]; then
		echo "warning: --resume: ${tsv} was started with TEST_PLATFORM=${tp_old}, this run has TEST_PLATFORM=${TEST_PLATFORM:-auto}: its suite charts may get another overlay than the recorded rows had" >&2
	fi
	if [[ -n "$tctx" ]]; then
		# Its warnings name members as the TSV records them (_platform_sanitize).
		_pl_tn="$(_platform_sanitize "$tctx")"
		for c in ${_pl_rc[@]+"${_pl_rc[@]}"}; do _pl_gall+="${_pl_gall:+ }$(_platform_sanitize "$c")"; done
		# Kubernetes versions, member by member (probe_kube_versions names them as given).
		kv_old="$(_platform_preamble_value "$tsv" KUBE_VERSIONS)" || kv_old=""
		kv_new="$(probe_kube_versions "$_pl_ctxs" "${KUBECTL[@]}")"
		IFS=',' read -r -a _pl_p <<<"$kv_old"
		for line in ${_pl_p[@]+"${_pl_p[@]}"}; do [[ "$line" != *=* ]] || _pl_rko[${line%%=*}]="${line#*=}"; done
		IFS=',' read -r -a _pl_p <<<"$kv_new"
		for line in ${_pl_p[@]+"${_pl_p[@]}"}; do [[ "$line" != *=* ]] || _pl_rkn[${line%%=*}]="${line#*=}"; done
		for c in ${_pl_rc[@]+"${_pl_rc[@]}"}; do
			if [[ -z "$kv_old" ]]; then
				unr+="$(_platform_sanitize "$c")"$'\t'"$(_platform_unread_why "$tsv" KUBE_VERSIONS "" "${_pl_rkn[$c]:-unknown}")"$'\t'KUBE_VERSIONS$'\n'
				continue
			fi
			# A member the sweep did not have at its start: the record's warning names it.
			[[ -n "${_pl_rko[$c]+x}" ]] || continue
			o="${_pl_rko[$c]}"
			n="${_pl_rkn[$c]:-unknown}"
			case "$(_platform_build_cmp KUBE_VERSIONS "$o" "$n")" in
			differs) dies+=$'\n'"  $(_platform_sanitize "$c"): KUBE_VERSIONS recorded ${o}, now ${n}" ;;
			unknown) unr+="$(_platform_sanitize "$c")"$'\t'"$(_platform_unread_why "$tsv" KUBE_VERSIONS "$o" "$n" " (${n})")"$'\t'KUBE_VERSIONS$'\n' ;;
			esac
		done
		# The tuning levers and the root Sidecar's egress hosts.
		tb_old="$(_platform_preamble_value "$tsv" TUNING_BASELINE)" || tb_old=""
		eh_old="$(_platform_preamble_value "$tsv" SIDECAR_EGRESS_HOSTS)" || eh_old=""
		while IFS= read -r line; do
			case "$line" in
			TUNING_BASELINE=*) tb_new="${line#*=}" ;;
			SIDECAR_EGRESS_HOSTS=*) eh_new="${line#*=}" ;;
			esac
		done < <(tuning_baseline_state "$tctx" "${KUBECTL[@]}")
		if [[ "$tb_old" != *=* || "$tb_new" != *=* ]]; then
			unr+="${_pl_tn}"$'\t'"$(_platform_unread_why "$tsv" TUNING_BASELINE "$tb_old" "${tb_new:-unknown}")"$'\t'TUNING_BASELINE$'\n'
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
					unr+="${_pl_tn}"$'\t'"$(_platform_unread_why "$tsv" "TUNING_BASELINE ${lv}" "$o" "$n")"$'\t'"TUNING_BASELINE ${lv}"$'\n'
				elif [[ "$o" != "$n" ]]; then
					dies+=$'\n'"  ${_pl_tn}: TUNING_BASELINE ${lv} recorded ${o}, now ${n}"
				fi
			done
		fi
		if [[ -n "$eh_old" && "$eh_old" != unknown && -n "$eh_new" && "$eh_new" != unknown ]]; then
			[[ "$eh_old" == "$eh_new" ]] || dies+=$'\n'"  ${_pl_tn}: SIDECAR_EGRESS_HOSTS recorded ${eh_old}, now ${eh_new}"
		else
			unr+="${_pl_tn}"$'\t'"$(_platform_unread_why "$tsv" SIDECAR_EGRESS_HOSTS "$eh_old" "${eh_new:-unknown}")"$'\t'SIDECAR_EGRESS_HOSTS$'\n'
		fi
		# istiod's limits (per replica): the denominators of the report's istiod limit figures.
		lim="$(cap_istiod_limits "$tctx" "${KUBECTL[@]}")"
		for key in ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
			o="$(_platform_preamble_value "$tsv" "$key")" || o=""
			if [[ "$key" == ISTIOD_CPU_LIMIT_M ]]; then n="$(_platform_kv "$lim" cpu_m)"; else n="$(_platform_kv "$lim" mem_mi)"; fi
			if [[ -z "$o" || "$o" == unknown || "$n" == unknown ]]; then
				unr+="${_pl_tn}"$'\t'"$(_platform_unread_why "$tsv" "$key" "$o" "$n")"$'\t'"${key}"$'\n'
			elif [[ "$o" != "$n" ]]; then
				dies+=$'\n'"  ${_pl_tn}: ${key} recorded ${o}, now ${n}"
			fi
		done
		# What the report only shows for every row: warnings, never a stop.
		nt="$(cap_node_totals "$tctx" "${KUBECTL[@]}")"
		csv="$tctx"
		for c in ${_pl_rc[@]+"${_pl_rc[@]}"}; do [[ "$c" == "$tctx" ]] || csv+=",${c}"; done
		infra="$(env_collect_infra "$csv" "${KUBECTL[@]}")"
		for key in NODE_ALLOC_CPU_M NODE_ALLOC_MEM_MI ISTIOD_REQ_CPU_M ISTIOD_REQ_MEM_MI ISTIOD_LIM_CPU_M ISTIOD_LIM_MEM_MI NETWORK_TOPOLOGY; do
			o="$(_platform_preamble_value "$tsv" "$key")" || continue
			case "$key" in
			NODE_ALLOC_CPU_M) n="$(_platform_kv "$nt" cpu_m)" note="a cluster autoscaler moves it; each row's node figures are its own reads" ;;
			NODE_ALLOC_MEM_MI) n="$(_platform_kv "$nt" mem_mi)" note="a cluster autoscaler moves it; each row's node figures are its own reads" ;;
			NETWORK_TOPOLOGY) n="$(_platform_kv "$infra" "$key")" note="the report labels every row with the recorded one" ;;
			*) n="$(_platform_kv "$infra" "$key")" note="the report shows the recorded value; its istiod limit figures use ISTIOD_CPU_LIMIT_M and ISTIOD_MEM_LIMIT_MI" ;;
			esac
			g="$_pl_tn"
			[[ "$key" != NETWORK_TOPOLOGY ]] || g="$_pl_gall"
			if [[ "$o" == unknown || "$n" == unknown ]]; then
				unr+="${g}"$'\t'"$(_platform_unread_why "$tsv" "$key" "$o" "$n")"$'\t'"${key}"$'\n'
			elif [[ "$o" != "$n" ]]; then
				echo "warning: --resume: ${g}: ${key} recorded ${o}, now ${n}; ${note}" >&2
			fi
		done
		o="$(_platform_preamble_value "$tsv" ISTIOD_REPLICAS_BY_CONTEXT)" || o=""
		if [[ -n "$o" ]]; then
			_pl_rko=() _pl_rkn=()
			IFS=',' read -r -a _pl_p <<<"$o"
			for line in ${_pl_p[@]+"${_pl_p[@]}"}; do [[ "$line" != *=* ]] || _pl_rko[${line%%=*}]="${line#*=}"; done
			IFS=',' read -r -a _pl_p <<<"$(_platform_kv "$infra" ISTIOD_REPLICAS_BY_CONTEXT)"
			for line in ${_pl_p[@]+"${_pl_p[@]}"}; do [[ "$line" != *=* ]] || _pl_rkn[${line%%=*}]="${line#*=}"; done
			for c in ${_pl_rc[@]+"${_pl_rc[@]}"}; do
				[[ -n "${_pl_rko[$c]+x}" ]] || continue
				o="${_pl_rko[$c]}"
				n="${_pl_rkn[$c]:-unknown}"
				if [[ "$o" == unknown || "$n" == unknown ]]; then
					unr+="$(_platform_sanitize "$c")"$'\t'"$(_platform_unread_why "$tsv" ISTIOD_REPLICAS_BY_CONTEXT "$o" "$n")"$'\t'ISTIOD_REPLICAS_BY_CONTEXT$'\n'
				elif [[ "$o" != "$n" ]]; then
					echo "warning: --resume: $(_platform_sanitize "$c"): ISTIOD_REPLICAS_BY_CONTEXT recorded ${o}, now ${n}; an HPA moves it, the report shows the recorded count while each row records its own istiod pods" >&2
				fi
			done
		fi
	fi
	# The values not read, one warning per member and reason.
	while IFS=$'\t' read -r c line key; do
		[[ -n "$c" ]] || continue
		g="${c}"$'\t'"${line}"
		[[ -n "${_pl_gkeys[$g]+x}" ]] || _pl_gk+=("$g")
		_pl_gkeys[$g]+="${_pl_gkeys[$g]:+, }${key}"
	done <<<"$unr"
	for g in ${_pl_gk[@]+"${_pl_gk[@]}"}; do
		keys="${_pl_gkeys[$g]}"
		echo "warning: --resume: ${g%%$'\t'*}: ${keys}: ${g#*$'\t'}, so this run cannot tell whether $([[ "$keys" == *", "* ]] && echo they || echo it) changed since its rows were measured" >&2
	done
	[[ -z "$dies" ]] || die "--resume: ${tsv} was started on other builds, settings or cluster values than the members have now:${dies}
The rows this run appends would be credited to what its preamble records. ${again}"
}

# platform_drift_check <sweep_dir> <ctxs_csv>: after a sweep's last step (outside every window;
# nothing in a dry-run), read these members' record again and compare it with the one the sweep
# started with (PLATFORM_PROBE_ROWS); when the sweep's TSVs (<sweep_dir>/*.tsv) record them, also
# each member's KUBE_VERSIONS (probe_kube_versions) and, on the first member (where the sweeps
# read them), TUNING_BASELINE and SIDECAR_EGRESS_HOSTS (tuning_baseline_state), against every
# definite value those TSVs recorded. A value that changed warns, naming the member, key, both
# values, the usual cause and what to do, and goes into <sweep_dir>/platform-drift.txt
# (PLATFORM_DRIFT_FILE: "# <KEY>=<ctx>=<value at the end>,..." lines, the levers as
# "# TUNING_BASELINE=<value at the end>"), which every report of the sweep says in its body
# (platform_report_warnings; the record's keys and KUBE_VERSIONS merge as a second value:
# mixed:). A value not read at either end warns only. It never fails the sweep (PL40: its
# reports run next): a check it cannot make is a warning.
# shellcheck disable=SC2329
platform_drift_check() {
	local dir="$1" _pl_ctxs="$2" start now kind c key o n marker found="" k fresh=0 f v lv
	local tb_start="" eh_start="" tb_end="" eh_end="" kv_end="" tb_rec=0 eh_rec=0 kv_rec=0 line
	local -a _pl_c=() _pl_uo=() _pl_do=() _pl_p=()
	local -A _pl_end=() _pl_unk=() _pl_dig=() _pl_tb=() _pl_kv=() _pl_kv_start=() _pl_kv_now=()
	! ((${DRY_RUN:-0})) || return 0
	split_csv "$_pl_ctxs" _pl_c
	((${#_pl_c[@]})) || return 0
	if ! declare -F reach_sanitize >/dev/null || ! declare -F _config_sha256 >/dev/null || [[ -z "${KUBECTL[*]:-}" ]]; then
		echo "warning: platform_drift_check needs reach_sanitize (source tests/lib/reach.sh), _config_sha256 (tests/lib/config.sh) and KUBECTL; not checked, so the reports cannot tell whether a build changed during the sweep" >&2
		return 0
	fi
	start="$(_platform_rows_of "$_pl_ctxs")"
	echo "Platform record: reading ${_pl_c[*]} again, to check that no build, istiod setting, tuning lever or Kubernetes version changed during the sweep"
	if ! now="$(_platform_read_members "${_pl_c[@]}")"; then
		echo "warning: the platform record could not be read again (no temp dir), so the reports cannot tell whether a build changed during the sweep" >&2
		return 0
	fi
	while IFS=$'\t' read -r kind c key o n; do
		case "$kind" in
		differs)
			echo "warning: ${c}: ${key} changed during the sweep: ${o} at its start, ${n} at its end; rows measured after the change ran with the new value (written to ${dir}/${PLATFORM_DRIFT_FILE}, so its reports read ${key} mixed); $(_platform_drift_cause "$key")" >&2
			_pl_end[$key]+="${_pl_end[$key]:+,}${c}=${n}"
			found=1
			;;
		unknown)
			# Read at both ends, but a digest @unknown (no pod had started) on one: its own warning.
			if ! _platform_unread "$key" "$o" && ! _platform_unread "$key" "$n" && [[ "${o}${n}" == *@unknown* ]]; then
				[[ -n "${_pl_dig[$c]+x}" ]] || _pl_do+=("$c")
				_pl_dig[$c]+="${_pl_dig[$c]:+, }${key}"
			else
				[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
				_pl_unk[$c]+="${_pl_unk[$c]:+, }${key}"
			fi
			;;
		esac
	done < <(_platform_diff "$start" "$now" "$_pl_ctxs")
	# What the sweep's TSVs recorded once, at their start: each lever's and each member's
	# definite values.
	for f in "$dir"/*.tsv; do
		[[ -f "$f" ]] || continue
		if v="$(_platform_preamble_value "$f" TUNING_BASELINE)"; then
			((tb_rec)) || tb_start="$v"
			tb_rec=1
			IFS=',' read -r -a _pl_p <<<"$v"
			for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$lv" == *=* && "${lv#*=}" != unknown ]] || continue
				k="${lv%%=*}"
				case ";${_pl_tb[$k]:-};" in *";${lv#*=};"*) ;; *) _pl_tb[$k]="${_pl_tb[$k]:-}${_pl_tb[$k]:+;}${lv#*=}" ;; esac
			done
		fi
		if v="$(_platform_preamble_value "$f" SIDECAR_EGRESS_HOSTS)"; then
			((eh_rec)) || eh_start="$v"
			eh_rec=1
			k=SIDECAR_EGRESS_HOSTS
			[[ "$v" == unknown ]] ||
				case ";${_pl_tb[$k]:-};" in *";${v};"*) ;; *) _pl_tb[$k]="${_pl_tb[$k]:-}${_pl_tb[$k]:+;}${v}" ;; esac
		fi
		if v="$(_platform_preamble_value "$f" KUBE_VERSIONS)"; then
			kv_rec=1
			IFS=',' read -r -a _pl_p <<<"$v"
			for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$lv" == *=* ]] || continue
				c="${lv%%=*}"
				[[ -n "${_pl_kv_start[$c]+x}" ]] || _pl_kv_start[$c]="${lv#*=}"
				_platform_unread KUBE_VERSIONS "${lv#*=}" ||
					case ";${_pl_kv[$c]:-};" in *";${lv#*=};"*) ;; *) _pl_kv[$c]="${_pl_kv[$c]:-}${_pl_kv[$c]:+;}${lv#*=}" ;; esac
			done
		fi
	done
	if ((tb_rec || eh_rec)); then
		if declare -F tuning_baseline_state >/dev/null; then
			while IFS= read -r line; do
				case "$line" in
				TUNING_BASELINE=*) tb_end="${line#*=}" ;;
				SIDECAR_EGRESS_HOSTS=*) eh_end="${line#*=}" ;;
				esac
			done < <(tuning_baseline_state "${_pl_c[0]}" "${KUBECTL[@]}")
		else
			echo "warning: platform_drift_check needs tuning_baseline_state (source tests/lib/preamble.sh) to read the tuning levers again; not checked, so the reports cannot tell whether they changed during the sweep" >&2
			tb_rec=0 eh_rec=0
		fi
	fi
	if ((tb_rec)); then
		c="$(_platform_sanitize "${_pl_c[0]}")"
		v=0
		IFS=',' read -r -a _pl_p <<<"$tb_end"
		for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
			[[ "$lv" == *=* ]] || continue
			if [[ "${lv#*=}" == unknown || -z "${_pl_tb[${lv%%=*}]:-}" ]]; then
				[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
				_pl_unk[$c]+="${_pl_unk[$c]:+, }TUNING_BASELINE ${lv%%=*}"
			elif [[ "${_pl_tb[${lv%%=*}]}" != "${lv#*=}" ]]; then
				v=1
			fi
		done
		if [[ "$tb_end" != *=* ]]; then
			[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
			_pl_unk[$c]+="${_pl_unk[$c]:+, }TUNING_BASELINE"
		elif ((v)); then
			echo "warning: ${c}: TUNING_BASELINE changed during the sweep: ${tb_start} at its start, ${tb_end} at its end; rows measured after the change ran with other tuning levers (written to ${dir}/${PLATFORM_DRIFT_FILE}, which its reports say in their body); $(_platform_drift_cause TUNING_BASELINE)" >&2
			_pl_end[TUNING_BASELINE]="$tb_end"
			found=1
		fi
	fi
	if ((eh_rec)); then
		c="$(_platform_sanitize "${_pl_c[0]}")"
		if [[ -z "$eh_end" || "$eh_end" == unknown || -z "${_pl_tb[SIDECAR_EGRESS_HOSTS]:-}" ]]; then
			[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
			_pl_unk[$c]+="${_pl_unk[$c]:+, }SIDECAR_EGRESS_HOSTS"
		elif [[ "${_pl_tb[SIDECAR_EGRESS_HOSTS]}" != "$eh_end" ]]; then
			echo "warning: ${c}: SIDECAR_EGRESS_HOSTS changed during the sweep: ${eh_start} at its start, ${eh_end} at its end; rows measured after the change ran with other root Sidecar egress hosts (written to ${dir}/${PLATFORM_DRIFT_FILE}, which its reports say in their body); $(_platform_drift_cause SIDECAR_EGRESS_HOSTS)" >&2
			_pl_end[SIDECAR_EGRESS_HOSTS]="$eh_end"
			found=1
		fi
	fi
	if ((kv_rec)); then
		if declare -F probe_kube_versions >/dev/null; then
			kv_end="$(probe_kube_versions "$_pl_ctxs" "${KUBECTL[@]}")"
			IFS=',' read -r -a _pl_p <<<"$kv_end"
			for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do [[ "$lv" != *=* ]] || _pl_kv_now[${lv%%=*}]="${lv#*=}"; done
			for c in "${_pl_c[@]}"; do
				[[ -n "${_pl_kv_start[$c]+x}" ]] || continue
				n="${_pl_kv_now[$c]:-unknown}"
				if _platform_unread KUBE_VERSIONS "$n" || [[ -z "${_pl_kv[$c]:-}" ]]; then
					k="$(_platform_sanitize "$c")"
					[[ -n "${_pl_unk[$k]+x}" ]] || _pl_uo+=("$k")
					_pl_unk[$k]+="${_pl_unk[$k]:+, }KUBE_VERSIONS"
				elif [[ "${_pl_kv[$c]}" != "$n" ]]; then
					echo "warning: ${c}: KUBE_VERSIONS changed during the sweep: ${_pl_kv_start[$c]} at its start, ${n} at its end; rows measured after the change ran on another Kubernetes version (written to ${dir}/${PLATFORM_DRIFT_FILE}, which its reports say in their body); $(_platform_drift_cause KUBE_VERSIONS)" >&2
					_pl_end[KUBE_VERSIONS]+="${_pl_end[KUBE_VERSIONS]:+,}${c}=${n}"
					found=1
				fi
			done
		else
			echo "warning: platform_drift_check needs probe_kube_versions (source tests/lib/preamble.sh) to read the Kubernetes versions again; not checked, so the reports cannot tell whether they changed during the sweep" >&2
		fi
	fi
	for c in ${_pl_do[@]+"${_pl_do[@]}"}; do
		echo "warning: ${c}: ${_pl_dig[$c]} read with a digest @unknown at the sweep's start or end (no pod had started), so whether $([[ "${_pl_dig[$c]}" == *", "* ]] && echo they || echo it) changed during the sweep is not known" >&2
	done
	for c in ${_pl_uo[@]+"${_pl_uo[@]}"}; do
		echo "warning: ${c}: ${_pl_unk[$c]} not read at the sweep's start or end, so whether $([[ "${_pl_unk[$c]}" == *", "* ]] && echo they || echo it) changed during the sweep is not known" >&2
	done
	[[ -n "$found" ]] || return 0
	marker="${dir}/${PLATFORM_DRIFT_FILE}"
	[[ -f "$marker" ]] || fresh=1
	if ! {
		((fresh == 0)) || echo "# Values that changed during this sweep: the value at its end, per member (tests/lib/platform.sh platform_drift_check; TUNING_BASELINE and SIDECAR_EGRESS_HOSTS on its first member; the TSVs record the value at its start)"
		echo "# DRIFT_READ_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		for k in "${PLATFORM_KEYS[@]}" KUBE_VERSIONS TUNING_BASELINE SIDECAR_EGRESS_HOSTS; do
			[[ -z "${_pl_end[$k]+x}" ]] || echo "# ${k}=${_pl_end[$k]}"
		done
	} >>"$marker"; then
		echo "warning: could not write ${marker}: the reports of this sweep will not show that a value changed during it" >&2
	fi
	return 0
}
