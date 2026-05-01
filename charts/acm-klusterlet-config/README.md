# acm-klusterlet-config

Cluster-scoped **KlusterletConfig** (default name `global`). Install after the KlusterletConfig CRD exists — typically after **MultiClusterHub** is **Running** and registration controllers have reconciled. Applied by `platform-setup/001-acm-install-hub.sh` unless `ACM_INSTALL_KLUSTERLETCONFIG=0`.
