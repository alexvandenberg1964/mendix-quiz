#!/usr/bin/env bash
# =============================================================================
# deploy.sh — PostNL Daily Quiz — Full AWS CLI setup
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (aws configure)
#   - Node.js 22+ (for bundling the Lambda packages)
#   - jq (brew install jq  /  apt install jq)
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# To tear everything down afterwards:
#   ./teardown.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — edit these if needed
# ---------------------------------------------------------------------------
REGION="eu-west-1"          # Frankfurt — closest to PostNL
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="quiz-lambda-role"
POLICY_NAME="quiz-dynamo-policy"

TABLE_QUESTIONS="quiz-questions"
TABLE_PARTICIPANTS="quiz-participants"
TABLE_FEEDBACK="quiz-feedback"

LAMBDA_GET="quiz-getQuestion"
LAMBDA_ANSWER="quiz-saveAnswer"
LAMBDA_FEEDBACK="quiz-saveFeedback"

API_NAME="quiz-api"

echo "============================================="
echo " PostNL Daily Quiz — AWS Deploy"
echo " Region:     $REGION"
echo " Account ID: $ACCOUNT_ID"
echo "============================================="
echo ""

# ---------------------------------------------------------------------------
# STEP 1 — DynamoDB tables
# ---------------------------------------------------------------------------
echo ">>> [1/6] Creating DynamoDB tables..."

aws dynamodb create-table \
  --table-name "$TABLE_QUESTIONS" \
  --attribute-definitions AttributeName=questionId,AttributeType=S \
  --key-schema AttributeName=questionId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" \
  --no-cli-pager 2>/dev/null || echo "  (quiz-questions already exists, skipping)"

aws dynamodb create-table \
  --table-name "$TABLE_PARTICIPANTS" \
  --attribute-definitions \
    AttributeName=email,AttributeType=S \
    AttributeName=date,AttributeType=S \
  --key-schema \
    AttributeName=email,KeyType=HASH \
    AttributeName=date,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" \
  --no-cli-pager 2>/dev/null || echo "  (quiz-participants already exists, skipping)"

aws dynamodb create-table \
  --table-name "$TABLE_FEEDBACK" \
  --attribute-definitions \
    AttributeName=feedbackId,AttributeType=S \
    AttributeName=questionId,AttributeType=S \
  --key-schema \
    AttributeName=feedbackId,KeyType=HASH \
    AttributeName=questionId,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" \
  --no-cli-pager 2>/dev/null || echo "  (quiz-feedback already exists, skipping)"

echo "  Waiting for tables to become ACTIVE..."
aws dynamodb wait table-exists --table-name "$TABLE_QUESTIONS" --region "$REGION"
aws dynamodb wait table-exists --table-name "$TABLE_PARTICIPANTS" --region "$REGION"
aws dynamodb wait table-exists --table-name "$TABLE_FEEDBACK" --region "$REGION"
echo "  Tables ready."

# ---------------------------------------------------------------------------
# STEP 2 — IAM role and policy
# ---------------------------------------------------------------------------
echo ""
echo ">>> [2/6] Creating IAM role and attaching policy..."

# Substitute actual REGION and ACCOUNT_ID into the policy document
sed "s/REGION/$REGION/g; s/ACCOUNT_ID/$ACCOUNT_ID/g" iam-dynamo-policy.json > /tmp/quiz-dynamo-policy.json

# Create the Lambda execution role (ignore error if it already exists)
ROLE_ARN=$(aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://iam-trust-policy.json \
  --query "Role.Arn" \
  --output text 2>/dev/null) || \
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.Arn" --output text)

echo "  Role ARN: $ROLE_ARN"

# Attach managed CloudWatch Logs policy
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
  2>/dev/null || true

# Put inline DynamoDB policy
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file://iam-dynamo-policy.json

echo "  Waiting 10s for IAM role propagation..."
sleep 10

# ---------------------------------------------------------------------------
# STEP 3 — Bundle Lambda functions as zip packages
# ---------------------------------------------------------------------------
echo ""
echo ">>> [3/6] Bundling Lambda function packages..."

