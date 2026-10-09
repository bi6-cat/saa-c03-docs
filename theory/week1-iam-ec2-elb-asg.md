# Tuần 1 – Nền tảng: Global Infra, IAM, EC2, EBS, ELB, Auto Scaling

**Mục tiêu:** hiểu cách AWS tổ chức hạ tầng, kiểm soát truy cập bằng IAM, và dựng được kiến trúc web "chuẩn": ALB + Auto Scaling nhiều AZ.
**Lab đi kèm:** `labs/lab01-ec2-alb-asg`

> **Cách đọc file này**
> - Phần chữ thường: kiến thức cốt lõi, phải nắm.
> - **💡 Kinh nghiệm thực tế**: những gì hay gặp khi vận hành hệ thống thật (lỗi, chi phí, thói quen tốt). Không phải lúc nào cũng ra đề nhưng giúp bạn *hiểu vì sao* đáp án đúng.
> - **🎯 Mẹo thi**: cách đề SAA-C03 hay hỏi, từ khoá → đáp án.
> - Số liệu (giới hạn, giá) AWS thay đổi theo thời gian – khi làm thật hãy đối chiếu doc; khi thi, đề thường dùng số "kinh điển" ghi ở đây.

---

## 1. Hạ tầng toàn cầu & Shared Responsibility

### 1.1 Region, AZ, Edge

| Khái niệm | Ý nghĩa | Ghi nhớ |
|---|---|---|
| **Region** | Cụm data center độc lập về địa lý, ví dụ `ap-southeast-1` (Singapore) | Dữ liệu **không tự rời Region**. Chọn theo: compliance/luật dữ liệu, độ trễ, dịch vụ có sẵn, giá |
| **Availability Zone (AZ)** | 1+ data center tách biệt (nguồn điện, làm mát, mạng riêng) trong Region, nối nhau bằng mạng độ trễ thấp | HA = trải tài nguyên qua **≥ 2 AZ** (production nên 3) |
| **Edge Location / PoP** | Điểm của CloudFront, Route 53, Global Accelerator, WAF (cho CloudFront) | Không phải Region, không chạy EC2 |
| **Local Zone** | Mở rộng Region tới gần một thành phố lớn | Ứng dụng cần độ trễ một chữ số ms cho người dùng ở thành phố đó |
| **Wavelength** | Hạ tầng AWS đặt trong mạng 5G của nhà mạng | Ứng dụng mobile/edge siêu thấp trễ |
| **Outposts** | Rack AWS đặt trong data center của bạn | Cần dữ liệu ở on-prem nhưng dùng API AWS |

**4 tiêu chí chọn Region** (đề hay hỏi theo thứ tự ưu tiên):
1. **Compliance / chủ quyền dữ liệu** – luật bắt buộc dữ liệu ở quốc gia nào → loại hết các Region khác.
2. **Độ trễ** tới người dùng.
3. **Dịch vụ / tính năng có sẵn** (không phải Region nào cũng có mọi dịch vụ, mọi loại instance).
4. **Giá** (cùng dịch vụ, mỗi Region giá khác nhau; us-east-1 thường rẻ nhất).

**Phạm vi của dịch vụ** (rất quan trọng khi thiết kế HA):
- **Global**: IAM, Route 53, CloudFront, WAF gắn CloudFront, Organizations.
- **Regional**: S3 (bucket nằm ở 1 Region), DynamoDB, Lambda, SQS, VPC, ALB, ASG…
- **Zonal (gắn 1 AZ)**: EC2 instance, EBS volume, subnet, NAT Gateway, instance store. → Thứ gì zonal thì phải nhân bản qua nhiều AZ mới HA.

> 💡 **Kinh nghiệm thực tế**
> - **Tên AZ khác nhau giữa các account**: `ap-southeast-1a` ở account A có thể là data center khác `ap-southeast-1a` ở account B. Khi phối hợp nhiều account (VPC sharing, PrivateLink, đo độ trễ) hãy dùng **AZ ID** (vd. `apse1-az1`) – nó cố định cho mọi account.
> - Từ Việt Nam, Singapore (`ap-southeast-1`) thường cho độ trễ thấp và có gần như đủ dịch vụ. Trước khi chốt Region, mở trang "AWS Services by Region" kiểm tra dịch vụ bạn cần.
> - Không phải mọi AZ đều có mọi loại instance mới. Lỗi `InsufficientInstanceCapacity` hoặc "instance type not supported in this AZ" là chuyện thường – thiết kế ASG cho phép **nhiều loại instance** giúp tránh.

### 1.2 Shared Responsibility Model

- AWS: bảo mật **của** cloud (phần cứng, data center, mạng vật lý, hypervisor, phần mềm của dịch vụ managed).
- Bạn: bảo mật **trong** cloud (IAM, dữ liệu, cấu hình Security Group, patch OS EC2, mã hoá, cấu hình ứng dụng).

| Loại dịch vụ | Ví dụ | AWS lo | Bạn lo |
|---|---|---|---|
| IaaS | EC2, EBS | Phần cứng, hypervisor | **OS (patch)**, runtime, app, firewall OS, SG, dữ liệu, IAM |
| Managed / PaaS | RDS, ElastiCache, EKS control plane | + OS, patch DB engine, backup hạ tầng | Cấu hình DB (user, quyền, tham số), SG, mã hoá bật/tắt, cửa sổ bảo trì |
| Serverless / abstracted | S3, DynamoDB, Lambda, SQS | + gần như toàn bộ nền tảng | **Dữ liệu, IAM/policy, mã hoá, code** của bạn |

> 🎯 **Mẹo thi**: câu hỏi kiểu "ai chịu trách nhiệm patch DB engine của RDS?" → AWS. "Ai chịu trách nhiệm cấu hình Security Group / bật mã hoá / quản lý IAM?" → **khách hàng**, kể cả với dịch vụ managed. "Patch OS của EC2" → khách hàng.

---

## 2. IAM (Identity and Access Management)

IAM là dịch vụ **global**, **miễn phí**, nhưng thay đổi có độ trễ lan truyền (eventual consistency) vài giây.

### 2.1 Thành phần

| Thành phần | Mô tả | Ghi chú |
|---|---|---|
| **Root user** | Email tạo account, quyền tuyệt đối, **không bị IAM policy giới hạn** (chỉ SCP giới hạn được, và chỉ với member account) | Chỉ dùng cho tác vụ chỉ root làm được |
| **IAM User** | Danh tính có credential **dài hạn** (password console, access key) | Hạn chế dùng cho người; ưu tiên Identity Center |
| **Group** | Tập user để gán quyền chung | Không lồng group; group không phải principal (không đặt trong `Principal`); 1 user tối đa 10 group |
| **Role** | Danh tính **không có credential dài hạn**, được *assume* để lấy credential tạm (STS) | Dùng cho dịch vụ AWS (EC2, Lambda…), cross-account, federation, Identity Center |
| **Policy** | Tài liệu JSON mô tả quyền | Identity-based, resource-based, boundary, SCP… |
| **Instance profile** | "Vỏ" chứa 1 role để gắn vào EC2 | Console tự tạo cùng tên khi tạo role cho EC2; dùng CLI/IaC phải tạo riêng |

**Các tác vụ chỉ root làm được** (đề thi thỉnh thoảng hỏi): đổi thông tin account / đóng account, đổi Support plan, khôi phục quyền khi admin IAM tự khoá mình, bật **MFA Delete** cho S3 bucket, một số thiết lập billing, đăng ký bán trên Reserved Instance Marketplace.

