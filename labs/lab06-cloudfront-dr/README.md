# Lab 06 – CloudFront + OAC, Origin Group failover, S3 Cross-Region Replication (DR), Budget

**Thời gian:** ~75 phút (CloudFront deploy mất 5–15 phút mỗi lần đổi cấu hình) | **Chi phí:** gần như 0 nếu làm trong ngày. CloudFront không tính phí theo giờ và có free tier hằng tháng (1 TB ra Internet, 10 triệu request – tài khoản "Free plan" mới có thể khác, xem Billing); S3 chỉ vài KB; truyền dữ liệu liên Region không đáng kể. Lab **cố ý không dùng** WAF, Route 53, domain riêng, Global Accelerator vì có phí cố định.
**Liên quan lý thuyết:** `theory/week6-resilience-dr-cost.md` (mục 2, 4, 6)

## Mục tiêu
- Phục vụ nội dung qua **CloudFront** với S3 **không public**, chỉ nhận request từ distribution nhờ **OAC**.
- Tạo bản sao dữ liệu sang **Region DR** bằng **S3 Cross-Region Replication (CRR)**.
- Cấu hình **Origin Group**: origin chính bị lỗi → CloudFront tự đọc bản ở Region DR (mô hình *Pilot Light/Warm Standby* cho tầng nội dung tĩnh).
- Giảm chi phí: **Price class 100**; xác nhận **AWS Budget** đã có (làm ở phần chuẩn bị trong README gốc).

> Lab dùng **2 Region**: `AWS_REGION` (mặc định `ap-southeast-1`) là origin, `DR_REGION` (mặc định `ap-southeast-2`) là DR.
> Đổi DR: `export DR_REGION=ap-northeast-1` (phải khác `AWS_REGION`, và dùng **cùng giá trị** khi chạy `verify.sh`/`cleanup.sh`).

## Quy ước tên (BẮT BUỘC)
`<ACCOUNT_ID>` là 12 chữ số account của bạn (`aws sts get-caller-identity --query Account --output text`).

| Tài nguyên | Tên |
|---|---|
| Bucket origin (AWS_REGION) | **`saa-lab06-<ACCOUNT_ID>-origin`** |
| Bucket DR (DR_REGION) | **`saa-lab06-<ACCOUNT_ID>-dr`** |
| CloudFront distribution | trường **Description (Comment) = `saa-lab06-cdn`** |
| Origin Access Control | **`saa-lab06-oac`** |
| IAM role cho replication | để Console tự tạo (`s3crr_role_for_saa-lab06-...`) |

## Bước 1 – Hai bucket
Tạo **cả hai** bucket với: **Versioning bật** (CRR bắt buộc), **Block all public access = ON** (mặc định), mã hoá mặc định SSE-S3.
- `saa-lab06-<ACCOUNT_ID>-origin` ở `AWS_REGION`
- `saa-lab06-<ACCOUNT_ID>-dr` ở `DR_REGION`

## Bước 2 – Replication (origin → DR)
Bucket origin → **Management → Replication rules → Create**:
1. Rule scope: **All objects**. Destination: bucket DR (cùng account).
2. IAM role: **Create new role**.
3. **Không** tick *Delete marker replication* (mặc định đang tắt – hãy để vậy; lý do ở phần "Thử phá").
4. Hỏi *Replicate existing objects?* → **No**.

## Bước 3 – CloudFront
1. Create distribution. Origin domain: chọn bucket **origin** (kiểu S3 bucket – **không** chọn "static website endpoint").
2. **Origin access → Origin access control settings** → Create new OAC tên `saa-lab06-oac` (sign requests: Always).
3. Viewer protocol policy: **Redirect HTTP to HTTPS**. Default root object: **`index.html`**.
4. **Price class: Use only North America and Europe** (= `PriceClass_100`). **WAF: không bật.**
5. Description: **`saa-lab06-cdn`**. Tạo xong **chép lại Distribution ID** và Domain name `dxxxx.cloudfront.net`.
6. Tab **Origins → Create origin**: thêm bucket **DR** với **cùng OAC** `saa-lab06-oac`.
7. Tab **Origins → Create origin group**: primary = origin bucket, secondary = DR bucket. Failover criteria: tick **403, 404, 500, 502, 503, 504**.
   > Vì sao có cả 403 *và* 404? Với OAC, bucket policy thường chỉ cấp `s3:GetObject` (không `s3:ListBucket`) nên object không tồn tại trả về **403**, không phải 404.
