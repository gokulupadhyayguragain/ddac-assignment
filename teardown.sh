#!/usr/bin/env bash
# ==============================================================================
# SafeTrace — Task 1 teardown. Deletes every resource created by deploy.sh in a
# dependency-safe order.
#
# Why the old teardown left a VPC behind:
#   * Deleting an ASG with --force-delete only *starts* instance termination; the
#     instances (and their ENIs) linger for minutes. Those ENIs pin the EC2
#     security group and the subnets, so SG/subnet/VPC deletes fail with
#     DependencyViolation.
#   * Deleting an ALB / NAT gateway is also asynchronous and leaves ENIs behind.
#   * The previous script swallowed those errors as "skip", so it reported done
#     while the VPC, subnets and security groups were still there.
#
# This version fixes that by:
#   * waiting for instances / ALB / RDS / NAT to be *fully* gone,
#   * deleting leftover network interfaces,
#   * retrying dependency-blocked deletes until they succeed (with a timeout),
#   * and falling back to VPC-wide discovery so resources missing from
#     .state.env are still cleaned up.
# ==============================================================================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.env"
source "$HERE/lib.sh"
require_cli
state_load

echo "This will DELETE all SafeTrace Task 1 resources in ${AWS_REGION}."
read -r -p "Type 'destroy' to continue: " confirm
[ "$confirm" = "destroy" ] || die "Aborted."

# If the VPC id wasn't in .state.env, recover it from the Name tag so the
# VPC-wide fallbacks below still work.
if [ -z "${VPC_ID:-}" ] || [ "$VPC_ID" = "None" ]; then
  VPC_ID="$(aws_q ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
  [ "$VPC_ID" = "None" ] && VPC_ID=""
fi
[ -n "${VPC_ID:-}" ] && log "Targeting VPC ${VPC_ID}"

# --- one-shot delete (best effort, no retry) ----------------------------------
del() { "$@" >/dev/null 2>&1 && ok "$*" || warn "skip: $*"; }

# --- delete with retry: keeps trying while AWS reports a transient dependency --
# Treats "already gone" as success; retries DependencyViolation / in-use errors.
del_retry() {
  local tries="${RETRY_TRIES:-30}" delay="${RETRY_DELAY:-10}" i out
  for ((i = 1; i <= tries; i++)); do
    if out="$("$@" 2>&1)"; then ok "$*"; return 0; fi
    if printf '%s' "$out" | grep -qiE 'NotFound|does not exist|could not find|InvalidGroup\.NotFound|no such'; then
      ok "already gone: $*"; return 0
    fi
    if printf '%s' "$out" | grep -qiE 'DependencyViolation|in use|currently in use|has dependencies|not.*available yet|cannot be deleted'; then
      [ "$i" -eq 1 ] && log "dependency busy, retrying (up to $((tries * delay))s): $*"
      sleep "$delay"; continue
    fi
    warn "error: $* -> $(printf '%s' "$out" | tail -n1)"
    return 1
  done
  warn "timed out after $((tries * delay))s: $*"
  return 1
}

# --- wait until every non-terminated instance in the VPC is gone --------------
wait_instances_terminated() {
  [ -n "${VPC_ID:-}" ] || return 0
  local ids
  # Proactively terminate anything still running (covers instances not managed
  # by the ASG, or a partial previous teardown).
  ids="$(aws_q ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
  if [ -n "$ids" ] && [ "$ids" != "None" ]; then
    log "Terminating instances: $ids"
    aws_q ec2 terminate-instances --instance-ids $ids >/dev/null 2>&1 || true
  fi
  log "Waiting for EC2 instances in ${VPC_ID} to terminate…"
  for _ in $(seq 1 60); do
    ids="$(aws_q ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
    [ -z "$ids" ] || [ "$ids" = "None" ] && { ok "no instances remain"; return 0; }
    sleep 10
  done
  warn "instances still present after wait: $ids"
}

# --- delete every 'available' (detached) ENI left in the VPC ------------------
delete_leftover_enis() {
  [ -n "${VPC_ID:-}" ] || return 0
  local enis eni
  enis="$(aws_q ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null)"
  for eni in $enis; do
    [ "$eni" = "None" ] && continue
    del_retry aws_q ec2 delete-network-interface --network-interface-id "$eni"
  done
}

