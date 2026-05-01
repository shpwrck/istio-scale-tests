# platform-setup

Optional **ACM hub** and **OpenShift GitOps** automation on the RHACM hub (before Istio mesh steps under `istio-setup/`).

| Script | Purpose |
| ------ | ------- |
| `001-acm-install-hub.sh` | RHACM operator, MultiClusterHub, KlusterletConfig, per-spoke ManagedCluster + import |
| `002-acm-openshift-gitops.sh` | OpenShift GitOps operator, ACM GitOpsCluster wiring, Argo managed-cluster Secret patch |

Run from repo root. Typical order: **`001`** then **`002`**, then `istio-setup/002`–`010`. See root **`README.md`** and **`AGENTS.md`**.
