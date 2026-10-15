# Tuần 6 – Resilience, Disaster Recovery, Hiệu năng toàn cầu & Cost Optimization

**Mục tiêu:** thiết kế hệ thống chịu lỗi theo RPO/RTO, tăng tốc phân phối nội dung toàn cầu, và tối ưu chi phí. Học kèm **Well-Architected Framework (6 trụ cột)**.
**Lab đi kèm:** `labs/lab06-cloudfront-dr`

> Ký hiệu: **💡 Kinh nghiệm thực tế** · **🎯 Mẹo thi** · **⚠️ Hay nhầm**.

---

## 1. Well-Architected Framework

### 1.1 Sáu trụ cột

| Trụ cột | Câu hỏi cốt lõi | Nguyên tắc tiêu biểu |
|---|---|---|
| **Operational Excellence** | Vận hành & cải tiến thế nào? | IaC, thay đổi nhỏ thường xuyên có thể rollback, runbook, học từ sự cố, observability |
| **Security** | Bảo vệ dữ liệu, hệ thống ra sao? | Danh tính mạnh, least privilege, truy vết, bảo mật mọi lớp, mã hoá, tự động hoá, chuẩn bị ứng phó sự cố |
| **Reliability** | Chịu lỗi & phục hồi thế nào? | Tự động phục hồi, kiểm thử phục hồi, scale ngang, ngừng đoán capacity, quản lý thay đổi bằng tự động hoá |
| **Performance Efficiency** | Dùng tài nguyên hiệu quả? | Dùng công nghệ tiên tiến dạng dịch vụ, đi toàn cầu trong vài phút, serverless, thử nghiệm thường xuyên |
| **Cost Optimization** | Trả đúng giá trị nhận được? | Mô hình tiêu dùng (trả theo dùng), đo hiệu quả, ngừng chi cho "nâng nhấc nặng", phân bổ chi phí |
| **Sustainability** | Giảm tác động môi trường? | Tối đa hoá mức sử dụng, chọn Region/phần cứng hiệu quả (Graviton), dịch vụ managed, giảm dữ liệu thừa |

Đề SAA-C03 chia 4 domain (**Secure 30%**, **Resilient 26%**, **High-Performing 24%**, **Cost-Optimized 20%**) nhưng tư duy là các trụ cột này. **AWS Well-Architected Tool** (miễn phí trên Console) giúp tự đánh giá workload theo bộ câu hỏi.

### 1.2 Nguyên tắc thiết kế chung
- Thiết kế cho **thất bại** ("everything fails, all the time") – mọi thành phần có thể hỏng; hỏi "nếu cái này chết thì sao?".
- **Không điểm đơn lẻ gây lỗi (SPOF)** – mỗi tầng ≥ 2 AZ.
- **Stateless** + **loose coupling** + **scale ngang** (horizontal) thay vì scale dọc.
- **Tự động hoá** (IaC, auto scaling, auto recovery) – con người là nguồn lỗi lớn nhất khi hoảng loạn.
- Ưu tiên **dịch vụ managed** – AWS lo HA của chính dịch vụ.

---

## 2. RPO / RTO & chiến lược DR

### 2.0 HA vs Fault Tolerance vs DR – ba khái niệm hay bị trộn

| | Mục tiêu | Phạm vi lỗi | Ví dụ | Chi phí |
|---|---|---|---|---|
| **High Availability (HA)** | **Giảm** downtime, failover nhanh (có thể gián đoạn vài giây–phút) | Lỗi instance / AZ | ASG đa AZ, RDS Multi-AZ (failover 60–120 giây) | Vừa |
| **Fault Tolerance (FT)** | Tiếp tục chạy **gần như không gián đoạn** khi có lỗi | Lỗi component | Aurora/DynamoDB nhiều bản sao ghi sẵn, active/active, S3 (≥3 AZ) | Cao: cần dư thừa hơn, phức tạp hơn |
| **Disaster Recovery (DR)** | Phục hồi sau sự cố **lớn** theo **RPO/RTO** | Mất cả Region / dữ liệu hỏng | Backup & Restore, Pilot Light, Warm Standby, Active/Active | Tuỳ chiến lược |

- HA ≠ DR: Multi-AZ **không** cứu được khi mất cả Region; Multi-Region cũng **không** cứu được xoá nhầm/hỏng dữ liệu đã bị replicate (cần backup, versioning, point-in-time).
- Đề nói "failover tự động, giảm downtime" → HA; "không được gián đoạn" → FT; "RPO/RTO sau thảm hoạ" → DR.
- 🎯 **Tìm single point of failure trước khi chọn service "xịn"**: ASG 3 AZ nhưng DB chỉ 1 instance trong 1 AZ, hoặc 1 NAT Gateway dùng chung, thì hệ thống vẫn **không** resilient. Đi dọc luồng Route 53 → ALB → ASG → DB và hỏi "tầng nào chỉ có một?".

