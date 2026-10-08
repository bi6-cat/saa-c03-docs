#!/usr/bin/env bash
# Verify Lab 03 – S3 + DynamoDB   (thêm --advanced để chấm cả phần nâng cao)
source "$(dirname "$0")/../_common.sh"
preflight
B=saa-lab03-$ACCOUNT_ID
T=saa-lab03-orders
Q=saa-lab03-events
ADV=0; has_flag --advanced && ADV=1

section "A1. Bucket $B"
if ! aws s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
  fail "Không thấy bucket $B (kiểm tra tên và AWS_REGION)"
else
  pass "Bucket tồn tại"
  loc=$(awsq s3api get-bucket-location --bucket "$B" --query LocationConstraint)
  [ -z "$loc" ] && loc=us-east-1
  check "Bucket ở region $AWS_REGION" "$loc" "$AWS_REGION"

  check "Versioning = Enabled" "$(awsq s3api get-bucket-versioning --bucket "$B" --query Status)" "Enabled"

  enc=$(awsq s3api get-bucket-encryption --bucket "$B" \
        --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm")
  case "$enc" in AES256|aws:kms|aws:kms:dsse) pass "Default encryption = $enc" ;; *) fail "Chưa cấu hình default encryption (thực tế: '${enc:-<trống>}')" ;; esac

  pab=$(aws s3api get-public-access-block --bucket "$B" --output json 2>/dev/null |
        jq -r '.PublicAccessBlockConfiguration | (.BlockPublicAcls and .IgnorePublicAcls and .BlockPublicPolicy and .RestrictPublicBuckets)')
  check_true "Block Public Access bật đủ 4 tuỳ chọn" "$pab"

  lc=$(aws s3api get-bucket-lifecycle-configuration --bucket "$B" --output json 2>/dev/null)
  if [ -n "$lc" ]; then
    r=$(echo "$lc" | jq -r '[.Rules[] | select(.Status=="Enabled") | .Transitions[]? | select(.StorageClass=="STANDARD_IA" and .Days>=30)] | length >= 1')
    check_true "Lifecycle: chuyển sang STANDARD_IA sau ≥ 30 ngày" "$r"
    r=$(echo "$lc" | jq -r '[.Rules[] | select(.Status=="Enabled") | .NoncurrentVersionExpiration.NoncurrentDays? | select(. != null and . <= 90)] | length >= 1')
    check_true "Lifecycle: xoá noncurrent version sau ≤ 90 ngày" "$r"
    r=$(echo "$lc" | jq -r '[.Rules[] | select(.Status=="Enabled") | .AbortIncompleteMultipartUpload.DaysAfterInitiation? | select(. != null)] | length >= 1')
    [ "$r" = "true" ] && pass "Bonus: có abort incomplete multipart upload" || warn "BONUS: chưa có rule abort incomplete multipart upload"
  else
    fail "Chưa có lifecycle configuration"
  fi

  pol=$(awsq s3api get-bucket-policy --bucket "$B" --query Policy)
  if [ -n "$pol" ]; then
    r=$(echo "$pol" | jq -r '[.Statement] | flatten | [.[] | select(.Effect=="Deny" and ((.Condition.Bool."aws:SecureTransport" // "") == "false"))] | length >= 1')
    check_true "Bucket policy có Deny khi aws:SecureTransport=false" "$r"
  else
    fail "Chưa có bucket policy"
  fi

  section "A2. Kiểm tra chức năng (ghi object thử nghiệm vào prefix verify/, sẽ được dọn lại)"
  tmp=$(mktemp); echo "verify-$(date +%s)" > "$tmp"
  aws s3 cp "$tmp" "s3://$B/verify/test.txt" >/dev/null 2>&1 && \
  aws s3 cp "$tmp" "s3://$B/verify/test.txt" >/dev/null 2>&1
  nv=$(aws s3api list-object-versions --bucket "$B" --prefix verify/test.txt --output json 2>/dev/null | jq -r '.Versions | length')
  [ "${nv:-0}" -ge 2 ] && pass "Ghi 2 lần cùng key → $nv version (versioning hoạt động)" || fail "Không thấy ≥ 2 version của verify/test.txt"
  sse=$(awsq s3api head-object --bucket "$B" --key verify/test.txt --query ServerSideEncryption)
  [ -n "$sse" ] && pass "Object mới được mã hoá tự động ($sse)" || fail "Object không có ServerSideEncryption"

  # Request HTTP (không TLS) phải bị policy từ chối. Dùng get-object để lấy được thông điệp lỗi, và đòi đúng
  # AccessDenied (nếu là InvalidAccessKeyId/lỗi mạng thì KHÔNG tính là policy đã chặn).
  http_ep="${AWS_ENDPOINT_URL_S3:-${AWS_ENDPOINT_URL:-https://s3.$AWS_REGION.amazonaws.com}}"; http_ep="http://${http_ep#*://}"
  err=$(aws s3api get-object --bucket "$B" --key verify/test.txt --endpoint-url "$http_ep" /dev/null 2>&1)
  if [ $? -eq 0 ]; then
    fail "Request qua HTTP (không TLS) vẫn được chấp nhận → bucket policy chưa chặn"
  elif echo "$err" | grep -q 'AccessDenied'; then
    pass "Request qua HTTP (không TLS) bị policy từ chối (AccessDenied)"
  else
    fail "Request HTTP lỗi nhưng không phải AccessDenied của policy: $(echo "$err" | head -1)"
  fi
  delete_prefix "$B" "verify/"
  rm -f "$tmp"
