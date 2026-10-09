# Tuần 2 – Networking: VPC, kết nối, Route 53

**Mục tiêu:** tự thiết kế được VPC nhiều tầng, chọn đúng cách kết nối (peering / TGW / VPN / Direct Connect / PrivateLink) và routing policy của Route 53. Đây là phần nhiều người yếu nhất – dành thời gian **vẽ sơ đồ bằng tay**.
**Lab đi kèm:** `labs/lab02-vpc`

> Ký hiệu: **💡 Kinh nghiệm thực tế** (vận hành thật) · **🎯 Mẹo thi** (cách đề hỏi) · **⚠️ Hay nhầm**.

---

## 1. VPC cơ bản

### 1.1 VPC & CIDR
- **VPC** gắn với **1 Region**, trải qua mọi AZ của Region đó.
- CIDR IPv4 từ **/16 (65.536 IP) đến /28 (16 IP)**. Có thể thêm CIDR phụ (mặc định tối đa 5 CIDR IPv4/VPC, xin tăng được). Có thể thêm IPv6 (/56 do AWS cấp hoặc BYOIP).
- Nên dùng dải private RFC 1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.
- **Default VPC**: mỗi Region có sẵn `172.31.0.0/16`, mỗi AZ một subnet `/20` public → tiện thử nghiệm, **không dùng cho production**.

**Ôn nhanh CIDR**: `/n` → số IP = 2^(32−n).

| CIDR | Số IP | Dùng được trong subnet AWS |
|---|---|---|
| /16 | 65.536 | 65.531 |
| /20 | 4.096 | 4.091 |
| /22 | 1.024 | 1.019 |
| /24 | 256 | **251** |
| /26 | 64 | 59 |
| /28 | 16 | **11** |

### 1.2 Subnet
- Subnet nằm trong **đúng 1 AZ**; không trải nhiều AZ.
- Mỗi subnet **AWS giữ 5 IP**. Với `10.0.0.0/24`:
  - `.0` network address
  - `.1` VPC router
  - `.2` Amazon DNS (Route 53 Resolver; thực tế là "base VPC + 2")
  - `.3` dự phòng cho AWS
  - `.255` broadcast (VPC không hỗ trợ broadcast nhưng vẫn giữ)
- **Public subnet** = route table có `0.0.0.0/0 → Internet Gateway` (và instance có public IP / EIP).
- **Private subnet** = không có route trực tiếp ra IGW (có thể ra Internet qua NAT).
- Bật **Auto-assign public IPv4** chỉ ở public subnet (lab02 có yêu cầu).

> 💡 **Kinh nghiệm thực tế – quy hoạch IP (làm 1 lần, sống với nó nhiều năm)**
> - **Không bao giờ** dùng lại cùng một CIDR (vd. `10.0.0.0/16`) cho mọi VPC/môi trường. Sau này peering, Transit Gateway, VPN về on-prem sẽ **trùng dải** và không nối được – sửa lại cực đau (phải dựng lại VPC).
> - Lập bảng IPAM ngay từ đầu: ví dụ `10.0.0.0/16` dev, `10.1.0.0/16` staging, `10.2.0.0/16` prod, `10.100.0.0/16` dành cho on-prem… Kiểm tra dải on-prem/công ty để tránh trùng. Doanh nghiệp lớn dùng **VPC IPAM**.
> - Subnet đừng quá nhỏ: EKS/ECS (mỗi pod/task một IP), Lambda trong VPC, ALB, interface endpoint đều "ăn" IP. Private subnet cho container nên ≥ /20.
> - Mẫu phổ biến: mỗi AZ 3 subnet – **public** (ALB, NAT), **private-app**, **private-data** (RDS, ElastiCache) – mỗi tầng một route table/NACL riêng.

### 1.3 Route table
- Mỗi subnet gắn **đúng 1** route table (một route table gắn được nhiều subnet). Subnet không gắn route table riêng → dùng **main route table**.
- Route `local` (CIDR của VPC) luôn có, không xoá được → mọi subnet trong VPC nói chuyện được với nhau (chỉ SG/NACL chặn).
- **Longest prefix match**: route cụ thể nhất thắng (`10.1.2.0/24` thắng `10.1.0.0/16` thắng `0.0.0.0/0`).
- Target có thể là: IGW, NAT GW, VPC peering, TGW, VGW, gateway endpoint (prefix list), ENI (appliance), GWLB endpoint…

> 💡 **Kinh nghiệm thực tế**: giữ **main route table "sạch"** (chỉ có `local`) và gắn route table tường minh cho từng subnet. Nếu main RT có route ra IGW, mọi subnet mới tạo mà quên gắn RT sẽ **vô tình thành public**.

