#!/usr/bin/env bash
# Verify Lab 04 – SNS → SQS → Lambda → DynamoDB
#   --dlq        thêm bài thử poison message → DLQ (chậm, ~3–6 phút)
#   --advanced   chấm thêm phần nâng cao (filter policy, alarm DLQ, FIFO, concurrency, EventBridge)
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab04
RUN_DLQ=0; has_flag --dlq && RUN_DLQ=1
ADV=0; has_flag --advanced && ADV=1

section "1. DynamoDB"
check "Bảng $P-orders có PK orderId" \
  "$(awsq dynamodb describe-table --table-name $P-orders --query "Table.KeySchema[?KeyType=='HASH'].AttributeName")" "orderId"

section "2. SQS queue & DLQ"
QURL=$(awsq sqs get-queue-url --queue-name $P-queue --query QueueUrl)
DURL=$(awsq sqs get-queue-url --queue-name $P-dlq --query QueueUrl)
QARN=""; DARN=""
if [ -n "$QURL" ] && [ -n "$DURL" ]; then
  pass "Có queue $P-queue và DLQ $P-dlq"
  QA=$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names All --output json)
  DARN=$(aws sqs get-queue-attributes --queue-url "$DURL" --attribute-names QueueArn --query Attributes.QueueArn --output text)
  QARN=$(echo "$QA" | jq -r '.Attributes.QueueArn')
  vt=$(echo "$QA" | jq -r '.Attributes.VisibilityTimeout')
  [ "$vt" -ge 60 ] && pass "Visibility timeout = ${vt}s (≥ 60s)" || fail "Visibility timeout = ${vt}s, cần ≥ 60s (≥ 6 × timeout Lambda)"
  wt=$(echo "$QA" | jq -r '.Attributes.ReceiveMessageWaitTimeSeconds')
  [ "$wt" -ge 1 ] && pass "Long polling bật (WaitTimeSeconds=$wt)" || warn "Nên bật long polling (Receive message wait time 20s)"
  rp=$(echo "$QA" | jq -r '.Attributes.RedrivePolicy // empty')
  if [ -n "$rp" ]; then
    check "DLQ của queue = $P-dlq" "$(echo "$rp" | jq -r '.deadLetterTargetArn')" "$DARN"
    check "maxReceiveCount = 3" "$(echo "$rp" | jq -r '.maxReceiveCount')" "3"
  else
    fail "Queue chưa có redrive policy (DLQ)"
  fi
else
  fail "Thiếu queue $P-queue hoặc $P-dlq"
fi

section "3. SNS → SQS"
TOPIC=$(awsq sns list-topics --query "Topics[?ends_with(TopicArn, ':$P-topic')].TopicArn")
if [ -n "$TOPIC" ]; then
  pass "Có SNS topic $P-topic"
  sub=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" --output json |
        jq -r --arg q "$QARN" '[.Subscriptions[] | select(.Protocol=="sqs" and .Endpoint==$q and (.SubscriptionArn|startswith("arn:")))] | length')
  [ "$sub" -ge 1 ] && pass "Queue đã subscribe topic và được Confirmed" || fail "Chưa có subscription SQS → $P-queue ở trạng thái Confirmed"
else
  fail "Không thấy SNS topic $P-topic"
fi

