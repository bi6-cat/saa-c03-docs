#!/usr/bin/env bash
# Verify Lab 05 – KMS, Secrets Manager, IAM least privilege, CloudTrail
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab05
SECRET=$P/db-credentials
ROLE=$P-app-role

section "1. KMS customer managed key"
K=$(aws kms describe-key --key-id alias/$P-key --output json 2>/dev/null)
KEYID=""; KEYARN=""
if [ -n "$K" ]; then
  KEYID=$(echo "$K" | jq -r '.KeyMetadata.KeyId'); KEYARN=$(echo "$K" | jq -r '.KeyMetadata.Arn')
  pass "Có key alias/$P-key ($KEYID)"
  check "KeyManager = CUSTOMER" "$(echo "$K" | jq -r '.KeyMetadata.KeyManager')" "CUSTOMER"
  check "KeyState = Enabled" "$(echo "$K" | jq -r '.KeyMetadata.KeyState')" "Enabled"
  check "Key đối xứng (SYMMETRIC_DEFAULT)" "$(echo "$K" | jq -r '.KeyMetadata.KeySpec')" "SYMMETRIC_DEFAULT"
  check "Key rotation bật" "$(awsq kms get-key-rotation-status --key-id "$KEYID" --query KeyRotationEnabled)" "True"
else
  fail "Không thấy KMS alias/$P-key"
fi

section "2. Secrets Manager"
S=$(aws secretsmanager describe-secret --secret-id "$SECRET" --output json 2>/dev/null)
if [ -n "$S" ]; then
  pass "Có secret $SECRET"
  skms=$(echo "$S" | jq -r '.KmsKeyId // ""')
  if [ -n "$skms" ] && [ -n "$KEYID" ] && { [[ "$skms" == *"$KEYID"* ]] || [ "$skms" = "alias/$P-key" ]; }; then
    pass "Secret được mã hoá bằng CMK $P-key"
  else
    fail "Secret chưa dùng CMK $P-key (KmsKeyId: '${skms:-aws/secretsmanager mặc định}')"
  fi
  SECRET_ARN=$(echo "$S" | jq -r '.ARN')
else
  fail "Không thấy secret $SECRET"
fi

section "3. IAM role least privilege"
ROLE_ARN=$(awsq iam get-role --role-name $ROLE --query Role.Arn)
if [ -z "$ROLE_ARN" ]; then
  fail "Không thấy role $ROLE"
else
  pass "Có role $ROLE"
  n=$(awsq iam list-attached-role-policies --role-name $ROLE --query "length(AttachedPolicies)")
  [ "${n:-0}" = "0" ] && pass "Role không gắn managed policy rộng" || warn "Role có $n managed policy gắn kèm – lab yêu cầu chỉ inline policy hẹp"

  sim() { # sim <action> <resource-arn> -> allowed|implicitDeny|explicitDeny
    awsq iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" --action-names "$1" --resource-arns "$2" --query "EvaluationResults[0].EvalDecision"
  }
  if [ -n "${SECRET_ARN:-}" ]; then
    check "Mô phỏng: GetSecretValue trên secret của lab → allowed" "$(sim secretsmanager:GetSecretValue "$SECRET_ARN")" "allowed"
  fi
  other="arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:other/not-this-one-AbCdEf"
  check "Mô phỏng: GetSecretValue trên secret KHÁC → bị từ chối" "$(sim secretsmanager:GetSecretValue "$other")" "implicitDeny"
  if [ -n "$KEYARN" ]; then
    check "Mô phỏng: kms:Decrypt trên key của lab → allowed" "$(sim kms:Decrypt "$KEYARN")" "allowed"
  fi
  check "Mô phỏng: s3:GetObject trên bucket bất kỳ → bị từ chối" "$(sim s3:GetObject "arn:aws:s3:::any-bucket/*")" "implicitDeny"
  check "Mô phỏng: iam:CreateUser → bị từ chối" "$(sim iam:CreateUser "*")" "implicitDeny"

  section "4. Thử thật: assume-role rồi gọi API"
  CREDS=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name $P-verify --duration-seconds 900 --output json 2>/dev/null)
  if [ -z "$CREDS" ]; then
    fail "Không assume được role (kiểm tra trust policy tin cậy account của bạn; không dùng root user)"
  else
    as_role() {
      env AWS_ACCESS_KEY_ID="$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)" \
          AWS_SECRET_ACCESS_KEY="$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)" \
          AWS_SESSION_TOKEN="$(echo "$CREDS" | jq -r .Credentials.SessionToken)" \
          -u AWS_PROFILE "$@"
    }
    if as_role aws secretsmanager get-secret-value --secret-id "$SECRET" --query Name --output text >/dev/null 2>&1; then
      pass "Role đọc được secret $SECRET (đã giải mã qua KMS)"
    else
      fail "Role KHÔNG đọc được secret (thiếu GetSecretValue hoặc kms:Decrypt? chờ vài giây để IAM lan truyền rồi chạy lại)"
    fi
    if as_role aws s3 ls >/dev/null 2>&1; then fail "Role liệt kê được S3 – quyền quá rộng"; else pass "Role KHÔNG liệt kê được S3 (AccessDenied)"; fi
    if as_role aws secretsmanager list-secrets >/dev/null 2>&1; then fail "Role liệt kê được mọi secret – quyền quá rộng"; else pass "Role KHÔNG liệt kê được danh sách secret"; fi
  fi
fi

section "5. CloudTrail"
TR=$(aws cloudtrail describe-trails --trail-name-list $P-trail --output json 2>/dev/null | jq -c '.trailList[0] // empty')
if [ -n "$TR" ]; then
  pass "Có trail $P-trail"
  check_true "Trail đa Region (IsMultiRegionTrail)" "$(echo "$TR" | jq -r '.IsMultiRegionTrail')"
  check_true "Log file validation bật" "$(echo "$TR" | jq -r '.LogFileValidationEnabled')"
  check "Trail đang ghi log" "$(awsq cloudtrail get-trail-status --name $P-trail --query IsLogging)" "True"
  bk=$(echo "$TR" | jq -r '.S3BucketName')
  aws s3api head-bucket --bucket "$bk" >/dev/null 2>&1 && pass "Bucket log tồn tại ($bk)" || fail "Không truy cập được bucket log $bk"
  last=$(awsq cloudtrail get-trail-status --name $P-trail --query LatestDeliveryTime)
  [ -n "$last" ] && pass "Trail đã giao log lần cuối: $last" || warn "Chưa có log nào được giao (có thể cần chờ ~5–15 phút sau khi tạo)"
else
  fail "Không thấy trail $P-trail (kiểm tra AWS_REGION là home region của trail)"
fi

summary
