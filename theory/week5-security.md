# Tuần 5 – Security (domain chiếm 30% đề)

**Mục tiêu:** chọn đúng dịch vụ bảo mật cho từng tình huống: mã hoá, quản lý bí mật, chống tấn công, phát hiện, giám sát, quản trị nhiều account.
**Lab đi kèm:** `labs/lab05-security`

---

## 1. Mã hoá với KMS

### 1.1 Các loại khoá
| Loại | Quản lý | Ghi chú |
|---|---|---|
| **AWS owned keys** | AWS (không thấy trong account) | Mặc định cho nhiều dịch vụ (vd. DynamoDB), miễn phí |
| **AWS managed keys** (`aws/s3`, `aws/ebs`…) | AWS tạo trong account bạn | Xoay vòng tự động (hằng năm), bạn không sửa key policy |
| **Customer managed keys (CMK)** | **Bạn** | Tự đặt key policy, bật/tắt rotation, xoá có lịch (7–30 ngày), 1 USD/tháng/key + phí request |

- **Symmetric** (AES-256, mặc định, dữ liệu không rời KMS) vs **Asymmetric** (RSA/ECC – ký/xác thực hoặc mã hoá bên ngoài AWS).
- **Envelope encryption**: KMS mã hoá *data key*; data key mã hoá dữ liệu lớn (KMS chỉ trực tiếp mã hoá ≤ 4 KB).
- **Key policy** là resource-based policy **bắt buộc** của KMS: nếu key policy không "bật IAM policies" (statement cho account root) thì IAM policy một mình không đủ.
- KMS key **gắn với Region**. Muốn dùng cùng key ở nhiều Region (vd. S3 CRR mã hoá KMS, Global Tables, Aurora Global) → **Multi-Region keys**.
- Mọi lời gọi KMS được ghi **CloudTrail** → audit.
- **CloudHSM**: HSM **single-tenant** chuyên dụng (FIPS 140-2 Level 3), **bạn quản lý khoá**, phù hợp compliance nghiêm ngặt/SSL offload. KMS là multi-tenant managed.

### 1.2 Mã hoá theo dịch vụ
- **S3**: SSE-S3 / SSE-KMS / SSE-C / DSSE-KMS. **EBS/RDS/EFS/DynamoDB/…**: KMS. In-transit: TLS.
- **ACM** (Certificate Manager): cấp & tự gia hạn cert TLS **công khai miễn phí** cho ALB/CloudFront/API Gateway. Cert cho **CloudFront phải ở us-east-1**; ALB dùng cert ở cùng Region.

---

## 2. Quản lý bí mật & cấu hình
| | Secrets Manager | SSM Parameter Store |
|---|---|---|
| Mục đích | Bí mật (DB password, API key) | Cấu hình + (SecureString) bí mật |
| **Tự xoay vòng (rotation)** | **Có** (Lambda, tích hợp RDS/Redshift/DocumentDB) | Không tích hợp sẵn |
| Chi phí | ~0,40 USD/secret/tháng | Standard parameter **miễn phí** |
| Mã hoá | KMS | KMS (SecureString) |
→ "Xoay vòng mật khẩu DB tự động" = **Secrets Manager**; "lưu cấu hình rẻ" = **Parameter Store**.

---

## 3. Bảo vệ ứng dụng & mạng
| Dịch vụ | Làm gì | Gắn với |
|---|---|---|
| **AWS WAF** | Tường lửa **L7**: chặn SQLi, XSS, rate-based rule, geo block, IP set, bot control | **ALB, CloudFront, API Gateway, AppSync, Cognito** (không gắn NLB/EC2) |
| **AWS Shield Standard** | Chống DDoS L3/L4, **miễn phí, tự động** | Mọi khách hàng |
| **Shield Advanced** | DDoS nâng cao, đội DRT, bảo hiểm chi phí tăng đột biến | EC2, ELB, CloudFront, Route 53, Global Accelerator |
| **AWS Firewall Manager** | Quản lý tập trung WAF/Shield/SG/Network Firewall trên **Organization** | |
| **AWS Network Firewall** | Firewall stateful trong VPC: IPS, lọc domain, deep inspection | VPC |
| **Security Group / NACL** | Tuần 2 | |
| **CloudFront** | Hấp thụ DDoS ở edge; **OAC** truy cập S3 riêng tư; **signed URL/cookie**; **geo restriction**; field-level encryption | |

