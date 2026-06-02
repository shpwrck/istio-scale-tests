#!/usr/bin/env bash
# Shared test helper for bats-core tests of tests/lib/ functions.
# Sourced by every .bats file via: load test_helper

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${_TEST_DIR}/../../.." && pwd)"
export ROOT

load "${_TEST_DIR}/bats-support/load.bash"
load "${_TEST_DIR}/bats-assert/load.bash"

source "${ROOT}/tests/lib/common.sh"