### 2.1 Định nghĩa
```
          Lần backup/sao chép cuối        Thảm hoạ               Hệ thống chạy lại
   ──────────────●──────────────────────────✖──────────────────────────●──────────►
                 │◄──────── RPO ───────────►│◄──────── RTO ───────────►│
                  (dữ liệu có thể mất)        (thời gian gián đoạn)
```
- **RPO** (Recovery Point Objective): chịu mất bao nhiêu **dữ liệu**, đo bằng thời gian (RPO 1 giờ = có thể mất 1 giờ dữ liệu cuối).
- **RTO** (Recovery Time Objective): chịu **gián đoạn** bao lâu tới khi phục vụ lại.
- RPO/RTO càng nhỏ → chi phí càng cao. Đây là **quyết định kinh doanh**, không phải kỹ thuật: hỏi "mất 1 giờ dữ liệu / ngừng 4 giờ thì công ty thiệt bao nhiêu?".

### 2.2 Bốn chiến lược DR (đa Region)

| Chiến lược | RPO | RTO | Ở Region DR có gì? | Chi phí |
|---|---|---|---|---|
| **Backup & Restore** | Giờ (theo tần suất backup) | **Giờ → ngày** | Chỉ bản backup (snapshot, S3, AWS Backup copy). Khi sự cố mới dựng toàn bộ hạ tầng (IaC) + restore dữ liệu | **Thấp nhất** |
| **Pilot Light** | Phút (dữ liệu sao chép liên tục) | **Chục phút → giờ** | **Dữ liệu luôn sao chép** (DB replica, S3 CRR), lõi tối thiểu; **compute tắt/chưa tạo** (AMI, template sẵn). Sự cố: bật/khởi tạo app server, scale up | Thấp |
| **Warm Standby** | Giây → phút | **Phút** | Bản **thu nhỏ đang chạy** của toàn hệ thống (ALB + vài instance + DB replica), có thể phục vụ một phần traffic. Sự cố: scale lên full + chuyển traffic | Trung bình |
| **Multi-site Active/Active** | **≈ 0** | **≈ 0** | Hệ thống **đầy đủ chạy ở nhiều Region**, cùng phục vụ (Route 53 latency/weighted, DynamoDB Global Tables, Aurora Global) | **Cao nhất** |

**Ví dụ so sánh cho một ứng dụng web + MySQL:**
- *Backup & Restore*: snapshot RDS hằng giờ copy sang Region DR; AMI copy; CloudFormation template. Sự cố → chạy template, restore snapshot (mất 1–3 giờ).
- *Pilot Light*: RDS **cross-Region read replica** chạy liên tục; Launch Template + ASG `desired=0` sẵn ở DR. Sự cố → promote replica, đặt ASG desired=4, đổi Route 53 (20–40 phút).
- *Warm Standby*: như trên nhưng ASG ở DR đang chạy 1 instance nhỏ sau ALB; Route 53 failover tự động; sự cố → promote DB + scale ASG (vài phút).
- *Active/Active*: Aurora Global Database (write forwarding) hoặc DynamoDB Global Tables; ALB + ASG đầy đủ cả 2 Region; Route 53 latency routing (gần như không gián đoạn).

> ⚠️ **Hay nhầm**: Pilot Light vs Warm Standby. Pilot Light: **dữ liệu sống, compute chưa chạy** (như bếp gas chỉ có ngọn lửa mồi). Warm Standby: **toàn bộ stack đang chạy ở quy mô nhỏ**, phục vụ được ngay (nếu chậm).

### 2.3 Công cụ DR
- **AWS Backup**:
  - **Backup plan** (tần suất, cửa sổ, lifecycle sang cold storage, retention) gán theo **tag**/resource.
  - **Backup vault** mã hoá KMS, **access policy**; **Vault Lock** (governance/compliance – compliance mode không ai xoá được, chống ransomware); *logically air-gapped vault*.
  - **Copy cross-Region và cross-account** tự động; **backup policies** từ Organizations; **Backup Audit Manager** (báo cáo tuân thủ); **restore testing** tự động.
  - Hỗ trợ EC2, EBS, RDS, Aurora, DynamoDB, EFS, FSx, S3, Storage Gateway, DocumentDB, Neptune, Redshift…
- **AWS Elastic Disaster Recovery (DRS)**: sao chép **liên tục ở mức block** server on-prem/cloud khác/EC2 sang **vùng staging chi phí thấp** ở AWS; khi cần, launch instance phục hồi trong vài phút. **RPO giây, RTO phút**, có point-in-time (khôi phục về trước khi bị ransomware), hỗ trợ failback.
- **Cross-Region theo dịch vụ**: S3 **CRR**, RDS cross-Region read replica / snapshot copy, **Aurora Global Database**, **DynamoDB Global Tables**, EBS snapshot copy, AMI copy, EFS replication, ECR replication, KMS Multi-Region keys, Secrets Manager replica.
- **Chuyển traffic**: **Route 53 failover/health check**, **Global Accelerator**, **Route 53 ARC** (routing control).

