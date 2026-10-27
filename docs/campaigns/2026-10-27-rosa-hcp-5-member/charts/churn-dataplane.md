---
run_id: "20261027T151327Z-3162743"
harness_sha: "d21a197"
istio_version: "v1.30.5"
istio_version_source: "live"
istio_version_pin: "v1.30.5"
istio_version_by_context: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5"
istio_active_revisions: "<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default"
istio_generations: "<mesh-a-ctx>=1/1,<mesh-b-ctx>=1/1,<mesh-c-ctx>=1/1,<mesh-d-ctx>=1/1,<mesh-e-ctx>=1/1"
kube_versions: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6,<mesh-e-ctx>=v1.34.6"
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
run_config: "tests/campaign/profiles/rosa/churn-dataplane.env"
run_config_sha256: "f09b6903b7a263d5a80e9fa6130ce613401a4a26ea31ae070e02de967ff8d98d"
platform: "openshift"
test_platform: "auto"
platform_by_context: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift,<mesh-c-ctx>=openshift,<mesh-d-ctx>=openshift,<mesh-e-ctx>=openshift"
mesh_operator_by_context: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3,<mesh-c-ctx>=servicemeshoperator3:3.4.3,<mesh-d-ctx>=servicemeshoperator3:3.4.3,<mesh-e-ctx>=servicemeshoperator3:3.4.3"
istiod_image_by_context: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-c-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-d-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-e-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
proxy_image_by_context: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-c-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-d-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-e-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
node_provider_by_context: "<mesh-a-ctx>=aws,<mesh-b-ctx>=aws,<mesh-c-ctx>=aws,<mesh-d-ctx>=aws,<mesh-e-ctx>=aws"
istiod_env_by_context: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772,<mesh-c-ctx>=0c3d8d887772,<mesh-d-ctx>=0c3d8d887772,<mesh-e-ctx>=0c3d8d887772"
generated: 2026-10-27T16:32:03+00:00
---

# Churn x Data-Plane — Charts

% Chart 1: Δp99 Tail Latency vs Mesh Size

```mermaid
xychart-beta
    title "Δp99 Tail Latency vs Mesh Size"
    x-axis "Mesh Size" [1, 2, 3, 4, 5]
    y-axis "Δp99 (ms)"
    line [3.06, 10.58, 12.32, 10.12, 10.88]
    line [9.09, 20.18, 17.83, 20.58, 20.75]
    line [7.89, 21.18, 24.52, 21.49, 21.74]
```

> Series order (by churn rate): **1** **5** **10**. Expected: ~flat across mesh size.

% Chart 2: istiod EDS Pushes vs Mesh Size

```mermaid
xychart-beta
    title "istiod EDS Pushes vs Mesh Size"
    x-axis "Mesh Size" [1, 2, 3, 4, 5]
    y-axis "EDS push count"
    line [3820, 4035, 3750, 2665, 2430]
    line [4512, 4637, 4571, 3125, 4629]
    line [9200, 8982, 8113, 5364, 5899]
```

> Series order (by churn rate): **1** **5** **10**. Expected: scales with churn rate, ~flat across mesh size.

