# acm-klusterlet-config

Cluster-scoped KlusterletConfig (default name `global`). Install after the KlusterletConfig CRD exists — typically after MultiClusterHub is Running and registration controllers have reconciled. Applied by Terraform (`terraform/platform/platform_acm.tf`, `helm_release.acm_klusterlet_config`) when `var.acm_install_klusterletconfig` is `true`.