fi

section "B1. DynamoDB table $T"
D=$(aws dynamodb describe-table --table-name "$T" --output json 2>/dev/null)
if [ -z "$D" ]; then
  fail "Không thấy bảng $T"
else
  pass "Bảng tồn tại"
  check "Partition key = customerId" "$(echo "$D" | jq -r '.Table.KeySchema[] | select(.KeyType=="HASH") | .AttributeName')" "customerId"
  check "Sort key = orderId" "$(echo "$D" | jq -r '.Table.KeySchema[] | select(.KeyType=="RANGE") | .AttributeName')" "orderId"
  check "Capacity mode = On-demand" "$(echo "$D" | jq -r '.Table.BillingModeSummary.BillingMode // "PROVISIONED"')" "PAY_PER_REQUEST"
  gsi=$(echo "$D" | jq -r '.Table.GlobalSecondaryIndexes[]? | select(.IndexName=="status-index") | [(.KeySchema[] | select(.KeyType=="HASH") | .AttributeName), (.KeySchema[] | select(.KeyType=="RANGE") | .AttributeName)] | join("/")')
  check "GSI status-index (HASH/RANGE)" "$gsi" "status/createdAt"
  ttl=$(aws dynamodb describe-time-to-live --table-name "$T" --output json 2>/dev/null)
  check "TTL status ENABLED" "$(echo "$ttl" | jq -r '.TimeToLiveDescription.TimeToLiveStatus')" "ENABLED"
  check "TTL attribute = expireAt" "$(echo "$ttl" | jq -r '.TimeToLiveDescription.AttributeName')" "expireAt"
  pitr=$(awsq dynamodb describe-continuous-backups --table-name "$T" --query "ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus")
  check "PITR = ENABLED" "$pitr" "ENABLED"

  section "B2. Kiểm tra chức năng (ghi 1 item thử nghiệm rồi xoá)"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if aws dynamodb put-item --table-name "$T" --item "{\"customerId\":{\"S\":\"verify\"},\"orderId\":{\"S\":\"v-$ts\"},\"status\":{\"S\":\"VERIFY\"},\"createdAt\":{\"S\":\"$ts\"},\"expireAt\":{\"N\":\"$(( $(date +%s) + 3600 ))\"}}" >/dev/null 2>&1; then
    pass "put-item thành công"
    n=$(awsq dynamodb query --table-name "$T" --key-condition-expression "customerId = :c" \
        --expression-attribute-values '{":c":{"S":"verify"}}' --query Count)
    [ "${n:-0}" -ge 1 ] && pass "Query theo partition key tìm thấy $n item" || fail "Query theo PK không thấy item"
    ok=0
    for _ in 1 2 3 4 5 6; do  # GSI là eventually consistent
      n=$(awsq dynamodb query --table-name "$T" --index-name status-index --key-condition-expression "#s = :s" \
          --expression-attribute-names '{"#s":"status"}' --expression-attribute-values '{":s":{"S":"VERIFY"}}' --query Count)
      [ "${n:-0}" -ge 1 ] && { ok=1; break; }
      sleep 2
    done
    [ $ok -eq 1 ] && pass "Query qua GSI status-index tìm thấy item" || fail "Query qua GSI không thấy item (GSI có thể chưa Active)"
    aws dynamodb delete-item --table-name "$T" --key "{\"customerId\":{\"S\":\"verify\"},\"orderId\":{\"S\":\"v-$ts\"}}" >/dev/null 2>&1
  else
    fail "put-item thất bại (kiểm tra tên attribute và quyền)"
  fi
