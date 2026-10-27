---
istio_version: "v1.30.5"
istio_version_source: "live"
istio_version_pin: "v1.30.5"
istio_version_by_context: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5"
istio_active_revisions: "<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default"
istio_generations: "<mesh-a-ctx>=1/1,<mesh-b-ctx>=1/1,<mesh-c-ctx>=1/1,<mesh-d-ctx>=1/1,<mesh-e-ctx>=1/1"
harness_sha: "d21a197"
files_consumed: 10
tuning_baseline: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
sidecar_egress_hosts: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
run_config: "tests/campaign/profiles/rosa/churn.env"
run_config_sha256: "fa0d077a4411524cc477e224ce10e00eadb4f02927f082f002f5f0067de8c144"
platform: "openshift"
test_platform: "auto"
platform_by_context: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift,<mesh-c-ctx>=openshift,<mesh-d-ctx>=openshift,<mesh-e-ctx>=openshift"
mesh_operator_by_context: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3,<mesh-c-ctx>=servicemeshoperator3:3.4.3,<mesh-d-ctx>=servicemeshoperator3:3.4.3,<mesh-e-ctx>=servicemeshoperator3:3.4.3"
istiod_image_by_context: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-c-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-d-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-e-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
proxy_image_by_context: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-c-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-d-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-e-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
node_provider_by_context: "<mesh-a-ctx>=aws,<mesh-b-ctx>=aws,<mesh-c-ctx>=aws,<mesh-d-ctx>=aws,<mesh-e-ctx>=aws"
istiod_env_by_context: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772,<mesh-c-ctx>=0c3d8d887772,<mesh-d-ctx>=0c3d8d887772,<mesh-e-ctx>=0c3d8d887772"
kube_versions: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6,<mesh-e-ctx>=v1.34.6"
generated: 2026-10-27T15:13:17+00:00
---

# Churn Convergence — Charts

> 1 of 50 rows dropped (no valid samples / restart-poisoned; status != OK) — excluded from the charted averages.

% Chart 1: Convergence latency (ms) vs mesh size
% Series order: local avg, remote reach avg, remote EDS avg
% x-axis starts at mesh 2 (remote series undefined at mesh 1)

```mermaid
xychart-beta
    title "Convergence Latency vs Mesh Size"
    x-axis "Mesh Size" [2, 3, 4, 5]
    y-axis "Latency (ms)"
    line [5428, 5451, 5554, 5608]
    line [5175, 5238, 5379, 5507]
    line [4951, 5122, 5236, 5441]
```

> Series order: **local avg**, **remote reach avg**, **remote EDS avg**.
> x-axis starts at mesh 2 — remote metrics are undefined at mesh size 1.

% Chart 2: xDS pushes vs mesh size
% Series order: source xDS pushes, remote xDS pushes

```mermaid
xychart-beta
    title "xDS Pushes vs Mesh Size"
    x-axis "Mesh Size" [2, 3, 4, 5]
    y-axis "Push count"
    line [153, 142, 132, 149]
    line [18, 31, 44, 49]
```

> Series order: **source xDS pushes**, **remote xDS pushes**.

% Chart 3: Push amplification ratio vs mesh size

```mermaid
xychart-beta
    title "Push Amplification vs Mesh Size"
    x-axis "Mesh Size" [2, 3, 4, 5]
    y-axis "Amplification ratio"
    line [0.8, 0.9, 1.2, 0.8]
```

> Series: **push amplification ratio** (total xDS pushes / source push triggers). Scales with connected proxies x xDS types; compare across mesh sizes, not against 1.