> 💡 **Kinh nghiệm thực tế – DR**
> - **DR chưa từng diễn tập = không có DR.** Lên lịch game day ít nhất mỗi quý: thật sự failover sang Region DR, đo RTO/RPO thực tế, ghi lại bước nào thủ công/chậm.
> - Hạ tầng DR phải dựng bằng **IaC** – dựng tay lúc 3 giờ sáng giữa sự cố gần như chắc chắn sai.
> - Đừng quên **phụ thuộc ngầm**: AMI, KMS key, secret, cert ACM, parameter, quota dịch vụ ở Region DR (quota mặc định thấp → xin tăng trước!), bản ghi DNS, IAM role (global – ổn).
> - Backup phải được **bảo vệ khỏi chính account bị xâm nhập**: copy sang account backup riêng + Vault Lock. Ransomware hiện đại xoá backup trước khi mã hoá.
> - Kiểm tra **restore**, không chỉ kiểm tra "backup job thành công".

---

## 3. Mẫu thiết kế chịu lỗi (trong một Region)

| Tầng | Mẫu HA |
|---|---|
| DNS | Route 53 (SLA 100%), health check |
| Edge | CloudFront (đa edge, origin failover) |
| Load balancer | ALB/NLB đa AZ (managed) |
| Compute | **ASG đa AZ** + ELB health check; container ECS/EKS service đa AZ; Lambda (đa AZ sẵn) |
| Session/state | ElastiCache (Multi-AZ) / DynamoDB – **không** lưu trên instance |
| File | S3 (≥3 AZ) / EFS Regional |
| DB | **RDS Multi-AZ / Aurora** (replica ở AZ khác), DynamoDB (đa AZ sẵn) |
| Messaging | SQS/SNS/EventBridge (đa AZ sẵn) |
| Mạng ra ngoài | NAT Gateway **mỗi AZ** |

**Kỹ thuật bổ sung**
- **Health check + tự phục hồi**: ASG thay instance; **EC2 Auto Recovery** (CloudWatch alarm `StatusCheckFailed_System` → recover giữ nguyên instance ID, IP, EBS); Route 53 health check.
- **Retry với exponential backoff + jitter**, đặt **timeout** cho mọi lời gọi, **circuit breaker** (ngừng gọi dịch vụ đang chết một thời gian).
- **Rate limiting & throttling** (API Gateway, WAF) bảo vệ backend khỏi bị quá tải.
- **Graceful degradation**: tính năng phụ hỏng (gợi ý sản phẩm) không làm hỏng chức năng chính (thanh toán); trả trang tĩnh từ S3 khi backend chết (Route 53 failover / CloudFront custom error page).
- **Static stability**: thiết kế để khi một AZ chết, AZ còn lại **đã có đủ capacity** (chạy dư 50% với 2 AZ, 33% với 3 AZ) thay vì phải scale-out trong lúc sự cố.
- **Bulkhead / cell-based**: chia khách hàng vào nhiều "cell" độc lập để lỗi chỉ ảnh hưởng một phần.
- **Chaos engineering / game day**: **AWS Fault Injection Service (FIS)** tiêm lỗi (tắt instance, tăng độ trễ, mô phỏng AZ mất điện) để kiểm chứng.
- **Route 53 ARC zonal shift**: rút traffic ALB/NLB khỏi AZ bị suy giảm trong vài phút.

> 💡 Ví dụ static stability: cần 6 instance để phục vụ tải đỉnh. Với 2 AZ → chạy **6 + 6** (mỗi AZ đủ gánh một mình) nếu yêu cầu không gián đoạn khi mất AZ; hoặc 3 AZ × 3 instance = 9 (mất 1 AZ còn 6). Phương án 3 AZ rẻ hơn – lý do production hay dùng 3 AZ.

---

## 4. CloudFront (CDN)

### 4.1 Cách hoạt động
- Người dùng → DNS trả **edge location** gần nhất → edge có cache (**hit**) thì trả ngay; **miss** → hỏi **Regional Edge Cache** → (miss) → **origin**. Có thể bật **Origin Shield** (một lớp cache tập trung nữa) để giảm tải origin.
- **Origin**: S3 bucket (REST endpoint), S3 static website endpoint (custom origin), ALB/NLB, EC2, API Gateway, MediaPackage, **bất kỳ HTTP server** (kể cả on-prem). **VPC origins**: trỏ thẳng tới ALB/NLB/EC2 trong **private subnet** (không cần public).
- Lợi ích: giảm độ trễ, giảm tải & chi phí origin (data từ origin AWS → CloudFront **miễn phí**), hấp thụ DDoS (Shield Standard), TLS ở edge, HTTP/2, HTTP/3.

