#!/usr/bin/env bash
# ==============================================================================
# SafeTrace — Task 1 serverful deployment, provisioned entirely with the AWS CLI.
#
#   Browser → ALB (HTTP 80) → EC2 Auto Scaling Group (2 AZs)
#           → Docker Compose (Next.js :80 + Express :5000) → RDS PostgreSQL (private)
#   Secrets Manager → app config   |   CloudWatch → metrics/logs
#
# The script is idempotent: re-running it reuses existing resources by Name tag.
# Resource ids are written to .state.env for teardown.sh.
# ==============================================================================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.env"
source "$HERE/lib.sh"

require_cli
[ -n "$DB_PASSWORD" ] || die "DB_PASSWORD is empty. Set it in config.env (8+ chars, avoid / @ \" space)."
[ -n "$JWT_SECRET" ] || JWT_SECRET="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c40)"

ACCOUNT_ID="$(aws_account_id)"
log "Account ${ACCOUNT_ID} · region ${AWS_REGION} · project ${PROJECT}"
: > "$STATE_FILE"
state_set AWS_REGION "$AWS_REGION"

# ------------------------------------------------------------------ 1. VPC ----
ensure_vpc() {
  VPC_ID="$(aws_q ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT}-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
  if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
    VPC_ID="$(aws_q ec2 create-vpc --cidr-block "$VPC_CIDR" --query 'Vpc.VpcId' --output text)"
    aws_q ec2 wait vpc-available --vpc-ids "$VPC_ID"
    tag_resource "$VPC_ID" "${PROJECT}-vpc"
    aws_q ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
    aws_q ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
  fi
  state_set VPC_ID "$VPC_ID"; ok "VPC ${VPC_ID}"
}

# -------------------------------------------------------------- 2. Subnets ----
ensure_subnets() {
  mapfile -t AZS < <(aws_q ec2 describe-availability-zones --query 'AvailabilityZones[0:2].ZoneName' --output text | tr '\t' '\n')
  PUBLIC_SUBNETS=(); PRIVATE_SUBNETS=()
  local i=0
  for cidr in $PUBLIC_SUBNET_CIDRS; do
    local az="${AZS[$i]}" name="${PROJECT}-public-$((i+1))"
    local id; id="$(find_by_name_tag subnets "$name" 'Subnets[0].SubnetId')"
    if [ -z "$id" ]; then
      id="$(aws_q ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" --query 'Subnet.SubnetId' --output text)"
      tag_resource "$id" "$name"
      aws_q ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch
    fi
    PUBLIC_SUBNETS+=("$id"); i=$((i+1))
  done
  i=0
  for cidr in $PRIVATE_SUBNET_CIDRS; do
    local az="${AZS[$i]}" name="${PROJECT}-private-$((i+1))"
    local id; id="$(find_by_name_tag subnets "$name" 'Subnets[0].SubnetId')"
    if [ -z "$id" ]; then
      id="$(aws_q ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" --query 'Subnet.SubnetId' --output text)"
      tag_resource "$id" "$name"
    fi
    PRIVATE_SUBNETS+=("$id"); i=$((i+1))
  done
  state_set PUBLIC_SUBNETS "${PUBLIC_SUBNETS[*]}"
  state_set PRIVATE_SUBNETS "${PRIVATE_SUBNETS[*]}"
  ok "Subnets public=[${PUBLIC_SUBNETS[*]}] private=[${PRIVATE_SUBNETS[*]}]"
}

