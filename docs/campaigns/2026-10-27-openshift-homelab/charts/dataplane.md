---
RUN_ID: "mixed:20261027T121927Z-1654456,20261027T122137Z-1656601,20261027T122419Z-1662849,20261027T122807Z-1674363"
DATE: "mixed:2026-10-27T12:19:27+00:00,2026-10-27T12:21:37+00:00,2026-10-27T12:24:20+00:00,2026-10-27T12:28:08+00:00"
HARNESS_SHA: "d21a197"
ISTIO_VERSION: "v1.30.5"
ISTIO_VERSION_PIN: "v1.30.5"
ISTIO_VERSION_SOURCE: "live"
ISTIO_VERSION_BY_CONTEXT: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5"
ISTIO_ACTIVE_REVISIONS: "<mesh-a-ctx>=default,<mesh-b-ctx>=default"
ISTIO_GENERATIONS: "<mesh-a-ctx>=3/3,<mesh-b-ctx>=3/3"
KUBE_VERSIONS: "mixed:<mesh-a-ctx>=v1.34.8 | <mesh-a-ctx>=v1.34.8,<mesh-b-ctx>=v1.34.8"
FORTIO_IMAGE: "fortio/fortio:1.75.3"
SETTLE_SEC: "30"
WARMUP_DURATION_SEC: "5"
QPS_LEVELS: "10,100,500"
DURATION_SEC: "30"
CONNECTIONS: "8"
SOURCE_CTX: "<mesh-a-ctx>"
REMOTE_CONTEXTS: "mixed:(empty),<mesh-b-ctx>"
MESH_SIZE: "mixed:1,2"
NAMESPACE: "dataplane-test"
TUNING_BASELINE: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
SIDECAR_EGRESS_HOSTS: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
SERVER_REPLICAS: "mixed:<mesh-a-ctx>=2/2 | <mesh-a-ctx>=2/2,<mesh-b-ctx>=2/2"
MIN_QPS_RATIO: "0.95"
MIN_PCT_200: "0.99"
REACH_REQUESTS: "10"
REACH_QPS: "10"
REACH_HTTP_TIMEOUT_SEC: "3"
REACH_DETAIL_TIMEOUT_SEC: "35"
REACH_ATTEMPTS: "3"
REACH_RETRY_SEC: "10"
ON_UNREACHABLE: "warn"
RUN_CONFIG: "tests/campaign/profiles/openshift/dataplane.env"
RUN_CONFIG_SHA256: "fd844b3c539fedbf3db5bbabade2f4ece8dc4d81765c70bc68ad09f4ff162e27"
PLATFORM: "openshift"
TEST_PLATFORM: "auto"
PLATFORM_BY_CONTEXT: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift"
MESH_OPERATOR_BY_CONTEXT: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3"
ISTIOD_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
PROXY_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
NODE_PROVIDER_BY_CONTEXT: "<mesh-a-ctx>=none,<mesh-b-ctx>=none"
ISTIOD_ENV_BY_CONTEXT: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772"
generated: "2026-10-27T12:32:26+00:00"
---

# Data-Plane Latency — Charts

> **Note (2026-10-27 lab run):** the sample was too small for the mesh-size chart. With two members only mesh size 2 has remote data, so only the QPS chart is generated. The numbers are in the [record](../README.md).

> The mesh-size chart needs two mesh sizes with remote data; only the QPS chart is shown.

```mermaid
xychart-beta
    title "p50 Latency vs QPS (Mesh Size 2)"
    x-axis "QPS" [10, 100, 500]
    y-axis "Latency (ms)"
    line [1.87, 1.83, 1.58]
    line [2.62, 2.51, 1.67]
```

> Series order: **local**, **remote** at mesh size 2.
