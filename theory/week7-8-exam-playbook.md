# Tuần 7–8 – Luyện đề & Playbook thi

## 1. Quy trình luyện đề (rất quan trọng)

1. **Tuần 7**: làm 3–4 bộ đề (Tutorials Dojo / Skill Builder). Chế độ *review* (xem giải thích ngay) ở bộ đầu, chế độ *timed* từ bộ thứ 3.
2. **Review MỌI câu** – cả câu đúng (vì có thể đúng do đoán). Với mỗi câu sai/đoán, điền vào **sổ lỗi**.
3. Quay lại `theory/` + lab tương ứng cho mảng yếu, **làm lại lab** nếu là mảng thực hành (VPC, IAM…).
4. **Tuần 8**: làm lại đề (đề mới + đề sai), mục tiêu **ổn định ≥ 80–85%** ở ít nhất 2–3 bộ liên tiếp.
5. 2 ngày trước thi: đọc lại sổ lỗi + bảng so sánh bên dưới. Ngủ đủ.

### Mẫu sổ lỗi (copy ra file riêng)
| Ngày | Chủ đề | Câu hỏi tóm tắt | Mình chọn | Đúng là | Vì sao sai / Từ khoá quyết định |
|---|---|---|---|---|---|
| | | | | | |

---

## 2. Kỹ thuật làm bài

- **Đọc câu cuối trước** (họ hỏi gì?), rồi đọc kịch bản.
- Gạch **từ khoá ràng buộc**: *most cost-effective, least operational overhead, highly available, fault tolerant, near real-time, minimum changes, secure, without managing servers*.
  - `least operational overhead` → managed/serverless.
  - `most cost-effective` → rẻ nhất *thoả* yêu cầu (đừng chọn thứ xịn hơn mức cần).
  - `highly available` → đa AZ; `disaster recovery` → đa Region.
  - `minimal code changes` → giữ kiến trúc hiện tại, dịch vụ tương thích (Amazon MQ, Aurora MySQL-compatible, FSx…).
- **Loại trừ** 2 đáp án sai rõ ràng trước (sai kỹ thuật, thừa tính năng, vi phạm ràng buộc), rồi chọn trong 2 còn lại.
- Câu "chọn 2": mỗi đáp án phải tự đứng được, không cần bổ trợ nhau trừ khi đề nói.
- Đánh dấu câu khó (flag), **làm sau**. Mục tiêu ~ 2 phút/câu: 65 câu trong 130 phút (nếu được +30 phút ESL thì thoải mái hơn).
- Không để trống – không trừ điểm câu sai. 15 trong 65 câu không tính điểm; đừng hoảng khi gặp câu lạ.

---

## 3. Bảng so sánh "cứu cánh" (đọc kỹ trước ngày thi)

### Compute & Network
| Tình huống | Chọn |
|---|---|
| Routing HTTP theo path/host | ALB |
| IP tĩnh, TCP/UDP, hiệu năng cực cao | NLB |
| Appliance firewall bên thứ ba | GWLB |
| Instance private đi ra Internet | NAT Gateway |
| Instance private truy cập S3/DynamoDB miễn phí | Gateway Endpoint |
| Nối nhiều VPC + on-prem | Transit Gateway |
| Expose 1 dịch vụ riêng tư | PrivateLink |
| On-prem nhanh, mã hoá | Site-to-Site VPN |
| On-prem băng thông ổn định | Direct Connect (+VPN nếu cần mã hoá) |
| Chặn IP cụ thể ở mức subnet | NACL |
| Cache toàn cầu | CloudFront |
| IP anycast tĩnh, TCP/UDP | Global Accelerator |

### Storage & DB
| Tình huống | Chọn |
|---|---|
| Block 1 instance | EBS (io2 cho IOPS cao) |
| Dùng chung Linux nhiều AZ | EFS |
| Windows SMB | FSx for Windows |
| HPC | FSx for Lustre |
| Rất nhanh nhưng tạm thời | Instance Store |
| Lưu trữ lâu dài rẻ nhất | S3 Glacier Deep Archive |
| Mẫu truy cập bất định | S3 Intelligent-Tiering |
| WORM/compliance | S3 Object Lock |
| SQL quan hệ, HA | RDS Multi-AZ / Aurora |
| Scale đọc | Read Replica / Aurora Replica / ElastiCache |
| NoSQL ms, serverless | DynamoDB (+DAX) |
| Kho dữ liệu phân tích | Redshift |
| SQL trên S3 không hạ tầng | Athena |
| Graph / Mongo / Cassandra / Time-series | Neptune / DocumentDB / Keyspaces / Timestream |

