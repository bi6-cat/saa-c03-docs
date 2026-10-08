#!/usr/bin/env bash
# Cleanup Lab 04
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab04
confirm "$P-*"

echo "- Xoá EventBridge rule (nâng cao)..."
if aws events describe-rule --name $P-order-events >/dev/null 2>&1; then
  ids=$(awsq events list-targets-by-rule --rule $P-order-events --query "Targets[].Id")
  [ -n "$ids" ] && aws events remove-targets --rule $P-order-events --ids $ids >/dev/null
  aws events delete-rule --name $P-order-events && echo "  đã xoá rule"
fi

echo "- Xoá CloudWatch alarm trên DLQ (nâng cao)..."
for a in $(aws cloudwatch describe-alarms --output json 2>/dev/null | jq -r --arg q "$P-dlq" '.MetricAlarms[]? | select([.Dimensions[]? | select(.Name=="QueueName" and .Value==$q)] | length >= 1) | .AlarmName'); do
  aws cloudwatch delete-alarms --alarm-names "$a" && echo "  đã xoá alarm $a"
done

echo "- Xoá event source mapping & Lambda..."
for u in $(awsq lambda list-event-source-mappings --function-name $P-processor --query "EventSourceMappings[].UUID"); do
  aws lambda delete-event-source-mapping --uuid "$u" >/dev/null
done
aws lambda delete-function --function-name $P-processor >/dev/null 2>&1 && echo "  đã xoá Lambda"
aws logs delete-log-group --log-group-name "/aws/lambda/$P-processor" 2>/dev/null && echo "  đã xoá log group"

echo "- Xoá SNS topic (kèm subscription)..."
for t in topic alerts; do
  T=$(awsq sns list-topics --query "Topics[?ends_with(TopicArn, ':$P-$t')].TopicArn")
  [ -n "$T" ] && aws sns delete-topic --topic-arn "$T" && echo "  đã xoá topic $P-$t"
done

echo "- Xoá SQS queue & DLQ..."
for q in $P-queue $P-dlq $P-vip-queue $P-orders.fifo; do
  u=$(awsq sqs get-queue-url --queue-name $q --query QueueUrl)
  [ -n "$u" ] && aws sqs delete-queue --queue-url "$u" && echo "  đã xoá $q"
done

echo "- Xoá DynamoDB table..."
aws dynamodb delete-table --table-name $P-orders >/dev/null 2>&1 && echo "  đã yêu cầu xoá bảng"

echo "- Xoá IAM role..."
R=$P-lambda-role
for arn in $(awsq iam list-attached-role-policies --role-name $R --query "AttachedPolicies[].PolicyArn"); do
  aws iam detach-role-policy --role-name $R --policy-arn "$arn"
done
for n in $(awsq iam list-role-policies --role-name $R --query "PolicyNames"); do
  aws iam delete-role-policy --role-name $R --policy-name "$n"
done
aws iam delete-role --role-name $R 2>/dev/null && echo "  đã xoá role"
echo "Xong."