# ----------------------------------------------- 3. IGW + NAT + route tables --
ensure_routing() {
  IGW_ID="$(aws_q ec2 describe-internet-gateways --filters "Name=tag:Name,Values=${PROJECT}-igw" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)"
  if [ "$IGW_ID" = "None" ] || [ -z "$IGW_ID" ]; then
    IGW_ID="$(aws_q ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)"
    tag_resource "$IGW_ID" "${PROJECT}-igw"
    aws_q ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" || true
  fi
  state_set IGW_ID "$IGW_ID"

  # public route table
  PUB_RT="$(find_by_name_tag route-tables "${PROJECT}-public-rt" 'RouteTables[0].RouteTableId')"
  if [ -z "$PUB_RT" ]; then
    PUB_RT="$(aws_q ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)"
    tag_resource "$PUB_RT" "${PROJECT}-public-rt"
    aws_q ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  fi
  for s in "${PUBLIC_SUBNETS[@]}"; do aws_q ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$s" >/dev/null 2>&1 || true; done
  state_set PUB_RT "$PUB_RT"

  # private route table (+ NAT if not using public instances)
  PRIV_RT="$(find_by_name_tag route-tables "${PROJECT}-private-rt" 'RouteTables[0].RouteTableId')"
  if [ -z "$PRIV_RT" ]; then
    PRIV_RT="$(aws_q ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)"
    tag_resource "$PRIV_RT" "${PROJECT}-private-rt"
  fi
  for s in "${PRIVATE_SUBNETS[@]}"; do aws_q ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$s" >/dev/null 2>&1 || true; done
  state_set PRIV_RT "$PRIV_RT"

  if [ "$USE_PUBLIC_INSTANCES" != "true" ]; then
    NAT_ID="$(aws_q ec2 describe-nat-gateways --filter "Name=tag:Name,Values=${PROJECT}-nat" "Name=state,Values=available,pending" --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)"
    if [ "$NAT_ID" = "None" ] || [ -z "$NAT_ID" ]; then
      local eip; eip="$(aws_q ec2 allocate-address --domain vpc --query AllocationId --output text)"
      tag_resource "$eip" "${PROJECT}-nat-eip"
      NAT_ID="$(aws_q ec2 create-nat-gateway --subnet-id "${PUBLIC_SUBNETS[0]}" --allocation-id "$eip" --query 'NatGateway.NatGatewayId' --output text)"
      tag_resource "$NAT_ID" "${PROJECT}-nat"
      log "Waiting for NAT gateway…"; aws_q ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"
      state_set NAT_EIP "$eip"
    fi
    aws_q ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null 2>&1 || true
    state_set NAT_ID "$NAT_ID"
  fi
  ok "Routing ready (igw=${IGW_ID})"
}

# ------------------------------------------------------ 4. Security groups ----
sg_create() {
  local name="$1" desc="$2" id
  id="$(aws_q ec2 describe-security-groups --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws_q ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" --query GroupId --output text)"
    tag_resource "$id" "$name"
  fi
  echo "$id"
}
ensure_security_groups() {
  ALB_SG="$(sg_create "${PROJECT}-alb-sg" 'SafeTrace ALB')"
  EC2_SG="$(sg_create "${PROJECT}-ec2-sg" 'SafeTrace instances')"
  RDS_SG="$(sg_create "${PROJECT}-rds-sg" 'SafeTrace database')"
  # ALB: HTTP/HTTPS from the internet
  aws_q ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  aws_q ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  # EC2: HTTP 80 from ALB only
  aws_q ec2 authorize-security-group-ingress --group-id "$EC2_SG" --protocol tcp --port 80 --source-group "$ALB_SG" >/dev/null 2>&1 || true
  # RDS: 5432 from EC2 only
  aws_q ec2 authorize-security-group-ingress --group-id "$RDS_SG" --protocol tcp --port 5432 --source-group "$EC2_SG" >/dev/null 2>&1 || true
  state_set ALB_SG "$ALB_SG"; state_set EC2_SG "$EC2_SG"; state_set RDS_SG "$RDS_SG"
  ok "Security groups alb=${ALB_SG} ec2=${EC2_SG} rds=${RDS_SG}"
}

# ----------------------------------------------------------------- 5. IAM ----
ensure_iam() {
  local role="${PROJECT}-ec2-role"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam create-role --role-name "$role" --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  fi
  aws iam attach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy >/dev/null 2>&1 || true
  aws iam attach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
  aws iam put-role-policy --role-name "$role" --policy-name "${PROJECT}-read-secret" --policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:${SECRET_NAME}*\"}]}" >/dev/null
  if ! aws iam get-instance-profile --instance-profile-name "$role" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$role" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$role" --role-name "$role" >/dev/null
    sleep 10  # allow the instance profile to propagate
  fi
  INSTANCE_PROFILE="$role"; state_set INSTANCE_PROFILE "$role"
  ok "IAM role + instance profile ${role}"
}

