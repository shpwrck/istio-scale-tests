#!/usr/bin/env bats
# terraform/rosa-hcp/scripts/002-pre-destroy-vpc-cleanup.sh and 003-auto-teardown.sh run
# end to end against stub terraform, aws and rosa binaries (no AWS account, no cluster):
# the merged VPC list, the interface-endpoint guard, and 003's billing-first order.

load test_helper

setup() {
	STUB_DIR="$(mktemp -d)"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin" "${STUB_DIR}/window" "${STUB_DIR}/tf/scripts"
	: >"${STUB_LOG}"
	# Copies, so the scripts' terraform dir (their parent) is a scratch dir, not the checkout.
	cp "${ROOT}/terraform/rosa-hcp/scripts/002-pre-destroy-vpc-cleanup.sh" \
		"${ROOT}/terraform/rosa-hcp/scripts/003-auto-teardown.sh" "${STUB_DIR}/tf/scripts/"
	S002="${STUB_DIR}/tf/scripts/002-pre-destroy-vpc-cleanup.sh"
	S003="${STUB_DIR}/tf/scripts/003-auto-teardown.sh"
	printf 'aws_region        = "us-east-2"\nopenshift_version = "4.21.11"\ncluster_count     = 2\n' \
		>"${STUB_DIR}/tf/terraform.tfvars"

	# terraform: state, outputs and destroys driven by files in $STUB_DIR. All of it lives in the
	# default workspace; any other TF_WORKSPACE sees an empty one, as real terraform does: no
	# state, no outputs, and a destroy that "succeeds" with nothing destroyed.
	cat >"${STUB_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $* ws=${TF_WORKSPACE:-default}" >>"$STUB_LOG"
if [[ "${TF_WORKSPACE:-default}" != default ]]; then
	case " $* " in
	*" state list "*) echo "No state file was found!" >&2; exit 1 ;;
	*" output "*) echo "Warning: No outputs found" >&2; exit 1 ;;
	*" show -json "*) echo '{"format_version":"1.0"}' ;;
	esac
	exit 0
fi
case " $* " in
*" show -json "*) cat "$STUB_DIR/state.json" 2>/dev/null || echo '{}' ;;
*" output -json by_cluster "*)
	[[ -f "$STUB_DIR/output.json" ]] || { echo "Error: output not found" >&2; exit 1; }
	cat "$STUB_DIR/output.json" ;;
*" state list "*) cat "$STUB_DIR/state.list" 2>/dev/null || true ;;
*" destroy "*"-target=module.rosa_hcp"*)
	rc="$(cat "$STUB_DIR/target.rc" 2>/dev/null || echo 0)"
	[[ "$rc" != 0 ]] || echo '{}' >"$STUB_DIR/output.json"
	exit "$rc" ;;
*" destroy "*)
	n="$(cat "$STUB_DIR/full.fails" 2>/dev/null || echo 0)"
	if ((n > 0)); then
		echo $((n - 1)) >"$STUB_DIR/full.fails"
		echo "Error: DependencyViolation" >&2
		exit 1
	fi
	: >"$STUB_DIR/state.list"
	rm -f "$STUB_DIR/live_vpcs"
	echo '{}' >"$STUB_DIR/state.json" ;;
esac
exit 0
EOF
	# aws: a VPC exists when listed in $STUB_DIR/live_vpcs; everything else is empty.
	cat >"${STUB_DIR}/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$STUB_LOG"
args=" $* "
case "$args" in
*" configure get region "*) exit 1 ;;
*" sns get-topic-attributes "*)
	[[ -z "${STUB_SNS_FAIL:-}" ]] || { echo "An error occurred (NotFound) when calling the GetTopicAttributes operation" >&2; exit 254; }
	echo "${STUB_SNS_CONFIRMED:-1}" ;;
