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
generated: 2026-10-27T14:09:14+00:00
---

# Control-Plane Resource Scaling — Charts

> **Note (2026-10-27 lab run):** no charts were generated. This profile runs namespace scaling only, at one mesh size, and the chart generator covers neither. The numbers are in the [record](../README.md) and the sweep's Namespace scaling section.

> Charts cover the legacy layout only; growth cells (namespace scaling) are in the markdown report's Namespace scaling section.
