#!/usr/bin/env bash
# Shared helpers for the SafeTrace Task 1 AWS CLI deployment scripts.
# Sourced by deploy.sh and teardown.sh.

set -euo pipefail

# --- pretty logging -----------------------------------------------------------
c_reset='\033[0m'; c_green='\033[0;32m'; c_blue='\033[0;34m'; c_yellow='\033[0;33m'; c_red='\033[0;31m'
log()   { printf "${c_blue}▸ %s${c_reset}\n" "$*"; }
ok()    { printf "${c_green}✓ %s${c_reset}\n" "$*"; }
warn()  { printf "${c_yellow}! %s${c_reset}\n" "$*"; }
die()   { printf "${c_red}✗ %s${c_reset}\n" "$*" >&2; exit 1; }

# --- prerequisites ------------------------------------------------------------
require_cli() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are not configured. Run 'aws configure' first."
}

aws_account_id() { aws sts get-caller-identity --query Account --output text; }

# --- state file ---------------------------------------------------------------
# Persist created resource identifiers so teardown can find them.
state_set() {
  local key="$1" value="$2"
  touch "$STATE_FILE"
  grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || true
  echo "${key}=${value}" >> "$STATE_FILE"
}
state_load() { [ -f "$STATE_FILE" ] && set -a && source "$STATE_FILE" && set +a || true; }

# --- generic AWS helpers ------------------------------------------------------
aws_q() { aws --region "$AWS_REGION" "$@"; }

# Find a resource id by Name tag; echoes empty string if not found.
find_by_name_tag() {
  local resource="$1" name="$2" query="$3"
  aws_q ec2 "describe-${resource}" \
    --filters "Name=tag:Name,Values=${name}" "Name=vpc-id,Values=${VPC_ID:-*}" \
    --query "$query" --output text 2>/dev/null | grep -v '^None$' || true
}

tag_resource() {
  local id="$1" name="$2"
  aws_q ec2 create-tags --resources "$id" \
    --tags "Key=Name,Value=${name}" "Key=Project,Value=${PROJECT}" >/dev/null
}
