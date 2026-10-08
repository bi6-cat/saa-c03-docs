#!/usr/bin/env bash
# Cleanup Lab 06 (KHÔNG xoá AWS Budget – đó là phần chuẩn bị dùng lâu dài)
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab06
DR_REGION="${DR_REGION:-ap-southeast-2}"
[ "$DR_REGION" = "$AWS_REGION" ] && DR_REGION=ap-southeast-1
SRC=$P-$ACCOUNT_ID-origin
DST=$P-$ACCOUNT_ID-dr
confirm "$P-* (CloudFront, bucket $SRC và $DST, role replication)"

echo "- CloudFront distribution (Disable → chờ Deployed → Delete; mất ~5–15 phút)..."
DID=$(aws cloudfront list-distributions --output json 2>/dev/null | jq -r --arg c "$P-cdn" '[(.DistributionList.Items // [])[] | select(.Comment==$c)][0].Id // ""')
if [ -n "$DID" ]; then
  CFG=$(aws cloudfront get-distribution-config --id "$DID" --output json)
  ETAG=$(echo "$CFG" | jq -r .ETag)
  if [ "$(echo "$CFG" | jq -r .DistributionConfig.Enabled)" = "true" ]; then
    tmp=$(mktemp)
    echo "$CFG" | jq '.DistributionConfig | .Enabled = false' > "$tmp"
    aws cloudfront update-distribution --id "$DID" --if-match "$ETAG" --distribution-config "file://$tmp" >/dev/null && echo "  đã Disable $DID"
    rm -f "$tmp"
  fi
  echo "  chờ distribution Deployed (có thể vài phút)..."
  aws cloudfront wait distribution-deployed --id "$DID"
  ETAG=$(aws cloudfront get-distribution-config --id "$DID" --query ETag --output text)
  aws cloudfront delete-distribution --id "$DID" --if-match "$ETAG" && echo "  đã xoá distribution $DID"
else
  echo "  (không thấy distribution $P-cdn – bỏ qua)"
fi

echo "- Origin Access Control..."
OACID=$(aws cloudfront list-origin-access-controls --output json 2>/dev/null | jq -r --arg n "$P-oac" '[(.OriginAccessControlList.Items // [])[] | select(.Name==$n)][0].Id // ""')
if [ -n "$OACID" ]; then
  del_oac() {
    local e
    e=$(aws cloudfront get-origin-access-control --id "$OACID" --query ETag --output text) || return 1
    aws cloudfront delete-origin-access-control --id "$OACID" --if-match "$e"
  }
  retry 6 del_oac && echo "  đã xoá OAC $OACID" || echo "  không xoá được OAC (còn distribution dùng?) – xoá tay trong Console: CloudFront → Origin access"
fi

echo "- Replication + bucket..."
ROLE_ARN=$(aws s3api get-bucket-replication --bucket "$SRC" --region "$AWS_REGION" --query ReplicationConfiguration.Role --output text 2>/dev/null | sed 's/^None$//')
aws s3api delete-bucket-replication --bucket "$SRC" --region "$AWS_REGION" >/dev/null 2>&1
empty_bucket "$SRC" "$AWS_REGION"
empty_bucket "$DST" "$DR_REGION"

echo "- IAM role replication (chỉ xoá nếu tên thuộc lab)..."
if [ -n "$ROLE_ARN" ]; then
  R=${ROLE_ARN##*/}
  case "$R" in
    s3crr_role_for_saa-lab06-*|saa-lab06-*)
      for arn in $(awsq iam list-attached-role-policies --role-name "$R" --query "AttachedPolicies[].PolicyArn"); do
        aws iam detach-role-policy --role-name "$R" --policy-arn "$arn"
        case "${arn##*/}" in *saa-lab06*) aws iam delete-policy --policy-arn "$arn" 2>/dev/null && echo "  đã xoá policy ${arn##*/}";; esac
      done
      for n in $(awsq iam list-role-policies --role-name "$R" --query "PolicyNames"); do
        aws iam delete-role-policy --role-name "$R" --policy-name "$n"
      done
      aws iam delete-role --role-name "$R" 2>/dev/null && echo "  đã xoá role $R"
      ;;
    *) echo "  role '$R' không mang tên lab – giữ nguyên, hãy tự kiểm tra." ;;
  esac
else
  echo "  (không có replication config / role – bỏ qua)"
fi
echo "Xong. AWS Budget được GIỮ LẠI có chủ đích."
