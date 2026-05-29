---
name: istio-scale-tests
last_updated: 2026-05-29
---

# istio-scale-tests Strategy

## Target problem

Multi-cluster Istio has too many interacting scaling dimensions and tuning factors — mesh size, workload count, cluster topology, configuration knobs — to reason about analytically. The only way to know if it will meet a deployment's demands is to measure empirically with successive parameterized tests, and there's no repeatable way to do that today.

## Our approach

A full-lifecycle harness — provision, test, tune, report — where users can enter at any stage with what they already have. Covering the whole workflow end-to-end is what makes the scaling question actually answerable, because skipping a stage is where people get unreliable results.

## Who it's for

**Primary:** Platform architects evaluating greenfield multi-cluster Istio deployments — they're hiring istio-scale-tests to get empirical answers about whether Istio can meet their scale requirements before committing.

## Key metrics

- **Dimension coverage** — number of scaling dimensions answerable by existing test suites
- **Result reproducibility** — variance across identical runs on the same infrastructure
- **Profile effectiveness** — measurable performance improvement from recommended tuning profiles vs. baseline
- **Operator error rate** — how often a test run fails or needs re-run due to parameter misconfiguration

## Tracks

### Provisioning

Automated cluster and mesh standup from zero — the target user is evaluating greenfield deployments and usually has no existing infrastructure to test on.

_Why it serves the approach:_ The harness can't be full-lifecycle if the user has to manually build clusters before they can start.

### Tests

Parameterized test suites covering scaling dimensions: xDS propagation, control-plane resources, data-plane latency, churn convergence.

_Why it serves the approach:_ The suites encode subject matter expertise about what to measure and how — knowledge the evaluating architect wouldn't have themselves.

### Profiling

Tuning profile evaluation curated for Red Hat OpenShift Service Mesh, turning test results into actionable configuration recommendations.

_Why it serves the approach:_ Profiles are validated against what OSSM actually supports, not generic upstream Istio — this is a Red Hat-driven project.

### Reporting

Human-readable output — markdown summaries, sweep reports — designed for both the technical operator and the decision-makers above them.

_Why it serves the approach:_ Without clear reports, test results stay locked in the head of whoever ran them and can't drive an organizational decision.

## Not working on

- Ambient mesh support
- Integration with external observability products (Prometheus, OpenTelemetry, Kiali)