### 1.4 Ghép thành phần

```
                         Internet
                            │
                     ┌──────▼──────┐
                     │     IGW     │
                     └──────┬──────┘
   ┌────────────────────────┼────────────────────────┐  VPC 10.0.0.0/16
   │  AZ-a                  │                 AZ-b   │
   │ ┌─────────────────┐    │    ┌─────────────────┐ │
   │ │ Public 10.0.0/24│    │    │ Public 10.0.1/24│ │  RT-public: 0.0.0.0/0 → IGW
   │ │ ALB node, NAT-a │    │    │ ALB node, NAT-b │ │
   │ └────────┬────────┘         └────────┬────────┘ │
   │ ┌────────▼────────┐         ┌────────▼────────┐ │
   │ │ App 10.0.10/24  │         │ App 10.0.11/24  │ │  RT-app-a: 0.0.0.0/0 → NAT-a
   │ │ EC2/ECS         │         │ EC2/ECS         │ │  RT-app-b: 0.0.0.0/0 → NAT-b
   │ └────────┬────────┘         └────────┬────────┘ │  + S3 prefix list → Gateway Endpoint
   │ ┌────────▼────────┐         ┌────────▼────────┐ │
   │ │ DB 10.0.20/24   │         │ DB 10.0.21/24   │ │  RT-db: chỉ local
   │ │ RDS primary     │◄───────►│ RDS standby     │ │
   │ └─────────────────┘         └─────────────────┘ │
   └──────────────────────────────────────────────────┘
```

### 1.5 Thành phần ra/vào Internet

| Thành phần | Vai trò | Ghi chú |
|---|---|---|
| **Internet Gateway (IGW)** | NAT 1-1 giữa public IP ↔ private IP, cho phép 2 chiều | 1 IGW/VPC, tự scale, HA, miễn phí (chỉ trả data transfer) |
| **NAT Gateway** | Instance **private** đi ra Internet (IPv4), **chặn kết nối khởi tạo từ ngoài vào** | Đặt trong **public subnet**, có EIP; **nằm trong 1 AZ**; 5 Gbps tự tăng tới 100 Gbps; tính phí **theo giờ + theo GB xử lý** |
| **NAT Instance** | EC2 tự làm NAT (AMI NAT, tắt source/dest check) | Rẻ ở tải rất nhỏ, có thể dùng làm bastion, nhưng tự lo HA/scale/patch – đề coi là "cách cũ" |
| **Egress-only IGW** | Giống NAT cho **IPv6** (chỉ chiều ra) | IPv6 là public nên không cần NAT, chỉ cần chặn chiều vào |
| **Private NAT Gateway** | NAT giữa các mạng private (vd. VPC có CIDR trùng on-prem) | Không có EIP, không ra Internet |

**NAT Gateway HA**: một NAT/AZ, route table của mỗi AZ trỏ tới NAT **cùng AZ**. Nếu cả 2 AZ dùng chung NAT ở AZ-a: AZ-a sập → AZ-b mất Internet, đồng thời phải trả phí data **liên AZ**.

> 💡 **Kinh nghiệm thực tế – NAT Gateway là "kẻ ngốn tiền thầm lặng"**
> - Phí ~0,045–0,06 USD/giờ/NAT (tuỳ Region) **+ ~0,045 USD/GB xử lý**. 3 AZ × 24/7 ≈ hơn 100 USD/tháng chỉ tiền giờ, chưa kể data.
> - Thủ phạm hay gặp: instance private kéo dữ liệu **S3/DynamoDB qua NAT** (→ thêm **Gateway Endpoint**, miễn phí), pull image ECR hàng loạt (→ interface endpoint ECR + gateway endpoint S3), gửi log CloudWatch nhiều (→ interface endpoint logs).
> - Dev/test: có thể chỉ 1 NAT cho cả VPC, hoặc tắt khi không dùng. Lab trong repo này **cố ý không tạo NAT**.
> - Dùng VPC Flow Logs + Cost Explorer (usage type `NatGateway-Bytes`) để tìm ai đang đẩy traffic qua NAT.
> - AWS đã bổ sung biến thể NAT Gateway trải nhiều AZ (chế độ *regional*) trong thời gian gần đây – kiểm tra doc nếu dùng thật; **đề thi vẫn dùng mô hình NAT zonal**: "mỗi AZ một NAT".

