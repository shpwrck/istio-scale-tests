---
run_id: "20261027T124520Z-1791026"
harness_sha: "d21a197"
istio_version: "v1.30.5"
istio_version_source: "live"
istio_version_pin: "v1.30.5"
istio_version_by_context: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5"
istio_active_revisions: "<mesh-a-ctx>=default,<mesh-b-ctx>=default"
istio_generations: "<mesh-a-ctx>=3/3,<mesh-b-ctx>=3/3"
kube_versions: "<mesh-a-ctx>=v1.34.8,<mesh-b-ctx>=v1.34.8"
tuning_baseline: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
sidecar_egress_hosts: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
istiod_replicas: "1"
settle_sec: "10"
baseline_duration_sec: "60"
churn_duration_sec: "60"
qps: "200"
connections: "8"
namespace: "churn-dataplane-test"
fanout_max_skew_ms: "1000"
fanout_metrics_timeout: "30"
min_pct_200: "0.99"
reach_requests: "10"
reach_qps: "10"
reach_http_timeout_sec: "3"
reach_detail_timeout_sec: "35"
reach_attempts: "3"
reach_retry_sec: "10"
on_unreachable: "warn"
run_config: "tests/campaign/profiles/openshift/churn-dataplane.env"
run_config_sha256: "82adcfe3ce75f5f35f598bce6ac6b2924237c351666dfa64c2c1c267b169c497"
platform: "openshift"
test_platform: "auto"
platform_by_context: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift"
mesh_operator_by_context: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3"
istiod_image_by_context: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
proxy_image_by_context: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
node_provider_by_context: "<mesh-a-ctx>=none,<mesh-b-ctx>=none"
istiod_env_by_context: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772"
generated: 2026-10-27T12:59:31+00:00
---

# Churn x Data-Plane — Charts

% Chart 1: Δp99 Tail Latency vs Mesh Size

```mermaid
xychart-beta
    title "Δp99 Tail Latency vs Mesh Size"
    x-axis "Mesh Size" [1, 2]
    y-axis "Δp99 (ms)"
    line [5.08, 4.43]
    line [5.23, 5.29]
```

> Series order (by churn rate): **1** **5**. Expected: ~flat across mesh size.

% Chart 2: istiod EDS Pushes vs Mesh Size

```mermaid
xychart-beta
    title "istiod EDS Pushes vs Mesh Size"
    x-axis "Mesh Size" [1, 2]
    y-axis "EDS push count"
    line [1934, 2669]
    line [2268, 1962]
```

> Series order (by churn rate): **1** **5**. Expected: scales with churn rate, ~flat across mesh size.