> 💡 **Kinh nghiệm thực tế – root user**
> - Bật MFA (tốt nhất là khoá cứng FIDO2 hoặc 2 thiết bị MFA – AWS cho đăng ký nhiều thiết bị), xoá mọi access key của root, cất mật khẩu vào password manager, rồi **gần như không đăng nhập root nữa**.
> - Gắn email root là một **email nhóm/alias** (không phải email cá nhân nhân viên) để không mất quyền khi người đó nghỉ việc.
> - Trong AWS Organizations hiện có thể quản lý tập trung root credential của member account (xoá luôn password root của member) – tìm hiểu "centralized root access" khi làm multi-account.

### 2.2 Cấu trúc policy

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ReadOwnBucketOverTLS",
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"],
    "Condition": { "Bool": { "aws:SecureTransport": "true" } }
  }]
}
```

| Phần tử | Ý nghĩa |
|---|---|
| `Version` | Luôn dùng `"2012-10-17"` (bản cũ hơn không hỗ trợ policy variable) |
| `Sid` | Tên statement (tuỳ chọn) |
| `Effect` | `Allow` hoặc `Deny` |
| `Principal` | **Chỉ có trong resource-based policy** (bucket policy, trust policy…): ai được áp dụng |
| `Action` / `NotAction` | API được phép/bị cấm. `NotAction` = "mọi thứ trừ…" (cẩn thận khi dùng với Allow) |
| `Resource` / `NotResource` | ARN tài nguyên |
| `Condition` | Điều kiện: IP, MFA, tag, VPC endpoint, Region, thời gian… |

> ⚠️ **Hay nhầm với S3**: `s3:ListBucket` áp lên **bucket ARN** (`arn:aws:s3:::my-bucket`), còn `s3:GetObject/PutObject` áp lên **object ARN** (`arn:aws:s3:::my-bucket/*`). Thiếu một trong hai là AccessDenied.

**Condition key hay dùng (global)**

| Key | Dùng để |
|---|---|
| `aws:SourceIp` | Giới hạn IP công khai gọi API (không áp dụng khi đi qua VPC endpoint – lúc đó dùng `aws:SourceVpce`/`aws:VpcSourceIp`) |
| `aws:SourceVpce`, `aws:SourceVpc` | Chỉ cho phép truy cập qua VPC endpoint / VPC cụ thể (hay dùng trong bucket policy) |
| `aws:SecureTransport` | Bắt buộc HTTPS |
| `aws:MultiFactorAuthPresent` | Bắt buộc đăng nhập có MFA |
| `aws:RequestedRegion` | Giới hạn Region được dùng |
| `aws:PrincipalOrgID` | Chỉ cho principal thuộc Organization của bạn (thay vì liệt kê từng account) |
| `aws:PrincipalTag/…`, `aws:ResourceTag/…`, `aws:RequestTag/…` | Phân quyền theo tag (**ABAC**) |
| `aws:SourceArn`, `aws:SourceAccount` | Chống *confused deputy* khi cho dịch vụ AWS (SNS, CloudFront…) truy cập tài nguyên |

**Policy variable**: `${aws:username}`, `${aws:PrincipalTag/team}`… Ví dụ cho mỗi user một "thư mục nhà" trong S3:

```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject"],
  "Resource": "arn:aws:s3:::company-home/${aws:username}/*"
}
```

**Trust policy** (resource-based policy *của role*: ai được assume role này):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

Cho bên thứ ba (vd. công cụ SaaS giám sát) assume role trong account bạn → thêm **External ID** để chống *confused deputy*:

```json
{
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111122223333:root" },
  "Action": "sts:AssumeRole",
  "Condition": { "StringEquals": { "sts:ExternalId": "a1b2c3-unique-per-customer" } }
}
```

### 2.3 Các loại policy

| Loại | Gắn vào | Cấp quyền? | Ghi chú |
|---|---|---|---|
| **AWS managed policy** | user/group/role | Có | AWS viết & cập nhật (vd. `ReadOnlyAccess`). Tiện nhưng thường **rộng hơn cần** |
| **Customer managed policy** | user/group/role | Có | Bạn viết, tái sử dụng, có version (giữ tối đa 5 version) |
| **Inline policy** | 1 user/group/role cụ thể | Có | Gắn chặt 1-1, bị xoá cùng danh tính. Dùng khi muốn quyền không bị gắn nhầm chỗ khác |
| **Resource-based policy** | Tài nguyên (S3, SQS, SNS, KMS, Lambda, Secrets Manager, ECR…, trust policy của role) | Có | Có `Principal`; cho phép **cross-account** mà không cần assume role |
| **Permissions boundary** | user/role | **Không** | Trần quyền tối đa của danh tính đó |
| **SCP** (Organizations) | OU/account | **Không** | Trần quyền cho mọi principal trong account (kể cả root của member account); **không áp cho management account** và service-linked role |
| **RCP** (Resource Control Policy, Organizations) | OU/account | **Không** | Trần quyền ở phía **tài nguyên** (S3, KMS, SQS, STS, Secrets Manager…) – dùng dựng "data perimeter" |
| **Session policy** | Truyền khi `AssumeRole`/federation | **Không** | Thu hẹp thêm quyền của phiên |
| **ACL** | S3 object/bucket (cũ) | Có | Legacy; khuyên **tắt** (Bucket owner enforced) |

### 2.4 Logic đánh giá quyền (rất hay ra đề)

```
Request đến
   │
   ├─ Có explicit Deny ở BẤT KỲ policy nào (SCP, RCP, resource, identity, boundary, session)?
   │        └─ Có → DENY (dừng)
   │
   ├─ SCP/RCP của Organization có Allow hành động này không?        Không → DENY
   ├─ Resource-based policy có Allow cho principal này không?      Có → (cùng account) thường ALLOW*
   ├─ Identity-based policy có Allow không?                         Không → DENY (implicit)
   ├─ Permissions boundary (nếu có) có Allow không?                 Không → DENY
   ├─ Session policy (nếu có) có Allow không?                       Không → DENY
   └─ ALLOW
```
\* Chi tiết tinh vi giữa resource-based và boundary/session ít khi ra đề; nhớ quy tắc tổng quát dưới đây là đủ.

**Quy tắc vàng**
1. Mặc định **implicit deny**.
2. **Explicit Deny thắng tất cả.**
3. Cần ít nhất 1 **Allow**, và Allow phải nằm **trong mọi "trần"** đang áp dụng (SCP, RCP, boundary, session policy). Quyền hiệu lực = **giao** của các trần với tập Allow.
4. **Cùng account**: Allow ở identity-based **hoặc** resource-based là đủ.
5. **Cross-account**: cần Allow ở **cả hai** phía – identity policy bên gọi **và** resource-based policy bên tài nguyên; hoặc principal **assume role** sang account kia (khi đó role bên kia cần trust policy + quyền).

**Hai cách cross-account – khác nhau ở đâu?**

| | Resource-based policy (vd. bucket policy cho account B) | Assume role sang account A |
|---|---|---|
| Principal giữ quyền gốc? | **Có** – vẫn dùng quyền của mình ở account B cùng lúc | **Không** – trong phiên role chỉ có quyền của role |
| Dùng được cho | Dịch vụ hỗ trợ resource policy (S3, SQS, SNS, KMS, Lambda…) | Mọi dịch vụ |
| Ví dụ | Copy dữ liệu từ bucket A sang bucket B trong một lệnh | Admin trung tâm quản trị nhiều account |

> 💡 **Kinh nghiệm thực tế – debug AccessDenied**
> 1. Luôn chạy `aws sts get-caller-identity` trước: rất nhiều lỗi do bạn đang dùng **sai profile/role**.
> 2. Thông báo lỗi dạng mã hoá (EC2 hay trả) → `aws sts decode-authorization-message --encoded-message <msg>`.
> 3. Message mới của AWS thường ghi rõ "...because no identity-based policy allows" hoặc "...with an explicit deny in a service control policy" → đọc kỹ để biết phải sửa ở **tầng nào**.
> 4. Dùng **IAM Policy Simulator** hoặc `aws iam simulate-principal-policy` (lab05 dùng lệnh này) để kiểm thử trước.
> 5. Nhớ các "trần" vô hình: SCP của Org, permissions boundary, key policy của KMS, bucket policy có Deny, VPC endpoint policy. Admin "full quyền" vẫn có thể bị chặn bởi những thứ này.
> 6. Thay đổi IAM có độ trễ vài giây – script tạo role rồi dùng ngay lập tức đôi khi lỗi, cần retry/sleep ngắn.

### 2.5 Role cho dịch vụ AWS – cơ chế credential tạm

- EC2 gắn instance profile → SDK/CLI trên máy tự lấy credential tạm từ **Instance Metadata Service** (`169.254.169.254`), credential tự xoay vòng trước khi hết hạn. **Không cần và không nên** cấu hình access key trên máy.
- Lambda/ECS task/EKS pod: tương tự, nhận credential qua biến môi trường hoặc endpoint riêng (**task role**, **IRSA / EKS Pod Identity**).
- **Service-linked role**: role do dịch vụ tự tạo (vd. `AWSServiceRoleForAutoScaling`), bạn không sửa quyền được; SCP không chặn được role này.
- **STS**: `AssumeRole` trả credential có hạn 15 phút – tối đa `MaxSessionDuration` của role (mặc định 1 giờ, tối đa 12 giờ). **Role chaining** (từ role này assume role khác) bị giới hạn **1 giờ**.

### 2.6 IAM Identity Center vs IAM User

| | IAM Identity Center (SSO) | IAM User |
|---|---|---|
| Credential | Tạm thời (qua portal / `aws configure sso`) | Dài hạn (password + access key) |
| Nhiều account | Một lần đăng nhập vào nhiều account qua **permission set** | Phải tạo user ở từng account |
| Nguồn danh tính | Thư mục nội bộ, AD, IdP ngoài (Okta, Entra ID… qua SAML + SCIM) | Riêng IAM |
| Khuyến nghị | **Mặc định cho con người** | Chỉ khi bắt buộc (vd. ứng dụng cũ ngoài AWS cần access key – nhưng nên xem *IAM Roles Anywhere*) |

### 2.7 Công cụ IAM nên biết

| Công cụ | Làm gì |
|---|---|
| **IAM Access Analyzer** | Tìm tài nguyên chia sẻ ra **ngoài** account/Org (S3, role, KMS, Lambda, SQS…); tìm **quyền không dùng** (unused access); **sinh policy** từ lịch sử CloudTrail; validate policy |
| **Credential report** | CSV toàn bộ user: password/key/MFA, lần dùng cuối → audit định kỳ |
| **Last accessed (Access Advisor)** | Dịch vụ nào user/role được cấp nhưng chưa từng dùng → thu hẹp quyền |
| **Policy Simulator** | Thử "nếu gọi API X thì có được không" |

### 2.8 Best practices (bản đầy đủ)

- Khoá root (MFA, không access key).
- Con người dùng **Identity Center/federation**, workload dùng **role** → không còn credential dài hạn.
- **Least privilege**: bắt đầu từ managed policy để chạy được, sau đó dùng Access Analyzer sinh policy hẹp hơn.
- Bật **MFA** cho mọi người dùng; dùng condition `aws:MultiFactorAuthPresent` cho hành động nhạy cảm.
- Dùng **permissions boundary** khi cho phép developer tự tạo role (họ không thể tạo role mạnh hơn trần).
- **ABAC** (phân quyền theo tag) khi số lượng dự án/team tăng nhanh – một policy dùng cho nhiều team.
- Audit định kỳ: credential report, access key cũ > 90 ngày, user không hoạt động.

> 🎯 **Mẹo thi – IAM**
> - Thấy đáp án "tạo IAM user, lưu access key vào EC2/user data/code" → **gần như luôn sai**. Đáp án đúng: **IAM role / instance profile**.
> - "Cho developer tự tạo role nhưng không vượt quyền của họ" → **permissions boundary**.
> - "Ngăn mọi account trong Org dùng Region ngoài danh sách" → **SCP** với `aws:RequestedRegion`.
> - "Bên thứ ba truy cập account của bạn" → **cross-account role + External ID**, không đưa access key.
> - "Cho ứng dụng mobile truy cập S3 với quyền theo từng người dùng" → **Cognito Identity Pool** (tuần 5), không phải IAM user cho mỗi người.

---

## 3. EC2

### 3.1 Đọc tên instance

`m7g.2xlarge` = họ **m** · thế hệ **7** · thuộc tính **g** (Graviton/ARM) · kích thước **2xlarge**.
Thuộc tính hay gặp: `g` = Graviton, `a` = AMD, `i` = Intel, `d` = có NVMe instance store, `n` = mạng tăng cường, `e` = thêm RAM/storage, `z` = tần số CPU cao.
Mỗi bậc size gấp đôi tài nguyên: `large` (2 vCPU) → `xlarge` (4) → `2xlarge` (8)…

| Họ | Dùng cho | Ví dụ use case |
|---|---|---|
| **T** (burstable) | Tải nhẹ, thỉnh thoảng tăng vọt | Web nhỏ, dev/test, bastion |
| **M** | General purpose, cân bằng CPU/RAM | App server, backend |
| **C** | Compute-optimized | Batch, encoding, game server, HPC, web tải cao |
| **R / X / z** | Memory-optimized | In-memory DB, cache lớn, SAP HANA, phân tích real-time |
| **I / D / H** | Storage-optimized (instance store NVMe/HDD lớn) | NoSQL (Cassandra), data warehouse, Elasticsearch, IOPS cực cao |
| **G / P / Inf / Trn** | Tăng tốc (GPU, chip ML) | Training/inference ML, đồ hoạ |
| **Mac** | macOS trên Dedicated Host | Build app iOS |

**Graviton** (ARM, hậu tố `g`): theo AWS cho hiệu năng/giá tốt hơn đáng kể so với x86 cùng thế hệ (tới ~40% với Graviton2). Phần lớn workload Linux, container, ngôn ngữ thông dịch (Python, Node, Java) chạy được ngay; cần build lại image ARM nếu dùng container.

**Nitro System**: nền tảng ảo hoá hiện đại của AWS (gần như mọi instance mới). Yêu cầu Nitro cho: EBS Multi-Attach, một số tính năng mạng, hiệu năng EBS cao.

### 3.2 Burstable (T2/T3/T4g)
- Instance tích **CPU credit** khi dùng CPU dưới mức *baseline* (vd. t3.micro baseline 10%), tiêu credit khi vượt baseline.
- **Standard mode**: hết credit → CPU bị ép về baseline (ứng dụng chậm hẳn).
- **Unlimited mode**: vượt baseline tiếp, nhưng **trả thêm tiền** nếu trung bình vượt baseline lâu. **T3/T3a/T4g mặc định là Unlimited**.

> 💡 **Kinh nghiệm thực tế**
> - Theo dõi metric `CPUCreditBalance` và `CPUSurplusCreditsCharged`. Instance T chạy CPU cao liên tục → chuyển sang M/C sẽ **rẻ và ổn định hơn**.
> - "Server đột nhiên chậm mỗi chiều" mà dùng t2/t3 standard → nghi ngay hết credit.

### 3.3 Vòng đời instance

| Hành động | Instance store | EBS root | Public IPv4 (tự gán) | Private IP | Tính phí compute |
|---|---|---|---|---|---|
| **Reboot** | Giữ | Giữ | Giữ | Giữ | Có |
| **Stop** | **Mất** | Giữ | **Đổi** (cấp IP mới khi start) | Giữ | Không (vẫn trả EBS) |
| **Hibernate** | Mất | Giữ + RAM được ghi vào root EBS | Đổi | Giữ | Không |
| **Terminate** | Mất | Xoá nếu `DeleteOnTermination=true` (mặc định với root) | Mất | Mất | Không |

- Cần IP công khai cố định qua stop/start → **Elastic IP** (hoặc đặt sau ALB/NLB).
- **Hibernate**: khởi động lại nhanh, giữ trạng thái RAM (app khởi động lâu, cache nóng). Yêu cầu root EBS **mã hoá**, RAM giới hạn (<150 GB), không quá 60 ngày.
- **Termination protection** chống xoá nhầm qua API/Console (không chặn được việc OS tự shutdown nếu *shutdown behavior = terminate*, cũng không chặn ASG scale-in).

### 3.4 AMI
- AMI = snapshot EBS root (+ volume phụ) + metadata (kiến trúc, quyền launch, block device mapping).
- **Gắn với Region** → `copy-image` sang Region khác (cho DR/multi-region).
- Chia sẻ AMI cho account khác: sửa launch permission. AMI **mã hoá** → phải chia sẻ cả **KMS key (customer managed)**; AMI mã hoá bằng key mặc định `aws/ebs` **không chia sẻ được** → copy lại bằng CMK trước.
- **Golden AMI**: AMI đã cài sẵn agent, bản vá, phần mềm → giảm thời gian boot trong ASG (thay vì user data cài mọi thứ mỗi lần). Tự động hoá bằng **EC2 Image Builder**.

> 💡 **Kinh nghiệm thực tế**
> - **Deregister AMI không xoá snapshot** bên dưới → snapshot mồ côi vẫn tính tiền. Dọn cả hai.
> - Lấy ID AMI Amazon Linux mới nhất không cần hard-code, dùng **SSM public parameter**:
>   `aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text`
>   (trong Launch Template có thể tham chiếu thẳng `resolve:ssm:...`).

### 3.5 User data & Instance Metadata
- **User data**: script chạy **một lần ở lần boot đầu tiên** với quyền root (mặc định). Giới hạn 16 KB. Log trên Amazon Linux: `/var/log/cloud-init-output.log` – **chỗ đầu tiên phải xem khi web không lên**.
- **Instance metadata** `http://169.254.169.254/latest/meta-data/`: instance-id, AZ, IP, credential của role…
- **IMDSv2** (token, session-oriented) chống tấn công **SSRF** đánh cắp credential. Nên đặt **"V2 only (token required)"** (lab01 yêu cầu).

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone
```

> 💡 **Kinh nghiệm thực tế**
> - Chạy **container trên EC2** (Docker, ECS-on-EC2, EKS node) mà container không lấy được metadata khi bật IMDSv2 → tăng **hop limit** lên 2 (mặc định 1), vì gói tin đi qua thêm một "hop" mạng của container.
> - User data lỗi giữa chừng thì script không tự chạy lại ở lần boot sau. Debug xong nên đưa vào AMI hoặc dùng công cụ cấu hình (SSM State Manager, Ansible).

### 3.6 Mô hình mua (purchasing options)

| Loại | Đặc điểm | Giảm giá (tham khảo) | Dùng khi |
|---|---|---|---|
| **On-Demand** | Trả theo giây (Linux/Windows) hoặc giờ, không cam kết | 0% | Tải không đoán trước, ngắn hạn, thử nghiệm |
| **Compute Savings Plans** | Cam kết **$/giờ** 1 hoặc 3 năm; áp cho **mọi** họ/size/Region/OS EC2 + **Fargate + Lambda** | tới ~66% | Tải nền ổn định nhưng muốn linh hoạt đổi loại/Region/chuyển sang container |
| **EC2 Instance Savings Plans** | Cam kết $/giờ cho **một họ instance trong một Region** (đổi size/OS tuỳ ý) | tới ~72% | Biết chắc họ instance và Region |
| **Standard Reserved Instances** | Cam kết cấu hình (loại, Region, OS, tenancy) 1/3 năm; bán lại được trên RI Marketplace | tới ~72% | Tải cố định, ổn định |
| **Convertible RI** | Như RI nhưng đổi được sang cấu hình khác | thấp hơn Standard | Cần đổi loại instance trong kỳ cam kết |
| **Spot** | Dùng dung lượng dư; AWS có thể thu hồi với **cảnh báo 2 phút** | tới ~90% | Batch, CI/CD, big data, render, xử lý ảnh, stateless web phía sau ASG |
| **Dedicated Host** | Nguyên máy vật lý riêng, **thấy socket/core**, chọn host đặt instance | — | **BYOL** theo socket/core (Windows Server, SQL Server, Oracle), compliance |
| **Dedicated Instance** | Instance chạy trên phần cứng chỉ của account bạn, không kiểm soát host | — | Yêu cầu cô lập phần cứng, không cần quản host |
| **On-Demand Capacity Reservation** | **Giữ chỗ** dung lượng trong 1 AZ, trả như On-Demand dù không chạy | 0% (ghép SP/RI để giảm) | Sự kiện lớn, DR cần đảm bảo có máy |

**Tuỳ chọn thanh toán** (RI/SP): All Upfront (rẻ nhất) > Partial Upfront > No Upfront.

**Spot chi tiết**
- Khi bị thu hồi: hành vi *terminate* (mặc định), *stop* hoặc *hibernate*. Nhận cảnh báo qua metadata (`spot/instance-action`) và EventBridge; còn có **Rebalance recommendation** báo sớm rủi ro.
- **Spot Fleet / EC2 Fleet / ASG mixed instances**: yêu cầu nhiều loại instance, nhiều AZ. Chiến lược phân bổ khuyên dùng: **price-capacity-optimized** (vừa rẻ vừa ít bị thu hồi).
- Thiết kế cho Spot: stateless, checkpoint công việc (lưu tiến độ lên S3/DynamoDB), lấy việc từ hàng đợi SQS (bị thu hồi thì message tự hiện lại).

> 💡 **Kinh nghiệm thực tế – chiến lược chi phí "3 tầng"**
> 1. Phần tải **nền 24/7** → Savings Plans (Compute SP nếu chưa chắc tương lai).
> 2. Phần **biến động dự đoán được** → On-Demand trong ASG.
> 3. Phần **chịu gián đoạn** → Spot (đa dạng ≥ 5–10 loại instance để giảm thu hồi).
> Mua SP sau khi đã **right-size** (chạy Compute Optimizer vài tuần), nếu không bạn cam kết trả tiền cho máy quá to trong 1–3 năm.

> 🎯 **Mẹo thi**
> - "Chịu gián đoạn / có thể khởi động lại / batch / rẻ nhất" → **Spot**.
> - "Chạy 24/7 ổn định 1–3 năm, rẻ nhất" → **RI/Savings Plans (3 năm, All Upfront)**. Thêm "có thể đổi họ instance/chuyển sang Lambda/Fargate" → **Compute Savings Plans**.
> - "License theo socket/core" → **Dedicated Host**.
> - "Phải chắc chắn có dung lượng trong AZ X vào ngày Y" → **Capacity Reservation** (RI zonal cũng giữ chỗ nhưng cam kết dài).
> - "Spot instance không được dùng cho DB chính / workload không chịu gián đoạn".

### 3.7 Placement Groups

| Loại | Cách đặt | Ưu | Nhược / giới hạn | Use case |
|---|---|---|---|---|
| **Cluster** | Gần nhau trong **1 AZ** (cùng rack/gần rack) | Độ trễ thấp nhất, băng thông cao giữa node | Hỏng rack/AZ là ảnh hưởng tất cả | HPC, MPI, big data cần trao đổi node-node nhanh |
| **Spread** | Mỗi instance trên **phần cứng khác nhau** | Giảm lỗi đồng thời | **Tối đa 7 instance đang chạy/AZ/group** | Ít instance nhưng cực quan trọng (vd. 3 node quorum) |
| **Partition** | Chia thành partition (≤ 7 partition/AZ), mỗi partition 1 nhóm rack riêng | Hàng trăm instance, cô lập lỗi theo partition, app biết partition qua metadata | — | Hadoop/HDFS, Cassandra, Kafka |

> 💡 Cluster placement group nên **launch tất cả instance cùng lúc, cùng loại**; thêm sau dễ gặp lỗi thiếu dung lượng.

### 3.8 Mạng của EC2
- **ENI** (Elastic Network Interface): card mạng ảo – private IP chính/phụ, SG, MAC. Gắn/tách sang instance khác **cùng AZ** → kỹ thuật failover cũ (chuyển ENI/IP sang máy dự phòng).
- **Public IPv4**: tự gán khi launch (đổi khi stop/start). **Elastic IP**: IP tĩnh của bạn. Từ 2024 AWS tính phí **mọi** public IPv4 (~0,005 USD/giờ/IP), dù đang gắn hay không → hạn chế public IP, đặt sau ALB, dùng IPv6 khi có thể.
- **Enhanced Networking (ENA)**: băng thông cao, PPS cao, độ trễ thấp – mặc định trên instance hiện đại.
- **EFA** (Elastic Fabric Adapter): ENA + bypass kernel cho HPC/ML phân tán (MPI, NCCL), chỉ Linux.
- **Source/destination check**: mặc định bật; **phải tắt** khi instance làm NAT/router/firewall.

### 3.9 Truy cập vào instance

| Cách | Cần mở port? | Ghi chú |
|---|---|---|
| SSH/RDP với key pair | 22/3389 | Cách truyền thống; key pair là ở Region |
| Bastion host | 22 ở bastion | Thêm một máy phải bảo vệ |
| **EC2 Instance Connect** | 22 (từ dải IP dịch vụ) | Đẩy SSH key tạm 60 giây qua IAM |
| **EC2 Instance Connect Endpoint** | Không cần public IP | SSH/RDP vào instance private không cần bastion |
| **SSM Session Manager** | **Không mở port inbound nào** | Kiểm soát bằng IAM, log phiên vào S3/CloudWatch. Cần SSM Agent + role `AmazonSSMManagedInstanceCore` + đường ra endpoint SSM (NAT hoặc interface endpoint `ssm`, `ssmmessages`, `ec2messages`) |

> 🎯 "Truy cập shell an toàn, không mở port 22, có audit" → **Session Manager**.

### 3.10 Giám sát EC2
- Metric mặc định: CPU, network, disk I/O (của instance store), status check. Basic monitoring 5 phút, **detailed monitoring 1 phút** (có phí).
- **RAM, dung lượng đĩa trống, số process KHÔNG có sẵn** → cài **CloudWatch Agent** (đề hay bẫy chỗ này).
- **Status check**: *System* (lỗi phía hạ tầng AWS → stop/start để chuyển host, hoặc **auto recovery**) vs *Instance* (lỗi trong OS → bạn tự sửa/reboot) vs *Attached EBS*.

---

## 4. EBS & Instance Store

### 4.1 EBS cơ bản
- Ổ **block qua mạng**, **gắn với 1 AZ**, được sao chép trong AZ đó (không chịu được mất AZ).
- Tồn tại độc lập với instance (tuỳ cờ `DeleteOnTermination`). Thường 1 volume gắn 1 instance tại một thời điểm.
- Trả tiền theo **dung lượng cấp phát** (GB-tháng) + IOPS/throughput cấp thêm, **không phải** dung lượng đã dùng.
- Độ bền: 99,8–99,9% (gp/st/sc/io1), **99,999% với io2**.

### 4.2 Các loại volume

| Loại | Kiểu | Hiệu năng | Boot? | Dùng khi |
|---|---|---|---|---|
| **gp3** | SSD | Nền **3.000 IOPS + 125 MiB/s** bất kể dung lượng; mua thêm IOPS/throughput **độc lập** (cổ điển tới 16.000 IOPS / 1.000 MiB/s – AWS đã nâng thêm, xem doc) | Có | **Mặc định cho hầu hết** |
| **gp2** | SSD | 3 IOPS/GiB (tối thiểu 100), burst 3.000 cho volume nhỏ, tối đa 16.000 | Có | Cũ – nên chuyển sang gp3 |
| **io1** | SSD provisioned | tới 64.000 IOPS | Có | DB cần IOPS cao (cũ) |
| **io2 Block Express** | SSD provisioned | tới **256.000 IOPS**, 4.000 MiB/s, 64 TiB, độ trễ sub-ms, bền 99,999% | Có | DB quan trọng: Oracle, SQL Server, SAP, IOPS cực cao |
| **st1** | HDD throughput | tới 500 MiB/s | **Không** | Big data, log, ETL đọc tuần tự |
| **sc1** | HDD cold | tới 250 MiB/s, rẻ nhất | **Không** | Dữ liệu ít truy cập vẫn cần trên block |

> Lưu ý: IOPS thực tế còn bị giới hạn bởi **băng thông EBS của instance** – volume io2 256K IOPS gắn vào instance nhỏ sẽ không đạt được. Dùng instance **EBS-optimized** (mặc định với Nitro).

> 💡 **Kinh nghiệm thực tế**
> - **gp2 → gp3**: thường rẻ hơn ~20% và hiệu năng nền tốt hơn với volume nhỏ. Đổi bằng **Elastic Volumes** ngay khi đang chạy, không downtime. Đây là "quick win" chi phí phổ biến nhất.
> - **Elastic Volumes**: tăng dung lượng/đổi loại/đổi IOPS khi đang chạy, nhưng **không thu nhỏ được**, và thường phải chờ ~6 giờ giữa hai lần sửa. Tăng dung lượng xong **phải mở rộng filesystem** trong OS: `sudo growpart /dev/nvme0n1 1` rồi `sudo xfs_growfs -d /` (XFS) hoặc `sudo resize2fs /dev/nvme0n1p1` (ext4).
> - Volume tạo từ snapshot **đọc lần đầu rất chậm** (dữ liệu được tải lười từ S3). DB vừa restore chạy chậm bất thường là vì vậy → "khởi tạo" bằng cách đọc toàn bộ (`fio`/`dd`) hoặc bật **Fast Snapshot Restore** (tính phí theo giờ/AZ).

### 4.3 Snapshot
- Lưu vào S3 (do AWS quản lý, bạn không thấy bucket), **incremental** (chỉ block thay đổi), nhưng xoá snapshot cũ vẫn khôi phục được snapshot mới (AWS tự giữ block cần thiết).
- Nên snapshot khi ứng dụng nhất quán (flush/freeze FS) hoặc dùng AWS Backup.
- Copy snapshot **sang Region khác** (DR), **chia sẻ** cho account khác (snapshot mã hoá → cần chia sẻ CMK).
- **EBS Snapshot Archive**: rẻ hơn ~75%, khôi phục mất 24–72 giờ, lưu tối thiểu 90 ngày → snapshot giữ lâu để tuân thủ.
- **Recycle Bin**: rule giữ snapshot/AMI bị xoá trong X ngày → chống xoá nhầm.
- **Data Lifecycle Manager (DLM)** / **AWS Backup**: lịch snapshot, giữ N bản, copy cross-Region tự động.

### 4.4 Mã hoá EBS
- AES-256 qua KMS, **trong suốt** với OS, gần như không ảnh hưởng hiệu năng. Mã hoá cả dữ liệu at rest, dữ liệu di chuyển giữa instance–volume, snapshot, volume tạo từ snapshot.
- Bật **"EBS encryption by default"** theo từng Region → mọi volume mới tự mã hoá. (Nên bật ngay ở mọi account.)
- Mã hoá volume đang chưa mã hoá: **snapshot → copy snapshot bật encryption → tạo volume từ snapshot đã mã hoá → thay volume** (hoặc tạo volume mới từ snapshot chưa mã hoá với tuỳ chọn encrypt).

### 4.5 Multi-Attach
- Chỉ **io1/io2**, gắn 1 volume vào **tối đa 16 instance Nitro trong cùng AZ**.
- Ứng dụng phải tự quản lý ghi đồng thời (filesystem cluster-aware như GFS2) – **không** dùng ext4/XFS thông thường.
- Use case hiếm (cluster ứng dụng đặc thù). Nhu cầu "nhiều máy dùng chung file" thông thường → **EFS/FSx**.

### 4.6 Instance Store
- Ổ NVMe/SSD/HDD **gắn trực tiếp trên host vật lý** → IOPS rất cao (hàng trăm nghìn – triệu), độ trễ cực thấp, không tính thêm tiền (đã nằm trong giá instance).
- **Ephemeral**: dữ liệu **còn qua reboot**, nhưng **mất khi stop, hibernate, terminate hoặc host hỏng**. Không snapshot được.
- Dùng cho: cache, buffer, scratch, dữ liệu tạm, dữ liệu đã được nhân bản ở tầng ứng dụng (Cassandra, Kafka với replication).

| | EBS | Instance Store | EFS |
|---|---|---|---|
| Kiểu | Block qua mạng | Block gắn host | File (NFS) |
| Phạm vi | 1 AZ | 1 host | Region (đa AZ) |
| Bền khi stop | Có | **Không** | Có |
| Chia sẻ nhiều instance | Không (trừ Multi-Attach) | Không | **Có, hàng nghìn** |
| Hiệu năng | Tới 256K IOPS (io2 BE) | Cao nhất | Thấp hơn block, scale theo dung lượng/throughput mode |
| Giá | Thấp–vừa | Đã gồm trong instance | Cao hơn EBS nhiều lần/GB |

---

## 5. Elastic Load Balancing (ELB)

### 5.1 Khái niệm chung
- **Listener**: cổng + giao thức LB lắng nghe (HTTP:80, HTTPS:443, TCP:…).
- **Rule** (ALB): điều kiện → hành động.
- **Target group**: tập target (instance / IP / Lambda / ALB) + cấu hình health check, giao thức tới target.
- **Internet-facing** (DNS public, nằm ở public subnet) vs **internal** (chỉ private IP – dùng giữa các tầng nội bộ).
- ELB là dịch vụ managed, **tự scale**, đặt node ở mỗi AZ bạn bật; bạn truy cập qua **DNS name** (không dùng IP của ALB vì có thể đổi).

| Loại | Tầng | Đặc điểm nổi bật | Dùng khi |
|---|---|---|---|
| **ALB** | L7 (HTTP/HTTPS/gRPC, WebSocket) | Routing theo **host, path, header, method, query string, source IP**; target instance/IP/**Lambda**; redirect, fixed response, **xác thực Cognito/OIDC**; WAF; mutual TLS | Web, microservices, container (ECS dynamic port) |
| **NLB** | L4 (TCP/UDP/TLS) | Hàng triệu request/giây, độ trễ cực thấp, **IP tĩnh mỗi AZ / gắn Elastic IP**, giữ source IP, endpoint service cho **PrivateLink**, target có thể là ALB | Game, IoT, VoIP, giao thức phi-HTTP, cần IP cố định để đối tác whitelist |
| **GWLB** | L3 | Chuyển traffic trong suốt qua appliance (firewall/IDS/IPS) bằng **GENEVE port 6081** | Chèn appliance bên thứ ba (Palo Alto, Fortinet…) |
| **CLB** | L4/L7 | Thế hệ cũ | Không dùng cho thiết kế mới |

### 5.2 ALB chi tiết
- **Rule** được đánh giá theo **priority**; mỗi listener có rule default.
  Ví dụ: `/api/*` → TG-api; `/images/*` → TG-static; host `admin.example.com` → TG-admin; header `X-Canary: true` → TG-v2.
- **Weighted target groups**: forward 90% TG-blue / 10% TG-green → **canary / blue-green** ngay tại ALB.
- **Redirect HTTP → HTTPS** bằng rule của listener 80 (không cần code).
- **Target type Lambda**: ALB gọi Lambda với request HTTP dạng JSON.
- **ECS dynamic port mapping**: nhiều task trên cùng EC2, mỗi task cổng khác nhau; ALB tự route.
- **Header gửi tới target**: `X-Forwarded-For` (IP client thật), `X-Forwarded-Proto` (http/https), `X-Forwarded-Port`. Log của web server sẽ chỉ thấy IP của ALB nếu không đọc header này.
- **Sticky session**: cookie do ALB tạo (`AWSALB`, theo thời gian) hoặc cookie của ứng dụng.
- **Slow start**: tăng dần traffic cho target mới (app cần warm-up cache/JIT).
- **Idle timeout** mặc định 60 giây.

### 5.3 NLB chi tiết
- Một **IP tĩnh mỗi AZ** (hoặc gắn Elastic IP của bạn) → đối tác/firewall whitelist được.
- **Giữ nguyên source IP client** (target kiểu instance; kiểu IP thì tuỳ cấu hình hoặc dùng Proxy Protocol v2).
- Hỗ trợ **TLS termination**, UDP, và (từ 2023) gắn **Security Group**.
- Mẫu "**NLB → ALB**": cần IP tĩnh **và** routing L7.
- Endpoint service phía sau **PrivateLink** bắt buộc dùng NLB (hoặc GWLB).

### 5.4 Health check, cross-zone, draining, TLS
- **Health check** (ALB mặc định): interval 30 giây, timeout 5 giây, 5 lần OK → healthy, 2 lần lỗi → unhealthy, mã thành công 200.
- **Cross-zone load balancing**: chia đều cho mọi target ở mọi AZ thay vì chia đều theo AZ.
  - ALB: luôn bật ở mức LB, không tính phí data liên AZ (có thể tắt ở mức target group).
  - NLB/GWLB: **mặc định tắt**; bật thì **tính phí data liên AZ**.
  - Ví dụ tại sao quan trọng: AZ-a có 2 instance, AZ-b có 8 instance. Không cross-zone → mỗi AZ nhận 50%, 2 máy ở AZ-a mỗi máy gánh 25% tổng tải, quá tải.
- **Deregistration delay** (connection draining) mặc định **300 giây**: chờ request đang chạy xong rồi mới gỡ target.
- **TLS termination** ở LB với cert **ACM** (miễn phí, tự gia hạn). **SNI** cho nhiều cert/nhiều domain trên một listener 443 (ALB, NLB; CLB không hỗ trợ). **Security policy** chọn phiên bản TLS/cipher (vd. chỉ TLS 1.2+).
- Mã hoá end-to-end: LB re-encrypt tới target bằng HTTPS (target dùng cert tự ký cũng được).

> 💡 **Kinh nghiệm thực tế – vận hành ELB**
> - **Đọc mã lỗi**: `502 Bad Gateway` = target đóng kết nối/trả response lỗi (app crash, keep-alive timeout của app **nhỏ hơn** idle timeout của ALB → chỉnh keep-alive app > 60 giây); `503` = **không có target healthy** nào (hoặc chưa đăng ký); `504 Gateway Timeout` = target xử lý quá idle timeout hoặc SG/NACL chặn đường tới target.
> - **Health check path** nên là endpoint nhẹ (`/health`) kiểm tra chính process đó. Nếu `/health` gọi sâu xuống DB, khi DB chậm **mọi** target cùng unhealthy → ALB trả 503 toàn bộ (cascading failure).
> - Deploy chậm vì phải chờ 300 giây draining → hạ deregistration delay xuống 30–60 giây cho request ngắn.
> - Bật **access logs** của ALB ra S3 (query bằng Athena) – cực hữu ích khi điều tra lỗi/tấn công.
> - Đặt ALB ở **public subnet**, instance ở **private subnet**, SG instance chỉ cho phép **SG của ALB** (lab01 làm đúng mẫu này).

### 5.5 Bảng chọn nhanh
| Yêu cầu | Chọn |
|---|---|
| Routing theo URL path / hostname | ALB |
| Xác thực người dùng ở LB (Cognito, OIDC) | ALB |
| Gọi Lambda qua HTTP không dùng API Gateway | ALB (hoặc Lambda Function URL) |
| IP tĩnh / Elastic IP cho LB | NLB (hoặc Global Accelerator trước ALB) |
| TCP/UDP phi-HTTP, hàng triệu kết nối | NLB |
| Expose dịch vụ qua PrivateLink | NLB |
| Firewall bên thứ ba trong suốt | GWLB |

---

## 6. Auto Scaling Group (ASG)

### 6.1 Thành phần
- **Launch Template** (khuyên dùng, có version; Launch Configuration đã cũ/không còn hỗ trợ tính năng mới): AMI, instance type (hoặc danh sách), key pair, SG, IAM instance profile, user data, EBS, IMDSv2…
- **Capacity**: `min` (không bao giờ dưới), `desired` (mục tiêu hiện tại), `max` (trần chi phí/an toàn).
- **Subnets ở nhiều AZ** → ASG tự cân bằng số instance giữa các AZ.
- Gắn **Target Group** để instance tự đăng ký/huỷ đăng ký vào ALB/NLB.

### 6.2 Health check
- **EC2** (mặc định): chỉ thay khi status check EC2 lỗi (VM chết).
- **ELB**: thay cả instance mà VM vẫn chạy nhưng **app không trả lời health check** → nên bật khi có LB.
- **Health check grace period** (mặc định 300 giây): thời gian cho instance mới khởi động xong trước khi bị đánh giá. Đặt **quá ngắn** + app khởi động lâu → ASG liên tục giết instance mới ("vòng lặp launch–terminate"). Đặt quá dài → phát hiện lỗi chậm.

### 6.3 Scaling policies

| Policy | Cách hoạt động | Ví dụ |
|---|---|---|
| **Target tracking** (khuyên dùng) | Giữ metric quanh giá trị mục tiêu, ASG tự tạo alarm | CPU trung bình 50%; `ALBRequestCountPerTarget` = 1.000; network in |
| **Step scaling** | Theo các bậc ngưỡng của CloudWatch alarm | CPU 60–80% → +1; > 80% → +3 |
| **Simple scaling** | 1 alarm → 1 hành động, chờ cooldown | Cũ, ít dùng |
| **Scheduled** | Theo lịch | 8h sáng thứ 2–6 đặt min=10, 20h trả về min=2 |
| **Predictive** | ML dự đoán theo lịch sử (cần ~24 giờ+ dữ liệu, tốt với chu kỳ đều) | Tải tăng mỗi sáng – scale **trước** khi tải tới |

**Scale theo hàng đợi SQS** (rất hay ra đề): đừng dùng thẳng số message; tính **backlog per instance** = `ApproximateNumberOfMessagesVisible / số instance`, rồi target tracking với giá trị chấp nhận được = (độ trễ chấp nhận / thời gian xử lý 1 message).
Ví dụ: mỗi message xử lý 0,1 giây, chấp nhận trễ 10 giây → mục tiêu 100 message/instance.

### 6.4 Cooldown, warm-up, termination
- **Default cooldown** 300 giây (cho simple scaling); với target tracking/step dùng **instance warm-up** để metric của instance mới chưa ổn định không bị tính.
- **Termination policy mặc định** khi scale-in: chọn AZ có nhiều instance nhất → trong đó ưu tiên instance dùng launch template/configuration **cũ nhất** → … Có thể tuỳ chỉnh (OldestInstance, NewestInstance, AllocationStrategy…).
- **Scale-in protection**: bảo vệ instance đang làm việc dài khỏi bị scale-in.
- **AZ rebalancing**: khi AZ lệch (sau sự cố), ASG launch ở AZ thiếu trước rồi terminate ở AZ thừa.

### 6.5 Tính năng nâng cao
- **Lifecycle hooks**: tạm giữ instance ở trạng thái `Pending:Wait` (cài đặt, đăng ký vào hệ thống khác) hoặc `Terminating:Wait` (đẩy log, rút khỏi cluster) trước khi tiếp tục.
- **Warm pool**: giữ sẵn instance đã khởi tạo (stopped/hibernated) → scale-out nhanh cho app khởi động lâu.
- **Instance refresh**: cập nhật AMI/launch template mới cho cả ASG theo kiểu rolling, giữ `MinHealthyPercentage`, có checkpoint và rollback.
- **Mixed instances policy**: kết hợp On-Demand base + % Spot, nhiều loại instance (vd. `m6i.large`, `m6a.large`, `m5.large`, `m7g.large`…).
- **Capacity Rebalancing**: chủ động thay Spot khi có rebalance recommendation.

### 6.6 Kiến trúc chuẩn 3 tầng chịu lỗi

```
           Route 53 (Alias)
                │
        ┌───────▼────────┐
        │   ALB (public  │   SG-alb: 443/80 từ 0.0.0.0/0
        │ subnet, ≥2 AZ) │
        └───┬────────┬───┘
     AZ-a   │        │   AZ-b
  ┌─────────▼──┐  ┌──▼─────────┐
  │ EC2 (ASG)  │  │ EC2 (ASG)  │  private subnet, SG-web: 80 chỉ từ SG-alb
  └─────┬──────┘  └──────┬─────┘
        │   ElastiCache (session/cache)
  ┌─────▼──────┐  ┌──────▼─────┐
  │ RDS primary│◄─┤ RDS standby│  DB subnet, SG-db: 3306 chỉ từ SG-web
  └────────────┘  └────────────┘  (Multi-AZ, đồng bộ)
```

Nguyên tắc: **stateless web tier** (session ra ElastiCache/DynamoDB, file ra S3/EFS), mỗi tầng ≥ 2 AZ, SG tham chiếu SG theo chuỗi, chỉ ALB ra Internet.

> 💡 **Kinh nghiệm thực tế – ASG**
> - Instance mới cứ bị terminate liên tục → xem *Activity history* của ASG: thường do health check ELB fail (sai path/port, SG không cho ALB vào, user data lỗi) hoặc grace period quá ngắn.
> - Đừng SSH vào sửa tay một instance trong ASG – lần scale tiếp theo sẽ mất. Sửa **launch template/AMI** rồi **instance refresh**.
> - Đặt `max` hợp lý như "cầu chì chi phí": một bug vòng lặp hoặc tấn công có thể đẩy ASG lên max.
> - Scale-out nhanh, scale-in chậm (thận trọng) là cấu hình an toàn cho người dùng.

---

## 7. Bẫy thường gặp trong đề

1. "Ít công vận hành nhất" → ưu tiên dịch vụ managed/serverless hơn tự chạy trên EC2.
2. "Chịu mất 1 AZ" → nhiều AZ, không phải nhiều instance trong 1 AZ. Cluster placement group **không** HA.
3. "Dùng IAM user + access key trên EC2" → **sai**, đáp án đúng là **IAM role**.
4. "Cần IP tĩnh cho load balancer" → **NLB** (hoặc Global Accelerator), không phải ALB.
5. "Routing theo URL path / hostname" → **ALB**.
6. "Tải batch chịu được gián đoạn, rẻ nhất" → **Spot**. "Cam kết dài hạn, ổn định" → **Savings Plans/RI**.
7. "Dữ liệu tạm tốc độ cao" → **Instance Store**; "DB cần IOPS cao bền" → **io2 Block Express**.
8. EBS **không** chia sẻ trực tiếp giữa nhiều instance (trừ Multi-Attach io1/io2 cùng AZ) → dùng chung file nhiều instance Linux: **EFS**.
9. "Giám sát RAM/disk của EC2" → **CloudWatch Agent** (không có sẵn).
10. "App lưu session trên instance, người dùng bị đăng xuất khi scale-in" → đưa session ra **ElastiCache/DynamoDB** (sticky session chỉ là chữa cháy).
11. "Instance trong ASG không phục vụ được nhưng không bị thay" → bật **ELB health check** cho ASG.
12. "Tải tăng vào giờ cố định mỗi ngày" → **Scheduled** hoặc **Predictive scaling**.
13. "Giữ địa chỉ IP client thật ở backend sau ALB" → đọc **X-Forwarded-For**.
14. "Chia sẻ AMI mã hoá cho account khác" → mã hoá bằng **customer managed KMS key** và chia sẻ key.
15. "Hibernate" – nhớ yêu cầu root EBS mã hoá; dùng khi cần giữ trạng thái RAM.

---

## 8. Tự kiểm tra

1. Một policy có `Allow s3:*` và một policy khác `Deny s3:DeleteObject` cùng gắn vào user. User có xoá được object không?
2. Vì sao dùng IAM role cho EC2 an toàn hơn nhúng access key vào code?
3. Khi nào dùng NLB thay vì ALB? Nêu 2 lý do.
4. ASG có `min=2, desired=2, max=6`, bạn terminate thủ công 1 instance. Chuyện gì xảy ra, và nhờ health check loại nào mà instance "treo dịch vụ nhưng VM vẫn chạy" cũng được thay?
5. Spread placement group giới hạn bao nhiêu instance mỗi AZ?
6. Muốn chuyển một EBS volume sang AZ khác thì làm thế nào?
7. Bạn cần ổ dùng chung cho 20 instance Linux ở nhiều AZ. Chọn gì?
8. Phân biệt Dedicated Host và Dedicated Instance.
9. User ở account B cần đọc bucket ở account A. Cần cấu hình những gì nếu không dùng assume role?
10. SCP của OU cho phép `ec2:*`, `s3:*`; identity policy của user cho phép `dynamodb:*` và `s3:GetObject`. User làm được gì?
11. Stop rồi start một EC2 có public IP tự gán và instance store. Điều gì thay đổi?
12. Volume gp2 500 GiB có bao nhiêu IOPS nền? Chuyển sang gp3 thì sao?
13. ALB trả 503 cho mọi request. Nguyên nhân khả dĩ nhất?
14. ASG xử lý message từ SQS. Nên scale theo metric nào?
15. Một ứng dụng web cần IP tĩnh để đối tác whitelist **và** routing theo path. Thiết kế?

<details><summary>Đáp án</summary>

1. Không – explicit Deny thắng Allow.
2. Role cấp credential tạm tự xoay vòng qua STS/metadata, không lộ key dài hạn trong code/AMI/repo; thu hồi chỉ cần sửa role.
3. Cần IP tĩnh/Elastic IP, giao thức TCP/UDP phi-HTTP, hiệu năng/độ trễ cực thấp, giữ source IP, làm endpoint service cho PrivateLink.
4. ASG phát hiện thiếu so với desired và khởi tạo instance mới. Health check loại **ELB** (dựa trên health check của target group).
5. 7 instance đang chạy/AZ/group.
6. Tạo snapshot → tạo volume mới từ snapshot ở AZ đích (sang Region khác thì copy snapshot trước).
7. **EFS** (NFS, multi-AZ, Linux).
8. Host: máy vật lý riêng, kiểm soát/nhìn thấy socket-core, chọn host đặt instance (BYOL, compliance). Instance: phần cứng riêng nhưng không kiểm soát host/vị trí đặt.
9. Bucket policy ở account A cho phép principal của account B (`s3:GetObject`, `s3:ListBucket`), **và** identity policy ở account B cho phép user gọi các action đó trên bucket ARN của A. (Nếu object mã hoá bằng CMK: key policy cũng phải cho phép account B `kms:Decrypt`.)
10. Chỉ `s3:GetObject`. DynamoDB bị SCP chặn (SCP không có Allow), EC2 thì identity policy không cấp. Quyền hiệu lực là giao của hai bên.
11. Public IP đổi (cấp mới), dữ liệu instance store mất, EBS và private IP giữ nguyên; instance có thể chạy trên host khác.
12. gp2: 3 × 500 = 1.500 IOPS (burst tới 3.000). gp3: nền 3.000 IOPS + 125 MiB/s bất kể dung lượng, thường rẻ hơn.
13. Không có target healthy trong target group (health check fail do sai path/port, SG không cho ALB, app chết) hoặc chưa đăng ký target.
14. Backlog per instance (`ApproximateNumberOfMessagesVisible` / số instance) với target tracking (custom metric).
15. **NLB (IP tĩnh/EIP) → ALB làm target** (routing L7), hoặc **Global Accelerator** (2 IP anycast tĩnh) trước ALB.
</details>

## Tài liệu nên đọc thêm
- AWS Well-Architected Framework – Reliability pillar ("Design your workload service architecture") và Security pillar (Identity and access management).
- Doc: "Policy evaluation logic" (IAM), "IAM JSON policy elements: Condition operators", "Amazon EBS volume types", "Target groups for your Application Load Balancers – Health checks", "Scaling based on Amazon SQS".
- FAQ: EC2, ELB, Auto Scaling, IAM.
