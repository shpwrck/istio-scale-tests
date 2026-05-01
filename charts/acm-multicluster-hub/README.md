# acm-multicluster-hub

Single **MultiClusterHub** custom resource. Install after the ACM operator CSV has installed the **MultiClusterHub** CRD. `spec.localClusterName` is set by `istio-setup/001-acm-install-hub.sh` (Terraform / `--local-cluster-name`), RHACM max **34** characters.
