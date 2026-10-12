# Tuần 7–8 – Luyện đề & Playbook thi

> Ký hiệu: **💡 Kinh nghiệm thực tế** · **🎯 Mẹo thi** · **⚠️ Hay nhầm**.

## 0. Hiểu đề thi trước khi luyện

| Thông tin | Giá trị (đối chiếu exam guide chính thức trước khi thi) |
|---|---|
| Mã đề | SAA-C03 |
| Số câu | **65** (50 tính điểm + **15 không tính điểm**, không biết câu nào) |
| Thời gian | **130 phút** (+30 phút nếu được duyệt **ESL**) |
| Dạng câu | Multiple choice (1 đáp án đúng / 4) và multiple response (≥ 2 đáp án đúng / ≥ 5) |
| Thang điểm | 100–1000, **đậu từ 720** (scaled score) |
| Cách chấm | *Compensatory* – không cần đậu từng domain, chỉ cần tổng đạt. **Không trừ điểm câu sai** |
| Domain | **Secure 30%** · **Resilient 26%** · **High-Performing 24%** · **Cost-Optimized 20%** |
| Phí | 150 USD; đậu được voucher giảm 50% cho lần thi sau |
| Hiệu lực | 3 năm |

Hệ quả thực tế: phần **Security** nặng nhất – đừng ôn lệch về compute. Gần như mọi câu là **tình huống kiến trúc** ("công ty X cần Y với ràng buộc Z"), hiếm khi hỏi định nghĩa thuần.

---

## 1. Quy trình luyện đề (rất quan trọng)

### 1.1 Kế hoạch 2 tuần

| Ngày | Việc | Ghi chú |
|---|---|---|
| T7-1 | Đề 1 – chế độ **review** (xem giải thích từng câu) | Mục tiêu: làm quen văn phong, chưa quan trọng điểm |
| T7-2 | Review **toàn bộ** đề 1, điền sổ lỗi | Mất 2–3 giờ – đây mới là phần học thật |
| T7-3 | Ôn lại `theory/` các mảng sai nhiều nhất | |
| T7-4 | Đề 2 – review mode → review → sổ lỗi | |
| T7-5 | Làm lại lab của mảng yếu (VPC, IAM hay sai nhất) | Lý thuyết đọc 3 lần không bằng tự cấu hình 1 lần |
| T7-6 | Đề 3 – **timed mode** (130 phút, không xem đáp án) | Từ đây luôn bấm giờ |
| T7-7 | Review đề 3 + đọc bảng so sánh mục 4 | |
| T8-1 → T8-4 | Đề 4, 5, 6 timed + review + sổ lỗi | Theo dõi xu hướng điểm |
| T8-5 | Làm lại những câu từng sai (bộ đề sai) | Tutorials Dojo có chế độ "incorrect only" |
| T8-6 | Đọc lại sổ lỗi + mục 3, 4, 5 của file này | Không học thêm kiến thức mới |
| T8-7 | Nghỉ nhẹ, kiểm tra thiết bị (nếu thi online), ngủ đủ | |

**Mục tiêu sẵn sàng**: **≥ 80–85% ổn định ở ≥ 3 bộ đề timed liên tiếp** (đề luyện thường khó hơn hoặc ngang đề thật).

### 1.2 Review đúng cách
- **Review MỌI câu**, kể cả câu đúng – có thể bạn đúng do đoán, hoặc đúng nhưng vì lý do sai.
- Với mỗi câu, tự trả lời được **vì sao 3 đáp án còn lại sai**. Nếu chỉ biết "đáp án B đúng" là chưa học xong câu đó.
- Gắn nhãn **loại lỗi** – mỗi loại có cách chữa khác nhau:

| Loại lỗi | Ví dụ | Cách chữa |
|---|---|---|
| **Thiếu kiến thức** | Không biết Gateway Endpoint chỉ hỗ trợ S3/DynamoDB | Đọc lại theory + FAQ/doc mục đó, làm lab |
| **Đọc sót ràng buộc** | Bỏ qua chữ "least operational overhead" | Luyện gạch từ khoá (mục 2) |
| **Nhầm hai dịch vụ giống nhau** | CloudTrail vs Config, Pilot Light vs Warm Standby | Học bảng so sánh mục 4, tự viết lại bảng bằng lời của mình |
| **Nghĩ quá sâu (overthinking)** | Chọn giải pháp phức tạp "cho chắc" | Nhớ: đáp án là giải pháp **đơn giản nhất thoả mọi yêu cầu** |
| **Đổi đáp án** | Đổi từ đúng sang sai khi xem lại | Chỉ đổi khi phát hiện **bằng chứng cụ thể** trong đề |

