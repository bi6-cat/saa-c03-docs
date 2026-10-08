import json
import os
from decimal import Decimal

import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def lambda_handler(event, context):
    """Xử lý batch message từ SQS. Trả về các message lỗi để SQS chỉ retry chúng."""
    failures = []
    for record in event["Records"]:
        try:
            body = json.loads(record["body"])
            # Nếu SNS không bật raw message delivery, body là "phong bì" SNS -> bóc ra
            if isinstance(body, dict) and "Message" in body and "TopicArn" in body:
                body = json.loads(body["Message"])

            if body.get("poison"):
                raise ValueError("poison message (cố ý lỗi để thử DLQ)")

            table.put_item(
                Item={
                    "orderId": str(body["orderId"]),
                    "amount": Decimal(str(body.get("amount", 0))),
                    "source": "saa-lab04",
                }
            )
        except Exception as exc:  # noqa: BLE001
            print("FAILED", record["messageId"], repr(exc))
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}
