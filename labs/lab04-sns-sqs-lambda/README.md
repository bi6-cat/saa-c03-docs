# Lab 04 – Kiến trúc bất đồng bộ: SNS → SQS (+DLQ) → Lambda → DynamoDB

**Thời gian:** ~60–90 phút (+~60 phút phần nâng cao) | **Chi phí:** ≈ 0 (nằm trong free tier với lượng nhỏ; CloudWatch alarm đầu tiên nằm trong free tier)
**Liên quan lý thuyết:** `theory/week4-decoupling-serverless.md`

## Mục tiêu
```
Publisher ──► SNS topic ──► SQS queue ──► Lambda (batch) ──► DynamoDB
                               │ (sau 3 lần xử lý lỗi)
                               └──► SQS Dead-Letter Queue
```
Hiểu fan-out, buffer, retry, DLQ, visibility timeout, partial batch failure.

## Quy ước tên (BẮT BUỘC)
| Tài nguyên | Tên |
|---|---|
| DynamoDB table | `saa-lab04-orders` (PK: `orderId` String, on-demand) |
| SQS DLQ | `saa-lab04-dlq` (Standard) |
| SQS queue | `saa-lab04-queue` (Standard) |
| SNS topic | `saa-lab04-topic` (Standard) |
| Lambda function | `saa-lab04-processor` (Python 3.12+ ) |
| IAM role của Lambda | `saa-lab04-lambda-role` |

## Bước 1 – DynamoDB
Tạo bảng `saa-lab04-orders`, partition key `orderId` (String), On-demand.

## Bước 2 – SQS
1. Tạo `saa-lab04-dlq` (Standard, mặc định).
2. Tạo `saa-lab04-queue` (Standard):
   - **Visibility timeout: 60 giây** (phải ≥ 6 × timeout Lambda; Lambda timeout sẽ đặt 10 giây).
   - **Receive message wait time: 20 giây** (long polling).
   - **Dead-letter queue**: bật, chọn `saa-lab04-dlq`, **Maximum receives = 3**.
   - Chưa cần sửa access policy ngay (xem Bước 4).

## Bước 3 – Lambda
1. IAM role `saa-lab04-lambda-role` (trusted entity: Lambda) với:
   - Managed policy **`AWSLambdaSQSQueueExecutionRole`** (đọc/xoá SQS + ghi CloudWatch Logs)
   - Inline policy cho phép **`dynamodb:PutItem`** trên bảng `saa-lab04-orders` *(chỉ đúng bảng đó – least privilege)*
2. Function `saa-lab04-processor`, runtime **Python 3.12 hoặc mới hơn**, role ở trên, **Timeout = 10 giây**, biến môi trường `TABLE_NAME=saa-lab04-orders`. Dán code trong [`lambda_function.py`](lambda_function.py).
3. Thêm trigger: **SQS → `saa-lab04-queue`**, Batch size 10, bật **Report batch item failures**.