### 1.3 Mẫu sổ lỗi (copy ra file riêng, vd. `mistakes.md`)
| Ngày | Domain | Chủ đề | Câu hỏi tóm tắt | Mình chọn | Đúng là | Loại lỗi | Từ khoá quyết định / bài học |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

> 💡 **Kinh nghiệm thực tế**: sau 3–4 bộ đề, đếm sổ lỗi theo chủ đề. Thường 70–80% lỗi tập trung vào 4–5 chủ đề (VPC/kết nối, IAM/KMS, DR/RPO-RTO, chọn DB, S3 storage classes). Dồn sức vào đó thay vì đọc lại tất cả.

---

## 2. Kỹ thuật làm bài

### 2.1 Quy trình 4 bước cho mỗi câu
1. **Đọc câu cuối trước** (họ hỏi gì? chọn 1 hay chọn 2?).
2. Đọc kịch bản, **gạch ràng buộc** (hiện trạng, yêu cầu chức năng, yêu cầu phi chức năng).
3. **Loại trừ** đáp án sai rõ ràng (sai kỹ thuật, vi phạm ràng buộc, thừa phức tạp).
4. So sánh 2 đáp án còn lại **chỉ theo ràng buộc đề nêu** – không theo sở thích hay "thực tế công ty mình".

### 2.2 Từ khoá ràng buộc → hướng đáp án

| Từ khoá | Hướng đáp án |
|---|---|
| *least operational overhead*, *minimal management*, *fully managed* | Managed/serverless (Lambda, Fargate, DynamoDB, Aurora Serverless, S3, managed rule…) – loại mọi đáp án "tự cài trên EC2", "viết script cron" |
| *most cost-effective*, *lowest cost* | Rẻ nhất **mà vẫn thoả** yêu cầu (Spot, S3 IA/Glacier, Gateway Endpoint, serverless cho tải thưa). Không chọn thứ "xịn" vượt mức |
| *highly available*, *fault tolerant* | **Đa AZ** (ASG đa AZ, Multi-AZ DB, NAT mỗi AZ) |
| *disaster recovery*, *regional outage* | **Đa Region** (CRR, Aurora Global, Global Tables, Route 53 failover) + chọn chiến lược theo RPO/RTO |
| *near real-time* | Firehose, EventBridge, Lambda; *real-time* + nhiều consumer → Kinesis Data Streams |
| *decouple*, *buffer*, *spiky traffic* | SQS (+ ASG theo backlog / Lambda) |
| *minimal code changes*, *lift and shift* | Dịch vụ tương thích: Amazon MQ, RDS/Aurora cùng engine, FSx, EFS, MGN, Elastic Beanstalk |
| *without managing servers* | Lambda, Fargate, DynamoDB, S3, Aurora Serverless |
| *securely*, *least privilege* | Role thay key, KMS, Secrets Manager, private subnet + endpoint, SG tham chiếu SG |
| *static IP* | NLB / Global Accelerator / Elastic IP |
| *global users, low latency* | CloudFront (HTTP, cache) / Global Accelerator (TCP/UDP) / Route 53 latency / DynamoDB Global Tables / Aurora Global |
| *compliance, cannot be deleted* | S3 Object Lock compliance, Glacier Vault Lock, Backup Vault Lock |
| *audit who did what* | CloudTrail |
| *temporary credentials*, *federated* | STS, Identity Center, Cognito Identity Pool |

### 2.3 Quản lý thời gian
- Trung bình **2 phút/câu**: 65 câu ≈ 130 phút. Mốc kiểm tra: câu 20 ở phút ~40, câu 40 ở phút ~80.
- Câu nào > 3 phút → chọn đáp án tạm, **flag**, đi tiếp. Không để trống.
- **Dành 10–15 phút cuối** để xem lại câu flag.
- 15 câu không tính điểm có thể rất lạ – gặp câu "chưa từng nghe" đừng hoảng, đoán hợp lý rồi đi tiếp.
- Câu "chọn 2": mỗi đáp án phải **tự đứng được**, không cần bổ trợ nhau trừ khi đề nói "kết hợp". Thường là 2 bước của một giải pháp hoặc 2 giải pháp độc lập cùng đúng.

### 2.4 Mẫu đáp án nhiễu hay gặp (học để loại nhanh)