### 1.6 DNS trong VPC
- Hai thuộc tính VPC: `enableDnsSupport` (dùng Amazon DNS server) và `enableDnsHostnames` (cấp hostname public cho instance). **Phải bật cả hai** để dùng **Private Hosted Zone** và **private DNS của interface endpoint**.
- **Route 53 Resolver** (tại `.2`) phân giải cả tên nội bộ lẫn Internet.
- **Hybrid DNS**:
  - **Inbound endpoint**: on-prem hỏi được tên trong VPC/private hosted zone.
  - **Outbound endpoint + forwarding rule**: VPC hỏi được tên miền on-prem (`corp.local`).
- **Route 53 Resolver DNS Firewall**: chặn truy vấn DNS tới domain độc hại (chống **data exfiltration qua DNS**).

---

## 2. Security Group vs NACL

| | Security Group | Network ACL |
|---|---|---|
| Cấp độ | **ENI** (instance, RDS, Lambda trong VPC, endpoint…) | **Subnet** (áp cho mọi thứ trong subnet) |
| Trạng thái | **Stateful** – cho chiều đi thì chiều về tự cho | **Stateless** – phải mở **cả chiều về**, nhớ **ephemeral ports** |
| Rule | Chỉ **Allow** | **Allow + Deny** |
| Đánh giá | Gộp **tất cả** rule | Theo **số thứ tự nhỏ → lớn**, khớp rule đầu tiên là **dừng** |
| Mặc định | SG mới: chặn mọi inbound, cho mọi outbound | NACL mặc định: cho tất cả. NACL **mới tạo**: chặn tất cả |
| Nguồn/đích rule | CIDR, **SG khác**, prefix list | Chỉ CIDR |
| Giới hạn (mặc định) | ~60 rule inbound + 60 outbound/SG, 5 SG/ENI | ~20 rule/chiều |

**Ephemeral ports**: client mở kết nối từ một cổng ngẫu nhiên cao. Linux 32768–60999, Windows 49152–65535, ELB/NAT GW 1024–65535 → NACL thường mở **1024–65535** cho chiều trả về.

**Ví dụ NACL cho public subnet chứa web server:**

| Chiều | Rule # | Giao thức | Port | Nguồn/Đích | Hành động |
|---|---|---|---|---|---|
| Inbound | 90 | All | All | `203.0.113.5/32` (IP xấu) | **DENY** |
| Inbound | 100 | TCP | 443 | 0.0.0.0/0 | ALLOW |
| Inbound | 110 | TCP | 1024–65535 | 0.0.0.0/0 | ALLOW (response cho kết nối do server khởi tạo, vd. tải bản vá) |
| Inbound | * | All | All | 0.0.0.0/0 | DENY |
| Outbound | 100 | TCP | 1024–65535 | 0.0.0.0/0 | ALLOW (response về client) |
| Outbound | 110 | TCP | 443 | 0.0.0.0/0 | ALLOW (server gọi ra ngoài) |
| Outbound | * | All | All | 0.0.0.0/0 | DENY |

**Mẫu SG theo chuỗi (chuẩn)**:
- `alb-sg`: inbound 443 từ `0.0.0.0/0`.
- `web-sg`: inbound 80 **từ `alb-sg`**.
- `db-sg`: inbound 3306 **từ `web-sg`**.
→ Không cần biết IP, instance mới trong ASG tự được phép.

> 💡 **Kinh nghiệm thực tế**
> - 95% trường hợp chỉ cần **Security Group**; để NACL ở mặc định (allow all) trừ khi cần chặn IP/dải, hoặc yêu cầu tuân thủ "defense in depth" ở mức subnet.
> - Đánh số rule NACL cách nhau 10 hoặc 100 để chèn rule sau này.
> - Sửa SG có hiệu lực **ngay lập tức**; kết nối đã được theo dõi (tracked) có thể vẫn sống sau khi xoá rule – khi ứng phó sự cố cần chặn ngay kết nối đang có, NACL hiệu quả hơn.
> - "Timeout" (treo rồi hết giờ) thường là SG/NACL/route chặn; "Connection refused" (bị từ chối ngay) thường là đường mạng đã thông nhưng **không có process** lắng nghe cổng đó.
> - Đừng mở SSH `0.0.0.0/0`. Dùng Session Manager (không cần port 22) hoặc giới hạn IP văn phòng.

> 🎯 **Mẹo thi**: "Chặn một IP/dải IP cụ thể" → **NACL deny** (SG không có Deny) hoặc **WAF IP set** nếu traffic đi qua ALB/CloudFront/API Gateway. "Sửa SG rồi mà response vẫn không về" → SG stateful nên không phải SG – xem NACL chiều về (ephemeral ports).

---

## 3. VPC Endpoints (truy cập dịch vụ AWS không qua Internet)

