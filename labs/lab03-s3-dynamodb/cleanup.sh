#!/usr/bin/env bash
# Cleanup Lab 03 – xoá bucket (mọi version) và bảng DynamoDB
source "$(dirname "$0")/../_common.sh"
preflight
confirm "bucket saa-lab03-$ACCOUNT_ID, queue saa-lab03-events và bảng saa-lab03-orders"

echo "- Xoá bucket (kể cả mọi version/delete marker)..."
empty_bucket "saa-lab03-$ACCOUNT_ID"

echo "- Xoá SQS queue sự kiện (phần nâng cao)..."
QU=$(awsq sqs get-queue-url --queue-name saa-lab03-events --query QueueUrl)
[ -n "$QU" ] && aws sqs delete-queue --queue-url "$QU" && echo "  đã xoá saa-lab03-events"

echo "- Xoá bảng DynamoDB..."
aws dynamodb delete-table --table-name saa-lab03-orders >/dev/null 2>&1 && echo "  đã yêu cầu xoá saa-lab03-orders" || echo "  (không thấy bảng)"
echo "Xong."
