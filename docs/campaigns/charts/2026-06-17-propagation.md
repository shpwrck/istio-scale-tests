---
SWEEP_RUN_ID: "20260617T134154Z-470438"
HARNESS_SHA: "0461af1-dirty"
ISTIO_VERSION: "v1.28.5"
SOURCE_CTX: "cluster-002"
ITERATIONS: "10"
POLL_INTERVAL_S: "0.250"
TIMEOUT_SEC: "120"
SETTLE_SEC: "5"
FANOUT_MAX_SKEW_MS: "1000"
FANOUT_METRICS_TIMEOUT: "30"
BACKER_IMAGE: "hashicorp/http-echo:1.0"
TUNING_BASELINE: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
SIDECAR_EGRESS_HOSTS: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
iterations:
  -
    RUN_ID: "20260617T134215Z-470871"
    DATE: "2026-06-17T13:42:19+00:00"
    MESH_SIZE: "1"
    REMOTES: "none"
    KUBE_VERSIONS: "cluster-002=v1.34.6"
  -
    RUN_ID: "20260617T134456Z-475561"
    DATE: "2026-06-17T13:45:01+00:00"
    MESH_SIZE: "2"
    REMOTES: "cluster-003"
    KUBE_VERSIONS: "cluster-002=v1.34.6,cluster-003=v1.34.6"
  -
    RUN_ID: "20260617T134759Z-482462"
    DATE: "2026-06-17T13:48:06+00:00"
    MESH_SIZE: "3"
    REMOTES: "cluster-003 cluster-004"
    KUBE_VERSIONS: "cluster-002=v1.34.6,cluster-003=v1.34.6,cluster-004=v1.34.6"
generated: 2026-06-17T13:51:26+00:00
---

# Endpoint Propagation Latency — Charts

% Chart 1: P1 local xDS + P2 remote istiod EDS latency
% Series order: P1 wall avg (ms), P2 EDS avg (ms)
% x-axis starts at mesh 2 (P2 undefined at mesh 1)

```mermaid
xychart-beta
    title "P1 + P2 Latency vs Mesh Size"
    x-axis "Mesh Size" [2, 3]
    y-axis "Latency (ms)"
    line [1994, 2028]
    line [1979, 2021]
```

> Series order: **P1 wall avg** (ms), **P2 EDS avg** (ms).
> x-axis starts at mesh 2 — P2 is undefined at mesh size 1 (no remote cluster).

% Chart 2: P3 remote sidecar apply latency
% Series: P3 sidecar avg (ms)

```mermaid
xychart-beta
    title "P3 Remote Sidecar Latency vs Mesh Size"
    x-axis "Mesh Size" [2, 3]
    y-axis "Latency (ms)"
    line [2238, 2403]
```

> Series: **P3 sidecar avg** (ms). Separate chart — P3 is typically ~10x P1/P2 scale.
