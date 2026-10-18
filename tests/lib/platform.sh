#!/usr/bin/env bash
# Platform of a mesh member and the suite-chart overlay for it. Sourced, never executed.
#
# Consumers: propagation, churn, churn-dataplane, controlplane, dataplane (the 001 setup scripts)
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
#
# Requires KUBECTL (resolve_kubectl) and TEST_PLATFORM (config/options.env: auto,
# kubernetes or openshift; read at call time). With DRY_RUN=1 and TEST_PLATFORM=auto no
# cluster is asked and the Kubernetes defaults render, so a dry-run stays offline; set
# TEST_PLATFORM=openshift to preview the OpenShift render.
# shellcheck shell=bash

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