| | **Gateway Endpoint** | **Interface Endpoint** (PrivateLink) |
|---|---|---|
| Dịch vụ | **Chỉ S3 và DynamoDB** | Hầu hết dịch vụ khác (SQS, SNS, KMS, Secrets Manager, SSM, ECR, CloudWatch, STS, API Gateway private…) và cả S3 |
| Cơ chế | Thêm route **prefix list** (`pl-xxx`) → `vpce-xxx` vào route table | Tạo **ENI có private IP** trong subnet của bạn; DNS của dịch vụ trỏ về IP này (private DNS) |
| Bảo mật | **Endpoint policy** | Endpoint policy + **Security Group** |
| Truy cập từ on-prem/VPC khác (qua VPN/DX/peering/TGW) | **Không** | **Có** |
| Chi phí | **Miễn phí** | Phí theo giờ mỗi AZ + phí theo GB |

**Siết bucket chỉ cho truy cập qua endpoint** (bucket policy):

```json
{
  "Sid": "DenyNotFromMyVpce",
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": ["arn:aws:s3:::secure-bucket", "arn:aws:s3:::secure-bucket/*"],
  "Condition": { "StringNotEquals": { "aws:SourceVpce": "vpce-0abc123def456" } }
}
```
⚠️ Policy kiểu này cũng khoá **chính bạn** trên Console (không đi qua endpoint). Thêm ngoại lệ cho role admin trước khi áp dụng.

**AWS PrivateLink cho dịch vụ của bạn**: bên cung cấp đặt dịch vụ sau **NLB** → tạo **Endpoint Service**; bên tiêu thụ tạo **interface endpoint** tới service đó.
- Không cần peering/IGW/NAT, **không lo CIDR trùng**, chỉ expose **một dịch vụ** (không mở cả mạng), một chiều (consumer → provider).
- Phù hợp mô hình SaaS phục vụ hàng trăm khách hàng/VPC.

> 💡 **Kinh nghiệm thực tế – VPC không có NAT (private hoàn toàn)**
> Muốn EC2/ECS/Lambda trong VPC không có Internet vẫn hoạt động, thường cần các endpoint: S3 (gateway), DynamoDB (gateway), `ecr.api`, `ecr.dkr`, `logs`, `sts`, `secretsmanager`, `ssm` + `ssmmessages` + `ec2messages` (cho Session Manager), `kms`… Mỗi interface endpoint × số AZ đều tính tiền giờ → với nhiều VPC, dồn endpoint về **VPC dùng chung** (centralized endpoints qua TGW + Private Hosted Zone).

> 🎯 **Mẹo thi**: "Instance private ghi S3 **không qua Internet và rẻ nhất**" → **Gateway Endpoint**. "Từ on-prem truy cập S3 qua Direct Connect một cách private" → **S3 Interface Endpoint** (gateway endpoint không dùng được từ on-prem). "Đối tác truy cập một dịch vụ của bạn, CIDR trùng nhau" → **PrivateLink**.

---

## 4. Kết nối giữa các mạng

### 4.1 VPC Peering
- Nối 2 VPC (cùng/khác account, cùng/khác Region) qua hạ tầng AWS, traffic private.
- **CIDR không được chồng lấn.**
- **Không bắc cầu (non-transitive)**: A–B và B–C **không** có nghĩa A–C. Cũng không "mượn" IGW/NAT/VPN/DX của VPC kia (**no edge-to-edge routing**).
- Sau khi tạo phải: (1) chấp nhận yêu cầu ở phía kia, (2) **thêm route ở cả hai route table**, (3) mở SG (có thể tham chiếu SG của VPC peer cùng Region).
- Data cùng AZ qua peering miễn phí; khác AZ/khác Region tính phí data. Không có phí giờ.
- N VPC full mesh cần N(N−1)/2 peering → 10 VPC = 45 kết nối → chuyển sang **Transit Gateway**.

### 4.2 Transit Gateway (TGW)
- **Hub-and-spoke** ở mức Region: nối hàng nghìn VPC, VPN, Direct Connect (qua DX Gateway), **có bắc cầu**.
- **Route table riêng của TGW** để cô lập: vd. VPC dev không nói chuyện được với VPC prod nhưng cả hai đi được tới VPC shared-services.
- **ECMP** trên nhiều tunnel VPN → cộng gộp băng thông VPN (vượt 1,25 Gbps/tunnel).
- **Inter-Region peering** giữa các TGW; **multicast**; chia sẻ TGW cho account khác qua **RAM**.
- **Appliance mode**: giữ traffic đối xứng khi đi qua firewall stateful trong VPC inspection.
- Chi phí: phí giờ **mỗi attachment** + phí theo GB xử lý → đắt hơn peering cho lưu lượng lớn giữa 2 VPC.

