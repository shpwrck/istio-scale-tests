---
SWEEP_RUN_ID: "20261027T143912Z-2380553"
HARNESS_SHA: "d21a197"
ISTIO_VERSION: "v1.30.5"
ISTIO_VERSION_PIN: "v1.30.5"
ISTIO_VERSION_SOURCE: "live"
ISTIO_VERSION_BY_CONTEXT: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5"
ISTIO_ACTIVE_REVISIONS: "<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default"
ISTIO_GENERATIONS: "<mesh-a-ctx>=1/1,<mesh-b-ctx>=1/1,<mesh-c-ctx>=1/1,<mesh-d-ctx>=1/1,<mesh-e-ctx>=1/1"
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
RUN_CONFIG: "tests/campaign/profiles/rosa/propagation.env"
RUN_CONFIG_SHA256: "9dd833c17bd66ac30a2c1fb991ccf7c0de3a6974d2f42885ead2a309e4835d2c"
PLATFORM: "openshift"
TEST_PLATFORM: "auto"
PLATFORM_BY_CONTEXT: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift,<mesh-c-ctx>=openshift,<mesh-d-ctx>=openshift,<mesh-e-ctx>=openshift"
MESH_OPERATOR_BY_CONTEXT: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3,<mesh-c-ctx>=servicemeshoperator3:3.4.3,<mesh-d-ctx>=servicemeshoperator3:3.4.3,<mesh-e-ctx>=servicemeshoperator3:3.4.3"
ISTIOD_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-c-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-d-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-e-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
PROXY_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-c-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-d-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-e-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
NODE_PROVIDER_BY_CONTEXT: "<mesh-a-ctx>=aws,<mesh-b-ctx>=aws,<mesh-c-ctx>=aws,<mesh-d-ctx>=aws,<mesh-e-ctx>=aws"
ISTIOD_ENV_BY_CONTEXT: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772,<mesh-c-ctx>=0c3d8d887772,<mesh-d-ctx>=0c3d8d887772,<mesh-e-ctx>=0c3d8d887772"
iterations:
  -
    RUN_ID: "20261027T143920Z-2382827"
    DATE: "2026-10-27T14:39:21+00:00"
    MESH_SIZE: "1"
    REMOTES: "none"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6"
  -
    RUN_ID: "20261027T144050Z-2386779"
    DATE: "2026-10-27T14:40:51+00:00"
    MESH_SIZE: "2"
    REMOTES: "<mesh-b-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6"
  -
    RUN_ID: "20261027T144229Z-2393975"
    DATE: "2026-10-27T14:42:30+00:00"
    MESH_SIZE: "3"
    REMOTES: "<mesh-b-ctx> <mesh-c-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6"
  -
    RUN_ID: "20261027T144415Z-2401746"
    DATE: "2026-10-27T14:44:16+00:00"
    MESH_SIZE: "4"
    REMOTES: "<mesh-b-ctx> <mesh-c-ctx> <mesh-d-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6"
  -
    RUN_ID: "20261027T144609Z-2410551"
    DATE: "2026-10-27T14:46:11+00:00"
    MESH_SIZE: "5"
    REMOTES: "<mesh-b-ctx> <mesh-c-ctx> <mesh-d-ctx> <mesh-e-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6,<mesh-e-ctx>=v1.34.6"
tsv_columns: [23]
generated: 2026-10-27T14:48:49+00:00
---

# Endpoint Propagation Latency — Charts

```mermaid
xychart-beta
    title "P1 + P2 Latency vs Mesh Size"
    x-axis "Mesh Size" [2, 3, 4, 5]
    y-axis "Latency (ms)"
    line [668, 661, 678, 636]
    line [673, 617, 674, 620]
```

> Series order: **P1 wall avg** (ms), **P2 EDS avg** (ms).
> x-axis starts at mesh 2 — P2 is undefined at mesh size 1 (no remote cluster).

```mermaid
xychart-beta
    title "P3 Remote Sidecar Latency vs Mesh Size"
    x-axis "Mesh Size" [2, 3, 4, 5]
    y-axis "Latency (ms)"
    line [644, 604, 682, 625]
```

> Series: **P3 sidecar avg** (ms). Separate chart — P3 is typically ~10x P1/P2 scale.
