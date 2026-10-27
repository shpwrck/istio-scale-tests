---
RUN_ID: "mixed:20261027T132416Z-1970784,20261027T132700Z-1978356,20261027T133019Z-1985957,20261027T133514Z-1998171,20261027T134045Z-2009157,20261027T134749Z-2020070,20261027T135531Z-2028413,20261027T140442Z-2046396,20261027T141434Z-2063227,20261027T142601Z-2083645"
DATE: "mixed:2026-10-27T13:24:17+00:00,2026-10-27T13:27:01+00:00,2026-10-27T13:30:20+00:00,2026-10-27T13:35:15+00:00,2026-10-27T13:40:46+00:00,2026-10-27T13:47:50+00:00,2026-10-27T13:55:32+00:00,2026-10-27T14:04:43+00:00,2026-10-27T14:14:35+00:00,2026-10-27T14:26:01+00:00"
HARNESS_SHA: "d21a197"
ISTIO_VERSION: "v1.30.5"
ISTIO_VERSION_PIN: "v1.30.5"
ISTIO_VERSION_SOURCE: "live"
ISTIO_VERSION_BY_CONTEXT: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5"
ISTIO_ACTIVE_REVISIONS: "<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default"
ISTIO_GENERATIONS: "<mesh-a-ctx>=1/1,<mesh-b-ctx>=1/1,<mesh-c-ctx>=1/1,<mesh-d-ctx>=1/1,<mesh-e-ctx>=1/1"
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
generated: "2026-10-27T14:38:04+00:00"
---

# Data-Plane Latency — Charts

```mermaid
xychart-beta
    title "p50 Latency vs Mesh Size (QPS 1000)"
    x-axis "Mesh Size" [2, 3, 4, 5]
    y-axis "Latency (ms)"
    line [1.73, 1.69, 1.71, 1.72]
    line [2.71, 2.54, 2.61, 2.61]
```

> Series order: **local**, **remote**. The gap is the cross-cluster overhead.

```mermaid
xychart-beta
    title "p50 Latency vs QPS (Mesh Size 5)"
    x-axis "QPS" [10, 100, 500, 1000]
    y-axis "Latency (ms)"
    line [2.47, 2.03, 1.93, 1.72]
    line [3.80, 3.50, 3.05, 2.61]
```

> Series order: **local**, **remote** at mesh size 5.
