---
RUN_ID: "mixed:20261027T165116Z-3947058,20261027T165400Z-3948457,20261027T165719Z-3950551,20261027T170233Z-3953232,20261027T170803Z-3957051,20261027T171508Z-3961161,20261027T172248Z-3966242,20261027T173206Z-3972975,20261027T174210Z-3981385,20261027T175339Z-4003634"
DATE: "mixed:2026-10-27T16:51:17+00:00,2026-10-27T16:54:01+00:00,2026-10-27T16:57:19+00:00,2026-10-27T17:02:34+00:00,2026-10-27T17:08:04+00:00,2026-10-27T17:15:09+00:00,2026-10-27T17:22:49+00:00,2026-10-27T17:32:07+00:00,2026-10-27T17:42:11+00:00,2026-10-27T17:53:40+00:00"
HARNESS_SHA: "bf258af"
ISTIO_VERSION: "v1.30.5"
ISTIO_VERSION_PIN: "v1.30.5"
ISTIO_VERSION_SOURCE: "live"
ISTIO_VERSION_BY_CONTEXT: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5"
ISTIO_ACTIVE_REVISIONS: "<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default"
ISTIO_GENERATIONS: "<mesh-a-ctx>=7/7,<mesh-b-ctx>=7/7,<mesh-c-ctx>=7/7,<mesh-d-ctx>=7/7,<mesh-e-ctx>=7/7"
KUBE_VERSIONS: "mixed:<mesh-a-ctx>=v1.34.6 | <mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6 | <mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6 | <mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6 | <mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6,<mesh-e-ctx>=v1.34.6"
FORTIO_IMAGE: "fortio/fortio:1.75.3"
SETTLE_SEC: "30"
WARMUP_DURATION_SEC: "5"
QPS_LEVELS: "10,100,500,1000"
DURATION_SEC: "30"
CONNECTIONS: "8"
SOURCE_CTX: "<mesh-a-ctx>"
REMOTE_CONTEXTS: "mixed:(empty) | <mesh-b-ctx> | <mesh-b-ctx>,<mesh-c-ctx> | <mesh-b-ctx>,<mesh-c-ctx>,<mesh-d-ctx> | <mesh-b-ctx>,<mesh-c-ctx>,<mesh-d-ctx>,<mesh-e-ctx>"
MESH_SIZE: "mixed:1,2,3,4,5"
NAMESPACE: "dataplane-test"
TUNING_BASELINE: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
SIDECAR_EGRESS_HOSTS: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
SERVER_REPLICAS: "mixed:<mesh-a-ctx>=2/2 | <mesh-a-ctx>=2/2,<mesh-b-ctx>=2/2 | <mesh-a-ctx>=2/2,<mesh-b-ctx>=2/2,<mesh-c-ctx>=2/2 | <mesh-a-ctx>=2/2,<mesh-b-ctx>=2/2,<mesh-c-ctx>=2/2,<mesh-d-ctx>=2/2 | <mesh-a-ctx>=2/2,<mesh-b-ctx>=2/2,<mesh-c-ctx>=2/2,<mesh-d-ctx>=2/2,<mesh-e-ctx>=2/2"
MIN_QPS_RATIO: "0.95"
MIN_PCT_200: "0.99"
REACH_REQUESTS: "10"
REACH_QPS: "10"
REACH_HTTP_TIMEOUT_SEC: "3"
REACH_DETAIL_TIMEOUT_SEC: "35"
REACH_ATTEMPTS: "3"
REACH_RETRY_SEC: "10"
ON_UNREACHABLE: "warn"
RUN_CONFIG: "tests/campaign/profiles/rosa/dataplane.env"
RUN_CONFIG_SHA256: "db074568fba1090eabad72c8a08100bb7f5f9f6eabc97bba207a95e613e1afcc"
PLATFORM: "openshift"
TEST_PLATFORM: "auto"
PLATFORM_BY_CONTEXT: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift,<mesh-c-ctx>=openshift,<mesh-d-ctx>=openshift,<mesh-e-ctx>=openshift"
MESH_OPERATOR_BY_CONTEXT: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3,<mesh-c-ctx>=servicemeshoperator3:3.4.3,<mesh-d-ctx>=servicemeshoperator3:3.4.3,<mesh-e-ctx>=servicemeshoperator3:3.4.3"
ISTIOD_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-c-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-d-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-e-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
PROXY_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-c-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-d-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-e-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
NODE_PROVIDER_BY_CONTEXT: "<mesh-a-ctx>=aws,<mesh-b-ctx>=aws,<mesh-c-ctx>=aws,<mesh-d-ctx>=aws,<mesh-e-ctx>=aws"
ISTIOD_ENV_BY_CONTEXT: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772,<mesh-c-ctx>=0c3d8d887772,<mesh-d-ctx>=0c3d8d887772,<mesh-e-ctx>=0c3d8d887772"
generated: "2026-10-27T18:05:43+00:00"
---

# Data-Plane Latency — Charts

```mermaid
xychart-beta
    title "p50 Latency vs Mesh Size (QPS 1000)"
    x-axis "Mesh Size" [2, 3, 4, 5]
    y-axis "Latency (ms)"
    line [1.72, 1.73, 1.74, 1.72]
    line [2.57, 2.65, 2.60, 2.71]
```

> Series order: **local**, **remote**. The gap is the cross-cluster overhead.

```mermaid
xychart-beta
    title "p50 Latency vs QPS (Mesh Size 5)"
    x-axis "QPS" [10, 100, 500, 1000]
    y-axis "Latency (ms)"
    line [2.52, 2.28, 1.96, 1.72]
    line [4.03, 3.56, 3.14, 2.71]
```

> Series order: **local**, **remote** at mesh size 5.
