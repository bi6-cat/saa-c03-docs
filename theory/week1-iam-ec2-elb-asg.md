# Tuần 1 – Nền tảng: Global Infra, IAM, EC2, EBS, ELB, Auto Scaling

**Mục tiêu:** hiểu cách AWS tổ chức hạ tầng, kiểm soát truy cập bằng IAM, và dựng được kiến trúc web "chuẩn": ALB + Auto Scaling nhiều AZ.
**Lab đi kèm:** `labs/lab01-ec2-alb-asg`

---

## 1. Hạ tầng toàn cầu & Shared Responsibility

| Khái niệm | Ý nghĩa | Ghi nhớ |
|---|---|---|
| **Region** | Cụm data center độc lập về địa lý | Dữ liệu **không tự rời Region**. Chọn theo: compliance/luật dữ liệu, độ trễ, dịch vụ có sẵn, giá |
| **Availability Zone (AZ)** | 1+ data center tách biệt trong Region, nối bằng mạng tốc độ cao | HA = trải tài nguyên qua **≥ 2 AZ** |
| **Edge Location** | Điểm cache của CloudFront/Route 53/Global Accelerator | Không phải Region |
| **Local Zone / Wavelength / Outposts** | Đưa tính toán gần người dùng / mạng 5G / on-prem | Chỉ cần biết use case |

**Shared Responsibility Model**
- AWS: bảo mật **của** cloud (phần cứng, data center, hypervisor, dịch vụ managed).
- Bạn: bảo mật **trong** cloud (IAM, dữ liệu, Security Group, patch OS của EC2, mã hoá…).
- Dịch vụ càng managed (RDS, Lambda, S3) → AWS gánh càng nhiều (patch OS/DB engine). EC2 thì bạn tự patch OS.

---

## 2. IAM (Identity and Access Management)

IAM là **global**, miễn phí.

### 2.1 Thành phần
- **User**: người/ứng dụng có credential dài hạn (password, access key). Hạn chế tạo access key; ưu tiên **IAM Identity Center** cho người.
- **Group**: tập user (không lồng nhau, không chứa role).
- **Role**: danh tính **không** có credential dài hạn; được **assume** để lấy credential tạm (STS). Dùng cho: EC2/Lambda truy cập dịch vụ khác, cross-account, federation.
- **Policy**: JSON mô tả quyền.
- **Instance profile**: "vỏ" để gắn role vào EC2 (Console tự tạo khi tạo role cho EC2).