### 4.2 Cache behaviors & cache
- Một distribution có nhiều **cache behavior** theo **path pattern** (đánh giá theo thứ tự), mỗi behavior trỏ origin riêng với policy riêng:
  `/api/*` → ALB, không cache · `/static/*` → S3, cache 1 năm · `Default (*)` → S3.
- **Cache key** = những gì phân biệt bản cache (URL + header/cookie/query string được chọn). Đưa quá nhiều thứ vào cache key → **hit ratio giảm**.
- **Cache policy** (cái gì vào cache key + TTL), **origin request policy** (gửi thêm gì tới origin mà không vào cache key), **response headers policy** (thêm CORS, security headers như HSTS, CSP).
- **TTL**: mặc định 24 giờ (86.400 giây), min/max cấu hình được; origin có thể điều khiển bằng `Cache-Control: max-age` / `Expires`.
- **Invalidation**: xoá cache trước hạn (`/images/*`) – tính phí khi vượt mức miễn phí hằng tháng, mất vài phút lan toả. Cách tốt hơn cho asset: **versioned filename** (`app.3f9a1c.js`) → không cần invalidation, cache được rất lâu.
- **Nén** gzip/Brotli tự động.

### 4.3 Bảo mật
- HTTPS: viewer → CloudFront (cert **ACM ở us-east-1**, custom domain qua CNAME/Alias) và CloudFront → origin (HTTPS only / match viewer).
- **OAC (Origin Access Control)**: S3 bucket **private**, chỉ nhận request được CloudFront ký. Bucket policy cho principal `cloudfront.amazonaws.com` với điều kiện `AWS:SourceArn` = ARN distribution (lab06). OAC hỗ trợ SSE-KMS, mọi Region, PUT/POST – **thay OAI cũ**.
- Với **custom origin** (ALB): chặn truy cập trực tiếp bằng **custom header bí mật** (CloudFront thêm header, ALB rule chỉ chấp nhận khi có header) + SG chỉ cho phép **managed prefix list của CloudFront**.
- **Signed URL / signed cookies** (dùng **trusted key group**):
  - *Signed URL*: cho **một file** cụ thể, hoặc client không hỗ trợ cookie.
  - *Signed cookies*: cho **nhiều file** (cả thư mục, video HLS nhiều segment) mà không phải đổi URL.
  - *Canned policy* (chỉ thời hạn) vs *custom policy* (thời điểm bắt đầu, dải IP, wildcard).
- **Geo restriction**: allowlist/blocklist **quốc gia** (bản quyền nội dung). Logic chi tiết hơn → WAF geo match hoặc edge function.
- **Field-level encryption**: mã hoá một số trường form (số thẻ) ngay ở edge bằng public key, chỉ backend có private key giải được.
- Tích hợp **WAF** + **Shield Advanced**.

| | **S3 pre-signed URL** | **CloudFront signed URL** |
|---|---|---|
| Đi qua | Thẳng tới S3 | Qua edge CloudFront (có cache) |
| Ký bằng | Credential IAM của người ký | Private key của trusted key group |
| Thời hạn | Tối đa 7 ngày (IAM user) | Tuỳ ý |
| Dùng khi | Upload/download tạm một object | Phân phối nội dung trả phí/riêng tư cho nhiều người, toàn cầu |

### 4.4 Tính sẵn sàng & edge compute
- **Origin Group / origin failover**: origin chính trả mã lỗi được chọn (500, 502, 503, 504, 403, 404…) hoặc timeout → CloudFront thử origin phụ. **Chỉ áp dụng cho GET, HEAD, OPTIONS** (lab06: S3 origin ở Region chính + bucket DR qua CRR).
- **Custom error pages**: trả trang thân thiện (từ S3) khi origin lỗi.
- **Continuous deployment**: distribution staging nhận một % traffic để thử cấu hình mới.

| | **CloudFront Functions** | **Lambda@Edge** |
|---|---|---|
| Ngôn ngữ | JavaScript | Node.js, Python |
| Thời gian chạy | **< 1 ms** | Tới 5 giây (viewer) / 30 giây (origin) |
| Sự kiện | Viewer request / viewer response | Cả 4: viewer req/resp, **origin req/resp** |
| Truy cập mạng / body | Không | **Có** |
| Quy mô / giá | Hàng triệu req/giây, rẻ ~1/6 | Thấp hơn, đắt hơn |
| Dùng cho | Rewrite/redirect URL, thêm header, chuẩn hoá cache key, xác thực token nhẹ (JWT) | Logic phức tạp, gọi dịch vụ ngoài, sửa body, chọn origin động |