*" --output text "*) echo 0 ;;
*" sts get-caller-identity "*) echo '{"Account":"000000000000"}' ;;
*" ec2 describe-vpcs "*)
	vpc="${args##* --vpc-ids }"
	vpc="${vpc%% *}"
	if grep -qx "$vpc" "$STUB_DIR/live_vpcs" 2>/dev/null; then
		echo '{"Vpcs":[{}]}'
	else
		echo "An error occurred (InvalidVpcID.NotFound) when calling the DescribeVpcs operation" >&2
		exit 254
	fi ;;
*" describe-vpc-endpoints "*) cat "$STUB_DIR/eps.json" 2>/dev/null || echo '{"VpcEndpoints":[]}' ;;
*" delete-vpc-endpoints "*) echo '{"Unsuccessful":[]}' ;;
*" describe-instances "*) cat "$STUB_DIR/instances.json" 2>/dev/null || echo '[]' ;;
*" describe-network-interfaces "*" --query "*) echo '[]' ;;
*" describe-network-interfaces "*) echo '{"NetworkInterfaces":[]}' ;;
*" describe-security-groups "*) echo '{"SecurityGroups":[]}' ;;
*" describe-load-balancers "*) echo '[]' ;;
*" describe-volumes "*) echo '{"Volumes":[]}' ;;
*) echo '{}' ;;
esac
EOF
	cat >"${STUB_DIR}/bin/rosa" <<'EOF'
#!/usr/bin/env bash
echo "rosa $*" >>"$STUB_LOG"
[[ -z "${STUB_ROSA_FAIL:-}" ]] || exit 1
case " $* " in
*" token "*) echo stub-offline-token ;;
*" whoami "*) echo '{}' ;;
*" list clusters "*) cat "$STUB_DIR/rosa_clusters.json" 2>/dev/null || echo '[]' ;;
esac
EOF
	for t in notify-send systemd-run; do
		printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n' "$t" >"${STUB_DIR}/bin/$t"
	done
	cat >"${STUB_DIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
case " $* " in
*" is-system-running "*) echo running ;;
*" is-active "*) exit 3 ;;
esac
EOF
	printf '#!/usr/bin/env bash\necho yes\n' >"${STUB_DIR}/bin/loginctl"
	# Windows interop for the WSL check: %UserProfile% is $STUB_DIR/winhome.
	cat >"${STUB_DIR}/bin/cmd.exe" <<'EOF'
#!/usr/bin/env bash
printf 'C:\\Users\\op\r\n'
EOF
	printf '#!/usr/bin/env bash\necho "$STUB_DIR/winhome"\n' >"${STUB_DIR}/bin/wslpath"
	chmod +x "${STUB_DIR}/bin/"*
	PATH="${STUB_DIR}/bin:${PATH}"
	mkdir -p "${STUB_DIR}/winhome"
	# Not WSL, whatever the host is; the WSL test points this at a WSL kernel string.
	echo "Linux version 6.8.0-generic" >"${STUB_DIR}/proc_version"
	export ROSA_TEARDOWN_PROC_VERSION="${STUB_DIR}/proc_version"

	# Saved by_cluster copy: two clusters with their region.
	cat >"${STUB_DIR}/window/by_cluster.json" <<'EOF'
{"cluster-001": {"aws_region": "us-east-2", "cluster_name": "cluster-001", "vpc_id": "vpc-aaa"},
 "cluster-002": {"aws_region": "us-east-2", "cluster_name": "cluster-002", "vpc_id": "vpc-bbb"}}
EOF
	printf 'vpc-aaa\n' >"${STUB_DIR}/live_vpcs"
	# --arm requires a topic; the stub reports one confirmed subscription unless told otherwise.
	SNS="arn:aws:sns:us-east-2:000000000000:rosa-window"
	unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE TF_WORKSPACE STUB_SNS_FAIL STUB_SNS_CONFIRMED
}

teardown() {
	rm -rf "${STUB_DIR}"
}

endpoint_json() {
	cat >"${STUB_DIR}/eps.json" <<'EOF'
{"VpcEndpoints": [
 {"VpcEndpointId": "vpce-111", "State": "available", "ServiceName": "com.amazonaws.vpce.us-east-2.vpce-svc-router", "NetworkInterfaceIds": ["eni-111"]},
 {"VpcEndpointId": "vpce-222", "State": "available", "ServiceName": "com.amazonaws.us-east-2.sts", "NetworkInterfaceIds": ["eni-222"]}]}
EOF
}

