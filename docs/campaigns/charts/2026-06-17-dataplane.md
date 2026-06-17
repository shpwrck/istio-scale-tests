---
RUN_ID: "20260617T132259Z-449292"
DATE: "2026-06-17T13:23:01+00:00"
HARNESS_SHA: "0461af1-dirty"
ISTIO_VERSION: "v1.28.5"
KUBE_VERSION[cluster-002]: "v1.34.6"
FORTIO_IMAGE: "fortio/fortio:1.69.5"
SETTLE_SEC: "30"
WARMUP_DURATION_SEC: "5"
QPS_LEVELS: "10,100,500,1000"
DURATION_SEC: "30"
CONNECTIONS: "8"
SOURCE_CTX: "cluster-002"
REMOTE_CONTEXTS: ""
MESH_SIZE: "1"
NAMESPACE: "dataplane-test"
TUNING_BASELINE: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
SIDECAR_EGRESS_HOSTS: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
generated: "2026-06-17T13:40:53+00:00"
---

# Data-Plane Latency — Charts

% Chart 1: p50 latency (ms) vs mesh size at QPS 1000
% Series order: local, remote
% x-axis starts at mesh 2 (remote undefined at mesh 1)

```mermaid
xychart-beta
    title "p50 Latency vs Mesh Size (QPS 1000)"
    x-axis "Mesh Size" [2, 3]
    y-axis "Latency (ms)"
    line [2.13, 2.28]
    line [3.42, 3.45]
```

> Series order: **local**, **remote**. The gap = cross-cluster overhead.

% Chart 2: p50 latency (ms) vs QPS at mesh size 3

```mermaid
xychart-beta
    title "p50 Latency vs QPS (Mesh Size 3)"
    x-axis "QPS" [10, 100, 500, 1000]
    y-axis "Latency (ms)"
    line [3.22, 2.93, 2.31, 2.28]
    line [4.50, 4.42, 3.49, 3.45]
```

> Series order: **local**, **remote** at mesh size 3.
