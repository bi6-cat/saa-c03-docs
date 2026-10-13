"""Lab 01 – N5: Lambda làm target của ALB (path /api/*).

ALB gọi Lambda với event dạng {httpMethod, path, headers, queryStringParameters, body, ...}
và mong nhận lại đúng định dạng response bên dưới (statusCode, headers, body...).
"""
import json


def lambda_handler(event, context):
    body = {
        "source": "lambda",
        "path": event.get("path"),
        "method": event.get("httpMethod"),
        "query": event.get("queryStringParameters"),
        "requestId": context.aws_request_id,
    }
    return {
        "statusCode": 200,
        "statusDescription": "200 OK",
        "isBase64Encoded": False,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