# --- 002: where the VPC ids come from ---

@test "002 reads the VPCs from the saved copy once the by_cluster output is empty" {
	echo '{}' >"${STUB_DIR}/output.json"
	run bash "$S002" --dry-run --by-cluster-json "${STUB_DIR}/window/by_cluster.json"
	assert_success
	assert_output --partial "Region:  us-east-2"
	assert_output --partial "VPCs:    2 (saved copy: 2, terraform output: 0, state: 0)"
	assert_output --partial "--- cluster-001 (vpc-aaa; from saved) ---"
	assert_output --partial "already deleted (not found in us-east-2)"
}

@test "002 without a saved copy or state still dies with no VPCs" {
	echo '{}' >"${STUB_DIR}/output.json"
	run bash "$S002" --dry-run
	assert_failure
	assert_output --partial "no VPCs found"
}

@test "002 merges VPCs that only the state knows and flags the stale copy" {
	cat >"${STUB_DIR}/state.json" <<'EOF'
{"values": {"root_module": {"child_modules": [{"resources": [
 {"address": "module.vpc[\"cluster-003\"].aws_vpc.this[0]", "type": "aws_vpc",
  "values": {"id": "vpc-ccc", "arn": "arn:aws:ec2:us-east-2:000000000000:vpc/vpc-ccc"}}]}]}}}
EOF
	printf 'vpc-aaa\nvpc-ccc\n' >"${STUB_DIR}/live_vpcs"
	run bash "$S002" --dry-run --by-cluster-json "${STUB_DIR}/window/by_cluster.json"
	assert_success
	assert_output --partial "VPCs:    3 (saved copy: 2, terraform output: 0, state: 1)"
	assert_output --partial "warning: vpc-ccc (cluster-003) is in terraform state but not in the saved copy"
	assert_output --partial "note: vpc-aaa (cluster-001) is in the saved copy but not in terraform state"
}

@test "002 calls a missing VPC an error when the region is only a guess and nothing was found" {
	echo '{"cluster-001": {"vpc_id": "vpc-aaa"}}' >"${STUB_DIR}/window/old.json"
	: >"${STUB_DIR}/live_vpcs"
	run env AWS_REGION=us-west-2 bash "$S002" --dry-run --by-cluster-json "${STUB_DIR}/window/old.json"
	assert_failure
	assert_output --partial "(from the environment)"
	assert_output --partial "not found in us-west-2 (wrong region? pass --region)"
}

# --- 002: interface endpoints ---

@test "002 only reports interface endpoints without --delete-interface-endpoints" {
	endpoint_json
	run bash "$S002" --dry-run --by-cluster-json "${STUB_DIR}/window/by_cluster.json"
	assert_success
	assert_output --partial "note: interface endpoint vpce-111"
	refute_output --partial "would delete interface endpoint"
}

@test "002 keeps interface endpoints while instances are left in the VPC" {
	endpoint_json
	echo '["i-0001"]' >"${STUB_DIR}/instances.json"
	run bash "$S002" --by-cluster-json "${STUB_DIR}/window/by_cluster.json" --delete-interface-endpoints
	assert_success
	assert_output --partial "skip endpoint vpce-111 (com.amazonaws.vpce.us-east-2.vpce-svc-router): 1 instance(s) still in the VPC"
	run grep -c "delete-vpc-endpoints" "${STUB_LOG}"
	assert_output "0"
}

