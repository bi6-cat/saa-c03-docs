# Tuần 4 – Decoupling, Serverless & Container

**Mục tiêu:** thiết kế kiến trúc **loosely coupled, bất đồng bộ, serverless**; phân biệt SQS / SNS / EventBridge / Kinesis; biết khi nào dùng Lambda, Fargate, ECS, EKS, Step Functions.
**Lab đi kèm:** `labs/lab04-sns-sqs-lambda`

> Ký hiệu: **💡 Kinh nghiệm thực tế** · **🎯 Mẹo thi** · **⚠️ Hay nhầm**.

---

## 1. Vì sao decouple?

**Coupling chặt** (A gọi đồng bộ trực tiếp B):
- B chậm → A chậm theo; B chết → A lỗi (lỗi dây chuyền).
- A và B phải scale cùng nhịp; tải đột biến từ A đè bẹp B.
- Deploy B phải phối hợp với A.

**Đặt queue/topic/event bus ở giữa** để:
- **Đệm tải (buffer / load leveling)**: A đẩy 10.000 việc trong 1 phút, B xử lý đều 100 việc/giây, không mất việc nào.
- **Retry & cô lập lỗi**: B lỗi tạm thời → message quay lại hàng đợi, sau N lần → DLQ.
- **Scale độc lập**: số consumer co giãn theo độ dài hàng đợi.
- **Mở rộng dễ**: thêm hệ thống mới chỉ cần subscribe, không sửa A.

| Mẫu | Dịch vụ | Một câu |
|---|---|---|
| **Queue** (point-to-point) | SQS | 1 message → **1** consumer xử lý, xoá sau khi xong |
| **Pub/Sub** (fan-out) | SNS | 1 message → **nhiều** subscriber, đẩy (push) ngay |
| **Event bus** (routing theo nội dung) | EventBridge | Sự kiện → rule lọc theo nội dung → nhiều target, nguồn AWS/SaaS/app |
| **Stream** (log có thứ tự, đọc lại được) | Kinesis Data Streams, MSK | Dữ liệu giữ lại, nhiều consumer đọc độc lập, replay |
| **Orchestration** (điều phối từng bước) | Step Functions | Workflow có trạng thái, retry, nhánh, chờ |

---

## 2. Amazon SQS (hàng đợi)

### 2.1 Standard vs FIFO

| | Standard | FIFO |
|---|---|---|
| Thông lượng | Gần như **không giới hạn** | **300 msg/giây** mỗi API (**3.000** với batching 10); *high throughput mode* cao hơn nhiều |
| Thứ tự | Best-effort (có thể lệch) | **Đúng thứ tự** trong mỗi `MessageGroupId` |
| Giao | **At-least-once** (có thể trùng) | **Exactly-once processing** (khử trùng trong cửa sổ **5 phút** bằng `MessageDeduplicationId` hoặc content-based deduplication) |
| Tên queue | bất kỳ | phải kết thúc bằng **`.fifo`** |
| Dùng khi | Hầu hết trường hợp decouple | Đơn hàng/giao dịch phải đúng thứ tự, không được trùng |

> 💡 FIFO thứ tự theo **message group**: dùng `MessageGroupId = customerId` → thứ tự đúng cho từng khách hàng và các khách hàng khác nhau vẫn xử lý **song song**. Dùng một group duy nhất cho mọi message = chỉ 1 consumer xử lý tại một thời điểm (chậm).

### 2.2 Vòng đời một message

```
Producer ──SendMessage──► [ Queue ] ──ReceiveMessage──► Consumer
                             │   (message bị ẩn trong visibility timeout)
                             │
           Consumer xử lý xong ──DeleteMessage──► message bị xoá vĩnh viễn
           Consumer lỗi / quá timeout ──► message hiện lại, ReceiveCount+1
           ReceiveCount > maxReceiveCount ──► chuyển sang DLQ
```

### 2.3 Các thông số hay ra đề

| Thông số | Giá trị | Ghi chú |
|---|---|---|
| **Visibility timeout** | Mặc định **30 giây**, 0 giây – **12 giờ** | Phải ≥ thời gian xử lý. Với Lambda: ≥ **6 × timeout của function** (+ batching window). Có thể gia hạn từng message bằng `ChangeMessageVisibility` |
| **Retention** | **1 phút – 14 ngày**, mặc định **4 ngày** | Hết hạn → message bị xoá, kể cả chưa xử lý |
| **Delay queue / message timer** | **0–15 phút** | Trì hoãn message mới xuất hiện |
| **Long polling** | `WaitTimeSeconds` 1–**20 giây** | Giảm request rỗng → **giảm chi phí** và độ trễ. Nên bật (lab04 dùng 20 giây) |
| **DLQ** | `maxReceiveCount` (vd. 3–5) | DLQ của FIFO phải là FIFO; đặt retention DLQ **dài hơn** queue nguồn; có **redrive** đẩy message từ DLQ về lại queue nguồn |
| **Kích thước message** | Truyền thống **256 KB** (AWS đã nâng lên 1 MiB – đối chiếu doc) | Lớn hơn → lưu S3, gửi con trỏ (**SQS Extended Client Library**) |
| **Message in-flight** | ~120.000 (Standard), ~20.000 (FIFO) | Đã nhận chưa xoá – vượt sẽ lỗi `OverLimit` |
| **Batch** | Tối đa 10 message/lệnh Send/Receive/Delete | Batching giảm chi phí (tính theo request) |