for FN in getQuestion saveAnswer saveFeedback; do
  echo "  Bundling $FN..."
  cd "lambda/$FN"
  # Create a minimal package.json so Node.js treats this as an ES module
  cat > package.json <<'PKGJSON'
{ "type": "module" }
PKGJSON
  zip -q -r "/tmp/quiz-${FN}.zip" .
  cd ../..
  echo "  Created /tmp/quiz-${FN}.zip"
done

# ---------------------------------------------------------------------------
# STEP 4 — Deploy Lambda functions
# ---------------------------------------------------------------------------
echo ""
echo ">>> [4/6] Deploying Lambda functions..."

ENV_VARS="Variables={QUESTIONS_TABLE=$TABLE_QUESTIONS,PARTICIPANTS_TABLE=$TABLE_PARTICIPANTS,FEEDBACK_TABLE=$TABLE_FEEDBACK}"

deploy_lambda() {
  local NAME=$1
  local HANDLER=$2
  local ZIP=$3

  # Try update first; if it doesn't exist, create it
  if aws lambda update-function-code \
    --function-name "$NAME" \
    --zip-file "fileb://$ZIP" \
    --region "$REGION" \
    --no-cli-pager &>/dev/null; then

    aws lambda update-function-configuration \
      --function-name "$NAME" \
      --environment "$ENV_VARS" \
      --region "$REGION" \
      --no-cli-pager > /dev/null
    echo "  Updated $NAME"
  else
    aws lambda create-function \
      --function-name "$NAME" \
      --runtime nodejs22.x \
      --role "$ROLE_ARN" \
      --handler "$HANDLER" \
      --zip-file "fileb://$ZIP" \
      --environment "$ENV_VARS" \
      --timeout 15 \
      --memory-size 256 \
      --region "$REGION" \
      --no-cli-pager > /dev/null
    echo "  Created $NAME"
  fi
}

deploy_lambda "$LAMBDA_GET"      "index.handler" "quiz-getQuestion.zip"
deploy_lambda "$LAMBDA_ANSWER"   "index.handler" "quiz-saveAnswer.zip"
deploy_lambda "$LAMBDA_FEEDBACK" "index.handler" "quiz-saveFeedback.zip"

echo "  Waiting for functions to be Active..."
aws lambda wait function-active --function-name "$LAMBDA_GET"      --region "$REGION"
aws lambda wait function-active --function-name "$LAMBDA_ANSWER"   --region "$REGION"
aws lambda wait function-active --function-name "$LAMBDA_FEEDBACK" --region "$REGION"

# Retrieve Lambda ARNs
ARN_GET=$(aws lambda get-function --function-name "$LAMBDA_GET" --region "$REGION" --query "Configuration.FunctionArn" --output text)
ARN_ANSWER=$(aws lambda get-function --function-name "$LAMBDA_ANSWER" --region "$REGION" --query "Configuration.FunctionArn" --output text)
ARN_FEEDBACK=$(aws lambda get-function --function-name "$LAMBDA_FEEDBACK" --region "$REGION" --query "Configuration.FunctionArn" --output text)

# ---------------------------------------------------------------------------
# STEP 5 — API Gateway (HTTP API)
# ---------------------------------------------------------------------------
echo ""
echo ">>> [5/6] Creating API Gateway HTTP API..."

# Create the HTTP API
API_ID=$(aws apigatewayv2 create-api \
  --name "$API_NAME" \
  --protocol-type HTTP \
  --cors-configuration \
    AllowOrigins="*",AllowMethods="GET,POST,OPTIONS",AllowHeaders="Content-Type" \
  --region "$REGION" \
  --query "ApiId" \
  --output text)

echo "  API ID: $API_ID"

# Helper: create integration and return its ID
create_integration() {
  local LAMBDA_ARN=$1
  aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
    --payload-format-version "2.0" \
    --region "$REGION" \
    --query "IntegrationId" \
    --output text
}

INT_GET=$(create_integration "$ARN_GET")
INT_ANSWER=$(create_integration "$ARN_ANSWER")
INT_FEEDBACK=$(create_integration "$ARN_FEEDBACK")