## Bước 4 – SNS và liên kết SNS → SQS
1. Tạo SNS topic Standard `saa-lab04-topic`.
2. Tạo **Subscription**: protocol **Amazon SQS**, endpoint = ARN của `saa-lab04-queue`. (Console có thể tự thêm quyền cho queue cùng account; nếu không, hãy tự thêm policy ở mục 3 bên dưới.)
3. Đảm bảo **queue access policy** của `saa-lab04-queue` cho SNS gửi vào:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "sns.amazonaws.com" },
    "Action": "sqs:SendMessage",
    "Resource": "<ARN của saa-lab04-queue>",
    "Condition": { "ArnEquals": { "aws:SourceArn": "<ARN của saa-lab04-topic>" } }
  }]
}
```
4. Subscription phải ở trạng thái **Confirmed**.

## Thử tay
```bash
TOPIC=$(aws sns list-topics --query "Topics[?contains(TopicArn,'saa-lab04-topic')].TopicArn" --output text)
aws sns publish --topic-arn "$TOPIC" --message '{"orderId":"o-1001","amount":25}'
aws dynamodb get-item --table-name saa-lab04-orders --key '{"orderId":{"S":"o-1001"}}'
```
Thử **poison message**: `--message '{"orderId":"bad-1","poison":true}'` → Lambda ném lỗi → message được nhận lại tối đa 3 lần rồi vào DLQ. Xem `saa-lab04-dlq` → *Poll for messages*.

## Câu hỏi
1. Nếu Lambda timeout (10s) nhưng visibility timeout chỉ 5s thì sao?
2. Vì sao dùng SNS → SQS thay vì SNS → Lambda trực tiếp? (bền, retry, DLQ, tách tốc độ)
3. "Report batch item failures" giải quyết vấn đề gì? (chỉ retry message lỗi, không lặp cả batch)
4. Muốn thêm hệ thống thứ hai cũng nhận mọi đơn hàng (ví dụ gửi email)? Thêm gì? (queue/consumer thứ hai subscribe cùng topic; dùng filter policy nếu chỉ cần một phần)
5. Nếu cần thứ tự nghiêm ngặt và không trùng? (SNS FIFO + SQS FIFO)

## PHẦN NÂNG CAO (chấm bằng `bash verify.sh --advanced`)

Làm sau khi phần cơ bản đã PASS hoàn toàn. Mỗi mục là một "mẫu thiết kế" hay ra trong đề SAA.

| Tài nguyên | Tên (BẮT BUỘC) |
|---|---|
| SQS queue cho khách VIP | `saa-lab04-vip-queue` (Standard) |
| SNS topic cảnh báo | `saa-lab04-alerts` |
| CloudWatch alarm | tên bất kỳ, trên `saa-lab04-dlq` |
| SQS FIFO queue | `saa-lab04-orders.fifo` |
| EventBridge rule (bus `default`) | `saa-lab04-order-events` |

### N1. Fan-out có lọc: SNS filter policy
1. Tạo `saa-lab04-vip-queue`, thêm access policy cho SNS giống Bước 4 (chỉ khác `Resource` là ARN queue VIP).
2. Subscribe queue này vào `saa-lab04-topic` với **Subscription filter policy** (scope: *Message attributes*):
```json
{ "tier": ["vip"] }
```
3. Publish thử:
```bash
aws sns publish --topic-arn "$TOPIC" --message '{"orderId":"o-vip-1","amount":500}' \
  --message-attributes '{"tier":{"DataType":"String","StringValue":"vip"}}'
