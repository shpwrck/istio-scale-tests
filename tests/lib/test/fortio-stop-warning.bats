#!/usr/bin/env bats
# fortio_client_stop (tests/lib/fortio.sh; the EXIT trap of dataplane 002 and
# churn-dataplane 002 and 003, fortio-stop.bats) when the delete of the client pod fails:
# its warning names what bounds the load still running there (the probe's --duration, or
# dataplane's --warmup-duration, and 5 s) and returns 0. No cluster: kubectl is a stand-in.

bats_require_minimum_version 1.5.0
load test_helper

@test "fortio_client_stop: a delete that fails warns that the load runs on for up to the probe's --duration (--warmup-duration in dataplane's warmup) and 5 s more, and never fails" {
	source "${ROOT}/tests/lib/fortio.sh"
	k() { return 1; }
	run --separate-stderr fortio_client_stop ctx-a ns-a client-0 k
	assert_success
	[[ "$stderr" == *"warning: ctx-a: could not delete the fortio client pod client-0: its load runs on for up to the probe's --duration (--warmup-duration in dataplane's warmup) from its start, and 5 s more; wait that long before the next run"* ]] \
		|| { echo "$stderr"; false; }
}