@test "002 deletes unmanaged interface endpoints in an empty VPC, never Terraform's" {
	endpoint_json
	cat >"${STUB_DIR}/state.json" <<'EOF'
{"values": {"root_module": {"resources": [
 {"address": "aws_vpc_endpoint.sts", "type": "aws_vpc_endpoint", "values": {"id": "vpce-222"}}]}}}
EOF
	run bash "$S002" --by-cluster-json "${STUB_DIR}/window/by_cluster.json" --delete-interface-endpoints
	assert_success
	assert_output --partial "skip endpoint vpce-222 (com.amazonaws.us-east-2.sts; managed by terraform)"
	assert_output --partial "delete interface endpoint vpce-111"
	run grep "delete-vpc-endpoints" "${STUB_LOG}"
	assert_output --partial "--vpc-endpoint-ids vpce-111"
	refute_output --partial "vpce-222"
}

# --- 003: billing-first teardown ---

@test "003 destroys the clusters first, then cleans and destroys the rest, retrying" {
	printf 'module.rosa_hcp["cluster-001"]\nmodule.vpc["cluster-001"]\n' >"${STUB_DIR}/state.list"
	# The live output has lost cluster-001 and gained cluster-003: the saved copy keeps all three.
	echo '{"cluster-002": {"cluster_name": "cluster-002", "vpc_id": "vpc-bbb"}, "cluster-003": {"cluster_name": "cluster-003", "vpc_id": "vpc-ccc"}}' \
		>"${STUB_DIR}/output.json"
	echo 1 >"${STUB_DIR}/full.fails"
	run bash "$S003" --now --state-dir "${STUB_DIR}/window" --region us-east-2 --retry-wait 0
	assert_success
	assert_output --partial "RESULT CLEAN"

	target=$(grep -n -- '-target=module.rosa_hcp' "${STUB_LOG}" | head -1 | cut -d: -f1)
	cleanup=$(grep -n 'describe-vpc-endpoints' "${STUB_LOG}" | head -1 | cut -d: -f1)
	full=$(grep -n 'terraform .* destroy ' "${STUB_LOG}" | grep -v -- '-target=' | head -1 | cut -d: -f1)
	token=$(grep -n 'rosa token --refresh' "${STUB_LOG}" | head -1 | cut -d: -f1)
	[ -n "$target" ]
	[ -n "$cleanup" ]
	[ -n "$full" ]
	[ -n "$token" ]
	((token < target && target < cleanup && cleanup < full))
	run bash -c "grep 'terraform .* destroy ' '${STUB_LOG}' | grep -vc -- '-target='"
	assert_output "2"

	run jq -r 'keys | join(",")' "${STUB_DIR}/window/by_cluster.json"
	assert_output "cluster-001,cluster-002,cluster-003"
	run cat "${STUB_DIR}/window/teardown.result"
	assert_output --partial " CLEAN cluster destroy: ok; full destroy: ok; audit: 0 item(s)"
	grep -q "RESULT CLEAN" "${STUB_DIR}/window/teardown.log"
	[ ! -d "${STUB_DIR}/window/teardown.lock" ]
}

@test "003 still runs every step, then reports FAILED, notifies and exits 1 when nothing succeeds" {
	printf 'module.vpc["cluster-001"]\n' >"${STUB_DIR}/state.list"
	echo 1 >"${STUB_DIR}/target.rc"
	echo 99 >"${STUB_DIR}/full.fails"
	# No --region: it comes from terraform.tfvars.
	run bash "$S003" --now --state-dir "${STUB_DIR}/window" --retries 2 --retry-wait 0 \
		--sns-topic-arn arn:aws:sns:us-east-2:000000000000:rosa-window
	assert_failure
	assert_output --partial "RESULT FAILED: cluster destroy: FAILED; full destroy: FAILED"
	assert_output --partial "LEAK  terraform state still holds 1 resources"
	assert_output --partial "LEAK  VPC vpc-aaa still exists"
	run grep -c "terraform .* destroy " "${STUB_LOG}"
	assert_output "4"
	run grep "sns publish" "${STUB_LOG}"
	assert_output --partial "--region us-east-2 sns publish --topic-arn arn:aws:sns:us-east-2:000000000000:rosa-window --subject ROSA auto-teardown FAILED"
	run grep -c "^notify-send " "${STUB_LOG}"
	assert_output "1"
}

