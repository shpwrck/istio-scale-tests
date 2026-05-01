# acm-operator

OperatorGroup + Subscription for the **advanced-cluster-management** package from OperatorHub. Applied first; wait for the ACM ClusterServiceVersion **Succeeded** before installing `charts/acm-multicluster-hub`.

Configured by `istio-setup/001-acm-install-hub.sh` and `config/versions.env` (`ACM_CHANNEL`, `ACM_NAMESPACE`).