> 💡 **Kinh nghiệm thực tế**: kiến trúc nhiều account phổ biến = **TGW trung tâm** + VPC "network/egress" chứa NAT dùng chung + VPC "inspection" chứa Network Firewall + VPC "shared services" chứa endpoint, AD, DNS resolver. Tiết kiệm NAT và endpoint, kiểm soát tập trung. Hai VPC nói chuyện cực nhiều với nhau thì vẫn có thể peering trực tiếp để tránh phí xử lý của TGW.

### 4.3 Site-to-Site VPN
- IPsec qua **Internet**, dựng trong vài phút/giờ. Mỗi kết nối gồm **2 tunnel** (2 endpoint AWS ở 2 AZ) – cấu hình **cả hai** tunnel phía on-prem để HA.
- Thành phần: **Virtual Private Gateway (VGW)** gắn vào VPC (hoặc **TGW**) + **Customer Gateway (CGW)** = đại diện thiết bị/IP phía on-prem.
- Routing **static** hoặc **BGP (dynamic, khuyên dùng)**. Bật **route propagation** trên route table VPC để route từ VGW tự vào.
- Băng thông ~**1,25 Gbps/tunnel**; muốn hơn → TGW + ECMP nhiều kết nối.
- **Accelerated VPN**: đi vào edge gần nhất qua Global Accelerator (chỉ với TGW).
- **AWS VPN CloudHub**: nhiều site on-prem nói chuyện với nhau qua VGW (hub-and-spoke).
- **Client VPN**: VPN cho **từng người dùng** (OpenVPN) vào VPC.

### 4.4 AWS Direct Connect (DX)
- Đường **vật lý riêng** từ data center/colocation tới **DX location** của AWS. Băng thông ổn định, độ trễ thấp và nhất quán, phí data ra **rẻ hơn** Internet.
- **Dedicated connection**: 1 / 10 / 100 Gbps (và 400 Gbps) – cổng riêng của bạn. **Hosted connection**: qua đối tác, từ 50 Mbps tới vài chục Gbps.
- Thời gian cung cấp: **nhiều tuần tới vài tháng** → không dùng cho nhu cầu "trong tuần này".
- **Virtual Interface (VIF)**:
  - **Private VIF** → VGW hoặc **Direct Connect Gateway** (vào VPC).
  - **Public VIF** → dịch vụ AWS public (S3, DynamoDB… qua endpoint public) không qua Internet.
  - **Transit VIF** → DX Gateway → **Transit Gateway**.
- **Mã hoá**: mặc định **không mã hoá** → chạy **IPsec VPN trên DX** (qua public VIF hoặc transit VIF) hoặc **MACsec** (mã hoá L2, trên cổng dedicated tốc độ cao).
- **Direct Connect Gateway**: 1 kết nối DX tới **nhiều VPC ở nhiều Region** (global).
- **Độ bền**:
  - *Development*: 1 kết nối.
  - *High resiliency*: 2 kết nối ở **2 DX location khác nhau**.
  - *Maximum resiliency*: 2 location × 2 kết nối mỗi location.
  - Tiết kiệm: **DX chính + Site-to-Site VPN dự phòng** (BGP ưu tiên DX).

| Cần | Chọn |
|---|---|
| Nhanh (giờ/ngày), rẻ, mã hoá sẵn, tạm thời hoặc dự phòng | **Site-to-Site VPN** |
| Băng thông lớn, ổn định, độ trễ nhất quán, khối lượng data lớn đều đặn | **Direct Connect** |
| DX + yêu cầu mã hoá | **DX + IPsec VPN** (hoặc MACsec) |
| Nối nhiều VPC + on-prem, quản lý tập trung, có bắc cầu | **Transit Gateway** |
| 2–vài VPC đơn giản | **VPC Peering** |
| Chỉ expose 1 dịch vụ, CIDR trùng, mô hình SaaS | **PrivateLink** |
| Chia sẻ subnet cho nhiều account trong Org | **VPC Sharing (RAM)** |
| Người dùng cá nhân truy cập VPC | **Client VPN** |

> 🎯 **Mẹo thi**: "cần kết nối on-prem **ngay trong tuần**, sau này chuyển sang DX" → VPN trước, DX sau. "DX duy nhất, cần HA với chi phí thấp" → thêm **VPN backup**. "DX cần mã hoá" → **IPsec VPN over DX**. "1 DX vào VPC ở 3 Region" → **Direct Connect Gateway**.

---

## 5. Giám sát & công cụ mạng

