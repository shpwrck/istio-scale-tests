#!/usr/bin/env bats
# A member listed twice, a remote equal to the source, or two members the platform record
# would write under one name, is refused before any cluster call: split_contexts itself, then a
# sample of the entrypoints that call it (and platform_members_check, platform.bats), with an
# empty kubeconfig and kubectl and oc stubs that log every call.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

setup() {
	KC="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$KC"
	export TMPDIR="$BATS_TEST_TMPDIR"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	: > "$STUB_LOG"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB_LOG"\nexit 1\n' > "${BIN}/kubectl"
	printf '#!/usr/bin/env bash\nprintf "oc %%s\\n" "$*" >> "$STUB_LOG"\nexit 1\n' > "${BIN}/oc"
	chmod +x "${BIN}/kubectl" "${BIN}/oc"
}

# _refuses <suite/script> <stderr fragment> <args...>: --dry-run with an empty kubeconfig
# exits non-zero with the fragment on stderr, before any kubectl or oc call. With
# REFUSES_RUN=1, the run itself (no --dry-run), its results under the test's temp dir.
_refuses() {
	local s="$1" want="$2" r
	local -a dry=(--dry-run)
	shift 2
	: > "$STUB_LOG"
	((${REFUSES_RUN:-0} == 0)) || dry=()
	r="${BATS_TEST_TMPDIR}/results"
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" CHURN_RESULTS_DIR="$r" COEXEC_RESULTS_DIR="$r" \
		CONTROLPLANE_RESULTS_DIR="$r" DATAPLANE_RESULTS_DIR="$r" GWAPI_RESULTS_DIR="$r" \
		PROPAGATION_RESULTS_DIR="$r" run --separate-stderr "${ROOT}/tests/${s}.sh" ${dry[@]+"${dry[@]}"} "$@"
	if [[ "$status" -eq 0 || "$stderr" != *"$want"* ]]; then
		echo "${s} $*: exit ${status}, stderr: ${stderr}" >&2
		return 1
	fi
	if [[ -s "$STUB_LOG" ]]; then
		echo "${s}: a cluster call before the refusal: $(cat "$STUB_LOG")" >&2
		return 1
	fi
}

@test "split_contexts: values trimmed; a member listed twice, or the source as one of the remotes, is refused naming it and the flag; a key with a quote or a bracket is one key" {
	run split_contexts "a,b" OUT --contexts
	assert_success
	split_contexts " a , b ,," OUT --contexts
	[ "${OUT[*]}" = "a b" ]
	run split_contexts "a,b,a" OUT --contexts
	assert_failure
	assert_output "error: --contexts lists a twice (a,b,a): list each mesh member once"
	run split_contexts "b,a" OUT --remote-contexts a
	assert_failure
	assert_output "error: --remote-contexts lists the source context a: the remotes are the other mesh members"
	run split_contexts "x\"y],x\"y]" OUT --contexts
	assert_output --partial 'lists x"y] twice'
}

@test "the entrypoints refuse before any cluster call: a member twice in --contexts or SETUP_CONTEXTS, a remote twice or equal to the source, two members the platform record would write under one name (in a sweep's and a probe's dry run and run), tuning 003's one state-file name; lists without them run on" {
	local run want="lab~a and lab_a would be recorded under one name, lab_a"
	_refuses churn/003-run-sweep "--contexts lists ci-a twice (ci-a,ci-b,ci-a): list each mesh member once" --contexts ci-a,ci-b,ci-a
	SETUP_CONTEXTS=ci-a,ci-b,ci-b _refuses churn/003-run-sweep "SETUP_CONTEXTS lists ci-b twice (ci-a,ci-b,ci-b)"
	SETUP_CONTEXTS=ci-a,ci-b,ci-b _refuses tuning/005-cleanup "--contexts (or SETUP_CONTEXTS) lists ci-b twice"
	_refuses dataplane/002-run-latency-probe "--remote-contexts lists the source context ci-a" \
		--source-context ci-a --remote-contexts ci-b,ci-a
	_refuses dataplane/002-run-latency-probe "--remote-contexts lists ci-b twice (ci-b,ci-c,ci-b)" \
		--source-context ci-a --remote-contexts ci-b,ci-c,ci-b
	for run in 0 1; do
		REFUSES_RUN="$run" _refuses controlplane/003-run-sweep "$want" --contexts 'lab~a,lab_a'
		REFUSES_RUN="$run" _refuses dataplane/002-run-latency-probe "$want" --source-context 'lab~a' --remote-contexts lab_a
	done
	# Tuning 003's state file names are stricter still: its own check refuses the pair first.
	_refuses tuning/003-run-tuning-sweep "contexts lab~a and lab_a have one state file name" \
		--suite churn-dataplane --contexts 'lab~a,lab_a' --gitops-context ci-hub
	[ ! -e "${BATS_TEST_TMPDIR}/results" ]
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/churn/005-cleanup.sh" --dry-run --contexts ci-a,ci-b
	assert_success
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/dataplane/002-run-latency-probe.sh" --dry-run --source-context 'lab:a' --remote-contexts lab_a
	assert_success
	[ ! -s "$STUB_LOG" ]
}