# ----------------------------------------------------------------- 6. RDS ----
write_secret() {
  local db_url="$1" frontend_url="$2"
  local json
  json="$(printf '{"DATABASE_URL":"%s","JWT_SECRET":"%s","AWS_REGION":"%s","FRONTEND_PUBLIC_URL":"%s","AUTH_VERIFICATION_TTL_MINUTES":"10","AUTH_DEV_EXPOSE_VERIFICATION_CODE":"%s","TRUST_PROXY":"true"}' \
    "$db_url" "$JWT_SECRET" "$AWS_REGION" "$frontend_url" "$AUTH_DEV_EXPOSE_VERIFICATION_CODE")"
  if aws_q secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
    aws_q secretsmanager put-secret-value --secret-id "$SECRET_NAME" --secret-string "$json" >/dev/null
  else
    aws_q secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$json" >/dev/null
  fi
  state_set SECRET_NAME "$SECRET_NAME"
}
ensure_rds() {
  local subnet_group="${PROJECT}-db-subnets"
  aws_q rds create-db-subnet-group --db-subnet-group-name "$subnet_group" \
    --db-subnet-group-description "SafeTrace private DB subnets" \
    --subnet-ids "${PRIVATE_SUBNETS[@]}" >/dev/null 2>&1 || true
  if ! aws_q rds describe-db-instances --db-instance-identifier "${PROJECT}-db" >/dev/null 2>&1; then
    local multiaz="--no-multi-az"; [ "$DB_MULTI_AZ" = "true" ] && multiaz="--multi-az"
    aws_q rds create-db-instance \
      --db-instance-identifier "${PROJECT}-db" \
      --db-name "$DB_NAME" --engine postgres --engine-version "$DB_ENGINE_VERSION" \
      --master-username "$DB_USERNAME" --master-user-password "$DB_PASSWORD" \
      --db-instance-class "$DB_INSTANCE_CLASS" --allocated-storage "$DB_ALLOCATED_STORAGE" --storage-type gp3 \
      --db-subnet-group-name "$subnet_group" --vpc-security-group-ids "$RDS_SG" \
      --no-publicly-accessible --backup-retention-period 1 $multiaz >/dev/null
  fi
  log "Waiting for RDS to become available (this can take ~10 minutes)…"
  aws_q rds wait db-instance-available --db-instance-identifier "${PROJECT}-db"
  DB_ENDPOINT="$(aws_q rds describe-db-instances --db-instance-identifier "${PROJECT}-db" --query 'DBInstances[0].Endpoint.Address' --output text)"
  state_set DB_INSTANCE "${PROJECT}-db"; state_set DB_SUBNET_GROUP "$subnet_group"
  ok "RDS endpoint ${DB_ENDPOINT}"
}

# ----------------------------------------------------- 7. Target group/ALB ----
ensure_target_group() {
  TG_ARN="$(aws_q elbv2 describe-target-groups --names "${PROJECT}-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
  if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
    TG_ARN="$(aws_q elbv2 create-target-group --name "${PROJECT}-tg" --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
      --health-check-path /api/health --health-check-interval-seconds 30 --healthy-threshold-count 2 \
      --matcher HttpCode=200 --target-type instance --query 'TargetGroups[0].TargetGroupArn' --output text)"
  fi
  state_set TG_ARN "$TG_ARN"; ok "Target group ${TG_ARN}"
}
ensure_alb() {
  local subnets=("${PRIVATE_SUBNETS[@]}")
  ALB_ARN="$(aws_q elbv2 describe-load-balancers --names "${PROJECT}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
  if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
    ALB_ARN="$(aws_q elbv2 create-load-balancer --name "${PROJECT}-alb" --type application --scheme internet-facing \
      --subnets "${PUBLIC_SUBNETS[@]}" --security-groups "$ALB_SG" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  fi
  log "Waiting for ALB…"; aws_q elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
  ALB_DNS="$(aws_q elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"
  if ! aws_q elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`80`]' --output text | grep -q .; then
    aws_q elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" >/dev/null
  fi
  state_set ALB_ARN "$ALB_ARN"; state_set ALB_DNS "$ALB_DNS"; ok "ALB ${ALB_DNS}"
}