### 5.1 VPC Flow Logs
- Ghi **metadata** của traffic IP (srcaddr, dstaddr, srcport, dstport, protocol, packets, bytes, action **ACCEPT/REJECT**) ở mức VPC / subnet / ENI. **Không** chứa nội dung gói tin.
- Đích: CloudWatch Logs, S3 (rẻ, query bằng Athena), Kinesis Data Firehose.
- **Không** ghi: traffic tới Amazon DNS (.2) – dùng Route 53 Resolver query logs; metadata `169.254.169.254`; DHCP; time sync `169.254.169.123`; Windows license activation.
- Không ảnh hưởng hiệu năng mạng (thu thập ngoài đường truyền).

Đọc một bản ghi:
```
2 123456789012 eni-0a1b 10.0.1.25 10.0.20.10 49152 3306 6 10 840 1700000000 1700000060 REJECT OK
```
→ Từ `10.0.1.25:49152` tới `10.0.20.10:3306` (TCP=6) bị **REJECT** → SG của DB hoặc NACL đang chặn.

> 💡 **Kinh nghiệm thực tế**: REJECT ở chiều vào (inbound) mà không có REJECT chiều về → SG/NACL inbound. ACCEPT chiều vào nhưng REJECT chiều trả → **NACL** (stateless) chặn ephemeral ports – SG không bao giờ gây ra kiểu này vì stateful.

### 5.2 Công cụ khác
- **Reachability Analyzer**: phân tích **tĩnh** đường đi giữa hai điểm (ENI, instance, IGW…) → chỉ ra chính xác thành phần chặn (route, SG, NACL). Không gửi gói tin thật. Dùng cực tốt khi debug.
- **Network Access Analyzer**: tìm đường truy cập **không mong muốn** (vd. DB có đường ra Internet không?).
- **Traffic Mirroring**: sao chép **gói tin thật** từ ENI tới appliance IDS/phân tích.
- **Network Firewall** (stateful, IDS/IPS, lọc domain), **AWS WAF** (L7), **Shield** (DDoS) – chi tiết tuần 5.

---

## 6. Route 53

### 6.1 Cơ bản
- DNS managed, SLA **100%**, kiêm **đăng ký domain** và **health check**.
- **Public hosted zone**: phân giải trên Internet. **Private hosted zone**: chỉ trong các VPC được gắn (cần `enableDnsSupport` + `enableDnsHostnames`). Có thể cùng tên domain (**split-horizon DNS**: nội bộ trả IP private, bên ngoài trả IP public).
- Record hay dùng: `A` (IPv4), `AAAA` (IPv6), `CNAME` (tên → tên), `MX`, `TXT`, `NS`, `SOA`, `CAA`, `SRV`.
- **TTL**: thời gian resolver/client cache bản ghi. TTL cao → ít truy vấn, rẻ, nhưng đổi IP lâu có hiệu lực.

### 6.2 Alias vs CNAME

| | CNAME | **Alias** (riêng của Route 53) |
|---|---|---|
| Zone apex (`example.com`) | **Không được** | **Được** |
| Đích | Bất kỳ hostname | Tài nguyên AWS: ALB/NLB, CloudFront, API Gateway, S3 website, Elastic Beanstalk, VPC interface endpoint, Global Accelerator, record khác trong cùng zone |
| Phí truy vấn | Có | **Miễn phí** khi trỏ tới tài nguyên AWS |
| TTL | Tự đặt | Không đặt được (lấy theo tài nguyên đích) |
| Health check | — | "Evaluate target health" theo sức khoẻ đích |
| Trỏ tới DNS name của EC2 | Có | **Không** |

### 6.3 Routing policy

| Policy | Cách hoạt động | Health check | Dùng khi |
|---|---|---|---|
| **Simple** | Trả 1 hoặc nhiều giá trị, client tự chọn ngẫu nhiên | Không | 1 đích đơn giản |
| **Weighted** | Chia theo trọng số (vd. 90/10). Trọng số 0 = không nhận traffic | Có | Canary, blue/green, A/B, chuyển dần sang Region mới |
| **Latency** | Trả Region có **độ trễ đo được** thấp nhất tới người dùng | Có | Ứng dụng đa Region, tối ưu tốc độ |
| **Failover** | Primary/Secondary; primary unhealthy → trả secondary | **Bắt buộc** cho primary | Active–Passive DR (vd. secondary là trang tĩnh S3 "đang bảo trì") |
| **Geolocation** | Theo **vị trí** người dùng (lục địa, quốc gia, bang Mỹ); cần bản ghi **Default** cho nơi không khớp | Có | Tuân thủ/bản quyền nội dung theo nước, ngôn ngữ, giá theo vùng |
| **Geoproximity** | Theo **khoảng cách** địa lý + **bias** (−99…+99) để nới/thu vùng phục vụ | Có | Dồn thêm traffic sang một Region (vd. Region mới có nhiều dung lượng) |
| **Multivalue answer** | Trả **tối đa 8** bản ghi **khỏe** ngẫu nhiên | Có | "Load balancing phía client" đơn giản – **không thay được ELB** |
| **IP-based** | Theo dải CIDR của client/resolver | Có | Biết rõ dải IP của ISP/khách hàng, tối ưu chi phí/đường đi |

