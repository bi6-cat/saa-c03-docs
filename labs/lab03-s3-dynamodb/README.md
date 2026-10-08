# Lab 03 – S3 an toàn + lifecycle, và DynamoDB (GSI, TTL, PITR)

**Thời gian:** ~60 phút (+~45 phút phần nâng cao) | **Chi phí:** ≈ 0 (dung lượng cực nhỏ, DynamoDB on-demand)
**Liên quan lý thuyết:** `theory/week3-storage-database.md`

> RDS/Aurora Multi-AZ **không** làm lab ở đây vì tốn tiền theo giờ. Đọc lý thuyết + xem demo; nếu muốn thử: 1 RDS `db.t4g.micro` Single-AZ vài giờ rồi **xoá ngay (bỏ cả final snapshot)**.

## Phần A – S3 bucket

### Tên (BẮT BUỘC)
Bucket: **`saa-lab03-<ACCOUNT_ID>`** (12 chữ số account – chạy `aws sts get-caller-identity --query Account --output text`). Region: region của bạn (`$AWS_REGION`).

### Yêu cầu cấu hình
1. **Block all public access**: bật cả 4 tuỳ chọn.
2. **Versioning**: Enabled.
3. **Default encryption**: SSE-S3 hoặc SSE-KMS (thử SSE-KMS với AWS managed key `aws/s3`; để mặc định SSE-S3 cũng đạt).
4. **Lifecycle rule** (tên bất kỳ, áp dụng cho cả bucket, Enabled):
   - Chuyển *current version* sang **Standard-IA** sau **≥ 30 ngày**.
   - Xoá *noncurrent versions* sau **≤ 90 ngày** (noncurrent expiration).
   - (Bonus) Abort incomplete multipart upload sau 7 ngày.
