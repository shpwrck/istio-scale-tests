---
istio_version: v1.28.5
harness_sha: 0461af1
files_consumed: 1
generated: 2026-06-17T13:19:28+00:00
---

# Control-Plane Resource Scaling — Charts

% Chart 1: istiod CPU (m, per replica) vs mesh size, by sidecar scoping
% Series order: none

```mermaid
xychart-beta
    title "istiod CPU vs Mesh Size by Sidecar Scoping"
    x-axis "Mesh Size" [1, 2, 3]
    y-axis "CPU (m, per replica)"
    line [537, 586, 608]
```

> Series order: **none**.

% Chart 2: Per-proxy config dump size (MB) by scoping at mesh size 3

```mermaid
xychart-beta
    title "Config Dump Size by Scoping (mesh size 3)"
    x-axis "Sidecar Scoping" ["none"]
    y-axis "Size (MB)"
    bar [0.7]
```

> Config dump avg (MB) at the largest mesh size swept (3).