**Kết hợp nhiều tầng** (Traffic Flow hoặc record lồng record): ví dụ Latency giữa 2 Region, mỗi Region là Weighted giữa 2 phiên bản, mỗi phiên bản có Failover.

### 6.4 Health check
- Loại: **endpoint** (HTTP/HTTPS/TCP tới IP/domain), **calculated** (kết hợp nhiều health check bằng AND/OR/"ít nhất N"), **CloudWatch alarm**.
- Khoảng 15 health checker toàn cầu kiểm tra mỗi 30 giây (hoặc 10 giây – "fast", tốn thêm); endpoint được coi **healthy** nếu **> 18%** checker báo OK. Tuỳ chọn *string matching* trong 5.120 byte đầu của response.
- Health checker nằm **ngoài VPC** của bạn → không chạm được tài nguyên **private** → dùng **CloudWatch alarm** (metric của tài nguyên private) làm health check. Endpoint public phải cho phép dải IP của health checker trong SG/firewall.

### 6.5 Tính năng khác
- **DNSSEC** signing cho public hosted zone.
- **Route 53 Application Recovery Controller (ARC)**: *routing control* (công tắc on/off chuyển traffic giữa Region với data plane rất bền), *readiness check*, **zonal shift / zonal autoshift** (rút traffic khỏi một AZ bị suy giảm cho ALB/NLB).
- **Resolver endpoints / DNS Firewall / query logging** (mục 1.6).

> 💡 **Kinh nghiệm thực tế – đổi DNS mà không ai bị ảnh hưởng**
> 1. Vài ngày trước khi chuyển (migration, đổi IP), **hạ TTL** xuống 60 giây và **chờ hết TTL cũ** (vd. TTL cũ là 86400 thì chờ ít nhất 1 ngày).
> 2. Chuyển bản ghi, theo dõi; chạy ổn rồi mới tăng TTL lại.
> 3. Chuyển dần bằng **Weighted** (1% → 10% → 50% → 100%) để rollback dễ.
> - Một số client/JVM cache DNS lâu hơn TTL → đây là lý do đề gợi ý **Global Accelerator** cho failover "không phụ thuộc DNS cache".
> - Mua domain ở nơi khác vẫn dùng Route 53 được: tạo hosted zone, rồi đổi **NS record ở nhà đăng ký** sang 4 name server Route 53 cấp.

---

## 7. Accelerate truy cập toàn cầu (chi tiết tuần 6)
- **CloudFront**: CDN cache nội dung HTTP/S ở edge.
- **Global Accelerator**: 2 IP **anycast tĩnh**, đưa traffic vào backbone AWS ở edge gần nhất, hợp TCP/UDP, failover giữa Region trong vài chục giây theo health check (không cache).

---

## 8. Bẫy thường gặp
1. "Instance ở private subnet cần cài bản vá từ Internet" → **NAT Gateway** trong **public** subnet + route `0.0.0.0/0 → NAT` trong route table private.
2. "NAT Gateway HA" → **một cái mỗi AZ**, route table mỗi AZ trỏ NAT cùng AZ.
3. Peering **không bắc cầu**, không edge-to-edge; CIDR trùng → không peering được (cân nhắc PrivateLink hoặc Private NAT).
4. "Truy cập S3 từ VPC không qua Internet, miễn phí" → **Gateway endpoint**. "Từ on-prem" → **Interface endpoint**.
5. "Chặn IP độc hại" → **NACL deny** (hoặc WAF với ALB/CloudFront).
6. NACL stateless: quên mở **ephemeral ports** cho chiều trả → timeout.
7. "On-prem ↔ AWS, riêng tư, băng thông cao, ổn định" → DX; "nhanh trong vài ngày, mã hoá" → VPN; "DX + mã hoá" → VPN over DX.
8. "Zone apex trỏ vào ALB/CloudFront" → **Alias**, không phải CNAME.
9. Số IP khả dụng subnet = tổng − **5**.
10. "Nhiều VPC (hàng chục) + on-prem cần nói chuyện với nhau" → **Transit Gateway** (không phải mesh peering).
11. "Private hosted zone không phân giải được" → kiểm tra `enableDnsHostnames`/`enableDnsSupport` và zone đã **associate** với VPC chưa.
12. "Health check Route 53 cho tài nguyên private" → **CloudWatch alarm-based health check**.
13. "Nội dung chỉ được phân phối ở một số quốc gia (bản quyền)" → **Geolocation** (Route 53) hoặc **CloudFront geo restriction**.
14. "Phân tích vì sao instance A không kết nối được B mà không cần gửi traffic" → **Reachability Analyzer**; "xem traffic bị từ chối" → **Flow Logs**.
15. "Lambda trong VPC không gọi được API Internet" → Lambda trong VPC **không có public IP** kể cả ở public subnet → đặt ở private subnet + NAT.