### Integration & Serverless
| Tình huống | Chọn |
|---|---|
| Decouple, buffer | SQS |
| Fan-out | SNS (+SQS) |
| Event routing, schedule | EventBridge |
| Streaming nhiều consumer/replay | Kinesis Data Streams |
| Nạp stream vào S3/Redshift | Firehose |
| Workflow nhiều bước | Step Functions |
| Container không quản server | Fargate (ECS/EKS) |
| Chạy code theo sự kiện | Lambda |

### Security & Governance
| Tình huống | Chọn |
|---|---|
| Khoá mã hoá do AWS quản lý (audit) | KMS |
| HSM riêng, FIPS L3 | CloudHSM |
| Xoay vòng secret tự động | Secrets Manager |
| Chặn SQLi/XSS | WAF |
| DDoS nâng cao | Shield Advanced |
| Ai gọi API? | CloudTrail |
| Cấu hình thay đổi/tuân thủ | Config |
| Hành vi đáng ngờ | GuardDuty |
| Lỗ hổng CVE | Inspector |
| PII trong S3 | Macie |
| Gộp findings | Security Hub |
| Trần quyền cho account | SCP |
| Đăng nhập app web/mobile | Cognito User Pool |
| Cấp credential AWS cho user app | Cognito Identity Pool |
| SSO nhiều account | IAM Identity Center |

### Resilience & Cost
| Tình huống | Chọn |
|---|---|
| DR rẻ, chấp nhận giờ | Backup & Restore |
| DR vài chục phút | Pilot Light / Warm Standby |
| DR gần 0 | Active/Active |
| Cross-Region DB | Aurora Global / Cross-Region replica / DynamoDB Global Tables |
| Cảnh báo chi phí | AWS Budgets |
| Right-size | Compute Optimizer |
| Tải ổn định dài hạn | Savings Plans / RI |
| Batch chịu gián đoạn | Spot |

---

## 4. Từ khoá → dịch vụ (phản xạ nhanh)

- "Lift-and-shift" server → **Application Migration Service (MGN)**
- Chuyển DB khác engine → **DMS + SCT**
- Chuyển dữ liệu offline TB/PB → **Snow Family**; online → **DataSync**
- SFTP vào S3 → **Transfer Family**
- NAS on-prem mở rộng cloud → **Storage Gateway**
- Máy ảo thay SSH → **SSM Session Manager**
- IaC → **CloudFormation / CDK**
- PaaS upload code → **Elastic Beanstalk**
- Sự kiện hạ tầng AWS → **EventBridge**
- Giám sát metric/log/alarm → **CloudWatch**
- Distributed tracing → **X-Ray**
- Đóng gói dùng chung cấu hình giữa account → **RAM**
- Landing zone nhiều account → **Control Tower**

---

## 5. Ngày thi

**Đăng ký**: Tạo tài khoản ở aws.amazon.com/certification → *Schedule exam* → Pearson VUE (thi tại trung tâm hoặc **online proctored**). Phí 150 USD. Nên **xin trước ESL +30 phút** nếu bạn không dùng tiếng Anh bản ngữ.
**Online proctored**: kiểm tra webcam/mic/mạng ở máy thi trước, phòng yên tĩnh, bàn trống, giấy tờ tuỳ thân hợp lệ (tên khớp tài khoản).
**Trước đó**: ngủ đủ, ăn nhẹ, đến sớm 30 phút (hoặc vào sớm để check-in).
**Trong khi thi**: đọc kỹ, quản lý thời gian, flag câu khó, **dành 10–15 phút cuối để xem lại câu flag**.
**Sau thi**: kết quả pass/fail thường hiện ngay; điểm chi tiết trong vài ngày. Chứng chỉ có hạn 3 năm.

Kiểm tra lại mọi thông tin (mã đề, giá, quy định) trên trang chính thức của AWS vì có thể thay đổi.

---

## 6. Checklist sẵn sàng thi
- [ ] Làm xong 6 lab, `verify.sh` đều PASS
- [ ] Đọc xong lý thuyết tuần 1–6 (`week1` … `week6`), tự kiểm tra đúng ≥ 80%
- [ ] Hoàn thành 6 lab (`verify.sh` toàn PASS) và đã chạy `cleanup.sh` cho từng lab
- [ ] Đề thử: ≥ 80–85% ổn định ở ≥ 3 bộ liên tiếp
- [ ] Sổ lỗi được xem lại, không còn lỗi lặp
- [ ] Đã đọc Well-Architected (5–6 trụ cột) và FAQ: S3, VPC, RDS/Aurora, DynamoDB, SQS/SNS, IAM
- [ ] Đã dọn tài nguyên lab (`cleanup.sh`) – kiểm tra Billing
- [ ] Đã đặt lịch thi + xin ESL (nếu cần)
