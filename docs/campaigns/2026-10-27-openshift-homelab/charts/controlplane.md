---
istio_version: "v1.30.5"
istio_version_source: "live"
istio_version_pin: "v1.30.5"
istio_version_by_context: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5"
istio_active_revisions: "<mesh-a-ctx>=default,<mesh-b-ctx>=default"
istio_generations: "<mesh-a-ctx>=9/9,<mesh-b-ctx>=9/9"
harness_sha: "d21a197"
run_ids: ["20261027T131315Z-1934118"]
istio_versions: ["v1.30.5"]
harness_shas: ["d21a197"]
run_config: "tests/campaign/profiles/openshift/controlplane.env"
run_config_sha256: "cd4f75274d688e2e11088906df5c498fa0ef1b24c1a769af9ce9cff7c496e7a8"
platform: "openshift"
test_platform: "auto"
platform_by_context: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift"
mesh_operator_by_context: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3"
istiod_image_by_context: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
proxy_image_by_context: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
node_provider_by_context: "<mesh-a-ctx>=none,<mesh-b-ctx>=none"
istiod_env_by_context: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772"
kube_versions: "<mesh-a-ctx>=v1.34.8,<mesh-b-ctx>=v1.34.8"
files_consumed: 1
tuning_baseline: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
sidecar_egress_hosts: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
generated: 2026-10-27T15:00:02+00:00
---

# Control-Plane Resource Scaling — Charts

## Namespace scaling

> Probe windows: the cost of one more namespace at N, a line per sidecar scoping (series order in the note under each chart). Points are the Namespace scaling table's; a cell with no valid sample has no point.

```mermaid
xychart-beta
    title "istiod heap in use (MiB) vs namespaces (mesh=1 K=2 config-only)"
    x-axis "Namespaces (N)" [100, 200, 400]
    y-axis "istiod heap in use (MiB)"
    line [102, 141, 169]
    line [107, 122, 140]
    line [129, 153, 181]
```

> Series order: **namespace**, **none**, **wide**.

```mermaid
xychart-beta
    title "Per-proxy config (KiB) vs namespaces (mesh=1 K=2 config-only)"
    x-axis "Namespaces (N)" [100, 200, 400]
    y-axis "Per-proxy config (KiB)"
    line [356.8, 356.8, 356.8]
    line [356.8, 356.8, 356.8]
    line [1525, 2694, 5031]
```

> Series order: **namespace**, **none**, **wide**.

```mermaid
xychart-beta
    title "Gateway clusters vs namespaces (mesh=1 K=2 config-only)"
    x-axis "Namespaces (N)" [100, 200, 400]
    y-axis "Gateway clusters"
    line [431, 831, 1631]
```

> One line: the gateway keeps `*/*`, so its figure does not depend on the sidecar scoping.

```mermaid
xychart-beta
    title "Gateway memory (MiB) vs namespaces (mesh=1 K=2 config-only)"
    x-axis "Namespaces (N)" [100, 200, 400]
    y-axis "Gateway memory (MiB)"
    line [37, 66, 122]
```

> One line: the gateway keeps `*/*`, so its figure does not depend on the sidecar scoping.

```mermaid
xychart-beta
    title "xDS push time (ms) vs namespaces (mesh=1 K=2 config-only)"
    x-axis "Namespaces (N)" [100, 200, 400]
    y-axis "xDS push time (ms)"
    line [0.68, 1.19, 1.69]
    line [0.63, 1.18, 1.72]
    line [1.15, 1.75, 2.85]
```

> Series order: **namespace**, **none**, **wide**.

