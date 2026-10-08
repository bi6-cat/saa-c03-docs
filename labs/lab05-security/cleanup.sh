#!/usr/bin/env bash
# Cleanup Lab 05
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab05
confirm "$P-*"

echo "- CloudTrail..."
BK=$(awsq cloudtrail describe-trails --trail-name-list $P-trail --query "trailList[0].S3BucketName")
aws cloudtrail delete-trail --name $P-trail 2>/dev/null && echo "  đã xoá trail"
if [ -n "$BK" ]; then
  echo "  Bucket log: $BK"
  read -r -p "  Xoá luôn bucket log này (và toàn bộ log trong đó)? [y/N] " a
  [ "$a" = "y" ] && empty_bucket "$BK"
fi

echo "- Secrets Manager (xoá ngay, không chờ recovery window)..."
aws secretsmanager delete-secret --secret-id $P/db-credentials --force-delete-without-recovery >/dev/null 2>&1 && echo "  đã xoá secret"

echo "- IAM role..."
R=$P-app-role
for arn in $(awsq iam list-attached-role-policies --role-name $R --query "AttachedPolicies[].PolicyArn"); do
  aws iam detach-role-policy --role-name $R --policy-arn "$arn"
done
for n in $(awsq iam list-role-policies --role-name $R --query "PolicyNames"); do
  aws iam delete-role-policy --role-name $R --policy-name "$n"
done
aws iam delete-role --role-name $R 2>/dev/null && echo "  đã xoá role"

echo "- KMS key (không xoá ngay được: tối thiểu 7 ngày chờ)..."
KID=$(awsq kms describe-key --key-id alias/$P-key --query KeyMetadata.KeyId)
if [ -n "$KID" ]; then
  aws kms delete-alias --alias-name alias/$P-key
  aws kms schedule-key-deletion --key-id "$KID" --pending-window-in-days 7 >/dev/null && echo "  đã lên lịch xoá key $KID sau 7 ngày (kiểm tra Billing để chắc chắn không còn tính phí key)"
fi
echo "Xong."
