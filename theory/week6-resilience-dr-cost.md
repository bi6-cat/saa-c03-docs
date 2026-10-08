# Tuần 6 – Resilience, Disaster Recovery, Hiệu năng toàn cầu & Cost Optimization

**Mục tiêu:** thiết kế hệ thống chịu lỗi theo RPO/RTO, tăng tốc phân phối nội dung toàn cầu, và tối ưu chi phí. Học kèm **Well-Architected Framework (6 trụ cột)**.
**Lab đi kèm:** `labs/lab06-cloudfront-dr`

---

## 1. Well-Architected Framework

6 trụ cột: **Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability**.
Đề SAA-C03 chia 4 domain (Secure, Resilient, High-Performing, Cost-Optimized) nhưng tư duy là các trụ cột này.

Nguyên tắc cốt lõi:
- Thiết kế cho **thất bại** (everything fails); tự động hoá; **stateless**; loose coupling; scale ngang (horizontal) thay vì dọc.
- **Không điểm đơn lẻ gây lỗi (no SPOF)** – mỗi tầng ≥ 2 AZ.
- Dùng dịch vụ managed khi có thể.

---

## 2. RPO / RTO & chiến lược DR

- **RPO** (Recovery Point Objective): chịu mất bao nhiêu **dữ liệu** (tính theo thời gian).
- **RTO** (Recovery Time Objective): chịu **gián đoạn** bao lâu.

| Chiến lược | RPO/RTO | Mô tả | Chi phí |
|---|---|---|---|
| **Backup & Restore** | Giờ → ngày | Sao lưu định kỳ (S3, snapshot, AWS Backup), khi sự cố mới dựng lại | Thấp nhất |
| **Pilot Light** | Phút → giờ | Dữ liệu luôn sao chép (DB replica), hạ tầng lõi tối thiểu; **bật phần còn lại khi sự cố** | Thấp |
| **Warm Standby** | Phút | Bản thu nhỏ **đang chạy** của toàn hệ thống, scale lên khi sự cố | Trung bình |
| **Multi-site Active/Active** | ≈ 0 / gần 0 | Chạy đầy đủ ở nhiều Region, chia tải | Cao nhất |

Công cụ DR:
- **AWS Backup**: policy backup tập trung, cross-Region/cross-account, Vault Lock.
- **AWS Elastic Disaster Recovery (DRS)**: sao chép liên tục server on-prem/EC2 sang AWS, RPO giây, RTO phút.
- **Cross-Region**: S3 CRR, RDS cross-Region read replica / snapshot copy, **Aurora Global Database**, **DynamoDB Global Tables**, EBS snapshot copy, AMI copy.
- **Route 53 failover / health check**, **Global Accelerator** để chuyển hướng traffic.

---

## 3. Mẫu thiết kế chịu lỗi

- **Web tier**: ALB đa AZ + ASG.
- **DB**: RDS Multi-AZ / Aurora; read replica cho đọc; cache ElastiCache.
- **Stateless**: session ở ElastiCache/DynamoDB; file ở S3/EFS; không lưu trên instance.
- **Loose coupling**: SQS/SNS/EventBridge.
- **Health check + tự phục hồi**: ASG thay instance; **EC2 Auto Recovery** (CloudWatch alarm `StatusCheckFailed_System` → recover); Route 53 health check.
- **Retry với exponential backoff + jitter**, timeout, circuit breaker.
- **Rate limiting & throttling** (API Gateway, WAF) bảo vệ backend.
- **Chaos / game day**: kiểm thử khả năng chịu lỗi (AWS Fault Injection Service).

---

## 4. CloudFront (CDN)

- Cache nội dung tại **Edge locations** → giảm độ trễ và tải cho origin. Origin: S3, ALB, EC2, API Gateway, HTTP server bất kỳ (kể cả on-prem).
- **Bảo mật**: HTTPS (cert ACM ở **us-east-1**), **OAC** (Origin Access Control) để **S3 chỉ nhận request từ CloudFront**, **signed URL / signed cookies** (nội dung trả phí/riêng tư), **geo restriction**, tích hợp **WAF**, field-level encryption.
- **Origin Groups** (failover origin chính → phụ).
- **Cache**: TTL, cache policy (header/query/cookie), **invalidation** (xoá cache sớm, tính phí khi nhiều) hoặc dùng **versioned filenames**.
- **Lambda@Edge** (Node/Python, chạy ở Regional Edge Cache, nhiều tình huống) và **CloudFront Functions** (nhẹ, sub-ms, thao tác header/URL).
- **Price class** giảm giá bằng cách giới hạn edge locations.

### CloudFront vs Global Accelerator
| | CloudFront | Global Accelerator |
|---|---|---|
| Mục đích | **Cache** nội dung (static/dynamic) HTTP/S | Tăng tốc & HA cho **ứng dụng** TCP/UDP qua backbone AWS |
| IP | DNS name, IP đổi | **2 IP anycast tĩnh** |
| Cache | Có | Không |
| Dùng khi | Website, video, API cacheable | Game, VoIP, IoT, non-HTTP, cần IP tĩnh, failover nhanh giữa Region |

---