| Mẫu nhiễu | Vì sao sai |
|---|---|
| "Tạo IAM user, lưu access key trong EC2/code/user data" | Luôn có cách tốt hơn: IAM role |
| "Viết script chạy cron trên một EC2 để…" | Thêm vận hành + SPOF; thường có dịch vụ managed (EventBridge Scheduler, Lambda, AWS Backup, Config remediation) |
| "Dùng CloudWatch để xem ai đã xoá tài nguyên" | Đó là việc của CloudTrail |
| "Dùng Multi-AZ để tăng hiệu năng đọc" | Multi-AZ là HA; scale đọc là read replica |
| "Lambda chạy 30 phút / xử lý file 20 GB trong /tmp 512 MB" | Vi phạm giới hạn Lambda (15 phút, /tmp tối đa 10 GB) |
| "VPC peering bắc cầu A→B→C" | Peering không transitive |
| "Gắn WAF vào NLB" | WAF chỉ gắn ALB/CloudFront/API GW/AppSync/Cognito… |
| "CNAME cho zone apex" | Phải dùng Alias |
| "Dùng Kinesis để decouple đơn giản giữa 2 tầng web" | Over-engineering; SQS phù hợp hơn |
| "Snowball cho 5 TB khi có đường DX 10 Gbps rảnh" | Online (DataSync) nhanh hơn |
| "Bật mã hoá cho RDS đang chạy bằng một nút" | Phải snapshot → copy có mã hoá → restore |
| "Dùng S3 One Zone-IA cho dữ liệu duy nhất, quan trọng" | Mất AZ là mất dữ liệu |
| Giải pháp đúng kỹ thuật nhưng thêm 3–4 dịch vụ không cần | Đề thường chọn phương án **đơn giản nhất** thoả mãn |

---

## 3. Phân tích đề mẫu (tự soạn, minh hoạ cách suy luận)

**Ví dụ 1.** Một công ty chạy ứng dụng web trên EC2 trong private subnet. Ứng dụng tải lên hàng TB dữ liệu mỗi ngày vào S3 trong cùng Region. Chi phí NAT Gateway rất cao. Cần giảm chi phí **mà không cho instance truy cập Internet công khai** tới S3.
A. Thay NAT Gateway bằng NAT instance lớn hơn
B. Tạo **S3 Gateway VPC Endpoint** và cập nhật route table private subnet
C. Tạo S3 Interface Endpoint ở mọi AZ
D. Chuyển instance sang public subnet và gán Elastic IP

→ Ràng buộc: *giảm chi phí*, *không qua Internet*, *S3 cùng Region*. D vi phạm bảo mật. A vẫn tính data qua NAT, thêm vận hành. C chạy được nhưng có phí giờ + GB. **B** miễn phí, private. **Đáp án B.**

**Ví dụ 2.** Ứng dụng đặt hàng nhận lượng đơn tăng đột biến 10 lần trong các đợt khuyến mãi; tầng xử lý đơn thỉnh thoảng bị quá tải và **mất đơn**. Cần giải pháp **ít thay đổi kiến trúc nhất** để không mất đơn.
A. Tăng instance type của tầng xử lý
B. Đặt **SQS queue** giữa tầng web và tầng xử lý; tầng xử lý scale theo độ dài queue
C. Dùng Kinesis Data Streams với 100 shard
D. Dùng SNS gửi đơn trực tiếp tới tầng xử lý

→ Từ khoá: *đột biến*, *mất đơn* → cần **buffer bền**. A không giải quyết đột biến 10x. D: SNS không lưu message, consumer chậm vẫn mất. C chạy được nhưng phức tạp, cần quản shard. **Đáp án B.**

**Ví dụ 3.** Công ty cần DR cho ứng dụng gồm ALB, ASG EC2 và Aurora MySQL. Yêu cầu **RPO < 1 phút, RTO < 15 phút**, chi phí ở Region DR **càng thấp càng tốt** trong giới hạn đó.
A. Backup Aurora hằng ngày, copy snapshot sang Region DR
B. **Aurora Global Database**; ở Region DR có sẵn ALB + ASG chạy ở mức tối thiểu; Route 53 failover
C. Active/Active đầy đủ ở hai Region
D. Aurora cross-Region read replica; ở Region DR không có hạ tầng nào, tạo bằng tay khi sự cố

→ A: RPO 24 giờ – loại. C: thoả nhưng **không** "chi phí thấp nhất". D: tạo tay khó đạt RTO 15 phút. B = **Warm Standby** với replication < 1 giây. **Đáp án B.**