Chống DDoS kiến trúc: CloudFront + Route 53 + ALB + Auto Scaling + Shield + WAF, ẩn origin.

---

## 4. Phát hiện & điều tra
| Dịch vụ | Dùng để |
|---|---|
| **CloudTrail** | **Ai gọi API gì, khi nào, từ đâu**. Event history 90 ngày (management events); tạo **trail** để lưu S3 lâu dài, đa Region, **log file validation**, tích hợp CloudWatch Logs |
| **AWS Config** | **Trạng thái cấu hình tài nguyên theo thời gian & tuân thủ** (Config rules, remediation) – "SG này mở 22 ra Internet từ khi nào?" |
| **GuardDuty** | Phát hiện mối đe doạ bằng ML từ CloudTrail, VPC Flow Logs, DNS logs (+S3, EKS, Lambda…) |
| **Inspector** | Quét **lỗ hổng** (CVE) cho EC2, ECR, Lambda |
| **Macie** | Tìm **dữ liệu nhạy cảm/PII** trong S3 |
| **Security Hub** | Tổng hợp phát hiện từ GuardDuty/Inspector/Macie/Config… + kiểm tra chuẩn (CIS) |
| **Detective** | Điều tra nguyên nhân gốc, trực quan hoá |
| **IAM Access Analyzer** | Tìm tài nguyên **chia sẻ ra ngoài** (S3, IAM role, KMS…) và validate policy |
| **CloudWatch** | Metric, log, alarm; **Logs Insights** |
| **Trusted Advisor** | Kiểm tra best-practice (cost, security, limits, fault tolerance) |
| **Security Lake** | Data lake log bảo mật chuẩn OCSF |
| **Artifact** | Báo cáo compliance của AWS (SOC, ISO…) |

Phân biệt hay nhầm: **CloudTrail = API calls (ai làm gì)**, **Config = trạng thái cấu hình (thay đổi/tuân thủ)**, **CloudWatch = hiệu năng/log vận hành**, **GuardDuty = hành vi đáng ngờ**, **Inspector = lỗ hổng phần mềm**, **Macie = PII trong S3**.

---

## 5. Định danh nâng cao
- **Cognito**
  - **User Pool**: đăng ký/đăng nhập (**authentication**), JWT token, social/SAML/OIDC login, MFA. Tích hợp ALB/API Gateway.
  - **Identity Pool**: đổi token (từ User Pool/Google/Facebook/SAML) lấy **credential AWS tạm** để truy cập trực tiếp S3, DynamoDB…
- **IAM Identity Center (SSO)**: đăng nhập một lần vào nhiều account AWS/ứng dụng, tích hợp AD/IdP, quản lý bằng permission set.
- **AWS Directory Service**: *AWS Managed Microsoft AD*, *AD Connector* (proxy tới AD on-prem), *Simple AD*.
- **STS**: `AssumeRole` (cross-account), `AssumeRoleWithWebIdentity/SAML`. Credential tạm 15 phút – 12 giờ.
- **Resource Access Manager (RAM)**: chia sẻ tài nguyên (subnet, TGW…) giữa account không cần peering.

---

## 6. Nhiều account & quản trị
- **AWS Organizations**: nhiều account, **consolidated billing** (gộp để hưởng giá tổng), OU, **SCP** (trần quyền, không cấp quyền, không áp cho management account).
- **Control Tower**: thiết lập **landing zone** nhiều account theo best practice (guardrails).
- **Service Catalog**: danh mục sản phẩm đã duyệt cho người dùng tự cấp phát.
- **Tag policies**, **AWS License Manager**, **Systems Manager** (Session Manager, Patch Manager).

---