@test "003 --dry-run destroys and deletes nothing" {
	printf 'module.vpc["cluster-001"]\n' >"${STUB_DIR}/state.list"
	endpoint_json
	run bash "$S003" --dry-run --state-dir "${STUB_DIR}/window"
	assert_success
	assert_output --partial "OK    region us-east-2"
	assert_output --partial "Dry run: 0 problem(s)."
	assert_output --partial "[dry-run] would delete interface endpoint vpce-111"
	run grep -cE ' destroy |delete-|sns publish' "${STUB_LOG}"
	assert_output "0"
	[ ! -e "${STUB_DIR}/window/teardown.log" ]
}

@test "003 --dry-run fails when the rosa login is gone" {
	run env STUB_ROSA_FAIL=1 bash "$S003" --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2
	assert_failure
	assert_output --partial "FAIL  rosa token --refresh failed"
}

@test "003 --dry-run with only the quota resources in state and no saved copy skips 002" {
	# P0 applies the service quotas a day early; by_cluster.json is only saved after apply.
	rm -f "${STUB_DIR}/window/by_cluster.json"
	printf 'data.aws_servicequotas_service_quota.vpc\naws_servicequotas_service_quota.vpc[0]\n' >"${STUB_DIR}/state.list"
	run bash "$S003" --dry-run --state-dir "${STUB_DIR}/window"
	assert_success
	assert_output --partial "OK    terraform state: 2 resources, 0 VPC(s)"
	assert_output --partial "INFO  no VPC known yet (no saved copy, no aws_vpc in state): 002 --dry-run skipped"
	assert_output --partial "Dry run: 0 problem(s)."
	refute_output --partial "cannot read"
	run grep -c "describe-vpcs" "${STUB_LOG}"
	assert_output "0"
}

@test "003 cleans the VPCs only the state knows when no copy was saved" {
	# The clusters already left state (a manual destroy that stopped on a DependencyViolation)
	# and nobody saved by_cluster.json: 002 must run without --by-cluster-json and use the state.
	rm -f "${STUB_DIR}/window/by_cluster.json"
	printf 'module.vpc["cluster-001"].aws_vpc.this[0]\n' >"${STUB_DIR}/state.list"
	cat >"${STUB_DIR}/state.json" <<'EOF'
{"values": {"root_module": {"child_modules": [{"resources": [
 {"address": "module.vpc[\"cluster-001\"].aws_vpc.this[0]", "type": "aws_vpc",
  "values": {"id": "vpc-aaa", "arn": "arn:aws:ec2:us-east-2:000000000000:vpc/vpc-aaa"}}]}]}}}
EOF
	echo 1 >"${STUB_DIR}/full.fails"
	run bash "$S003" --now --state-dir "${STUB_DIR}/window" --retry-wait 0
	assert_output --partial "002 falls back to terraform state"
	assert_output --partial "VPCs:    1 (saved copy: 0, terraform output: 0, state: 1)"
	refute_output --partial "cannot read"
	refute_output --partial "--by-cluster-json"
	assert_output --partial "full destroy: ok"
	run grep -c "=== Pre-destroy VPC cleanup ===" "${STUB_DIR}/window/teardown.log"
	assert_output "2"
}