8. Tab **Behaviors → Default (*) → Edit**: đổi *Origin and origin groups* sang **origin group** vừa tạo.
9. **Bucket policy cho CẢ HAI bucket** (Console đôi khi chỉ tự cập nhật bucket đầu tiên). Thay `<BUCKET>`, `<ACCOUNT_ID>`, `<DISTRIBUTION_ID>`:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipalReadOnly",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::<BUCKET>/*",
    "Condition": { "StringEquals": {
      "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DISTRIBUTION_ID>" } }
  }]
}
```
Chờ trạng thái distribution = **Deployed**.

## Bước 4 – Thử tay
```bash
echo '<h1>SAA lab06</h1>' > index.html
aws s3 cp index.html s3://saa-lab06-<ACCOUNT_ID>-origin/index.html
curl -i https://<domain>.cloudfront.net/                      # 200 (lần đầu: X-Cache: Miss from cloudfront)
curl -i https://<domain>.cloudfront.net/                      # lần hai: X-Cache: Hit from cloudfront
curl -i https://saa-lab06-<ACCOUNT_ID>-origin.s3.<REGION>.amazonaws.com/index.html   # 403 – không đi vòng qua CloudFront được
aws s3 ls s3://saa-lab06-<ACCOUNT_ID>-dr/ --region <DR_REGION>   # index.html xuất hiện sau vài giây–vài phút
```

## Bước 5 – Budget (từ phần chuẩn bị)
`verify.sh` kiểm tra bạn **đã có** ít nhất 1 Budget loại COST với ≥ 3 ngưỡng cảnh báo (50/80/100%). Chưa có thì tạo ngay: Billing → Budgets → Create budget → *Monthly cost budget*. **Lab này không xoá Budget** (cleanup chỉ xoá tài nguyên `saa-lab06-*`).
Cũng nên kiểm tra tay: Billing preferences → *Receive Free Tier usage alerts* (CLI không kiểm tra được mục này).

## Thử phá (rất đáng làm – chính là một "game day" nhỏ)
1. Upload `dr-demo.txt` vào bucket origin, chờ nó xuất hiện ở bucket DR.
2. **Xoá** `dr-demo.txt` ở bucket origin (versioning bật nên chỉ sinh *delete marker*; delete marker **không** được replicate vì bạn đã tắt tuỳ chọn đó).
3. `curl -i https://<domain>/dr-demo.txt` → vẫn **200**: primary trả 404/403 → CloudFront chuyển sang secondary ở Region DR.
4. Bật thử *Delete marker replication* rồi lặp lại: DR cũng mất → failover thất bại. Bài học: replication **không phải backup**; muốn chống xoá nhầm cần versioning/backup riêng.
5. Với object đã được cache, CloudFront trả bản cache dù origin đã mất – muốn thấy ngay cần **invalidation** `/dr-demo.txt` hoặc dùng tên file có version (đúng "bẫy" số 5 của week6).

## Đọc thêm (không có lab)
- **Route 53 failover + health check** để chuyển DNS giữa hai Region cho ứng dụng động; **Global Accelerator** khi cần 2 IP anycast tĩnh, giao thức TCP/UDP.
- **Signed URL/cookies** cho nội dung trả phí; **geo restriction**; chứng chỉ ACM cho CloudFront phải tạo ở **us-east-1**.
- **AWS Backup** (cross-Region/cross-account copy, Vault Lock) và **Aurora Global Database / DynamoDB Global Tables** cho tầng dữ liệu – hai lab này không dùng vì chi phí.

## Câu hỏi
1. Vì sao cần bật Versioning trên cả hai bucket để dùng CRR? Replication có chép các object đã tồn tại trước khi tạo rule không?
2. OAC khác OAI chỗ nào? Điều kiện `AWS:SourceArn` trong bucket policy ngăn chặn kịch bản nào?
3. Vì sao origin group cần failover cả mã 403 lẫn 404?
4. Chiến lược DR của lab này gần *Pilot Light*, *Warm Standby* hay *Backup & Restore*? RPO/RTO ước lượng thế nào?
5. Hai cách để làm CloudFront phục vụ ngay bản mới của một file đã cache?
6. Vì sao lab chọn Price Class 100 và vì sao không đặt WAF?

## Verify & Cleanup
```bash
bash verify.sh       # chấm cấu hình + thử thật: upload, chờ replicate, kiểm tra truy cập trực tiếp S3, kiểm tra failover
bash cleanup.sh      # Disable → chờ Deployed → xoá distribution, OAC, 2 bucket, role replication (mất ~10–20 phút vì chờ CloudFront)
```
`verify.sh` ghi 2 object thử nghiệm `verify-<timestamp>-*.txt` vào bucket origin và tự xoá lại (kể cả delete marker) khi xong.
