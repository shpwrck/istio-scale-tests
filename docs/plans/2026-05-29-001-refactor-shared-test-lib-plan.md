---
title: "refactor: Consolidate shared shell helpers into tests/lib/"
type: refactor
status: active
date: 2026-05-29
origin: docs/brainstorms/2026-05-29-shared-test-lib-requirements.md
---

# refactor: Consolidate shared shell helpers into tests/lib/

## Summary

Extract duplicated helper functions from ~30 test scripts across 6 suites into a shared `tests/lib/` directory with four files. Add bats-core unit tests as the primary coupling guard and a `verify.sh` pre-merge gate. Phase by lib file — each phase is a separate commit validated against a real cluster before proceeding.

---

## Problem Frame

Helper functions like `die()` (29 copies) and `split_csv()` (19 copies) are inlined in every test script. This obscures test logic behind boilerplate and makes cross-suite fixes error-prone. Only `churn-dataplane/lib/` has factored-out helpers — those files become the seed for the global lib. (See origin: `docs/brainstorms/2026-05-29-shared-test-lib-requirements.md`)

---

## Requirements

**Shared library structure**

R1. Create `tests/lib/common.sh` with `die()`, `split_csv()`, `is_pos_int()`, `validate_scoping()`. Sourced by every test script.

R2. Create `tests/lib/timestamp.sh` with `_detect_now_ns()`, `now_ns()`, `now_ms()`. Sourced by probe scripts.

R3. Create `tests/lib/preamble.sh` with `harness_sha()`, `kube_versions()`, `probe_kube_versions()`, `write_preamble()`, `istiod_restart_status()`, `istiod_start_time_seconds()`. Sourced by probe scripts writing TSV.

R4. Create `tests/lib/metrics.sh` with `scrape_istiod_metrics()`, `extract_counter_sum()`, `extract_counter_by_label()`, `extract_gauge()`, `delta_histogram_p99()`. Sourced by scripts scraping Prometheus.

R5. Canonical implementations from `tests/churn-dataplane/lib/preamble.sh` and `tests/churn-dataplane/lib/metrics.sh`.

**Conversion and cleanup**

R6. Source lines added after `source "${ROOT}/config/versions.env"` with `# shellcheck disable=SC1091`.

R7. Inline definitions deleted, no stubs or shims.

R8. Rename `validate_scoping_value()` callsite in `tests/controlplane/003-run-sweep.sh` to `validate_scoping()`.

R9. Delete `tests/churn-dataplane/lib/` after promotion.

R10. `write_preamble()` accepts a title argument instead of hardcoding `"# churn-dataplane co-exec test"`.

**Testing and validation**

R11. bats-core unit tests for all pure-logic functions.

R12. Fixture files for Prometheus metrics and histogram data.

R13. Timing functions tested for format/magnitude, not exact values.

R14. `tests/lib/verify.sh` runs bash -n, shellcheck, grep audit, bats tests, and dry-run sweeps.

R15. Each phase is a separate commit with cluster validation between phases.

**Documentation**

R16. Update AGENTS.md with `tests/lib/` conventions and verify.sh requirement.

R17. Each lib file includes a header comment listing consuming suites.

---

## Key Technical Decisions

**bats-core as git submodules.** Vendor `bats-core`, `bats-assert`, and `bats-support` as git submodules under `tests/lib/test/`. This keeps the repo self-contained — no external dependency on dev machine state. Matches the repo's existing pattern of vendoring dependencies rather than assuming tool availability.

**Canonical source is the file-based API.** `extract_counter_sum()` and `extract_counter_by_label()` take file paths (from `churn-dataplane/lib/metrics.sh`). The controlplane/002 string-based variants (`echo "$metrics" | awk`) stay inline in that script — they're a different API serving a different architecture, not duplicates.

**controlplane/002 now_ms() switches to canonical version.** The `_detect_now_ms()` variant is replaced by the `_detect_now_ns`-based canonical version from preamble.sh. Both produce millisecond timestamps via the same platform detection chain. The controlplane variant tested `date -u +%s%3N` directly; the canonical version derives it from `_detect_now_ns()`. Functionally equivalent.