```
Queue VIP chỉ nhận message `tier=vip`; `saa-lab04-queue` (không filter) vẫn nhận tất cả.
Hỏi: filter theo *nội dung* message (body) thay vì attribute thì đổi tuỳ chọn nào? (`FilterPolicyScope = MessageBody`.) Message **không có** attribute `tier` thì queue VIP nhận hay không? (không.)

### N2. Giám sát DLQ bằng CloudWatch Alarm
1. Tạo SNS topic `saa-lab04-alerts` (có thể subscribe email của bạn để nhận thật).
2. CloudWatch → Alarms → Create alarm: metric **SQS → Queue Metrics → `ApproximateNumberOfMessagesVisible`** của `saa-lab04-dlq`, statistic **Maximum**, period 1 phút, điều kiện **≥ 1**, hành động khi `In alarm` → topic `saa-lab04-alerts`.

Hỏi: vì sao đây là cách chuẩn để biết có message lỗi? (DLQ im lặng – không ai biết nếu không có alarm.) Message trong DLQ giữ được bao lâu? (retention của DLQ, mặc định 4 ngày – nên đặt dài hơn queue gốc; dùng *DLQ redrive* để đẩy ngược lại sau khi sửa lỗi.)

### N3. SQS FIFO: không trùng, đúng thứ tự
Tạo **FIFO** queue `saa-lab04-orders.fifo` (tên phải kết thúc `.fifo`), **Content-based deduplication: tắt** (bạn tự đặt `MessageDeduplicationId`).
```bash
Q=$(aws sqs get-queue-url --queue-name saa-lab04-orders.fifo --query QueueUrl --output text)
aws sqs send-message --queue-url $Q --message-body A --message-group-id g1 --message-deduplication-id d-A
aws sqs send-message --queue-url $Q --message-body A --message-group-id g1 --message-deduplication-id d-A   # trùng → bị loại
```
Hỏi: *Message group ID* quyết định điều gì? (thứ tự chỉ được đảm bảo **trong một group**; nhiều group xử lý song song.) Cửa sổ khử trùng lặp bao lâu? (5 phút.) Thông lượng FIFO so với Standard? (thấp hơn; có *high throughput mode*.) Khi nào bắt buộc FIFO? (chuyển khoản, lệnh có thứ tự…)

### N4. Bảo vệ hệ thống phía sau: concurrency của Lambda
1. Lambda `saa-lab04-processor` → Configuration → Concurrency → **Reserved concurrency = 5** (giới hạn **và** dành riêng).
2. Trigger SQS → Edit → **Maximum concurrency = 2** (Scaling configuration; tối thiểu 2).

Hỏi: nếu reserved concurrency (vd. 1) thấp hơn nhu cầu thì SQS xử lý ra sao? (Lambda bị throttle → message quay lại queue và bị đếm vào `maxReceiveCount` → có thể vào DLQ oan! Vì vậy đặt Maximum concurrency của trigger ≤ reserved, và `maxReceiveCount` đủ lớn.)
> Tài khoản mới có thể có quota Lambda concurrency rất thấp (10) nên **không** đặt được reserved concurrency (phải chừa ≥ 10 không dành riêng). `verify.sh` sẽ báo WARN trong trường hợp đó – bạn có thể bỏ qua phần đặt reserved, vẫn đặt Maximum concurrency của trigger.

### N5. Kiến trúc hướng sự kiện: EventBridge → SNS
1. EventBridge → Rules (bus **default**) → tên **`saa-lab04-order-events`**, loại *Rule with an event pattern*:
```json
{ "source": ["saa.lab04"], "detail-type": ["OrderPlaced"] }
```
2. Target: **SNS topic** `saa-lab04-topic`; *Additional settings → Configure target input → **Part of the matched event** → `$.detail`* (để message gửi đi chính là `{"orderId":..,"amount":..}`).
3. **Topic access policy** phải cho EventBridge publish (nếu Console chưa tự thêm):
```json
{ "Effect": "Allow", "Principal": { "Service": "events.amazonaws.com" },
  "Action": "sns:Publish", "Resource": "<ARN saa-lab04-topic>" }
```
4. Thử: `aws events put-events --entries '[{"Source":"saa.lab04","DetailType":"OrderPlaced","Detail":"{\"orderId\":\"e-1\",\"amount\":7}"}]'` → sau vài giây có item `e-1` trong DynamoDB.

Hỏi: EventBridge khác SNS ở đâu? (lọc theo nội dung phong phú, nguồn là dịch vụ AWS/SaaS/ứng dụng, schedule, archive & replay, nhiều đích cho một rule.) Khi nào dùng **EventBridge Scheduler / rule cron** thay vì cron trên EC2?

### Câu hỏi nâng cao
6. Có nên bật *raw message delivery* cho subscription SNS → SQS không? Lambda trong lab này phải đổi gì? (Raw: body là message gốc, không bọc envelope.)
7. Giữ thứ tự nghiêm ngặt nhưng muốn xử lý song song nhiều khách hàng: thiết kế *message group ID* thế nào? (mỗi khách hàng một group.)
8. SNS → Lambda trực tiếp có retry/DLQ không? Khác SNS → SQS → Lambda thế nào về chịu tải đột biến?

## Verify & Cleanup
```bash
bash verify.sh            # kiểm tra cấu hình + gửi 1 message thật qua SNS và chờ ghi vào DynamoDB
bash verify.sh --dlq      # thêm kiểm tra poison message → DLQ (chậm, ~3–5 phút)
bash verify.sh --advanced # thêm phần nâng cao N1–N5 (có thể kết hợp: --dlq --advanced)
bash cleanup.sh
```