- **Mã hoá**: SSE-SQS (mặc định) hoặc SSE-KMS; in-transit HTTPS.
- **Access policy** (resource-based): cho phép SNS topic, S3 bucket, account khác gửi vào queue.
- **Scale consumer**: CloudWatch `ApproximateNumberOfMessagesVisible` / `ApproximateAgeOfOldestMessage` → ASG target tracking theo **backlog per instance** (xem tuần 1).

> 💡 **Kinh nghiệm thực tế – SQS**
> - **Consumer phải idempotent** (xử lý trùng không gây hại): Standard queue có thể giao trùng; Lambda retry cũng gây trùng. Kỹ thuật: lưu `messageId`/business key đã xử lý vào DynamoDB với điều kiện `attribute_not_exists`, hoặc thiết kế thao tác "ghi đè cùng giá trị".
> - **Visibility timeout quá ngắn** là nguyên nhân số 1 của "message bị xử lý 2–3 lần" và "DLQ đầy dù code không lỗi".
> - **Luôn có DLQ + alarm** trên `ApproximateNumberOfMessagesVisible` của DLQ > 0. DLQ không ai nhìn = mất dữ liệu trong im lặng sau khi hết retention.
> - Theo dõi `ApproximateAgeOfOldestMessage`: tăng dần = consumer không theo kịp.
> - **Poison message** (message luôn làm consumer crash) → DLQ sau `maxReceiveCount` lần; với Lambda batch, bật **ReportBatchItemFailures** để chỉ message lỗi quay lại chứ không phải cả batch (lab04).

---

## 3. Amazon SNS (pub/sub)

- Publisher gửi 1 message lên **topic** → SNS **đẩy** tới mọi subscriber: **SQS, Lambda, HTTP(S), email, SMS, mobile push, Kinesis Data Firehose**.
- SNS **không lưu** message để đọc sau: subscriber không nhận được (HTTP lỗi) → retry theo policy rồi bỏ (hoặc vào DLQ của subscription).
- **Filter policy** (theo message attributes hoặc nội dung body JSON): mỗi subscriber chỉ nhận message khớp, vd. queue "payment" chỉ nhận `{"eventType": ["ORDER_PAID"]}`.
- **SNS FIFO**: thứ tự + khử trùng, kết hợp SQS FIFO.
- **Raw message delivery**: gửi body gốc tới SQS/HTTP thay vì JSON bọc của SNS.
- **Message data protection**: phát hiện/che PII trong message.
- Queue nhận từ SNS phải có **queue policy** cho phép `sns.amazonaws.com` `sqs:SendMessage` với điều kiện `aws:SourceArn` = ARN topic (lab04 Bước 4). Nếu queue mã hoá bằng CMK, key policy cũng phải cho SNS dùng key.

### Mẫu SNS + SQS fan-out (rất hay ra đề)

```
                       ┌──► SQS "thumbnail" ──► Lambda resize      (DLQ riêng)
S3 upload ──► SNS ─────┼──► SQS "metadata"  ──► Lambda ghi DynamoDB (DLQ riêng)
                       └──► SQS "notify"    ──► Lambda gửi email    (DLQ riêng)
```
Vì sao không SNS → Lambda trực tiếp? Mỗi nhánh có **bộ đệm riêng, tốc độ riêng, retry riêng, DLQ riêng**; một hệ thống chậm/hỏng không ảnh hưởng hệ thống khác; thêm nhánh mới không đụng nhánh cũ.

> ⚠️ S3 event notification: **một** loại sự kiện + prefix chỉ gửi tới **một** đích → muốn nhiều đích thì S3 → **SNS** (fan-out) hoặc S3 → **EventBridge**.

---

## 4. Amazon EventBridge

