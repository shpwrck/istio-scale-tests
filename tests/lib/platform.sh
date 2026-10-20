#!/usr/bin/env bash
# Platform of a mesh member and the suite-chart overlay for it. Sourced, never executed.
#
# Consumers: every suite script that takes TEST_PLATFORM (platform_validate, with its argument
# checks; the setups through platform_chart_args); propagation, churn, churn-dataplane,
# controlplane, dataplane (the 001 setup scripts: the chart overlay; the TSV writers and reports:
# the platform record; the sweeps: its drift check, and controlplane 003 --resume its resume
# check), gateway-api (001: the platform record and the operator build), tuning (001: the refusal
# of a profile's objects left on a member; 003: each pass's record, its drift check and that
# refusal; 004: each pass's record, tuning levers, istiod limits and replica counts, compared
# between passes; 005: the profile label and kinds; 006: the hub's Argo CD namespace)
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
#   platform_probe_share <dir>              -> hand a sweep's record to the steps it runs
#                                              (<dir>/platform-record.txt)
#   platform_probe_reset                    -> forget the record read so far, so the next
#                                              platform_probe reads every member (tuning 003:
#                                              each pass reads its own)
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
#   platform_drift_check <sweep_dir> <ctxs_csv> [<run>]
#                                           -> after a sweep's last step (tuning 003: each pass's,
#                                              <run> pass): read the record, the tuning levers,
#                                              istiod's limits and replica counts (the
#                                              controlplane suite's) and the Kubernetes versions
#                                              again and write <sweep_dir>/platform-drift.txt for
#                                              its reports: each value that changed (it warns),
#                                              and the values it could not compare
#   platform_drift_changes <tsv>...         -> what those reads found changed, one line per key
#                                              (tuning 004 words its own warnings)
#   platform_drift_unread <tsv>...          -> what they could not compare, one line per key
#                                              with its members
#   platform_lever_values <tsv>...          -> KEY=value for the tuning levers, the root
#                                              Sidecar's egress hosts, istiod's limits and its
#                                              replicas per member over a pass's inputs (tuning
#                                              004)
#   platform_compare_values <ref> <values> [<key>...]
#                                           -> KEY<TAB>same|differs|unknown per record key (or per
#                                              <key>) of two platform_report_values outputs
#   platform_compare_members <key> <ref> <value>
#                                           -> the members of two *_BY_CONTEXT values that do
#                                              not match, one line each (a member that ran more
#                                              than one value, mixed:, matches one of them)
#   platform_value_against <key> <value> <ref>
#                                           -> a value shown against a reference one: only the
#                                              members that do not match, five at most (the
#                                              one value when none or every member differs)
#   platform_summary <by_context value>     -> the value without member names, digests shortened
#   platform_members_by_value <by_context value>
#                                           -> each value with the members that have it (five
#                                              named), digests shortened
#   platform_short_digests <text>           -> sha256 digests shortened to 12 hex digits
#   platform_report_is_key <key>            -> return 0 for a record key
#   platform_value_has <value> <word>       -> return 0 when a member's value holds <word>
#   platform_tuning_objects_check <value> [<profile> [<objects>]]
#                                           -> other|missing|unknown|own|none, with the members
#                                              and objects: a value against a tuning pass's
#                                              profile and the objects it puts on every member
#   platform_tuning_objects <ctx>           -> a member's tuning profile objects, or none
#   platform_start_warnings <ctxs_csv>      -> a sweep's warnings at its start (tuning objects)
#   platform_tuning_objects_refuse <ctxs_csv> <what>
#                                           -> die when a member holds a profile's objects
#   platform_help_lines <all|reads>         -> a --help's Environment lines for TEST_PLATFORM,
#                                              PLATFORM_READ_TIMEOUT and PLATFORM_READ_PARALLEL
#                                              (or the last two only)
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
# reads the levers and Kubernetes versions again with preamble.sh's, and istiod's limits and
# replica counts with capacity.sh's cap_istiod_limits (without one, a warning, and the values it
# reads are listed as not compared at the end).
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
#                             hand edit changes it. none without an istiod pod
#                             (_platform_env_digest)
#   TUNING_OBJECTS_BY_CONTEXT the objects a tuning profile created (tests/tuning: labelled
#                             istio-scale-tests/tuning-profile, of the kinds a profile may create,
#                             and the marker ConfigMap every applied profile gets: PLATFORM_TUNING_
#                             KINDS, in any namespace) as <profile>:<Kind>/<ns>/<name>, sorted; none
#                             when there are none (the usual state: a tuning run deletes them when
#                             it reverts its profile). A killed tuning run leaves them (its marker
#                             even for a profile that only sets istiod's env), and a root-namespace
#                             DestinationRule (profile 04) changes every proxy's clusters, which no
#                             other key shows
# Images drop the registry host and path (a mirror can name an internal host) and carry the
# sha256 the pods run (the sha256:<64 hex> in the imageID: after "@", bare as kind gives a loaded
# image, or after docker:// as cri-dockerd gives a local one). Only the pods whose container
# started (it reports a digest) count, those not terminated (an evicted pod) first; when none
# has, each pod's spec image with @unknown, or with the digest the spec pins. Every comparison
# takes @unknown as not read (a warning), never as another build. Several values on one member
# are "+"-joined (a rollout). Every value keeps only [A-Za-z0-9_.:/@+-] (anything else becomes
# _), so it holds no tab, newline, comma, = or |.
# A file written before the record has none of these keys (the suites supported only OpenShift
# with OSSM then), and its values read unknown in a report; one written before
# ISTIOD_ENV_BY_CONTEXT or TUNING_OBJECTS_BY_CONTEXT has the others.
#
# A sweep calls platform_probe once with all its members, before its first step, then
# platform_probe_share: the record (PLATFORM_PROBE_ROWS, never exported: one line per member,
# <ctx> and the seven values (PLATFORM_ROW_KEYS) tab-separated) goes to platform-record.txt in
# the sweep dir, whose path is exported (PLATFORM_PROBE_FILE), and each step it runs reads that
# file when it sources this one. No environment string holds it: Linux refuses to run any
# command whose environment holds a string over 128 KiB, the record of about 400 members. The
# steps reuse it for the members it covers and read only the others, like RUN_CONFIG, and those
# whose platform it recorded unknown (a transient failure at the sweep's start; a phase that
# reuses a saved record reads nothing: platform_probe_load). A standalone step reads its own
# members. With DRY_RUN=1 nothing is read, every value is unknown and no file is written. After
# its last step a sweep reads its members again (platform_drift_check): a build, istiod setting
# or limit, tuning lever, tuning profile object or Kubernetes version that changed while it ran
# goes to platform-drift.txt in the sweep dir, which every report of the sweep says in its body,
# naming each member's value at the start and at the end (the record's keys merge it as a second
# value, mixed:; so does KUBE_VERSIONS in a report that merges it, churn's).
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
# The label of a tuning profile's objects, the kinds a profile may create, and its marker's (a
# ConfigMap on each member it is applied to: tests/tuning/001-apply-profile.sh). The record lists
# them all (TUNING_OBJECTS_BY_CONTEXT); tests/tuning/005-cleanup.sh restores each member's Istio CR
# from its markers and deletes the rest by kind; tuning 004 checks that each pass's record holds
# its profile's marker (tuning-profile-<profile> in istio-system) on every member. Keep in sync
# with tests/tuning/lib/tuning.py (LABEL, ALLOWED_KINDS, MARKER_KIND, MARKER_NAMESPACE,
# MARKER_PREFIX), which platform.bats checks. The marker's kind is its kubectl resource
# (PLATFORM_TUNING_MARKER_KIND) and, as the record lists it, its object kind
# (PLATFORM_TUNING_MARKER_OBJECT_KIND, tuning.py's MARKER_KIND).
PLATFORM_TUNING_LABEL=istio-scale-tests/tuning-profile
PLATFORM_TUNING_RESOURCE_KINDS=destinationrules.networking.istio.io,sidecars.networking.istio.io,envoyfilters.networking.istio.io,telemetries.telemetry.istio.io
PLATFORM_TUNING_MARKER_KIND=configmaps
PLATFORM_TUNING_MARKER_OBJECT_KIND=ConfigMap
PLATFORM_TUNING_MARKER_NS=istio-system
PLATFORM_TUNING_MARKER_PREFIX=tuning-profile-
PLATFORM_TUNING_KINDS="${PLATFORM_TUNING_RESOURCE_KINDS},${PLATFORM_TUNING_MARKER_KIND}"
# The jq program over a list of them: "<profile>:<Kind>/<ns>/<name>" per object, sorted and
# "+"-joined, or none (a TUNING_OBJECTS_BY_CONTEXT value).
# shellcheck disable=SC2016  # jq program: $label is a jq variable
PLATFORM_TUNING_JQ='[.items[]? | "\(.metadata.labels[$label] // "unlabelled"):\(.kind // "unknown")/\(.metadata.namespace // "-")/\(.metadata.name // "-")"]
	| unique | if length == 0 then "none" else join("+") end'
# kubectl --request-timeout of each platform-record read, and how many members are read at once
# (config/options.env; the same defaults for a caller that did not source it). platform_validate
# checks both.
PLATFORM_READ_TIMEOUT="${PLATFORM_READ_TIMEOUT:-20s}"
PLATFORM_READ_PARALLEL="${PLATFORM_READ_PARALLEL:-20}"
# The record's preamble keys, in order; the reports print the same list.
# shellcheck disable=SC2034  # read by the reports
PLATFORM_KEYS=(PLATFORM TEST_PLATFORM PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT
	PROXY_IMAGE_BY_CONTEXT NODE_PROVIDER_BY_CONTEXT ISTIOD_ENV_BY_CONTEXT TUNING_OBJECTS_BY_CONTEXT)
# The per-member keys, in the order of a PLATFORM_PROBE_ROWS line's values (after <ctx>).
PLATFORM_ROW_KEYS=(PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT PROXY_IMAGE_BY_CONTEXT
	NODE_PROVIDER_BY_CONTEXT ISTIOD_ENV_BY_CONTEXT TUNING_OBJECTS_BY_CONTEXT)
# The keys a tuning pass is compared on (tuning 004): every record key but istiod's settings and
# the tuning objects, which a profile changes on purpose (spec.values.pilot.env, its resources),
# and each member's Kubernetes version (KUBE_VERSIONS, which every TSV records next to the record).
# shellcheck disable=SC2034  # read by tuning 004
PLATFORM_PASS_KEYS=(PLATFORM TEST_PLATFORM PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT
	PROXY_IMAGE_BY_CONTEXT NODE_PROVIDER_BY_CONTEXT KUBE_VERSIONS)
# The file platform_drift_check writes into a sweep dir and platform_merge_by_context reads
# next to each input (not *.tsv, so no report or tuning glob takes it for data).
PLATFORM_DRIFT_FILE="platform-drift.txt"
# The file platform_probe_share writes into a sweep dir: the record the sweep read at its start,
# which its steps read (PLATFORM_PROBE_FILE). A controlplane --resume writes it anew from its own
# read; the TSV's preamble keeps the record of the sweep's start.
PLATFORM_RECORD_FILE="platform-record.txt"

# A step a sweep runs starts from the sweep's record, read here as this file is sourced
# (platform_probe_share); its platform_probe still reads again a member the record holds
# unknown. PLATFORM_PROBE_ROWS is never exported, even when it came in so (a test): no command
# this shell runs gets it in its environment.
export -n PLATFORM_PROBE_ROWS
if [[ -z "${PLATFORM_PROBE_ROWS:-}" && -n "${PLATFORM_PROBE_FILE:-}" ]]; then
	if [[ -r "$PLATFORM_PROBE_FILE" ]]; then
		PLATFORM_PROBE_ROWS="$(<"$PLATFORM_PROBE_FILE")"
		[[ -z "$PLATFORM_PROBE_ROWS" ]] || PLATFORM_PROBE_ROWS+=$'\n'
	else
		echo "warning: cannot read the sweep's platform record (PLATFORM_PROBE_FILE: ${PLATFORM_PROBE_FILE}); this step reads its own members' record" >&2
	fi
fi

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
# openshift, PLATFORM_READ_TIMEOUT a kubectl --request-timeout above zero (20s, 1.5m, 1m30s, or
# seconds) and PLATFORM_READ_PARALLEL a whole number above zero. Call it with the other argument
# checks, before anything is read.
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
# sha256 that ran (the sha256:<64 hex> in the imageID, wherever it stands), of the pods whose
# container started (it reports one) or whose spec pins a digest, those not terminated (Failed or
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

