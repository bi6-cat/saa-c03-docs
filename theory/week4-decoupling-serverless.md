# Tuần 4 – Decoupling, Serverless & Container

**Mục tiêu:** thiết kế kiến trúc **loosely coupled, bất đồng bộ, serverless**; phân biệt SQS / SNS / EventBridge / Kinesis; biết khi nào dùng Lambda, Fargate, ECS, EKS.
**Lab đi kèm:** `labs/lab04-sns-sqs-lambda`

---

## 1. Vì sao decouple?
Coupling chặt (A gọi trực tiếp B) → B chậm/chết kéo A chết, khó scale độc lập. Đặt **queue/topic/event bus** ở giữa để: đệm tải (buffer), retry, scale từng phần độc lập, chịu lỗi.

---

## 2. Amazon SQS (hàng đợi)

| | Standard | FIFO |
|---|---|---|
| Thông lượng | Gần như không giới hạn | 300 msg/s (3.000 với batching); có *high throughput mode* cao hơn |
| Thứ tự | Best-effort | **Đúng thứ tự** theo `MessageGroupId` |
| Giao | **At-least-once** (có thể trùng) | **Exactly-once processing** (dedup 5 phút) |
| Tên queue | bất kỳ | phải kết thúc `.fifo` |

Các thông số hay ra đề:
- **Visibility timeout**: sau khi consumer nhận, message bị ẩn (mặc định **30 giây**, tối đa 12 giờ). Xử lý xong phải **xoá** message; nếu không sẽ xuất hiện lại. Nên ≥ thời gian xử lý (với Lambda: ≥ **6 × timeout của function**).
- **Retention**: 1 phút – 14 ngày (mặc định 4 ngày).
- **Delay queue**: trì hoãn 0–15 phút.
- **Long polling** (`WaitTimeSeconds` tới 20 giây): giảm số request rỗng/chi phí – nên bật.
- **Dead-Letter Queue (DLQ)**: sau `maxReceiveCount` lần nhận thất bại → chuyển sang DLQ để điều tra. DLQ của FIFO phải là FIFO.
- **Kích thước message**: truyền thống 256 KB (AWS đã nâng giới hạn lên 1 MiB gần đây – đối chiếu doc); lớn hơn → lưu S3, gửi con trỏ (**SQS Extended Client**).
- Mã hoá: SSE (SQS-managed hoặc KMS). Queue policy cho phép SNS/S3 gửi vào.
- **Scale consumer** theo độ dài hàng đợi: CloudWatch `ApproximateNumberOfMessagesVisible` → ASG (backlog per instance).

---

## 3. Amazon SNS (pub/sub)

- Publisher gửi 1 message → **fan-out** tới nhiều subscriber: SQS, Lambda, HTTP(S), email, SMS, mobile push, Firehose.
- **Filter policy** để mỗi subscriber chỉ nhận loại message mình cần.
- **SNS FIFO** (kết hợp SQS FIFO).
- **Mẫu SNS + SQS fan-out**: 1 sự kiện → nhiều queue độc lập, mỗi hệ thống xử lý với tốc độ riêng, có DLQ riêng; bền hơn SNS → Lambda trực tiếp.
- Queue phải có **queue policy** cho phép `sns.amazonaws.com` `SendMessage` từ topic ARN.

---

## 4. Amazon EventBridge
- **Event bus** nhận sự kiện từ: dịch vụ AWS (vd. EC2 state change, CloudTrail API call), ứng dụng của bạn, **SaaS partner**; **rule** lọc theo pattern → target (Lambda, SQS, SNS, Step Functions, API destination…).
- **Scheduler / scheduled rules** (cron) → thay cho cron server.
- **Schema registry**, **Archive & replay**, **Pipes** (point-to-point source → filter → enrich → target).
- Chọn SNS vs EventBridge: SNS = fan-out đơn giản, throughput cao; EventBridge = routing theo nội dung, nguồn AWS/SaaS, schedule.

---