echo "  Creating routes..."
aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "GET /question" \
  --target "integrations/$INT_GET" \
  --region "$REGION" --no-cli-pager > /dev/null

aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "POST /answer" \
  --target "integrations/$INT_ANSWER" \
  --region "$REGION" --no-cli-pager > /dev/null

aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "POST /feedback" \
  --target "integrations/$INT_FEEDBACK" \
  --region "$REGION" --no-cli-pager > /dev/null

echo "  Creating stage and auto-deploying..."
aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name "prod" \
  --auto-deploy \
  --region "$REGION" --no-cli-pager > /dev/null

# Grant API Gateway permission to invoke each Lambda
grant_invoke() {
  local LAMBDA_NAME=$1
  local STATEMENT_ID=$2
  aws lambda add-permission \
    --function-name "$LAMBDA_NAME" \
    --statement-id "$STATEMENT_ID" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
    --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
}

grant_invoke "$LAMBDA_GET"      "apigw-get-question"
grant_invoke "$LAMBDA_ANSWER"   "apigw-save-answer"
grant_invoke "$LAMBDA_FEEDBACK" "apigw-save-feedback"

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"

# ---------------------------------------------------------------------------
# STEP 6 — Seed a sample question
# ---------------------------------------------------------------------------
echo ""
echo ">>> [6/6] Seeding sample questions..."

seed_question() {
  local ID=$1
  local CATEGORY=$2
  local TEXT=$3
  local OPTIONS=$4
  local CORRECT=$5
  local EXPLANATION=$6
  local DIFFICULTY=$7

  aws dynamodb put-item \
    --table-name "$TABLE_QUESTIONS" \
    --item "{
      \"questionId\": {\"S\": \"$ID\"},
      \"category\":   {\"S\": \"$CATEGORY\"},
      \"text\":       {\"S\": \"$TEXT\"},
      \"options\":    {\"L\": $OPTIONS},
      \"correctIndex\":{\"N\": \"$CORRECT\"},
      \"explanation\": {\"S\": \"$EXPLANATION\"},
      \"difficulty\":  {\"S\": \"$DIFFICULTY\"},
      \"active\":      {\"BOOL\": true}
    }" \
    --region "$REGION" \
    --no-cli-pager
}

seed_question "q001" \
  "Domain Modeling" \
  "What is the maximum inheritance depth recommended in a Mendix domain model?" \
  '[{"S":"1"},{"S":"2"},{"S":"3"},{"S":"5"}]' \
  2 \
  "Mendix recommends a maximum of 3 levels of inheritance to keep the domain model navigable and maintainable." \
  "medium"

seed_question "q002" \
  "Microflows" \
  "Which activity should you use to iterate over a list of objects in a microflow?" \
  '[{"S":"Loop"},{"S":"For Each"},{"S":"Iterate List"},{"S":"List Comprehension"}]' \
  1 \
  "The For Each activity in Mendix microflows is the correct way to iterate over a list of objects." \
  "easy"

seed_question "q003" \
  "Security" \
  "At which level does Mendix enforce entity access rules by default?" \
  '[{"S":"Module level"},{"S":"Page level"},{"S":"Entity level"},{"S":"Microflow level"}]' \
  2 \
  "Access rules are defined at the entity level in Mendix, controlling which user roles can read, write, or create objects." \
  "medium"

echo "  3 sample questions seeded."

# ---------------------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
echo " DEPLOYMENT COMPLETE"
echo "============================================="
echo ""
echo " API endpoint:"
echo "   $API_ENDPOINT"
echo ""
echo " Routes:"
echo "   GET  $API_ENDPOINT/question?email=you@postnl.nl"
echo "   POST $API_ENDPOINT/answer"
echo "   POST $API_ENDPOINT/feedback"
echo ""
echo " Quick smoke test:"
echo "   curl \"$API_ENDPOINT/question?email=test@postnl.nl\" | jq ."
echo ""
echo " Add this to your quiz HTML:"
echo "   const API = \"$API_ENDPOINT\";"
echo ""

# Save the endpoint to a file for easy reference
echo "$API_ENDPOINT" > .api-endpoint
echo " Endpoint saved to .api-endpoint"
echo "============================================="