# _platform_sanitize <value>: one record value: [A-Za-z0-9_.:/@+-] only, unknown when empty.
# _platform_sanitize_to <name> <value>: the same into variable <name>, in this shell (no fork: a
# loop over 500 members calls it per member).
# shellcheck disable=SC2329
_platform_sanitize() {
	local _pl_sv
	_platform_sanitize_to _pl_sv "$1"
	printf '%s\n' "$_pl_sv"
}
# shellcheck disable=SC2329
_platform_sanitize_to() {
	local _pl_st="${2//[^A-Za-z0-9_.:\/@+-]/_}"
	printf -v "$1" '%s' "${_pl_st:-unknown}"
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
# first 300 bytes of the read's stderr, addresses and host names masked (reach_sanitize), and the
# knob to raise when the read ran out of time (_platform_timed_out).
# shellcheck disable=SC2329
_platform_warn() {
	local why hint=""
	why="$(head -c 300 "$3" 2>/dev/null)" || why=""
	! _platform_timed_out "$3" || hint="; $(_platform_timeout_hint)"
	why="$(reach_sanitize "${why:-no answer}")"
	echo "warning: ${1}: could not read ${2}; recorded as unknown: ${why}${hint}" >&2
}

# _platform_timed_out <err file>: return 0 when a read's stderr says it ran out of time (kubectl's
# client timeout, a deadline, or the server's Timeout answer to the request's timeout).
# shellcheck disable=SC2329
_platform_timed_out() {
	grep -qiE 'Client\.Timeout|deadline exceeded|i/o timeout|timeout exceeded|\(Timeout\)|timed out' "$1" 2>/dev/null
}

# _platform_timeout_hint: what to do about a read that ran out of time.
# shellcheck disable=SC2329
_platform_timeout_hint() {
	echo "no answer within PLATFORM_READ_TIMEOUT (${PLATFORM_READ_TIMEOUT}); raise it in the environment, config/options.env or, in a script that takes one, the --config file, for a large or slow member"
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
		 | {run: ([$p.status.containerStatuses[]? | select(.name == "discovery")][0].imageID // "" | test("sha256:[0-9a-f]{64}")),
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
# <nodes>\t<istiod env>\t<tuning objects>" on stdout, a warning per value it could not read on
# stderr. After a read the member did not answer, the rest are not tried (each would wait out the
# timeout) and read unknown. The platform is what the member serves, whatever TEST_PLATFORM says
# (a disagreement warns); the operator is looked for on it, or on TEST_PLATFORM's when the member
# could not be asked. istiod's env comes from the same pod list as the images (no other read). The
# tuning objects: one list of PLATFORM_TUNING_KINDS by PLATFORM_TUNING_LABEL in every namespace (a
# kind the member does not serve makes it unknown, never none).
# shellcheck disable=SC2329
_platform_probe_member() {
	local ctx="$1" w="$2" platform look op=unknown istiod=unknown proxy=unknown nodes=unknown ienv=unknown tobj=unknown rc=0 f last=""
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
		           | [capture("(?<d>sha256:[0-9a-f]{64})")][0].d // "")}
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
		last="${w}/platform.err"
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
			last="${w}/op.json.err"
			((rc != 0)) || op="$(jq -r --arg name "$PLATFORM_SAIL_DEPLOY" "$sail_jq" "${w}/op.json" 2>/dev/null)" || op=""
			;;
		openshift)
			_platform_read "$ctx" "${w}/op.json" -n "$PLATFORM_OSSM_NS" get clusterserviceversions.operators.coreos.com || rc=$?
			last="${w}/op.json.err"
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
		last="${w}/pods.json.err"
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
		last="${w}/nodes.json.err"
		((rc != 0)) || nodes="$(jq -r "$nodes_jq" "${w}/nodes.json" 2>/dev/null)" || nodes=""
		if [[ "$rc" != 0 || -z "$nodes" ]]; then
			[[ -s "${w}/nodes.json.err" ]] || echo "the reply did not parse" >"${w}/nodes.json.err"
			_platform_warn "$ctx" "the node provider" "${w}/nodes.json.err"
			nodes=unknown
		fi
	fi
	if ((rc != 1)); then
		rc=0
		_platform_read "$ctx" "${w}/tuning.json" get "$PLATFORM_TUNING_KINDS" -A -l "$PLATFORM_TUNING_LABEL" || rc=$?
		last="${w}/tuning.json.err"
		((rc != 0)) || tobj="$(jq -r --arg label "$PLATFORM_TUNING_LABEL" "$PLATFORM_TUNING_JQ" "${w}/tuning.json" 2>/dev/null)" || tobj=""
		if [[ "$rc" != 0 || -z "$tobj" ]]; then
			[[ -s "${w}/tuning.json.err" ]] || echo "the reply did not parse" >"${w}/tuning.json.err"
			_platform_warn "$ctx" "the tuning profile objects (label ${PLATFORM_TUNING_LABEL})" "${w}/tuning.json.err"
			tobj=unknown
		fi
	fi
	if ((rc == 1)); then
		if [[ -n "$last" ]] && _platform_timed_out "$last"; then
			echo "warning: ${ctx}: did not answer within PLATFORM_READ_TIMEOUT (${PLATFORM_READ_TIMEOUT}); its platform record stops here (the values not read are unknown)" >&2
		else
			echo "warning: ${ctx}: did not answer; its platform record stops here (the values not read are unknown)" >&2
		fi
	fi
	_pl_val=("$(_platform_sanitize "$platform")" "$(_platform_sanitize "$op")" "$(_platform_sanitize "$istiod")"
		"$(_platform_sanitize "$proxy")" "$(_platform_sanitize "$nodes")" "$(_platform_sanitize "$ienv")"
		"$(_platform_sanitize "$tobj")")
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ctx" "${_pl_val[@]}"
}

# _platform_unknown_row <ctx>: a record line with every value unknown.
# shellcheck disable=SC2329
_platform_unknown_row() {
	local out="$1" k
	for k in "${PLATFORM_ROW_KEYS[@]}"; do out+=$'\tunknown'; done
	printf '%s\n' "$out"
}

# _platform_index: _PL_IDX, each member's line of PLATFORM_PROBE_ROWS (its first), built again
# only when the record changed since (_PL_IDX_SRC; the helpers below keep it current). A loop
# over many members calls it once in its own shell first and then reads _PL_IDX, so a lookup is
# one array read instead of a scan of every line (500 members: 500 scans of 500 lines); even the
# check costs a millisecond at 500 members, so the loops do not repeat it.
declare -gA _PL_IDX=()
# shellcheck disable=SC2329
_platform_index() {
	local line c
	[[ -z "${_PL_IDX_SET:-}" || "${_PL_IDX_SRC:-}" != "${PLATFORM_PROBE_ROWS:-}" ]] || return 0
	_PL_IDX=()
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		c="${line%%$'\t'*}"
		[[ -z "$c" || -n "${_PL_IDX[$c]+x}" ]] || _PL_IDX[$c]="$line"
	done <<<"${PLATFORM_PROBE_ROWS:-}"
	_PL_IDX_SRC="${PLATFORM_PROBE_ROWS:-}"
	_PL_IDX_SET=1
}

# _platform_row <ctx>: the member's line of PLATFORM_PROBE_ROWS; return 1 when it has none.
# shellcheck disable=SC2329
_platform_row() {
	_platform_index
	[[ -n "$1" && -n "${_PL_IDX[$1]+x}" ]] || return 1
	printf '%s\n' "${_PL_IDX[$1]}"
}

# _platform_rows_add <lines>: append these lines (members PLATFORM_PROBE_ROWS does not have, each
# line newline-terminated) and keep the index current.
# shellcheck disable=SC2329
_platform_rows_add() {
	local line c
	[[ -n "$1" ]] || return 0
	_platform_index
	PLATFORM_PROBE_ROWS+="$1"
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		c="${line%%$'\t'*}"
		[[ -z "$c" || -n "${_PL_IDX[$c]+x}" ]] || _PL_IDX[$c]="$line"
	done <<<"$1"
	_PL_IDX_SRC="$PLATFORM_PROBE_ROWS"
}

# _platform_rows_set <lines>: put each of these rows (newline-terminated) in PLATFORM_PROBE_ROWS
# in place of its member's line (at the end when it has none), all in one pass over the record (a
# pass per row is quadratic on a large mesh), and keep the index current.
# shellcheck disable=SC2329
_platform_rows_set() {
	local line out="" c
	local -a _pl_ord=()
	local -A _pl_new=() _pl_used=()
	[[ -n "$1" ]] || return 0
	while IFS= read -r line; do
		c="${line%%$'\t'*}"
		[[ -n "$c" ]] || continue
		[[ -n "${_pl_new[$c]+x}" ]] || _pl_ord+=("$c")
		_pl_new[$c]="$line"
	done <<<"$1"
	((${#_pl_ord[@]})) || return 0
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		c="${line%%$'\t'*}"
		if [[ -n "$c" && -n "${_pl_new[$c]+x}" ]]; then
			[[ -n "${_pl_used[$c]+x}" ]] || out+="${_pl_new[$c]}"$'\n'
			_pl_used[$c]=1
		else
			out+="${line}"$'\n'
		fi
	done <<<"${PLATFORM_PROBE_ROWS:-}"
	for c in "${_pl_ord[@]}"; do
		[[ -n "${_pl_used[$c]+x}" ]] || out+="${_pl_new[$c]}"$'\n'
	done
	_platform_index
	PLATFORM_PROBE_ROWS="$out"
	for c in "${_pl_ord[@]}"; do
		_PL_IDX[$c]="${_pl_new[$c]}"
	done
	_PL_IDX_SRC="$PLATFORM_PROBE_ROWS"
}

# _platform_row_has_unknown <row>: return 0 when one of the row's values is unknown.
# shellcheck disable=SC2329
_platform_row_has_unknown() {
	[[ $'\t'"${1#*$'\t'}"$'\t' == *$'\tunknown\t'* ]]
}

# _platform_each <fn> <tmp> <ctx>...: run "<fn> <ctx> <tmp>/<i>" for each member in the
# background, PLATFORM_READ_PARALLEL at a time (500 members would otherwise start 500 reads, and
# their kubectl processes, at once), with its stdout in <tmp>/<i>.row and its stderr in
# <tmp>/<i>.warn (<i>: the member's index), and wait for all of them. The pool runs in a subshell
# of its own, so its waits see only its reads, never a job of the caller's.
# shellcheck disable=SC2329
_platform_each() {
	local fn="$1" tmp="$2"
	shift 2
	(
		local i n=0
		local -a _pl_m=("$@")
		for i in "${!_pl_m[@]}"; do
			if ((n >= PLATFORM_READ_PARALLEL)); then
				wait -n || true
				n=$((n - 1))
			fi
			mkdir -p "${tmp}/${i}"
			("$fn" "${_pl_m[i]}" "${tmp}/${i}" >"${tmp}/${i}.row" 2>"${tmp}/${i}.warn") &
			n=$((n + 1))
		done
		wait
	)
}

# _platform_read_members <ctx>...: read each member's record (_platform_probe_member; a member's
# reads one after the other, each bounded by PLATFORM_READ_TIMEOUT), PLATFORM_READ_PARALLEL
# members at a time (_platform_each): the rows on stdout and the warnings on stderr, both in
# argument order. A member whose read fails outright gets a row of unknowns and a warning.
# Return 1 without KUBECTL or a temp dir.
# shellcheck disable=SC2329
_platform_read_members() {
	local i tmp row
	local -a _pl_m=("$@")
	((${#_pl_m[@]})) || return 0
	[[ -n "${KUBECTL[*]:-}" ]] || return 1
	tmp="$(mktemp -d)" || return 1
	_platform_each _platform_probe_member "$tmp" "${_pl_m[@]}"
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
		"istiod settings (its discovery container env)" "tuning profile objects")
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
# put them in it (not exported: a sweep hands it on with platform_probe_share). Call it in the
# script's own shell (not in $(...)), before any measurement window. Never fails for a member it
# cannot read: those values are unknown and each one gets a warning. Dies when <ctxs_csv> lists a
# member twice, or two members the record would write under one name (_platform_sanitize): their
# values would be read, counted and recorded as two members' (mesh size, every value per member).
# shellcheck disable=SC2329
platform_probe() {
	local ctx c row rows old add="" set=""
	local -a ctxs=() todo=() _pl_again=()
	local -A _pl_seen=() _pl_name=()
	platform_validate
	# Checked before the dry-run returns, though the probes (dataplane 002, controlplane 002) exit
	# their dry-run before they call this: platform.bats's static test is what checks every caller.
	declare -F reach_sanitize >/dev/null || die "platform_probe needs reach_sanitize (source tests/lib/reach.sh)"
	declare -F _config_sha256 >/dev/null || die "platform_probe needs _config_sha256 (source tests/lib/config.sh)"
	split_csv "$1" ctxs
	PLATFORM_PROBE_LAST="$(IFS=,; echo "${ctxs[*]}")"
	_platform_index
	for ctx in "${ctxs[@]}"; do
		[[ -n "$ctx" ]] || continue
		[[ -z "${_pl_seen[$ctx]+x}" ]] ||
			die "${ctx} is listed twice among the mesh members: list each member once (--contexts or SETUP_CONTEXTS; a probe's --source-context is not one of its --remote-contexts)"
		_pl_seen[$ctx]=1
		_platform_sanitize_to c "$ctx"
		[[ -z "${_pl_name[$c]+x}" ]] ||
			die "${_pl_name[$c]} and ${ctx} would be recorded under one name, ${c} (the record writes a member's name with A-Z, a-z, 0-9 and _.:/@+- only): rename one of the two contexts"
		_pl_name[$c]="$ctx"
		if [[ -z "${_PL_IDX[$ctx]+x}" ]]; then
			todo+=("$ctx")
		elif ! ((${DRY_RUN:-0} || ${PLATFORM_PROBE_LOADED:-0})) && _platform_row_has_unknown "${_PL_IDX[$ctx]}"; then
			_pl_again+=("$ctx")
		fi
	done
	((${#todo[@]} + ${#_pl_again[@]})) || return 0
	if ((${DRY_RUN:-0})); then
		for ctx in "${todo[@]}"; do
			add+="$(_platform_unknown_row "$ctx")"$'\n'
		done
		_platform_rows_add "$add"
		return 0
	fi
	[[ -n "${KUBECTL[*]:-}" ]] || die "neither kubectl nor oc found on PATH (platform_probe needs KUBECTL)"
	if ((${#_pl_again[@]})); then
		echo "Platform record: reading again $(_platform_names "${_pl_again[@]}") (an unknown value in the record this step inherited)" >&2
	fi
	rows="$(_platform_read_members ${todo[@]+"${todo[@]}"} ${_pl_again[@]+"${_pl_again[@]}"})" ||
		die "platform_probe: cannot read the platform record (no temp dir)"
	# The members read again are merged in place, the new ones appended, each set at once.
	while IFS= read -r row; do
		[[ -n "$row" ]] || continue
		old="${row%%$'\t'*}"
		if [[ -n "${_PL_IDX[$old]+x}" ]]; then
			set+="$(_platform_row_merge "${_PL_IDX[$old]}" "$row")"$'\n'
		else
			add+="${row}"$'\n'
		fi
	done <<<"$rows"
	_platform_rows_set "$set"
	_platform_rows_add "$add"
}

# platform_member_value <ctx> <platform|operator|istiod|proxy|nodes|istiod_env|tuning_objects>: one
# value of a member's record (PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ...); unknown when it
# was not read.
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
	tuning_objects) i=7 ;;
	*) die "platform_member_value: unknown field '$2' (platform, operator, istiod, proxy, nodes, istiod_env or tuning_objects)" ;;
	esac
	_platform_index
	row=""
	[[ -z "$1" || -z "${_PL_IDX[$1]+x}" ]] || row="${_PL_IDX[$1]}"
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
	local line old add="" set=""
	local -A _pl_seen=()
	PLATFORM_PROBE_LOADED=1
	[[ -f "$1" ]] || return 0
	_platform_index
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		old="${line%%$'\t'*}"
		[[ -n "$old" && -z "${_pl_seen[$old]+x}" ]] || continue
		_pl_seen[$old]=1
		if [[ -z "${_PL_IDX[$old]+x}" ]]; then
			add+="${line}"$'\n'
		elif _platform_row_has_unknown "${_PL_IDX[$old]}" && ! _platform_row_has_unknown "$line"; then
			set+="${line}"$'\n'
		fi
	done <"$1"
	_platform_rows_set "$set"
	_platform_rows_add "$add"
}

# platform_probe_share <dir>: hand this sweep's record to the steps it runs: write it to
# <dir>/platform-record.txt (created with <dir>) and export its path (PLATFORM_PROBE_FILE),
# which a step reads when it sources this file. Never the environment: Linux refuses to run any
# command whose environment holds a string over 128 KiB, the record of about 400 members. Call it
# right after the sweep's platform_probe (and --resume check). With DRY_RUN=1 it writes nothing
# and each step records its own members (unknown, as the sweep's are).
# shellcheck disable=SC2329
platform_probe_share() {
	local f="${1}/${PLATFORM_RECORD_FILE}"
	((${DRY_RUN:-0} == 0)) || return 0
	if ! mkdir -p "$1" || ! printf '%s' "${PLATFORM_PROBE_ROWS:-}" >"$f"; then
		die "platform_probe_share: cannot write ${f}: the steps of this sweep need the record it read"
	fi
	export PLATFORM_PROBE_FILE="$f"
}

# platform_probe_reset: forget the record this shell holds (PLATFORM_PROBE_ROWS, inherited or
# read, and a platform_probe_load), and stop handing it to the steps it runs (PLATFORM_PROBE_FILE),
# so the next platform_probe reads every member again. tuning 003 calls it before each pass's
# platform_probe: a profile changes the record (istiod's env, its objects), so each pass has its
# own.
# shellcheck disable=SC2329
platform_probe_reset() {
	PLATFORM_PROBE_ROWS=""
	unset PLATFORM_PROBE_LOADED PLATFORM_PROBE_LAST PLATFORM_PROBE_FILE
	_PL_IDX=()
	_PL_IDX_SRC=""
	_PL_IDX_SET=""
}

# _platform_values <ctxs_csv>: the record as KEY=value lines (PLATFORM_KEYS order) for these
# members; a member platform_probe did not read warns and reads unknown.
# shellcheck disable=SC2329
_platform_values() {
	local ctx row agg sk=0 so=0 su=0 c j
	local -a ctxs=() _pl_f=() _pl_by=()
	split_csv "$1" ctxs
	_platform_index
	for ctx in ${ctxs[@]+"${ctxs[@]}"}; do
		if [[ -n "$ctx" && -n "${_PL_IDX[$ctx]+x}" ]]; then
			row="${_PL_IDX[$ctx]}"
		else
			echo "warning: ${ctx}: no platform record was read (platform_probe was not called for it); its values read unknown" >&2
			row="$(_platform_unknown_row "$ctx")"
		fi
		IFS=$'\t' read -r -a _pl_f <<<"$row"
		case "${_pl_f[1]}" in
		kubernetes) sk=1 ;;
		openshift) so=1 ;;
		*) su=1 ;;
		esac
		_platform_sanitize_to c "$ctx"
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

# platform_start_warnings <ctxs_csv>: what a sweep warns about on stderr as it starts, from the
# record platform_probe read for these members (nothing in a dry-run, which reads none): a tuning
# profile's objects or marker in place on a member (TUNING_OBJECTS_BY_CONTEXT), which every step
# would measure with. Call it right after platform_probe_share, before the first step; every report
# of the run warns again (platform_report_warnings).
# shellcheck disable=SC2329
platform_start_warnings() {
	local v state who objs hint
	((${DRY_RUN:-0} == 0)) || return 0
	v="$(_platform_values "$1" 2>/dev/null | sed -n 's/^TUNING_OBJECTS_BY_CONTEXT=//p')"
	IFS=$'\t' read -r state who objs < <(platform_tuning_objects_check "$v")
	[[ "$state" == other ]] || return 0
	echo "warning: a tuning profile's objects are in place on ${who} (TUNING_OBJECTS_BY_CONTEXT: ${objs}), so this sweep would measure that profile's configuration, not the charts'. Unless that is the point, stop it now (Ctrl-C); then, unless a tuning run is still in progress on these members (wait for it to end), undo them with $(_platform_cleanup_hint "$1"); every report of this run warns too" >&2
}

# _platform_cleanup_hint <ctxs_csv>: the tests/tuning/005-cleanup.sh command that undoes a profile
# left applied on these members (its marker restores each member's Istio CR from any checkout),
# and the flags that find the state and the Argo CD pause of the run that left it, which only
# that run's results directory records.
# shellcheck disable=SC2329
_platform_cleanup_hint() {
	local v="--contexts ${1}"
	((${#v} <= 200)) || v="the same --contexts"
	echo "./tests/tuning/005-cleanup.sh ${v} (add --results-dir <that run's --output-dir> if it had one, and --gitops-context <hub> to resume Argo CD if it paused it)"
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
	printf '| Platform | %s (TEST_PLATFORM %s); nodes %s; operator %s; istiod %s; gateway proxy %s; istiod env %s; tuning objects %s |\n' \
		"${_pl_rec[PLATFORM]}" "${_pl_rec[TEST_PLATFORM]}" "$(platform_collapse "${_pl_rec[NODE_PROVIDER_BY_CONTEXT]}")" \
		"$(platform_collapse "${_pl_rec[MESH_OPERATOR_BY_CONTEXT]}")" "$(platform_collapse "${_pl_rec[ISTIOD_IMAGE_BY_CONTEXT]}")" \
		"$(platform_collapse "${_pl_rec[PROXY_IMAGE_BY_CONTEXT]}")" "$(platform_collapse "${_pl_rec[ISTIOD_ENV_BY_CONTEXT]}")" \
		"$(platform_collapse "${_pl_rec[TUNING_OBJECTS_BY_CONTEXT]}")"
}

# _platform_parts_to <key> <value> <array name>: the builds a value holds, into the array: without
# "mixed:", split at ";" (a merged value) and "+" (not for KUBE_VERSIONS, whose versions can hold
# one: v1.30.4+k3s1), a MESH_OPERATOR_BY_CONTEXT one without the state after its last "/"
# ("/Available", "/Succeeded", ...: a value that differs only in it is the same build; no other
# key has a state, and TUNING_OBJECTS_BY_CONTEXT's <Kind>/<ns>/<name> keeps its slashes); "?" for a
# value not read (_platform_unread). A NODE_PROVIDER_BY_CONTEXT "none" beside a provider is
# dropped: a node its cloud controller has not initialized yet (a scale-up) has no providerID,
# and its provider is the others' ("aws+none" is aws), not another platform.
# shellcheck disable=SC2329
_platform_parts_to() {
	local _pl_px _pl_py _pl_ps=';+'
	local -a _pl_pxs=()
	local -n _pl_pt_out="$3"
	_pl_pt_out=()
	[[ "$1" != KUBE_VERSIONS ]] || _pl_ps=';'
	IFS="$_pl_ps" read -r -a _pl_pxs <<<"${2#mixed:}"
	for _pl_px in ${_pl_pxs[@]+"${_pl_pxs[@]}"}; do
		[[ -n "$_pl_px" ]] || continue
		if _platform_unread "$1" "$_pl_px"; then
			_pl_pt_out+=('?')
		elif [[ "$1" == MESH_OPERATOR_BY_CONTEXT ]]; then
			_pl_pt_out+=("${_pl_px%/*}")
		else
			_pl_pt_out+=("$_pl_px")
		fi
	done
	[[ "$1" == NODE_PROVIDER_BY_CONTEXT ]] || return 0
	for _pl_px in ${_pl_pt_out[@]+"${_pl_pt_out[@]}"}; do
		case "$_pl_px" in
		none | '?' | no-nodes | unrecognized) ;;
		*)
			# A provider: the nodes without one are its nodes not initialized yet.
			_pl_pxs=()
			for _pl_py in "${_pl_pt_out[@]}"; do [[ "$_pl_py" == none ]] || _pl_pxs+=("$_pl_py"); done
			_pl_pt_out=("${_pl_pxs[@]}")
			return 0
			;;
		esac
	done
}

# _platform_part_match <part> <part>: two builds (_platform_parts_to): return 0 when they are the
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
# _platform_build_cmp_to <name> <key> <value> <value>: the same into variable <name>, in this
# shell (no fork: a resume or a report compares every member's value of every key). Two equal
# values with nothing unread in them are the same without being split.
# shellcheck disable=SC2329
_platform_build_cmp() {
	local _pl_bc
	_platform_build_cmp_to _pl_bc "$@"
	printf '%s\n' "$_pl_bc"
}
# shellcheck disable=SC2329
_platform_build_cmp_to() {
	# Every local is _pl_b*: <name> is the caller's variable (res, cmp, ...), which a local of the
	# same name here would hide from printf -v.
	local _pl_bo="$1" _pl_bk="$2" _pl_bx _pl_by _pl_bm _pl_bb _pl_br=same
	local -a _pl_bxa=() _pl_bxb=() _pl_bka=() _pl_bkb=()
	if [[ "$3" == "$4" && "${3#mixed:}" == *[A-Za-z0-9]* && "$3" != *unknown* && ( "$_pl_bk" != KUBE_VERSIONS || "$3" != *unreachable* ) ]]; then
		printf -v "$_pl_bo" same
		return 0
	fi
	_platform_parts_to "$_pl_bk" "$3" _pl_bxa
	_platform_parts_to "$_pl_bk" "$4" _pl_bxb
	for _pl_bx in ${_pl_bxa[@]+"${_pl_bxa[@]}"}; do
		if [[ "$_pl_bx" == '?' ]]; then _pl_br=unknown; else _pl_bka+=("$_pl_bx"); fi
	done
	for _pl_bx in ${_pl_bxb[@]+"${_pl_bxb[@]}"}; do
		if [[ "$_pl_bx" == '?' ]]; then _pl_br=unknown; else _pl_bkb+=("$_pl_bx"); fi
	done
	if ((${#_pl_bka[@]} == 0 || ${#_pl_bkb[@]} == 0)); then
		printf -v "$_pl_bo" unknown
		return 0
	fi
	for _pl_bx in "${_pl_bka[@]}"; do
		_pl_bb=2
		for _pl_by in "${_pl_bkb[@]}"; do
			_platform_part_match "$_pl_bx" "$_pl_by" && _pl_bm=0 || _pl_bm=$?
			((_pl_bm >= _pl_bb)) || _pl_bb=$_pl_bm
		done
		if ((_pl_bb == 2)); then printf -v "$_pl_bo" differs; return 0; fi
		((_pl_bb == 0)) || _pl_br=unknown
	done
	for _pl_by in "${_pl_bkb[@]}"; do
		_pl_bb=2
		for _pl_bx in "${_pl_bka[@]}"; do
			_platform_part_match "$_pl_by" "$_pl_bx" && _pl_bm=0 || _pl_bm=$?
			((_pl_bm >= _pl_bb)) || _pl_bb=$_pl_bm
		done
		if ((_pl_bb == 2)); then printf -v "$_pl_bo" differs; return 0; fi
		((_pl_bb == 0)) || _pl_br=unknown
	done
	printf -v "$_pl_bo" '%s' "$_pl_br"
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
	TUNING_OBJECTS_BY_CONTEXT) echo "tuning profile objects" ;;
	KUBE_VERSIONS) echo "Kubernetes versions" ;;
	TUNING_BASELINE) echo "tuning levers" ;;
	SIDECAR_EGRESS_HOSTS) echo "root Sidecar egress hosts" ;;
	ISTIOD_CPU_LIMIT_M) echo "istiod CPU limits" ;;
	ISTIOD_MEM_LIMIT_MI) echo "istiod memory limits" ;;
	ISTIOD_REPLICAS_BY_CONTEXT) echo "istiod replica counts" ;;
	TEST_PLATFORM) echo "TEST_PLATFORM overrides (the suite charts' overlay)" ;;
	*) echo values ;;
	esac
}

# _platform_cause <key>: what usually changes a key's value, for a drift warning and a refused
# --resume.
# shellcheck disable=SC2329
_platform_cause() {
	case "$1" in
	MESH_OPERATOR_BY_CONTEXT) echo "an operator upgrade (an Argo CD sync of a new chart revision, or a new OLM CSV)" ;;
	ISTIOD_IMAGE_BY_CONTEXT | PROXY_IMAGE_BY_CONTEXT) echo "an Argo CD sync of a new revision or an operator upgrade" ;;
	ISTIOD_ENV_BY_CONTEXT) echo "a tuning profile applied or reverted on these members (by a tuning run, or one stopped before its revert, which tests/tuning/005-cleanup.sh undoes), or a sync or hand edit of the Istio CR's spec.values.pilot.env" ;;
	TUNING_OBJECTS_BY_CONTEXT) echo "a tuning profile applied or reverted on these members (by a tuning run, or one stopped before its revert, which tests/tuning/005-cleanup.sh undoes from its marker), or a profile's objects applied or deleted by hand" ;;
	KUBE_VERSIONS) echo "a managed control-plane upgrade" ;;
	TUNING_BASELINE | SIDECAR_EGRESS_HOSTS) echo "a GitOps sync or self-heal that put a lever back, a tuning profile left applied, or a hand edit" ;;
	ISTIOD_CPU_LIMIT_M | ISTIOD_MEM_LIMIT_MI) echo "an Argo CD sync, a tuning profile or a hand edit of istiod's resources (the Istio CR's spec.values.pilot.resources)" ;;
	ISTIOD_REPLICAS_BY_CONTEXT) echo "an HPA (the Istio CR's spec.values.pilot.autoscaleEnabled turned on), an Argo CD sync or a tuning profile that sets spec.values.pilot.replicaCount, or a hand scale of istiod's Deployment" ;;
	*) echo "a context that now points at a rebuilt or another cluster" ;;
	esac
}