- **Event bus**: *default bus* (sự kiện từ dịch vụ AWS: EC2 state change, ASG, CodePipeline, **CloudTrail API call**…), *custom bus* (sự kiện của ứng dụng bạn), *partner bus* (**SaaS**: Zendesk, Datadog, Shopify…).
- **Rule** = **event pattern** (lọc theo bất kỳ trường nào trong JSON, prefix, số, tồn tại/không tồn tại…) → tối đa vài target/rule: Lambda, SQS, SNS, Step Functions, Kinesis, ECS task, API Gateway, **API destination** (HTTP bên ngoài), event bus account/Region khác.
- **Input transformer**: định dạng lại event trước khi gửi target.
- Retry tới **24 giờ** (mặc định), DLQ (SQS) cho từng target.
- **Archive & replay**: lưu event để chạy lại (sau khi sửa bug consumer).
- **Schema registry**: tự khám phá schema, sinh code binding.
- **EventBridge Scheduler**: lịch cron/rate/one-time, có **time zone**, hàng triệu lịch → thay cron server và thay "scheduled rule" cũ.
- **EventBridge Pipes**: point-to-point *source → filter → enrich → target* (vd. DynamoDB Stream → lọc → gọi Lambda enrich → SQS), giảm code "keo dán".
- **Cross-account**: gửi event sang bus của account trung tâm (gom sự kiện bảo mật toàn Org).

Ví dụ event pattern: bắt mọi instance EC2 chuyển sang `stopped` ở môi trường prod:
```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": { "state": ["stopped"] }
}
```

**SNS hay EventBridge?**
| | SNS | EventBridge |
|---|---|---|
| Nguồn | App của bạn publish | Dịch vụ AWS, SaaS, app của bạn |
| Lọc | Filter policy (attributes/body) | Event pattern mạnh hơn trên toàn bộ JSON |
| Target | SQS, Lambda, HTTP, email, SMS, push, Firehose | 20+ loại dịch vụ AWS, API destination |
| Thông lượng / độ trễ | Rất cao, độ trễ thấp | Cao, độ trễ thường cao hơn chút |
| Tính năng thêm | SMS/email/push tới con người | Archive/replay, schema registry, Scheduler, Pipes |

> 🎯 "Phản ứng tự động khi có sự kiện của dịch vụ AWS (instance dừng, GuardDuty finding, gọi API nhạy cảm)" → **EventBridge rule**. "Gửi SMS/email/push tới người dùng" → **SNS**. "Cron không server" → **EventBridge Scheduler + Lambda**. "Tích hợp sự kiện từ SaaS" → **EventBridge partner event bus**.

---

## 5. Kinesis & streaming

| Dịch vụ | Dùng khi | Điểm chính |
|---|---|---|
| **Kinesis Data Streams (KDS)** | Thu thập luồng dữ liệu real-time, **nhiều consumer**, **replay**, **thứ tự theo partition key** | Giữ **24 giờ (mặc định) – 365 ngày**; chế độ *provisioned* (tự quản shard) hoặc *on-demand* |
| **Amazon Data Firehose** | **Nạp** luồng vào S3, Redshift, OpenSearch, Splunk, HTTP, Snowflake… gần real-time | Serverless, tự scale, buffer theo kích thước/thời gian, biến đổi bằng Lambda, chuyển **Parquet/ORC**, nén. **Không lưu để replay** |
| **Managed Service for Apache Flink** | Phân tích luồng (SQL/Flink) real-time: window, aggregate, phát hiện bất thường | Đọc từ KDS/MSK |
| **Amazon MSK** | **Kafka** managed (provisioned hoặc Serverless) | Di chuyển hệ thống đang dùng Kafka, cần API Kafka |

### 5.1 Kinesis Data Streams chi tiết
- Dữ liệu chia vào **shard** theo **partition key** (hash). Mỗi shard (provisioned):
  - Ghi: **1 MB/giây hoặc 1.000 record/giây**.
  - Đọc: **2 MB/giây** dùng chung cho mọi consumer kiểu thường; **Enhanced Fan-Out**: mỗi consumer có riêng 2 MB/giây/shard (push, độ trễ ~70 ms).
- Thứ tự đảm bảo **trong một shard** (cùng partition key).
- Consumer: Lambda (event source mapping), KCL (Kinesis Client Library – dùng DynamoDB để checkpoint), Firehose, Flink.
- Lỗi `ProvisionedThroughputExceededException` → **hot shard** (partition key kém phân tán) → chọn key tốt hơn, **split shard**, retry với backoff, hoặc dùng on-demand mode.
- Mã hoá KMS at rest; truy cập private qua interface endpoint.

### 5.2 SQS vs Kinesis Data Streams vs SNS

| | SQS | SNS | Kinesis Data Streams |
|---|---|---|---|
| Mô hình | Pull, queue | Push, pub/sub | Pull (hoặc push với EFO), stream |
| Sau khi xử lý | **Xoá** | Không lưu | **Giữ lại** tới hết retention |
| Nhiều consumer đọc cùng dữ liệu | Không (mỗi message 1 consumer) | Có (mỗi subscriber một bản) | **Có**, mỗi consumer theo vị trí riêng |
| Replay | Không | Không | **Có** |
| Thứ tự | FIFO queue | FIFO topic | Theo shard/partition key |
| Scale | Tự động | Tự động | Theo shard (hoặc on-demand) |
| Use case | Job queue, decouple | Thông báo, fan-out | Clickstream, log, IoT telemetry, real-time analytics |