# ------------------------------------------------------ 8. Launch template ----
ensure_launch_template() {
  AMI_ID="$(aws_q ssm get-parameters --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query 'Parameters[0].Value' --output text)"
  local subnet_ids; subnet_ids="${PRIVATE_SUBNETS[*]}"
  [ "$USE_PUBLIC_INSTANCES" = "true" ] && subnet_ids="${PUBLIC_SUBNETS[*]}"

  # Build user-data from the repo bootstrap script, injecting the chosen repo URL.
  local ud_tmp; ud_tmp="$(mktemp)"
  sed "s#https://github.com/gokulupadhyayguragain/ddac-assignment.git#${REPO_URL}#g" "$HERE/../../aws-user-data.sh" > "$ud_tmp"
  local ud_b64; ud_b64="$(base64 -w0 "$ud_tmp" 2>/dev/null || base64 "$ud_tmp" | tr -d '\n')"

  local lt_data; lt_data="$(mktemp)"
  cat > "$lt_data" <<JSON
{
  "ImageId": "${AMI_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "IamInstanceProfile": { "Name": "${INSTANCE_PROFILE}" },
  "SecurityGroupIds": ["${EC2_SG}"],
  "MetadataOptions": { "HttpTokens": "required", "HttpEndpoint": "enabled" },
  "BlockDeviceMappings": [
    { "DeviceName": "/dev/sda1", "Ebs": { "VolumeSize": ${ROOT_VOLUME_GB}, "VolumeType": "gp3", "DeleteOnTermination": true } }
  ],
  "TagSpecifications": [
    { "ResourceType": "instance", "Tags": [ {"Key":"Name","Value":"${PROJECT}-app"}, {"Key":"Project","Value":"${PROJECT}"} ] }
  ],
  "UserData": "${ud_b64}"
}
JSON

  if aws_q ec2 describe-launch-templates --launch-template-names "${PROJECT}-lt" >/dev/null 2>&1; then
    aws_q ec2 create-launch-template-version --launch-template-name "${PROJECT}-lt" \
      --launch-template-data "file://${lt_data}" >/dev/null
  else
    aws_q ec2 create-launch-template --launch-template-name "${PROJECT}-lt" \
      --launch-template-data "file://${lt_data}" >/dev/null
  fi
  rm -f "$ud_tmp" "$lt_data"
  state_set LAUNCH_TEMPLATE "${PROJECT}-lt"
  state_set INSTANCE_SUBNETS "$subnet_ids"
  ok "Launch template ${PROJECT}-lt (AMI ${AMI_ID})"
}

# ----------------------------------------------------------------- 9. ASG ----
ensure_asg() {
  local subnet_ids; subnet_ids="$(echo "$INSTANCE_SUBNETS" | tr ' ' ',')"
  if ! aws_q autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${PROJECT}-asg" --query 'AutoScalingGroups[0]' --output text 2>/dev/null | grep -q .; then
    aws_q autoscaling create-auto-scaling-group --auto-scaling-group-name "${PROJECT}-asg" \
      --launch-template "LaunchTemplateName=${PROJECT}-lt,Version=\$Latest" \
      --min-size "$ASG_MIN" --max-size "$ASG_MAX" --desired-capacity "$ASG_DESIRED" \
      --vpc-zone-identifier "$subnet_ids" \
      --target-group-arns "$TG_ARN" \
      --health-check-type ELB --health-check-grace-period 300 \
      --tags "Key=Name,Value=${PROJECT}-app,PropagateAtLaunch=true,ResourceId=${PROJECT}-asg,ResourceType=auto-scaling-group"
  else
    aws_q autoscaling update-auto-scaling-group --auto-scaling-group-name "${PROJECT}-asg" \
      --launch-template "LaunchTemplateName=${PROJECT}-lt,Version=\$Latest" \
      --min-size "$ASG_MIN" --max-size "$ASG_MAX" --desired-capacity "$ASG_DESIRED"
  fi
  aws_q autoscaling put-scaling-policy --auto-scaling-group-name "${PROJECT}-asg" \
    --policy-name "${PROJECT}-cpu-target" --policy-type TargetTrackingScaling \
    --target-tracking-configuration "{\"PredefinedMetricSpecification\":{\"PredefinedMetricType\":\"ASGAverageCPUUtilization\"},\"TargetValue\":${CPU_TARGET}}" >/dev/null
  state_set ASG_NAME "${PROJECT}-asg"
  ok "Auto Scaling group ${PROJECT}-asg (min=${ASG_MIN} desired=${ASG_DESIRED} max=${ASG_MAX})"
}

# -------------------------------------------------------------- run order ----
ensure_vpc
ensure_subnets
ensure_routing
ensure_security_groups
ensure_iam
ensure_rds
write_secret "postgresql://${DB_USERNAME}:${DB_PASSWORD}@${DB_ENDPOINT}:5432/${DB_NAME}" "http://pending-alb"
ensure_target_group
ensure_alb
write_secret "postgresql://${DB_USERNAME}:${DB_PASSWORD}@${DB_ENDPOINT}:5432/${DB_NAME}" "http://${ALB_DNS}"
ensure_launch_template
ensure_asg

cat <<SUMMARY

$(ok "SafeTrace Task 1 deployment complete")
  App URL        : http://${ALB_DNS}
  Health check   : http://${ALB_DNS}/api/health
  Secret         : ${SECRET_NAME}
  State file     : ${STATE_FILE}

First boot builds the Docker images and can take several minutes. Watch targets:
  aws elbv2 describe-target-health --region ${AWS_REGION} --target-group-arn ${TG_ARN}

Seed demo data once healthy:
  curl -X POST http://${ALB_DNS}/api/admin/seed
SUMMARY