- **Price class**: giới hạn tập edge để giảm giá – *Price Class 100* (Bắc Mỹ, châu Âu, Israel), *200* (+ phần lớn châu Á, Trung Đông, châu Phi), *All*.

> 💡 **Kinh nghiệm thực tế – CloudFront**
> - Lab06 dùng **Price Class 100** để tiết kiệm – nhưng nhóm này **không có edge ở châu Á**: người dùng Việt Nam sẽ được phục vụ từ edge xa hơn. Ứng dụng thật cho người dùng châu Á → Price Class 200 hoặc All.
> - Theo dõi **cache hit ratio** (CloudFront reports). Hit ratio thấp → xem có đang đưa cookie/header/query string không cần thiết vào cache key không.
> - Mỗi lần sửa distribution mất vài phút deploy – lên kế hoạch thay đổi, đừng sửa giữa giờ cao điểm.
> - Lỗi 403 với S3 origin qua OAC: kiểm tra bucket policy (đúng ARN distribution), đang chọn REST endpoint (không phải website endpoint), object tồn tại (S3 trả 403 thay vì 404 khi thiếu quyền `ListBucket`), và KMS key policy nếu object mã hoá SSE-KMS.

### 4.5 CloudFront vs Global Accelerator

| | CloudFront | Global Accelerator |
|---|---|---|
| Mục đích | **Cache** nội dung (static/dynamic) HTTP/S | Tăng tốc & HA cho **ứng dụng** TCP/UDP qua backbone AWS |
| IP | DNS name, IP edge thay đổi | **2 IP anycast tĩnh** (hoặc BYOIP) |
| Cache | Có | **Không** |
| Giao thức | HTTP/HTTPS, WebSocket | **TCP, UDP** (mọi giao thức trên đó) |
| Failover | Origin group (theo request) | Endpoint group theo health check, chuyển Region trong vài chục giây, **không phụ thuộc DNS cache** |
| Kiểm soát traffic | Theo behavior | **Traffic dial** (% mỗi Region), **endpoint weight**, client affinity |
| Dùng khi | Website, video, API cacheable, tải file | Game, VoIP, IoT, MQTT, non-HTTP, cần IP tĩnh để whitelist, failover đa Region nhanh, blue/green giữa Region |

---

## 5. Tăng tốc truyền dữ liệu / hiệu năng

| Lớp | Kỹ thuật |
|---|---|
| Truyền dữ liệu | **S3 Transfer Acceleration** (upload xa), **multipart upload**, **byte-range fetches**, nhiều **prefix** để tăng request/giây, Global Accelerator cho TCP/UDP, DX cho hybrid |
| Lưu trữ block | Chọn đúng loại (**gp3/io2**), cấp IOPS/throughput, instance **EBS-optimized**, RAID 0 ở mức OS (hiệu năng; RAID 1 ít dùng vì EBS đã nhân bản trong AZ), **instance store** cho scratch |
| Compute | Đúng họ instance (C cho CPU, R cho RAM, I cho IOPS, G/P cho GPU), **cluster placement group**, ENA/EFA, Graviton, scale ngang |
| Cache nhiều lớp | **CloudFront** → **API Gateway cache** → **ElastiCache / DAX** → DB |
| DB | **Read replica** + RDS Proxy; **Aurora** (replica nhanh), **Aurora Serverless v2**; DynamoDB (+DAX, **Global Tables** để đọc/ghi gần người dùng); chọn đúng loại DB cho từng mẫu truy cập (polyglot persistence) |
| Kiến trúc | Bất đồng bộ (queue thay vì chờ), event-driven thay vì polling, đặt tài nguyên gần người dùng (multi-Region, edge) |

> 🎯 "Người dùng toàn cầu upload file lớn lên một bucket chậm" → **S3 Transfer Acceleration** (+ multipart). "Đọc nhiều phần của object rất lớn song song" → **byte-range fetch**. "DB quá tải bởi truy vấn đọc lặp lại" → **ElastiCache** (RDS) / **DAX** (DynamoDB) hoặc read replica.

---

## 6. Cost Optimization

### 6.1 Công cụ