> 🎯 "Real-time, nhiều ứng dụng cùng đọc, đọc lại dữ liệu cũ" → **KDS**. "Nạp dữ liệu streaming vào S3/Redshift với ít vận hành nhất" → **Firehose** ("near real-time", buffer vài giây – vài phút). "Đang dùng Kafka, không muốn sửa code" → **MSK**.

---

## 6. AWS Lambda

### 6.1 Giới hạn quan trọng

| Thông số | Giá trị |
|---|---|
| Timeout | tối đa **15 phút** (900 giây) |
| Memory | **128 MB – 10.240 MB**; **CPU tăng tỷ lệ theo memory** (tới 6 vCPU) |
| `/tmp` (ephemeral storage) | 512 MB – 10 GB |
| Gói deploy | .zip **50 MB** (nén, upload trực tiếp) / **250 MB** (giải nén, gồm layer); **container image tới 10 GB** |
| Biến môi trường | tổng 4 KB |
| Payload | đồng bộ **6 MB**; bất đồng bộ 256 KB (AWS đã/đang nâng – kiểm tra doc) |
| Layers | tối đa 5/function |
| Concurrency | mặc định **1.000/Region/account** (xin tăng), mỗi function scale thêm ~1.000 instance mỗi 10 giây |

Giá: theo **số request** + **GB-giây** (memory × thời gian chạy, tính theo ms). Kiến trúc **arm64 (Graviton)** rẻ hơn x86.

> 💡 **Tăng memory có thể làm Lambda rẻ hơn**: CPU tăng theo memory → hàm chạy nhanh hơn → GB-giây có thể giảm. Dùng công cụ **AWS Lambda Power Tuning** để tìm cấu hình tối ưu.

### 6.2 Ba kiểu gọi (invocation)

| Kiểu | Ai gọi | Retry khi lỗi | Xử lý lỗi |
|---|---|---|---|
| **Synchronous** | API Gateway, ALB, Function URL, SDK `Invoke`, Cognito trigger | **Không tự retry** – caller nhận lỗi và tự quyết | Trả lỗi về client |
| **Asynchronous** | S3, SNS, EventBridge, CloudWatch Logs, SES… | Lambda tự retry **2 lần** (cấu hình 0–2), giữ event tối đa 6 giờ | **Destinations** (on-success / on-failure → SQS, SNS, Lambda, EventBridge, S3) hoặc DLQ (SQS/SNS) |
| **Event source mapping (poll)** | **SQS, Kinesis, DynamoDB Streams, MSK**, Amazon MQ | Lambda poll và gọi theo **batch** | SQS: message quay lại queue → DLQ của queue. Stream: retry tới khi thành công/hết hạn → *bisect batch*, *max retry attempts*, *max record age*, *on-failure destination* |

> ⚠️ Với **Kinesis/DynamoDB Streams**, một record lỗi làm **kẹt cả shard** (Lambda retry mãi để giữ thứ tự) → luôn cấu hình *bisect on error* + *maximum retry attempts* + *on-failure destination*. Với SQS: bật **ReportBatchItemFailures**.

### 6.3 Concurrency & cold start
- **Concurrency** = số instance chạy đồng thời ≈ request/giây × thời gian xử lý trung bình (giây). 500 req/s × 0,2 s = 100.
- **Reserved concurrency**: (1) giữ chỗ phần concurrency cho function quan trọng; (2) **đặt trần** để function không làm sập downstream (vd. DB chỉ chịu 50 kết nối → reserved = 50). Đặt 0 = tắt function.
- **Provisioned concurrency**: khởi động sẵn N môi trường → **không cold start** (tính phí khi bật), kết hợp Application Auto Scaling theo lịch.
- **Cold start**: lần đầu/scale-out phải tải code + khởi tạo runtime (vài trăm ms – vài giây, nặng với Java/.NET, gói lớn, gắn VPC thời xưa). Giảm: provisioned concurrency, **SnapStart** (Java, Python, .NET), giảm kích thước gói, khởi tạo client SDK **ngoài handler** để tái sử dụng giữa các lần gọi.
- Vượt concurrency → **throttle** (`429` với sync; async/poll thì Lambda tự retry).

### 6.4 Lambda trong VPC
- Gắn VPC để truy cập RDS, ElastiCache, tài nguyên private (Lambda tạo Hyperplane ENI trong subnet).
- Lambda trong VPC **không có public IP** (kể cả đặt ở public subnet) → muốn gọi Internet/API AWS public phải qua **NAT Gateway** (từ private subnet) hoặc **VPC endpoint**.
- Lambda **không gắn VPC** thì ra Internet được nhưng không vào được tài nguyên private.

