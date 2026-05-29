#!/usr/bin/env bash
# Portable nanosecond / millisecond timestamp functions.
# Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane, propagation
#
# Exposes:
#   now_ns   -> portable nanosecond-resolution Unix timestamp
#   now_ms   -> portable millisecond-resolution Unix timestamp
#
# Requires: tests/lib/common.sh (for die())
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# macOS BSD `date` does not support `%N`, so we detect the best
# available source once and cache it.
NOW_NS_IMPL=""
_detect_now_ns() {
	[[ -n "$NOW_NS_IMPL" ]] && return
	if [[ "$(date -u +%s%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
		NOW_NS_IMPL="date"
	elif command -v gdate >/dev/null 2>&1 \
		&& [[ "$(gdate -u +%s%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
		NOW_NS_IMPL="gdate"
	elif command -v python3 >/dev/null 2>&1; then
		NOW_NS_IMPL="python3"
	elif command -v perl >/dev/null 2>&1; then
		NOW_NS_IMPL="perl"
	else
		die "no nanosecond-resolution time source: install GNU coreutils (gdate), python3, or perl"
	fi
}
# shellcheck disable=SC2329
now_ns() {
	_detect_now_ns
	case "$NOW_NS_IMPL" in
	date)    date -u +%s%N ;;
	gdate)   gdate -u +%s%N ;;
	python3) python3 -c 'import time; print(int(time.time()*1e9))' ;;
	perl)    perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1e9' ;;
	esac
}
# shellcheck disable=SC2329
now_ms() {
	_detect_now_ns
	case "$NOW_NS_IMPL" in
	date)    echo $(( $(date -u +%s%N) / 1000000 )) ;;
	gdate)   gdate -u +%s%3N ;;
	python3) python3 -c 'import time; print(int(time.time()*1000))' ;;
	perl)    perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000' ;;
	esac
}