### 2.2 Cấu trúc policy
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",            // Allow | Deny
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::my-bucket/*",
    "Condition": { "Bool": { "aws:SecureTransport": "true" } }
  }]
}
```
- **Identity-based policy**: gắn vào user/group/role.
- **Resource-based policy**: gắn vào tài nguyên (S3 bucket policy, SQS queue policy, KMS key policy, role *trust policy*) và có `Principal`.
- **Permissions boundary**: trần quyền tối đa của user/role (không tự cấp quyền).
- **SCP** (Organizations): trần quyền cho cả account (không tự cấp quyền; không áp dụng cho management account).
- **Session policy**: giới hạn thêm khi assume role.

### 2.3 Logic đánh giá quyền (rất hay ra đề)
1. Mặc định **implicit deny**.
2. Có **explicit Deny** ở bất cứ đâu → **Deny** (thắng tất cả).
3. Ngược lại, cần ít nhất 1 **Allow** (và phải nằm trong mọi "trần" như SCP/boundary).
- **Cùng account**: identity-based *hoặc* resource-based cho Allow là đủ.
- **Cross-account**: cần Allow ở **cả hai** phía (identity bên gọi + resource-based bên được gọi), hoặc dùng cách assume role sang account kia.

### 2.4 Best practices
- Khoá root user, bật MFA, không tạo access key cho root.
- **Least privilege**; dùng **role** thay vì nhúng access key vào EC2/app.
- Dùng group để gán quyền; bật MFA; xoay vòng credential; dùng IAM Access Analyzer, Credential Report, "last accessed".

---

## 3. EC2

### 3.1 Họ instance (nhớ theo mục đích)
| Họ | Dùng cho |
|---|---|
| **T** (burstable) | Workload nhẹ, dùng CPU credits. Hết credit → bị giới hạn (hoặc trả thêm nếu Unlimited) |
| **M** | General purpose, cân bằng |
| **C** | Compute-optimized: batch, game server, HPC, encoding |
| **R / X / z** | Memory-optimized: in-memory DB, cache, SAP HANA |
| **I / D / H** | Storage-optimized: NoSQL, data warehouse, IOPS cao (instance store NVMe) |
| **G / P / Inf / Trn** | GPU / ML training & inference |

### 3.2 AMI, User data, Metadata
- **AMI**: image để khởi tạo instance; **gắn với Region** (copy sang Region khác khi cần).
- **User data**: script chạy lần đầu khi boot (root).
- **Instance metadata** `http://169.254.169.254/latest/meta-data/` – nên dùng **IMDSv2** (token) để chống SSRF.

### 3.3 Mô hình mua (purchasing options)
| Loại | Đặc điểm | Dùng khi |
|---|---|---|
| **On-Demand** | Trả theo giây/giờ, không cam kết | Tải không đoán trước, thử nghiệm |
| **Savings Plans** (Compute / EC2 Instance) | Cam kết $/giờ 1 hoặc 3 năm, giảm tới ~72% | Tải ổn định; Compute SP linh hoạt nhất (cả Fargate/Lambda) |
| **Reserved Instances** (Standard / Convertible) | Cam kết cấu hình 1/3 năm | Tải ổn định cố định cấu hình |
| **Spot** | Rẻ tới ~90%, AWS có thể thu hồi (cảnh báo 2 phút) | Batch, xử lý dữ liệu, CI, stateless, chịu được gián đoạn |
| **Dedicated Host** | Máy vật lý riêng, thấy socket/core | Giấy phép theo socket/core (BYOL), compliance |
| **Dedicated Instance** | Phần cứng riêng cho bạn, không kiểm soát host | Yêu cầu cô lập phần cứng |
| **Capacity Reservation** | Giữ chỗ dung lượng trong 1 AZ (kết hợp SP/RI để giảm giá) | Đảm bảo có máy khi cần (ví dụ sự kiện) |

### 3.4 Placement Groups
- **Cluster**: gần nhau trong 1 AZ → độ trễ thấp, băng thông cao (HPC). Rủi ro: cùng phần cứng.
- **Spread**: tách phần cứng; tối đa **7 instance/AZ/group** → ứng dụng quan trọng ít instance.
- **Partition**: nhóm theo partition (rack) → Hadoop, Cassandra, Kafka.

### 3.5 Mạng EC2
- **ENI**: card mạng ảo (private IP, SG, MAC). Có thể tách/gắn sang instance khác cùng AZ.
- **Elastic IP**: public IPv4 tĩnh (tính phí khi không gắn, và AWS tính phí public IPv4 nói chung).
- **EFA**: HPC/ML cần độ trễ thấp (kernel bypass). **Enhanced networking (ENA)** cho băng thông cao.

---

## 4. EBS & Instance Store

- **EBS**: ổ block mạng, **gắn với 1 AZ**, tồn tại độc lập với vòng đời instance (tuỳ cờ `DeleteOnTermination`). Chuyển AZ/Region qua **snapshot** (lưu S3, incremental).
- **Instance store**: ổ gắn trực tiếp host, **rất nhanh nhưng mất dữ liệu** khi stop/terminate/host hỏng → cache, buffer, scratch.

| Loại | Dùng khi |
|---|---|
| **gp3** | Mặc định, SSD cân bằng. 3.000 IOPS / 125 MB/s nền, tăng độc lập IOPS/throughput |
| **gp2** | SSD cũ, IOPS gắn với dung lượng |
| **io2 / io2 Block Express** | DB quan trọng cần IOPS cao & bền (tới 64.000 / 256.000 IOPS), hỗ trợ **Multi-Attach** (io1/io2) |
| **st1** | HDD throughput: big data, log streaming |
| **sc1** | HDD lạnh rẻ nhất, truy cập ít |
> HDD (st1/sc1) **không dùng làm boot volume**.

- Mã hoá EBS dùng KMS, trong suốt; snapshot của volume mã hoá cũng mã hoá. Mã hoá cho volume chưa mã hoá: tạo snapshot → copy có bật encryption → tạo volume.
- **Data Lifecycle Manager (DLM)** / AWS Backup: tự động snapshot theo lịch.

---

## 5. Elastic Load Balancing (ELB)

| Loại | Tầng | Đặc điểm | Dùng khi |
|---|---|---|---|
| **ALB** | L7 (HTTP/HTTPS/gRPC) | Routing theo path, host, header, query; target: instance, IP, **Lambda**; WebSocket; tích hợp WAF, Cognito, redirect | Web app, microservices, container |
| **NLB** | L4 (TCP/UDP/TLS) | Hiệu năng rất cao, độ trễ thấp, **IP tĩnh/Elastic IP mỗi AZ**, PrivateLink | Game, IoT, giao thức không phải HTTP, cần IP cố định |
| **GWLB** | L3 | Chuyển traffic qua appliance bảo mật (firewall, IDS) bằng GENEVE (port 6081) | Appliance bên thứ ba |
| **CLB** | L4/L7 cũ | Legacy | Tránh dùng |

Các điểm quan trọng:
- **Cross-zone load balancing**: ALB bật sẵn (không tính phí data giữa AZ); NLB/GWLB mặc định tắt (bật sẽ tính phí).
- **Health check** → chỉ route tới target khỏe.
- **Sticky session** (cookie) khi app lưu session trên server – nhưng tốt hơn là lưu session ngoài (ElastiCache/DynamoDB) để app **stateless**.
- **SSL/TLS termination** tại ELB với cert từ **ACM**; **SNI** cho nhiều cert trên 1 listener (ALB/NLB).
- Client IP thật: ALB gửi qua header `X-Forwarded-For`. NLB giữ nguyên source IP (với target kiểu instance).
- **Connection draining / deregistration delay**: cho request đang chạy hoàn tất trước khi gỡ target.

---

## 6. Auto Scaling Group (ASG)

- Thành phần: **Launch Template** (AMI, instance type, SG, role, user data…) + **min / desired / max** + subnet nhiều AZ + (tuỳ) gắn Target Group + Health check.
- **Health check**: EC2 (mặc định) hoặc **ELB** (bật khi có load balancer để thay instance "không phục vụ được dù VM còn chạy").
- **Scaling policies**
  - **Target tracking** (khuyên dùng): giữ metric ở mức mục tiêu, vd CPU 50% hoặc `ALBRequestCountPerTarget`.
  - **Step / Simple**: theo ngưỡng CloudWatch alarm.
  - **Scheduled**: theo lịch (biết trước tải).
  - **Predictive**: dự đoán theo lịch sử.
- **Cooldown / warm-up** tránh scale dồn dập.
- **Mixed instances + Spot** để tối ưu chi phí.
- **Lifecycle hooks**: chạy việc trước khi instance vào/ra dịch vụ.
- ASG tự **cân bằng AZ**; instance hỏng → tự thay thế (self-healing).

**Kiến trúc chuẩn 3 tầng chịu lỗi:**
`Route 53 → ALB (public subnets, ≥2 AZ) → ASG EC2 (private subnets) → RDS Multi-AZ`
Instance chỉ nhận traffic từ **SG của ALB**, không mở ra Internet.

---

## 7. Bẫy thường gặp trong đề

1. "Ít công vận hành nhất" → ưu tiên dịch vụ managed/serverless hơn tự chạy trên EC2.
2. "Chịu mất 1 AZ" → nhiều AZ, không phải nhiều instance trong 1 AZ.
3. "Dùng IAM user + access key trên EC2" → **sai**, đáp án đúng là **IAM role**.
4. "Cần IP tĩnh cho load balancer" → **NLB** (hoặc Global Accelerator), không phải ALB.
5. "Routing theo URL path" → **ALB**.
6. "Tải batch chịu được gián đoạn, rẻ nhất" → **Spot**. "Cam kết dài hạn, ổn định" → **Savings Plans/RI**.
7. "Dữ liệu tạm tốc độ cao" → **Instance Store**; "DB cần IOPS cao bền" → **io2**.
8. EBS **không** chia sẻ trực tiếp giữa nhiều instance (trừ Multi-Attach io1/io2 cùng AZ) → muốn dùng chung nhiều instance Linux: **EFS**.

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

<details><summary>Đáp án</summary>

1. Không – explicit Deny thắng Allow.
2. Role cấp credential tạm tự xoay vòng qua STS/metadata, không lộ key dài hạn trong code/AMI/repo.
3. Cần IP tĩnh/Elastic IP, giao thức TCP/UDP phi-HTTP, hiệu năng/độ trễ cực thấp, PrivateLink.
4. ASG phát hiện thiếu so với desired và khởi tạo instance mới. Health check loại **ELB** (dựa trên health check của target group).
5. 7 instance/AZ/group.
6. Tạo snapshot → tạo volume mới từ snapshot ở AZ đích.
7. **EFS** (NFS, multi-AZ, Linux).
8. Host: máy vật lý riêng, kiểm soát/nhìn thấy socket-core (BYOL, compliance). Instance: phần cứng riêng nhưng không kiểm soát vị trí đặt instance trên host.
</details>

## Tài liệu nên đọc thêm
- AWS Well-Architected Framework (Reliability pillar) – phần "Design your workload service architecture".
- FAQ: EC2, ELB, Auto Scaling, IAM.