**Ví dụ 4 (chọn 2).** Ứng dụng serverless dùng API Gateway + Lambda + DynamoDB. Người dùng báo phản hồi chậm ở lần gọi đầu sau một thời gian không dùng, và DynamoDB bị đọc lặp lại cùng một item rất nhiều. Chọn **HAI** biện pháp.
A. Bật **Provisioned Concurrency** cho Lambda
B. Chuyển Lambda sang EC2
C. Thêm **DAX** trước DynamoDB
D. Tăng timeout của Lambda lên 15 phút
E. Chuyển DynamoDB sang RDS

→ "Chậm ở lần gọi đầu" = cold start → **A**. "Đọc lặp cùng item" = cache → **C**. B, E đổi kiến trúc không cần thiết; D không liên quan. **Đáp án A, C.**

**Ví dụ 5.** Một team cần cho phép nhà cung cấp bên thứ ba đọc một bucket S3 trong account của mình bằng công cụ của họ chạy trong account AWS của họ. Giải pháp **an toàn nhất**?
A. Tạo IAM user cho nhà cung cấp và gửi access key
B. Bật public read cho bucket
C. Tạo **IAM role** với quyền đọc bucket, trust policy cho account nhà cung cấp kèm **External ID**
D. Chia sẻ mật khẩu root

→ Bên thứ ba + an toàn nhất → cross-account role + External ID (chống confused deputy). A dùng credential dài hạn. **Đáp án C.** (Bucket policy cho account kia cũng hợp lệ, nhưng khi đề nhắc "bên thứ ba" + External ID thì role là đáp án chuẩn.)

> 🎯 Để ý cách loại trừ ở trên: hầu như luôn có 1–2 đáp án **vi phạm rõ ràng một ràng buộc**, và 1 đáp án **đúng nhưng quá mức cần thiết** (đắt/phức tạp). Đáp án đúng là cái còn lại.

---

## 4. Bảng so sánh "cứu cánh" (đọc kỹ trước ngày thi)

### Compute & Network
| Tình huống | Chọn |
|---|---|
| Routing HTTP theo path/host, xác thực ở LB | ALB |
| IP tĩnh, TCP/UDP, hiệu năng cực cao, PrivateLink | NLB |
| Appliance firewall bên thứ ba | GWLB |
| Instance private đi ra Internet | NAT Gateway (mỗi AZ một cái) |
| Instance private truy cập S3/DynamoDB miễn phí | Gateway Endpoint |
| Truy cập dịch vụ AWS khác private / từ on-prem tới S3 | Interface Endpoint |
| Nối nhiều VPC + on-prem | Transit Gateway |
| Expose 1 dịch vụ riêng tư, CIDR trùng | PrivateLink |
| On-prem nhanh, mã hoá | Site-to-Site VPN |
| On-prem băng thông ổn định | Direct Connect (+VPN nếu cần mã hoá) |
| 1 DX tới nhiều VPC nhiều Region | Direct Connect Gateway |
| Chặn IP cụ thể ở mức subnet | NACL |
| Cache toàn cầu | CloudFront |
| IP anycast tĩnh, TCP/UDP, failover Region nhanh | Global Accelerator |
| Truy cập shell không mở port 22 | SSM Session Manager |
| Batch chịu gián đoạn | Spot |
| License theo socket/core | Dedicated Host |
| HPC độ trễ thấp giữa node | Cluster placement group + EFA |

### Storage & DB
| Tình huống | Chọn |
|---|---|
| Block 1 instance | EBS (gp3 mặc định, io2 cho IOPS cao) |
| Dùng chung Linux nhiều AZ | EFS |
| Windows SMB / AD | FSx for Windows |
| HPC / ML từ S3 | FSx for Lustre |
| NAS NetApp đa giao thức | FSx for ONTAP |
| Rất nhanh nhưng tạm thời | Instance Store |
| Lưu trữ lâu dài rẻ nhất | S3 Glacier Deep Archive |
| Lưu trữ, cần lấy mili-giây | S3 Glacier Instant Retrieval |
| Mẫu truy cập bất định | S3 Intelligent-Tiering |
| WORM/compliance | S3 Object Lock (Compliance) |
| Upload xa nhanh | S3 Transfer Acceleration + multipart |
| SQL quan hệ, HA | RDS Multi-AZ / Aurora |
| Scale đọc | Read Replica / Aurora Replica / ElastiCache |
| Quá nhiều connection từ Lambda | RDS Proxy |
| DR DB đa Region RPO giây | Aurora Global Database |
| NoSQL ms, serverless | DynamoDB (+DAX) |
| NoSQL đa Region multi-active | DynamoDB Global Tables |
| Kho dữ liệu phân tích | Redshift |
| SQL trên S3 không hạ tầng | Athena |
| Tìm kiếm full-text | OpenSearch |
| Graph / Mongo / Cassandra / Time-series | Neptune / DocumentDB / Keyspaces / Timestream |
| Chuyển DB khác engine | DMS + SCT |