| Công cụ | Làm gì |
|---|---|
| **Cost Explorer** | Phân tích & **dự báo** chi phí theo thời gian/dịch vụ/tag/account; gợi ý **Savings Plans/RI**; báo cáo coverage & utilization |
| **AWS Budgets** | Ngân sách + **cảnh báo** (chi phí, usage, RI/SP coverage/utilization; theo thực tế hoặc **dự báo**) + **Budget actions** (gắn IAM policy/SCP chặn, dừng EC2/RDS) |
| **Cost Anomaly Detection** | ML phát hiện chi phí **bất thường** (tăng đột biến) và cảnh báo |
| **Cost & Usage Report (CUR / Data Exports)** | Dữ liệu chi tiết nhất từng dòng → S3 → Athena/QuickSight |
| **Cost Allocation Tags** | Chia chi phí theo dự án/team/môi trường – phải **activate** tag trong Billing (chỉ áp từ lúc activate về sau) |
| **Compute Optimizer** | Gợi ý **right-sizing** bằng ML cho EC2, ASG, EBS, Lambda, ECS on Fargate, RDS |
| **Cost Optimization Hub** | Gom mọi khuyến nghị tiết kiệm ở một chỗ, ước tính số tiền |
| **Trusted Advisor** | Kiểm tra tài nguyên nhàn rỗi (EC2 CPU thấp, EIP không gắn, EBS không dùng, LB không có backend…) |
| **Savings Plans / RI** | Cam kết để giảm giá |
| **AWS Pricing Calculator** | Ước tính **trước** khi xây |
| **Organizations** | Gộp hoá đơn, chia sẻ giảm giá |

### 6.2 Mô hình mua – tổng hợp
- **Savings Plans**: *Compute SP* (EC2 mọi họ/Region/OS + Fargate + Lambda, tới ~66%), *EC2 Instance SP* (1 họ trong 1 Region, tới ~72%), *SageMaker SP*. Cam kết **$/giờ** 1 hoặc 3 năm; All/Partial/No Upfront.
- **Reserved Instances**: Standard (tới ~72%, bán lại được trên Marketplace) / Convertible (đổi cấu hình). *Regional RI* (linh hoạt AZ & size trong họ, không giữ chỗ) vs *Zonal RI* (giữ chỗ dung lượng trong AZ). Ngoài EC2 còn có reserved cho **RDS, ElastiCache, Redshift, OpenSearch, DynamoDB (reserved capacity)** – Savings Plans **không** áp cho các dịch vụ này (trừ khi AWS bổ sung loại SP mới – kiểm tra doc).
- **Spot**: tới ~90% cho tải chịu gián đoạn; Spot Fleet/ASG mixed instances, nhiều loại instance, `price-capacity-optimized`.
- **On-Demand**: phần biến động, ngắn hạn.

### 6.3 Chi phí truyền dữ liệu (nắm nguyên tắc)

| Luồng | Phí |
|---|---|
| Internet → AWS (data **vào**) | **Miễn phí** |
| AWS → Internet (data **ra**) | Có phí (~0,09–0,12 USD/GB tuỳ Region, giảm theo bậc; có mức miễn phí hằng tháng) |
| Giữa các **AZ** (cùng Region) | Có phí nhỏ, **tính cả 2 chiều** (~0,01 USD/GB mỗi chiều) |
| Cùng AZ qua **private IP** | **Miễn phí** (qua public IP/EIP thì vẫn bị tính như liên AZ) |
| Giữa các **Region** | Có phí (~0,02 USD/GB, tuỳ cặp Region) |
| Origin AWS → **CloudFront** | **Miễn phí**; CloudFront → Internet thường rẻ hơn EC2 → Internet |
| EC2 → S3/DynamoDB **cùng Region** | Miễn phí (nhưng nếu đi qua **NAT Gateway** thì trả phí xử lý NAT) |
| NAT Gateway | Phí giờ + **phí mỗi GB xử lý** |
| Interface endpoint / TGW | Phí giờ + phí mỗi GB |

> 💡 **Kinh nghiệm thực tế – phát hiện "tiền rơi" do data transfer**
> - Cost Explorer → lọc theo *Usage type* chứa `DataTransfer`, `NatGateway-Bytes`, `Regional-Bytes`. Phí liên AZ lớn bất thường thường do: microservice gọi chéo AZ liên tục, cluster Kafka/Elasticsearch sao chép chéo AZ, NAT dùng chung ở 1 AZ.
> - Thêm **S3/DynamoDB Gateway Endpoint** ở mọi VPC – miễn phí và thường cắt được một phần đáng kể phí NAT.
> - Đặt CloudFront trước S3/ALB vừa nhanh hơn vừa thường rẻ hơn cho data ra Internet.

