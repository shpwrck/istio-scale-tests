---
leave-behind: v1
state-scope: rosa-validation
status: current
---

# ROSA validation leave-behind

How to stand up the ROSA path end to end (`terraform/rosa-hcp`, then `terraform/platform` in rosa
mode, then a mesh check), run one cost-capped validation window on it, and tear it all down again.
**A window is running:** 4 clusters exist (Tier C, window commit `8150d4b`) since T0 = 2026-10-14
12:42 UTC; the auto-teardown is armed for 20:57 UTC (T0+8:15) and `rosa-warn` for 19:57 UTC. The run
before it (3 HCP clusters, ~1h50m, 2026-10-12) was destroyed and verified empty. The account-level
ROSA setup stays between windows (the OCM role, the user role and the
`ManagedOpenShift-HCP-ROSA-*` account roles). The window is planned in
[window-plan.md](window-plan.md); its owner decisions were settled on 2026-10-13: Tier C and a $100
hard cap. While a window runs, this paragraph says "4 clusters exist since <T0>, auto-teardown armed
for <T0+8:15>"; afterwards, "destroyed and audited empty on <date>".

## Operability

### State and access

- AWS: an IAM user with AdministratorAccess (never root keys, which `rosa` rejects) in a
  named AWS CLI profile in `~/.aws/`. Export `AWS_PROFILE=<profile>` and `AWS_REGION=<region>`
  for every terraform, rosa and aws command.
- Red Hat: `rosa login --use-auth-code` (session in `~/.config/ocm/ocm.json`).
  Terraform's rhcs provider reuses it through
  `RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"` (the offline refresh token; the
  provider mints access tokens from it). The auto-teardown runs that itself, so the login must stay
  valid all window: check `rosa whoami` at every checkpoint.
- One-time account setup: in the AWS console, open Red Hat OpenShift Service on AWS → Get started,
  enable ROSA, then "Continue to Red Hat" and sign in as the Red Hat account `rosa` uses. Then
  `rosa create ocm-role --mode auto --yes` and `rosa create user-role --mode auto --yes`.
  An AWS account's ROSA subscription can be linked to only one Red Hat account,
  and demo-platform sandbox accounts usually come pre-linked to someone else.
- Old ROSA classic IAM: on 2026-10-14 the 4 classic account roles, 18 orphaned classic operator
  roles from earlier clusters and their 10 customer-managed policies were deleted. Only the HCP
  account roles, the OCM role and the user role remain. The deleted roles' trust policies and policy
  documents are saved in `~/.rosa-window/iam-backup/` on the operator host.
- Window worktree: run a window from its own worktree at the pinned commit, never by detaching the
  main checkout. The 2026-10-14 window runs from `<repo>/.claude/worktrees/rosa-window`, detached at
  `8150d4b` (`git -C <repo> worktree add <path> <window-sha>`; the plan's `<repo>-rosa-window` works
  the same). The main checkout's `terraform/platform` default workspace holds the existing-cluster
  lab; the window worktree has no lab state, so no ROSA command there can touch the lab.
- Terraform state, in the window worktree: `terraform/rosa-hcp/terraform.tfstate` and the
  platform's `rosa` workspace (`terraform/platform/terraform.tfstate.d/rosa/`), both local and
  gitignored. rosa-hcp uses only its default workspace (the platform reads
  `../rosa-hcp/terraform.tfstate` by path). Every platform command is prefixed with
  `TF_WORKSPACE=rosa`, never exported (Re-run). Inputs in `terraform.tfvars` / `rosa.tfvars`
  (gitignored, mode 0600, in the window worktree).
- Cluster access: `terraform/rosa-hcp/kubeconfig` (mode 0600; exec plugin that logs in as
  `cluster-admin` with the Terraform-generated password). Its contexts are the cluster keys:
  `cluster-001` is the ACM hub (`<acm-hub-ctx>`), `cluster-002` to `cluster-004` are
  `<mesh-a-ctx>`, `<mesh-b-ctx>`, `<mesh-c-ctx>`.