@test "003 and 002 ignore an exported TF_WORKSPACE: rosa-hcp has only the default workspace" {
	# The runbook's platform commands use TF_WORKSPACE=rosa; exported, it would aim every rosa-hcp
	# command at an empty workspace whose destroy "succeeds" with nothing destroyed.
	printf 'module.rosa_hcp["cluster-001"]\nmodule.vpc["cluster-001"].aws_vpc.this[0]\n' >"${STUB_DIR}/state.list"
	echo '{"cluster-001": {"cluster_name": "cluster-001", "vpc_id": "vpc-aaa"}}' >"${STUB_DIR}/output.json"
	run env TF_WORKSPACE=rosa bash "$S003" --now --state-dir "${STUB_DIR}/window" --region us-east-2 --retry-wait 0
	assert_success
	assert_output --partial "INFO  TF_WORKSPACE=rosa ignored"
	assert_output --partial "RESULT CLEAN"
	run grep -c "ws=rosa" "${STUB_LOG}"
	assert_output "0"

	cat >"${STUB_DIR}/state.json" <<'EOF'
{"values": {"root_module": {"child_modules": [{"resources": [
 {"address": "module.vpc[\"cluster-003\"].aws_vpc.this[0]", "type": "aws_vpc",
  "values": {"id": "vpc-ccc", "arn": "arn:aws:ec2:us-east-2:000000000000:vpc/vpc-ccc"}}]}]}}}
EOF
	run env TF_WORKSPACE=rosa bash "$S002" --dry-run
	assert_success
	assert_output --partial "note: ignoring TF_WORKSPACE=rosa"
	assert_output --partial "VPCs:    1 (saved copy: 0, terraform output: 0, state: 1)"
}

@test "003 --dry-run fails while rosa-hcp state sits in another workspace" {
	mkdir -p "${STUB_DIR}/tf/terraform.tfstate.d/rosa"
	echo '{"resources": [{"mode": "managed", "type": "rhcs_cluster_rosa_hcp"}, {"mode": "data", "type": "aws_region"}]}' \
		>"${STUB_DIR}/tf/terraform.tfstate.d/rosa/terraform.tfstate"
	run bash "$S003" --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2
	assert_failure
	assert_output --partial "FAIL  resources in other rosa-hcp workspaces: rosa(1)"
}

@test "003 destroys nothing without --now: no mode, or --fire-after/--unit without --arm" {
	run bash "$S003" --state-dir "${STUB_DIR}/window" --region us-east-2
	assert_failure
	assert_output --partial "choose a mode: --now"
	# A re-arm after a reboot that forgets --arm, with and without --dry-run.
	run bash "$S003" --fire-after 8h15m --sns-topic-arn arn:aws:sns:us-east-2:000000000000:rosa-window \
		--state-dir "${STUB_DIR}/window"
	assert_failure
	assert_output --partial "--fire-after needs --arm"
	run bash "$S003" --fire-after 8h15m --dry-run --state-dir "${STUB_DIR}/window"
	assert_failure
	assert_output --partial "--fire-after needs --arm"
	run bash "$S003" --now --unit rosa-autoteardown --state-dir "${STUB_DIR}/window"
	assert_failure
	assert_output --partial "--unit needs --arm or --disarm"
	run bash "$S003" --arm --now --state-dir "${STUB_DIR}/window"
	assert_failure
	assert_output --partial "exclude each other"
	run cat "${STUB_LOG}"
	assert_output ""
}

# --- 003: arming the timer ---

@test "003 --arm --dry-run aims both triggers at T0 + --fire-after" {
	t0=$(($(date -u +%s) - 3600))
	echo "$t0" >"${STUB_DIR}/window/t0"
	expected="$(date -u -d "@$((t0 + 7200))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$((t0 + 7200))" '+%Y-%m-%d %H:%M:%S')"
	run env AWS_PROFILE=window bash "$S003" --arm --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 --fire-after 2h \
		--sns-topic-arn "$SNS"
	assert_success
	assert_output --partial "fires at ${expected} UTC (T0 from"
	assert_output --partial "--on-calendar=${expected// /\\ }\\ UTC"
	assert_output --partial "--setenv=AWS_PROFILE=window --setenv=AWS_REGION=us-east-2"
	assert_output --regexp "--on-active=3[56][0-9][0-9]s"
	assert_output --partial "003-auto-teardown.sh --now --state-dir"
	assert_output --partial "--sns-topic-arn ${SNS}"
	assert_output --partial "OK    SNS topic: 1 confirmed subscription(s)"
	assert_output --partial "would publish to SNS: ROSA auto-teardown armed: fires at ${expected} UTC"
	run grep -cE "^systemd-run |sns publish" "${STUB_LOG}"
	assert_output "0"
}