### 6.5 Tính năng khác
- **Versions** (bất biến) & **Aliases** (con trỏ, vd. `prod` → v5); alias có **weighted routing** (90% v5, 10% v6) → canary; CodeDeploy tự động canary/linear + rollback theo alarm.
- **Layers**: chia sẻ thư viện/runtime giữa các function.
- **Environment variables** mã hoá bằng KMS; bí mật nên lấy từ Secrets Manager/Parameter Store (có *Parameters and Secrets Lambda Extension* để cache).
- **Function URL**: HTTPS endpoint riêng cho function, auth IAM hoặc public – đơn giản hơn API Gateway khi không cần tính năng quản lý API.
- **Response streaming**, **Lambda@Edge / CloudFront Functions** (chạy ở edge – tuần 6).
- Kết hợp RDS: **RDS Proxy** để tránh cạn connection.

### 6.6 Mẫu serverless điển hình
- **Web/API**: `CloudFront → S3 (frontend)` + `API Gateway → Lambda → DynamoDB`, Cognito xác thực.
- **Xử lý file**: `S3 upload → (SQS) → Lambda → S3/DynamoDB`.
- **Job queue**: `API → SQS → Lambda (batch) → DB`, DLQ + alarm.
- **Lịch**: `EventBridge Scheduler → Lambda`.
- **Stream**: `Kinesis → Lambda → DynamoDB/S3`; `DynamoDB Streams → Lambda → OpenSearch` (đồng bộ chỉ mục tìm kiếm).
- **Workflow**: `Step Functions` điều phối nhiều Lambda + dịch vụ.

> 💡 **Kinh nghiệm thực tế – Lambda**
> - Bật **X-Ray/structured logging**; đặt **log retention** cho CloudWatch Logs group (mặc định "Never expire" → tiền log tăng mãi).
> - Đặt timeout sát với thực tế (không để mặc định 3 giây cho tác vụ gọi API ngoài, cũng không để 15 phút cho mọi thứ).
> - Dùng **reserved concurrency** như "van an toàn" bảo vệ DB/API bên thứ ba.
> - Hàm gọi hàm đồng bộ (Lambda → Lambda) là anti-pattern: trả tiền 2 lần thời gian chờ. Dùng Step Functions hoặc queue.
> - Tác vụ > 15 phút hoặc cần chạy liên tục → **Fargate/ECS task, AWS Batch**, hoặc chia nhỏ bằng Step Functions (Distributed Map).

---

## 7. Amazon API Gateway

| Loại | Tính năng | Khi nào |
|---|---|---|
| **REST API** | Đầy đủ: API key + **usage plan** (quota/throttle theo khách hàng), request validation, mapping template, **cache**, **WAF**, resource policy, private endpoint, canary | API cho khách hàng/đối tác, cần quản lý API |
| **HTTP API** | Đơn giản, **rẻ hơn** (~70%), độ trễ thấp; JWT authorizer (Cognito/OIDC), Lambda authorizer, IAM; **không** có cache, usage plan, WAF trực tiếp | Proxy tới Lambda/HTTP, API nội bộ đơn giản |
| **WebSocket API** | Kết nối 2 chiều lâu dài, route theo message | Chat, game, dashboard real-time |

- **Endpoint type**: *Edge-optimized* (đi qua mạng CloudFront, client toàn cầu; cert custom domain ở **us-east-1**), *Regional* (client cùng Region hoặc tự đặt CloudFront phía trước; cert cùng Region), *Private* (chỉ truy cập từ VPC qua **interface endpoint `execute-api`** + resource policy).
- **Throttling**: mặc định **10.000 request/giây/Region/account**, burst **5.000**; giới hạn thêm theo stage/method/usage plan → client nhận `429 Too Many Requests`.
- **Caching** (REST): 0,5–237 GB, TTL mặc định **300 giây** (tối đa 3.600), theo stage.
- **Timeout tích hợp** mặc định tối đa **29 giây** (REST Regional/Private có thể xin tăng) → tác vụ dài: trả về ngay `202 Accepted` + xử lý bất đồng bộ qua SQS/Step Functions, client poll hoặc nhận WebSocket/webhook.
- **Authorizer**: **IAM** (SigV4 – client là dịch vụ AWS/ứng dụng có credential), **Cognito User Pool** (người dùng app), **Lambda authorizer** (token/logic tuỳ chỉnh, bên thứ ba).
- **Tích hợp**: Lambda (proxy), HTTP, **dịch vụ AWS trực tiếp** (vd. PutItem DynamoDB, SendMessage SQS **không cần Lambda**), mock, VPC link (tới NLB/ALB private).
- **Stage** + **stage variables**, **canary release**, export OpenAPI.

