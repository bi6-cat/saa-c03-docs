# Tuần 2 – Networking: VPC, kết nối, Route 53

**Mục tiêu:** tự thiết kế được VPC nhiều tầng, chọn đúng cách kết nối (peering / TGW / VPN / Direct Connect / PrivateLink) và routing policy của Route 53. Đây là phần nhiều người yếu nhất – dành thời gian vẽ sơ đồ.
**Lab đi kèm:** `labs/lab02-vpc`

---

## 1. VPC cơ bản

- **VPC** gắn với 1 Region, trải qua nhiều AZ. CIDR IPv4 từ **/16 đến /28**. Có thể thêm CIDR phụ.
- **Subnet** nằm trong **đúng 1 AZ**. Mỗi subnet **mất 5 IP** (network, router, DNS, dự phòng, broadcast).
  Ví dụ /24 = 256 − 5 = 251 IP khả dụng.
- **Public subnet** = subnet có route `0.0.0.0/0 → Internet Gateway` (và instance có public IP). **Private subnet** = không có route trực tiếp ra IGW.
- **Route table**: quyết định hướng đi của traffic; route cụ thể nhất (longest prefix) thắng. Subnet không gắn route table riêng dùng **main route table**.
- **Default VPC**: mỗi Region có sẵn, subnet public ở mọi AZ – tiện thử nghiệm, **không dùng cho production**.

### Ghép thành phần
```
Internet ── IGW ── [Public subnet: ALB, NAT GW, bastion] ──
                         │ route 0.0.0.0/0 → NAT GW
                    [Private subnet: app EC2] ── [Private/DB subnet: RDS]
                         └─ Gateway Endpoint → S3 / DynamoDB (không qua Internet, miễn phí)
```

### Internet access
| Thành phần | Vai trò |
|---|---|
| **Internet Gateway (IGW)** | Cho phép 2 chiều giữa VPC và Internet. Scale tự động, HA, miễn phí |
| **NAT Gateway** | Cho instance **private** đi ra Internet (IPv4), **chặn kết nối vào**. Đặt trong **public subnet**, **nằm trong 1 AZ** → muốn HA phải mỗi AZ một cái. Tính phí theo giờ + data |
| **NAT Instance** | Cách cũ tự quản lý (EC2), phải tắt source/dest check. Rẻ hơn ở tải nhỏ nhưng tự lo HA |
| **Egress-only IGW** | Giống NAT nhưng cho **IPv6** (outbound only) |

---

## 2. Security Group vs NACL

| | Security Group | Network ACL |
|---|---|---|
| Cấp độ | ENI / instance | **Subnet** |
| Trạng thái | **Stateful** (cho request đi vào thì response tự được ra) | **Stateless** (phải mở cả chiều về, nhớ **ephemeral ports 1024–65535**) |
| Rule | Chỉ **Allow** | **Allow + Deny**, đánh giá theo **số thứ tự rule nhỏ → lớn**, khớp là dừng |
| Mặc định | Chặn inbound, cho phép outbound | NACL mặc định: cho phép hết; NACL mới tạo: chặn hết |
| Nguồn rule | CIDR hoặc **SG khác** | CIDR |

- Muốn **chặn một IP cụ thể** → dùng **NACL** (SG không có Deny).
- SG tham chiếu SG: `web-sg` chỉ nhận port 80 từ `alb-sg` → mô hình chuẩn.

---

## 3. VPC Endpoints (truy cập dịch vụ AWS không qua Internet)

| Loại | Dịch vụ | Cách hoạt động | Chi phí |
|---|---|---|---|
| **Gateway Endpoint** | **Chỉ S3 và DynamoDB** | Thêm route (prefix list) vào route table | **Miễn phí** |
| **Interface Endpoint** (PrivateLink) | Hầu hết dịch vụ khác (SQS, SNS, Secrets Manager, API…, cả S3 interface) | ENI với private IP trong subnet | Phí theo giờ + data |

