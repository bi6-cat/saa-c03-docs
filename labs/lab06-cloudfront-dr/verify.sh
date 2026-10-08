#!/usr/bin/env bash
# Verify Lab 06 – S3 + OAC + CloudFront origin group + CRR (DR) + Budget
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab06
DR_REGION="${DR_REGION:-ap-southeast-2}"
[ "$DR_REGION" = "$AWS_REGION" ] && DR_REGION=ap-southeast-1
SRC=$P-$ACCOUNT_ID-origin
DST=$P-$ACCOUNT_ID-dr
info "Origin: $SRC ($AWS_REGION) | DR: $DST ($DR_REGION)"

bucket_checks() { # <bucket> <region> <nhãn>
  local b=$1 r=$2 label=$3 pab
  if aws s3api head-bucket --bucket "$b" --region "$r" >/dev/null 2>&1; then
    pass "Có bucket $label $b ($r)"
  else
    fail "Không thấy bucket $label $b ở $r"; return 1
  fi
  check "$label: Versioning = Enabled" "$(awsq s3api get-bucket-versioning --bucket "$b" --region "$r" --query Status)" "Enabled"
  pab=$(aws s3api get-public-access-block --bucket "$b" --region "$r" --query PublicAccessBlockConfiguration --output json 2>/dev/null)
  [ -z "$pab" ] && pab='{}'
  check_true "$label: Block Public Access bật đủ 4 mục" "$(echo "$pab" | jq -r '[.BlockPublicAcls,.IgnorePublicAcls,.BlockPublicPolicy,.RestrictPublicBuckets] | all')"
}

section "1. Hai bucket"
SRC_OK=false; DST_OK=false
bucket_checks "$SRC" "$AWS_REGION" "origin" && SRC_OK=true
bucket_checks "$DST" "$DR_REGION" "DR" && DST_OK=true

section "2. Cross-Region Replication"
REPL_OK=false
if [ "$SRC_OK" = true ]; then
  REPL=$(aws s3api get-bucket-replication --bucket "$SRC" --region "$AWS_REGION" --output json 2>/dev/null)
  if [ -z "$REPL" ]; then
    fail "Bucket origin chưa có replication rule"
  else
    n=$(echo "$REPL" | jq --arg d "arn:aws:s3:::$DST" '[.ReplicationConfiguration.Rules[] | select(.Status=="Enabled" and .Destination.Bucket==$d)] | length')
    if [ "${n:-0}" -ge 1 ]; then pass "Có rule Enabled: $SRC → $DST"; REPL_OK=true; else fail "Không có rule Enabled nào trỏ tới bucket DR $DST"; fi
    dm=$(echo "$REPL" | jq -r '[.ReplicationConfiguration.Rules[] | select(.DeleteMarkerReplication.Status=="Enabled")] | length')
    if [ "${dm:-0}" -eq 0 ]; then pass "Delete marker replication đang TẮT (DR giữ bản khi origin bị xoá)"; else fail "Delete marker replication đang BẬT – tắt đi để DR còn dữ liệu khi origin bị xoá"; REPL_OK=false; fi
  fi
else
  warn "Bỏ qua: chưa có bucket origin"
fi

section "3. CloudFront distribution"
D=$(aws cloudfront list-distributions --output json 2>/dev/null | jq -c --arg c "$P-cdn" '[(.DistributionList.Items // [])[] | select(.Comment==$c)][0] // empty')
DID=""; DOMAIN=""; DSTATUS=""
if [ -z "$D" ]; then
  fail "Không thấy distribution có Description '$P-cdn'"
