---
SWEEP_RUN_ID: "20261027T123230Z-1688793"
HARNESS_SHA: "d21a197"
ISTIO_VERSION: "v1.30.5"
ISTIO_VERSION_PIN: "v1.30.5"
ISTIO_VERSION_SOURCE: "live"
ISTIO_VERSION_BY_CONTEXT: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5"
ISTIO_ACTIVE_REVISIONS: "<mesh-a-ctx>=default,<mesh-b-ctx>=default"
ISTIO_GENERATIONS: "<mesh-a-ctx>=3/3,<mesh-b-ctx>=3/3"
SOURCE_CTX: "<mesh-a-ctx>"
ITERATIONS: "10"
POLL_INTERVAL_S: "0.250"
TIMEOUT_SEC: "120"
SETTLE_SEC: "5"
FANOUT_MAX_SKEW_MS: "1000"
FANOUT_METRICS_TIMEOUT: "30"
BACKER_IMAGE: "hashicorp/http-echo:1.0"
TUNING_BASELINE: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
SIDECAR_EGRESS_HOSTS: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
RUN_CONFIG: "tests/campaign/profiles/openshift/propagation.env"
RUN_CONFIG_SHA256: "4baeb61b07828632702307d79ea481872e9c08d18df6d951c0129a6f8be29651"
PLATFORM: "openshift"
TEST_PLATFORM: "auto"
PLATFORM_BY_CONTEXT: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift"
MESH_OPERATOR_BY_CONTEXT: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3"
ISTIOD_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
PROXY_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
NODE_PROVIDER_BY_CONTEXT: "<mesh-a-ctx>=none,<mesh-b-ctx>=none"
ISTIOD_ENV_BY_CONTEXT: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772"
iterations:
  -
    RUN_ID: "20261027T123240Z-1689738"
    DATE: "2026-10-27T12:32:41+00:00"
    MESH_SIZE: "1"
    REMOTES: "none"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.8"
  -
    RUN_ID: "20261027T123357Z-1697307"
    DATE: "2026-10-27T12:33:58+00:00"
    MESH_SIZE: "2"
    REMOTES: "<mesh-b-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.8,<mesh-b-ctx>=v1.34.8"
tsv_columns: [23]
generated: 2026-10-27T15:00:02+00:00
---

# Endpoint Propagation Latency — Charts

> The mesh-size charts require at least two mesh sizes with remote data (mesh >= 2); below, what this run can show.

```mermaid
xychart-beta
    title "P1 Local xDS Latency vs Mesh Size"
    x-axis "Mesh Size" [1, 2]
    y-axis "Latency (ms)"
    line [737, 1173]
```

> Series: **P1 local xDS (wall)**, the mean over valid iterations; a mesh size with none is left out.

```mermaid
xychart-beta
    title "Propagation Phases at Mesh Size 2"
    x-axis ["P1 local xDS", "P2 remote EDS", "P3 remote sidecar"]
    y-axis "Latency (ms)"
    bar [1173, 1172, 1864]
```

> Means over valid samples (P1 per iteration, P2 and P3 per remote row) at the one mesh size with remote data.