- Đề hay hỏi: "Instance private cần ghi S3 mà **không đi qua NAT/Internet và rẻ nhất**" → **Gateway Endpoint**.
- **AWS PrivateLink**: expose dịch vụ của bạn cho VPC khác/khách hàng **không cần peering/IGW** (qua NLB + Endpoint Service), không lo CIDR chồng lấn.

---

## 4. Kết nối giữa mạng

### 4.1 VPC Peering
- Nối 2 VPC (cùng/khác account, cùng/khác Region). **CIDR không được chồng lấn.**
- **Không bắc cầu (non-transitive)**: A–B, B–C ≠ A–C. Phải cập nhật route table **hai phía**.
- Số VPC lớn → mesh peering rối → dùng **Transit Gateway**.

### 4.2 Transit Gateway (TGW)
- **Hub-and-spoke**: một router trung tâm nối nhiều VPC, VPN, Direct Connect; **có bắc cầu**.
- Hỗ trợ route table riêng để cô lập, **multicast**, **ECMP** (cộng băng thông nhiều tunnel VPN), peering giữa TGW các Region.

### 4.3 Site-to-Site VPN
- IPsec qua Internet, 2 tunnel/connection, dựng trong vài phút. Băng thông ~1,25 Gbps/tunnel.
- Cần **Virtual Private Gateway** (gắn VPC) hoặc TGW + **Customer Gateway** (thiết bị phía on-prem).
- **Client VPN**: cho từng người dùng truy cập VPC.

### 4.4 AWS Direct Connect (DX)
- Đường **riêng vật lý**, băng thông ổn định, độ trễ thấp: **1 / 10 / 100 Gbps** (dedicated) hoặc hosted (50 Mbps…).
- Mất vài tuần để cung cấp. **Mặc định KHÔNG mã hoá** → thêm **VPN trên DX** nếu cần mã hoá.
- HA: 2 DX ở 2 location, hoặc **DX + VPN dự phòng**.
- **Direct Connect Gateway**: nối 1 DX tới nhiều VPC ở nhiều Region.

| Cần | Chọn |
|---|---|
| Nhanh, rẻ, tạm thời / dự phòng, mã hoá | Site-to-Site VPN |
| Băng thông lớn, ổn định, độ trễ thấp, riêng | Direct Connect |
| Nối nhiều VPC + on-prem, dễ quản | Transit Gateway |
| 2 VPC đơn giản | Peering |
| Chỉ expose 1 dịch vụ | PrivateLink |

---

## 5. Giám sát & công cụ mạng
- **VPC Flow Logs**: log metadata IP traffic (ACCEPT/REJECT) ở mức VPC/subnet/ENI → CloudWatch Logs, S3, Firehose. Dùng điều tra "vì sao không kết nối được". **Không** chứa nội dung packet.
- **Reachability Analyzer**: phân tích đường đi giữa 2 điểm (cấu hình tĩnh).
- **Traffic Mirroring**: sao chép packet để phân tích sâu.
- **Network Firewall** (stateful, IDS/IPS, lọc domain), **AWS WAF** (L7), **Shield** (DDoS) – chi tiết tuần 5.

---

## 6. Route 53

### 6.1 Cơ bản
- DNS managed, SLA 100%, **Public hosted zone** (Internet) và **Private hosted zone** (trong VPC).
- Record: A, AAAA, CNAME, MX, TXT, NS…
- **CNAME không dùng được ở zone apex** (`example.com`), **Alias record thì được**; Alias trỏ tới tài nguyên AWS (ALB, CloudFront, S3 website, API Gateway…), **miễn phí truy vấn** và hỗ trợ health check của đích.

