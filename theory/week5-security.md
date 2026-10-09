# Tuần 5 – Security (domain chiếm 30% đề)

**Mục tiêu:** chọn đúng dịch vụ bảo mật cho từng tình huống: mã hoá, quản lý bí mật, chống tấn công, phát hiện, giám sát, định danh, quản trị nhiều account.
**Lab đi kèm:** `labs/lab05-security`

> Ký hiệu: **💡 Kinh nghiệm thực tế** · **🎯 Mẹo thi** · **⚠️ Hay nhầm**.
> Ôn lại tuần 1 (IAM policy, logic đánh giá quyền) trước khi đọc – phần này dựa trên nó.

**Bản đồ tư duy bảo mật theo lớp** (dùng để loại trừ đáp án):

| Lớp | Câu hỏi | Dịch vụ |
|---|---|---|
| Định danh & quyền | Ai được làm gì? | IAM, Identity Center, Cognito, Organizations (SCP/RCP), STS |
| Mạng / biên | Traffic nào được vào? | SG, NACL, WAF, Shield, Network Firewall, CloudFront, PrivateLink |
| Dữ liệu | Dữ liệu được bảo vệ thế nào? | KMS, CloudHSM, ACM, Secrets Manager, Macie, S3 Object Lock |
| Phát hiện | Có gì bất thường không? | GuardDuty, Inspector, Macie, Security Hub, Detective, Config |
| Ghi nhận & audit | Ai đã làm gì, khi nào? | CloudTrail, Config, VPC Flow Logs, CloudWatch Logs |
| Phản ứng | Tự động xử lý thế nào? | EventBridge, Lambda, SSM Automation, Config remediation |

---

## 1. Mã hoá với KMS

### 1.1 Các loại khoá

| Loại | Ai quản lý | Thấy trong account? | Rotation | Key policy | Phí |
|---|---|---|---|---|---|
| **AWS owned keys** | AWS, dùng chung nhiều account | Không | AWS lo | Không xem/sửa | Miễn phí |
| **AWS managed keys** (`aws/s3`, `aws/ebs`, `aws/rds`…) | AWS tạo trong account bạn, cho 1 dịch vụ | Có | **Tự động hằng năm** (bắt buộc) | Xem được, **không sửa** | Không phí key (vẫn tính request) |
| **Customer managed keys (CMK)** | **Bạn** | Có | Tuỳ chọn (mặc định 365 ngày, chỉnh được; có rotate theo yêu cầu) | **Bạn viết** | ~1 USD/tháng/key + phí request |

- **Symmetric** (AES-256-GCM, mặc định): khoá **không bao giờ rời KMS**, mọi thao tác qua API. Dùng cho hầu hết dịch vụ AWS.
- **Asymmetric** (RSA/ECC): ký/xác minh chữ ký, hoặc mã hoá bởi bên ngoài AWS bằng public key (tải public key về).
- **HMAC keys**: tạo/xác minh mã MAC.
- **Imported key material (BYOK)**: bạn đưa key material vào KMS – tự chịu trách nhiệm lưu bản gốc, **không auto-rotate**, có thể đặt hạn.
- **Custom key store**: KMS dùng **CloudHSM cluster** của bạn (hoặc External Key Store ngoài AWS) làm nơi chứa khoá.

### 1.2 Envelope encryption (hiểu để trả lời "vì sao")
- API `Encrypt` của KMS chỉ mã hoá dữ liệu **≤ 4 KB** → dữ liệu lớn dùng **envelope encryption**:
  1. Gọi `GenerateDataKey` → KMS trả **data key** dạng plaintext + bản mã hoá bởi KMS key.
  2. Dùng data key plaintext mã hoá dữ liệu cục bộ, **xoá plaintext khỏi bộ nhớ**.
  3. Lưu dữ liệu đã mã hoá + data key đã mã hoá cạnh nhau.
  4. Giải mã: gửi data key đã mã hoá cho KMS `Decrypt` → nhận plaintext data key → giải mã dữ liệu.
- S3, EBS, RDS… đều làm thế này "phía sau" – đây là lý do mã hoá **gần như không ảnh hưởng hiệu năng**.

### 1.3 Key policy & quyền
- **Key policy** là resource-based policy **bắt buộc** của mọi KMS key. Khác các dịch vụ khác: nếu key policy không cho phép, **IAM policy một mình không đủ**.
- Key policy mặc định (tạo qua Console) có statement cho **account root** (`arn:aws:iam::<account>:root`) → nghĩa là "**cho phép IAM policy trong account điều khiển key này**". Xoá statement đó → chỉ những principal ghi tên trong key policy mới dùng được.
- **Grants**: uỷ quyền tạm/lập trình (EBS, RDS dùng grants để dùng key thay bạn).
- Condition hay dùng: `kms:ViaService` (chỉ cho dùng key khi gọi qua S3/EBS…), `kms:EncryptionContext:*`, `kms:CallerAccount`.
- **Cross-account**: (1) key policy ở account A cho phép account B; (2) IAM policy ở account B cho user/role dùng key ARN đó.
- Chia sẻ **snapshot/AMI mã hoá** cho account khác → bắt buộc dùng **CMK** (khoá AWS managed `aws/ebs` không chia sẻ được).