@test "003 --arm refuses without an SNS topic that has a confirmed subscription" {
	# The SNS email is the only alert that reaches an operator away from the host.
	run bash "$S003" --arm --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 --fire-after 2h
	assert_failure
	assert_output --partial "FAIL  no --sns-topic-arn: --arm needs a topic with a confirmed email subscription"
	run env STUB_SNS_CONFIRMED=0 bash "$S003" --arm --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 \
		--fire-after 2h --sns-topic-arn "$SNS"
	assert_failure
	assert_output --partial "FAIL  SNS topic has no confirmed subscription"
	run env STUB_SNS_FAIL=1 bash "$S003" --arm --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 \
		--fire-after 2h --sns-topic-arn "$SNS"
	assert_failure
	assert_output --partial "FAIL  cannot read SNS topic ${SNS}"
	# The P0 teardown dry run flags an unconfirmed topic too, but runs without one.
	run env STUB_SNS_CONFIRMED=0 bash "$S003" --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 \
		--sns-topic-arn "$SNS"
	assert_failure
	assert_output --partial "FAIL  SNS topic has no confirmed subscription"
	run bash "$S003" --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2
	assert_success
	assert_output --partial "INFO  no --sns-topic-arn: the result reaches only this host's desktop"
	run grep -cE "^systemd-run |sns publish" "${STUB_LOG}"
	assert_output "0"
}

@test "003 --arm arms the timer, then publishes an armed message to SNS" {
	echo "$(($(date -u +%s) - 3600))" >"${STUB_DIR}/window/t0"
	run bash "$S003" --arm --state-dir "${STUB_DIR}/window" --region us-east-2 --fire-after 2h --sns-topic-arn "$SNS"
	assert_success
	run grep -c "^systemd-run --user --unit=rosa-autoteardown " "${STUB_LOG}"
	assert_output "1"
	run grep "sns publish" "${STUB_LOG}"
	assert_output --partial "--region us-east-2 sns publish --topic-arn ${SNS} --subject ROSA auto-teardown armed: fires at "
}

@test "003 --arm defaults to the window plan's Tier C deadline, T0 + 8h15m" {
	t0=$(($(date -u +%s) - 3600))
	echo "$t0" >"${STUB_DIR}/window/t0"
	expected="$(date -u -d "@$((t0 + 29700))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$((t0 + 29700))" '+%Y-%m-%d %H:%M:%S')"
	run bash "$S003" --arm --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 --sns-topic-arn "$SNS"
	assert_success
	assert_output --partial "fires at ${expected} UTC (T0 from"
	assert_output --partial "+ 8h15m;"
}

@test "003 --arm on WSL needs instanceIdleTimeout=-1 in .wslconfig" {
	echo "Linux version 5.15.167.4-microsoft-standard-WSL2" >"${STUB_DIR}/proc_version"
	run bash "$S003" --arm --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 --fire-after 2h --sns-topic-arn "$SNS"
	assert_failure
	assert_output --partial "Dry run: 1 problem(s)."
	assert_output --partial "FAIL  WSL: ${STUB_DIR}/winhome/.wslconfig has no [general] instanceIdleTimeout=-1 (unset)"
	# The teardown dry run at P0 flags it too.
	run bash "$S003" --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2
	assert_failure
	assert_output --partial "FAIL  WSL:"
	printf '[wsl2]\r\nvmIdleTimeout=-1\r\n\r\n[general]\r\ninstanceIdleTimeout = -1   # keep the timer alive\r\n' \
		>"${STUB_DIR}/winhome/.wslconfig"
	run bash "$S003" --arm --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 --fire-after 2h --sns-topic-arn "$SNS"
	assert_success
	assert_output --partial "OK    WSL: instanceIdleTimeout=-1"
}

@test "003 --arm refuses a deadline that has passed" {
	echo "$(($(date -u +%s) - 36000))" >"${STUB_DIR}/window/t0"
	run bash "$S003" --arm --dry-run --state-dir "${STUB_DIR}/window" --region us-east-2 --fire-after 8h15m
	assert_failure
	assert_output --partial "has passed or is under a minute away"
}