### 6.2 Routing policy
| Policy | Dùng khi |
|---|---|
| **Simple** | 1 đích (có thể nhiều giá trị, client chọn ngẫu nhiên), không health check |
| **Weighted** | Chia tỷ lệ traffic (canary, blue/green) |
| **Latency** | Đưa người dùng đến Region có độ trễ thấp nhất |
| **Failover** | Active–Passive với health check |
| **Geolocation** | Theo vị trí người dùng (quốc gia/lục địa) – tuân thủ, ngôn ngữ, giới hạn phân phối |
| **Geoproximity** | Theo vị trí địa lý + **bias** để dồn thêm traffic (cần Traffic Flow) |
| **Multivalue answer** | Trả tới 8 bản ghi khỏe, như "load balancing DNS" thô sơ kèm health check |
| **IP-based** | Theo CIDR của client |

- **Health check**: endpoint, CloudWatch alarm, hoặc calculated (kết hợp). Health check **không** đi tới được private resource (dùng CloudWatch alarm cho trường hợp đó).
- **TTL** thấp → đổi nhanh hơn nhưng nhiều truy vấn hơn.

---

## 7. Accelerate truy cập toàn cầu (xem thêm tuần 6)
- **CloudFront**: CDN cache nội dung (HTTP/S).
- **Global Accelerator**: 2 IP **anycast tĩnh**, đi vào backbone AWS, hợp cả TCP/UDP, failover nhanh theo health check (không cache).

---

## 8. Bẫy thường gặp
1. "Instance ở private subnet cần cài bản vá từ Internet" → **NAT Gateway** trong public subnet + route.
2. "NAT Gateway HA" → **một cái mỗi AZ**, route table mỗi AZ trỏ NAT cùng AZ.
3. Peering **không bắc cầu**; CIDR trùng nhau → không peering được.
4. "Truy cập S3 từ VPC không qua Internet, miễn phí" → **Gateway endpoint**.
5. "Chặn IP độc hại" → **NACL deny** (hoặc WAF với ALB/CloudFront).
6. NACL stateless: quên mở **ephemeral ports** cho chiều trả → timeout.
7. "On-prem ↔ AWS, riêng tư, băng thông cao" → DX; "nhanh trong vài ngày, mã hoá" → VPN.
8. "Zone apex trỏ vào ALB" → **Alias**, không phải CNAME.
9. Số IP khả dụng subnet = tổng − **5**.

---

## 9. Tự kiểm tra

1. VPC `10.0.0.0/16`, subnet `/24`: mỗi subnet có bao nhiêu IP dùng được?
2. Phân biệt public vs private subnet về mặt kỹ thuật.
3. Vì sao 3 VPC peering A–B và B–C vẫn không cho A nói chuyện với C? Giải pháp?
4. Rule NACL số 100 deny `203.0.113.5/32`, rule số 200 allow `0.0.0.0/0`. Packet từ IP đó bị gì?
5. NAT Gateway nằm ở public hay private subnet? Có HA tự động qua nhiều AZ không?
6. Gateway endpoint hỗ trợ dịch vụ nào?
7. Direct Connect có mã hoá mặc định không? Cách bổ sung?
8. Khi nào dùng Geolocation, khi nào Latency routing?

<details><summary>Đáp án</summary>

1. 256 − 5 = 251.
2. Public: route table có `0.0.0.0/0 → IGW` (và instance có public IP). Private: không có route đó.
3. Peering không bắc cầu; dùng Transit Gateway hoặc peering A–C trực tiếp.
4. Bị chặn (rule 100 khớp trước, dừng).
5. Public subnet; không – nằm trong 1 AZ, cần mỗi AZ một NAT.
6. S3 và DynamoDB.
7. Không; chạy IPsec VPN trên Direct Connect.
8. Geolocation: theo vị trí để tuân thủ/ngôn ngữ/giới hạn khu vực. Latency: để người dùng tới Region nhanh nhất.
</details>

## Tài liệu nên đọc thêm
- Doc: "VPC – How Amazon VPC works", "Gateway endpoints", bài "Building a scalable and secure multi-VPC AWS network infrastructure" (whitepaper).