### Integration & Serverless
| Tình huống | Chọn |
|---|---|
| Decouple, buffer | SQS |
| Thứ tự + không trùng | SQS FIFO |
| Fan-out | SNS (+SQS) |
| Event routing theo nội dung, sự kiện AWS/SaaS | EventBridge |
| Cron serverless | EventBridge Scheduler |
| Streaming nhiều consumer/replay | Kinesis Data Streams |
| Nạp stream vào S3/Redshift/OpenSearch | Data Firehose |
| Kafka managed | MSK |
| Workflow nhiều bước, chờ phê duyệt | Step Functions (Standard) |
| Container không quản server | Fargate (ECS/EKS) |
| Chạy code theo sự kiện, < 15 phút | Lambda |
| Job batch dài | AWS Batch |
| Di chuyển app dùng AMQP/MQTT/JMS | Amazon MQ |
| Bán gói API theo khách hàng | API Gateway REST + usage plan |

### Security & Governance
| Tình huống | Chọn |
|---|---|
| Khoá mã hoá managed (audit) | KMS (CMK nếu cần kiểm soát policy/chia sẻ) |
| Cùng khoá ở nhiều Region | KMS Multi-Region keys |
| HSM riêng, FIPS L3 | CloudHSM |
| Xoay vòng secret tự động | Secrets Manager |
| Cấu hình rẻ, phân cấp | SSM Parameter Store |
| Cert TLS miễn phí cho ALB/CloudFront | ACM (CloudFront: us-east-1) |
| Chặn SQLi/XSS, rate limit | WAF |
| DDoS nâng cao | Shield Advanced |
| Quản lý WAF/SG toàn Org | Firewall Manager |
| Lọc domain egress trong VPC | Network Firewall |
| Ai gọi API? | CloudTrail |
| Cấu hình thay đổi/tuân thủ | Config |
| Hành vi đáng ngờ | GuardDuty |
| Lỗ hổng CVE | Inspector |
| PII trong S3 | Macie |
| Gộp findings, chấm chuẩn | Security Hub |
| Điều tra nguyên nhân gốc | Detective |
| Tài nguyên bị chia sẻ ra ngoài | IAM Access Analyzer |
| Trần quyền cho account | SCP |
| Trần quyền cho 1 role/user | Permissions boundary |
| Bên thứ ba truy cập account | Cross-account role + External ID |
| Đăng nhập app web/mobile | Cognito User Pool |
| Cấp credential AWS cho user app | Cognito Identity Pool |
| SSO nhiều account | IAM Identity Center |
| AD trên AWS có trust với on-prem | AWS Managed Microsoft AD |
| Landing zone nhiều account | Control Tower |
| Chia sẻ subnet/TGW giữa account | RAM |

### Resilience & Cost
| Tình huống | Chọn |
|---|---|
| DR rẻ, chấp nhận giờ | Backup & Restore |
| DR chục phút, dữ liệu sống | Pilot Light |
| DR vài phút | Warm Standby |
| DR gần 0 | Active/Active |
| Cross-Region DB | Aurora Global / Cross-Region replica / DynamoDB Global Tables |
| Backup tập trung, không xoá được | AWS Backup + Vault Lock + cross-account copy |
| DR server on-prem RPO giây | Elastic Disaster Recovery |
| Failover DNS giữa Region | Route 53 failover + health check |
| Cảnh báo chi phí | AWS Budgets |
| Chi phí bất thường | Cost Anomaly Detection |
| Right-size | Compute Optimizer |
| Tải ổn định dài hạn | Savings Plans / RI |
| Linh hoạt họ instance + Fargate/Lambda | Compute Savings Plans |
| Chi phí theo team | Cost allocation tags (activate) |

---

## 5. Từ khoá → dịch vụ (phản xạ nhanh)

