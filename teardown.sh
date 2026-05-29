#!/usr/bin/env bash
# =============================================================================
# teardown.sh — removes all quiz AWS resources
# Run this to clean up when you no longer need the quiz backend.
# =============================================================================

set -euo pipefail

REGION="eu-west-1"
ROLE_NAME="quiz-lambda-role"
POLICY_NAME="quiz-dynamo-policy"
API_NAME="quiz-api"

echo ">>> Deleting API Gateway..."
API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='$API_NAME'].ApiId" --output text 2>/dev/null || true)
if [ -n "$API_ID" ]; then
  aws apigatewayv2 delete-api --api-id "$API_ID" --region "$REGION"
  echo "  Deleted API $API_ID"
fi

echo ">>> Deleting Lambda functions..."
for FN in quiz-getQuestion quiz-saveAnswer quiz-saveFeedback; do
  aws lambda delete-function --function-name "$FN" --region "$REGION" 2>/dev/null && \
    echo "  Deleted $FN" || echo "  $FN not found, skipping"
done

echo ">>> Deleting IAM role..."
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" 2>/dev/null || true
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null && echo "  Deleted role" || echo "  Role not found"

echo ">>> Deleting DynamoDB tables..."
for TABLE in quiz-questions quiz-participants quiz-feedback; do
  aws dynamodb delete-table --table-name "$TABLE" --region "$REGION" 2>/dev/null && \
    echo "  Deleted $TABLE" || echo "  $TABLE not found, skipping"
done

echo ""
echo "All quiz resources removed."