else
  DID=$(echo "$D" | jq -r .Id); DOMAIN=$(echo "$D" | jq -r .DomainName); DSTATUS=$(echo "$D" | jq -r .Status)
  pass "Có distribution $DID ($DOMAIN)"
  check "Status = Deployed" "$DSTATUS" "Deployed"
  check_true "Enabled" "$(echo "$D" | jq -r .Enabled)"
  check "Price class = PriceClass_100" "$(echo "$D" | jq -r .PriceClass)" "PriceClass_100"
  check "Default root object = index.html" "$(echo "$D" | jq -r '.DefaultRootObject')" "index.html"
  vpp=$(echo "$D" | jq -r '.DefaultCacheBehavior.ViewerProtocolPolicy')
  if [ "$vpp" = "redirect-to-https" ] || [ "$vpp" = "https-only" ]; then pass "Viewer chỉ dùng HTTPS ($vpp)"; else fail "Viewer protocol policy là '$vpp' – phải redirect-to-https hoặc https-only"; fi

  for b in "$SRC" "$DST"; do
    has=$(echo "$D" | jq -r --arg d "$b.s3." '[.Origins.Items[] | select(.DomainName|startswith($d))] | length')
    if [ "$has" = "0" ]; then
      fail "Distribution chưa có origin kiểu S3 bucket cho $b (không dùng static website endpoint)"
    else
      oac=$(echo "$D" | jq -r --arg d "$b.s3." '[.Origins.Items[] | select(.DomainName|startswith($d))][0].OriginAccessControlId // ""')
      if [ -n "$oac" ]; then pass "Origin $b dùng OAC ($oac)"; else fail "Origin $b chưa dùng OAC"; fi
    fi
  done

  OG=$(echo "$D" | jq -c '(.OriginGroups.Items // [])[0] // empty')
  if [ -z "$OG" ]; then
    fail "Chưa có origin group (primary = origin, secondary = DR)"
  else
    pass "Có origin group $(echo "$OG" | jq -r .Id)"
    dom() { echo "$D" | jq -r --arg id "$1" '[.Origins.Items[] | select(.Id==$id)][0].DomainName // ""'; }
    prim=$(dom "$(echo "$OG" | jq -r '.Members.Items[0].OriginId')")
    sec=$(dom "$(echo "$OG" | jq -r '.Members.Items[1].OriginId')")
    [[ "$prim" == "$SRC.s3."* ]] && pass "Primary origin = bucket origin" || fail "Primary origin phải là $SRC (hiện: '${prim:-<trống>}')"
    [[ "$sec" == "$DST.s3."* ]] && pass "Secondary origin = bucket DR" || fail "Secondary origin phải là $DST (hiện: '${sec:-<trống>}')"
    codes=$(echo "$OG" | jq -r '[.FailoverCriteria.StatusCodes.Items[]?] | map(tostring) | join(",")')
    if [[ ",$codes," == *",403,"* || ",$codes," == *",404,"* ]]; then pass "Failover bắt lỗi object thiếu (codes: $codes)"; else fail "Failover cần 403 và/hoặc 404 (OAC thiếu object thường trả 403). Hiện: '$codes'"; fi
    if [[ ",$codes," == *",500,"* || ",$codes," == *",502,"* || ",$codes," == *",503,"* || ",$codes," == *",504,"* ]]; then pass "Failover bắt lỗi 5xx của origin"; else fail "Failover chưa có mã 5xx (500/502/503/504)"; fi
    check "Default behavior trỏ tới origin group" "$(echo "$D" | jq -r '.DefaultCacheBehavior.TargetOriginId')" "$(echo "$OG" | jq -r .Id)"
  fi

  for pair in "$SRC:$AWS_REGION" "$DST:$DR_REGION"; do
    b=${pair%%:*}; r=${pair##*:}
    pol=$(awsq s3api get-bucket-policy --bucket "$b" --region "$r" --query Policy)
    if [ -n "$pol" ] && echo "$pol" | jq -e --arg a "arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DID" \
        '[.Statement] | flatten | .[] | select(.Effect=="Allow" and ((.Principal|type)=="object") and (.Principal.Service=="cloudfront.amazonaws.com") and ((.Condition.StringEquals["AWS:SourceArn"] // "")==$a))' >/dev/null 2>&1; then
      pass "Bucket policy $b chỉ cho CloudFront distribution $DID đọc"
    else
      fail "Bucket policy của $b chưa cho principal cloudfront.amazonaws.com với AWS:SourceArn của $DID"
    fi
  done
fi

section "4. Thử thật: upload, replicate, truy cập trực tiếp, failover"
if [ "$REPL_OK" = true ] && [ "$DST_OK" = true ] && [ -n "$DOMAIN" ] && [ "$DSTATUS" = "Deployed" ]; then
  TS=$(date +%s); K1=verify-$TS-direct.txt; K2=verify-$TS-failover.txt
  B1="saa-lab06 direct $TS"; B2="saa-lab06 failover $TS"
  F=$(mktemp); BODYF=$(mktemp); V1=""; V2=""; DM=""
  e2e_cleanup() {
    [ -n "$DM" ] && aws s3api delete-object --bucket "$SRC" --key "$K2" --version-id "$DM" --region "$AWS_REGION" >/dev/null 2>&1
    [ -n "$V1" ] && { aws s3api delete-object --bucket "$SRC" --key "$K1" --version-id "$V1" --region "$AWS_REGION" >/dev/null 2>&1
                      aws s3api delete-object --bucket "$DST" --key "$K1" --version-id "$V1" --region "$DR_REGION" >/dev/null 2>&1; }
    [ -n "$V2" ] && { aws s3api delete-object --bucket "$SRC" --key "$K2" --version-id "$V2" --region "$AWS_REGION" >/dev/null 2>&1
                      aws s3api delete-object --bucket "$DST" --key "$K2" --version-id "$V2" --region "$DR_REGION" >/dev/null 2>&1; }
    rm -f "$F" "$BODYF"
  }
  trap e2e_cleanup EXIT

  printf '%s' "$B1" > "$F"
  V1=$(awsq s3api put-object --bucket "$SRC" --key "$K1" --body "$F" --content-type text/plain --region "$AWS_REGION" --query VersionId)
  printf '%s' "$B2" > "$F"
  V2=$(awsq s3api put-object --bucket "$SRC" --key "$K2" --body "$F" --content-type text/plain --region "$AWS_REGION" --query VersionId)
  if [ -z "$V1" ] || [ -z "$V2" ]; then
    fail "Không ghi được object thử nghiệm vào $SRC (thiếu quyền?)"
  else
    info "Đã ghi $K1 và $K2 vào origin; chờ replicate sang DR (tối đa ~3 phút)..."
    ok1=false; ok2=false
    for _ in $(seq 1 18); do
      aws s3api head-object --bucket "$DST" --key "$K1" --region "$DR_REGION" >/dev/null 2>&1 && ok1=true
      aws s3api head-object --bucket "$DST" --key "$K2" --region "$DR_REGION" >/dev/null 2>&1 && ok2=true
      [ "$ok1" = true ] && [ "$ok2" = true ] && break
      sleep 10
    done
    if [ "$ok1" = true ] && [ "$ok2" = true ]; then
      pass "Object được replicate sang bucket DR ($DR_REGION)"
    else
      fail "Sau ~3 phút object chưa sang DR – xem Replication rule/role (hoặc chạy lại verify.sh nếu replicate chậm)"
    fi

    code=$(curl -s -o /dev/null -w '%{http_code}' "https://$SRC.s3.$AWS_REGION.amazonaws.com/$K1")
    check "Truy cập thẳng S3 (bỏ qua CloudFront) bị chặn" "$code" "403"

    cf_get() { # <key> -> in HTTP code, body vào $BODYF (thử lại vì có thể cần vài giây)
      local i c
      for i in 1 2 3; do
        c=$(curl -s -o "$BODYF" -w '%{http_code}' "https://$DOMAIN/$1")
        [ "$c" = "200" ] && break
        sleep 5
      done
      echo "$c"
    }
    code=$(cf_get "$K1")
    if [ "$code" = "200" ] && [ "$(cat "$BODYF")" = "$B1" ]; then pass "Qua CloudFront đọc được object (200, đúng nội dung)"; else fail "Qua CloudFront không đọc được $K1 (HTTP $code) – kiểm tra OAC + bucket policy + distribution đã Deployed"; fi

    # Xoá ở origin -> chỉ sinh delete marker (versioning) và marker KHÔNG sang DR -> CloudFront phải failover
    DM=$(awsq s3api delete-object --bucket "$SRC" --key "$K2" --region "$AWS_REGION" --query VersionId)
    info "Đã tạo delete marker cho $K2 ở origin; đọc qua CloudFront (chưa từng cache key này)"
    code=$(cf_get "$K2")
    if [ "$code" = "200" ] && [ "$(cat "$BODYF")" = "$B2" ]; then pass "Origin mất object → CloudFront failover sang DR (200, đúng nội dung)"; else fail "Failover chưa hoạt động (HTTP $code) – kiểm tra origin group, mã 403/404 và OAC/bucket policy của bucket DR"; fi
  fi
  e2e_cleanup; trap - EXIT
  info "Đã dọn object thử nghiệm."
else
  warn "Bỏ qua phần thử thật vì phần cấu hình ở trên chưa đạt (cần replication OK, bucket DR, distribution Deployed)"
fi

section "5. AWS Budget"
BJ=$(aws budgets describe-budgets --account-id "$ACCOUNT_ID" --region us-east-1 --output json 2>/dev/null)
[ -z "$BJ" ] && BJ='{}'
names=$(echo "$BJ" | jq -r '(.Budgets // [])[] | select(.BudgetType=="COST") | .BudgetName')
if [ -z "$names" ]; then
  fail "Chưa có Budget loại COST nào (Billing → Budgets → Create; nhớ đặt cảnh báo 50/80/100%)"
else
  pass "Có Budget loại COST"
  best=0
  while IFS= read -r nme; do
    c=$(awsq budgets describe-notifications-for-budget --account-id "$ACCOUNT_ID" --budget-name "$nme" --region us-east-1 --query "length(Notifications)")
    [ "${c:-0}" -gt "$best" ] && best=${c:-0}
  done <<< "$names"
  if [ "$best" -ge 3 ]; then pass "Budget có $best ngưỡng cảnh báo"; else warn "Budget chỉ có $best ngưỡng cảnh báo – nên có 3 (50/80/100%)"; fi
fi
warn "Hãy tự xác nhận Billing preferences → 'Receive Free Tier usage alerts' đã bật (CLI không kiểm tra được)"

summary