- "Lift-and-shift" server → **Application Migration Service (MGN)**
- Khảo sát hạ tầng on-prem trước migration → **Application Discovery Service** / Migration Hub
- Chuyển DB khác engine → **DMS + SCT**
- Chuyển dữ liệu offline TB/PB → **Snow Family**; online → **DataSync**
- SFTP vào S3 → **Transfer Family**
- NAS on-prem mở rộng cloud / file như NFS nhưng lưu S3 → **Storage Gateway (S3 File Gateway)**
- Thay băng từ → **Tape Gateway**
- Máy ảo thay SSH → **SSM Session Manager**; vá OS hàng loạt → **SSM Patch Manager**
- IaC → **CloudFormation / CDK**; nhiều account/Region → **StackSets**
- PaaS upload code → **Elastic Beanstalk**
- Sự kiện hạ tầng AWS → **EventBridge**
- Giám sát metric/log/alarm → **CloudWatch**; RAM/disk EC2 → **CloudWatch Agent**
- Distributed tracing → **X-Ray**
- Chia sẻ tài nguyên giữa account → **RAM**
- Landing zone nhiều account → **Control Tower**
- Danh mục sản phẩm đã duyệt → **Service Catalog**
- GraphQL → **AppSync**
- Đồng bộ dữ liệu từ SaaS → **AppFlow**
- BI dashboard → **QuickSight**
- Quản trị data lake, quyền cột/hàng → **Lake Formation**
- Kiểm thử chịu lỗi → **Fault Injection Service**

---

## 6. Ngày thi

**Đăng ký**: tạo tài khoản ở aws.amazon.com/certification → *Schedule exam* → Pearson VUE (thi tại trung tâm hoặc **online proctored**). **Xin ESL +30 phút trước khi đặt lịch** nếu bạn không dùng tiếng Anh bản ngữ (accommodation áp dụng cho các lần đặt lịch sau đó).

**Online proctored**
- Chạy *system test* của Pearson VUE trên **chính máy và mạng sẽ thi** vài ngày trước (VPN công ty, phần mềm bảo mật hay chặn).
- Phòng riêng yên tĩnh, bàn trống, không màn hình phụ; giấy tờ tuỳ thân hợp lệ, **tên khớp tài khoản**.
- Không đọc thành tiếng, không che miệng, không rời khung hình, **không có giờ nghỉ** – đi vệ sinh trước.
- Check-in mở trước giờ thi ~30 phút; vào sớm vì khâu chụp phòng/giấy tờ mất thời gian.

**Tại trung tâm**: đến sớm 30 phút, mang giấy tờ tuỳ thân, đồ cá nhân để tủ.

**Trong khi thi**
- Đọc kỹ, gạch ràng buộc, loại trừ, flag câu khó, theo dõi mốc thời gian.
- **Dành 10–15 phút cuối** xem lại câu flag; chỉ đổi đáp án khi có lý do cụ thể.
- Nếu một chuỗi câu khó liên tiếp → hít thở, có thể chúng là câu không tính điểm.

**Sau thi**: kết quả chính thức thường gửi trong vòng vài ngày làm việc (đôi khi sớm hơn); badge qua Credly. Có voucher 50% cho lần thi sau.

Kiểm tra lại mọi thông tin (mã đề, giá, quy định, domain) trên trang chính thức của AWS vì có thể thay đổi.

---

## 7. Checklist sẵn sàng thi
- [ ] Đọc xong lý thuyết tuần 1–6 (`week1` … `week6`), tự kiểm tra đúng ≥ 80%
- [ ] Hoàn thành 6 lab (`verify.sh` toàn PASS) và đã chạy `cleanup.sh` cho từng lab – kiểm tra lại Billing không còn tài nguyên tính phí
- [ ] Đề thử timed: ≥ 80–85% ổn định ở ≥ 3 bộ liên tiếp
- [ ] Sổ lỗi đã phân loại; không còn lỗi lặp lại ở cùng chủ đề
- [ ] Phân biệt được ngay: CloudTrail/Config/CloudWatch/GuardDuty; Multi-AZ/Read Replica; Pilot Light/Warm Standby; SQS/SNS/EventBridge/Kinesis; Gateway/Interface Endpoint; SCP/boundary; User Pool/Identity Pool
- [ ] Đã đọc Well-Architected (6 trụ cột) và FAQ: S3, VPC, RDS/Aurora, DynamoDB, SQS/SNS, IAM, KMS
- [ ] Đã đặt lịch thi + xin ESL (nếu cần) + chạy system test (nếu thi online)