## 5. Tăng tốc truyền dữ liệu / hiệu năng
- **S3 Transfer Acceleration**: upload xa nhờ edge location.
- **S3 multipart upload**, **byte-range fetches**; **prefix** nhiều để tăng request/giây.
- **EBS**: chọn loại (gp3/io2), **EBS-optimized**, RAID 0 (hiệu năng) / RAID 1 (dự phòng) ở mức OS.
- **EC2**: instance phù hợp (C cho CPU, R cho RAM), **placement group cluster**, Enhanced Networking/EFA.
- **Cache nhiều lớp**: CloudFront → API Gateway cache → ElastiCache/DAX → DB.
- **Read replica** + RDS Proxy; **Aurora Serverless v2**; **DynamoDB DAX / Global Tables**.
- **Tránh polling**; dùng bất đồng bộ.

---

## 6. Cost Optimization

### 6.1 Công cụ
| Công cụ | Làm gì |
|---|---|
| **Cost Explorer** | Phân tích & dự báo chi phí theo thời gian/dịch vụ/tag |
| **AWS Budgets** | Ngân sách + **cảnh báo** (chi phí, usage, RI/SP coverage) + hành động tự động |
| **Cost & Usage Report (CUR)** | Dữ liệu chi tiết nhất (S3, Athena) |
| **Cost Allocation Tags** | Chia chi phí theo dự án/team (phải **activate** tag) |
| **Compute Optimizer** | Gợi ý right-sizing EC2/EBS/Lambda/ASG bằng ML |
| **Trusted Advisor** | Đề xuất tiết kiệm (tài nguyên nhàn rỗi…) |
| **Savings Plans / RI** | Cam kết để giảm giá |
| **AWS Pricing Calculator** | Ước tính trước |
| **Organizations** | Gộp hoá đơn |

### 6.2 Chiến lược
- **Right-sizing**, tắt tài nguyên không dùng (lịch dev/test), xoá EBS/EIP/snapshot mồ côi.
- **Mô hình mua**: Savings Plans/RI cho nền ổn định; **Spot** cho batch/chịu gián đoạn; On-Demand cho phần biến động; **mixed instances ASG**.
- **Serverless / managed** cho tải thưa (trả theo dùng).
- **S3**: Lifecycle + Intelligent-Tiering + class phù hợp; xoá multipart dở dang.
- **Truyền dữ liệu**: data **vào** AWS miễn phí; **ra Internet** tính phí; **giữa AZ** tính phí (nhỏ); **cùng AZ qua private IP** miễn phí. Dùng CloudFront (rẻ hơn truyền thẳng từ origin), **Gateway endpoint** thay NAT cho S3/DynamoDB.
- **NAT Gateway** đắt: gộp, dùng endpoint, hoặc dùng NAT instance cho tải thấp (đánh đổi vận hành).
- **Graviton** (ARM) thường rẻ/hiệu năng-trên-giá tốt hơn.
- **Right-sizing DB**: Aurora Serverless v2, Reserved cho DB nền, tắt DB dev ngoài giờ, dùng read replica thay vì scale dọc quá mức.

---

## 7. Bẫy thường gặp
1. Chọn DR theo **RTO/RPO + chi phí**: RPO/RTO vài giờ → Backup/Restore hoặc Pilot Light; gần 0 → Active/Active.
2. "Failover tự động giữa hai Region với DNS" → **Route 53 failover + health check**; "không phụ thuộc DNS cache, IP tĩnh" → **Global Accelerator**.
3. "S3 nguồn nội dung chỉ truy cập qua CloudFront" → **OAC** + bucket policy.
4. "Nội dung trả phí chỉ người đã đăng nhập mới xem" → **signed URL/cookies**.
5. "Cache chưa hết hạn nhưng cần cập nhật ngay" → **invalidation** (hoặc đổi tên file có version).
6. "Tải Spot bị thu hồi" → thiết kế stateless/checkpoint; dùng ASG mixed.
7. "Tiết kiệm nhất cho workload 24/7 ổn định nhiều năm" → **Savings Plans/RI 3 năm, trả trước toàn bộ**.
8. "Tìm tài nguyên lãng phí" → **Trusted Advisor / Compute Optimizer / Cost Explorer**.
9. "Cảnh báo khi chi phí vượt X" → **AWS Budgets**.
10. Tính phí data ra Internet → dùng **CloudFront** hoặc nén dữ liệu.

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

<details><summary>Đáp án</summary>

1. Warm Standby (hoặc Aurora Global/ cross-Region replica + hạ tầng thu nhỏ đang chạy).
2. Pilot Light: chỉ dữ liệu + lõi tối thiểu, khi sự cố mới bật phần còn lại. Warm Standby: bản thu nhỏ của cả hệ thống đã chạy sẵn, chỉ cần scale.
3. Giao thức TCP/UDP phi-HTTP, cần IP tĩnh, failover nhanh, không cần cache.
4. OAC + bucket policy cho `cloudfront.amazonaws.com` với điều kiện `AWS:SourceArn` của distribution; bật Block Public Access.
5. Spot (kèm checkpoint/queue).
6. S3 Gateway Endpoint (miễn phí) gắn vào route table private subnet.
7. Chưa **activate cost allocation tag** trong Billing (và tag phải được gắn trước khi phát sinh chi phí).
8. Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability.
</details>

## Tài liệu nên đọc thêm
- Whitepaper "Disaster Recovery of Workloads on AWS: Recovery in the Cloud" (4 chiến lược DR).
- Well-Architected: Reliability, Performance Efficiency, Cost Optimization pillar.
- Doc: "CloudFront – restrict access to an Amazon S3 origin (OAC)", "CloudFront origin groups", "S3 Replication". FAQ: CloudFront, Global Accelerator, AWS Backup.