### 1.4 Vòng đời & giới hạn
- **Disable** key: ngay lập tức không dùng được (bật lại được).
- **Schedule deletion**: chờ **7–30 ngày** (mặc định 30) rồi xoá vĩnh viễn → **mọi dữ liệu mã hoá bằng key đó mất vĩnh viễn**. Đặt alarm CloudTrail/EventBridge cho `ScheduleKeyDeletion`.
- **Rotation**: KMS giữ các phiên bản key material cũ để giải mã dữ liệu cũ; key ID/ARN không đổi → ứng dụng không cần sửa. Rotation thủ công (khi import key material) = tạo key mới + đổi **alias**.
- **KMS gắn với Region**. Cần cùng khoá ở nhiều Region (S3 CRR với SSE-KMS, DynamoDB Global Tables, Aurora Global, mã hoá phía client đa Region) → **Multi-Region keys** (cùng key ID & material, nhân bản sang Region khác, policy độc lập).
- **Quota request** (vài nghìn – vài chục nghìn request/giây/Region tuỳ thao tác) → `ThrottlingException` khi S3 SSE-KMS tải lớn → bật **S3 Bucket Key**, cache data key.
- Mọi lời gọi KMS ghi vào **CloudTrail** → audit ai giải mã gì, khi nào.

> 💡 **Kinh nghiệm thực tế – KMS**
> - Lỗi `AccessDenied` khi đọc object S3/secret dù IAM đúng → **thiếu `kms:Decrypt`** hoặc key policy không cho phép. Rất hay gặp khi chuyển từ SSE-S3 sang SSE-KMS (lab05 kiểm tra đúng điểm này).
> - Dùng **alias** (`alias/app-prod`) trong code/IaC thay key ID để dễ đổi khoá.
> - Tách **key administrators** (quản lý key, không giải mã) và **key users** (dùng key) trong key policy → separation of duties.
> - Một CMK cho mỗi ứng dụng/mức nhạy cảm/môi trường là cách cân bằng phổ biến giữa kiểm soát và chi phí.

### 1.5 CloudHSM
- **HSM single-tenant** chuyên dụng (chuẩn FIPS 140 Level 3), trong VPC của bạn. **Bạn quản lý user và khoá**; AWS chỉ lo phần cứng, **không truy cập được khoá** → mất credential là mất khoá.
- HA: **cluster ≥ 2 HSM ở 2 AZ** (AWS tự đồng bộ).
- API chuẩn: **PKCS#11, JCE, CNG/KSP**; dùng cho **SSL/TLS offload**, Oracle TDE, CA riêng, ký số; làm custom key store cho KMS.

| | KMS | CloudHSM |
|---|---|---|
| Tenancy | Multi-tenant managed | **Single-tenant** |
| Quản lý khoá | AWS vận hành, bạn kiểm soát quyền | **Bạn toàn quyền** |
| Tích hợp dịch vụ AWS | Sâu, sẵn có | Qua custom key store hoặc app tự tích hợp |
| Giao diện | API AWS | PKCS#11, JCE, CNG |
| Khi nào | Mặc định | Yêu cầu tuân thủ HSM riêng, kiểm soát khoá tuyệt đối, API chuẩn công nghiệp |

