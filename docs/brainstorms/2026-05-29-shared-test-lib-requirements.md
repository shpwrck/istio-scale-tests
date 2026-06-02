---
date: 2026-05-29
topic: shared-test-lib
---

# Consolidate shared shell helpers into `tests/lib/`

## Summary

Create a shared `tests/lib/` directory with four files (`common.sh`, `timestamp.sh`, `preamble.sh`, `metrics.sh`) to replace identical helper functions duplicated across all 6 test suites (~30 scripts). Phase the work by lib file with real-cluster validation between phases. Add bats-core unit tests for the shared lib functions and a `tests/lib/verify.sh` script as a fast pre-merge gate.

---

## Problem Frame

Every test suite inlines the same helper functions — `die()` appears in 29 scripts, `split_csv()` in 19. Only `churn-dataplane/lib/` has factored-out helpers; the other five suites copy everything inline. This creates two problems: reading a 500-line probe script means scrolling past 80+ lines of boilerplate before reaching the test logic, and propagating a fix (like the recent `bucket_range()` overflow handling) requires editing the same function in multiple files.

The `churn-dataplane/lib/` directory already proves the sourcing pattern works and is the natural seed for the global lib.

---

## Key Decisions

**Only extract functions that are identical or trivially unifiable.** Functions that already diverge across suites (report formatters, `aggregate()`, `delta_histogram()` with different semantics, controlplane/002's string-based metric extractors) stay inline. This avoids the coupling risk of forcing divergent implementations into a shared interface.

**Phase by lib file, not by suite.** Each phase adds one new lib file and converts all its consumers. This keeps each phase self-contained and limits the blast radius if something breaks. Between phases, affected suites are validated against a real cluster.

**Stay with bash.** A language assessment (85% glue / 15% logic) confirmed that bash is the right fit for these orchestration-heavy scripts. The painful 15% (awk histogram calculations, report aggregation) is addressed by consolidation and unit testing rather than a rewrite.

**Add bats-core unit tests as the primary coupling guard.** Unit tests for pure-logic functions (`split_csv`, `bucket_range`, `delta_histogram_p99`, `extract_counter_sum`) catch regressions without requiring a cluster. This directly addresses the accidental cross-suite breakage concern.

**Add `verify.sh` as a fast pre-merge gate.** Runs `bash -n` + `shellcheck` + grep-for-leftover-inline-defs + all-suite `--dry-run` + bats test suite. This layers on top of unit tests to validate the full source chain.

---

## Requirements

**Shared library structure**

R1. Create `tests/lib/common.sh` containing `die()`, `split_csv()`, `is_pos_int()`, and `validate_scoping()`. Sourced by every test script.

R2. Create `tests/lib/timestamp.sh` containing `_detect_now_ns()`, `now_ns()`, and `now_ms()`. Sourced by probe/measurement scripts that need portable timestamps.

R3. Create `tests/lib/preamble.sh` containing `harness_sha()`, `kube_versions()`, `probe_kube_versions()`, `write_preamble()`, `istiod_restart_status()`, and `istiod_start_time_seconds()`. Sourced by probe scripts that write TSV output.

R4. Create `tests/lib/metrics.sh` containing `scrape_istiod_metrics()`, `extract_counter_sum()`, `extract_counter_by_label()`, `extract_gauge()`, and `delta_histogram_p99()`. Sourced by probe scripts that scrape Prometheus.

R5. Canonical implementations come from `tests/churn-dataplane/lib/preamble.sh` and `tests/churn-dataplane/lib/metrics.sh`. The controlplane/002 `_detect_now_ms()`/`now_ms()` variant is replaced by the canonical `_detect_now_ns`-based version (functionally equivalent).

**Conversion mechanics**

R6. Every consuming script adds `source "${ROOT}/tests/lib/<file>.sh"` immediately after the existing `source "${ROOT}/config/versions.env"` line, with `# shellcheck disable=SC1091`.

R7. Inline function definitions replaced by the shared lib are deleted from each consuming script. No stub comments or backwards-compatibility shims.

R8. The `validate_scoping_value()` callsite in `tests/controlplane/003-run-sweep.sh` is renamed to `validate_scoping()`.

**Cleanup**

R9. After all consumers are converted, delete `tests/churn-dataplane/lib/preamble.sh` and `tests/churn-dataplane/lib/metrics.sh`. Remove the `tests/churn-dataplane/lib/` directory.

R10. `write_preamble()` in the promoted `tests/lib/preamble.sh` accepts a title argument instead of hardcoding `"# churn-dataplane co-exec test"`.

**Unit tests**

R11. Add bats-core unit tests under `tests/lib/test/` covering all pure-logic functions in the shared lib. At minimum: `split_csv` (empty input, single value, whitespace trimming, trailing comma), `is_pos_int` (valid, zero, negative, non-numeric), `validate_scoping` (valid values, invalid value), `bucket_range` (boundary values, N/A, overflow), `extract_counter_sum` (multi-instance counter, missing counter, comment lines), `extract_counter_by_label` (label filtering, no match), `delta_histogram_p99` (normal case, missing buckets, negative deltas).

R12. Include fixture files under `tests/lib/test/fixtures/` with sample Prometheus metrics output and histogram bucket data for deterministic test input.

R13. Timing functions (`now_ns`, `now_ms`) are tested for output format (numeric, reasonable magnitude) rather than exact values.

**Validation**

R14. Create `tests/lib/verify.sh` that runs: (a) `bash -n` on every script under `tests/`, (b) `shellcheck` on all scripts and lib files, (c) grep audit confirming no inline definitions of extracted functions remain outside `tests/lib/`, (d) bats test suite, (e) `--dry-run` invocation of all suite sweep scripts.

R15. Each phase is a separate commit. Between phases, affected suites are validated against a real cluster before proceeding.

**Documentation**

R16. Update AGENTS.md to document the `tests/lib/` directory, the sourcing convention, and the requirement that changes to shared lib files must pass `tests/lib/verify.sh`.

R17. Each shared lib file includes a header comment listing which suites source it.

---

## Scope Boundaries

**Extracted (identical or trivially unifiable):** `die`, `split_csv`, `is_pos_int`, `validate_scoping`, timing functions, preamble/harness metadata functions, Prometheus metric extraction (file-based API).

**Stays inline (divergent implementations):** All `report_*()` formatters, `aggregate()`, `delta_histogram()` (different semantics in controlplane vs propagation), `cleanup()`/`cleanup_all()` (different scope per suite), `start_port_forward()`/`start_istiod_pf()` (different parameterization), controlplane/002's string-based `extract_counter_sum()`/`extract_counter_by_label()` (different API from the file-based canonical versions), `probe_kube_versions()` in propagation/002 (different interface from the preamble.sh version).

**Deferred:** Unifying the divergent functions (tier 2) is a separate effort once the shared lib pattern is proven and stable.

---

## Dependencies / Assumptions

- `bats-core` (with `bats-assert` and `bats-support` helper libraries) is available or installable on development machines. No cluster dependency for unit tests.
- Real ROSA cluster access is available between phases for integration validation.
- All scripts support `--dry-run` via their sweep orchestrators (verified in the existing codebase).
- The `ROOT` variable is defined before any `source` statement in every script (true for scripts called standalone; inherited for scripts called via sweep orchestrators).