fi

if [ $ADV -eq 1 ]; then
  echo; echo "######## PHẦN NÂNG CAO ########"

  section "A3. S3 nâng cao: ACL tắt, lifecycle dữ liệu lạnh, event notification, pre-signed URL"
  if aws s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
    check "Object Ownership = BucketOwnerEnforced (ACL bị vô hiệu)" \
      "$(awsq s3api get-bucket-ownership-controls --bucket "$B" --query "OwnershipControls.Rules[0].ObjectOwnership")" "BucketOwnerEnforced"

    r=$(echo "${lc:-{\}}" | jq -r '
      [.Rules[]? | select(.Status=="Enabled" and ((.Filter.Prefix // .Prefix // "")=="logs/"))
        | select([.Transitions[]? | select((.StorageClass=="GLACIER" or .StorageClass=="GLACIER_IR" or .StorageClass=="DEEP_ARCHIVE") and .Days>=90)] | length >= 1)
        | select((.Expiration.Days // 0) > ([.Transitions[]?.Days] | max // 0))] | length >= 1')
    check_true "Rule riêng cho prefix logs/: sang Glacier (≥ 90 ngày) rồi hết hạn (Expiration sau đó)" "$r"

    QURL=$(awsq sqs get-queue-url --queue-name $Q --query QueueUrl)
    NC=$(aws s3api get-bucket-notification-configuration --bucket "$B" --output json 2>/dev/null)
    r=$(echo "${NC:-{\}}" | jq -r '[.QueueConfigurations[]? | select((.Events|join(",")|test("ObjectCreated")) and ([.Filter.Key.FilterRules[]? | select((.Name|ascii_downcase)=="prefix" and .Value=="uploads/")] | length >= 1))] | length >= 1')
    check_true "S3 event notification: ObjectCreated trên prefix uploads/ → SQS" "$r"
    if [ -n "$QURL" ] && [ "$r" = "true" ]; then
      key="uploads/verify-$(date +%s).txt"
      echo hello > "$tmp" 2>/dev/null || tmp=$(mktemp)
      aws s3 cp "$tmp" "s3://$B/$key" >/dev/null 2>&1
      got=0
      for _ in 1 2 3 4 5 6; do
        msgs=$(aws sqs receive-message --queue-url "$QURL" --max-number-of-messages 10 --wait-time-seconds 5 --output json 2>/dev/null)
        [ -z "$msgs" ] && msgs='{}'
        while IFS= read -r h; do
          [ -n "$h" ] && aws sqs delete-message --queue-url "$QURL" --receipt-handle "$h" >/dev/null 2>&1
        done < <(echo "$msgs" | jq -r '.Messages[]?.ReceiptHandle')
        if echo "$msgs" | jq -e --arg k "$key" '[.Messages[]?.Body | fromjson? | .Records[]? | .s3.object.key | gsub("%2F";"/")] | index($k) != null' >/dev/null 2>&1; then got=1; break; fi
      done
      [ $got -eq 1 ] && pass "Upload $key → có message sự kiện trong $Q" || fail "Không nhận được message sự kiện cho $key (kiểm tra queue policy cho s3.amazonaws.com + aws:SourceArn)"
      delete_prefix "$B" "uploads/verify-"
    elif [ -z "$QURL" ]; then
      fail "Không thấy SQS queue $Q"
    fi

    # Pre-signed URL: có chữ ký → 200; bỏ chữ ký → 403
    echo "presign-$(date +%s)" > "$tmp"; body=$(cat "$tmp")
    aws s3 cp "$tmp" "s3://$B/verify/presign.txt" >/dev/null 2>&1
    url=$(aws s3 presign "s3://$B/verify/presign.txt" --expires-in 60 2>/dev/null)
    if [ -n "$url" ]; then
      got=$(curl -s -m 15 "$url")
      [ "$got" = "$body" ] && pass "Pre-signed URL tải được object (không cần credential)" || fail "Pre-signed URL không tải được object (nhận: '${got:0:60}')"
      code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${url%%\?*}")
      check "URL không có chữ ký bị từ chối" "$code" "403"
    else
      fail "Không tạo được pre-signed URL"
    fi
    delete_prefix "$B" "verify/"
    rm -f "$tmp"
  else
    fail "Bỏ qua phần S3 nâng cao vì thiếu bucket $B"
  fi

  section "B3. DynamoDB nâng cao: Streams, điều kiện ghi, transaction"
  if [ -n "$D" ]; then
    check_true "Streams bật" "$(echo "$D" | jq -r '.Table.StreamSpecification.StreamEnabled // false')"
    check "Stream view type = NEW_AND_OLD_IMAGES" "$(echo "$D" | jq -r '.Table.StreamSpecification.StreamViewType // ""')" "NEW_AND_OLD_IMAGES"

    ts=$(date +%s); cid="verify-adv"
    k1="{\"customerId\":{\"S\":\"$cid\"},\"orderId\":{\"S\":\"cond-$ts\"}}"
    it1="{\"customerId\":{\"S\":\"$cid\"},\"orderId\":{\"S\":\"cond-$ts\"},\"status\":{\"S\":\"NEW\"},\"createdAt\":{\"S\":\"$ts\"}}"
    aws dynamodb put-item --table-name "$T" --item "$it1" --condition-expression "attribute_not_exists(orderId)" >/dev/null 2>&1 \
      && pass "Ghi có điều kiện attribute_not_exists lần 1 thành công" || fail "Ghi có điều kiện lần 1 thất bại"
    err=$(aws dynamodb put-item --table-name "$T" --item "$it1" --condition-expression "attribute_not_exists(orderId)" 2>&1)
    echo "$err" | grep -q 'ConditionalCheckFailed' && pass "Ghi trùng khoá bị ConditionalCheckFailedException (idempotent)" || fail "Ghi trùng khoá lẽ ra phải bị từ chối bởi điều kiện"

    ta="{\"customerId\":{\"S\":\"$cid\"},\"orderId\":{\"S\":\"tx-a-$ts\"},\"status\":{\"S\":\"NEW\"},\"createdAt\":{\"S\":\"$ts\"}}"
    tb="{\"customerId\":{\"S\":\"$cid\"},\"orderId\":{\"S\":\"tx-b-$ts\"},\"status\":{\"S\":\"NEW\"},\"createdAt\":{\"S\":\"$ts\"}}"
    items=$(jq -nc --arg t "$T" --argjson a "$ta" --argjson b "$tb" '[{Put:{TableName:$t,Item:$a}},{Put:{TableName:$t,Item:$b,ConditionExpression:"attribute_exists(orderId)"}}]')
    err=$(aws dynamodb transact-write-items --transact-items "$items" 2>&1)
    if echo "$err" | grep -q 'TransactionCanceled'; then
      pass "Transaction bị huỷ vì một điều kiện sai"
      left=$(awsq dynamodb get-item --table-name "$T" --key "{\"customerId\":{\"S\":\"$cid\"},\"orderId\":{\"S\":\"tx-a-$ts\"}}" --query "Item.orderId.S")
      [ -z "$left" ] && pass "Tính nguyên tử: item A cũng KHÔNG được ghi (all-or-nothing)" || fail "Item A vẫn được ghi dù transaction bị huỷ"
    else
      fail "Transaction lẽ ra phải bị huỷ (TransactionCanceledException). Nhận: $(echo "$err" | head -1)"
    fi
    aws dynamodb delete-item --table-name "$T" --key "$k1" >/dev/null 2>&1
    aws dynamodb delete-item --table-name "$T" --key "{\"customerId\":{\"S\":\"$cid\"},\"orderId\":{\"S\":\"tx-a-$ts\"}}" >/dev/null 2>&1
  else
    fail "Bỏ qua phần DynamoDB nâng cao vì thiếu bảng $T"
  fi
else
  echo; info "Chạy 'bash verify.sh --advanced' để chấm thêm phần nâng cao (S3 event/presign/lifecycle lạnh, DynamoDB Streams/transaction)."
fi

summary
