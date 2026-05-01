# openshift-gitops-operator

OLM **Subscription** for `openshift-gitops-operator` (Red Hat OpenShift GitOps).

Helm installs into **`openshift-operators`** by default (`GITOPS_OPERATOR_NAMESPACE`), matching the cluster OperatorGroup. No OperatorGroup is created by default (`operatorGroup.create: false`). Putting the Subscription in a namespace with an OperatorGroup scoped only to that namespace selects **OwnNamespace** install mode, which this operator does **not** support (OLM error: *OwnNamespace InstallModeType not supported*).

The **Argo CD** instance and ACM **Placement** / **GitOpsCluster** CRs stay in **`openshift-gitops`** (`GITOPS_NAMESPACE`).

Installed from `platform-setup/002-acm-openshift-gitops.sh`. Channel defaults from `config/versions.env` (`GITOPS_OPERATOR_CHANNEL`); align with your OpenShift version per [OpenShift GitOps release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/).