# _platform_drift_cause <key>: the usual cause of a value that changed during a sweep
# (_platform_cause), and what to do for figures that can be published.
# shellcheck disable=SC2329
_platform_drift_cause() {
	local fix
	case "$1" in
	MESH_OPERATOR_BY_CONTEXT | ISTIOD_IMAGE_BY_CONTEXT | PROXY_IMAGE_BY_CONTEXT) fix="on one build" ;;
	ISTIOD_ENV_BY_CONTEXT) fix="with istiod's settings fixed" ;;
	TUNING_OBJECTS_BY_CONTEXT) fix="without a profile's objects (or with the same ones throughout)" ;;
	KUBE_VERSIONS) fix="on one Kubernetes version" ;;
	TUNING_BASELINE | SIDECAR_EGRESS_HOSTS) fix="with the levers fixed" ;;
	ISTIOD_CPU_LIMIT_M | ISTIOD_MEM_LIMIT_MI) fix="with istiod's limits fixed" ;;
	ISTIOD_REPLICAS_BY_CONTEXT) fix="with istiod's replica count fixed (autoscaling off, as charts/spoke-ossm sets it)" ;;
	*) fix="on fixed members" ;;
	esac
	echo "the usual cause is $(_platform_cause "$1"); for publishable figures, run the sweep again ${fix}"
}