## 5. Kinesis (streaming dữ liệu)
| Dịch vụ | Dùng khi |
|---|---|
| **Kinesis Data Streams** | Thu thập luồng dữ liệu thời gian thực, **nhiều consumer**, giữ lại 24 giờ – 365 ngày, **thứ tự trong shard**, tự quản lý shard (hoặc on-demand mode). Replay được |
| **Data Firehose** | **Nạp** luồng vào S3, Redshift, OpenSearch, Splunk… gần real-time, tự scale, có thể biến đổi bằng Lambda. Không lưu để replay |
| **Managed Service for Apache Flink** | Phân tích luồng SQL/Flink thời gian thực |
| **Amazon MSK** | Kafka managed |

So sánh nhanh **SQS vs Kinesis Data Streams**: SQS – message được xoá sau khi xử lý, 1 consumer group xử lý mỗi message; Kinesis – dữ liệu giữ lại, nhiều consumer đọc độc lập và có thể đọc lại, thứ tự theo partition key.

---

## 6. AWS Lambda
- Chạy code không quản lý server; trả theo số lần gọi + thời gian (GB-giây); có free tier lớn.
- **Giới hạn nhớ**: timeout tối đa **15 phút**; memory **128 MB – 10.240 MB** (CPU tăng theo memory); `/tmp` 512 MB – 10 GB; package .zip 50 MB (zipped)/250 MB (unzipped) hoặc **container image tới 10 GB**.
- **Invocation**: *synchronous* (API Gateway, ALB, SDK), *asynchronous* (S3, SNS, EventBridge – có retry & DLQ/destinations), *event source mapping/poll-based* (SQS, Kinesis, DynamoDB Streams, MSK).
- **Concurrency**: mặc định ~1.000/Region/account (xin tăng được). **Reserved concurrency** (giữ chỗ/giới hạn trần cho 1 function), **Provisioned concurrency** (khởi động sẵn, chống **cold start**). **SnapStart** giảm cold start (Java, v.v.).
- **VPC**: Lambda có thể gắn VPC để truy cập RDS/private resource (cần NAT hoặc endpoint nếu còn ra Internet/AWS API).
- **Layers**, **environment variables** (mã hoá bằng KMS), **versions & aliases** (canary), **Lambda@Edge / CloudFront Functions** (chạy ở edge).
- **Function URL**: HTTPS endpoint đơn giản không cần API Gateway.
- Kết hợp RDS: dùng **RDS Proxy** để tránh cạn connection.

### Mẫu serverless điển hình
`S3 upload → Lambda → DynamoDB`; `API Gateway → Lambda → DynamoDB`; `SQS → Lambda (batch) → xử lý`; `EventBridge schedule → Lambda`.

---

## 7. API Gateway
- Loại: **REST API** (tính năng đầy đủ: API keys, usage plan, request validation, cache, WAF), **HTTP API** (rẻ hơn, đơn giản, độ trễ thấp), **WebSocket API**.
- Endpoint: *Edge-optimized* (qua CloudFront), *Regional*, *Private* (trong VPC).
- **Throttling** (mặc định 10.000 rps/Region/account, burst 5.000), **caching** (0,5–237 GB, TTL mặc định 300 giây), **Authorizer**: IAM, Cognito User Pool, Lambda authorizer.
- Tích hợp: Lambda, HTTP, dịch vụ AWS, mock; **stage variables**, **canary release**.

---

## 8. Step Functions & Workflow khác
- **Step Functions**: điều phối workflow bằng state machine (retry, catch, parallel, map, chờ human approval…). **Standard** (chạy tới 1 năm, exactly-once) vs **Express** (tới 5 phút, throughput cao, at-least-once).
- **SWF** (cũ), **Amazon MQ** (ActiveMQ/RabbitMQ managed – dùng khi **di chuyển** app đang dùng AMQP/MQTT/JMS mà không muốn viết lại), **AppSync** (GraphQL managed), **AWS Batch** (job batch trên EC2/Spot/Fargate).

---

