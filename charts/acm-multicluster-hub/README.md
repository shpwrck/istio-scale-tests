# acm-multicluster-hub

Single MultiClusterHub custom resource. Install after the ACM operator CSV has installed the MultiClusterHub CRD. `spec.localClusterName` is set by Terraform (`terraform/platform/platform_acm.tf`, `helm_release.acm_multicluster_hub`, from `acm_local_cluster_name`), RHACM max 34 characters.

## Disabling MCE components at install (BLOCKER #1)

`multiclusterHub.disabledComponents` is a list of MCE/ACM component names to turn off
at install. Each name is rendered into `spec.overrides.components[]` as
`{name: <name>, enabled: false}`. The default is an empty list, which omits the
`overrides` block entirely (byte-identical to the previous `spec: {}` render).

For the 20-cluster/10k campaign, set it to `["server-foundation"]`. That component
owns `ocm-proxyserver`/`clusterview`, whose malformed `clusterview/v1alpha1.UserPermission`
OpenAPI poisons the hub `/openapi/v2` and crashes ArgoCD's hub cluster-cache
(`LoadOpenAPISchema`) — see `STRESS_TEST_STATUS.md` BLOCKER #1. Disabling it at the
initial install keeps the hosted apiserver from ever caching the poison
(it does not purge post-hoc on ROSA HCP); cluster-manager registration is unaffected.

Terraform sets it from `var.acm_disabled_components` (`set_list`); the chart key is
the single render path. Examples:

```bash
# helm (direct)
helm template charts/acm-multicluster-hub \
  --set-json 'multiclusterHub.disabledComponents=["server-foundation"]'

# terraform/platform/terraform.tfvars
acm_disabled_components = ["server-foundation"]
```

After install, gate on `terraform/platform/scripts/001-openapi-preflight.sh`
(read-only) to assert the hub `/openapi/v2` parses with no clusterview `SchemaError`
before running the app-of-apps.