### 6.4 Chiến lược tối ưu theo nhóm
- **Compute**: right-sizing (Compute Optimizer, xem CPU/RAM thực tế 2–4 tuần) → **Graviton** → mô hình mua (SP nền + Spot phần chịu gián đoạn) → **tắt ngoài giờ** cho dev/test (Instance Scheduler, ASG scheduled, Lambda + EventBridge) → serverless cho tải thưa.
- **Storage**: **gp2 → gp3**; xoá EBS **unattached**, snapshot cũ, AMI không dùng; **Snapshot Archive**; S3 **Lifecycle + Intelligent-Tiering**; dọn **noncurrent versions** và **incomplete multipart uploads**; EFS lifecycle IA/Archive.
- **Network**: Gateway Endpoint thay NAT cho S3/DynamoDB; giảm NAT dư thừa ở dev; CloudFront; giữ traffic trong AZ khi hợp lý; nén dữ liệu.
- **Database**: right-size instance; **Aurora Serverless v2** cho tải biến động; **reserved** cho DB nền; tắt DB dev ngoài giờ (nhớ RDS tự bật lại sau 7 ngày); read replica thay vì scale dọc quá mức; DynamoDB on-demand ↔ provisioned theo mẫu tải, table class Standard-IA.
- **Quản trị**: tag bắt buộc (tag policies, SCP từ chối tạo tài nguyên thiếu tag), chargeback/showback theo team, Budgets cho từng account/team, review chi phí hằng tháng.
- **Elastic IP / public IPv4**: mọi public IPv4 đều tính phí → bỏ IP không cần, dùng IPv6/ALB.
- **Log**: đặt **retention** cho CloudWatch Logs (mặc định không hết hạn), đẩy log cũ sang S3.

> 💡 **Kinh nghiệm thực tế – top "quick wins" chi phí theo thứ tự hay gặp**
> 1. Tài nguyên quên xoá (instance dev, NAT, ALB, RDS, EBS unattached, EIP, snapshot).
> 2. gp2 → gp3; instance quá to → right-size.
> 3. Savings Plans cho tải nền ổn định.
> 4. NAT Gateway: thêm gateway endpoint, gom NAT ở dev.
> 5. S3 lifecycle/Intelligent-Tiering, xoá version cũ.
> 6. CloudWatch Logs retention.
> 7. Tắt môi trường dev/test ngoài giờ (tiết kiệm ~65% thời gian chạy).

### 6.5 Sustainability (trụ cột thứ 6)
- Chọn Region dùng nhiều năng lượng tái tạo (khi không bị ràng buộc khác), đặt gần người dùng để giảm truyền dữ liệu.
- Tối đa hoá mức sử dụng (right-size, auto scaling, serverless – không để máy nhàn rỗi).
- Dùng phần cứng hiệu quả hơn (**Graviton**, instance thế hệ mới), dịch vụ managed (AWS tối ưu ở quy mô lớn).
- Giảm dữ liệu thừa (lifecycle, nén, xoá bản sao không cần).

---

## 7. Bẫy thường gặp
1. Chọn DR theo **RTO/RPO + chi phí**: RPO/RTO vài giờ/ngày → Backup & Restore; chục phút → Pilot Light; vài phút → Warm Standby; gần 0 → Active/Active.
2. "Failover tự động giữa hai Region với DNS" → **Route 53 failover + health check**; "không phụ thuộc DNS cache, IP tĩnh, TCP/UDP" → **Global Accelerator**.
3. "S3 nguồn nội dung chỉ truy cập qua CloudFront" → **OAC** + bucket policy (`AWS:SourceArn`).
4. "Nội dung trả phí chỉ người đã đăng nhập mới xem" → **signed URL** (1 file) / **signed cookies** (nhiều file).
5. "Cache chưa hết hạn nhưng cần cập nhật ngay" → **invalidation** (hoặc đổi tên file có version).
6. "Tải Spot bị thu hồi" → thiết kế stateless/checkpoint; dùng ASG mixed instances, đa dạng loại instance.
7. "Tiết kiệm nhất cho workload 24/7 ổn định nhiều năm" → **Savings Plans/RI 3 năm, All Upfront**.
8. "Tìm tài nguyên lãng phí / gợi ý right-size" → **Trusted Advisor / Compute Optimizer / Cost Optimization Hub**.
9. "Cảnh báo khi chi phí (dự báo) vượt X" → **AWS Budgets**; "phát hiện chi phí tăng bất thường" → **Cost Anomaly Detection**.
10. Data ra Internet tốn tiền → dùng **CloudFront** hoặc nén dữ liệu.
11. "Backup tập trung nhiều dịch vụ, nhiều account, không ai xoá được" → **AWS Backup + cross-account copy + Vault Lock (compliance)**.
12. "Sao chép liên tục server on-prem sang AWS để DR, RPO giây" → **Elastic Disaster Recovery (DRS)**.
13. "Chặn người dùng ở quốc gia X" → **CloudFront geo restriction** (hoặc WAF geo match).
14. "Origin failover cho CloudFront" chỉ với **GET/HEAD/OPTIONS** – không cứu được request ghi.
15. "Logic nhẹ ở edge (rewrite URL, header), siêu nhanh, rẻ" → **CloudFront Functions**; "cần gọi mạng/sửa body/origin event" → **Lambda@Edge**.
16. "Chi phí theo team" → **cost allocation tags** (nhớ activate) + Organizations (account theo team).