> 🎯 "Giới hạn số request theo từng khách hàng/API key, bán gói API" → **REST API + usage plan**. "API rẻ nhất, độ trễ thấp, proxy tới Lambda" → **HTTP API**. "Chống SQLi cho API" → **REST API + WAF**. "API chỉ gọi được từ trong VPC" → **Private REST API**.

---

## 8. Step Functions & các dịch vụ workflow/tích hợp khác

### 8.1 Step Functions
- Điều phối workflow bằng **state machine** (định nghĩa bằng Amazon States Language/JSON, có giao diện kéo thả Workflow Studio).
- State: **Task** (gọi Lambda hoặc **200+ dịch vụ AWS trực tiếp** qua SDK integration), **Choice** (rẽ nhánh), **Parallel**, **Map** (lặp song song; *Distributed Map* xử lý hàng triệu object S3), **Wait**, **Pass**, **Succeed/Fail**.
- **Retry** (với backoff) và **Catch** (bắt lỗi chuyển nhánh bù trừ) khai báo, không cần code → mẫu **Saga** (bù trừ khi một bước thất bại).
- **Callback / task token** (`.waitForTaskToken`): chờ con người phê duyệt hoặc hệ thống ngoài trả lời (tới 1 năm). **`.sync`**: chờ job (Batch, ECS, Glue) chạy xong.

| | **Standard** | **Express** |
|---|---|---|
| Thời gian tối đa | **1 năm** | **5 phút** |
| Ngữ nghĩa | **Exactly-once** | At-least-once (async) / at-most-once (sync) |
| Thông lượng | Vừa | Rất cao (hàng trăm nghìn/giây) |
| Tính phí | Theo state transition | Theo số lần chạy + thời gian + memory |
| Lịch sử | Lưu & xem trên console 90 ngày | Gửi CloudWatch Logs |
| Dùng khi | Quy trình nghiệp vụ dài, phê duyệt, ETL | Xử lý sự kiện khối lượng lớn, IoT, microservice ngắn |

### 8.2 Khác
- **Amazon MQ**: ActiveMQ/RabbitMQ managed – dùng khi **di chuyển** ứng dụng đang dùng giao thức **AMQP, MQTT, STOMP, OpenWire, JMS** mà **không muốn viết lại**. Chạy trên broker (active/standby 2 AZ), không scale "vô hạn" như SQS/SNS.
- **AppSync**: GraphQL managed (+ real-time subscription, offline sync cho mobile).
- **AWS Batch**: chạy job batch (container) trên EC2/Spot/Fargate, tự quản hàng đợi job và compute environment – job dài, HPC, không giới hạn 15 phút.
- **SWF**: workflow thế hệ cũ (đề mới hầu như chọn Step Functions).
- **Amazon AppFlow**: đồng bộ dữ liệu từ SaaS (Salesforce, SAP, Slack…) vào S3/Redshift không cần code.

> 🎯 "Workflow nhiều bước, có retry/rẽ nhánh/chờ phê duyệt, ít code" → **Step Functions**. "App on-prem dùng RabbitMQ/ActiveMQ, chuyển lên AWS ít sửa code nhất" → **Amazon MQ**. "Job xử lý vài giờ, chạy theo lô, rẻ" → **AWS Batch (Spot)**.

---

## 9. Container

| Dịch vụ | Mô tả |
|---|---|
| **ECS** | Điều phối container của AWS – đơn giản, tích hợp sâu với ALB, IAM, CloudWatch |
| **EKS** | **Kubernetes** managed (control plane do AWS chạy đa AZ) – chuẩn K8s, hệ sinh thái lớn, đa cloud/hybrid |
| **Fargate** | Compute **serverless** cho ECS/EKS: không quản lý EC2, trả theo vCPU/memory của task/pod |
| **ECR** | Registry image private/public, quét lỗ hổng (basic / enhanced qua Inspector), lifecycle policy xoá image cũ, replication cross-Region/account |
| **App Runner** | Chạy web/API từ source code hoặc image, tự build/deploy/scale/HTTPS – đơn giản nhất |