5. **Bucket policy** từ chối truy cập không dùng TLS:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::saa-lab03-<ACCOUNT_ID>", "arn:aws:s3:::saa-lab03-<ACCOUNT_ID>/*"],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}
```

### Thử tay
```bash
B=saa-lab03-$(aws sts get-caller-identity --query Account --output text)
echo v1 > f.txt && aws s3 cp f.txt s3://$B/demo/f.txt
echo v2 > f.txt && aws s3 cp f.txt s3://$B/demo/f.txt
aws s3api list-object-versions --bucket $B --prefix demo/f.txt   # thấy 2 version
aws s3 rm s3://$B/demo/f.txt                                       # tạo delete marker
aws s3api list-object-versions --bucket $B --prefix demo/f.txt   # DeleteMarkers + 2 version vẫn còn
```
Quan sát: xoá khi bật versioning chỉ thêm *delete marker*; có thể khôi phục bằng cách xoá marker.

## Phần B – DynamoDB

### Tên (BẮT BUỘC)
Bảng **`saa-lab03-orders`**
- Partition key: **`customerId`** (String); Sort key: **`orderId`** (String)
- Capacity mode: **On-demand**
- **GSI** tên **`status-index`**: Partition key **`status`** (String), Sort key **`createdAt`** (String)
- **TTL** bật trên attribute **`expireAt`**
- **Point-in-time recovery (PITR)**: bật
- Encryption: mặc định (AWS owned) là đủ

### Thử tay
```bash
aws dynamodb put-item --table-name saa-lab03-orders --item '{
 "customerId":{"S":"c-1"},"orderId":{"S":"o-1"},"status":{"S":"NEW"},
 "createdAt":{"S":"2026-01-01T00:00:00Z"},"expireAt":{"N":"4102444800"}}'
aws dynamodb query --table-name saa-lab03-orders \
  --key-condition-expression "customerId = :c" --expression-attribute-values '{":c":{"S":"c-1"}}'
aws dynamodb query --table-name saa-lab03-orders --index-name status-index \
  --key-condition-expression "#s = :s" --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"NEW"}}'
```
Hỏi: vì sao `status` phải đặt alias `#s`? (`status` là reserved word). Truy vấn theo `status` mà không có GSI sẽ phải làm gì? (Scan – tốn kém.)

## Câu hỏi
1. Vì sao bật versioning mà vẫn cần lifecycle cho noncurrent versions?
2. Standard → Standard-IA bị ràng buộc tối thiểu bao nhiêu ngày? Còn Glacier Deep Archive?
3. LSI khác GSI? Có thêm LSI sau khi tạo bảng được không?
4. On-demand vs Provisioned: khi nào chọn cái nào?
5. Nếu muốn bucket này sao chép sang Region khác, cần điều kiện gì? (xem Lab 06)

---

## PHẦN NÂNG CAO (chấm bằng `bash verify.sh --advanced`)

Các chủ đề này lặp đi lặp lại trong đề thi (S3 event-driven, chia sẻ tạm thời, tối ưu chi phí dữ liệu lạnh, DynamoDB nhất quán dữ liệu).

### N1. Tắt ACL (Object Ownership)
Bucket → Permissions → **Object Ownership → ACLs disabled (Bucket owner enforced)**.
Hỏi: vì sao AWS khuyên tắt ACL và dùng bucket policy/IAM? (một cơ chế phân quyền duy nhất, chủ bucket luôn sở hữu object.)

### N2. Lifecycle cho dữ liệu "lạnh" – thêm rule thứ hai
Rule tên bất kỳ, **Filter prefix = `logs/`**:
- Chuyển sang **Glacier Flexible Retrieval** (hoặc Glacier Instant Retrieval / Deep Archive) sau **≥ 90 ngày**.
- **Expiration** (xoá hẳn) sau số ngày **lớn hơn** ngày chuyển lớp, ví dụ **365**.

> Ghi nhớ: Standard-IA tối thiểu 30 ngày trước khi chuyển từ Standard; mỗi lớp lạnh có thời gian lưu tối thiểu và phí truy xuất – chuyển quá sớm rồi xoá sớm vẫn bị tính phí đủ thời gian tối thiểu.

### N3. S3 Event Notification → SQS
1. Tạo SQS queue **`saa-lab03-events`** (Standard).
2. Sửa **access policy** của queue cho phép S3 gửi, **giới hạn theo bucket của bạn**:
```json
{ "Version": "2012-10-17", "Statement": [{
  "Effect": "Allow", "Principal": { "Service": "s3.amazonaws.com" },
  "Action": "sqs:SendMessage", "Resource": "<ARN queue saa-lab03-events>",
  "Condition": { "ArnEquals": { "aws:SourceArn": "arn:aws:s3:::saa-lab03-<ACCOUNT_ID>" } } }] }
```
3. Bucket → Properties → **Event notifications → Create**: event type **All object create events**, **prefix `uploads/`**, đích **SQS queue** `saa-lab03-events`.
4. Thử: `aws s3 cp f.txt s3://$B/uploads/a.txt`, rồi `aws sqs receive-message --queue-url <url> --wait-time-seconds 10` → thấy JSON `Records[0].s3.object.key`.
Hỏi: khi nào chọn SQS, SNS, Lambda hay **EventBridge** làm đích? (EventBridge: lọc nâng cao, nhiều đích, archive/replay.)

### N4. Pre-signed URL
```bash
aws s3 cp f.txt s3://$B/verify/presign.txt
aws s3 presign s3://$B/verify/presign.txt --expires-in 60      # URL có chữ ký
curl "<URL ở trên>"                       # tải được dù không có credential
curl "<URL bỏ phần ?X-Amz-...>"           # 403
```
Hỏi: pre-signed URL kế thừa quyền của ai? (quyền của **người ký**; hết hạn khi URL hết hạn **hoặc** credential ký (vd. role session) hết hạn trước.) Khác gì CloudFront signed URL?

### N5. DynamoDB nâng cao
1. Bật **DynamoDB Streams** với **New and old images** (Table → Exports and streams).
2. Thử **ghi có điều kiện** (chống ghi đè / idempotent):
```bash
aws dynamodb put-item --table-name saa-lab03-orders --condition-expression "attribute_not_exists(orderId)" --item '{...}'   # lần 2 → ConditionalCheckFailedException
```
3. Thử **transaction** (`transact-write-items`) gồm 2 `Put`, trong đó một cái có `ConditionExpression` sai → cả hai bị huỷ (all-or-nothing). `verify.sh --advanced` tự làm bước 2–3.

Hỏi thêm: Streams khác Kinesis Data Streams for DynamoDB ở đâu? (Streams: 24 giờ, thứ tự theo item, tích hợp Lambda; KDS: lưu tới 1 năm, nhiều consumer.) Khi nào dùng **DAX** (cache vi giây, đọc) và **Global Tables** (đa Region active-active, cần Streams)?

### Câu hỏi nâng cao
6. Event notification tới SQS và tới EventBridge khác gì về bảo đảm và khả năng lọc?
7. Bật versioning + Object Lock (Compliance) khác gì so với chỉ bật versioning? (Object Lock phải bật khi tạo bucket – WORM, không xoá được tới hết retention.)
8. Transaction tốn gấp đôi WCU/RCU – khi nào đáng dùng, khi nào chỉ cần conditional write?

## Verify & Cleanup
```bash
bash verify.sh               # cấu hình cơ bản + ghi/xoá vài object & item thử nghiệm (tự dọn)
bash verify.sh --advanced    # thêm phần nâng cao N1–N5
bash cleanup.sh
```