## 7. Bảo mật dữ liệu S3 – checklist
1. Bật **Block Public Access** (cấp account).
2. Bucket policy `Deny` non-TLS; chỉ cho principal cần thiết; dùng **VPC endpoint policy** cho truy cập từ VPC.
3. Mã hoá SSE-KMS khi cần audit / kiểm soát khoá.
4. **Versioning + MFA Delete + Object Lock** cho dữ liệu quan trọng.
5. **Pre-signed URL** cho chia sẻ tạm thời.
6. Dùng **Macie** để dò PII; **Access Analyzer for S3** để thấy ai ngoài truy cập được.
7. CloudFront + **OAC** cho nội dung riêng tư.

---

## 8. Bẫy thường gặp
1. "Xoay vòng secret tự động" → **Secrets Manager** (không phải Parameter Store).
2. "Ai đã xoá bucket/terminate instance?" → **CloudTrail**. "Cấu hình SG bị đổi lúc nào?" → **Config**.
3. "Phát hiện hành vi bất thường/đào coin trên EC2" → **GuardDuty**. "CVE trên EC2" → **Inspector**.
4. "Tìm PII trong S3" → **Macie**.
5. "Chặn SQL injection/XSS" → **WAF** (gắn ALB/CloudFront/API GW); "chặn IP" → WAF IP set hoặc NACL.
6. "Quản lý khoá, FIPS 140-2 L3, tự quản" → **CloudHSM**.
7. "Giới hạn quyền tối đa cho toàn account trong Org" → **SCP**; "cho dev tự tạo role nhưng không vượt trần" → **permissions boundary**.
8. "Đăng nhập người dùng web/mobile + social login" → **Cognito User Pool**; "cấp quyền AWS trực tiếp cho user app" → **Identity Pool**.
9. "Truy cập S3 riêng tư qua CloudFront" → **OAC** (thay OAI cũ).
10. Cert cho CloudFront → ACM ở **us-east-1**.
11. EC2 cần quyền → **role/instance profile**; không nhúng key.
12. "Cross-account truy cập S3" → bucket policy cho principal account kia hoặc assume role.

---

## 9. Tự kiểm tra

1. Customer managed key khác AWS managed key ở điểm nào?
2. Cần ghi nhận mọi lời gọi API trong tài khoản trong 5 năm, đa Region, chống sửa log. Làm gì?
3. App trên EC2 cần mật khẩu RDS tự xoay mỗi 30 ngày. Dùng gì, cấp quyền thế nào?
4. Khác biệt giữa SCP và permissions boundary?
5. WAF gắn được vào những dịch vụ nào? Có gắn vào NLB không?
6. Phân biệt Cognito User Pool và Identity Pool.
7. Khi nào dùng CloudHSM thay vì KMS?
8. Tại sao IAM policy một mình có thể không đủ để dùng một KMS key?

<details><summary>Đáp án</summary>

1. CMK: bạn quản lý key policy, rotation, vô hiệu hoá/xoá, tốn phí; AWS managed: AWS quản lý, bạn không sửa policy, miễn phí key.
2. Tạo trail đa Region ghi vào S3 (bật log file validation, có thể bật Object Lock/lifecycle 5 năm), tuỳ chọn gửi CloudWatch Logs.
3. Secrets Manager với rotation; EC2 dùng IAM role có `secretsmanager:GetSecretValue` (và `kms:Decrypt` nếu dùng CMK).
4. SCP: trần cho cả account/OU trong Organizations. Boundary: trần cho một user/role cụ thể. Cả hai chỉ giới hạn, không tự cấp quyền.
5. ALB, CloudFront, API Gateway, AppSync, Cognito User Pool. Không gắn NLB/EC2 trực tiếp.
6. User Pool = đăng nhập/authN, trả JWT. Identity Pool = đổi token lấy credential AWS tạm (authZ).
7. Cần HSM riêng single-tenant, tự quản khoá, FIPS 140-2 Level 3, hoặc tích hợp PKCS#11/JCE.
8. Key policy là bắt buộc; cần key policy cho phép (trực tiếp hoặc bật uỷ quyền cho IAM).
</details>

## Tài liệu nên đọc thêm
- Well-Architected: Security pillar. Doc: "IAM policy evaluation logic", "KMS key policies", "Organizations – SCP".
- FAQ: KMS, Secrets Manager, WAF, Shield, GuardDuty, Cognito.