section "4. Lambda"
LF=$(aws lambda get-function-configuration --function-name $P-processor --output json 2>/dev/null)
ESM=""
if [ -n "$LF" ]; then
  pass "Có Lambda $P-processor"
  echo "$LF" | jq -r '.Runtime' | grep -q '^python3\.\(1[2-9]\|[2-9][0-9]\)' && pass "Runtime: $(echo "$LF" | jq -r '.Runtime')" || warn "Runtime là $(echo "$LF" | jq -r '.Runtime') (khuyên Python 3.12+)"
  tmo=$(echo "$LF" | jq -r '.Timeout')
  [ "$tmo" -le 10 ] && pass "Timeout = ${tmo}s" || warn "Timeout = ${tmo}s – lab khuyên 10s để khớp visibility timeout"
  check "Biến môi trường TABLE_NAME" "$(echo "$LF" | jq -r '.Environment.Variables.TABLE_NAME // ""')" "$P-orders"
  ESM=$(aws lambda list-event-source-mappings --function-name $P-processor --output json | jq -c --arg q "$QARN" '[.EventSourceMappings[] | select(.EventSourceArn==$q)][0]')
  if [ "$ESM" != "null" ] && [ -n "$ESM" ]; then
    st=$(echo "$ESM" | jq -r '.State')
    [ "$st" = "Enabled" ] && pass "Trigger SQS đang Enabled" || fail "Trigger SQS trạng thái '$st' (chờ vài giây hoặc kiểm tra quyền role)"
    r=$(echo "$ESM" | jq -r '(.FunctionResponseTypes // []) | index("ReportBatchItemFailures") != null')
    check_true "Bật Report batch item failures" "$r"
  else
    ESM=""
    fail "Chưa có trigger từ $P-queue tới Lambda"
  fi

  # Least privilege: dùng IAM policy simulator trên role của Lambda
  ROLE_ARN=$(echo "$LF" | jq -r '.Role')
  TBL_ARN=$(awsq dynamodb describe-table --table-name $P-orders --query Table.TableArn)
  sim() { awsq iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" --action-names "$1" --resource-arns "$2" --query "EvaluationResults[0].EvalDecision"; }
  if [ -n "$TBL_ARN" ]; then
    d1=$(sim dynamodb:PutItem "$TBL_ARN")
    if [ -z "$d1" ]; then
      warn "Không mô phỏng được IAM policy (thiếu quyền iam:SimulatePrincipalPolicy?) – bỏ qua kiểm tra least privilege"
    else
      check "Role: dynamodb:PutItem trên bảng $P-orders → allowed" "$d1" "allowed"
      check "Role: dynamodb:DeleteTable → bị từ chối (không cấp dynamodb:*)" "$(sim dynamodb:DeleteTable "$TBL_ARN")" "implicitDeny"
      check "Role: PutItem trên bảng KHÁC → bị từ chối" "$(sim dynamodb:PutItem "arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/not-this-table")" "implicitDeny"
    fi
  fi
else
  fail "Không thấy Lambda $P-processor"
fi

section "5. Chạy thật: publish qua SNS → chờ item xuất hiện trong DynamoDB"
wait_item() { # <orderId> [số lần]: chờ item xuất hiện trong DynamoDB
  local id=$1 n=${2:-12} i v
  for i in $(seq 1 "$n"); do
    v=$(awsq dynamodb get-item --table-name $P-orders --key "{\"orderId\":{\"S\":\"$id\"}}" --query "Item.orderId.S")
    [ "$v" = "$id" ] && return 0
    sleep 5
  done
  return 1
}
del_item() { aws dynamodb delete-item --table-name $P-orders --key "{\"orderId\":{\"S\":\"$1\"}}" >/dev/null 2>&1; }
if [ -n "$TOPIC" ]; then
  id="verify-$(date +%s)"
  aws sns publish --topic-arn "$TOPIC" --message "{\"orderId\":\"$id\",\"amount\":42}" >/dev/null 2>&1 && info "đã publish orderId=$id" || fail "Không publish được vào SNS"
  if wait_item "$id"; then
    pass "Message đi hết luồng SNS → SQS → Lambda → DynamoDB"
    del_item "$id"
  else
    fail "Sau 60s chưa thấy item $id trong DynamoDB. Xem CloudWatch Logs của Lambda, queue policy, quyền DynamoDB"
  fi
fi

if [ $RUN_DLQ -eq 1 ] && [ -n "$TOPIC" ] && [ -n "$DURL" ]; then
  section "6. Poison message → DLQ (chờ tối đa ~6 phút)"
  pid="poison-$(date +%s)"
  aws sns publish --topic-arn "$TOPIC" --message "{\"orderId\":\"$pid\",\"poison\":true}" >/dev/null 2>&1
  ok=0
  for i in $(seq 1 36); do
    n=$(awsq sqs get-queue-attributes --queue-url "$DURL" --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages)
    [ "${n:-0}" -ge 1 ] && { ok=1; break; }
    sleep 10
  done
  [ $ok -eq 1 ] && pass "Poison message đã vào DLQ" || fail "Chưa thấy message trong DLQ sau ~6 phút (kiểm tra maxReceiveCount, report batch failures)"
  [ -n "$DURL" ] && aws sqs purge-queue --queue-url "$DURL" >/dev/null 2>&1
else
  info "Bỏ qua bước DLQ (chạy: bash verify.sh --dlq)"
fi

if [ $ADV -eq 1 ]; then
  echo; echo "######## PHẦN NÂNG CAO ########"

  section "N1. SNS filter policy: queue VIP chỉ nhận message có tier=vip"
  VURL=$(awsq sqs get-queue-url --queue-name $P-vip-queue --query QueueUrl)
  if [ -z "$VURL" ] || [ -z "$TOPIC" ]; then
    fail "Thiếu queue $P-vip-queue hoặc topic $P-topic"
  else
    VARN=$(awsq sqs get-queue-attributes --queue-url "$VURL" --attribute-names QueueArn --query Attributes.QueueArn)
    VSUB=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" --output json | jq -r --arg q "$VARN" '[.Subscriptions[] | select(.Protocol=="sqs" and .Endpoint==$q and (.SubscriptionArn|startswith("arn:")))][0].SubscriptionArn // ""')
    if [ -z "$VSUB" ]; then
      fail "Queue VIP chưa subscribe topic (Confirmed)"
    else
      pass "Queue VIP đã subscribe topic"
      fp=$(awsq sns get-subscription-attributes --subscription-arn "$VSUB" --query Attributes.FilterPolicy)
      r=$(echo "${fp:-null}" | jq -r '(.tier // []) | index("vip") != null' 2>/dev/null)
      check_true "Subscription có filter policy {\"tier\":[\"vip\"]}" "${r:-false}"

      ts=$(date +%s); vid="adv-vip-$ts"; sid="adv-std-$ts"
      aws sns publish --topic-arn "$TOPIC" --message "{\"orderId\":\"$vid\",\"amount\":500}" \
        --message-attributes '{"tier":{"DataType":"String","StringValue":"vip"}}' >/dev/null 2>&1
      aws sns publish --topic-arn "$TOPIC" --message "{\"orderId\":\"$sid\",\"amount\":5}" \
        --message-attributes '{"tier":{"DataType":"String","StringValue":"standard"}}' >/dev/null 2>&1
      info "đã publish 1 message tier=vip ($vid) và 1 message tier=standard ($sid)"
      gotvip=0; gotstd=0; bodies=""
      for _ in 1 2 3 4 5 6; do
        msgs=$(aws sqs receive-message --queue-url "$VURL" --max-number-of-messages 10 --wait-time-seconds 5 --output json 2>/dev/null); [ -z "$msgs" ] && msgs='{}'
        bodies="$bodies $(echo "$msgs" | jq -r '.Messages[]?.Body')"
        while IFS= read -r h; do [ -n "$h" ] && aws sqs delete-message --queue-url "$VURL" --receipt-handle "$h" >/dev/null 2>&1; done < <(echo "$msgs" | jq -r '.Messages[]?.ReceiptHandle')
        [[ "$bodies" == *"$vid"* ]] && gotvip=1
        [ $gotvip -eq 1 ] && break
      done
      sleep 5  # chờ thêm để chắc message standard (nếu bị lọt) kịp tới
      msgs=$(aws sqs receive-message --queue-url "$VURL" --max-number-of-messages 10 --wait-time-seconds 3 --output json 2>/dev/null); [ -z "$msgs" ] && msgs='{}'
      bodies="$bodies $(echo "$msgs" | jq -r '.Messages[]?.Body')"
      [[ "$bodies" == *"$sid"* ]] && gotstd=1
      [ $gotvip -eq 1 ] && pass "Queue VIP nhận message tier=vip" || fail "Queue VIP không nhận được message tier=vip (kiểm tra queue policy cho SNS và filter policy)"
      [ $gotstd -eq 0 ] && pass "Queue VIP KHÔNG nhận message tier=standard (filter hoạt động)" || fail "Queue VIP nhận cả message tier=standard → filter policy sai/chưa áp dụng"
      sleep 3; del_item "$vid"; del_item "$sid"
    fi
  fi

  section "N2. CloudWatch alarm cho DLQ → SNS"
  AL=$(aws cloudwatch describe-alarms --output json 2>/dev/null | jq -c --arg q "$P-dlq" '
     [.MetricAlarms[]? | select(.Namespace=="AWS/SQS" and .MetricName=="ApproximateNumberOfMessagesVisible"
        and ([.Dimensions[]? | select(.Name=="QueueName" and .Value==$q)] | length >= 1))][0] // empty')
  if [ -z "$AL" ]; then
    fail "Chưa có alarm trên metric ApproximateNumberOfMessagesVisible của $P-dlq (namespace AWS/SQS)"
  else
    pass "Có alarm $(echo "$AL" | jq -r .AlarmName) trên $P-dlq"
    r=$(echo "$AL" | jq -r '(.ComparisonOperator=="GreaterThanOrEqualToThreshold" and .Threshold<=1) or (.ComparisonOperator=="GreaterThanThreshold" and .Threshold<1)')
    check_true "Alarm kích hoạt khi DLQ có ≥ 1 message" "$r"
    r=$(echo "$AL" | jq -r '[.AlarmActions[]? | select(test(":sns:") and endswith(":saa-lab04-alerts"))] | length >= 1')
    check_true "Alarm gửi thông báo tới SNS topic $P-alerts" "$r"
  fi

  section "N3. SQS FIFO: loại trùng lặp và giữ thứ tự"
  FURL=$(awsq sqs get-queue-url --queue-name $P-orders.fifo --query QueueUrl)
  if [ -z "$FURL" ]; then
    fail "Chưa có FIFO queue $P-orders.fifo"
  else
    check "Queue là FIFO" "$(awsq sqs get-queue-attributes --queue-url "$FURL" --attribute-names FifoQueue --query Attributes.FifoQueue)" "true"
    ts=$(date +%s); g="g-$ts"
    for x in A B C; do
      aws sqs send-message --queue-url "$FURL" --message-body "$x" --message-group-id "$g" --message-deduplication-id "d-$x-$ts" >/dev/null 2>&1
    done
    aws sqs send-message --queue-url "$FURL" --message-body "A" --message-group-id "$g" --message-deduplication-id "d-A-$ts" >/dev/null 2>&1  # gửi trùng lần 2
    got=""; handles=""
    for _ in 1 2 3; do
      msgs=$(aws sqs receive-message --queue-url "$FURL" --max-number-of-messages 10 --wait-time-seconds 3 --output json 2>/dev/null); [ -z "$msgs" ] && msgs='{}'
      got="$got$(echo "$msgs" | jq -r '[.Messages[]?.Body] | join("")')"
      while IFS= read -r h; do [ -n "$h" ] && aws sqs delete-message --queue-url "$FURL" --receipt-handle "$h" >/dev/null 2>&1; done < <(echo "$msgs" | jq -r '.Messages[]?.ReceiptHandle')
      [ ${#got} -ge 3 ] && break
    done
    check "Gửi A,B,C và A (trùng dedup-id) → nhận đúng 'ABC' (không trùng, đúng thứ tự)" "$got" "ABC"
  fi

  section "N4. Lambda concurrency: bảo vệ DynamoDB phía sau"
  if [ -z "$LF" ]; then
    fail "Bỏ qua: chưa có Lambda"
  else
    lim=$(awsq lambda get-account-settings --query AccountLimit.ConcurrentExecutions)
    rc=$(awsq lambda get-function-concurrency --function-name $P-processor --query ReservedConcurrentExecutions)
    mc=$(echo "${ESM:-{\}}" | jq -r '.ScalingConfig.MaximumConcurrency // empty')
    if [ -n "$lim" ] && [ "$lim" -le 10 ] && [ -z "$rc" ]; then
      warn "Quota concurrency của account chỉ $lim (tài khoản mới) – không đặt được reserved concurrency; xin tăng quota hoặc bỏ qua phần này"
    else
      [ -n "$rc" ] && [ "$rc" -ge 2 ] && [ "$rc" -le 10 ] && pass "Reserved concurrency = $rc (2–10)" || fail "Cần đặt reserved concurrency cho $P-processor trong khoảng 2–10 (hiện: '${rc:-chưa đặt}')"
    fi
    if [ -n "$mc" ]; then
      [ "$mc" -ge 2 ] && { [ -z "$rc" ] || [ "$mc" -le "$rc" ]; } && pass "Event source mapping Maximum concurrency = $mc (≤ reserved)" || fail "Maximum concurrency của trigger ($mc) phải ≥ 2 và ≤ reserved concurrency (${rc:-n/a})"
    else
      fail "Trigger SQS chưa đặt Maximum concurrency (Scaling configuration)"
    fi
  fi

  section "N5. EventBridge → SNS: kiến trúc hướng sự kiện"
  RULE=$P-order-events
  RJ=$(aws events describe-rule --name $RULE --output json 2>/dev/null)
  if [ -z "$RJ" ]; then
    fail "Chưa có EventBridge rule $RULE (bus default)"
  else
    pass "Có rule $RULE"
    check "Rule đang ENABLED" "$(echo "$RJ" | jq -r .State)" "ENABLED"
    r=$(echo "$RJ" | jq -r '(.EventPattern // "{}") | fromjson | (.source // []) | index("saa.lab04") != null')
    check_true "Event pattern lọc source = saa.lab04" "$r"
    TG=$(aws events list-targets-by-rule --rule $RULE --output json 2>/dev/null)
    r=$(echo "${TG:-{\}}" | jq -r --arg t "${TOPIC:-none}" '[.Targets[]? | select(.Arn==$t and .InputPath=="$.detail")] | length >= 1')
    check_true "Target = topic $P-topic với InputPath \$.detail" "$r"
    if [ "$r" = "true" ]; then
      eid="evt-$(date +%s)"
      fe=$(awsq events put-events --entries "[{\"Source\":\"saa.lab04\",\"DetailType\":\"OrderPlaced\",\"Detail\":\"{\\\"orderId\\\":\\\"$eid\\\",\\\"amount\\\":7}\"}]" --query FailedEntryCount)
      check "put-events không có entry lỗi" "$fe" "0"
      if wait_item "$eid"; then pass "Event đi hết EventBridge → SNS → SQS → Lambda → DynamoDB"; del_item "$eid"; else fail "Sau 60s chưa thấy item $eid (kiểm tra topic policy cho events.amazonaws.com và target InputPath)"; fi
    fi
  fi
else
  echo; info "Chạy 'bash verify.sh --advanced' để chấm thêm phần nâng cao (filter policy, alarm DLQ, FIFO, concurrency, EventBridge)."
fi

summary