# _platform_resume_causes <key>...: for a refused --resume, one line with the usual cause
# (_platform_cause) of each key that differs, each once; nothing without a key.
# shellcheck disable=SC2329
_platform_resume_causes() {
	local k out=""
	local -A _pl_seen=()
	for k in "$@"; do
		[[ -n "$k" && -z "${_pl_seen[$k]+x}" ]] || continue
		_pl_seen[$k]=1
		out+="${out:+; }${k}: $(_platform_cause "$k")"
	done
	[[ -z "$out" ]] || printf 'Usual causes: %s.\n' "$out"
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

# _platform_group <map> <order> <key> <member>: add <member> to the group <key> of the associative
# array <map> (its members \x1f-joined), and a new <key> to the array <order>: one warning per
# group (a key, a recorded value and a new one, say) instead of one per member of a large mesh.
# shellcheck disable=SC2329
_platform_group() {
	local -n _pg_map="$1" _pg_ord="$2"
	[[ -n "${_pg_map[$3]+x}" ]] || _pg_ord+=("$3")
	_pg_map[$3]+="${_pg_map[$3]:+$'\x1f'}${4}"
}

# _platform_group_names <members>: a group's members (\x1f-joined), as _platform_names names them.
# shellcheck disable=SC2329
_platform_group_names() {
	local -a _pg_w=()
	IFS=$'\x1f' read -r -a _pg_w <<<"$1"
	_platform_names ${_pg_w[@]+"${_pg_w[@]}"}
}

# _platform_groups_text <map> <order> [<members>]: the groups _platform_group made (<order>'s
# keys, each with its members in <map>), "<key> on <members>; ...": five groups, then "and <n>
# more members with other changes"; a group's members five named, then how many more (with
# _pl_no_members=1, dynamic scope: how many, "<n> of <members> members" when <members> is given).
# shellcheck disable=SC2329
_platform_groups_text() {
	local -n _pt_map="$1" _pt_ord="$2"
	local g v out="" i=0 more=0
	local -a _pt_w=()
	for g in ${_pt_ord[@]+"${_pt_ord[@]}"}; do
		IFS=$'\x1f' read -r -a _pt_w <<<"${_pt_map[$g]}"
		i=$((i + 1))
		if ((i > 5)); then
			more=$((more + ${#_pt_w[@]}))
			continue
		fi
		if ! ((${_pl_no_members:-0})); then
			v="$(_platform_names "${_pt_w[@]}")"
		elif [[ -n "${3:-}" ]]; then
			v="${#_pt_w[@]} of ${3} members"
		else
			v="${#_pt_w[@]} member$( ((${#_pt_w[@]} == 1)) || echo s)"
		fi
		out+="${out:+; }${g} on ${v}"
	done
	((more == 0)) || out+="; and ${more} more member$( ((more == 1)) || echo s) with other changes"
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
# merge) only the drift warning; with _pl_no_drift=1 the inputs' own values, without the drift
# marker's (what the runs recorded at their start).
# shellcheck disable=SC2329
platform_merge_by_context() {
	local key="$1" f line pair c x v cmp out="" n=0 missing=0 noun dis="" drf="" unr="" d i j unread partial differ atu=0 nokey=0
	local -a order=() pairs=() _pl_dis=() _pl_drf=() _pl_unr=() _pl_kn=() _pl_dd=() _pl_drv=()
	local -A _pl_vals=() _pl_drift=() _pl_unread_in=() _pl_ddir=() _pl_tsvv=() _pl_dend=() _pl_drvs=()
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
	for c in "${order[@]}"; do _pl_tsvv[$c]="${_pl_vals[$c]}"; done
	while IFS=$'\t' read -r d pair; do
		[[ -n "$pair" ]] || continue
		c="${pair%%=*}"
		x="${pair#*=}"
		[[ -n "${_pl_vals[$c]+set}" ]] || continue
		_pl_drift[$c]=1
		case ";${_pl_dend[$c]:-};" in *";${x};"*) ;; *) _pl_dend[$c]="${_pl_dend[$c]:-}${_pl_dend[$c]:+;}${x}" ;; esac
		[[ -n "${_pl_ddir[$d]+x}" ]] || { _pl_ddir[$d]=1; _pl_dd+=("$d"); }
		case ";${_pl_vals[$c]};" in *";${x};"*) ;; *) _pl_vals[$c]+=";${x}" ;; esac
	done < <( ((${_pl_no_drift:-0})) || _platform_drift_values "$key" "$@")
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
				_platform_build_cmp_to cmp "$key" "${_pl_kn[i]}" "${_pl_kn[j]}"
				case "$cmp" in
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
			# What it recorded at the start, and what the drift checks read at the end (the
			# digests are shortened once, in the warning).
			v="from ${_pl_tsvv[$c]//;/ or } to ${_pl_dend[$c]//;/ then }"
			_pl_drf+=("${c} ${v}")
			[[ -n "${_pl_drvs[$v]+x}" ]] || { _pl_drvs[$v]=1; _pl_drv+=("$v"); }
		elif ((differ)); then
			_pl_dis+=("${c} (${_pl_vals[$c]})")
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
		if ((${#_pl_drf[@]})); then
			drf="${#_pl_drf[@]} of ${#order[@]} members, "
			for v in "${_pl_drv[@]}"; do drf+="${v}${v:+; }"; done
			drf="${drf%; }"
		fi
		((${#_pl_unr[@]} == 0)) || unr="${#_pl_unr[@]} of ${#order[@]} members in some of the ${n}"
	else
		((${#_pl_dis[@]} == 0)) || dis="$(_platform_names "${_pl_dis[@]}")"
		((${#_pl_drf[@]} == 0)) || drf="$(_platform_names "${_pl_drf[@]}")"
		((${#_pl_unr[@]} == 0)) || unr="$(_platform_names "${_pl_unr[@]}")"
	fi
	if [[ -n "$drf" ]]; then
		platform_short_digests "warning: ${key} changed during the sweep (${PLATFORM_DRIFT_FILE} in $(_platform_names "${_pl_dd[@]}")): ${drf}; the TSVs record the value at the sweep's start, but rows measured after the change ran on other ${noun}, and the report cannot tell which rows those are; $(_platform_drift_cause "$key")" >&2
	fi
	((missing == 0)) || out="mixed:unknown,${out}"
	if ((${_pl_drift_only:-0})); then
		printf '%s\n' "$out"
		return 0
	fi
	if [[ -n "$dis" ]]; then
		platform_short_digests "warning: input TSVs disagree on ${key} for ${dis}: the report mixes runs on different ${noun}; compare like with like" >&2
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
# the tuning levers, root Sidecar egress hosts, istiod limits and istiod replica counts
# (_platform_drift_scalar_warnings), each only when the inputs record it, and what its reads at
# the end could not compare (_platform_drift_unread_warnings); and a tuning profile's objects in
# place (_platform_tuning_objects_warning). --no-members counts the members instead of naming
# them, for text that goes where context names may not (the scale envelope, pasted into campaign
# docs).
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
			TUNING_OBJECTS_BY_CONTEXT)
				# Its own warnings (drift included), then the objects the runs started with: one
				# that appeared during the sweep is the drift line's, not "in place when the run
				# started".
				platform_merge_by_context "$k" "$@" >/dev/null
				_platform_tuning_objects_warning "$(_pl_no_drift=1 platform_merge_by_context "$k" "$@" 2>/dev/null)"
				;;
			*) platform_merge_by_context "$k" "$@" >/dev/null ;;
			esac
		done
		if [[ " ${_pl_with[*]:-} " != *" KUBE_VERSIONS "* ]]; then
			_pl_drift_only=1
			platform_merge_by_context KUBE_VERSIONS "$@" >/dev/null
			_pl_drift_only=0
		fi
		_platform_drift_scalar_warnings "$@"
		_platform_drift_unread_warnings "$@"
	} 2>&1 | sed 's/^warning: //'
}

# _platform_tuning_objects_warning <TUNING_OBJECTS_BY_CONTEXT value>: one warning naming the members
# whose record holds a tuning profile's objects (platform_merge_by_context's value over the inputs'
# own records, _pl_no_drift=1: none is the chart baseline; unknown, not read, warns elsewhere) and
# the objects, five at most (platform_tuning_objects_check), or nothing. A tuning pass runs with
# its own on purpose (tuning 004 checks that each pass holds only those); any other run measured
# something else than the charts deploy (profile 04's root DestinationRule changes every proxy's
# clusters).
# shellcheck disable=SC2329
_platform_tuning_objects_warning() {
	local state who objs
	IFS=$'\t' read -r state who objs < <(platform_tuning_objects_check "$1")
	[[ "$state" == other ]] || return 0
	echo "warning: a tuning profile's objects were in place on ${who} when the run started (TUNING_OBJECTS_BY_CONTEXT: ${objs}), so unless this is a tuning pass its figures are not those of the charts' configuration; tests/tuning/005-cleanup.sh undoes them" >&2
}

# platform_tuning_objects_check <TUNING_OBJECTS_BY_CONTEXT value> [<profile> [<objects>]]: what a
# value holds against the tuning profile a run applied (none: the baseline, or a run that is no
# tuning pass), as "<state>\t<detail>\t<objects>". other: a member holds an object labelled with
# another profile (without <profile>: any object); <detail> names those members and <objects>
# those objects, five of each at most (with _pl_no_members=1, dynamic scope: how many members
# instead of their names). Else, with <profile>, missing: a value a member was read with (an
# input's, or the drift check's at the pass's end: each part of a mixed: value) lacks one of the
# profile's <objects> ("<Kind>/<ns>/<name>", "+"-joined; by default its marker, which
# tests/tuning/001-apply-profile.sh puts on every member before any change and 002 or 005 delete
# only after undoing the profile), so the profile was not in place there all along; <detail>
# names those members and <objects> the objects they lack. Else unknown: a member's objects were
# not read, or an input does not record the key; <detail> says which ("could not be read on
# <members>", "are not recorded ..."). Else own (<profile>'s objects only, every one of them) or
# none.
# shellcheck disable=SC2329
platform_tuning_objects_check() {
	local pair c input part o foreign lacks bare=0 own=0 n=0 who detail=""
	local -a _pl_p=() _pl_in=() _pl_parts=() _pl_m=() _pl_objs=() _pl_un=() _pl_want=() _pl_miss=() _pl_mo=()
	local -A _pl_o=() _pl_mos=()
	[[ -z "${2:-}" ]] ||
		IFS='+' read -r -a _pl_want <<<"${3:-${PLATFORM_TUNING_MARKER_OBJECT_KIND}/${PLATFORM_TUNING_MARKER_NS}/${PLATFORM_TUNING_MARKER_PREFIX}${2}}"
	IFS=',' read -r -a _pl_p <<<"$1"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		# unknown (no input has the key) or mixed:unknown (one has not): no member.
		if [[ "$pair" != *=* ]]; then
			bare=1
			continue
		fi
		c="${pair%%=*}" foreign=0 lacks=0 n=$((n + 1))
		IFS=';' read -r -a _pl_in <<<"${pair#*=}"
		for input in ${_pl_in[@]+"${_pl_in[@]}"}; do
			input="${input#mixed:}"
			if [[ "$input" == unknown ]]; then
				[[ " ${_pl_un[*]:-} " == *" ${c} "* ]] || _pl_un+=("$c")
				continue
			fi
			IFS='+' read -r -a _pl_parts <<<"$input"
			for part in ${_pl_parts[@]+"${_pl_parts[@]}"}; do
				case "$part" in
				none | "") ;;
				*)
					if [[ -n "${2:-}" && "${part%%:*}" == "$2" ]]; then
						own=1
						continue
					fi
					foreign=1
					[[ -n "${_pl_o[$part]+x}" ]] || { _pl_o[$part]=1; _pl_objs+=("$part"); }
					;;
				esac
			done
			for o in ${_pl_want[@]+"${_pl_want[@]}"}; do
				[[ "+${input}+" != *"+${2}:${o}+"* ]] || continue
				lacks=1
				[[ -n "${_pl_mos[$o]+x}" ]] || { _pl_mos[$o]=1; _pl_mo+=("${2}:${o}"); }
			done
		done
		((foreign == 0)) || _pl_m+=("$c")
		((lacks == 0)) || _pl_miss+=("$c")
	done
	if ((${#_pl_m[@]})); then
		if ((${_pl_no_members:-0})); then who="${#_pl_m[@]} of ${n} members"; else who="$(_platform_names "${_pl_m[@]}")"; fi
		printf 'other\t%s\t%s\n' "$who" "$(_platform_names "${_pl_objs[@]}")"
	elif ((${#_pl_miss[@]})); then
		if ((${_pl_no_members:-0})); then who="${#_pl_miss[@]} of ${n} members"; else who="$(_platform_names "${_pl_miss[@]}")"; fi
		printf 'missing\t%s\t%s\n' "$who" "$(_platform_names "${_pl_mo[@]}")"
	elif ((${#_pl_un[@]} || bare)); then
		if ((${#_pl_un[@]})); then
			if ((${_pl_no_members:-0})); then who="${#_pl_un[@]} of ${n} members"; else who="$(_platform_names "${_pl_un[@]}")"; fi
			detail="could not be read on ${who}"
		fi
		if ((bare && n == 0)); then
			detail="are not recorded (the inputs predate the key)"
		elif ((bare)); then
			detail+="${detail:+, and }are not recorded in every input (some predate the key)"
		fi
		printf 'unknown\t%s\t\n' "$detail"
	elif ((own)); then
		printf 'own\t\t\n'
	else
		printf 'none\t\t\n'
	fi
}

# platform_tuning_objects <ctx> [<dir>]: the tuning profile objects on the member, as the record
# holds them (PLATFORM_TUNING_JQ: "<profile>:<Kind>/<ns>/<name>", "+"-joined, or none), from one
# read bounded by PLATFORM_READ_TIMEOUT; return 1 with why on stderr (kubectl's first 300 bytes,
# addresses masked when reach_sanitize is there, or "the reply did not parse") when they cannot
# be listed. <dir>: a work dir (else a temp dir of its own).
# shellcheck disable=SC2329
platform_tuning_objects() {
	local w="${2:-}" own=0 rc=0 out="" why
	if [[ -z "$w" ]]; then
		w="$(mktemp -d)" || { echo "no temp dir" >&2; return 1; }
		own=1
	fi
	_platform_read "$1" "${w}/tuning.json" get "$PLATFORM_TUNING_KINDS" -A -l "$PLATFORM_TUNING_LABEL" || rc=$?
	((rc != 0)) || out="$(jq -r --arg label "$PLATFORM_TUNING_LABEL" "$PLATFORM_TUNING_JQ" "${w}/tuning.json" 2>/dev/null)" || out=""
	if [[ -z "$out" ]]; then
		[[ -s "${w}/tuning.json.err" ]] || echo "the reply did not parse" >"${w}/tuning.json.err"
		why="$(head -c 300 "${w}/tuning.json.err" 2>/dev/null)" || why=""
		! declare -F reach_sanitize >/dev/null || why="$(reach_sanitize "${why:-no answer}")"
		! _platform_timed_out "${w}/tuning.json.err" || why+="; $(_platform_timeout_hint)"
		((own == 0)) || rm -rf "$w"
		echo "${why:-no answer}" >&2
		return 1
	fi
	((own == 0)) || rm -rf "$w"
	printf '%s\n' "$out"
}

# platform_tuning_objects_refuse <ctxs_csv> <what>: die when a member holds a tuning profile's
# objects (platform_tuning_objects, PLATFORM_READ_PARALLEL members at a time), naming those members
# and objects (five of each at most) and tests/tuning/005-cleanup.sh, or when a member's cannot be
# listed: <what> ("every pass of this sweep (the baseline included)", "this profile") would be
# measured with them. Nothing in a dry-run.
# shellcheck disable=SC2329
platform_tuning_objects_refuse() {
	local i tmp v part
	local -a _pl_c=() _pl_m=() _pl_bad=() _pl_objs=() _pl_parts=()
	local -A _pl_o=()
	! ((${DRY_RUN:-0})) || return 0
	split_csv "$1" _pl_c
	((${#_pl_c[@]})) || return 0
	[[ -n "${KUBECTL[*]:-}" ]] || die "platform_tuning_objects_refuse needs KUBECTL (resolve_kubectl)"
	tmp="$(mktemp -d)" || die "no temp dir to list the tuning profile objects in"
	_platform_each platform_tuning_objects "$tmp" "${_pl_c[@]}"
	for i in "${!_pl_c[@]}"; do
		v="$(head -n 1 "${tmp}/${i}.row" 2>/dev/null || true)"
		if [[ -z "$v" ]]; then
			_pl_bad+=("${_pl_c[i]} ($(head -n 1 "${tmp}/${i}.warn" 2>/dev/null || echo "no answer"))")
			continue
		fi
		[[ "$v" != none ]] || continue
		_pl_m+=("${_pl_c[i]}")
		IFS=+ read -r -a _pl_parts <<<"$v"
		for part in ${_pl_parts[@]+"${_pl_parts[@]}"}; do
			[[ -n "${_pl_o[$part]+x}" ]] || { _pl_o[$part]=1; _pl_objs+=("$part"); }
		done
	done
	rm -rf "$tmp"
	((${#_pl_bad[@]} == 0)) ||
		die "the tuning profile objects (label ${PLATFORM_TUNING_LABEL}) could not be listed on $(_platform_names "${_pl_bad[@]}"): a member that cannot be asked may hold a profile's objects, and ${2} would be measured with them; fix the access (or raise PLATFORM_READ_TIMEOUT) and start again"
	if ((${#_pl_m[@]})); then
		die "a tuning profile's objects (label ${PLATFORM_TUNING_LABEL}) are on $(_platform_names "${_pl_m[@]}") already: $(_platform_names "${_pl_objs[@]}"). ${2^} would be measured with them. They are a tuning run still in progress on these members (wait for it to end), a profile left applied (a run stopped before its revert, in any checkout) or objects applied by hand; undo those with $(_platform_cleanup_hint "$1"), which also restores each member's Istio CR from the profile's marker, then start again"
	fi
}

# _platform_drift_scalar_findings <tsv>...: per input directory and key one of its inputs records
# (TUNING_BASELINE, SIDECAR_EGRESS_HOSTS, ISTIOD_CPU_LIMIT_M, ISTIOD_MEM_LIMIT_MI) that the
# PLATFORM_DRIFT_FILE there says changed: "<dir name>\t<key>\t<what>", <what> the value that
# input recorded at its start and each drift check's at the end (" then "-joined), or for
# TUNING_BASELINE only the levers that changed (_platform_lever_changes); then, when its inputs
# record each member's istiod replica count (the controlplane suite's ISTIOD_REPLICAS_BY_CONTEXT)
# and the file names members whose count changed, "<dir name>\tISTIOD_REPLICAS_BY_CONTEXT\t<a>
# to <b> on <members>; ..." (each member's values at the start, what those inputs recorded,
# " or "-joined, and each drift check's, " then "-joined; the members grouped by them,
# _platform_groups_text: with _pl_no_members=1, dynamic scope, how many of the members those
# inputs list, unknown included); then, when its inputs record istiod's limits and the file names
# members whose limits differ from them, "<dir name>\tISTIOD_LIMITS_DIFFER_BY_CONTEXT\t<ctx>=
# <cpu_m>/<mem_mi>,...\t<cpu_m>\t<mem_mi>" (every drift check's members, each pair once, and the
# limits recorded at the start).
# shellcheck disable=SC2329
_platform_drift_scalar_findings() {
	local f d key start name what v pair c
	local -a _pl_sd=() _pl_ends=() _pl_p=() _pl_rmo=() _pl_rgo=()
	local -A _pl_sf=() _pl_start=() _pl_rs=() _pl_re=() _pl_rg=() _pl_rall=()
	for f in "$@"; do
		d="$(dirname "$f")"
		[[ -n "${_pl_sf[$d]+x}" ]] || { _pl_sf[$d]=1; _pl_sd+=("$d"); }
		for key in TUNING_BASELINE SIDECAR_EGRESS_HOSTS ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
			[[ -z "${_pl_start["${key}|${d}"]+x}" ]] || continue
			start="$(_platform_preamble_value "$f" "$key")" || continue
			_pl_start["${key}|${d}"]="$start"
		done
	done
	for d in ${_pl_sd[@]+"${_pl_sd[@]}"}; do
		[[ -f "${d}/${PLATFORM_DRIFT_FILE}" ]] || continue
		name="$(cd "$d" 2>/dev/null && basename "$PWD")" || name="$(basename "$d")"
		for key in TUNING_BASELINE SIDECAR_EGRESS_HOSTS ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
			[[ -n "${_pl_start["${key}|${d}"]+x}" ]] || continue
			mapfile -t _pl_ends < <(sed -n "s/^# ${key}=//p" "${d}/${PLATFORM_DRIFT_FILE}")
			((${#_pl_ends[@]})) || continue
			start="${_pl_start["${key}|${d}"]}"
			what=""
			[[ "$key" != TUNING_BASELINE ]] || what="$(_platform_lever_changes "$start" "${_pl_ends[@]}")"
			[[ -n "$what" ]] || what="${start} at its start, $(_platform_then "${_pl_ends[@]}") at its end"
			printf '%s\t%s\t%s\n' "$name" "$key" "$what"
		done
		# Each member's istiod replica count: its definite values in these inputs at their start, by
		# its name in the record, and each drift check's at the end.
		mapfile -t _pl_ends < <(sed -n 's/^# ISTIOD_REPLICAS_BY_CONTEXT=//p' "${d}/${PLATFORM_DRIFT_FILE}")
		if ((${#_pl_ends[@]})); then
			_pl_rs=() _pl_re=() _pl_rg=() _pl_rmo=() _pl_rgo=() _pl_rall=()
			for f in "$@"; do
				[[ "$(dirname "$f")" == "$d" ]] || continue
				v="$(_platform_preamble_value "$f" ISTIOD_REPLICAS_BY_CONTEXT)" || continue
				IFS=',' read -r -a _pl_p <<<"$v"
				for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
					[[ "$pair" == *=* ]] || continue
					_platform_sanitize_to c "${pair%%=*}"
					_pl_rall[$c]=1
					[[ "${pair#*=}" != unknown ]] || continue
					_platform_alt_add _pl_rs "$c" "${pair#*=}"
				done
			done
			for v in "${_pl_ends[@]}"; do
				IFS=',' read -r -a _pl_p <<<"$v"
				for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
					[[ "$pair" == *=* ]] || continue
					_platform_sanitize_to c "${pair%%=*}"
					[[ -n "${_pl_rs[$c]+x}" ]] || continue
					[[ -n "${_pl_re[$c]+x}" ]] || _pl_rmo+=("$c")
					_platform_alt_add _pl_re "$c" "${pair#*=}"
				done
			done
			for c in ${_pl_rmo[@]+"${_pl_rmo[@]}"}; do
				_platform_group _pl_rg _pl_rgo "${_pl_rs[$c]//;/ or } to ${_pl_re[$c]//;/ then }" "$c"
			done
			# Without member names (platform_report_warnings --no-members): how many of the members
			# those inputs list, one whose count at the start is unknown too (as the unread warning
			# beside it counts them).
			what="$(_platform_groups_text _pl_rg _pl_rgo "${#_pl_rall[@]}")"
			[[ -z "$what" ]] || printf '%s\t%s\t%s\n' "$name" ISTIOD_REPLICAS_BY_CONTEXT "$what"
		fi
		[[ -n "${_pl_start["ISTIOD_CPU_LIMIT_M|${d}"]+x}${_pl_start["ISTIOD_MEM_LIMIT_MI|${d}"]+x}" ]] || continue
		# Every drift check's members (a --resume runs one more), each pair once.
		what="$(sed -n 's/^# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=//p' "${d}/${PLATFORM_DRIFT_FILE}" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)"
		[[ -n "$what" ]] || continue
		printf '%s\t%s\t%s\t%s\t%s\n' "$name" ISTIOD_LIMITS_DIFFER_BY_CONTEXT "$what" \
			"${_pl_start["ISTIOD_CPU_LIMIT_M|${d}"]:-unknown}" "${_pl_start["ISTIOD_MEM_LIMIT_MI|${d}"]:-unknown}"
	done
}

# _platform_drift_scalar_warnings <tsv>...: a warning per finding of
# _platform_drift_scalar_findings, for a sweep's reports: a changed lever, root Sidecar egress
# host, istiod limit or member's istiod replica count with what it does to the rows; members
# whose istiod limits differ from the recorded ones with what the controlplane report divides
# by them.
# shellcheck disable=SC2329
_platform_drift_scalar_warnings() {
	local name key what a b
	while IFS=$'\t' read -r name key what a b; do
		case "$key" in
		ISTIOD_LIMITS_DIFFER_BY_CONTEXT)
			echo "warning: $(_platform_limits_differ "$what" "$a" "$b" "the TSVs recorded on their source member") at the end of the sweep in ${name} (${PLATFORM_DRIFT_FILE}), but the report divides the window-peak CPU and RSS % of every member's rows (and the SLA verdict on them) by the recorded ones, so those members' rows read against another limit; the kubectl top % use each row's own; $(_platform_limits_cause)" >&2
			continue
			;;
		ISTIOD_CPU_LIMIT_M | ISTIOD_MEM_LIMIT_MI) what+="; rows measured after the change ran under another limit, but $(_platform_limit_figure "$key") divides by the one recorded at the start, as does the SLA verdict on it, and the report cannot tell which rows those are; the kubectl top % use each row's own limit" ;;
		ISTIOD_REPLICAS_BY_CONTEXT) what+="; rows measured after the change ran with another istiod replica count; the report's istiod replicas show the count recorded at the start, while each cell's own count of istiod pods is in the csv's istiod_pods_avg, the json's istiod_pods_per_cluster_avg and the growth table's istiod pods / cluster" ;;
		*) what+="; rows measured after the change ran with other $(_platform_noun "$key"), and the report cannot tell which rows those are" ;;
		esac
		echo "warning: ${key} changed during the sweep in ${name} (${PLATFORM_DRIFT_FILE}): ${what}; $(_platform_drift_cause "$key")" >&2
	done < <(_platform_drift_scalar_findings "$@")
}

# platform_drift_changes <tsv>...: what the reads at the end (platform_drift_check) found changed,
# from the PLATFORM_DRIFT_FILE next to these inputs, for a report that words its own warnings
# (tuning 004, one pass's TSVs at a time): one line per key, "<KEY>\t<noun>\t<what>", in
# PLATFORM_ROW_KEYS order, then KUBE_VERSIONS, TUNING_BASELINE, SIDECAR_EGRESS_HOSTS,
# ISTIOD_CPU_LIMIT_M, ISTIOD_MEM_LIMIT_MI and ISTIOD_REPLICAS_BY_CONTEXT; <noun> says what its
# values are ("Kubernetes versions"). For a key that lists each member, <what> groups the members
# by their value at the start (what the inputs recorded) and at the end, "<a> to <b> on <members>"
# (_platform_groups_text: five groups, five named a group; digests shortened; istiod's replica
# counts by _platform_drift_scalar_findings); for the others, _platform_drift_scalar_findings'
# (on the member the inputs read them on). Only a key the inputs record; not
# ISTIOD_LIMITS_DIFFER_BY_CONTEXT, which says how the members differ at the end, not what changed
# (nothing records another member's limits at the start): platform_lever_values gives each
# member's. Nothing, without merging anything, when no input has the file next to it, or none of
# those files holds a value (only DRIFT_READ_AT and NOT_COMPARED_AT_END: nothing changed).
# shellcheck disable=SC2329
platform_drift_changes() {
	local k pair c x out f d any=0
	local -a _pl_p=() _pl_mo=() _pl_cgo=()
	local -A _pl_s=() _pl_e=() _pl_cg=() _pl_dseen=()
	for f in "$@"; do
		d="$(dirname "$f")"
		[[ -z "${_pl_dseen[$d]+x}" ]] || continue
		_pl_dseen[$d]=1
		awk '/^# [A-Z_]+=/ && !/^# (DRIFT_READ_AT|NOT_COMPARED_AT_END)=/ { found = 1; exit } END { exit !found }' \
			"${d}/${PLATFORM_DRIFT_FILE}" 2>/dev/null || continue
		any=1
		break
	done
	((any)) || return 0
	for k in "${PLATFORM_ROW_KEYS[@]}" KUBE_VERSIONS; do
		_pl_s=() _pl_e=() _pl_cg=()
		_pl_mo=() _pl_cgo=()
		# Each member's values at the start: the inputs' own, without the drift file's.
		IFS=',' read -r -a _pl_p <<<"$(_pl_no_drift=1 platform_merge_by_context "$k" "$@" 2>/dev/null)"
		for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
			[[ "$pair" == *=* ]] || continue
			x="${pair#*=}"
			_pl_s[${pair%%=*}]="${x#mixed:}"
		done
		while IFS=$'\t' read -r _ pair; do
			[[ "$pair" == *=* ]] || continue
			c="${pair%%=*}"
			[[ -n "${_pl_s[$c]+x}" ]] || continue
			[[ -n "${_pl_e[$c]+x}" ]] || _pl_mo+=("$c")
			case ";${_pl_e[$c]:-};" in *";${pair#*=};"*) ;; *) _pl_e[$c]="${_pl_e[$c]:-}${_pl_e[$c]:+;}${pair#*=}" ;; esac
		done < <(_platform_drift_values "$k" "$@")
		((${#_pl_mo[@]})) || continue
		for c in "${_pl_mo[@]}"; do
			_platform_group _pl_cg _pl_cgo "${_pl_s[$c]//;/ or } to ${_pl_e[$c]//;/ then }" "$c"
		done
		out="$(_platform_groups_text _pl_cg _pl_cgo)"
		printf '%s\t%s\t%s\n' "$k" "$(_platform_noun "$k")" "$(platform_short_digests "$out")"
	done
	while IFS=$'\t' read -r _ k x _; do
		[[ "$k" != ISTIOD_LIMITS_DIFFER_BY_CONTEXT ]] || continue
		printf '%s\t%s\t%s\n' "$k" "$(_platform_noun "$k")" "$x"
	done < <(_platform_drift_scalar_findings "$@")
}

# platform_lever_values <tsv>...: KEY=value for what a tuning pass's inputs record outside the
# platform record and tuning 004 compares between passes, each only when an input records it:
# TUNING_BASELINE lever by lever (<lever>=<value>,...) and SIDECAR_EGRESS_HOSTS
# (tuning_baseline_state, on the member the inputs read them on: the first of their record);
# istiod's limits per replica on each member of their record, ISTIOD_CPU_LIMIT_M_BY_CONTEXT (m) and
# ISTIOD_MEM_LIMIT_MI_BY_CONTEXT (Mi): on that member the inputs' ISTIOD_CPU_LIMIT_M and
# ISTIOD_MEM_LIMIT_MI, on every other member the same, unless the read at the end
# (platform_drift_check: the PLATFORM_DRIFT_FILE next to the inputs) found others there
# (ISTIOD_LIMITS_DIFFER_BY_CONTEXT): an other member's are its limits at the end, since nothing
# records them at the start; unknown where that read could not read them (NOT_COMPARED_AT_END), or
# without the file (nothing read them); and ISTIOD_REPLICAS_BY_CONTEXT, istiod's replicas at the
# start on each member the inputs record them for: the controlplane suite's
# ISTIOD_REPLICAS_BY_CONTEXT (the Deployment's replicas, every member), else ISTIOD_REPLICAS as
# propagation records it (<ctx>=<n>,...: the Running istiod pods, every member) or as churn and
# churn-dataplane do (<n>: the source member's, the first of their record), each member by its
# name in the record, with the count the read at the end found there where it changed (the
# controlplane suite's: platform_drift_check reads the Deployments again). A value the inputs
# disagree on, that one of them does not record, or that the read at the end found changed holds
# each (unknown for an input without the key): mixed:<a>;<b> for a lever or a member,
# mixed:<a>,<b> for the egress hosts.
# shellcheck disable=SC2329
platform_lever_values() {
	local f d v lv k c x line out src="" fsrc rbare="" nbare=0 n=0 drift=0
	local -a _pl_p=() _pl_lo=() _pl_mo=() _pl_dd=() _pl_ro=()
	local -A _pl_lv=() _pl_has=() _pl_ddir=() _pl_rec=() _pl_src=() _pl_dl=() _pl_nc=() _pl_in=()
	local -A _pl_rep=() _pl_rn=() _pl_rf=()
	for f in "$@"; do
		n=$((n + 1))
		d="$(dirname "$f")"
		[[ -n "${_pl_ddir[$d]+x}" ]] || { _pl_ddir[$d]=1; _pl_dd+=("$d"); }
		if v="$(_platform_preamble_value "$f" TUNING_BASELINE)"; then
			_pl_has[TUNING_BASELINE]=$((${_pl_has[TUNING_BASELINE]:-0} + 1))
			IFS=',' read -r -a _pl_p <<<"$v"
			for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$lv" == *=* ]] || continue
				[[ -n "${_pl_lv[${lv%%=*}]+x}" ]] || _pl_lo+=("${lv%%=*}")
				_platform_alt_add _pl_lv "${lv%%=*}" "${lv#*=}"
			done
		fi
		for k in SIDECAR_EGRESS_HOSTS ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
			v="$(_platform_preamble_value "$f" "$k")" || continue
			_pl_has[$k]=$((${_pl_has[$k]:-0} + 1))
			_platform_alt_add _pl_rec "$k" "$v"
		done
		# The members of its record; the first is the one it read the levers and limits on.
		fsrc=""
		if v="$(_platform_preamble_value "$f" PLATFORM_BY_CONTEXT)"; then
			IFS=',' read -r -a _pl_p <<<"$v"
			for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$lv" == *=* ]] || continue
				c="${lv%%=*}"
				[[ -n "$fsrc" ]] || fsrc="$c"
				[[ -n "$src" ]] || src="$c"
				[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_mo+=("$c"); }
			done
		fi
		# istiod's replicas, in the form its suite records them: per member, or the source member's.
		if v="$(_platform_preamble_value "$f" ISTIOD_REPLICAS_BY_CONTEXT)" && [[ "$v" == *=* ]]; then
			:
		elif v="$(_platform_preamble_value "$f" ISTIOD_REPLICAS)"; then
			[[ "$v" == *=* || -z "$fsrc" ]] || v="${fsrc}=${v}"
		else
			continue
		fi
		_pl_has[ISTIOD_REPLICAS]=1
		_pl_rf=()
		IFS=',' read -r -a _pl_p <<<"$v"
		for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
			if [[ "$lv" != *=* ]]; then
				# No record to name its member (an input from before the record): a value without one.
				nbare=$((nbare + 1))
				case ";${rbare};" in *";${lv};"*) ;; *) rbare+="${rbare:+;}${lv}" ;; esac
				continue
			fi
			_platform_sanitize_to c "${lv%%=*}"
			[[ -z "${_pl_rf[$c]+x}" ]] || continue
			_pl_rf[$c]=1
			[[ -n "${_pl_rn[$c]+x}" ]] || _pl_ro+=("$c")
			_pl_rn[$c]=$((${_pl_rn[$c]:-0} + 1))
			_platform_alt_add _pl_rep "$c" "${lv#*=}"
		done
	done
	((${#_pl_has[@]})) || return 0
	# An input without a key that others record did not read it.
	if ((${_pl_has[TUNING_BASELINE]:-0} && ${_pl_has[TUNING_BASELINE]:-0} < n)); then
		for k in ${_pl_lo[@]+"${_pl_lo[@]}"}; do _platform_alt_add _pl_lv "$k" unknown; done
	fi
	for k in SIDECAR_EGRESS_HOSTS ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
		((${_pl_has[$k]:-0} == 0 || ${_pl_has[$k]:-0} == n)) || _platform_alt_add _pl_rec "$k" unknown
	done
	# The member they read the limits on: what they recorded, then what the reads at the end found.
	for k in ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
		[[ -z "${_pl_rec[$k]+x}" ]] || _pl_src[$k]="${_pl_rec[$k]}"
	done
	for d in ${_pl_dd[@]+"${_pl_dd[@]}"}; do
		[[ -f "${d}/${PLATFORM_DRIFT_FILE}" ]] || continue
		drift=1
		while IFS= read -r line; do
			line="${line#\# }"
			v="${line#*=}"
			case "${line%%=*}" in
			TUNING_BASELINE)
				# Every lever's value at the end (one changed); a lever the inputs did not read was
				# not compared.
				IFS=',' read -r -a _pl_p <<<"$v"
				for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
					[[ "$lv" == *=* ]] || continue
					x="${_pl_lv[${lv%%=*}]:-unknown}"
					[[ "${lv#*=}" == unknown || "$x" == unknown ]] || _platform_alt_add _pl_lv "${lv%%=*}" "${lv#*=}"
				done
				;;
			SIDECAR_EGRESS_HOSTS) [[ -z "${_pl_rec[SIDECAR_EGRESS_HOSTS]+x}" ]] || _platform_alt_add _pl_rec SIDECAR_EGRESS_HOSTS "$v" ;;
			ISTIOD_CPU_LIMIT_M | ISTIOD_MEM_LIMIT_MI)
				k="${line%%=*}"
				[[ -z "${_pl_src[$k]+x}" ]] || _platform_alt_add _pl_src "$k" "$v"
				;;
			ISTIOD_REPLICAS_BY_CONTEXT)
				# A member's count at the end, where it changed: another value it ran.
				IFS=',' read -r -a _pl_p <<<"$v"
				for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
					[[ "$lv" == *=* ]] || continue
					_platform_sanitize_to c "${lv%%=*}"
					[[ -z "${_pl_rep[$c]+x}" ]] || _platform_alt_add _pl_rep "$c" "${lv#*=}"
				done
				;;
			ISTIOD_LIMITS_DIFFER_BY_CONTEXT)
				IFS=',' read -r -a _pl_p <<<"$v"
				for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
					[[ "$lv" == *=*/* ]] || continue
					x="${lv#*=}"
					_platform_alt_add _pl_dl "ISTIOD_CPU_LIMIT_M|${lv%%=*}" "${x%%/*}"
					_platform_alt_add _pl_dl "ISTIOD_MEM_LIMIT_MI|${lv%%=*}" "${x#*/}"
				done
				;;
			NOT_COMPARED_AT_END)
				IFS=',' read -r -a _pl_p <<<"$v"
				for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
					[[ ";${lv#*=};" != *";ISTIOD_LIMITS_DIFFER_BY_CONTEXT;"* ]] || _pl_nc[${lv%%=*}]=1
				done
				;;
			esac
		done <"${d}/${PLATFORM_DRIFT_FILE}"
	done
	# Each value as one (_platform_alts_value, without a subshell per member: hundreds of members).
	if [[ -n "${_pl_has[TUNING_BASELINE]+x}" ]]; then
		out=""
		for k in ${_pl_lo[@]+"${_pl_lo[@]}"}; do
			x="${_pl_lv[$k]}"
			[[ "$x" != *";"* ]] || x="mixed:${x}"
			out+="${out:+,}${k}=${x}"
		done
		printf 'TUNING_BASELINE=%s\n' "${out:-unknown}"
	fi
	[[ -z "${_pl_has[SIDECAR_EGRESS_HOSTS]+x}" ]] ||
		printf 'SIDECAR_EGRESS_HOSTS=%s\n' "$(_platform_alts_value "${_pl_rec[SIDECAR_EGRESS_HOSTS]}" ,)"
	for k in ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
		[[ -n "${_pl_has[$k]+x}" ]] || continue
		out=""
		for c in ${_pl_mo[@]+"${_pl_mo[@]}"}; do
			if [[ "$c" == "$src" ]]; then
				x="${_pl_src[$k]}"
			elif ((drift == 0)) || [[ -n "${_pl_nc[$c]+x}" ]]; then
				x=unknown
			else
				x="${_pl_dl["${k}|${c}"]:-${_pl_rec[$k]}}"
			fi
			[[ "$x" != *";"* ]] || x="mixed:${x}"
			out+="${out:+,}${c}=${x}"
		done
		# Inputs without a record: the value without a member.
		[[ -n "$out" ]] || out="$(_platform_alts_value "${_pl_src[$k]}" ';')"
		if [[ "$k" == ISTIOD_CPU_LIMIT_M ]]; then printf 'ISTIOD_CPU_LIMIT_M_BY_CONTEXT=%s\n' "$out"; else printf 'ISTIOD_MEM_LIMIT_MI_BY_CONTEXT=%s\n' "$out"; fi
	done
	# istiod's replicas: a member an input does not record (or an input without the key) was not read
	# there.
	if [[ -n "${_pl_has[ISTIOD_REPLICAS]+x}" ]]; then
		out=""
		if [[ -n "$rbare" ]]; then
			((nbare == n)) || case ";${rbare};" in *";unknown;"*) ;; *) rbare+=";unknown" ;; esac
			out="$rbare"
			[[ "$out" != *";"* ]] || out="mixed:${out}"
		fi
		for c in ${_pl_ro[@]+"${_pl_ro[@]}"}; do
			((${_pl_rn[$c]} == n)) || _platform_alt_add _pl_rep "$c" unknown
			x="${_pl_rep[$c]}"
			[[ "$x" != *";"* ]] || x="mixed:${x}"
			out+="${out:+,}${c}=${x}"
		done
		printf 'ISTIOD_REPLICAS_BY_CONTEXT=%s\n' "$out"
	fi
}

# platform_drift_unread <tsv>...: what the reads at the end (platform_drift_check) could not
# compare, from the PLATFORM_DRIFT_FILE next to these inputs (NOT_COMPARED_AT_END: not read at
# the start or the end, or a digest @unknown; a lever as "TUNING_BASELINE <lever>";
# ISTIOD_LIMITS_DIFFER_BY_CONTEXT for a member whose istiod limits it could not read;
# ISTIOD_REPLICAS_BY_CONTEXT for a member whose replica count it could not read): one line
# per key, "<KEY>\t<members>", in the order they first appear, the members five named, then how
# many more (with _pl_no_members=1, dynamic scope: how many, "1 of 2 members" when the inputs
# record their members). Nothing without such a line.
# shellcheck disable=SC2329
platform_drift_unread() {
	local f d pair c k v m
	local -a _pl_dd=() _pl_p=() _pl_q=() _pl_ko=() _pl_w=()
	local -A _pl_ddir=() _pl_km=() _pl_seen=() _pl_rmem=()
	for f in "$@"; do
		d="$(dirname "$f")"
		[[ -n "${_pl_ddir[$d]+x}" ]] || { _pl_ddir[$d]=1; _pl_dd+=("$d"); }
		# Without names, the members of their record count them.
		((${_pl_no_members:-0})) || continue
		v="$(_platform_preamble_value "$f" PLATFORM_BY_CONTEXT)" || continue
		IFS=',' read -r -a _pl_p <<<"$v"
		for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
			[[ "$pair" != *=* ]] || _pl_rmem[${pair%%=*}]=1
		done
	done
	for d in ${_pl_dd[@]+"${_pl_dd[@]}"}; do
		while IFS= read -r pair; do
			IFS=',' read -r -a _pl_p <<<"$pair"
			for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$pair" == *=* ]] || continue
				c="${pair%%=*}"
				IFS=';' read -r -a _pl_q <<<"${pair#*=}"
				for k in ${_pl_q[@]+"${_pl_q[@]}"}; do
					[[ -n "$k" && -z "${_pl_seen["${k}|${c}"]+x}" ]] || continue
					_pl_seen["${k}|${c}"]=1
					[[ -n "${_pl_km[$k]+x}" ]] || _pl_ko+=("$k")
					_pl_km[$k]="${_pl_km[$k]:-}${_pl_km[$k]:+ }${c}"
				done
			done
		done < <(sed -n 's/^# NOT_COMPARED_AT_END=//p' "${d}/${PLATFORM_DRIFT_FILE}" 2>/dev/null)
	done
	m="${#_pl_rmem[@]}"
	for k in ${_pl_ko[@]+"${_pl_ko[@]}"}; do
		read -r -a _pl_w <<<"${_pl_km[$k]}"
		if ((${_pl_no_members:-0})) && ((m >= ${#_pl_w[@]} && m > 0)); then
			printf '%s\t%d of %d members\n' "$k" "${#_pl_w[@]}" "$m"
		elif ((${_pl_no_members:-0})); then
			printf '%s\t%d member%s\n' "$k" "${#_pl_w[@]}" "$( ((${#_pl_w[@]} == 1)) || echo s)"
		else
			printf '%s\t%s\n' "$k" "$(_platform_names "${_pl_w[@]}")"
		fi
	done
}

# _platform_drift_unread_warnings <tsv>...: for a sweep's reports, one warning per input directory
# whose reads at the end could not compare a value (platform_drift_unread).
# shellcheck disable=SC2329
_platform_drift_unread_warnings() {
	local f d k who out lim name
	local -a _pl_dd=()
	local -A _pl_df=()
	for f in "$@"; do
		d="$(dirname "$f")"
		[[ -n "${_pl_df[$d]+x}" ]] || { _pl_df[$d]="$f"; _pl_dd+=("$d"); }
	done
	for d in ${_pl_dd[@]+"${_pl_dd[@]}"}; do
		out="" lim=""
		while IFS=$'\t' read -r k who; do
			[[ -n "$k" ]] || continue
			if [[ "$k" == ISTIOD_LIMITS_DIFFER_BY_CONTEXT ]]; then
				lim="istiod's limits on ${who} (not read at its end)"
			else
				out+="${out:+; }${k} on ${who}"
			fi
		done < <(platform_drift_unread "${_pl_df[$d]}")
		[[ -z "$out" ]] || out+=" (not read at its start or end, or read with a digest @unknown: no pod had started)"
		[[ -z "$lim" ]] || out+="${out:+; }${lim}"
		[[ -n "$out" ]] || continue
		name="$(cd "$d" 2>/dev/null && basename "$PWD")" || name="$(basename "$d")"
		echo "warning: the read again at the end of the sweep in ${name} (${PLATFORM_DRIFT_FILE}) could not compare ${out}, so whether those changed during the sweep is not known; the report shows the values the TSVs recorded at its start" >&2
	done
}

# _platform_limit_figure <ISTIOD_CPU_LIMIT_M|ISTIOD_MEM_LIMIT_MI>: the controlplane report's one
# figure that divides by that recorded limit (the peak over every member's rows).
# shellcheck disable=SC2329
_platform_limit_figure() {
	if [[ "$1" == ISTIOD_CPU_LIMIT_M ]]; then echo "the report's window-peak CPU % (the highest istiod CPU of every member's rows)"; else echo "the report's RSS % (the highest istiod RSS of every member's rows)"; fi
}

# _platform_limits_member <ctx> <dir>: istiod's limits on the member (cap_istiod_limits), for
# _platform_each; read once more when a limit reads unknown (its read timed out, say).
# shellcheck disable=SC2329
_platform_limits_member() {
	local lim
	lim="$(cap_istiod_limits "$1" "${KUBECTL[@]}")"
	[[ "$(_platform_kv "$lim" cpu_m)" != unknown && "$(_platform_kv "$lim" mem_mi)" != unknown ]] ||
		lim="$(cap_istiod_limits "$1" "${KUBECTL[@]}")"
	printf '%s\n' "$lim"
}

# _platform_limits_differ <ctx>=<cpu_m>/<mem_mi>,... <recorded cpu_m> <recorded mem_mi> <where>:
# "istiod's limits per replica on <members> (CPU <c>m, memory <m>Mi; ...) differ from those
# <where> (CPU <c>m, memory <m>Mi)": the members grouped by their limits, five names a group and
# five groups at most, then how many more (with _pl_no_members=1, dynamic scope: how many members
# a group has, not their names).
# shellcheck disable=SC2329
_platform_limits_differ() {
	local pair v g out="" i=0 more=0
	local -a _pl_p=() _pl_g=() _pl_w=()
	local -A _pl_by=()
	IFS=',' read -r -a _pl_p <<<"$1"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		[[ "$pair" == *=* ]] || continue
		v="${pair#*=}"
		[[ -n "${_pl_by[$v]+x}" ]] || _pl_g+=("$v")
		_pl_by[$v]+="${_pl_by[$v]:+ }${pair%%=*}"
	done
	for g in ${_pl_g[@]+"${_pl_g[@]}"}; do
		read -r -a _pl_w <<<"${_pl_by[$g]}"
		i=$((i + 1))
		if ((i > 5)); then
			more=$((more + ${#_pl_w[@]}))
			continue
		fi
		if ((${_pl_no_members:-0})); then v="${#_pl_w[@]} member$( ((${#_pl_w[@]} == 1)) || echo s)"; else v="$(_platform_names "${_pl_w[@]}")"; fi
		out+="${out:+; }${v} (CPU $(_platform_limit_text "${g%%/*}" m), memory $(_platform_limit_text "${g#*/}" Mi))"
	done
	((more == 0)) || out+="; and ${more} more member$( ((more == 1)) || echo s) under other limits"
	printf "istiod's limits per replica on %s differ from those %s (CPU %s, memory %s)\n" "$out" "$4" \
		"$(_platform_limit_text "${2//;/ or }" m)" "$(_platform_limit_text "${3//;/ or }" Mi)"
}

# _platform_limit_text <value> <unit>: the value with its unit, or unknown.
# shellcheck disable=SC2329
_platform_limit_text() {
	if [[ "$1" == unknown || -z "$1" ]]; then echo unknown; else echo "${1}${2}"; fi
}

# _platform_limits_cause: what usually leaves istiod's limits different between members, and the
# way out.
# shellcheck disable=SC2329
_platform_limits_cause() {
	echo "the usual cause is a per-member change of istiod's resources (a hand edit of the Istio CR's spec.values.pilot.resources, a tuning profile applied to some members, or an Argo CD sync that reached some members only); for publishable figures, run the sweep again with the same istiod limits on every member"
}

# _platform_then <value>...: the values " then "-joined (the drift checks of one sweep dir, in
# the order they ran).
# shellcheck disable=SC2329
_platform_then() {
	local out="" v
	for v in "$@"; do out+="${out:+ then }${v}"; done
	printf '%s\n' "$out"
}

# _platform_lever_changes <start> <end>...: the TUNING_BASELINE levers (lever=value,...) whose
# value at an end differs from <start>'s, as "sidecar from on to off" (the ends " then "-joined:
# "sidecar from on to off then on"), ", "-separated; a lever not read (unknown) on a side is left
# out. Nothing when none differs.
# shellcheck disable=SC2329
_platform_lever_changes() {
	local start="$1" e lv k out="" seq diff
	local -a _pl_lo=() _pl_p=()
	local -A _pl_sv=() _pl_seq=()
	shift
	IFS=',' read -r -a _pl_p <<<"$start"
	for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
		[[ "$lv" == *=* ]] || continue
		_pl_lo+=("${lv%%=*}")
		_pl_sv[${lv%%=*}]="${lv#*=}"
	done
	for e in "$@"; do
		IFS=',' read -r -a _pl_p <<<"$e"
		for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
			[[ "$lv" == *=* ]] || continue
			k="${lv%%=*}"
			_pl_seq[$k]+="${_pl_seq[$k]:+ then }${lv#*=}"
		done
	done
	for k in ${_pl_lo[@]+"${_pl_lo[@]}"}; do
		[[ "${_pl_sv[$k]}" != unknown && -n "${_pl_seq[$k]:-}" ]] || continue
		seq="${_pl_seq[$k]}"
		diff=0
		IFS=' ' read -r -a _pl_p <<<"${seq// then / }"
		for e in ${_pl_p[@]+"${_pl_p[@]}"}; do
			[[ "$e" == unknown || "$e" == "${_pl_sv[$k]}" ]] || diff=1
		done
		((diff)) || continue
		out+="${out:+, }${k} from ${_pl_sv[$k]} to ${seq}"
	done
	printf '%s\n' "$out"
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
# "# key: value" (text), key: "value" (markdown front matter, through yaml_str), "| KEY |
# `value` |" (a markdown table row, through md_cell), or one compact JSON object with lowercase
# keys. A value from a hand-edited TSV keeps the front matter parseable and the row one row.
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

# platform_help_lines <all|reads>: the lines a sweep's --help adds to its Environment section
# for the platform record's knobs, with their current values (config/options.env): with "all",
# TEST_PLATFORM, PLATFORM_READ_TIMEOUT and PLATFORM_READ_PARALLEL; with "reads", the last two
# only (a script that describes TEST_PLATFORM its own way). Every caller names one (shellcheck's
# SC2119 flags a call without an argument).
# shellcheck disable=SC2329
platform_help_lines() {
	[[ "${1:-}" == reads ]] || cat <<EOF
  TEST_PLATFORM (auto, kubernetes or openshift; ${TEST_PLATFORM:-auto}): whether a member gets
  the suite chart's values-openshift.yaml; auto asks each member, and a --dry-run renders
  kubernetes. The platform record asks each member what it serves either way.
EOF
	cat <<EOF
  PLATFORM_READ_TIMEOUT (${PLATFORM_READ_TIMEOUT:-20s}): the bound on each read of the
  platform record (kubectl --request-timeout); raise it for members with many nodes or a
  slow link.
  PLATFORM_READ_PARALLEL (${PLATFORM_READ_PARALLEL:-20}): how many members' platform records
  are read at once (a few kubectl calls each; also their tuning objects, and istiod's limits
  and replica counts read again at a run's end); lower it when the machine running the suite
  runs short of memory or processes on a large mesh. The Kubernetes versions, and istiod's
  replicas at a run's start, are read on every member at once.
EOF
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

# _platform_bare_text <token>: a token without a member, as tuning 004's notes show it:
# mixed:unknown (some of a pass's inputs predate the key; platform_report_values) reads "not
# recorded in some of its TSVs", which the cell's unknown stands for; mixed:<a>;<b> (counts from
# before the record that disagree) "mixed: <a> and <b>"; any other as it is.
_platform_bare_text() {
	local x
	case "$1" in
	mixed:unknown) printf '%s\n' "not recorded in some of its TSVs" ;;
	mixed:*";"*)
		x="${1#mixed:}"
		printf 'mixed: %s\n' "${x//;/ and }"
		;;
	*) printf '%s\n' "$1" ;;
	esac
}

# platform_members_by_value <by_context value>: each value with the members that have it, five
# named (then how many more), "; "-joined in the order they first appear, digests shortened: a
# member whose inputs disagree reads "mixed: <a> and <b>". A token without a member comes first
# (_platform_bare_text: mixed:unknown, some inputs predate the key, reads "not recorded in some of
# its TSVs"; counts from before the record that disagree read "mixed: <a> and <b>").
# shellcheck disable=SC2329
platform_members_by_value() {
	local pair x out=""
	local -a _pl_p=() _pl_mo=()
	local -A _pl_mv=()
	IFS=',' read -r -a _pl_p <<<"$1"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		if [[ "$pair" != *=* ]]; then
			out+="${out:+; }$(_platform_bare_text "$pair")"
			continue
		fi
		x="${pair#*=}"
		[[ "$x" != mixed:* ]] || { x="${x#mixed:}"; x="mixed: ${x//;/ and }"; }
		_platform_group _pl_mv _pl_mo "$x" "${pair%%=*}"
	done
	for x in ${_pl_mo[@]+"${_pl_mo[@]}"}; do
		out+="${out:+; }${x} on $(_platform_group_names "${_pl_mv[$x]}")"
	done
	platform_short_digests "$out"
}

# platform_summary <by_context value>: the value without member names (the scale envelope is
# pasted into campaign docs): the one value every member shares, else each distinct value with
# its member count, ", "-separated ("pilot:1.30.5 (2 members), pilot:1.30.6 (1 member)"); a
# member whose inputs disagree reads "mixed: <a> and <b>"; digests shortened. A token without
# a member (some inputs predate the record) comes first, as one too when its inputs disagree.
# shellcheck disable=SC2329
platform_summary() {
	local pair v out="" i
	local -a _pl_p=() _pl_order=()
	local -A _pl_cnt=()
	IFS=',' read -r -a _pl_p <<<"$1"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		if [[ "$pair" != *=* ]]; then
			[[ "$pair" != mixed:*";"* ]] || { v="${pair#mixed:}"; pair="mixed: ${v//;/ and }"; }
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

# _platform_per_member <key>: return 0 for a key whose value lists each member (<ctx>=<value>,...):
# every *_BY_CONTEXT key, and KUBE_VERSIONS.
# shellcheck disable=SC2329
_platform_per_member() {
	[[ "$1" == *_BY_CONTEXT || "$1" == KUBE_VERSIONS ]]
}

# _platform_alt_add <map name> <key> <value>: add the value to the map's <key>, ";"-joined, once.
# shellcheck disable=SC2329
_platform_alt_add() {
	local -n _pl_aam="$1"
	case ";${_pl_aam[$2]:-};" in
	*";${3};"*) ;;
	*) _pl_aam[$2]="${_pl_aam[$2]:-}${_pl_aam[$2]:+;}${3}" ;;
	esac
}

# _platform_alts_value <values> <sep>: ";"-joined values as one value: the one, else
# mixed:<a><sep><b>.
# shellcheck disable=SC2329
_platform_alts_value() {
	if [[ "$1" != *";"* ]]; then printf '%s\n' "$1"; else printf 'mixed:%s\n' "${1//;/$2}"; fi
}

# _platform_alt_cmp_to <name> <key> <ref value> <value> <sep>: same, differs or unknown into
# variable <name> (_platform_build_cmp_to), for two values either of which may hold more than
# one (mixed:<a><sep><b>: inputs that disagree, or a value the read at an end found changed):
# same when one of the reference's is the same build as one of the other's (a tuning pass ran a
# build the reference pass started or ended with; the reference pass's own warning covers its
# mix, and a pass's own covers its), else differs when a pair differs, else unknown. Two values
# without mixed: compare as _platform_build_cmp_to does.
# shellcheck disable=SC2329
_platform_alt_cmp_to() {
	# Every local is _pl_a*: <name> is the caller's variable (r, res), which a local of the same
	# name here would hide from printf -v.
	local _pl_ao="$1" _pl_ak="$2" _pl_ax _pl_ay _pl_ac _pl_ar=unknown
	local -a _pl_aa=() _pl_ab=()
	if [[ "$3" != mixed:* && "$4" != mixed:* ]]; then
		_platform_build_cmp_to "$_pl_ao" "$_pl_ak" "$3" "$4"
		return 0
	fi
	IFS="$5" read -r -a _pl_aa <<<"${3#mixed:}"
	IFS="$5" read -r -a _pl_ab <<<"${4#mixed:}"
	for _pl_ax in ${_pl_aa[@]+"${_pl_aa[@]}"}; do
		for _pl_ay in ${_pl_ab[@]+"${_pl_ab[@]}"}; do
			_platform_build_cmp_to _pl_ac "$_pl_ak" "$_pl_ax" "$_pl_ay"
			case "$_pl_ac" in
			same)
				printf -v "$_pl_ao" same
				return 0
				;;
			differs) _pl_ar=differs ;;
			esac
		done
	done
	printf -v "$_pl_ao" '%s' "$_pl_ar"
}

# _platform_compare_key <key> <ref value> <value>: same, differs or unknown for one key of two
# platform_report_values outputs (a record key, KUBE_VERSIONS, or a key of
# platform_lever_values), by _platform_alt_cmp_to (a value that holds more than one, mixed:,
# matches one of them). Member by member for a key that lists each member
# (_platform_per_member; platform_compare_members), and lever by lever for TUNING_BASELINE: a
# member (or lever) whose builds differ makes it differs; else one not read on a side (unknown,
# unreachable for KUBE_VERSIONS, or a digest @unknown), or on one side only, makes it unknown, as
# does a token without a member (mixed:unknown) beside members. Two values that name no member
# (inputs from before the record: churn's bare replica count, say) compare as they are, and are
# unknown when a side has none. A state-only difference is the same build.
# shellcheck disable=SC2329
_platform_compare_key() {
	local key="$1" pair res=same any=0 m
	local -a _pl_p=()
	if ! _platform_per_member "$key" && [[ "$key" != TUNING_BASELINE ]]; then
		_platform_alt_cmp_to res "$key" "$2" "$3" ,
		echo "$res"
		return 0
	fi
	IFS=',' read -r -a _pl_p <<<"${2},${3}"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		if [[ "$pair" == *=* ]]; then any=1; else res=unknown; fi
	done
	if ((any == 0)); then
		res=unknown
		[[ -z "$2" || -z "$3" || "$2" == *,* || "$3" == *,* ]] || _platform_alt_cmp_to res "$key" "$2" "$3" ';'
		echo "$res"
		return 0
	fi
	m="$(platform_compare_members "$key" "$2" "$3")"
	if [[ $'\n'"${m}"$'\n' == *$'\tdiffers\n'* ]]; then
		echo differs
		return 0
	fi
	[[ -z "$m" ]] || res=unknown
	echo "$res"
}

# platform_compare_members <key> <ref value> <value>: "<member>\t<ref>\t<value>\t<result>" for
# each member of two values that list each member (a *_BY_CONTEXT key's, KUBE_VERSIONS', or
# TUNING_BASELINE's levers) that does not match (_platform_alt_cmp_to: a member whose value holds
# more than one, mixed:, matches when one of them is the other side's build, so a tuning pass
# that ran on a member the build the reference pass started or ended with there matches it):
# differs, another build; unknown, a value not read on a side (or a digest @unknown), or a
# member on one side only (the other side "-"). In the order the members first appear; nothing
# for a member that matches, or a token without a member (mixed:unknown).
# shellcheck disable=SC2329
platform_compare_members() {
	local key="$1" pair c r
	local -a _pl_p=() _pl_all=()
	local -A _pl_r=() _pl_v=() _pl_in=()
	IFS=',' read -r -a _pl_p <<<"$2"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		[[ "$pair" == *=* ]] || continue
		c="${pair%%=*}"
		_pl_r[$c]="${pair#*=}"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done
	IFS=',' read -r -a _pl_p <<<"$3"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		[[ "$pair" == *=* ]] || continue
		c="${pair%%=*}"
		_pl_v[$c]="${pair#*=}"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done
	for c in ${_pl_all[@]+"${_pl_all[@]}"}; do
		if [[ -z "${_pl_r[$c]+x}" || -z "${_pl_v[$c]+x}" ]]; then
			printf '%s\t%s\t%s\tunknown\n' "$c" "${_pl_r[$c]:--}" "${_pl_v[$c]:--}"
			continue
		fi
		_platform_alt_cmp_to r "$key" "${_pl_r[$c]}" "${_pl_v[$c]}" ';'
		[[ "$r" == same ]] || printf '%s\t%s\t%s\t%s\n' "$c" "${_pl_r[$c]}" "${_pl_v[$c]}" "$r"
	done
}

# platform_value_against <key> <value> <ref value>: a value of platform_report_values shown
# against a reference one (a tuning pass against the baseline), so a record of hundreds of
# members stays one short line: the one value every member shares (platform_collapse) when no
# member or every member differs from the reference (each recorded on both sides), else the
# members that do not match it (platform_compare_members): those that differ, then those not read
# or not recorded on a side, then those that only ran more than one value (which match by one of
# them: a note on what the inputs disagree on shows them), so the five named include those that
# differ first; each group in the order its members first appear, as <member>=<value> (a value it
# ran more than one of as "mixed: <a> and <b>", and so the shared one), five at most, then ", and
# <j> more members" ("member" for one), then "(<n> of <m> members; the other <k> match)" ("matches"
# for one), or "(all <m> members)": a member that matches by one of the reference's values (it ran
# two) is not hidden behind the shared value. A member only the reference has reads "<member> not
# recorded"; a token without a member comes first (_platform_bare_text: "not recorded in some of
# its TSVs" for mixed:unknown, an input without the key).
# shellcheck disable=SC2329
platform_value_against() {
	local key="$1" v pair c a b r t k n=0 bare="" one=0 names
	local -a _pl_items=() _pl_p=() _pl_vord=()
	local -A _pl_in=() _pl_it=() _pl_rk=()
	v="$(platform_collapse "$2")"
	[[ "$v" == *=* || "$v" != mixed:*";"* ]] || { b="${v#mixed:}"; v="mixed: ${b//;/ and }"; }
	if ! _platform_per_member "$key" || [[ "$2" != *=* ]]; then
		printf '%s\n' "$v"
		return 0
	fi
	# The members in the order they first appear (the reference's, then the others', as
	# platform_compare_members lists them).
	IFS=',' read -r -a _pl_p <<<"$3"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		[[ "$pair" == *=* && -z "${_pl_in[${pair%%=*}]+x}" ]] || continue
		_pl_in[${pair%%=*}]=1
		_pl_vord+=("${pair%%=*}")
	done
	IFS=',' read -r -a _pl_p <<<"$2"
	for pair in ${_pl_p[@]+"${_pl_p[@]}"}; do
		if [[ "$pair" != *=* ]]; then
			bare="${bare:-${pair}}"
			continue
		fi
		c="${pair%%=*}"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_vord+=("$c"); }
		[[ "$pair" != *=mixed:*";"* ]] || { b="${pair#*=mixed:}"; _pl_it[$c]="${c}=mixed: ${b//;/ and }"; }
	done
	[[ -z "$bare" ]] || bare="$(_platform_bare_text "$bare")"
	while IFS=$'\t' read -r c a b r; do
		[[ -n "$c" ]] || continue
		# 0: another value; 1: not read, or not recorded, on a side (the members that only ran
		# more than one value come last: 2).
		_pl_rk[$c]=1
		[[ "$r" != differs ]] || _pl_rk[$c]=0
		[[ "$a" != - && "$b" != - ]] || one=1
		[[ "$b" != mixed:*";"* ]] || { b="${b#mixed:}"; b="mixed: ${b//;/ and }"; }
		if [[ "$b" == - ]]; then _pl_it[$c]="${c} not recorded"; else _pl_it[$c]="${c}=${b}"; fi
	done < <(platform_compare_members "$key" "$3" "$2")
	# The members that differ first, so five not read or six that only ran two values do not push
	# one that differs out of the five named; then those not read, then those that ran two.
	for t in 0 1 2; do
		for c in ${_pl_vord[@]+"${_pl_vord[@]}"}; do
			[[ -z "${_pl_it[$c]+x}" || "${_pl_rk[$c]:-2}" != "$t" ]] || _pl_items+=("${_pl_it[$c]}")
		done
	done
	n=${#_pl_items[@]}
	if [[ "$v" != *=* ]] && ((one == 0 && (n == 0 || n == ${#_pl_in[@]}))); then
		printf '%s\n' "$v"
		return 0
	fi
	# Past five, how many more members: "m5=mixed: 1 and 2 and 2 more" would read as a third value.
	names="$(_platform_names ${_pl_items[@]+"${_pl_items[@]:0:5}"})"
	((n <= 5)) || names+=", and $((n - 5)) more member$( ((n - 5 == 1)) || echo s)"
	if ((n == 0)); then
		printf '%s\n' "${bare:+${bare}, }every member recorded matches"
	elif ((n == ${#_pl_in[@]})); then
		printf '%s%s (all %d members)\n' "${bare:+${bare}, }" "$names" "$n"
	else
		k=$((${#_pl_in[@]} - n))
		printf '%s%s (%d of %d members; the other %d match%s)\n' "${bare:+${bare}, }" "$names" "$n" "${#_pl_in[@]}" "$k" "$( ((k != 1)) || echo es)"
	fi
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
	local ctx row c
	local -a _pl_c=()
	split_csv "$1" _pl_c
	_platform_index
	for ctx in ${_pl_c[@]+"${_pl_c[@]}"}; do
		if [[ -n "$ctx" && -n "${_PL_IDX[$ctx]+x}" ]]; then row="${_PL_IDX[$ctx]}"; else row="$(_platform_unknown_row "$ctx")"; fi
		_platform_sanitize_to c "$ctx"
		printf '%s\t%s\n' "$c" "${row#*$'\t'}"
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
		_platform_sanitize_to c "$c"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		_platform_sanitize_to c "${line%%$'\t'*}"
		[[ -n "${_pl_or[$c]+x}" ]] || _pl_or[$c]="$line"
		[[ -n "${_pl_in[$c]+x}" ]] || { _pl_in[$c]=1; _pl_all+=("$c"); }
	done <<<"$1"
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		_platform_sanitize_to c "${line%%$'\t'*}"
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
			_platform_build_cmp_to res "${PLATFORM_ROW_KEYS[j]}" "$ov" "$nv"
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
# ISTIOD_REPLICAS_BY_CONTEXT (an HPA moves it; ISTIOD_REPLICAS is its summary; five warnings,
# then how many more members) and NETWORK_TOPOLOGY (env_collect_infra). METRICS_API is not
# compared: the resumed run's own preflight checks the metrics API. One line on stdout says the
# comparison ran. Nothing in a dry-run, or when <tsv> has no header yet (it is written anew).
# shellcheck disable=SC2329
platform_resume_check() {
	local tsv="$1" _pl_ctxs="$2" tctx="${3:-}" old new kind c key o n dies="" line tb_old eh_old tb_new="" eh_new="" lv
	local again tp_old snap src unr="" g cmp keys kv_old kv_new lim nt infra note csv _pl_tn i more=0
	local -a _pl_lv=() _pl_lo=() _pl_rc=() _pl_gk=() _pl_p=() _pl_ga=() _pl_dzo=() _pl_ck=() _pl_ugo=()
	local -a _pl_rgo=() _pl_mr=() _pl_mt=()
	local -A _pl_ov=() _pl_nv=() _pl_raw=() _pl_gkeys=() _pl_rko=() _pl_rkn=() _pl_dz=() _pl_ug=() _pl_rg=()
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
		_platform_sanitize_to g "$c"
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
	echo "Platform record: comparing what $(_platform_names ${_pl_rc[@]+"${_pl_rc[@]}"}) run now with what ${tsv} recorded at the sweep's start (--resume)"
	if [[ -z "$old" ]]; then
		echo "warning: --resume: ${tsv} predates the platform record (no PLATFORM_BY_CONTEXT line), so this run cannot tell whether the members still run the builds its rows were measured on; its report reads them unknown" >&2
	else
		while IFS=$'\t' read -r kind c key o n; do
			case "$kind" in
			differs) _platform_group _pl_dz _pl_dzo "${key}"$'\x1f'"${o}"$'\x1f'"${n}" "$c" ;;
			unknown)
				[[ "$o" != unknown ]] || _platform_preamble_value "$tsv" "$key" >/dev/null || o=""
				unr+="${c}"$'\t'"$(_platform_unread_why "$tsv" "$key" "$o" "$n" " (the warnings above say why)")"$'\t'"${key}"$'\n'
				;;
			missing)
				if [[ "$o" == - ]]; then _pl_mr+=("$c"); else _pl_mt+=("$c"); fi
				;;
			esac
		done < <(_platform_diff "$old" "$new" "$_pl_ctxs")
		if ((${#_pl_mr[@]} == 1)); then
			echo "warning: --resume: ${_pl_mr[0]} is a member of this run but not of the record in ${tsv}: the preamble is not rewritten on --resume, so its builds are never recorded and the report does not list it; start a new sweep to record it" >&2
		elif ((${#_pl_mr[@]})); then
			echo "warning: --resume: $(_platform_names "${_pl_mr[@]}") are members of this run but not of the record in ${tsv}: the preamble is not rewritten on --resume, so their builds are never recorded and the report does not list them; start a new sweep to record them" >&2
		fi
		if ((${#_pl_mt[@]} == 1)); then
			echo "warning: --resume: ${_pl_mt[0]} is in the record of ${tsv} but not a member of this run" >&2
		elif ((${#_pl_mt[@]})); then
			echo "warning: --resume: $(_platform_names "${_pl_mt[@]}") are in the record of ${tsv} but not members of this run" >&2
		fi
	fi
	tp_old="$(_platform_preamble_value "$tsv" TEST_PLATFORM)" || tp_old=""
	if [[ -n "$tp_old" && "$tp_old" != "${TEST_PLATFORM:-auto}" ]]; then
		echo "warning: --resume: ${tsv} was started with TEST_PLATFORM=${tp_old}, this run has TEST_PLATFORM=${TEST_PLATFORM:-auto}: its suite charts may get another overlay than the recorded rows had" >&2
	fi
	if [[ -n "$tctx" ]]; then
		# Its warnings name members as the TSV records them (_platform_sanitize).
		_pl_tn="$(_platform_sanitize "$tctx")"
		for c in ${_pl_rc[@]+"${_pl_rc[@]}"}; do
			_platform_sanitize_to g "$c"
			_pl_ga+=("$g")
		done
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
			_platform_build_cmp_to cmp KUBE_VERSIONS "$o" "$n"
			case "$cmp" in
			differs) _platform_group _pl_dz _pl_dzo "KUBE_VERSIONS"$'\x1f'"${o}"$'\x1f'"${n}" "$(_platform_sanitize "$c")" ;;
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
					_platform_group _pl_dz _pl_dzo "TUNING_BASELINE ${lv}"$'\x1f'"${o}"$'\x1f'"${n}" "$_pl_tn"
				fi
			done
		fi
		if [[ -n "$eh_old" && "$eh_old" != unknown && -n "$eh_new" && "$eh_new" != unknown ]]; then
			[[ "$eh_old" == "$eh_new" ]] || _platform_group _pl_dz _pl_dzo "SIDECAR_EGRESS_HOSTS"$'\x1f'"${eh_old}"$'\x1f'"${eh_new}" "$_pl_tn"
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
				_platform_group _pl_dz _pl_dzo "${key}"$'\x1f'"${o}"$'\x1f'"${n}" "$_pl_tn"
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
			if [[ "$o" == unknown || "$n" == unknown ]]; then
				line="$(_platform_unread_why "$tsv" "$key" "$o" "$n")"
				if [[ "$key" == NETWORK_TOPOLOGY ]]; then
					for g in ${_pl_ga[@]+"${_pl_ga[@]}"}; do unr+="${g}"$'\t'"${line}"$'\t'"${key}"$'\n'; done
				else
					unr+="${_pl_tn}"$'\t'"${line}"$'\t'"${key}"$'\n'
				fi
			elif [[ "$o" != "$n" ]]; then
				g="$_pl_tn"
				[[ "$key" != NETWORK_TOPOLOGY ]] || g="$(_platform_names ${_pl_ga[@]+"${_pl_ga[@]}"})"
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
					_platform_group _pl_rg _pl_rgo "${o}"$'\x1f'"${n}" "$(_platform_sanitize "$c")"
				fi
			done
			# Five warnings, then how many more members (an HPA spreads the counts), as the drift
			# check's.
			i=0
			for g in ${_pl_rgo[@]+"${_pl_rgo[@]}"}; do
				i=$((i + 1))
				if ((i > 5)); then
					IFS=$'\x1f' read -r -a _pl_p <<<"${_pl_rg[$g]}"
					more=$((more + ${#_pl_p[@]}))
					continue
				fi
				echo "warning: --resume: $(_platform_group_names "${_pl_rg[$g]}"): ISTIOD_REPLICAS_BY_CONTEXT recorded ${g%%$'\x1f'*}, now ${g#*$'\x1f'}; an HPA moves it, the report shows the recorded count while each row records its own istiod pods" >&2
			done
			((more == 0)) ||
				echo "warning: --resume: and ${more} more member$( ((more == 1)) || echo s) whose ISTIOD_REPLICAS_BY_CONTEXT is not the recorded one; an HPA moves it, the report shows the recorded count while each row records its own istiod pods" >&2
		fi
	fi
	# The values not read: each member's keys by reason, then one warning per keys and reason.
	while IFS=$'\t' read -r c line key; do
		[[ -n "$c" ]] || continue
		g="${c}"$'\t'"${line}"
		[[ -n "${_pl_gkeys[$g]+x}" ]] || _pl_gk+=("$g")
		_pl_gkeys[$g]+="${_pl_gkeys[$g]:+, }${key}"
	done <<<"$unr"
	for g in ${_pl_gk[@]+"${_pl_gk[@]}"}; do
		_platform_group _pl_ug _pl_ugo "${_pl_gkeys[$g]}"$'\x1f'"${g#*$'\t'}" "${g%%$'\t'*}"
	done
	for g in ${_pl_ugo[@]+"${_pl_ugo[@]}"}; do
		keys="${g%%$'\x1f'*}"
		echo "warning: --resume: $(_platform_group_names "${_pl_ug[$g]}"): ${keys}: ${g#*$'\x1f'}, so this run cannot tell whether $([[ "$keys" == *", "* ]] && echo they || echo it) changed since its rows were measured" >&2
	done
	# What differs: one line per key and values, naming its members.
	for g in ${_pl_dzo[@]+"${_pl_dzo[@]}"}; do
		IFS=$'\x1f' read -r key o n <<<"$g"
		dies+=$'\n'"  $(_platform_group_names "${_pl_dz[$g]}"): ${key} recorded ${o}, now ${n}"
		_pl_ck+=("${key%% *}")
	done
	[[ -z "$dies" ]] || die "--resume: ${tsv} was started on other builds, settings or cluster values than the members have now:${dies}
$(_platform_resume_causes "${_pl_ck[@]}")
The rows this run appends would be credited to what its preamble records. ${again}"
}

# platform_drift_check <sweep_dir> <ctxs_csv> [<run>]: after a sweep's last step (outside every
# window; nothing in a dry-run), read these members' record again and compare it with the one the
# sweep started with (PLATFORM_PROBE_ROWS); its messages name <run> (sweep; tuning 003 passes
# pass, for each pass's dir, and its limit messages then leave out the controlplane report's
# percentages, which a pass's comparison does not show). When the TSVs (<sweep_dir>/*.tsv)
# record them, also each member's KUBE_VERSIONS (probe_kube_versions) and, on the member the TSVs
# read them on (the first of their record, when it is one of <ctxs_csv>; else the first of
# <ctxs_csv>), TUNING_BASELINE and SIDECAR_EGRESS_HOSTS (tuning_baseline_state) and
# ISTIOD_CPU_LIMIT_M and ISTIOD_MEM_LIMIT_MI (cap_istiod_limits: the denominators of the
# controlplane report's window-peak CPU and RSS %), against every definite value those TSVs
# recorded; and istiod's limits on every other member against the recorded ones (a member that
# differs: ISTIOD_LIMITS_DIFFER_BY_CONTEXT, "<ctx>=<cpu_m>/<mem_mi>"; the report divides every
# member's rows by the recorded ones; a sweep's warns, a pass's does not: tuning 004 compares
# each member's limits between passes); and each member's istiod replica count (its Deployment's,
# from the same read) against the ones the TSVs recorded, when they record each member's
# (ISTIOD_REPLICAS_BY_CONTEXT, the controlplane suite's). Its first line names what it reads
# again: the record, and what the TSVs record of those. A value that changed warns, naming the
# member, key, both values (the levers that changed, for TUNING_BASELINE), the usual cause and
# what to do (five warnings for istiod's replica counts, then how many more members). Every
# check that reads the members again appends to <sweep_dir>/platform-drift.txt
# (PLATFORM_DRIFT_FILE), so the file says the check ran: "# DRIFT_READ_AT=<time>", then each value
# that changed, "# <KEY>=<ctx>=<value at the end>,..." (a once-recorded value as "# <KEY>=<value
# at the end>"), then "# NOT_COMPARED_AT_END=<ctx>=<KEY>;<KEY>,...", what it could not compare
# (not read at either end, or a digest @unknown; a lever as "TUNING_BASELINE <lever>";
# ISTIOD_LIMITS_DIFFER_BY_CONTEXT for a member whose limits it could not read; and every value of a
# read it could not make: a helper not sourced, no temp dir), which warns only. The end reads of
# the levers, of each member's limits (and replica count) and of each member's Kubernetes version
# are each made once more when they come back unknown (a read timed out): one read decides a
# tuning pass's cell.
# Every report of the sweep says both in its body (platform_report_warnings, with both values; the
# record's keys merge a changed value as a second one, mixed:, and so does KUBE_VERSIONS in a
# report that merges it with --with); tuning 004 reads them for each pass. It never fails the
# sweep (PL40: its reports run next): a check it cannot make is a warning.
# shellcheck disable=SC2329
platform_drift_check() {
	local dir="$1" _pl_ctxs="$2" run="${3:-sweep}" start now kind c key o n marker k fresh=0 f v lv
	local eh_start="" tb_end="" eh_end="" kv_end="" tb_rec=0 eh_rec=0 kv_rec=0 lim_rec=0 rep_rec=0 line
	local src="" src_rec="" lim chg m dif i tmp g said w again more=0
	local -a _pl_c=() _pl_uo=() _pl_do=() _pl_p=() _pl_lu=() _pl_chgo=() _pl_kgo=() _pl_ugo=() _pl_igo=() _pl_nco=()
	local -a _pl_so=() _pl_kv_again=() _pl_rpgo=() _pl_wl=()
	local -A _pl_end=() _pl_unk=() _pl_dig=() _pl_tb=() _pl_kv=() _pl_kv_start=() _pl_kv_now=()
	local -A _pl_lim_start=() _pl_chg=() _pl_kg=() _pl_ug=() _pl_ig=() _pl_nc=() _pl_skip=()
	local -A _pl_rep_tb=() _pl_rpg=()
	! ((${DRY_RUN:-0})) || return 0
	# Where the drift file's findings show: the sweep's reports, or tuning 004 for a pass.
	said="which its reports say in their body"
	[[ "$run" != pass ]] || said="which tuning 004 reads for this pass"
	split_csv "$_pl_ctxs" _pl_c
	((${#_pl_c[@]})) || return 0
	if ! declare -F reach_sanitize >/dev/null || ! declare -F _config_sha256 >/dev/null || [[ -z "${KUBECTL[*]:-}" ]]; then
		echo "warning: platform_drift_check needs reach_sanitize (source tests/lib/reach.sh), _config_sha256 (tests/lib/config.sh) and KUBECTL; not checked, so the reports cannot tell whether a build changed during the ${run}" >&2
		return 0
	fi
	start="$(_platform_rows_of "$_pl_ctxs")"
	# What the TSVs recorded once, at their start: each lever's, each istiod limit's, each
	# member's Kubernetes version's and istiod replica count's definite values, and the member they
	# read the levers and limits on.
	for f in "$dir"/*.tsv; do
		[[ -f "$f" ]] || continue
		if [[ -z "$src_rec" ]] && { _platform_preamble_value "$f" TUNING_BASELINE >/dev/null ||
			_platform_preamble_value "$f" ISTIOD_CPU_LIMIT_M >/dev/null; }; then
			line="$(_platform_file_rows "$f")"
			src_rec="${line%%$'\t'*}"
		fi
		if v="$(_platform_preamble_value "$f" TUNING_BASELINE)"; then
			tb_rec=1
			IFS=',' read -r -a _pl_p <<<"$v"
			for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$lv" == *=* && "${lv#*=}" != unknown ]] || continue
				k="${lv%%=*}"
				case ";${_pl_tb[$k]:-};" in *";${lv#*=};"*) ;; *) _pl_tb[$k]="${_pl_tb[$k]:-}${_pl_tb[$k]:+;}${lv#*=}" ;; esac
			done
		fi
		for k in ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
			v="$(_platform_preamble_value "$f" "$k")" || continue
			lim_rec=1
			[[ -n "${_pl_lim_start[$k]+x}" ]] || _pl_lim_start[$k]="$v"
			[[ "$v" != unknown ]] || continue
			case ";${_pl_tb[$k]:-};" in *";${v};"*) ;; *) _pl_tb[$k]="${_pl_tb[$k]:-}${_pl_tb[$k]:+;}${v}" ;; esac
		done
		if v="$(_platform_preamble_value "$f" SIDECAR_EGRESS_HOSTS)"; then
			((eh_rec)) || eh_start="$v"
			eh_rec=1
			k=SIDECAR_EGRESS_HOSTS
			[[ "$v" == unknown ]] ||
				case ";${_pl_tb[$k]:-};" in *";${v};"*) ;; *) _pl_tb[$k]="${_pl_tb[$k]:-}${_pl_tb[$k]:+;}${v}" ;; esac
		fi
		# Each member's replicas, by its name in the record (the controlplane suite's form).
		if v="$(_platform_preamble_value "$f" ISTIOD_REPLICAS_BY_CONTEXT)" && [[ "$v" == *=* ]]; then
			rep_rec=1
			IFS=',' read -r -a _pl_p <<<"$v"
			for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
				[[ "$lv" == *=* ]] || continue
				_platform_sanitize_to c "${lv%%=*}"
				[[ -n "${_pl_rep_tb[$c]+x}" ]] || _pl_rep_tb[$c]=""
				[[ "${lv#*=}" == unknown ]] ||
					case ";${_pl_rep_tb[$c]};" in *";${lv#*=};"*) ;; *) _pl_rep_tb[$c]+="${_pl_rep_tb[$c]:+;}${lv#*=}" ;; esac
			done
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
	# What this read compares: the record, and what the TSVs record of the rest.
	_pl_wl=(build "istiod setting")
	((lim_rec == 0)) || _pl_wl+=("istiod limit")
	((rep_rec == 0)) || _pl_wl+=("istiod replica count")
	((tb_rec == 0 && eh_rec == 0)) || _pl_wl+=("tuning lever")
	_pl_wl+=("tuning profile object")
	((kv_rec == 0)) || _pl_wl+=("Kubernetes version")
	w="$(printf '%s, ' "${_pl_wl[@]:0:${#_pl_wl[@]}-1}")"
	echo "Platform record: reading $(_platform_names "${_pl_c[@]}") again, to check that no ${w%, } or ${_pl_wl[${#_pl_wl[@]}-1]} changed during the ${run}"
	if ! now="$(_platform_read_members "${_pl_c[@]}")"; then
		echo "warning: the platform record could not be read again (no temp dir), so the reports cannot tell whether a build changed during the ${run}" >&2
		return 0
	fi
	while IFS=$'\t' read -r kind c key o n; do
		case "$kind" in
		differs)
			_platform_group _pl_chg _pl_chgo "${key}"$'\x1f'"${o}"$'\x1f'"${n}" "$c"
			_pl_end[$key]+="${_pl_end[$key]:+,}${c}=${n}"
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
	# One warning per key and values, naming its members (five, then how many more).
	for g in ${_pl_chgo[@]+"${_pl_chgo[@]}"}; do
		IFS=$'\x1f' read -r key o n <<<"$g"
		w="so its reports read ${key} mixed"
		[[ "$run" != pass ]] || w="$said"
		echo "warning: $(_platform_group_names "${_pl_chg[$g]}"): ${key} changed during the ${run}: ${o} at its start, ${n} at its end; rows measured after the change ran with the new value (written to ${dir}/${PLATFORM_DRIFT_FILE}, ${w}); $(_platform_drift_cause "$key")" >&2
	done
	# The member the TSVs read their once-recorded values on, by its name in this run.
	src="${_pl_c[0]}"
	if [[ -n "$src_rec" ]]; then
		for c in "${_pl_c[@]}"; do
			if [[ "$(_platform_sanitize "$c")" == "$src_rec" ]]; then
				src="$c"
				break
			fi
		done
	fi
	if ((tb_rec || eh_rec)); then
		if declare -F tuning_baseline_state >/dev/null; then
			# Once more when a lever or the hosts could not be read.
			for i in 1 2; do
				tb_end="" eh_end=""
				while IFS= read -r line; do
					case "$line" in
					TUNING_BASELINE=*) tb_end="${line#*=}" ;;
					SIDECAR_EGRESS_HOSTS=*) eh_end="${line#*=}" ;;
					esac
				done < <(tuning_baseline_state "$src" "${KUBECTL[@]}")
				again=0
				((tb_rec == 0)) || [[ "$tb_end" == *=* && ",${tb_end}," != *"=unknown,"* ]] || again=1
				((eh_rec == 0)) || [[ -n "$eh_end" && "$eh_end" != unknown ]] || again=1
				((again)) || break
			done
		else
			echo "warning: platform_drift_check needs tuning_baseline_state (source tests/lib/preamble.sh) to read the tuning levers again; not checked, so the reports cannot tell whether they changed during the ${run}" >&2
			c="$(_platform_sanitize "$src")"
			[[ -n "${_pl_skip[$c]+x}" ]] || _pl_so+=("$c")
			((tb_rec == 0)) || _pl_skip[$c]+="${_pl_skip[$c]:+;}TUNING_BASELINE"
			((eh_rec == 0)) || _pl_skip[$c]+="${_pl_skip[$c]:+;}SIDECAR_EGRESS_HOSTS"
			tb_rec=0 eh_rec=0
		fi
	fi
	if ((tb_rec)); then
		c="$(_platform_sanitize "$src")"
		chg=""
		IFS=',' read -r -a _pl_p <<<"$tb_end"
		for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do
			[[ "$lv" == *=* ]] || continue
			k="${lv%%=*}"
			if [[ "${lv#*=}" == unknown || -z "${_pl_tb[$k]:-}" ]]; then
				[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
				_pl_unk[$c]+="${_pl_unk[$c]:+, }TUNING_BASELINE ${k}"
			elif [[ "${_pl_tb[$k]}" != "${lv#*=}" ]]; then
				chg+="${chg:+, }${k} from ${_pl_tb[$k]//;/ or } to ${lv#*=}"
			fi
		done
		if [[ "$tb_end" != *=* ]]; then
			[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
			_pl_unk[$c]+="${_pl_unk[$c]:+, }TUNING_BASELINE"
		elif [[ -n "$chg" ]]; then
			echo "warning: ${c}: TUNING_BASELINE changed during the ${run}: ${chg}; rows measured after the change ran with other tuning levers (written to ${dir}/${PLATFORM_DRIFT_FILE}, ${said}); $(_platform_drift_cause TUNING_BASELINE)" >&2
			_pl_end[TUNING_BASELINE]="$tb_end"
		fi
	fi
	if ((eh_rec)); then
		c="$(_platform_sanitize "$src")"
		if [[ -z "$eh_end" || "$eh_end" == unknown || -z "${_pl_tb[SIDECAR_EGRESS_HOSTS]:-}" ]]; then
			[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
			_pl_unk[$c]+="${_pl_unk[$c]:+, }SIDECAR_EGRESS_HOSTS"
		elif [[ "${_pl_tb[SIDECAR_EGRESS_HOSTS]}" != "$eh_end" ]]; then
			echo "warning: ${c}: SIDECAR_EGRESS_HOSTS changed during the ${run}: ${eh_start} at its start, ${eh_end} at its end; rows measured after the change ran with other root Sidecar egress hosts (written to ${dir}/${PLATFORM_DRIFT_FILE}, ${said}); $(_platform_drift_cause SIDECAR_EGRESS_HOSTS)" >&2
			_pl_end[SIDECAR_EGRESS_HOSTS]="$eh_end"
		fi
	fi
	# istiod's limits (per replica): the controlplane report divides the window-peak CPU % and the
	# RSS % of every member's rows by the ones recorded on the TSVs' source member, and its SLA
	# verdict uses both. Read on every member, PLATFORM_READ_PARALLEL at a time: the source
	# member's against its start, every other member's against the recorded ones; and, from the
	# same read of istiod's Deployment, each member's replica count against the recorded ones.
	if ((lim_rec || rep_rec)); then
		if declare -F cap_istiod_limits >/dev/null && tmp="$(mktemp -d)"; then
			_platform_each _platform_limits_member "$tmp" "${_pl_c[@]}"
			for i in "${!_pl_c[@]}"; do
				m="${_pl_c[i]}"
				lim="$(head -n 1 "${tmp}/${i}.row" 2>/dev/null || true)"
				c="$(_platform_sanitize "$m")"
				dif=0 lv=""
				for k in ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
					if [[ "$k" == ISTIOD_CPU_LIMIT_M ]]; then n="$(_platform_kv "$lim" cpu_m)"; else n="$(_platform_kv "$lim" mem_mi)"; fi
					[[ -n "$n" ]] || n=unknown
					lv+="${lv:+/}${n}"
					[[ -n "${_pl_lim_start[$k]+x}" ]] || continue
					if [[ "$m" == "$src" ]]; then
						if [[ "$n" == unknown || -z "${_pl_tb[$k]:-}" ]]; then
							[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
							_pl_unk[$c]+="${_pl_unk[$c]:+, }${k}"
						elif [[ "${_pl_tb[$k]}" != "$n" ]]; then
							echo "warning: ${c}: ${k} changed during the ${run}: ${_pl_lim_start[$k]} at its start, ${n} at its end; rows measured after the change ran under another limit$([[ "$run" == pass ]] || echo ", but $(_platform_limit_figure "$k") divides by the recorded one, as does the SLA verdict on it, while the kubectl top % use each row's own limit") (written to ${dir}/${PLATFORM_DRIFT_FILE}, ${said}); $(_platform_drift_cause "$k")" >&2
							_pl_end[$k]="$n"
						fi
					elif [[ -n "${_pl_tb[$k]:-}" ]]; then
						if [[ "$n" == unknown ]]; then
							[[ " ${_pl_lu[*]:-} " == *" ${c} "* ]] || _pl_lu+=("$c")
						else
							case ";${_pl_tb[$k]};" in *";${n};"*) ;; *) dif=1 ;; esac
						fi
					fi
				done
				if [[ -n "${_pl_rep_tb[$c]+x}" ]]; then
					n="$(_platform_kv "$lim" replicas)"
					[[ -n "$n" ]] || n=unknown
					if [[ "$n" == unknown || -z "${_pl_rep_tb[$c]}" ]]; then
						[[ -n "${_pl_unk[$c]+x}" ]] || _pl_uo+=("$c")
						_pl_unk[$c]+="${_pl_unk[$c]:+, }ISTIOD_REPLICAS_BY_CONTEXT"
					elif [[ "${_pl_rep_tb[$c]}" != "$n" ]]; then
						_platform_group _pl_rpg _pl_rpgo "${_pl_rep_tb[$c]//;/ or }"$'\x1f'"${n}" "$c"
						_pl_end[ISTIOD_REPLICAS_BY_CONTEXT]+="${_pl_end[ISTIOD_REPLICAS_BY_CONTEXT]:+,}${c}=${n}"
					fi
				fi
				((dif)) || continue
				_pl_end[ISTIOD_LIMITS_DIFFER_BY_CONTEXT]+="${_pl_end[ISTIOD_LIMITS_DIFFER_BY_CONTEXT]:+,}${c}=${lv}"
			done
			rm -rf "$tmp"
			# Five warnings, then how many more members (an HPA spreads the counts); the drift file
			# keeps every member.
			i=0
			for g in ${_pl_rpgo[@]+"${_pl_rpgo[@]}"}; do
				i=$((i + 1))
				if ((i > 5)); then
					IFS=$'\x1f' read -r -a _pl_p <<<"${_pl_rpg[$g]}"
					more=$((more + ${#_pl_p[@]}))
					continue
				fi
				echo "warning: $(_platform_group_names "${_pl_rpg[$g]}"): ISTIOD_REPLICAS_BY_CONTEXT changed during the ${run}: ${g%%$'\x1f'*} at its start, ${g#*$'\x1f'} at its end; rows measured after the change ran with another istiod replica count (written to ${dir}/${PLATFORM_DRIFT_FILE}, ${said}); $(_platform_drift_cause ISTIOD_REPLICAS_BY_CONTEXT)" >&2
			done
			((more == 0)) ||
				echo "warning: and ${more} more member$( ((more == 1)) || echo s) whose ISTIOD_REPLICAS_BY_CONTEXT changed otherwise during the ${run} (written to ${dir}/${PLATFORM_DRIFT_FILE}, ${said})" >&2
			# Not for a pass: tuning 004 compares each member's limits with the reference pass's (a
			# difference every pass has is not the profile's).
			if [[ -n "${_pl_end[ISTIOD_LIMITS_DIFFER_BY_CONTEXT]+x}" && "$run" != pass ]]; then
				echo "warning: $(_platform_limits_differ "${_pl_end[ISTIOD_LIMITS_DIFFER_BY_CONTEXT]}" "${_pl_lim_start[ISTIOD_CPU_LIMIT_M]:-unknown}" "${_pl_lim_start[ISTIOD_MEM_LIMIT_MI]:-unknown}" "the TSVs recorded on $(_platform_sanitize "$src"), their source member") at the ${run}'s end, but the report divides the window-peak CPU and RSS % of every member's rows (and the SLA verdict on them) by the recorded ones, so those members' rows read against another limit, while the kubectl top % use each row's own (written to ${dir}/${PLATFORM_DRIFT_FILE}, ${said}); $(_platform_limits_cause)" >&2
			fi
			((${#_pl_lu[@]} == 0)) ||
				echo "warning: istiod's limits could not be read on $(_platform_names "${_pl_lu[@]}") at the ${run}'s end, so whether they are the ones $(if [[ "$run" == pass ]]; then echo "its TSVs record"; else echo "the report divides those members' window-peak CPU and RSS % by"; fi) is not known" >&2
		else
			w="istiod's limits and replica counts"
			((rep_rec)) || w="istiod's limits"
			((lim_rec)) || w="istiod's replica counts"
			echo "warning: platform_drift_check needs cap_istiod_limits (source tests/lib/capacity.sh) and a temp dir to read ${w} again; not checked, so the reports cannot tell whether they changed during the ${run}" >&2
			# Not compared at the end: the source member's recorded limits, every other member's, and
			# each member's recorded replica count.
			for m in "${_pl_c[@]}"; do
				c="$(_platform_sanitize "$m")"
				lv=""
				if ((lim_rec == 0)); then
					:
				elif [[ "$m" == "$src" ]]; then
					for k in ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI; do
						[[ -z "${_pl_lim_start[$k]+x}" ]] || lv+="${lv:+;}${k}"
					done
				else
					lv=ISTIOD_LIMITS_DIFFER_BY_CONTEXT
				fi
				[[ -z "${_pl_rep_tb[$c]+x}" ]] || lv+="${lv:+;}ISTIOD_REPLICAS_BY_CONTEXT"
				[[ -n "$lv" ]] || continue
				[[ -n "${_pl_skip[$c]+x}" ]] || _pl_so+=("$c")
				_pl_skip[$c]+="${_pl_skip[$c]:+;}${lv}"
			done
		fi
	fi
	if ((kv_rec)); then
		if declare -F probe_kube_versions >/dev/null; then
			kv_end="$(probe_kube_versions "$_pl_ctxs" "${KUBECTL[@]}")"
			IFS=',' read -r -a _pl_p <<<"$kv_end"
			for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do [[ "$lv" != *=* ]] || _pl_kv_now[${lv%%=*}]="${lv#*=}"; done
			# Once more for the members whose version could not be read.
			for c in "${_pl_c[@]}"; do
				[[ -n "${_pl_kv_start[$c]+x}" ]] || continue
				if _platform_unread KUBE_VERSIONS "${_pl_kv_now[$c]:-unknown}"; then _pl_kv_again+=("$c"); fi
			done
			if ((${#_pl_kv_again[@]})); then
				kv_end="$(probe_kube_versions "$(IFS=,; echo "${_pl_kv_again[*]}")" "${KUBECTL[@]}")"
				IFS=',' read -r -a _pl_p <<<"$kv_end"
				for lv in ${_pl_p[@]+"${_pl_p[@]}"}; do [[ "$lv" != *=* ]] || _pl_kv_now[${lv%%=*}]="${lv#*=}"; done
			fi
			for c in "${_pl_c[@]}"; do
				[[ -n "${_pl_kv_start[$c]+x}" ]] || continue
				n="${_pl_kv_now[$c]:-unknown}"
				if _platform_unread KUBE_VERSIONS "$n" || [[ -z "${_pl_kv[$c]:-}" ]]; then
					k="$(_platform_sanitize "$c")"
					[[ -n "${_pl_unk[$k]+x}" ]] || _pl_uo+=("$k")
					_pl_unk[$k]+="${_pl_unk[$k]:+, }KUBE_VERSIONS"
				elif [[ "${_pl_kv[$c]}" != "$n" ]]; then
					_platform_group _pl_kg _pl_kgo "${_pl_kv_start[$c]}"$'\x1f'"${n}" "$c"
					_pl_end[KUBE_VERSIONS]+="${_pl_end[KUBE_VERSIONS]:+,}${c}=${n}"
				fi
			done
			for g in ${_pl_kgo[@]+"${_pl_kgo[@]}"}; do
				echo "warning: $(_platform_group_names "${_pl_kg[$g]}"): KUBE_VERSIONS changed during the ${run}: ${g%%$'\x1f'*} at its start, ${g#*$'\x1f'} at its end; rows measured after the change ran on another Kubernetes version (written to ${dir}/${PLATFORM_DRIFT_FILE}, ${said}); $(_platform_drift_cause KUBE_VERSIONS)" >&2
			done
		else
			echo "warning: platform_drift_check needs probe_kube_versions (source tests/lib/preamble.sh) to read the Kubernetes versions again; not checked, so the reports cannot tell whether they changed during the ${run}" >&2
			for m in "${_pl_c[@]}"; do
				[[ -n "${_pl_kv_start[$m]+x}" ]] || continue
				c="$(_platform_sanitize "$m")"
				[[ -n "${_pl_skip[$c]+x}" ]] || _pl_so+=("$c")
				_pl_skip[$c]+="${_pl_skip[$c]:+;}KUBE_VERSIONS"
			done
		fi
	fi
	# The values not compared: one warning per keys, naming their members.
	for c in ${_pl_do[@]+"${_pl_do[@]}"}; do _platform_group _pl_ig _pl_igo "${_pl_dig[$c]}" "$c"; done
	for g in ${_pl_igo[@]+"${_pl_igo[@]}"}; do
		echo "warning: $(_platform_group_names "${_pl_ig[$g]}"): ${g} read with a digest @unknown at the ${run}'s start or end (no pod had started), so whether $([[ "$g" == *", "* ]] && echo they || echo it) changed during the ${run} is not known" >&2
	done
	for c in ${_pl_uo[@]+"${_pl_uo[@]}"}; do _platform_group _pl_ug _pl_ugo "${_pl_unk[$c]}" "$c"; done
	for g in ${_pl_ugo[@]+"${_pl_ugo[@]}"}; do
		echo "warning: $(_platform_group_names "${_pl_ug[$g]}"): ${g} not read at the ${run}'s start or end, so whether $([[ "$g" == *", "* ]] && echo they || echo it) changed during the ${run} is not known" >&2
	done
	# What it could not compare, per member: the reports and tuning 004 say so.
	for c in ${_pl_uo[@]+"${_pl_uo[@]}"}; do
		_pl_nco+=("$c")
		_pl_nc[$c]="${_pl_unk[$c]//, /;}"
	done
	for c in ${_pl_do[@]+"${_pl_do[@]}"}; do
		[[ -n "${_pl_nc[$c]+x}" ]] || _pl_nco+=("$c")
		_pl_nc[$c]="${_pl_nc[$c]:-}${_pl_nc[$c]:+;}${_pl_dig[$c]//, /;}"
	done
	for c in ${_pl_lu[@]+"${_pl_lu[@]}"}; do
		[[ -n "${_pl_nc[$c]+x}" ]] || _pl_nco+=("$c")
		_pl_nc[$c]="${_pl_nc[$c]:-}${_pl_nc[$c]:+;}ISTIOD_LIMITS_DIFFER_BY_CONTEXT"
	done
	# A read it could not make (its own warning above).
	for c in ${_pl_so[@]+"${_pl_so[@]}"}; do
		[[ -n "${_pl_nc[$c]+x}" ]] || _pl_nco+=("$c")
		_pl_nc[$c]="${_pl_nc[$c]:-}${_pl_nc[$c]:+;}${_pl_skip[$c]}"
	done
	line=""
	for c in ${_pl_nco[@]+"${_pl_nco[@]}"}; do line+="${line:+,}${c}=${_pl_nc[$c]}"; done
	marker="${dir}/${PLATFORM_DRIFT_FILE}"
	[[ -f "$marker" ]] || fresh=1
	if ! {
		((fresh == 0)) || echo "# The platform record read again at the end of this ${run} (tests/lib/platform.sh platform_drift_check), one block per read: when; each value that changed, as its value at the end, per member (TUNING_BASELINE, SIDECAR_EGRESS_HOSTS and istiod's limits on the member the TSVs read them on; ISTIOD_REPLICAS_BY_CONTEXT, istiod's Deployment replicas on each member, when the TSVs record each member's: the controlplane suite's; the TSVs record the value at the start); ISTIOD_LIMITS_DIFFER_BY_CONTEXT, the other members whose istiod limits per replica (CPU m/memory Mi) differ at the end from the recorded ones; NOT_COMPARED_AT_END, per member what it could not compare (not read at the start or the end, a digest @unknown, or a read it could not make)"
		echo "# DRIFT_READ_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		for k in "${PLATFORM_KEYS[@]}" KUBE_VERSIONS TUNING_BASELINE SIDECAR_EGRESS_HOSTS ISTIOD_CPU_LIMIT_M ISTIOD_MEM_LIMIT_MI ISTIOD_REPLICAS_BY_CONTEXT ISTIOD_LIMITS_DIFFER_BY_CONTEXT; do
			[[ -z "${_pl_end[$k]+x}" ]] || echo "# ${k}=${_pl_end[$k]}"
		done
		[[ -z "$line" ]] || echo "# NOT_COMPARED_AT_END=${line}"
	} >>"$marker"; then
		echo "warning: could not write ${marker}: the reports of this ${run} will not show what its read at the end found" >&2
	fi
	return 0
}
