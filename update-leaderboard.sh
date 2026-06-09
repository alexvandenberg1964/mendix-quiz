#!/usr/bin/env bash
# Quick update: repackage and redeploy only the getLeaderboard Lambda code.
# Run this after changing lambda/getLeaderboard/index.mjs

set -euo pipefail

REGION="eu-west-1"
LAMBDA_NAME="quiz-getLeaderboard"
ZIP_PATH="lambda/getLeaderboard/quiz-getLeaderboard.zip"
AWS_PROFILE="sandbox-851725425406"

echo ">>> Checking AWS login..."
aws sts get-caller-identity --profile "$AWS_PROFILE" --query "Account" --output text > /dev/null \
  || { echo "Not logged in. Run: aws sso login --profile $AWS_PROFILE"; exit 1; }

echo ">>> Packaging..."
(cd lambda/getLeaderboard && zip -j quiz-getLeaderboard.zip index.mjs)
echo "  Created $ZIP_PATH"

echo ">>> Deploying to $LAMBDA_NAME..."
MSYS_NO_PATHCONV=1 aws lambda update-function-code \
  --function-name "$LAMBDA_NAME" \
  --zip-file "fileb://$ZIP_PATH" \
  --region "$REGION" \
  --profile "$AWS_PROFILE" \
  --no-cli-pager > /dev/null

echo ""
echo "Done! Lambda updated."