### 1.6 Mã hoá theo dịch vụ & TLS
- **At rest**: S3 (SSE-S3/SSE-KMS/DSSE-KMS/SSE-C), EBS/RDS/Aurora/EFS/FSx/DynamoDB/SQS/SNS/Kinesis… đều tích hợp KMS. RDS/EFS **chỉ bật được khi tạo**.
- **In transit**: TLS ở mọi endpoint AWS; ép bằng policy (`aws:SecureTransport`), tham số DB, security policy của ELB/CloudFront.
- **ACM (Certificate Manager)**:
  - Cấp và **tự gia hạn** cert TLS công khai **miễn phí** cho ALB, NLB, CloudFront, API Gateway, App Runner…
  - Validation: **DNS** (khuyên dùng – tự gia hạn hoàn toàn) hoặc email.
  - Cert cho **CloudFront** (và custom domain API Gateway edge-optimized) phải ở **us-east-1**; ALB/NLB dùng cert ở **cùng Region**.
  - Cert công khai ACM thông thường **không export** để cài lên EC2 (đề thi coi như vậy) → cert trên EC2: tự quản (Let's Encrypt…) hoặc đặt ALB phía trước.
  - **AWS Private CA**: CA nội bộ cấp cert private (mTLS, thiết bị IoT, dịch vụ nội bộ) – có phí.

---

## 2. Quản lý bí mật & cấu hình

| | **Secrets Manager** | **SSM Parameter Store** |
|---|---|---|
| Mục đích | **Bí mật** (DB password, API key, OAuth token) | Cấu hình + bí mật (kiểu `SecureString`) |
| **Rotation tự động** | **Có** – tích hợp RDS/Aurora/Redshift/DocumentDB (managed rotation), hoặc Lambda tuỳ chỉnh | **Không** có sẵn (tự làm bằng EventBridge + Lambda) |
| Kích thước | Tới 64 KB | Standard 4 KB, Advanced 8 KB |
| Sao chép đa Region | **Có** (replica secret) | Không |
| Resource policy (cross-account) | **Có** | Không (chỉ Advanced tier + RAM) |
| Phân cấp | Theo tên | **Cây đường dẫn** `/app/prod/db/url` (lấy theo path) |
| Chi phí | ~0,40 USD/secret/tháng + phí API | Standard **miễn phí** (tới 10.000 tham số); Advanced có phí |
| Tính năng khác | Tạo mật khẩu ngẫu nhiên | Parameter policies (hết hạn – Advanced), **public parameters** của AWS (AMI ID mới nhất…), tham chiếu được secret của Secrets Manager |

→ "**Xoay vòng mật khẩu DB tự động**" = **Secrets Manager**; "lưu cấu hình/feature flag rẻ" = **Parameter Store**.

Lấy secret từ ứng dụng (role cần `secretsmanager:GetSecretValue` + `kms:Decrypt` nếu dùng CMK):
```bash
aws secretsmanager get-secret-value --secret-id saa-lab05/db-credentials \
  --query SecretString --output text
aws ssm get-parameters-by-path --path /app/prod --with-decryption --recursive
```

> 💡 **Kinh nghiệm thực tế – bí mật**
> - **Không bao giờ** commit secret vào Git, user data, AMI, biến môi trường plaintext của Lambda/ECS. ECS task definition có trường `secrets` tham chiếu thẳng Secrets Manager/Parameter Store; Lambda dùng extension để cache.
> - Ứng dụng nên **đọc secret lúc chạy và cache vài phút** (thư viện caching của AWS) – để khi rotation đổi mật khẩu app tự lấy bản mới, không cần deploy lại.
> - Rotation cần ứng dụng chịu được giai đoạn chuyển giao: chiến lược *alternating users* (2 user DB luân phiên) tránh lỗi đăng nhập khi đổi mật khẩu.
> - Lỡ lộ access key lên GitHub: **vô hiệu hoá key ngay**, xem CloudTrail key đó đã làm gì, kiểm tra tài nguyên lạ (EC2 đào coin ở Region ít dùng!), rồi mới điều tra tiếp. AWS cũng thường tự gắn policy `AWSCompromisedKeyQuarantine` và gửi email cảnh báo.

---

## 3. Bảo vệ ứng dụng & mạng

| Dịch vụ | Làm gì | Gắn với |
|---|---|---|
| **AWS WAF** | Tường lửa **L7**: chặn SQLi, XSS, rate-based rule, geo match, IP set, regex, kích thước request, **Bot Control**, chống chiếm tài khoản, CAPTCHA/Challenge | **ALB, CloudFront, API Gateway (REST), AppSync, Cognito User Pool**, App Runner, Verified Access (**không** gắn NLB/EC2 trực tiếp) |
| **AWS Shield Standard** | Chống DDoS **L3/L4** (SYN flood, UDP reflection), **miễn phí, tự động** | Mọi khách hàng |
| **Shield Advanced** | DDoS nâng cao (cả L7 khi kết hợp WAF, tự tạo rule giảm thiểu), **Shield Response Team** 24/7, **bảo vệ chi phí** (hoàn tiền scale do tấn công), báo cáo/metric chi tiết | EC2 (EIP), ELB, CloudFront, Route 53, Global Accelerator. ~3.000 USD/tháng/Organization, cam kết 1 năm |
| **AWS Firewall Manager** | Quản lý tập trung WAF rule, Shield Advanced, SG, Network Firewall, DNS Firewall cho **cả Organization**, tự áp lên tài nguyên/account mới | Cần Organizations + AWS Config |
| **AWS Network Firewall** | Firewall **stateful trong VPC**: IDS/IPS (rule tương thích Suricata), **lọc domain** (vd. chỉ cho ra `*.amazonaws.com`, `github.com`), TLS inspection | Subnet firewall riêng, route traffic qua firewall endpoint; mô hình tập trung với TGW |
| **Route 53 Resolver DNS Firewall** | Chặn truy vấn DNS tới domain độc hại | VPC |
| **Security Group / NACL** | Tuần 2 | ENI / subnet |
| **CloudFront** | Hấp thụ DDoS ở edge; **OAC** truy cập S3 riêng tư; **signed URL/cookie**; **geo restriction**; field-level encryption; ẩn origin | Edge |

### 3.1 WAF chi tiết
- **Web ACL** = danh sách rule (theo priority) + hành động mặc định (Allow/Block). Mỗi rule: Allow / Block / Count / CAPTCHA / Challenge.
- **Managed rule groups** của AWS (Core rule set/OWASP, SQL database, Known bad inputs, Amazon IP reputation, Anonymous IP list…) và của Marketplace → bật nhanh không phải tự viết.
- **Rate-based rule**: chặn IP (hoặc key khác: header, cookie…) gửi quá N request trong cửa sổ thời gian → chống brute-force, scraping, HTTP flood.
- Web ACL cho CloudFront tạo ở phạm vi **global** (us-east-1); cho ALB/API Gateway tạo ở **Region** của tài nguyên.
- Log ra CloudWatch Logs, S3, Firehose.

> 💡 **Kinh nghiệm thực tế – WAF**: bật rule mới ở chế độ **Count** vài ngày, xem log những request sẽ bị chặn, loại trừ false positive (vd. form upload bị nhận nhầm SQLi), rồi mới chuyển **Block**. Bật thẳng Block managed rule lên prod là cách nhanh nhất để tự làm sập checkout.

### 3.2 Kiến trúc chống DDoS (Well-Architected)
```
Người dùng → Route 53 (Shield) → CloudFront (+WAF, Shield) → ALB (+WAF) trong public subnet
          → ASG trong private subnet (scale hấp thụ tải) → DB private
```
Nguyên tắc: **giảm bề mặt tấn công** (chỉ edge public, origin ẩn sau CloudFront/OAC, SG chỉ cho phép CloudFront prefix list), **hấp thụ** (edge + auto scaling), **lọc L7** (WAF rate-based, managed rules), **giám sát** (CloudWatch, Shield Advanced metric).

---

## 4. Phát hiện, giám sát & điều tra

| Dịch vụ | Trả lời câu hỏi | Nguồn dữ liệu / Ghi chú |
|---|---|---|
| **CloudTrail** | **Ai gọi API gì, khi nào, từ đâu, kết quả?** | Event history 90 ngày (management events, miễn phí); **trail** → S3 lâu dài, đa Region, **log file validation**, gửi CloudWatch Logs/EventBridge |
| **AWS Config** | **Tài nguyên được cấu hình thế nào, thay đổi lúc nào, có tuân thủ không?** | Configuration item, timeline, **Config rules**, remediation, conformance pack, aggregator |
| **GuardDuty** | **Có hành vi đáng ngờ/mối đe doạ không?** | ML + threat intel trên CloudTrail, VPC Flow Logs, DNS logs (tự thu thập, **không cần bạn bật flow logs**) + S3, EKS, RDS login, Lambda, runtime, malware scan |
| **Inspector** | **Có lỗ hổng phần mềm (CVE) / lộ mạng không?** | EC2 (qua SSM agent hoặc agentless), image **ECR**, **Lambda** (gói + code); quét liên tục |
| **Macie** | **Có dữ liệu nhạy cảm/PII trong S3 không?** | ML + pattern (thẻ tín dụng, CMND/hộ chiếu, khoá bí mật…); đánh giá bucket public/không mã hoá |
| **Security Hub** | **Tổng thể tư thế bảo mật? Gom finding ở một chỗ** | Gom GuardDuty/Inspector/Macie/Config/Access Analyzer/đối tác; chấm theo chuẩn (AWS Foundational Best Practices, CIS, PCI DSS, NIST); cần Config |
| **Detective** | **Nguyên nhân gốc / phạm vi ảnh hưởng của một sự cố?** | Đồ thị hành vi từ CloudTrail, Flow Logs, GuardDuty findings |
| **IAM Access Analyzer** | **Tài nguyên nào chia sẻ ra ngoài? Quyền nào không dùng?** | S3, role, KMS, Lambda, SQS, Secrets Manager…; validate & sinh policy |
| **CloudWatch** | **Hệ thống chạy thế nào? (metric, log, alarm)** | Logs Insights, metric filter, alarm, dashboard, Synthetics |
| **Trusted Advisor** | **Có vi phạm best practice nào?** | Cost, security (bucket public, MFA root, SG mở), fault tolerance, quotas; đầy đủ check cần Business/Enterprise Support |
| **Security Lake** | Gom log bảo mật về data lake chuẩn **OCSF** | Cho SIEM/phân tích |
| **Audit Manager** | Thu thập **bằng chứng** cho kỳ audit (PCI, HIPAA, GDPR…) | |
| **Artifact** | Tải **báo cáo tuân thủ của AWS** (SOC, ISO, PCI) và ký thoả thuận (BAA) | |

**Phân biệt hay nhầm** (thuộc lòng):
- **CloudTrail = API calls (ai làm gì)**
- **Config = trạng thái cấu hình (thay đổi/tuân thủ)**
- **CloudWatch = hiệu năng/log vận hành/alarm**
- **GuardDuty = hành vi đáng ngờ (threat detection)**
- **Inspector = lỗ hổng phần mềm (CVE)**
- **Macie = PII trong S3**
- **Security Hub = gom và chấm điểm**
- **Detective = điều tra sau khi có finding**

### 4.1 CloudTrail chi tiết
- **Management events** (control plane: tạo/xoá/sửa tài nguyên, đăng nhập Console) – mặc định ghi; chia read/write.
- **Data events** (data plane: `GetObject/PutObject` S3, `Invoke` Lambda, item DynamoDB…) – **mặc định tắt**, tính phí, có thể rất nhiều → bật có chọn lọc.
- **Insights events**: phát hiện hoạt động API **bất thường** (đột biến `TerminateInstances`, lỗi AccessDenied tăng vọt).
- **Organization trail**: một trail cho mọi account trong Org, ghi về bucket của account log tập trung.
- **Log file integrity validation**: file digest (SHA-256, ký số) mỗi giờ → chứng minh log không bị sửa/xoá.
- Bảo vệ log: bucket ở **account log riêng**, SSE-KMS, **Object Lock**, MFA Delete, SCP cấm `cloudtrail:StopLogging`/`DeleteTrail`.
- Log tới S3 thường trong khoảng **5 phút** (không real-time) → muốn phản ứng gần real-time: **EventBridge** (nhận sự kiện CloudTrail) hoặc **CloudWatch Logs metric filter + alarm**.
- **CloudTrail Lake**: lưu và query sự kiện bằng SQL nhiều năm.

### 4.2 AWS Config chi tiết
- **Configuration recorder** ghi lại cấu hình mọi tài nguyên được hỗ trợ + quan hệ (SG nào gắn instance nào).
- **Config rules**: managed (hàng trăm rule có sẵn: `s3-bucket-public-read-prohibited`, `encrypted-volumes`, `restricted-ssh`, `iam-user-mfa-enabled`…) hoặc custom (Lambda/Guard). Kích hoạt khi thay đổi hoặc theo chu kỳ.
- **Remediation**: tự động hoặc thủ công qua **SSM Automation** (vd. tự bật Block Public Access cho bucket vi phạm).
- **Conformance pack**: bộ rule + remediation theo chuẩn (CIS, PCI…) triển khai một lần.
- **Aggregator**: xem tuân thủ của nhiều account/Region ở một chỗ.
- Config là **phát hiện (detective)**, không chặn trước. Chặn trước = SCP, IAM, Control Tower proactive controls.

### 4.3 GuardDuty chi tiết
- Bật 1 click, không agent (trừ Runtime Monitoring), không ảnh hưởng hiệu năng. Dùng thử 30 ngày.
- Finding ví dụ: EC2 giao tiếp với IP **đào coin**/C&C botnet, gọi API từ IP Tor, **credential của instance bị dùng từ ngoài AWS**, brute-force SSH/RDP, S3 bị đọc bất thường, đăng nhập RDS bất thường, malware trong EBS/S3.
- Multi-account: **delegated administrator** trong Organizations, tự bật cho account mới.
- Phản ứng tự động: **GuardDuty → EventBridge → Lambda/SSM** (cô lập instance, thu hồi session của role, chặn IP bằng WAF/NACL, thông báo SNS).

> 💡 **Kinh nghiệm thực tế – baseline bảo mật cho MỌI account (làm ngày đầu)**
> 1. MFA root, xoá access key root, Identity Center cho người.
> 2. **CloudTrail** đa Region (organization trail) → bucket log riêng, có validation.
> 3. **GuardDuty** + **Security Hub** + **Config** + **IAM Access Analyzer** bật ở mọi Region đang dùng (Region không dùng → chặn bằng SCP).
> 4. **S3 Block Public Access** cấp account, **EBS encryption by default**.
> 5. **AWS Budgets** + **Cost Anomaly Detection** (hoá đơn tăng bất thường thường là dấu hiệu bị xâm nhập).
> 6. Alarm cho: đăng nhập root, thay đổi IAM/SG/NACL, tắt CloudTrail, ConsoleLogin thất bại liên tục.

---

## 5. Định danh nâng cao

### 5.1 Amazon Cognito
- **User Pool** = **thư mục người dùng + đăng nhập (authentication)**:
  - Đăng ký/đăng nhập, xác minh email/SĐT, quên mật khẩu, **MFA**, chính sách mật khẩu, phát hiện đăng nhập rủi ro.
  - **Federation**: social (Google, Facebook, Apple, Amazon), **SAML** (AD FS, Okta), **OIDC**.
  - Trả **JWT** (ID token, access token, refresh token); giao diện đăng nhập dựng sẵn (hosted UI / managed login).
  - **Lambda triggers** tuỳ biến luồng (pre sign-up, post confirmation, pre token generation…).
  - Tích hợp **ALB** (authenticate action) và **API Gateway** (Cognito authorizer).
- **Identity Pool** (Federated Identities) = **đổi token lấy credential AWS tạm (authorization)**:
  - Nhận token từ User Pool, Google, SAML… → gọi STS cấp **credential IAM tạm** → app gọi **trực tiếp** S3, DynamoDB…
  - Role cho người dùng **đã xác thực** và **khách (guest)**; ánh xạ role theo nhóm/claim.
  - Policy theo từng người dùng: dùng biến `${cognito-identity.amazonaws.com:sub}` → mỗi người chỉ truy cập prefix S3 / partition key DynamoDB của mình.

```
Mobile app ──đăng nhập──► Cognito User Pool ──JWT──► app
app ──JWT──► Cognito Identity Pool ──STS──► credential tạm (role "authenticated")
app ──credential tạm──► S3: s3://bucket/users/<sub>/*   (chỉ thư mục của chính mình)
```

### 5.2 IAM Identity Center (SSO)
- Đăng nhập **một lần** vào **nhiều account AWS** + ứng dụng SAML (Salesforce, Microsoft 365…).
- Nguồn danh tính: thư mục nội bộ của Identity Center, **AWS Managed Microsoft AD / AD Connector**, hoặc **IdP ngoài** (Okta, Microsoft Entra ID, Google Workspace) qua **SAML 2.0 + SCIM** (tự đồng bộ user/group).
- **Permission set** = mẫu quyền → Identity Center tạo role tương ứng trong từng account được gán.
- CLI: `aws configure sso` → credential tạm, không còn access key dài hạn.

### 5.3 AWS Directory Service

| Lựa chọn | Mô tả | Dùng khi |
|---|---|---|
| **AWS Managed Microsoft AD** | AD **thật** do AWS vận hành (2 domain controller ở 2 AZ), có thể tạo **trust** với AD on-prem | Ứng dụng AD-aware chạy trên AWS (EC2 Windows, RDS SQL Server, FSx for Windows, WorkSpaces), cần AD trên cloud kể cả khi mất kết nối về on-prem |
| **AD Connector** | **Proxy** chuyển yêu cầu xác thực về AD on-prem, không lưu/cache gì trên cloud | Chỉ muốn dùng AD on-prem sẵn có cho Console/WorkSpaces…; cần VPN/DX ổn định |
| **Simple AD** | Thư mục tương thích AD (Samba) rẻ, nhỏ | Nhu cầu cơ bản, không cần trust, tính năng AD nâng cao |

### 5.4 STS & federation
- `AssumeRole` (cross-account, chuyển quyền), `AssumeRoleWithSAML` (doanh nghiệp), `AssumeRoleWithWebIdentity` (OIDC – với mobile nên dùng Cognito; với EKS là nền của IRSA), `GetSessionToken` (credential tạm có MFA cho IAM user), `GetCallerIdentity`.
- Credential tạm 15 phút – 12 giờ (tuỳ API & cấu hình role); role chaining tối đa 1 giờ.
- **IAM Roles Anywhere**: workload **ngoài AWS** (server on-prem) lấy credential tạm bằng chứng chỉ X.509 – thay access key dài hạn.

### 5.5 Resource Access Manager (RAM)
- Chia sẻ tài nguyên giữa các account (trong Org hoặc account cụ thể) **không cần copy**: **subnet (VPC sharing)**, Transit Gateway, Route 53 Resolver rules, prefix list, License Manager config, Aurora cluster (để clone), Capacity Reservation, Outposts…
- **VPC sharing**: account "network" sở hữu VPC/subnet; account ứng dụng tạo EC2/RDS/Lambda **ngay trong subnet được chia sẻ** → ít VPC, ít peering, quản lý mạng tập trung.

---

## 6. Nhiều account & quản trị

### 6.1 AWS Organizations
- **Management account** (trả tiền, quản lý Org – **không chạy workload ở đây**) + **member accounts**, nhóm trong **OU** (tối đa 5 cấp lồng).
- **Consolidated billing**: một hoá đơn, **gộp usage để hưởng bậc giá**, **chia sẻ RI/Savings Plans** giữa các account (có thể tắt).
- **Delegated administrator**: giao quản trị GuardDuty, Security Hub, Config, Firewall Manager… cho account "security" thay vì management account.
- **Chính sách**:

| Chính sách | Làm gì |
|---|---|
| **SCP** (Service Control Policy) | **Trần quyền** cho principal trong account (kể cả **root của member account**); không cấp quyền; không áp cho management account và service-linked role |
| **RCP** (Resource Control Policy) | Trần quyền **phía tài nguyên** (S3, KMS, STS, SQS, Secrets Manager…) – vd. "không ai ngoài Org truy cập được bucket của Org" |
| **Declarative policies** | Ép cấu hình dịch vụ trên toàn Org (vd. bắt buộc IMDSv2, cấm chia sẻ AMI public) |
| **Tag policies** | Chuẩn hoá key/giá trị tag |
| **Backup policies** | Áp kế hoạch AWS Backup cho nhiều account |
| AI services opt-out | Từ chối dùng dữ liệu để cải thiện dịch vụ AI |

**SCP – hai chiến lược**:
- **Deny list** (mặc định, khuyên dùng): giữ `FullAWSAccess`, thêm SCP **Deny** những thứ cấm.
- **Allow list**: bỏ `FullAWSAccess`, chỉ Allow dịch vụ được phép (chặt nhưng khó bảo trì).
- Quyền hiệu lực ở một account = **giao** của SCP ở root, mọi OU cha và chính account đó.

Ví dụ SCP chặn Region ngoài Singapore/Sydney, chừa dịch vụ global:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyOutsideAllowedRegions",
    "Effect": "Deny",
    "NotAction": ["iam:*", "organizations:*", "route53:*", "cloudfront:*", "sts:*", "support:*", "budgets:*"],
    "Resource": "*",
    "Condition": { "StringNotEquals": { "aws:RequestedRegion": ["ap-southeast-1", "ap-southeast-2"] } }
  }]
}
```
SCP phổ biến khác: cấm rời Organization, cấm tắt CloudTrail/GuardDuty/Config, cấm xoá log bucket, cấm dùng root của member account, bắt buộc mã hoá.

> 💡 **Kinh nghiệm thực tế – SCP**: thử SCP trên **OU sandbox** trước; một SCP Deny viết sai có thể chặn cả pipeline deploy của toàn công ty. Nhớ chừa ngoại lệ (condition `aws:PrincipalArn`) cho role "break-glass"/role của Control Tower.

### 6.2 AWS Control Tower
- Dựng **landing zone** nhiều account theo best practice trong vài giờ: OU Security với account **Log Archive** (log tập trung) và **Audit** (bảo mật), SSO, CloudTrail Org, Config.
- **Account Factory**: tạo account mới đã chuẩn hoá (qua Service Catalog hoặc Terraform – AFT).
- **Controls (guardrails)**:
  - *Preventive* – chặn trước (SCP/RCP).
  - *Detective* – phát hiện vi phạm (Config rules).
  - *Proactive* – kiểm tra template trước khi tạo tài nguyên (CloudFormation hooks).
- Dashboard tuân thủ toàn Org.

### 6.3 Khác
- **Service Catalog**: danh mục "sản phẩm" (template CloudFormation) đã duyệt → người dùng tự cấp phát mà không cần quyền rộng.
- **License Manager**: theo dõi giấy phép phần mềm (BYOL).
- **Systems Manager**: Session Manager (truy cập không mở port, log phiên), Patch Manager (vá theo baseline + maintenance window), Automation (runbook sửa lỗi tự động).

> 🎯 **Mẹo thi – quản trị**: "Ngăn **mọi** user kể cả admin của account con làm X" → **SCP**. "Dựng nhanh môi trường nhiều account theo best practice, có guardrail" → **Control Tower**. "Gộp hoá đơn, giảm giá theo tổng" → **Organizations consolidated billing**. "Chia sẻ subnet/TGW cho account khác" → **RAM**. "Cho phép team tự tạo hạ tầng đã chuẩn hoá" → **Service Catalog**.

---

## 7. Bảo mật dữ liệu S3 – checklist
1. Bật **Block Public Access** (cấp account).
2. **Object Ownership = Bucket owner enforced** (tắt ACL).
3. Bucket policy `Deny` non-TLS; chỉ cho principal cần thiết; dùng `aws:SourceVpce`/**VPC endpoint policy** cho truy cập từ VPC; `aws:PrincipalOrgID` cho chia sẻ trong Org.
4. Mã hoá **SSE-KMS** (CMK) khi cần audit/kiểm soát khoá + **S3 Bucket Key** để giảm phí KMS.
5. **Versioning + MFA Delete + Object Lock** cho dữ liệu quan trọng/backup (chống ransomware).
6. **Pre-signed URL** cho chia sẻ tạm thời; **CloudFront + OAC + signed URL** cho phân phối nội dung riêng tư.
7. **Macie** dò PII; **Access Analyzer for S3** thấy ai bên ngoài truy cập được; **Config rule** phát hiện bucket public.
8. **CloudTrail data events** cho bucket nhạy cảm (ai đọc object nào).
9. **Server access logs** hoặc CloudTrail cho điều tra.

---

## 8. Bẫy thường gặp
1. "Xoay vòng secret tự động" → **Secrets Manager** (không phải Parameter Store).
2. "Ai đã xoá bucket/terminate instance?" → **CloudTrail**. "Cấu hình SG bị đổi lúc nào / bucket có tuân thủ không?" → **Config**.
3. "Phát hiện hành vi bất thường/đào coin trên EC2" → **GuardDuty**. "CVE trên EC2/ECR/Lambda" → **Inspector**.
4. "Tìm PII trong S3" → **Macie**.
5. "Chặn SQL injection/XSS" → **WAF** (gắn ALB/CloudFront/API GW); "chặn IP" → WAF IP set hoặc NACL; "rate limit theo IP" → **WAF rate-based rule**.
6. "Quản lý khoá trên HSM riêng, FIPS Level 3, tự quản" → **CloudHSM**.
7. "Giới hạn quyền tối đa cho toàn account trong Org" → **SCP**; "cho dev tự tạo role nhưng không vượt trần" → **permissions boundary**.
8. "Đăng nhập người dùng web/mobile + social login" → **Cognito User Pool**; "cấp quyền AWS trực tiếp cho user app" → **Identity Pool**.
9. "Truy cập S3 riêng tư qua CloudFront" → **OAC** (thay OAI cũ).
10. Cert cho CloudFront → ACM ở **us-east-1**.
11. EC2 cần quyền → **role/instance profile**; không nhúng key.
12. "Cross-account truy cập S3" → bucket policy cho principal account kia (+ IAM bên kia) hoặc assume role; object mã hoá CMK → thêm key policy.
13. "DDoS nâng cao, đội phản ứng 24/7, bảo vệ chi phí" → **Shield Advanced**.
14. "Áp WAF rule cho mọi ALB của mọi account trong Org" → **Firewall Manager**.
15. "Chỉ cho EC2 trong VPC gọi ra một số domain cụ thể" → **Network Firewall** (domain allowlist) hoặc DNS Firewall.
16. "Log CloudTrail không bị chỉnh sửa" → **log file validation** + S3 Object Lock + bucket ở account riêng.
17. "Phản ứng gần real-time khi ai đó gọi API nguy hiểm" → **EventBridge rule trên sự kiện CloudTrail** (không đợi file log S3).
18. "Ứng dụng AD-aware trên AWS, cần trust với AD on-prem" → **AWS Managed Microsoft AD**; "chỉ dùng lại AD on-prem để đăng nhập" → **AD Connector**.
19. "Mã hoá dữ liệu DynamoDB/S3 ở 2 Region bằng cùng khoá" → **KMS Multi-Region keys**.
20. "Server on-prem cần gọi API AWS mà không dùng access key dài hạn" → **IAM Roles Anywhere**.

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
9. Giải thích envelope encryption và vì sao cần nó.
10. Bạn muốn chia sẻ AMI mã hoá bằng `aws/ebs` cho account khác. Có được không? Làm thế nào?
11. Một SCP gắn vào OU Dev chỉ có `Deny ec2:TerminateInstances`. Admin của account trong OU (có `AdministratorAccess`) còn làm được gì?
12. Phân biệt GuardDuty, Inspector, Macie bằng một câu mỗi cái.
13. Thiết kế để mỗi người dùng app mobile chỉ upload/đọc file trong "thư mục" S3 của chính mình.
14. Làm sao phát hiện và tự động sửa bucket S3 bị bật public?
15. Công ty có AD on-prem, muốn nhân viên đăng nhập Console của 30 account bằng tài khoản AD. Giải pháp?

<details><summary>Đáp án</summary>

1. CMK: bạn quản lý key policy, rotation (tuỳ chọn, chỉnh chu kỳ), vô hiệu hoá/xoá, chia sẻ cross-account, tốn phí; AWS managed: AWS quản lý, tự rotate hằng năm, không sửa policy, không chia sẻ cross-account, không tính phí key.
2. Tạo **organization/multi-Region trail** ghi vào S3 ở account log riêng (bật log file validation, SSE-KMS, Object Lock + lifecycle 5 năm), tuỳ chọn gửi CloudWatch Logs hoặc dùng CloudTrail Lake.
3. Secrets Manager với rotation (managed rotation cho RDS); EC2 dùng IAM role có `secretsmanager:GetSecretValue` (và `kms:Decrypt` nếu dùng CMK).
4. SCP: trần cho cả account/OU trong Organizations (kể cả root của member). Boundary: trần cho một user/role cụ thể. Cả hai chỉ giới hạn, không tự cấp quyền.
5. ALB, CloudFront, API Gateway (REST), AppSync, Cognito User Pool (và một số dịch vụ khác như App Runner). Không gắn NLB/EC2 trực tiếp (đặt CloudFront/ALB phía trước).
6. User Pool = đăng nhập/authN, trả JWT. Identity Pool = đổi token lấy credential AWS tạm (authZ) để gọi dịch vụ AWS trực tiếp.
7. Cần HSM riêng single-tenant, tự quản khoá hoàn toàn (AWS không truy cập), chuẩn FIPS Level 3, hoặc cần PKCS#11/JCE/CNG, SSL offload, Oracle TDE.
8. Key policy là bắt buộc; cần key policy cho phép (trực tiếp hoặc qua statement uỷ quyền cho account → IAM policy).
9. KMS sinh data key; data key mã hoá dữ liệu cục bộ; data key được mã hoá bởi KMS key và lưu cùng dữ liệu. Cần vì KMS chỉ mã hoá trực tiếp ≤ 4 KB và để tránh gửi dữ liệu lớn qua mạng tới KMS (nhanh, rẻ).
10. Không trực tiếp. Copy AMI (snapshot) và mã hoá lại bằng **CMK**, cấp quyền key cho account đích trong key policy, rồi chia sẻ AMI.
11. Mọi thứ `AdministratorAccess` cho phép **trừ** terminate EC2 (giả sử OU/root vẫn có `FullAWSAccess`). Explicit Deny trong SCP thắng.
12. GuardDuty: phát hiện mối đe doạ/hành vi đáng ngờ từ log. Inspector: quét lỗ hổng phần mềm và lộ mạng. Macie: tìm dữ liệu nhạy cảm trong S3.
13. Cognito User Pool (đăng nhập) + Identity Pool (credential tạm) với IAM policy giới hạn `arn:aws:s3:::bucket/users/${cognito-identity.amazonaws.com:sub}/*`. (Hoặc backend cấp pre-signed URL theo user.)
14. **Config rule** `s3-bucket-public-read-prohibited`/`...-write-prohibited` + **auto remediation** (SSM Automation bật Block Public Access); phòng ngừa: Block Public Access cấp account + SCP cấm tắt nó.
15. **IAM Identity Center** với nguồn danh tính là AD (qua **AD Connector** hoặc AWS Managed Microsoft AD có trust), gán **permission set** cho nhóm AD trên từng account.
</details>

## Tài liệu nên đọc thêm
- Well-Architected: Security pillar. Whitepaper "AWS Security Incident Response Guide", "Organizing Your AWS Environment Using Multiple Accounts".
- Doc: "IAM policy evaluation logic", "AWS KMS concepts" (envelope encryption), "Key policies in AWS KMS", "Service control policies", "Amazon Cognito user pools vs identity pools", "AWS WAF – How it works".
- FAQ: KMS, CloudHSM, Secrets Manager, WAF, Shield, GuardDuty, Cognito, Organizations, Control Tower.