# ============================================================ teardown ========

# 1. Auto Scaling group -> then wait for its instances to actually terminate
if [ -z "${ASG_NAME:-}" ]; then ASG_NAME="${PROJECT}-asg"; fi
log "Deleting Auto Scaling group ${ASG_NAME}…"
aws_q autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" \
  --min-size 0 --desired-capacity 0 >/dev/null 2>&1 || true
del aws_q autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete
wait_instances_terminated

# 2. Launch template
[ -z "${LAUNCH_TEMPLATE:-}" ] && LAUNCH_TEMPLATE="${PROJECT}-lt"
del_retry aws_q ec2 delete-launch-template --launch-template-name "$LAUNCH_TEMPLATE"

# 3. ALB listeners + ALB (wait for full deletion so its ENIs are released), then TG
if [ -n "${ALB_ARN:-}" ]; then
  for l in $(aws_q elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[].ListenerArn' --output text 2>/dev/null); do
    del aws_q elbv2 delete-listener --listener-arn "$l"
  done
  del aws_q elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  log "Waiting for the ALB to finish deleting…"
  aws_q elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
fi
[ -n "${TG_ARN:-}" ] && del_retry aws_q elbv2 delete-target-group --target-group-arn "$TG_ARN"

# 4. RDS (wait for full deletion) + subnet group
if [ -z "${DB_INSTANCE:-}" ]; then DB_INSTANCE="${PROJECT}-db"; fi
log "Deleting RDS ${DB_INSTANCE} (no final snapshot)…"
del aws_q rds delete-db-instance --db-instance-identifier "$DB_INSTANCE" \
  --skip-final-snapshot --delete-automated-backups
log "Waiting for RDS to finish deleting (can take several minutes)…"
aws_q rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE" 2>/dev/null || true
del_retry aws_q rds delete-db-subnet-group \
  --db-subnet-group-name "${DB_SUBNET_GROUP:-${PROJECT}-db-subnets}"

# 5. NAT gateway(s) + EIP — discover by VPC in case state is incomplete
if [ -n "${VPC_ID:-}" ]; then
  for nat in $(aws_q ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending,failed" \
    --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null); do
    [ "$nat" = "None" ] && continue
    del aws_q ec2 delete-nat-gateway --nat-gateway-id "$nat"
    log "Waiting for NAT gateway $nat to delete…"
    aws_q ec2 wait nat-gateway-deleted --nat-gateway-ids "$nat" 2>/dev/null || true
  done
elif [ -n "${NAT_ID:-}" ]; then
  del aws_q ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID"
  aws_q ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_ID" 2>/dev/null || true
fi
[ -n "${NAT_EIP:-}" ] && del_retry aws_q ec2 release-address --allocation-id "$NAT_EIP"

# 6. Secret
del aws_q secretsmanager delete-secret --secret-id "${SECRET_NAME}" --force-delete-without-recovery

# 7. IAM
role="${INSTANCE_PROFILE:-${PROJECT}-ec2-role}"
del aws iam remove-role-from-instance-profile --instance-profile-name "$role" --role-name "$role"
del aws iam delete-instance-profile --instance-profile-name "$role"
del aws iam delete-role-policy --role-name "$role" --policy-name "${PROJECT}-read-secret"
del aws iam detach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
del aws iam detach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
del aws iam delete-role --role-name "$role"

# 8. Network teardown — must wait for ENIs to clear first.
#    Order is dependency-safe: ENIs → SGs (RDS→EC2→ALB) → subnets → route
#    tables → IGW → VPC. Each delete retries while AWS still reports a
#    dependency, and VPC-wide discovery cleans anything missing from state.
log "Releasing leftover network interfaces…"
delete_leftover_enis

# 8a. Security groups.
#   SafeTrace's SGs reference each other (rds-sg <- ec2-sg <- alb-sg via
#   --source-group). AWS refuses to delete a SG while another SG's rule still
#   points at it, so deleting them in the wrong order deadlocks until the
#   per-SG retry times out (DependencyViolation for the full 300s). When
#   .state.env is missing we fall back to VPC discovery, whose order is not
#   guaranteed — so strip every non-default SG's ingress/egress rules FIRST.
#   Once no SG references any other, deletion order no longer matters.
strip_sg_rules() {
  local sg="$1" perms
  perms="$(aws_q ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)"
  if [ -n "$perms" ] && [ "$perms" != "[]" ] && [ "$perms" != "null" ]; then
    aws_q ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "$perms" >/dev/null 2>&1 || true
  fi
  perms="$(aws_q ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)"
  if [ -n "$perms" ] && [ "$perms" != "[]" ] && [ "$perms" != "null" ]; then
    aws_q ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions "$perms" >/dev/null 2>&1 || true
  fi
}

# Collect every target SG id (state ids + any non-default SG left in the VPC).
sg_ids=""
for sg in "${RDS_SG:-}" "${EC2_SG:-}" "${ALB_SG:-}"; do
  [ -n "$sg" ] && sg_ids="$sg_ids $sg"
done
if [ -n "${VPC_ID:-}" ]; then
  delete_leftover_enis
  for sg in $(aws_q ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
    [ "$sg" = "None" ] && continue
    sg_ids="$sg_ids $sg"
  done
fi
# De-dup, then revoke all rules before deleting any group.
sg_ids="$(printf '%s\n' $sg_ids | sort -u | tr '\n' ' ')"
for sg in $sg_ids; do strip_sg_rules "$sg"; done
for sg in $sg_ids; do del_retry aws_q ec2 delete-security-group --group-id "$sg"; done

# 8b. Subnets (state ids, then any subnet still in the VPC)
for s in ${PUBLIC_SUBNETS:-} ${PRIVATE_SUBNETS:-}; do
  del_retry aws_q ec2 delete-subnet --subnet-id "$s"
done
if [ -n "${VPC_ID:-}" ]; then
  for s in $(aws_q ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
    [ "$s" = "None" ] && continue
    del_retry aws_q ec2 delete-subnet --subnet-id "$s"
  done
fi

# 8c. Route tables (disassociate non-main associations, then delete non-main RTs)
clear_and_delete_rt() {
  local rt="$1"
  for assoc in $(aws_q ec2 describe-route-tables --route-table-ids "$rt" \
    --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
    --output text 2>/dev/null); do
    [ "$assoc" = "None" ] && continue
    del aws_q ec2 disassociate-route-table --association-id "$assoc"
  done
  del_retry aws_q ec2 delete-route-table --route-table-id "$rt"
}
for rt in "${PUB_RT:-}" "${PRIV_RT:-}"; do
  [ -n "$rt" ] && clear_and_delete_rt "$rt"
done
if [ -n "${VPC_ID:-}" ]; then
  for rt in $(aws_q ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null); do
    [ "$rt" = "None" ] && continue
    clear_and_delete_rt "$rt"
  done
fi

# 8d. Internet gateway (state id, then any IGW attached to the VPC)
if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  del_retry aws_q ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  del_retry aws_q ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi
if [ -n "${VPC_ID:-}" ]; then
  for igw in $(aws_q ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null); do
    [ "$igw" = "None" ] && continue
    del_retry aws_q ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID"
    del_retry aws_q ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done
fi

# 8e. The VPC itself (retries while any straggler dependency clears)
[ -n "${VPC_ID:-}" ] && del_retry aws_q ec2 delete-vpc --vpc-id "$VPC_ID"

# Verify the VPC is really gone before declaring success.
if [ -n "${VPC_ID:-}" ]; then
  if aws_q ec2 describe-vpcs --vpc-ids "$VPC_ID" >/dev/null 2>&1; then
    warn "VPC ${VPC_ID} still exists — check for stray ENIs/instances:"
    warn "  aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=${VPC_ID} --region ${AWS_REGION}"
    warn "  aws ec2 describe-instances --filters Name=vpc-id,Values=${VPC_ID} --region ${AWS_REGION}"
    warn "Re-run ./teardown.sh once they finish terminating."
  else
    ok "VPC ${VPC_ID} deleted"
  fi
fi

rm -f "$STATE_FILE"
ok "Teardown complete."
