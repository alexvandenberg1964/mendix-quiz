#!/usr/bin/env bash
# =============================================================================
# deploy-frontend.sh
# Syncs the static site (index.html, admin-questions.html, feedback.html,
# stats.html) to S3 and invalidates the CloudFront cache so changes go live
# immediately.
#
# Usage:
#   chmod +x deploy-frontend.sh
#   ./deploy-frontend.sh
# =============================================================================

set -euo pipefail

PROFILE="sandbox-851725425406"
REGION="eu-west-1"
BUCKET="mendix-quiz-site"
DISTRIBUTION_ID="E3COCISNX8CY53"

echo "============================================="
echo " Frontend — Deploy"
echo " Bucket:       $BUCKET"
echo " Distribution: $DISTRIBUTION_ID"
echo "============================================="

echo ""
echo ">>> Uploading site files..."
for f in index.html admin-questions.html feedback.html stats.html; do
  aws s3 cp "$f" "s3://$BUCKET/$f" \
    --content-type "text/html" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --no-progress
  echo "  Uploaded $f"
done

echo ""
echo ">>> Invalidating CloudFront cache..."
aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --profile "$PROFILE" \
  --no-cli-pager > /dev/null
echo "  Invalidation submitted"

echo ""
echo "============================================="
echo " DONE"
echo " Site: https://d2dr4khbe5rg54.cloudfront.net"
echo " (Invalidation takes ~30-60s to fully propagate)"
echo "============================================="
