---
istio_version: "v1.30.5"
istio_version_source: "live"
istio_version_pin: "v1.30.5"
istio_version_by_context: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5"
istio_active_revisions: "<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default"
istio_generations: "<mesh-a-ctx>=7/7,<mesh-b-ctx>=7/7,<mesh-c-ctx>=7/7,<mesh-d-ctx>=7/7,<mesh-e-ctx>=7/7"
harness_sha: "bf258af"
run_ids: ["20261027T180552Z-4034321"]
istio_versions: ["v1.30.5"]
harness_shas: ["bf258af"]
run_config: "tests/campaign/profiles/rosa/controlplane.env"
run_config_sha256: "84b2f2d8cfe993f0c74e8a6df29cc65eb9e936bc5e4d7f3701a0fb1f7bc1f0f3"
platform: "openshift"
test_platform: "auto"
platform_by_context: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift,<mesh-c-ctx>=openshift,<mesh-d-ctx>=openshift,<mesh-e-ctx>=openshift"
mesh_operator_by_context: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3,<mesh-c-ctx>=servicemeshoperator3:3.4.3,<mesh-d-ctx>=servicemeshoperator3:3.4.3,<mesh-e-ctx>=servicemeshoperator3:3.4.3"
istiod_image_by_context: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-c-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-d-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-e-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
proxy_image_by_context: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-c-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-d-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-e-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
node_provider_by_context: "<mesh-a-ctx>=aws,<mesh-b-ctx>=aws,<mesh-c-ctx>=aws,<mesh-d-ctx>=aws,<mesh-e-ctx>=aws"
istiod_env_by_context: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772,<mesh-c-ctx>=0c3d8d887772,<mesh-d-ctx>=0c3d8d887772,<mesh-e-ctx>=0c3d8d887772"
kube_versions: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6,<mesh-e-ctx>=v1.34.6"
files_consumed: 1
tuning_baseline: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
sidecar_egress_hosts: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
generated: 2026-10-27T19:42:56+00:00
---

# Control-Plane Resource Scaling — Charts

## Namespace scaling

> Probe windows: the cost of one more namespace at N, a line per sidecar scoping (series order in the note under each chart). Points are the Namespace scaling table's; a cell with no valid sample has no point.

```mermaid
xychart-beta
    title "istiod heap in use (MiB) vs namespaces (mesh=1 K=1 config-only)"
    x-axis "Namespaces (N)" [250, 1000, 2000, 4000]
    y-axis "istiod heap in use (MiB)"
    line [122, 192, 311, 505]
    line [149, 217, 388, 597]
```

> Series order: **namespace**, **wide**.

```mermaid
xychart-beta
    title "Per-proxy config (KiB) vs namespaces (mesh=1 K=1 config-only)"
    x-axis "Namespaces (N)" [250, 1000, 2000, 4000]
    y-axis "Per-proxy config (KiB)"
    line [351.4, 351.4, 351.4, 351.4]
    line [1818, 6200, 12057, 23770]
```

> Series order: **namespace**, **wide**.

```mermaid
xychart-beta
    title "Gateway clusters vs namespaces (mesh=1 K=1 config-only)"
    x-axis "Namespaces (N)" [250, 1000, 2000, 4000]
    y-axis "Gateway clusters"
    line [529, 2029, 4029, 8029]
```

> One line: the gateway keeps `*/*`, so its figure does not depend on the sidecar scoping.

```mermaid
xychart-beta
    title "Gateway memory (MiB) vs namespaces (mesh=1 K=1 config-only)"
    x-axis "Namespaces (N)" [250, 1000, 2000, 4000]
    y-axis "Gateway memory (MiB)"
    line [44, 152, 295, 582]
```

> One line: the gateway keeps `*/*`, so its figure does not depend on the sidecar scoping.

```mermaid
xychart-beta
    title "xDS push time (ms) vs namespaces (mesh=1 K=1 config-only)"
    x-axis "Namespaces (N)" [250, 1000, 2000, 4000]
    y-axis "xDS push time (ms)"
    line [0.49, 1.51, 2.94, 5.91]
    line [1.45, 4.75, 13.27, 29.73]
```

> Series order: **namespace**, **wide**.