---

## 8. Tự kiểm tra

1. RTO = 15 phút, RPO = 5 phút, ngân sách vừa phải. Chiến lược DR hợp lý?
2. Khác biệt Pilot Light và Warm Standby?
3. Khi nào Global Accelerator tốt hơn CloudFront?
4. Làm sao chỉ cho phép CloudFront đọc S3 bucket?
5. Một job xử lý ảnh chạy theo batch, có thể dừng/tiếp. Chọn mô hình mua nào?
6. Cách giảm chi phí NAT Gateway khi instance private gọi S3 nhiều?
7. Tag không xuất hiện trong báo cáo chi phí. Có thể thiếu bước nào?
8. Liệt kê 6 trụ cột Well-Architected.
9. Cần 4 instance để gánh tải đỉnh, phải chịu được mất 1 AZ mà không giảm năng lực. Dùng 2 AZ hay 3 AZ, mỗi AZ bao nhiêu instance?
10. Signed URL hay signed cookies cho dịch vụ xem video HLS (hàng trăm segment)?
11. Bạn muốn backup không thể bị xoá kể cả khi account production bị chiếm quyền admin. Thiết kế?
12. Cache hit ratio của CloudFront chỉ 20%. Nghi ngờ gì đầu tiên?
13. Ứng dụng game UDP toàn cầu cần IP cố định và failover Region nhanh. Chọn gì?
14. Chi phí data transfer liên AZ tăng mạnh. Ba nguyên nhân thường gặp?
15. Công ty muốn tự động dừng EC2 của account dev khi chi phí tháng vượt 500 USD. Dùng gì?

<details><summary>Đáp án</summary>

1. **Warm Standby** (DB cross-Region replica/Aurora Global + hạ tầng thu nhỏ đang chạy + Route 53 failover). Pilot Light khó đạt RTO 15 phút ổn định.
2. Pilot Light: chỉ dữ liệu sao chép + lõi tối thiểu, compute chưa chạy – khi sự cố mới bật/khởi tạo. Warm Standby: bản thu nhỏ của cả hệ thống đã chạy sẵn, chỉ cần scale lên và chuyển traffic.
3. Giao thức TCP/UDP phi-HTTP, cần IP tĩnh (whitelist), failover nhanh đa Region không phụ thuộc DNS, không cần cache.
4. **OAC** + bucket policy cho `cloudfront.amazonaws.com` với điều kiện `AWS:SourceArn` = ARN distribution; bật Block Public Access; dùng REST endpoint.
5. **Spot** (kèm checkpoint/queue, đa dạng loại instance).
6. **S3 Gateway Endpoint** (miễn phí) gắn vào route table private subnet.
7. Chưa **activate cost allocation tag** trong Billing (tag chỉ có hiệu lực cho chi phí phát sinh sau khi activate; cần tới 24 giờ để xuất hiện).
8. Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability.
9. 2 AZ: mỗi AZ 4 (tổng 8). 3 AZ: mỗi AZ 2 (tổng 6) – mất 1 AZ còn 4. → **3 AZ rẻ hơn**.
10. **Signed cookies** – một lần cấp, truy cập được mọi segment mà không phải ký từng URL.
11. **AWS Backup** copy sang **account backup riêng** (ở OU được SCP bảo vệ) + **Vault Lock compliance mode** (+ có thể cross-Region); quyền xoá không nằm ở account production.
12. Cache key chứa quá nhiều thứ (cookie, header, query string không cần thiết) hoặc TTL quá ngắn/origin gửi `Cache-Control: no-cache`.
13. **Global Accelerator** (2 IP anycast tĩnh, hỗ trợ UDP, health check + failover Region).
14. NAT Gateway ở 1 AZ dùng chung cho AZ khác; dịch vụ gọi chéo AZ liên tục (microservice, DB replica, cluster tự sao chép); dùng public IP/EIP giữa các instance thay vì private IP; NLB bật cross-zone.
15. **AWS Budgets** với **Budget action** (dừng EC2/RDS hoặc gắn policy chặn) cho account dev.
</details>

## Tài liệu nên đọc thêm
- Whitepaper "Disaster Recovery of Workloads on AWS: Recovery in the Cloud" (4 chiến lược DR).
- Well-Architected: Reliability, Performance Efficiency, Cost Optimization, Sustainability pillar.
- Doc: "Restricting access to an Amazon S3 origin (OAC)", "Optimizing high availability with CloudFront origin failover", "Serving private content with signed URLs and signed cookies", "S3 Replication", "AWS Global Accelerator – How it works", "Overview of data transfer costs for common architectures" (AWS blog).
- FAQ: CloudFront, Global Accelerator, AWS Backup, Elastic Disaster Recovery, Savings Plans.