- Planned window: Tier C, owner-approved on 2026-10-13.
  - Hub on 2× m5.2xlarge, `<mesh-a-ctx>` on 3× r7i.2xlarge, and `<mesh-b-ctx>` and
    `<mesh-c-ctx>` on 3× m7i.xlarge, all with fixed worker counts, in us-east-2.
  - Quotas: On-Demand Standard vCPUs (`L-1216C47A`) at least 64, Classic LBs at least 10, and the
    VPC, internet gateway, Elastic IP and NAT quotas from `terraform/rosa-hcp/service_quotas.tf`.
    On 2026-10-14 the account already had all of them (vCPU quota 1848, Classic LBs 20, VPCs,
    internet gateways and EIPs 10), so no increase was requested and `rosa verify quota` passed
    outright. A quota that high caps nothing: the fixed worker pools are the only structural cap.
    An account held at 64-72 vCPUs instead fails that one `rosa verify quota` check by design
    (window-plan.md, P0).
  - Tiers B and A are the fallbacks (window-plan.md, Fallback tiers).
- Budgets:
  - `rosa-window-monthly`: $100 limit (the owner's hard cap; nothing else bills in the account),
    ACTUAL alerts at 50/80/100% and a FORECASTED alert at 100%. An older account-wide $100 budget
    exists alongside it and is left alone.
  - `rosa-residual-daily`: the post-window leak tripwire, created at T+1.
- Alerts that reach the operator away from the host, both required:
  - SNS topic `rosa-window` (us-east-2) with a confirmed email subscription; its ARN is in
    `~/.rosa-window/sns-topic-arn`. It gets an "armed" email at T0 and the auto-teardown's result;
    `003-auto-teardown.sh --arm` refuses without it.
  - Phone alarms at T0+7:15, T0+7:45 and T0+9:15. The last is the off-host check that the
    auto-teardown worked, and the only alert left if the operator host dies.
- Window files outside git, in `~/.rosa-window/`: `t0` (epoch seconds when apply started),
  `by_cluster.json` (saved `terraform output -json by_cluster`: the VPC and cluster ids that outlive
  the state), `teardown.log` and `teardown.result` (written by the auto-teardown), `status.md`
  (phase progress and checkpoint times, for a resumed session), `window-sha`, `sns-topic-arn`, and
  the P0/P1 logs (`p0-*.log`, `p0-dryruns/`, `p1-*.log`).
- systemd user units on the operator host: `rosa-autoteardown` (armed by
  `terraform/rosa-hcp/scripts/003-auto-teardown.sh --arm`; log in `journalctl --user -u rosa-autoteardown`
  and `teardown.log`) and `rosa-warn`. The tfstate is local, so the backstop lives on the same host.
  On WSL, systemd units do not keep the distro running: it stops about 15 s after the last terminal
  closes, and the timers with it, unless `%UserProfile%\.wslconfig` sets
  `[general] instanceIdleTimeout=-1` (window-plan.md, P0). The operator host has it since
  2026-10-14.
- Task 3's GitOps pause record: `tests/dataplane/results/rosa-lb/gitops-pause-ew.json` (gitignored),
  released with `tests/tuning/006-gitops-pause.sh --resume --state-file <it>`.

### Template map

terraform/rosa-hcp/terraform.tfvars.example -> terraform/rosa-hcp/terraform.tfvars (region, version, cluster_count 4, fixed worker counts, hub and cluster-002 r7i.2xlarge overrides, common_tags)
terraform/rosa-hcp/outputs.tf (local.kubeconfig_yaml) -> terraform/rosa-hcp/kubeconfig (merged kubeconfig, mode 0600)
terraform/rosa-hcp/outputs.tf (output by_cluster) -> ~/.rosa-window/by_cluster.json (VPC and cluster ids read by scripts 002 and 003 after the state is gone)
terraform/platform/terraform.tfvars.example -> terraform/platform/rosa.tfvars (cluster_provider = "rosa", repo URL and pinned revision, istiod 2 CPU/8Gi request and 4 CPU/16Gi limit, proxy 20m/64Mi requests, small Argo CD)
tests/<suite>/configs/smoke.env -> tests/<suite>/configs/rosa-*.local.env (gitignored run configs with the real contexts)

### Re-run

The day before (no cluster spend): the fallback checks, quotas, budgets, tfvars and dry runs in
[window-plan.md, Prerequisites](window-plan.md#4-prerequisites-p0-the-day-before-no-cluster-spend).
Then, from the window worktree (timers for Tier C; the fallback tiers use other offsets, see
window-plan.md, Fallback tiers):

```bash
export AWS_PROFILE=<profile> AWS_REGION=us-east-2
unset TF_WORKSPACE                                   # never exported: rosa-hcp has only the default workspace
terraform/rosa-hcp/scripts/001-preflight.sh          # read-only; prints the fix for each failed check
# With the vCPU quota held at 64-72 (P0), 001's quota check FAILs by design (rosa wants 100).
# Then this must print nothing: no quota flagged but the vCPU one, no error.
rosa verify quota --region us-east-2 2>&1 |
  grep -vE '^(INFO|WARN): |L-1216C47A|Insufficient AWS quotas|following service quota codes'
terraform/rosa-hcp/scripts/003-auto-teardown.sh --dry-run --sns-topic-arn <arn>   # the unattended teardown would work

# T0: start the clock and arm the backstop before anything bills
mkdir -p ~/.rosa-window && date -u +%s > ~/.rosa-window/t0
terraform/rosa-hcp/scripts/003-auto-teardown.sh --arm --fire-after 8h15m --sns-topic-arn <arn>   # Tier B: 7h15m
systemd-run --user --unit=rosa-warn \
  --on-calendar="$(date -u -d "@$(( $(cat ~/.rosa-window/t0) + 26100 ))" '+%Y-%m-%d %H:%M:%S UTC')" \
  -- notify-send -u critical "ROSA: teardown must start in 30 min"                  # T0+7:15; Tier B: 22500
systemctl --user list-timers | grep rosa                             # both armed
# On the phone: the SNS email "ROSA auto-teardown armed: fires at ..." has arrived, and alarms are
# set for T0+7:15, T0+7:45 and T0+9:15 (Tier B: 6:15, 6:45, 8:15).

export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
terraform -chdir=terraform/rosa-hcp init
terraform -chdir=terraform/rosa-hcp plan -out=rosa.tfplan && terraform -chdir=terraform/rosa-hcp apply rosa.tfplan
terraform -chdir=terraform/rosa-hcp output -json by_cluster > ~/.rosa-window/by_cluster.json   # the VPC ids for 002/003
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform workspace new rosa               # first time in this worktree
TF_WORKSPACE=rosa terraform -chdir=terraform/platform plan -var-file=rosa.tfvars -out=platform.tfplan
TF_WORKSPACE=rosa terraform -chdir=terraform/platform apply platform.tfplan
```

`TF_WORKSPACE=rosa` goes in front of each platform command, never into `export`: exported, it
also reaches the rosa-hcp commands later in the same shell, and there it names an empty workspace in
which `destroy` prints `Destroy complete! Resources: 0 destroyed.` and exits 0 while every cluster
keeps billing. Scripts 002 and 003 ignore it; a plain `terraform -chdir=terraform/rosa-hcp` does not.

`--arm` reads T0 from `~/.rosa-window/t0` and sets two triggers on the same instant: a monotonic
one, and an absolute UTC time that still fires after the laptop wakes. It refuses to arm when the
unattended run would fail (tools on PATH, AWS credentials, rosa login, and on WSL a
`%UserProfile%\.wslconfig` without `instanceIdleTimeout=-1`) or could fail unnoticed (no
`--sns-topic-arn`, or a topic with no confirmed subscription). Once armed it publishes an "armed"
email to the topic, which proves the alert path. Transient timers do not survive a reboot: after
one, run the same `--arm` command again (it recomputes from T0). Without `--arm` that command fails
rather than tearing down: a real teardown needs `--now`.

Sizing (prices checked 2026-10-13, sources in [window-plan.md](window-plan.md#2-prices)):

- Every tier puts the hub on 2× m5.2xlarge and the members on 3 fixed workers
  (`worker_autoscale_min = worker_autoscale_max = 3`).
- Tier C, the plan of record, gives `cluster-002` (`<mesh-a-ctx>`) 3× r7i.2xlarge through
  `cluster_overrides`, and b and c 3× m7i.xlarge. It costs $8.25/h and needs 64 vCPUs. Its plan is
  224 resources (2026-10-14).
- The fallbacks: Tier B (all members m7i.xlarge) is $6.75/h and needs 52; Tier A (2 members) is
  $5.12/h and needs 40.
- The `rosa.tfvars` override sets istiod to 1 replica with a 2 CPU / 8Gi request and a 4 CPU / 16Gi
  limit (an 8Gi limit on B and A). The chart default, 3 × 4 CPU / 16Gi requested, does not fit.
- The override sets the proxy requests to 20m / 64Mi.
- On b and c the 16Gi limit is nominal. On their 16 GiB nodes, an istiod above its 8Gi request is
  the first pod evicted under memory pressure (window-plan.md, "b and c under the 16Gi limit").

### Verify and recover

- `rosa list clusters`: all `ready`. `oc --kubeconfig terraform/rosa-hcp/kubeconfig --context cluster-001 get applications.argoproj.io -n openshift-gitops`: all Synced/Healthy.
- On each member, `oc exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- bash /opt/check/readiness.sh`: `Ready ... ca=shared`.
- On each member, istiod runs 1 pod with an 8Gi memory request and a 16Gi limit (8Gi on the
  fallback tiers):
  `oc -n istio-system get pod -l app=istiod -o jsonpath='{..resources.requests.memory}/{..resources.limits.memory}'`.
- mesh-verify through each member's ingress (`.status.loadBalancer.ingress[0].hostname` on AWS): answers come from every member.
- Load balancer inventory (A0) and the task 3 commands: [window-plan.md, P2 and P5](window-plan.md#5-run-order-tier-c).
  After any gateway Service experiment, the recovery gate must pass: the GitOps pause resumed, every
  Application Synced/Healthy, the Service back to the chart spec, `ca=shared` on all 3 gates, a probe
  from every source REACHABLE, and exactly 2 gateway LBs per member.
- More than about 500 Terminating namespaces on any member, a missed T0+7:45 (T0+6:45 on Tier B)
  or a lost mesh: go straight to the billing-first teardown below.
- Teardown, planned path (results backed up first):

```bash
export AWS_PROFILE=<profile> AWS_REGION=us-east-2 RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
unset TF_WORKSPACE                     # else the rosa-hcp destroy below "succeeds" on an empty workspace
TF_WORKSPACE=rosa terraform -chdir=terraform/platform destroy -var-file=rosa.tfvars   # time box: 15 min
terraform/rosa-hcp/scripts/002-pre-destroy-vpc-cleanup.sh --by-cluster-json ~/.rosa-window/by_cluster.json
terraform -chdir=terraform/rosa-hcp destroy
# DependencyViolation on a VPC: ROSA left its <cluster-id>-vpce-private-router security group or its
# interface endpoint behind. Once the clusters are gone, run 002 again with
# --delete-interface-endpoints, then terraform destroy again.
```

  Keep both timers armed until the audit below comes back empty, then disarm them:
  `terraform/rosa-hcp/scripts/003-auto-teardown.sh --disarm; systemctl --user stop rosa-warn.timer`.
  A destroy that silently did nothing then still meets the backstop.
- Teardown, billing-first (the platform destroy hangs past its 15 minutes, or any abort rule fires):
  run `terraform/rosa-hcp/scripts/003-auto-teardown.sh --now` by hand; it is what the timer runs. It
  destroys `module.rosa_hcp` first (the clusters, their worker pools and IAM roles: the hourly
  ROSA, EC2 and EBS charges stop and nothing is left to recreate load balancers), then runs 002
  with `--delete-interface-endpoints` (and the saved VPC list, when there is one), then the full
  destroy, retrying steps up to 3 times, then a read-only audit. It ignores an exported
  `TF_WORKSPACE`, logs to `~/.rosa-window/teardown.log`, writes `teardown.result`, exits 1 on
  anything left, and publishes the result to `--sns-topic-arn`. It never touches
  `terraform/platform`; afterwards discard that state, which bills nothing, in the window worktree
  only: `unset TF_WORKSPACE; terraform -chdir=terraform/platform workspace select default && terraform -chdir=terraform/platform workspace delete -force rosa`.
- When the T0+9:15 phone alarm rings (T0+8:15 on Tier B), unless a teardown's audit already came
  back empty, confirm that the auto-teardown worked
  ([window-plan.md, If the T0+9:15 alarm rings](window-plan.md#if-the-t0915-alarm-rings)). An SNS
  email "finished: clean" settles it. Otherwise, on the operator host, in a shell set up as in
  Re-run (`cd <window-worktree>`, `export AWS_PROFILE=<profile> AWS_REGION=us-east-2`, and the
  `RHCS_*` variables), since it may be a fresh one after a reboot:
  - `systemctl --user is-active rosa-autoteardown.service` says `active`: it is still running;
    follow `~/.rosa-window/teardown.log`.
  - `~/.rosa-window/teardown.result` says `CLEAN`: only the email failed; run the audit.
  - Anything else: `terraform/rosa-hcp/scripts/003-auto-teardown.sh --now`, by T0+10:30 at the
    latest to stay under $100.
  - Host dead: `rosa delete cluster --cluster <name> --yes` per window cluster, from a machine
    with `rosa login` and credentials for the window's AWS account (`rosa` finds a cluster only
    through that account); without such a machine, delete each cluster in OpenShift Cluster
    Manager (console.redhat.com/openshift: Options or Actions, Delete cluster). Once the host is
    back, wait for those deletions to finish before `003 --now`.
- Audit after any teardown; every check must come back empty. The script's audit covers the state,
  the window's clusters, the saved VPCs and new unattached volumes; this list, across regions, is
  the authority (tag filters miss resources the clusters created with their own tags):

```bash
unset TF_WORKSPACE                     # else 'state list' reads an empty workspace and looks clean
rosa list clusters                                                  # none of the window's clusters
terraform -chdir=terraform/rosa-hcp state list                      # nothing
ls terraform/rosa-hcp/terraform.tfstate.d 2>/dev/null               # nothing: rosa-hcp has no other workspace
for id in $(jq -r '.[].vpc_id' ~/.rosa-window/by_cluster.json); do
  aws ec2 describe-vpcs --vpc-ids "$id" 2>&1 | grep -q InvalidVpcID.NotFound || echo "VPC $id still exists"
done
for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  echo "== $r"
  aws --region "$r" ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId'
  aws --region "$r" ec2 describe-nat-gateways --filter Name=state,Values=pending,available,deleting --query 'NatGateways[].NatGatewayId'
  aws --region "$r" elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName'
  aws --region "$r" elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'
  aws --region "$r" ec2 describe-addresses --query 'Addresses[].PublicIp'
done
aws ec2 describe-volumes --query 'Volumes[].[VolumeId,State,CreateTime]'
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[].[VpcEndpointId,VpcId,State]'
aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,StartTime]'
aws route53 list-hosted-zones --query 'HostedZones[].Name'
aws secretsmanager list-secrets --query 'SecretList[].Name'
aws resourcegroupstaggingapi get-resources --tag-filters Key=purpose,Values=rosa-window
```

- At T+1 and T+2 days: Cost Explorer by service
  (`aws ce get-cost-and-usage --time-period Start=<day>,End=<next-day> --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE`,
  $0.01 per call) shows EC2, ELB, VPC, EBS and the Marketplace ROSA line at about $0. Create
  `rosa-residual-daily` ($3, ACTUAL > 100%) at T+1: created earlier it fires on the window day itself
  and on ROSA charges that post late.

## Decision log

### Decisions

- Purpose: prove the ROSA path (greenfield: Terraform installs ACM, GitOps and the mesh), which the
  existing-cluster lab (brownfield) cannot, and measure what only AWS can show (task 3's load
  balancers, the 3-member partial mesh, AWS cross-cluster latency). Both paths were verified on 2026-10-12.
- Account traps found live, all now caught by `001-preflight.sh`: expired keys, root keys,
  no OCM role or user role, the AWS account linked to a different Red Hat org, and the browser
  reusing the wrong Red Hat SSO session (use a private window for `rosa login`).
- Machine type: the repo passes one resolved type to both the cluster and its worker pool
  (OCM's default changed to m7i.xlarge; a mismatch is immutable and fails the apply).
- Destroy order: operator CSV cleanup runs only after the ArgoCD CR, apps and MultiClusterHub are
  gone (before, it ran in parallel and the ArgoCD CR hung on its finalizer).
- Owner decisions, settled on 2026-10-13: Tier C, a $100 hard cap, us-east-2, and the istiod and
  proxy overrides below.
- Tier C, not B. The lab shape check could not run (the lab was powered off on 2026-10-13), so there
  is no evidence that an 8Gi istiod holds task 1's wide cells. C buys that headroom on mesh-a, plus
  task 6 in pods mode at 150-250 services × 2, for $1.50/h more than B. Its worst case, about $81,
  stays $19 under the cap.
- Tiers B and A are fallbacks, chosen before apply: B if r7i.2xlarge or the 64-vCPU quota is
  missing, A only without 52 vCPUs. The m7i.4xlarge variant of C is out: its worst case on the same
  timers is about $98.
- The 3-member partial mesh needs 4 clusters (the hub is never a mesh member). That is why the plan
  uses B or C over A: A loses the one task 3 case the lab cannot produce.
- 3 workers per member, fixed.
  - On b and c, istiod's 2 CPU / 8Gi request plus about 5 vCPU of ROSA, monitoring and ACM pods
    leave only about 2 vCPU free on 2 nodes.
  - mesh-a needs 3 nodes for its pods per node, not for CPU.
  - Fixed pools (min = max) are the structural cap on EC2 spend. A vCPU quota far above the need
    caps nothing and cannot be lowered; this account's (1848) is such a quota.
- Mesh-wide values are baked in at provision time, so no istiod restart happens before task 4's
  planned one.
  - istiod: request 2 CPU / 8Gi, limit 4 CPU / 16Gi.
  - Proxy requests: 20m / 64Mi.
  - The 16Gi limit is one value for every member. On the 16 GiB nodes of b and c it is nominal
    (GOMEMLIMIT 14.4 GiB, eviction above the 8Gi request), so task 1 watches their istiod by hand
    against 8Gi.
  - The proxy override changes scheduling only, and the campaign doc records it.
  - Checked before the 2026-10-14 platform apply: the `spoke-ossm-appset` override reaches the
    generated Applications' `helm.valuesObject` (with `clusterName` as a Helm parameter), and the
    Istio CR renders 1 replica, 2 CPU / 8Gi requested, 4 CPU / 16Gi limit, proxy 20m / 64Mi.
- Tasks 1 and 4 were never lab-validated. Their first ROSA runs start with a smoke step and a
  go/no-go before the expensive sweeps depend on them: task 4's read-only capture in P3, task 1's
  S1 in P6.
- Run order: cross-cluster measurements first (dataplane baseline, task 6), then task 3's gateway
  Service mutations on mesh-c only under one GitOps pause, then task 1 (single member, leaves
  thousands of namespaces, never deletes them in the window), then task 4's istiod delete last.
- Task 6 runs in pods mode, because config-only mode was not built for `vsdr`. It runs at 150 and
  250 services × 2 replicas on mesh-a, plus 60 × 2 per member across a and b, the most b can hold.
- Rejected on ROSA: touching `cacerts` (the lab already confirmed the CA race), OOM and
  liveness-probe tests, autoscaling worker pools, Tier D, and `rosa create cluster --expiration`
  (a hidden flag whose source says it is "not supported in production").
- Costs, checked 2026-10-13, with sources in window-plan.md:
  - Tier C is $8.2471/h: about $65 core (7.25 h), at most $77 extended, and about $81 worst case
    (auto-teardown at T0+8:15, billing ending about 45 min later).
  - Tier B is $6.75/h: about $48 core, at most $57 extended, and $60 worst case.
  - The earlier "about $3.5/hour for 3 small clusters" was really $4.31/h.
  - "$25-30/hour" for 20 members holds only for 2× m7i.xlarge members; campaign-shaped, it is about
    $248/h.
- AWS Budget `rosa-window-monthly` has a $100 limit, not month-to-date spend plus a ceiling: the
  account is otherwise idle. Its FORECASTED alert needs about 5 weeks of history before it can fire,
  so the ACTUAL alerts and the wall clock carry the load. Month-to-date before the 2026-10-14
  window was about $7, so its expected month totals are about $72 core, $84 extended and $88 worst
  case (in `status.md`).
- The wall clock is the spend meter: AWS Budgets refresh every 8-12 h, so they only catch leaks the
  next day. Hence T0 on disk, the spend estimate at every checkpoint, and an unattended,
  billing-first auto-teardown with both a monotonic and an absolute trigger.
- `003-auto-teardown.sh` destroys `module.rosa_hcp` before anything else: that stops the expensive
  hourly charges first and removes every controller that could recreate a load balancer while 002
  cleans up. After that targeted destroy the `by_cluster` output is empty, so 002 merges the saved
  copy, the output and the state, and with `--delete-interface-endpoints` also removes interface
  endpoints Terraform does not manage, only in VPCs with no instances left.
- `003-auto-teardown.sh --arm` defaults to `--fire-after 8h15m`, Tier C's deadline. The fallback
  tiers pass their own value.
- Failure modes that would silently void the $100 cap, closed in the scripts: a teardown needs an
  explicit `--now` (a re-arm that forgot `--arm` used to destroy mid-window); 002 and 003 drop an
  exported `TF_WORKSPACE` (rosa-hcp's destroy in the platform's `rosa` workspace reports success
  and destroys nothing); 003 passes the saved VPC list only once it exists (002 dies on a missing
  file and would never reach the state's VPCs); and `--arm` on WSL requires
  `instanceIdleTimeout=-1`, because systemd units do not keep a WSL distro running.
- A failed or unfired auto-teardown must reach an absent operator, and AWS Budgets lag 8-12 h.
  Tier C's worst case leaves $18.78 under the cap, about 2 h 15 min at the full rate. So both alerts
  are required, and both are free:
  - SNS with a confirmed email subscription. `--arm` refuses without one, and its "armed" email
    proves the path at T0.
  - A phone alarm at T0+9:15, an hour after the timer fires. It also covers what nothing on the host
    can report: a dead host, where the timer never runs.
  - A manual teardown started by T0+10:30 still ends billing under $100.
- The vCPU quota is not raised for a window. An account held at 64-72 vCPUs fails the one
  `rosa verify quota` check by design (rosa sizes it for five multi-AZ classic clusters), and the
  runbook reads the other quota lines instead of requesting an increase that can sit pending for
  hours. Near the need, the quota still stops an accidental extra cluster, which a fixed pool does
  not; well above it (as on this account), the fixed pools alone cap EC2.
- The orphaned ROSA classic roles and policies were removed on 2026-10-14 so the account holds only
  what the HCP path uses; they are recoverable from `~/.rosa-window/iam-backup/`.

### How to drive it

1. P0, the day before ([window-plan.md, Prerequisites](window-plan.md#4-prerequisites-p0-the-day-before-no-cluster-spend)):
   - check the Tier C conditions (r7i.2xlarge offered, 64 vCPUs), or switch to a fallback tier;
   - pin the commit in a window worktree;
   - request quotas and create the $100 budget;
   - create the SNS topic and confirm its email subscription;
   - write the tfvars and run configs;
   - run every dry run, including `003-auto-teardown.sh --dry-run --sns-topic-arn <arn>`.
2. T0: write `t0`, arm `rosa-autoteardown` (T0+8:15, with `--sns-topic-arn`) and `rosa-warn`
   (T0+7:15), check that the "armed" email reached the phone, and set the phone alarms for T0+7:15,
   T0+7:45 and T0+9:15. Then apply rosa-hcp, save `by_cluster.json`, and apply the platform (Re-run
   above). Record T0 and the checkpoint clock times in `~/.rosa-window/status.md`.
3. Verify (above) and take the A0 inventory.
4. Run the phases in [window-plan.md, Run order](window-plan.md#5-run-order-tier-c).
   - At every checkpoint, announce the spend estimate and check `rosa whoami`.
   - When a deadline slips, cut from the cut list.
   - Treat the task 4 smoke (P3) and task 1's S1 (P6) as go/no-go gates: they are those tasks'
     first live runs.
5. Collect evidence and back up `tests/*/results/` off the laptop.
6. Tear down by the planned path, or billing-first; start no later than T0+7:45.
7. Audit until every check is empty; disarm the timers and cancel the T0+9:15 phone alarm. If the
   alarm rings first, confirm the auto-teardown's result as in Verify and recover; a manual
   `003 --now` must start by T0+10:30.
8. Write `docs/campaigns/<date>-rosa-validation.md` from the template with placeholders, update this
   file's opening paragraph to the new state and commit it; check Cost Explorer at T+1 and T+2.
