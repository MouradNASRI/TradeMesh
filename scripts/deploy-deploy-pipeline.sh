#!/usr/bin/env bash
# Deploy the "deploy" CodePipeline stack (Option A: multi-stack deploy).
# - Reads parameters and tags from a JSON file
# - Validates the template
# - Deploys with CAPABILITY_NAMED_IAM
# - (Optional) starts the pipeline after a successful deploy
#
# Usage:
#   ./deploy-deploy-pipeline.sh \
#       [--region us-east-1] \
#       [--stack-name trd-codepipeline-deploy] \
#       [--template-file cloudformation/pipelines/codepipeline-deploy.yml] \
#       [--params-file cloudformation/envs/dev/pipelines/deploy-params.json] \
#       [--profile my-aws-profile] \
#       [--no-validate] \
#       [--run-pipeline]
#
# Requirements: awscli v2, jq

set -euo pipefail

# ---------- defaults (override via flags or env) ----------
REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="trd-codepipeline-deploy"
TEMPLATE_FILE="cloudformation/pipelines/codepipeline-deploy.yml"
PARAMS_FILE="cloudformation/envs/dev/pipelines/deploy-params.json"
PROFILE=""
VALIDATE=true
RUN_PIPELINE=false

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)        REGION="$2"; shift 2 ;;
    --stack-name)    STACK_NAME="$2"; shift 2 ;;
    --template-file) TEMPLATE_FILE="$2"; shift 2 ;;
    --params-file)   PARAMS_FILE="$2"; shift 2 ;;
    --profile)       PROFILE="--profile $2"; shift 2 ;;
    --no-validate)   VALIDATE=false; shift ;;
    --run-pipeline)  RUN_PIPELINE=true; shift ;;
    -h|--help)
      sed -n '1,50p' "$0"; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------- prerequisites ----------
command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found"; exit 1; }

[[ -f "$TEMPLATE_FILE" ]] || { echo "Template not found: $TEMPLATE_FILE"; exit 1; }
[[ -f "$PARAMS_FILE"  ]] || { echo "Params JSON not found: $PARAMS_FILE"; exit 1; }

echo "Region        : $REGION"
echo "Stack name    : $STACK_NAME"
echo "Template file : $TEMPLATE_FILE"
echo "Params file   : $PARAMS_FILE"
echo "Profile       : ${PROFILE/--profile /}"
echo

# ---------- optional template validation (server-side) ----------
if $VALIDATE; then
  echo ">> Validating CloudFormation template..."
  aws cloudformation validate-template \
    --region "$REGION" \
    --template-body "file://$TEMPLATE_FILE" $PROFILE >/dev/null
  echo "OK"
  echo
fi

# ---------- extract parameters & tags from JSON ----------
echo ">> Reading parameters and tags from JSON..."
# Build an array of --parameter-overrides entries (handles spaces safely)
readarray -t PARAM_OVERRIDES < <(jq -r '.Parameters|to_entries|map("\(.key)=\(.value|tostring)")|.[]' "$PARAMS_FILE")
readarray -t TAG_OVERRIDES    < <(jq -r '.Tags|to_entries|map("Key=\(.key),Value=\(.value|tostring)")|.[]' "$PARAMS_FILE" 2>/dev/null || true)

# Convenience values we’ll use later
PIPELINE_NAME=$(jq -r '.Parameters.PipelineName // empty' "$PARAMS_FILE")
ARTIFACT_BUCKET=$(jq -r '.Parameters.ArtifactBucketName // empty' "$PARAMS_FILE")
CONNECTION_ARN=$(jq -r '.Parameters.ConnectionArn // empty' "$PARAMS_FILE")

# ---------- quick preflight (nice-to-have checks) ----------
if [[ -n "$ARTIFACT_BUCKET" ]]; then
  echo ">> Checking artifact bucket exists: $ARTIFACT_BUCKET"
  if ! aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" $PROFILE 2>/dev/null; then
    echo "!! Warning: artifact bucket not found or not accessible: $ARTIFACT_BUCKET"
  fi
fi

if [[ -n "$CONNECTION_ARN" ]]; then
  echo ">> Checking CodeStar/CodeConnections status..."
  STATUS=$(aws codestar-connections get-connection --connection-arn "$CONNECTION_ARN" --query 'Connection.ConnectionStatus' --output text $PROFILE 2>/dev/null || echo "UNKNOWN")
  echo "Connection status: $STATUS"
  if [[ "$STATUS" != "AVAILABLE" ]]; then
    echo "!! Warning: Connection is not AVAILABLE. If PENDING, open AWS Console → Developer Tools → Connections and click Authorize/Update."
  fi
fi
echo

# ---------- deploy ----------
echo ">> Deploying stack $STACK_NAME ..."
set -x
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "${PARAM_OVERRIDES[@]}" \
  ${#TAG_OVERRIDES[@]}>/dev/null || true
set +x

# Tag handling: aws cfn deploy only supports --tags (not a list). Add if provided.
if [[ ${#TAG_OVERRIDES[@]} -gt 0 ]]; then
  # Re-run update with tags (no-op if already applied). We keep it separate for clarity.
  echo ">> Applying stack tags..."
  set -x
  aws cloudformation update-stack \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --use-previous-template \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters "${PARAM_OVERRIDES[@]/#/ParameterKey=}" \
                 "${PARAM_OVERRIDES[@]/#/ParameterValue=}" \
    --tags "${TAG_OVERRIDES[@]}" $PROFILE >/dev/null || true
  set +x
fi

echo ">> Waiting for stack to complete..."
aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$STACK_NAME" $PROFILE \
  || aws cloudformation wait stack-update-complete --region "$REGION" --stack-name "$STACK_NAME" $PROFILE

echo
echo "=== Stack outputs ==="
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" --output table $PROFILE || true
echo

# ---------- optionally kick the pipeline ----------
if $RUN_PIPELINE; then
  if [[ -z "$PIPELINE_NAME" || "$PIPELINE_NAME" == "null" ]]; then
    echo ">> Could not read PipelineName from params file; skipping start."
  else
    echo ">> Starting pipeline execution: $PIPELINE_NAME"
    aws codepipeline start-pipeline-execution --name "$PIPELINE_NAME" --region "$REGION" $PROFILE \
      --query 'pipelineExecutionId' --output text || true
  fi
fi

echo "Done."