### 9.1 Khái niệm ECS
- **Task definition**: "bản thiết kế" (image, CPU/memory, port, biến môi trường, secret, log, IAM role).
- **Task**: một bản chạy của task definition (một hoặc nhiều container).
- **Service**: duy trì N task chạy liên tục, thay task hỏng, gắn ALB, rolling/blue-green deploy (CodeDeploy).
- **Cluster**: nhóm logic; **capacity provider** quyết định chạy trên Fargate, Fargate Spot hay ASG EC2.
- **Launch type**: **EC2** (bạn quản lý instance – rẻ hơn khi tải lớn ổn định, cần GPU/daemon/tuỳ biến) vs **Fargate** (không quản lý server).
- **Network mode `awsvpc`**: mỗi task một ENI/IP riêng, SG riêng (bắt buộc với Fargate).
- **IAM**: **Task role** = quyền của **ứng dụng** trong container (gọi S3, DynamoDB…). **Task execution role** = quyền của **agent ECS** (kéo image ECR, đọc secret, ghi CloudWatch Logs).
- **Auto scaling**: *Service auto scaling* (số task theo CPU/memory/ALB request count/SQS) + *cluster auto scaling* (số EC2 qua capacity provider).
- **Lưu trữ bền** cho task: **EFS** (cả Fargate). Fargate có ephemeral storage 20–200 GiB.
- **Fargate Spot**: rẻ hơn nhiều, có thể bị thu hồi (cảnh báo 2 phút, SIGTERM).

### 9.2 EKS
- Node: **managed node groups** (EC2, AWS lo vòng đời), self-managed, **Fargate profile**, **Karpenter** (autoscaler nhanh, chọn instance tối ưu), **EKS Auto Mode** (AWS quản cả node).
- Quyền cho pod: **IRSA** (IAM Roles for Service Accounts) / **EKS Pod Identity**.
- Lưu trữ: EBS CSI (1 AZ), EFS CSI (dùng chung đa AZ).
- Phí control plane theo giờ mỗi cluster.

### 9.3 Chọn dịch vụ chạy code

| Tình huống | Chọn |
|---|---|
| Hàm ngắn (< 15 phút), theo sự kiện, tải thưa/bùng nổ | **Lambda** |
| Container, không muốn quản server | **ECS/EKS trên Fargate** |
| Đã dùng Kubernetes, cần tương thích/đa cloud | **EKS** |
| Container đơn giản trên AWS, ít khái niệm | **ECS** |
| Web app từ source, ít cấu hình nhất | **App Runner** / **Elastic Beanstalk** |
| Cần GPU, kiểm soát OS, tải lớn ổn định tối ưu giá | **ECS/EKS trên EC2** (Spot/SP) |
| Job batch dài | **AWS Batch** |

### 9.4 Dịch vụ triển khai & vận hành liên quan
- **Elastic Beanstalk**: PaaS – upload code (Java, .NET, Node, Python, PHP, Go, Docker), Beanstalk dựng EC2/ASG/ELB/CloudWatch. Bạn vẫn có quyền vào tài nguyên bên dưới. Môi trường *web* và *worker* (worker đọc từ SQS).
  Chế độ deploy: **All at once** (nhanh, downtime), **Rolling**, **Rolling with additional batch** (giữ đủ công suất), **Immutable** (dựng ASG mới, rollback an toàn nhất), **Traffic splitting** (canary), **Blue/Green** (môi trường mới + **swap URL**).
- **CloudFormation**: IaC (YAML/JSON) – stack, **change set** (xem trước thay đổi), **StackSets** (triển khai nhiều account/Region), **drift detection**, `DeletionPolicy: Retain/Snapshot` (giữ DB/bucket khi xoá stack), nested stacks. **CDK**: viết IaC bằng TypeScript/Python… sinh ra CloudFormation.
- **Systems Manager**: Session Manager (thay SSH), Patch Manager, Run Command, State Manager, **Parameter Store**, Automation runbook, Inventory.
- **X-Ray / CloudWatch Application Signals**: distributed tracing qua nhiều dịch vụ.

---

