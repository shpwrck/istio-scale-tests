#!/usr/bin/env bats
# tests/lib/lint-bare-scrape.sh, which verify.sh step 5 runs on tests/: a call that returns
# non-zero by design (a scrape with a failed pod, a sweep step that failed) must be guarded,
# captured or tested, or set -e ends the sweep on it.

load test_helper

setup() {
	source "${ROOT}/tests/lib/lint-bare-scrape.sh"
	FIX="${BATS_TEST_TMPDIR}/fix"
	mkdir -p "$FIX"
}

# case_file <name>: stdin as $FIX/<name> (bash, with a shebang).
case_file() {
	{ echo '#!/usr/bin/env bash'; cat; } > "${FIX}/$1"
}

@test "lint_bare_scrape_file: a bare scrape_ctx, fanout_scrape_all or fanout_scrape_aggregate call is flagged; a guarded, captured, if-condition or function-tail call, the definition line and a comment pass" {
	local f
	case_file bad1.sh <<'EOF'
scrape_ctx "$dir" "tick" "${ports[@]}" >/dev/null
if (( $(failed_count) > 0 )); then echo no; fi
EOF
	case_file bad2.sh <<'EOF'
fanout_scrape_all "$polldir" "tick" "${ports[@]}" >/dev/null
echo next
EOF
	case_file bad3.sh <<'EOF'
fanout_scrape_aggregate "$polldir" "tick" hist "${ports[@]}" >/dev/null
echo next
EOF
	run lint_bare_scrape_file "$FIX/bad1.sh"
	assert_failure
	assert_output --partial "bare call to scrape_ctx"
	run lint_bare_scrape_file "$FIX/bad2.sh"
	assert_failure
	assert_output --partial "bare call to fanout_scrape_all"
	run lint_bare_scrape_file "$FIX/bad3.sh"
	assert_failure
	assert_output --partial "bare call to fanout_scrape_aggregate"
	case_file good1.sh <<'EOF'
scrape_ctx "$dir" "tick" "${ports[@]}" >/dev/null || true
if (( $(failed_count) > 0 )); then echo no; fi
EOF
	case_file good2.sh <<'EOF'
skew="$(fanout_scrape_all "$dir" "pre" "${ports[@]}")"
echo "$skew"
EOF
	case_file good3.sh <<'EOF'
if ! fanout_scrape_all "$dir" "pre" "${ports[@]}"; then echo failed; fi
EOF
	case_file good4.sh <<'EOF'
scrape_ctx() {
	local dir="$1" prefix="$2"
	shift 2
	fanout_scrape_all "$dir" "$prefix" "$@"
}
EOF
	case_file good5.sh <<'EOF'
# fanout_scrape_all returns non-zero by design; capture it.
echo ok
EOF
	for f in "$FIX"/good*.sh; do
		run lint_bare_scrape_file "$f"
		assert_success
		assert_output ""
	done
}

@test "lint_bare_orchestrator_step_file: a bare step call in a sweep (\$SCRIPT_DIR or \${TUNING_DIR}, through sweep_step, a \\-continued one with no guard) is flagged; if !, || on the call or a later continued line, a capture, the post-loop report call and \"\$PROBE_SCRIPT\" pass" {
	local f
	mkdir -p "$FIX/bad" "$FIX/good"
	case_file bad/1-run-sweep.sh <<'EOF'
for ms in 1 2; do
	"$SCRIPT_DIR/001-setup-test.sh" --contexts "$active_csv"
done
EOF
	case_file bad/2-run-sweep.sh <<'EOF'
for p in a b; do
	"${TUNING_DIR}/001-apply-profile.sh" --profile "$p"
done
EOF
	case_file bad/3-run-sweep.sh <<'EOF'
for ms in 1 2; do
	sweep_step "$SCRIPT_DIR/001-setup-test.sh" --contexts "$x"
	echo next
done
EOF
	case_file bad/4-run-sweep.sh <<'EOF'
for p in a b; do
	"${TUNING_DIR}/002-revert-profile.sh" \
		--state-dir "$state_dir" \
		--contexts "$CONTEXTS_CSV" \
		--rollout-timeout "$ROLLOUT_TIMEOUT"
done
EOF
	for f in "$FIX"/bad/*.sh; do
		run lint_bare_orchestrator_step_file "$f"
		assert_failure
		assert_output --partial "bare orchestrator-step call"
	done
	assert_output --partial "002-revert-profile.sh"
	case_file good/1-run-sweep.sh <<'EOF'
for ms in 1 2; do
	if ! "$SCRIPT_DIR/001-setup-test.sh" --contexts "$active_csv"; then
		echo warn; continue
	fi
	"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || echo warn
	sweep_step "$SCRIPT_DIR/001-setup-test.sh" --contexts "$x" || echo warn
	"$PROBE_SCRIPT" --contexts x | tee out.log
done
out="$("$SCRIPT_DIR/002-probe.sh" --contexts x)"
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR"
EOF
	case_file good/2-run-sweep.sh <<'EOF'
for p in a b; do
	if ! "${TUNING_DIR}/001-apply-profile.sh" --profile "$p"; then
		echo warn; continue
	fi
	"${TUNING_DIR}/002-revert-profile.sh" --state-dir x || echo warn
	"${TUNING_DIR}/002-revert-profile.sh" \
		--state-dir "$state_dir" \
		--rollout-timeout "$ROLLOUT_TIMEOUT" || \
		echo "warn: revert failed" >&2
	if ! "${TUNING_DIR}/001-apply-profile.sh" \
		--profile "$p" \
		--contexts "$CONTEXTS_CSV"; then
		echo warn; continue
	fi
done
EOF
	for f in "$FIX"/good/*.sh; do
		run lint_bare_orchestrator_step_file "$f"
		assert_success
		assert_output ""
	done
}

@test "lint_bare_scrape_paths: the step lint covers *-run-sweep.sh and *-run-tuning-sweep.sh files only" {
	# A probe with a bare step call is not an orchestrator.
	case_file 002-probe.sh <<'EOF'
"$SCRIPT_DIR/001-setup-test.sh" --contexts x
EOF
	run lint_bare_scrape_paths "$FIX"
	assert_success
	case_file 003-run-tuning-sweep.sh <<'EOF'
for p in a b; do
	"${TUNING_DIR}/001-apply-profile.sh" --profile "$p"
done
EOF
	run lint_bare_scrape_paths "$FIX"
	assert_failure
	assert_output --partial "003-run-tuning-sweep.sh"
	assert_output --partial "001-apply-profile.sh"
	case_file 003-run-tuning-sweep.sh <<'EOF'
for p in a b; do
	if ! "${TUNING_DIR}/001-apply-profile.sh" --profile "$p"; then
		echo warn; continue
	fi
done
EOF
	run lint_bare_scrape_paths "$FIX"
	assert_success
}