## 9. Container
| Dịch vụ | Mô tả |
|---|---|
| **ECS** | Điều phối container của AWS. Launch type: **EC2** (tự quản cluster) hoặc **Fargate** (serverless, không quản lý server) |
| **EKS** | Kubernetes managed (tương thích K8s chuẩn, đa cloud); node trên EC2 hoặc Fargate |
| **ECR** | Registry image, quét lỗ hổng |
| **App Runner** | Chạy web app/API container đơn giản nhất, auto scale |
| **Fargate** | Compute engine serverless cho ECS/EKS |

- Quyền: **Task role** (ECS) / **IRSA / Pod Identity** (EKS) cấp cho container; **execution role** để kéo image/ghi log.
- Chọn: không muốn quản lý server → **Fargate**; đã dùng Kubernetes/đa cloud → **EKS**; đơn giản trên AWS → **ECS**.
- **Elastic Beanstalk**: PaaS – upload code, AWS lo EC2/ELB/ASG. **CloudFormation / CDK**: Infrastructure as Code. **Systems Manager**: quản lý fleet (Session Manager thay SSH, Patch Manager, Parameter Store).

---

## 10. Bẫy thường gặp
1. "Xử lý bất đồng bộ, không mất message, scale độc lập" → **SQS** giữa các tầng.
2. "Một sự kiện → nhiều hệ thống xử lý" → **SNS fan-out (SNS + SQS)** hoặc EventBridge.
3. "Thứ tự nghiêm ngặt + không trùng" → **SQS FIFO**.
4. "Message độc không xử lý được, ngăn lặp vô hạn" → **DLQ**.
5. "Dữ liệu streaming thời gian thực, nhiều consumer, replay" → **Kinesis Data Streams**; "đẩy vào S3 gần real-time" → **Firehose**.
6. "Cron không cần server" → **EventBridge Scheduler + Lambda**.
7. Lambda >15 phút → Step Functions / Fargate / Batch.
8. Lambda cold start → Provisioned Concurrency / SnapStart.
9. "Di chuyển app dùng AMQP/MQTT mà không sửa code" → **Amazon MQ**.
10. "Giảm tải DB cho Lambda" → RDS Proxy.

---

## 11. Tự kiểm tra

1. SQS Standard vs FIFO: 3 khác biệt chính?
2. Visibility timeout làm gì? Nếu đặt quá nhỏ so với thời gian xử lý thì sao?
3. Thiết kế: upload ảnh lên S3 → tạo thumbnail + ghi metadata + gửi email. Gợi ý kiến trúc decoupled?
4. Khi nào chọn Kinesis Data Streams thay cho SQS?
5. Lambda timeout tối đa? Cách tránh cold start?
6. Fargate khác EC2 launch type ở điểm nào?
7. SNS filter policy dùng để làm gì?
8. API Gateway REST API vs HTTP API – khi nào chọn cái nào?

<details><summary>Đáp án</summary>

1. Thông lượng (không giới hạn vs hạn chế), thứ tự (best-effort vs FIFO), giao (at-least-once vs exactly-once processing).
2. Ẩn message khỏi consumer khác khi đang xử lý. Quá nhỏ → message hiện lại khi chưa xử lý xong → xử lý trùng.
3. S3 Event → SNS topic → 3 SQS queue (thumbnail, metadata, email) → mỗi cái 1 Lambda/consumer, mỗi queue có DLQ. (Hoặc S3 → EventBridge → targets.)
4. Cần nhiều consumer đọc cùng dữ liệu, giữ lại/replay, thứ tự theo partition key, tốc độ cao liên tục.
5. 15 phút. Provisioned Concurrency, SnapStart, giảm kích thước package, tránh khởi tạo nặng.
6. Fargate không phải quản lý/patch/scale cụm EC2; trả theo vCPU/memory của task.
7. Lọc để mỗi subscriber chỉ nhận message khớp thuộc tính.
8. REST: cần API key/usage plan, validation, cache, WAF… HTTP API: đơn giản, rẻ, độ trễ thấp.
</details>

## Tài liệu nên đọc thêm
- FAQ: SQS, SNS, EventBridge, Kinesis Data Streams, Lambda, API Gateway, Step Functions.
- Doc: "SQS standard vs FIFO queues", "Lambda concurrency và cold start", "Choosing between REST API và HTTP API".