## 10. Bẫy thường gặp
1. "Xử lý bất đồng bộ, không mất message, scale độc lập" → **SQS** giữa các tầng.
2. "Một sự kiện → nhiều hệ thống xử lý độc lập" → **SNS fan-out (SNS + nhiều SQS)** hoặc EventBridge.
3. "Thứ tự nghiêm ngặt + không trùng" → **SQS FIFO** (thứ tự theo message group).
4. "Message độc không xử lý được, ngăn lặp vô hạn" → **DLQ** (+ alarm).
5. "Streaming real-time, nhiều consumer, replay" → **Kinesis Data Streams**; "đẩy vào S3/Redshift gần real-time, ít vận hành" → **Firehose**.
6. "Cron không cần server" → **EventBridge Scheduler + Lambda**.
7. Lambda > 15 phút → Step Functions (chia nhỏ) / Fargate / Batch.
8. Lambda cold start → **Provisioned Concurrency** / SnapStart.
9. "Di chuyển app dùng AMQP/MQTT/JMS mà không sửa code" → **Amazon MQ**.
10. "Lambda làm quá tải RDS" → **RDS Proxy** (+ reserved concurrency).
11. "Message bị xử lý nhiều lần" → visibility timeout quá ngắn / consumer không xoá message / Standard queue → tăng timeout, idempotent, hoặc FIFO.
12. "Giảm chi phí do polling SQS rỗng" → **long polling** (`WaitTimeSeconds` = 20).
13. "Message > 256 KB" → lưu S3 + con trỏ (SQS Extended Client).
14. "Container cần quyền gọi S3" → **task role** (không phải execution role, không nhúng key).
15. "Lambda trong VPC không gọi được API ngoài" → private subnet + **NAT Gateway** (hoặc VPC endpoint cho dịch vụ AWS).
16. "API Gateway timeout với tác vụ dài" → mô hình bất đồng bộ (202 + SQS/Step Functions).
17. "Phản ứng khi có API call nhạy cảm (vd. xoá bucket)" → **CloudTrail → EventBridge rule → Lambda/SNS**.

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
9. Lambda timeout 30 giây đọc từ SQS. Visibility timeout tối thiểu nên là bao nhiêu?
10. Một hàm Lambda xử lý Kinesis bị lỗi ở một record và cả shard đứng im. Vì sao và cách xử lý?
11. Phân biệt reserved concurrency và provisioned concurrency.
12. Task role và task execution role trong ECS khác nhau thế nào?
13. Ứng dụng cần đảm bảo đơn hàng của cùng khách hàng xử lý đúng thứ tự, nhưng tổng thông lượng cao. Cấu hình SQS thế nào?
14. Step Functions Standard hay Express cho quy trình phê duyệt khoản vay mất 3 ngày?
15. Bạn cần tự động cô lập EC2 khi GuardDuty phát hiện đào coin. Luồng sự kiện?

<details><summary>Đáp án</summary>

1. Thông lượng (gần như không giới hạn vs 300/3.000 msg/s), thứ tự (best-effort vs FIFO theo group), giao (at-least-once vs exactly-once processing). Tên FIFO kết thúc `.fifo`.
2. Ẩn message khỏi consumer khác khi đang xử lý. Quá nhỏ → message hiện lại khi chưa xử lý xong → xử lý trùng, có thể rơi vào DLQ oan.
3. S3 Event → SNS topic → 3 SQS queue (thumbnail, metadata, email) → mỗi queue 1 Lambda consumer, mỗi queue có DLQ. (Hoặc S3 → EventBridge → nhiều target.)
4. Cần nhiều consumer đọc cùng dữ liệu, giữ lại/replay, thứ tự theo partition key, luồng dữ liệu liên tục tốc độ cao (clickstream, telemetry).
5. 15 phút. Provisioned Concurrency, SnapStart, giảm kích thước package, khởi tạo client ngoài handler.
6. Fargate không phải quản lý/patch/scale cụm EC2; trả theo vCPU/memory của task. EC2 launch type: bạn quản lý instance, tận dụng RI/Spot, GPU, tuỳ biến.
7. Lọc để mỗi subscriber chỉ nhận message khớp thuộc tính/nội dung.
8. REST: cần API key/usage plan, validation, cache, WAF, private endpoint… HTTP API: đơn giản, rẻ, độ trễ thấp, JWT auth.
9. ≥ 6 × 30 = **180 giây** (cộng thêm batching window nếu có).
10. Với stream, Lambda retry batch lỗi cho tới khi thành công/hết hạn để giữ thứ tự → shard bị kẹt. Bật *bisect batch on function error*, giới hạn *maximum retry attempts*/*maximum record age*, cấu hình *on-failure destination* (SQS/SNS) để bỏ qua record độc.
11. Reserved: giữ chỗ và **đặt trần** concurrency cho function (miễn phí). Provisioned: **khởi động sẵn** môi trường để tránh cold start (tính phí).
12. Task role: quyền của code ứng dụng gọi dịch vụ AWS. Execution role: quyền của ECS agent để kéo image, lấy secret, ghi log.
13. **SQS FIFO** với `MessageGroupId = customerId` (nhiều group xử lý song song); bật high throughput mode nếu cần.
14. **Standard** (chạy tới 1 năm, có callback task token chờ phê duyệt). Express chỉ 5 phút.
15. GuardDuty finding → **EventBridge rule** (lọc loại finding) → Lambda/SSM Automation: đổi SG của instance sang SG cô lập, snapshot EBS để điều tra, gửi SNS thông báo.
</details>

## Tài liệu nên đọc thêm
- FAQ: SQS, SNS, EventBridge, Kinesis Data Streams, Data Firehose, Lambda, API Gateway, Step Functions, ECS, Fargate.
- Doc: "Amazon SQS visibility timeout", "Using Lambda with Amazon SQS", "Lambda concurrency", "Lambda event source mappings – error handling", "Choosing between REST APIs and HTTP APIs", "Choosing workflow type in Step Functions".
- Serverless Land (serverlessland.com) – thư viện pattern serverless có sơ đồ.