**Skip `tests/tuning/004-compare-profiles.sh`.** This script doesn't define `ROOT` and works standalone without sourcing `config/versions.env`. It only uses `die()`. Leave it unconverted; a one-liner inline `die()` is fine for an outlier.

**write_preamble() parameterization.** Add a `$1` title argument: `write_preamble <title> <tsv_file> <kv pairs...>`. Callers pass their suite name (e.g., `"churn-dataplane co-exec test"`). This is the only behavioral micro-change in the refactor.

---

## Scope Boundaries

**In scope:** Functions identical or trivially unifiable across suites (see R1-R4). bats-core tests for pure-logic functions. verify.sh gate. AGENTS.md documentation.

**Stays inline (divergent):** `report_*()` formatters, `aggregate()`, `delta_histogram()` (different semantics per suite), `cleanup()`/`cleanup_all()`, `start_port_forward()`/`start_istiod_pf()`, controlplane/002 string-based metric extractors, propagation/002 `probe_kube_versions()`.

### Deferred to Follow-Up Work

- Unifying divergent functions (tier 2) once the shared lib pattern is proven.
- Metric glossary in markdown reports (issue #17) — depends on this work.
- CI integration for verify.sh.

---

## Output Structure

```
tests/lib/
├── common.sh
├── timestamp.sh
├── preamble.sh
├── metrics.sh
├── verify.sh
└── test/
    ├── bats-core/          (git submodule)
    ├── bats-assert/        (git submodule)
    ├── bats-support/       (git submodule)
    ├── test_helper.bash
    ├── common.bats
    ├── timestamp.bats
    ├── metrics.bats
    └── fixtures/
        ├── prometheus_counters.txt
        ├── prometheus_gauges.txt
        ├── histogram_pre.txt
        └── histogram_post.txt
```

---

## Implementation Units

### U1. Set up bats-core submodules

**Goal:** Establish the test infrastructure so subsequent units can add tests alongside lib files.

**Requirements:** R11, R12

**Dependencies:** None

**Files:**
- `tests/lib/test/bats-core/` (submodule → `https://github.com/bats-core/bats-core`)
- `tests/lib/test/bats-assert/` (submodule → `https://github.com/bats-core/bats-assert`)
- `tests/lib/test/bats-support/` (submodule → `https://github.com/bats-core/bats-support`)
- `tests/lib/test/test_helper.bash`
- `.gitmodules` (updated)

**Approach:** Add three submodules pinned to latest stable tags. Create `test_helper.bash` that loads bats-support and bats-assert and sets up `ROOT` for sourcing lib files under test. This file is sourced by every `.bats` file via `load test_helper`.

**Patterns to follow:** bats-core convention — `setup()` loads helpers, each `@test` block is one assertion.

**Test scenarios:**
- Verify `bats --version` runs successfully from the submodule path
- Verify `test_helper.bash` loads without error

**Verification:** `tests/lib/test/bats-core/bin/bats tests/lib/test/test_helper.bash` runs without error.

---

### U2. Create `tests/lib/common.sh` and convert all scripts

**Goal:** Extract the most-duplicated functions and convert every script to source from the shared lib. This is the largest unit — it touches ~29 scripts but each edit is mechanical (add source line, delete inline definition).

**Requirements:** R1, R5, R6, R7, R8, R15, R17

**Dependencies:** None (can be done before or after U1)

**Files:**
- `tests/lib/common.sh` (create)
- `tests/lib/test/common.bats` (create)
- All scripts under `tests/churn/`, `tests/controlplane/`, `tests/dataplane/`, `tests/propagation/`, `tests/tuning/` except `tests/tuning/004-compare-profiles.sh`
- `tests/churn-dataplane/001-setup-coexec-test.sh`, `004-run-sweep.sh`, `005-report-results.sh`, `006-cleanup.sh`

**Approach:**

Create `tests/lib/common.sh` from the canonical implementations:
- `die()` — from `tests/churn-dataplane/lib/preamble.sh:20`
- `split_csv()` — from `tests/churn-dataplane/lib/preamble.sh:62-73`
- `is_pos_int()` — from `tests/controlplane/001-setup-controlplane-test.sh:49`
- `validate_scoping()` — from `tests/controlplane/001-setup-controlplane-test.sh:52-57`

Add header comment listing all 6 suites. Add `# shellcheck disable=SC2329` per existing convention.

For each consuming script:
1. Add `source "${ROOT}/tests/lib/common.sh"` after the existing `source "${ROOT}/config/versions.env"` line
2. Delete inline `die()` definition
3. Delete inline `split_csv()` definition (where present)
4. Delete inline `is_pos_int()`, `validate_scoping()` definitions (controlplane scripts only)
5. In `tests/controlplane/003-run-sweep.sh`: rename `validate_scoping_value` → `validate_scoping` at both definition and callsite

For churn-dataplane scripts that currently source `lib/preamble.sh` (which provides `die` and `split_csv`): add `source "${ROOT}/tests/lib/common.sh"` but keep the existing preamble.sh source line for now — it still provides the other functions. Remove `die()` and `split_csv()` from `tests/churn-dataplane/lib/preamble.sh` to avoid redefinition.

**Patterns to follow:** Existing `source` + `# shellcheck disable=SC1091` pattern used throughout the codebase.

**Test scenarios:**
- `split_csv`: empty string → empty array
- `split_csv`: single value → one-element array
- `split_csv`: `"a, b , c"` → `["a", "b", "c"]` (whitespace trimmed)
- `split_csv`: trailing comma → no empty element
- `is_pos_int`: `"5"` → success (exit 0)
- `is_pos_int`: `"0"` → failure (exit 1)
- `is_pos_int`: `"-1"` → failure
- `is_pos_int`: `"abc"` → failure
- `validate_scoping`: `"none"`, `"namespace"`, `"explicit"` → success
- `validate_scoping`: `"invalid"` → calls die (exit 1)
- `die`: outputs to stderr and exits 1

**Verification:** `bash -n` on all modified scripts passes. `grep -rn 'die() {' tests/ --include='*.sh' | grep -v tests/lib/ | grep -v tests/tuning/004` returns no matches. bats tests pass.

---

### U3. Create `tests/lib/timestamp.sh` and convert probe scripts

**Goal:** Extract portable timestamp detection into a shared file and convert the 4 probe scripts that use timing functions.

**Requirements:** R2, R5, R6, R7, R13, R17

**Dependencies:** U2 (common.sh must exist since timestamp functions use `die()` for error cases)

**Files:**
- `tests/lib/timestamp.sh` (create)
- `tests/lib/test/timestamp.bats` (create)
- `tests/churn/002-run-churn-probe.sh`
- `tests/controlplane/002-collect-resource-metrics.sh`
- `tests/propagation/002-run-endpoint-probe.sh`
- `tests/churn-dataplane/002-run-baseline-probe.sh`, `003-run-churn-probe.sh` (already source preamble.sh — remove timing functions from preamble.sh)

**Approach:**

Create `tests/lib/timestamp.sh` from `tests/churn-dataplane/lib/preamble.sh:25-59`:
- `_detect_now_ns()` with cached `NOW_NS_IMPL`
- `now_ns()`
- `now_ms()`

For `tests/controlplane/002-collect-resource-metrics.sh`: replace `_detect_now_ms()` + its `now_ms()` variant with `source "${ROOT}/tests/lib/timestamp.sh"`. The canonical `now_ms()` produces identical output.

Remove `_detect_now_ns()`, `now_ns()`, `now_ms()` from `tests/churn-dataplane/lib/preamble.sh`.

**Test scenarios:**
- `now_ns`: output matches `^[0-9]+$`
- `now_ns`: output is within plausible range (current epoch in nanoseconds ±1 hour)
- `now_ms`: output matches `^[0-9]+$`
- `now_ms`: output length is 13 digits (millisecond epoch)
- `_detect_now_ns`: sets `NOW_NS_IMPL` to one of `date`, `gdate`, `python3`, `perl`
- `_detect_now_ns`: second call is a no-op (cached)

**Verification:** `bash -n` on modified scripts. `grep -rn '_detect_now_ns\|_detect_now_ms' tests/ --include='*.sh' | grep -v tests/lib/` returns no matches. bats tests pass.

---

### U4. Create `tests/lib/preamble.sh` and `tests/lib/metrics.sh`, promote and delete old lib/

**Goal:** Promote the remaining functions from `tests/churn-dataplane/lib/` to the global lib, convert all consumers, and delete the old suite-local lib directory.

**Requirements:** R3, R4, R5, R6, R7, R9, R10, R11, R12, R17

**Dependencies:** U2, U3 (common.sh and timestamp.sh must exist — preamble.sh and metrics.sh depend on functions from both)

**Files:**
- `tests/lib/preamble.sh` (create)
- `tests/lib/metrics.sh` (create)
- `tests/lib/test/metrics.bats` (create)
- `tests/lib/test/fixtures/prometheus_counters.txt` (create)
- `tests/lib/test/fixtures/prometheus_gauges.txt` (create)
- `tests/lib/test/fixtures/histogram_pre.txt` (create)
- `tests/lib/test/fixtures/histogram_post.txt` (create)
- `tests/churn-dataplane/001-setup-coexec-test.sh`, `002-run-baseline-probe.sh`, `003-run-churn-probe.sh`, `004-run-sweep.sh`, `006-cleanup.sh`
- `tests/churn/002-run-churn-probe.sh` (uses `delta_histogram_p99`)
- `tests/churn-dataplane/lib/preamble.sh` (delete)
- `tests/churn-dataplane/lib/metrics.sh` (delete)
- `tests/churn-dataplane/lib/` (delete directory)

**Approach:**

Create `tests/lib/preamble.sh` from what remains in `tests/churn-dataplane/lib/preamble.sh` after U2 and U3 removed `die`, `split_csv`, and timing functions:
- `harness_sha()`, `kube_versions()`, `probe_kube_versions()`, `istiod_restart_status()`, `istiod_start_time_seconds()`, `write_preamble()`
- Parameterize `write_preamble()`: change signature from `write_preamble <tsv> <kv...>` to `write_preamble <title> <tsv> <kv...>`. The hardcoded `echo "# churn-dataplane co-exec test"` becomes `echo "# ${title}"`.

Create `tests/lib/metrics.sh` — copy `tests/churn-dataplane/lib/metrics.sh` as-is (all functions already removed from preamble.sh dependencies are in common.sh/timestamp.sh).

Update churn-dataplane scripts: replace `source "${ROOT}/tests/churn-dataplane/lib/preamble.sh"` with `source "${ROOT}/tests/lib/preamble.sh"` (and similarly for metrics.sh). Update `write_preamble` callsites to pass the title as the first argument.

Update `tests/churn/002-run-churn-probe.sh`: its inline `delta_histogram_p99()` takes string data via process substitution. Add `source "${ROOT}/tests/lib/metrics.sh"`, delete the inline definition, and write histogram data to temp files (the script already uses `TMPDIR_RUN`) before calling the file-based `delta_histogram_p99`.

Delete `tests/churn-dataplane/lib/preamble.sh`, `tests/churn-dataplane/lib/metrics.sh`, and the `tests/churn-dataplane/lib/` directory.

Create fixture files with realistic Prometheus metrics output for deterministic testing.

**Test scenarios:**

`extract_counter_sum`:
- Multi-instance counter (3 lines with same metric name, different labels) → sum of values
- Missing counter name → `0`
- File with only comment lines → `0`
- Counter with `{label="value"}` and bare counter → both counted

`extract_counter_by_label`:
- Filter by `type="cds"` → sum of matching lines only
- No matching label value → `0`

`extract_gauge`:
- Single gauge line → value extracted
- Gauge not present → empty output

`delta_histogram_p99`:
- Normal case: pre and post histogram files with known bucket distribution → expected p99 value
- All traffic in one bucket → p99 equals that bucket boundary
- Negative delta in a bucket (counter reset) → returns `N/A`
- Missing histogram name in file → returns `N/A`

**Verification:** `bash -n` on all modified scripts. `grep -rn 'churn-dataplane/lib' tests/ --include='*.sh'` returns no matches. `ls tests/churn-dataplane/lib/` fails (directory deleted). bats tests pass.

---

### U5. Create `tests/lib/verify.sh`

**Goal:** Build the pre-merge gate that validates the full source chain and catches inline-definition regressions.

**Requirements:** R14

**Dependencies:** U1, U2, U3, U4 (all lib files and tests must exist)

**Files:**
- `tests/lib/verify.sh` (create)

**Approach:**

Create an executable script that runs five checks in order, failing fast on the first error:

1. `bash -n` on every `.sh` file under `tests/`
2. `shellcheck` on all `tests/lib/*.sh` and `tests/*/*.sh`
3. Grep audit: confirm `die() {`, `split_csv() {`, `_detect_now_ns()`, `now_ns() {`, `now_ms() {`, `extract_counter_sum() {`, etc. do not appear outside `tests/lib/` (with an exception list for `tests/tuning/004-compare-profiles.sh` and known inline-only functions)
4. Run bats test suite: `tests/lib/test/bats-core/bin/bats tests/lib/test/*.bats`
5. Dry-run all sweep scripts with a dummy context:
   - `tests/churn/003-run-sweep.sh --dry-run --contexts ci-dummy`
   - `tests/controlplane/003-run-sweep.sh --dry-run --contexts ci-dummy`
   - `tests/dataplane/003-run-sweep.sh --dry-run --contexts ci-dummy`
   - `tests/propagation/006-run-sweep.sh --dry-run --contexts ci-dummy`
   - `tests/churn-dataplane/004-run-sweep.sh --dry-run --contexts ci-dummy`
   - `tests/tuning/003-run-tuning-sweep.sh --dry-run --contexts ci-dummy`

The script should support `--skip-dry-run` for environments without kubectl/oc.

**Test scenarios:**

Test expectation: none — this is a meta-verification script. Its correctness is validated by running it against the completed refactoring.

**Verification:** `verify.sh` exits 0 on the refactored codebase. Intentionally re-adding an inline `die()` to one script causes the grep audit to fail.

---

### U6. Update AGENTS.md

**Goal:** Document the shared lib, sourcing convention, and verify.sh requirement.

**Requirements:** R16

**Dependencies:** U2, U3, U4, U5

**Files:**
- `AGENTS.md`

**Approach:**

Add to the repository map table:
- `tests/lib/` — Shared bash helper functions sourced by all test suites
- `tests/lib/test/` — bats-core unit tests for shared helpers

Add to the "Script variables and naming" section or a new subsection:
- Convention: scripts source `"${ROOT}/tests/lib/common.sh"` (and optionally `timestamp.sh`, `preamble.sh`, `metrics.sh`) after `config/versions.env`
- Requirement: changes to `tests/lib/*.sh` must pass `tests/lib/verify.sh` before merge

Add to testing guidance:
- bats-core is vendored as git submodules under `tests/lib/test/`
- Run tests with `tests/lib/test/bats-core/bin/bats tests/lib/test/*.bats`

**Test scenarios:**

Test expectation: none — documentation-only change.

**Verification:** AGENTS.md mentions `tests/lib/`, `verify.sh`, and bats-core.

---

## Risks & Dependencies

**controlplane/002 `now_ms()` replacement.** The controlplane variant uses `_detect_now_ms()` which tests `date -u +%s%3N` directly. The canonical version derives milliseconds from `_detect_now_ns()`. Both produce millisecond timestamps, but the code path is slightly different. Risk is low — the platform detection covers the same cases — but this script should be specifically validated against a real cluster in its phase.

**churn/002 `delta_histogram_p99()` API change.** The inline version uses process substitution (`<(echo "$pre")`); the canonical version takes file paths. The conversion requires writing histogram data to temp files first. The awk logic is identical, so output should match, but the script should be validated end-to-end.

**Submodule initialization.** Contributors cloning the repo will need `git submodule update --init` to get bats-core. This is a new requirement that should be called out in the README or AGENTS.md.

---

## Sources & Research

- `tests/churn-dataplane/lib/preamble.sh` — canonical source for common.sh, timestamp.sh, and preamble.sh functions (197 lines, well-documented with `# shellcheck` annotations)
- `tests/churn-dataplane/lib/metrics.sh` — canonical source for metrics.sh functions (138 lines, file-based API)
- `.shellcheckrc` — already disables SC1091 globally (source-following), SC2155, SC2317
- AGENTS.md lines 39-48 — existing ROOT resolution and sourcing conventions
- Function audit from brainstorm session — confirmed 8 functions identical across all sites, 6 with minor differences, ~10 divergent (stay inline)