---

## 9. Tự kiểm tra

1. VPC `10.0.0.0/16`, subnet `/24`: mỗi subnet có bao nhiêu IP dùng được? Subnet `/28`?
2. Phân biệt public vs private subnet về mặt kỹ thuật.
3. Vì sao 3 VPC peering A–B và B–C vẫn không cho A nói chuyện với C? Giải pháp?
4. Rule NACL số 100 deny `203.0.113.5/32`, rule số 200 allow `0.0.0.0/0`. Packet từ IP đó bị gì? Nếu đảo số thứ tự thì sao?
5. NAT Gateway nằm ở public hay private subnet? Có HA tự động qua nhiều AZ không?
6. Gateway endpoint hỗ trợ dịch vụ nào? Dùng được từ on-prem qua VPN không?
7. Direct Connect có mã hoá mặc định không? Cách bổ sung?
8. Khi nào dùng Geolocation, khi nào Latency routing?
9. Web server trong subnet có NACL tuỳ chỉnh: inbound cho 443, outbound cho 443. Người dùng truy cập bị timeout. Vì sao?
10. Bạn cần chia 20% traffic sang phiên bản mới ở mức DNS. Policy nào?
11. Một công ty SaaS muốn 200 khách hàng (nhiều người dùng trùng `10.0.0.0/16`) gọi API private của họ. Giải pháp?
12. Vì sao không thể tạo CNAME cho `example.com`? Thay bằng gì?
13. Trong Flow Logs thấy inbound ACCEPT nhưng outbound REJECT cho cùng kết nối. Thủ phạm?
14. Kết nối DX duy nhất của công ty bị đứt. Thiết kế HA rẻ nhất?

<details><summary>Đáp án</summary>

1. 256 − 5 = 251. `/28`: 16 − 5 = 11.
2. Public: route table có `0.0.0.0/0 → IGW` (và instance có public IP). Private: không có route đó (có thể ra qua NAT).
3. Peering không bắc cầu; dùng Transit Gateway hoặc peering A–C trực tiếp.
4. Bị chặn (rule 100 khớp trước, dừng). Đảo lại (allow ở số nhỏ hơn) → được phép vì allow khớp trước.
5. Public subnet; không – nằm trong 1 AZ, cần mỗi AZ một NAT và route theo AZ.
6. S3 và DynamoDB. Không – gateway endpoint không dùng được qua VPN/DX/peering; dùng interface endpoint.
7. Không; chạy IPsec VPN trên Direct Connect (hoặc MACsec cho cổng dedicated hỗ trợ).
8. Geolocation: theo vị trí để tuân thủ/ngôn ngữ/giới hạn khu vực. Latency: để người dùng tới Region nhanh nhất.
9. NACL stateless: response về client đi ra từ port 443 tới **ephemeral port** của client → cần outbound allow 1024–65535.
10. **Weighted** (80/20).
11. **PrivateLink**: đặt API sau NLB, tạo Endpoint Service; mỗi khách hàng tạo interface endpoint – CIDR trùng không sao.
12. Chuẩn DNS không cho CNAME ở zone apex (xung đột với SOA/NS). Dùng **Alias record** (nếu đích là tài nguyên AWS).
13. **NACL** chặn chiều về (ephemeral ports); SG stateful không gây ra kiểu này.
14. Thêm **Site-to-Site VPN** làm đường dự phòng (BGP ưu tiên DX); HA cao hơn thì thêm DX thứ hai ở location khác.
</details>

## Tài liệu nên đọc thêm
- Doc: "How Amazon VPC works", "Subnet CIDR blocks", "Gateway endpoints", "Compare security groups and network ACLs", "Choosing a routing policy" (Route 53).
- Whitepaper: "Building a Scalable and Secure Multi-VPC AWS Network Infrastructure", "Amazon Virtual Private Cloud Connectivity Options", "AWS Direct Connect – Resiliency Recommendations".
- FAQ: VPC, Direct Connect, Transit Gateway, Route 53.
