#!/usr/bin/env bash
# =============================================================================
# deploy-leaderboard.sh
# Adds the getLeaderboard Lambda + GET /leaderboard route to the existing setup.
#
# Usage:
#   chmod +x deploy-leaderboard.sh
#   ./deploy-leaderboard.sh
# =============================================================================

set -euo pipefail

REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="quiz-lambda-role"
LAMBDA_NAME="quiz-getLeaderboard"
API_NAME="quiz-api"

TABLE_PARTICIPANTS="quiz-participants"

echo "============================================="
echo " Leaderboard — Deploy"
echo " Region:  $REGION"
#echo " Account: $ACCOUNT_ID"
echo "============================================="

# Get existing role ARN
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.Arn" --output text)
echo "Using role: $ROLE_ARN"

# Package
echo ""
echo ">>> Packaging Lambda..."
cd lambda/getLeaderboard
zip -j quiz-getLeaderboard.zip index.mjs
cd ../..
echo "  Created lambda/getLeaderboard/quiz-getLeaderboard.zip"

# Deploy Lambda
echo ""
echo ">>> Deploying Lambda..."
ENV_VARS="Variables={PARTICIPANTS_TABLE=$TABLE_PARTICIPANTS}"

ZIP_PATH="lambda/getLeaderboard/quiz-getLeaderboard.zip"

if MSYS_NO_PATHCONV=1 aws lambda update-function-code \
  --function-name "$LAMBDA_NAME" \
  --zip-file "fileb://$ZIP_PATH" \
  --region "$REGION" \
  --no-cli-pager &>/dev/null; then

  MSYS_NO_PATHCONV=1 aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --environment "$ENV_VARS" \
    --region "$REGION" \
    --no-cli-pager > /dev/null
  echo "  Updated $LAMBDA_NAME"
else
  MSYS_NO_PATHCONV=1 aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime nodejs22.x \
    --role "$ROLE_ARN" \
    --handler index.handler \
    --zip-file "fileb://$ZIP_PATH" \
    --environment "$ENV_VARS" \
    --timeout 15 \
    --memory-size 256 \
    --region "$REGION" \
    --no-cli-pager > /dev/null
  echo "  Created $LAMBDA_NAME"
fi

MSYS_NO_PATHCONV=1 aws lambda wait function-active \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION"

ARN_LB=$(aws lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" \
  --query "Configuration.FunctionArn" \
  --output text)

# Add route to existing API Gateway
echo ""
echo ">>> Adding GET /leaderboard route to API Gateway..."

API_ID=$(aws apigatewayv2 get-apis \
  --region "$REGION" \
  --query "Items[?Name=='$API_NAME'].ApiId" \
  --output text)

if [ -z "$API_ID" ]; then
  echo "ERROR: Could not find API named '$API_NAME' in $REGION"
  exit 1
fi
echo "  API ID: $API_ID"

# Create integration
INT_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${ARN_LB}/invocations" \
  --payload-format-version "2.0" \
  --region "$REGION" \
  --query "IntegrationId" \
  --output text)

# Create route
aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "GET /leaderboard" \
  --target "integrations/$INT_ID" \
  --region "$REGION" \
  --no-cli-pager > /dev/null

# Grant API Gateway invoke permission
MSYS_NO_PATHCONV=1 aws lambda add-permission \
  --function-name "$LAMBDA_NAME" \
  --statement-id "apigw-leaderboard" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
  --region "$REGION" \
  --no-cli-pager > /dev/null 2>&1 || true

# Redeploy stage
aws apigatewayv2 create-deployment \
  --api-id "$API_ID" \
  --stage-name prod \
  --region "$REGION" \
  --no-cli-pager > /dev/null

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"

echo ""
echo "============================================="
echo " DONE"
echo " New route: GET $API_ENDPOINT/leaderboard"
echo ""
echo " Quick test:"
echo "   curl \"$API_ENDPOINT/leaderboard\" | python3 -m json.tool"
echo "============================================="
