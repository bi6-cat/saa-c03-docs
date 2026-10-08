# Lab 05 – Security: KMS CMK, Secrets Manager, IAM least-privilege, CloudTrail

**Thời gian:** ~60 phút | **Chi phí:** rất nhỏ nhưng **không phải 0**: KMS key ≈ 1 USD/tháng (tính theo tỉ lệ), secret ≈ 0,40 USD/tháng. Làm xong trong ngày rồi `cleanup.sh`. CloudTrail trail đầu tiên cho management events miễn phí; chỉ tốn lưu trữ S3 rất nhỏ.
**Liên quan lý thuyết:** `theory/week5-security.md`

## Mục tiêu
- Tạo **customer managed KMS key** (rotation bật) và mã hoá một **secret** bằng nó.
- Tạo **IAM role least-privilege**: chỉ đọc đúng 1 secret, không hơn.
- Bật **CloudTrail** đa Region với log file validation.
- Hiểu cách **chứng minh** quyền hẹp: verify.sh thực sự `assume-role` và thử đọc/bị từ chối.

> Yêu cầu: bạn đăng nhập CLI bằng **IAM user/Identity Center có quyền admin** (không dùng root) để `sts:AssumeRole` và `iam:SimulatePrincipalPolicy` được.

## Quy ước tên (BẮT BUỘC)
| Tài nguyên | Tên |
|---|---|
| KMS key | alias **`alias/saa-lab05-key`** (symmetric, encrypt/decrypt) |
| Secret | **`saa-lab05/db-credentials`** |
| IAM role | **`saa-lab05-app-role`** |
| CloudTrail trail | **`saa-lab05-trail`** |

## Bước 1 – KMS
1. KMS → Customer managed keys → Create key: **Symmetric**, **Encrypt and decrypt**.
2. Alias `saa-lab05-key`. Key administrators / users: chính bạn (Console mặc định thêm policy cho phép IAM policy điều khiển key – đó là lý do identity policy sau này có hiệu lực).
3. Mở key → **Key rotation → Enable automatic key rotation**.

## Bước 2 – Secrets Manager
1. Store a new secret → *Other type of secret* → key/value tuỳ ý (vd. `username=app`, `password=...` – giá trị giả).
2. **Encryption key: chọn `alias/saa-lab05-key`** (không dùng `aws/secretsmanager`).
3. Tên secret: `saa-lab05/db-credentials`. Bỏ qua rotation (lý thuyết: Secrets Manager hỗ trợ rotation tự động, Parameter Store thì không).

## Bước 3 – IAM Role least privilege
1. Create role → Trusted entity: **AWS account → This account** (để verify có thể `assume-role`. Với app thật bạn sẽ tin cậy `ec2.amazonaws.com`/`lambda.amazonaws.com`).
2. Tên `saa-lab05-app-role`. Không gắn managed policy. Thêm **inline policy**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:<REGION>:<ACCOUNT_ID>:secret:saa-lab05/db-credentials-*"
    },
    {
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "<ARN của KMS key saa-lab05-key>"
    }
  ]
}
```
(Hậu tố `-*` vì ARN secret có 6 ký tự ngẫu nhiên ở cuối. Bạn có thể thay bằng ARN đầy đủ của secret.)

## Bước 4 – CloudTrail
1. CloudTrail → Create trail: tên **`saa-lab05-trail`**.
2. Storage: tạo S3 bucket mới (để Console tự đặt tên và tự gắn bucket policy).
3. Bật **Log file validation**. Chọn **Apply trail to all Regions** (multi-region). Events: *Management events* (Read + Write).
4. Đảm bảo trail đang **Logging**.

## Thử nghiệm tay (rất đáng làm)
```bash
ROLE_ARN=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/saa-lab05-app-role
CREDS=$(aws sts assume-role --role-arn $ROLE_ARN --role-session-name test --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r .SessionToken)
aws secretsmanager get-secret-value --secret-id saa-lab05/db-credentials --query Name   # OK
aws s3 ls                                                                                # AccessDenied
aws secretsmanager list-secrets                                                         # AccessDenied
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN                          # quay về user của bạn
```
Rồi vào **CloudTrail → Event history**, lọc `Event name = GetSecretValue` / `AssumeRole`: bạn thấy ai gọi, từ role session nào. Đây chính là điều đề thi gọi là "audit".

**Thử phá:** gỡ `kms:Decrypt` khỏi policy rồi gọi lại `get-secret-value` – lỗi gì? (vì secret mã hoá bằng CMK nên người gọi cần quyền Decrypt trên key đó).

## Đọc thêm (không có lab)
- **SCP** chặn hành vi nguy hiểm toàn Organization (ví dụ không cho tắt CloudTrail):
```json
{ "Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":["cloudtrail:StopLogging","cloudtrail:DeleteTrail"],"Resource":"*"}] }
```
- **GuardDuty** có thời gian dùng thử miễn phí – bật thử, xem Findings mẫu (`Generate sample findings`), rồi tắt nếu không cần.
- **WAF** gắn ALB/CloudFront; **Macie** dò PII trong S3; **Config** theo dõi cấu hình; **Inspector** quét CVE.

## Câu hỏi
1. Vì sao cần cả quyền Secrets Manager lẫn `kms:Decrypt`?
2. Khác nhau giữa `aws/secretsmanager` (AWS managed) và key của bạn khi nói về key policy và chi phí?
3. CloudTrail vs Config vs CloudWatch: mỗi cái trả lời câu hỏi nào?
4. SCP có thể *cấp* quyền không? (Không – chỉ đặt trần.)
5. Vì sao nên dùng role thay vì user + access key cho ứng dụng?

## Verify & Cleanup
```bash
bash verify.sh
bash cleanup.sh      # xoá trail, secret, bucket log, role; lên lịch xoá KMS key sau 7 ngày (tối thiểu)
```
