# Lab 02 – Tự dựng VPC 2 tầng, 2 AZ + S3 Gateway Endpoint

**Thời gian:** ~45–60 phút (+~60 phút phần nâng cao) | **Chi phí:** ≈ 0 (VPC/subnet/IGW/Gateway endpoint/VPC peering cùng Region miễn phí; Flow Logs chỉ tốn lưu trữ rất nhỏ). **Không tạo NAT Gateway** trong lab này.
**Liên quan lý thuyết:** `theory/week2-networking.md`

## Mục tiêu
Tự thiết kế và dựng VPC có public + private subnet ở 2 AZ, route table đúng, và cho private subnet truy cập S3 **không qua Internet** bằng Gateway Endpoint. Bật Flow Logs (bonus).

## Quy ước tên (BẮT BUỘC)
| Tài nguyên | Tên (tag `Name`) | Cấu hình |
|---|---|---|
| VPC | `saa-lab02-vpc` | CIDR **10.20.0.0/16** |
| Subnet public A | `saa-lab02-public-a` | `10.20.0.0/24`, AZ thứ nhất |
| Subnet public B | `saa-lab02-public-b` | `10.20.1.0/24`, AZ thứ hai |
| Subnet private A | `saa-lab02-private-a` | `10.20.10.0/24`, cùng AZ với public-a |
| Subnet private B | `saa-lab02-private-b` | `10.20.11.0/24`, cùng AZ với public-b |
| Internet Gateway | `saa-lab02-igw` | gắn vào VPC |
| Route table public | `saa-lab02-public-rt` | `0.0.0.0/0 → IGW`, gắn 2 public subnet |
| Route table private | `saa-lab02-private-rt` | **không** có route `0.0.0.0/0`, gắn 2 private subnet |
| S3 Gateway Endpoint | `saa-lab02-s3-endpoint` | gắn vào `saa-lab02-private-rt` |

Gắn tag `Project=saa-lab` nếu muốn.

## Các bước
1. **VPC**: VPC Console → *Create VPC → VPC only*, CIDR `10.20.0.0/16`, tên `saa-lab02-vpc`.
2. **Subnets** theo bảng. Với *public* subnets: bật **Auto-assign public IPv4 address** (Modify subnet settings). Private subnets: **không** bật.
3. **IGW**: tạo `saa-lab02-igw` → *Attach to VPC*.
4. **Route tables**:
   - `saa-lab02-public-rt`: thêm route `0.0.0.0/0 → saa-lab02-igw`; *Subnet associations* → 2 public subnet.
   - `saa-lab02-private-rt`: giữ route `local`; association → 2 private subnet.
5. **Gateway Endpoint**: Endpoints → Create endpoint → tên `saa-lab02-s3-endpoint`, service `com.amazonaws.<region>.s3` loại **Gateway**, VPC `saa-lab02-vpc`, chọn route table **`saa-lab02-private-rt`**.
6. **(Bonus ở phần cơ bản; bắt buộc ở phần nâng cao N4) Flow Logs**: VPC → *Flow logs → Create* cho `saa-lab02-vpc`, filter *All*, đích **CloudWatch Logs** (hoặc S3). Verify cơ bản chỉ cảnh báo (WARN) nếu thiếu.

## Suy ngẫm / thử tay (không bắt buộc)
- Quan sát route table private sau khi tạo endpoint: thấy một dòng đích là **prefix list** (`pl-xxxx`) → target `vpce-…`. Đây là cách Gateway Endpoint hoạt động.
- Nếu cần private subnet ra Internet (cập nhật gói) thì cần gì? (NAT Gateway ở **public** subnet + route `0.0.0.0/0 → nat-…` trong private-rt; ~0,05 USD/giờ + data → **đừng bật nếu không cần**, hoặc tạo rồi xoá ngay.)
- Vẽ lại sơ đồ bằng tay và ghi lên các route table.

## Câu hỏi
1. Mỗi subnet /24 có bao nhiêu IP dùng được? Vì sao?
2. Vì sao hai route table khác nhau? Điều gì khiến subnet "public"?
3. Gateway Endpoint khác Interface Endpoint thế nào? Vì sao ở đây dùng Gateway?
4. Muốn chặn một IP cụ thể vào public subnet → dùng NACL hay SG?
5. Nếu thêm VPC thứ hai `10.20.0.0/16`, có peering được không?

## PHẦN NÂNG CAO (chấm bằng `bash verify.sh --advanced`)

Bốn kỹ năng mạng hay ra đề nhất: **NACL**, **endpoint policy + bucket policy theo VPC endpoint**, **VPC peering**, **Flow Logs**. Tất cả miễn phí/gần miễn phí.

| Tài nguyên | Tên / cấu hình (BẮT BUỘC) |
|---|---|
| NACL | tag Name **`saa-lab02-public-nacl`**, gắn vào **2 public subnet** |
| Bucket private | **`saa-lab02-<ACCOUNT_ID>-private`** |
| VPC thứ hai | **`saa-lab02-vpc-b`**, CIDR **10.30.0.0/16**, 1 subnet `saa-lab02-b-subnet` `10.30.0.0/24` |
| Peering | tag Name **`saa-lab02-peering`** (VPC A ↔ VPC B), đã **Accept** |
| Bucket Flow Logs (nếu chọn S3) | `saa-lab02-<ACCOUNT_ID>-flowlogs` |

### N1. Network ACL cho public subnet
Tạo NACL `saa-lab02-public-nacl` trong `saa-lab02-vpc`, **Subnet associations** → 2 public subnet (private giữ NACL mặc định).

| Chiều | Rule # | Loại | Cổng | Nguồn/Đích | Hành động |
|---|---|---|---|---|---|
| Inbound | **90** | All | All | `203.0.113.0/24` (dải tài liệu, dùng giả lập kẻ tấn công) | **DENY** |
| Inbound | 100 | TCP | 80 | 0.0.0.0/0 | ALLOW |
| Inbound | 110 | TCP | 443 | 0.0.0.0/0 | ALLOW |
| Inbound | 120 | TCP | **1024–65535** | 0.0.0.0/0 | ALLOW (traffic trả về) |
| Outbound | 100 | All | All | 0.0.0.0/0 | ALLOW |

Tự kiểm tra hiểu bài (đây chính là cái bẫy NACL vs SG):
- Đổi rule 90 thành **200** thì điều gì xảy ra với IP `203.0.113.5`? (NACL xét **từ số nhỏ đến lớn**, gặp rule khớp đầu tiên là dừng → IP đó lọt qua rule 100.)
- Bỏ rule 120 thì web server vẫn nhận request nhưng client không nhận được trả lời? (NACL **stateless**: cần mở cổng tạm ở chiều tương ứng; SG thì **stateful** nên tự cho phép traffic trả về.)
- Bỏ outbound ALLOW thì sao? (Mọi response bị chặn.)

### N2. Bucket chỉ truy cập qua VPC endpoint
1. Sửa **endpoint policy** của `saa-lab02-s3-endpoint` (không để *Full access*):
```json
{ "Statement": [{ "Effect": "Allow", "Principal": "*",
  "Action": ["s3:GetObject", "s3:ListBucket"],
  "Resource": ["arn:aws:s3:::saa-lab02-*", "arn:aws:s3:::saa-lab02-*/*"] }] }
```
2. Tạo bucket `saa-lab02-<ACCOUNT_ID>-private` (Block Public Access ON). **Upload một file thử trước**, rồi gắn bucket policy:
```json
{ "Version": "2012-10-17", "Statement": [{
  "Sid": "OnlyFromVpce", "Effect": "Deny", "Principal": "*",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
  "Resource": ["arn:aws:s3:::<BUCKET>", "arn:aws:s3:::<BUCKET>/*"],
  "Condition": { "StringNotEquals": { "aws:SourceVpce": "<vpce-id của saa-lab02-s3-endpoint>" } } }] }
```
3. Từ máy của bạn: `aws s3 ls s3://<BUCKET>` → **AccessDenied**, kể cả khi bạn là admin (explicit Deny thắng mọi Allow).

> **Đừng dùng `"Action": "s3:*"` trong Deny này** – bạn sẽ tự khoá không sửa/xoá được policy (chỉ root mới gỡ được). Vì vậy policy trên chỉ chặn các action dữ liệu.
> Hỏi: nếu muốn cho phép thêm một EC2 trong VPC *khác*? (thêm `aws:SourceVpc`/endpoint khác vào điều kiện.) Khác nhau giữa `aws:SourceVpc` và `aws:SourceVpce`? (VPC vs endpoint cụ thể; `SourceVpc` chỉ có tác dụng khi request đi qua VPC endpoint.)

### N3. VPC Peering
1. Tạo VPC `saa-lab02-vpc-b` `10.30.0.0/16` + subnet `saa-lab02-b-subnet` `10.30.0.0/24`.
2. **Peering connection** `saa-lab02-peering`: requester = VPC A, accepter = VPC B (cùng account/Region) → **Accept request**.
3. **Route ở cả hai phía** (peering không tự thêm route!):
   - Route table `saa-lab02-private-rt` (VPC A): `10.30.0.0/16 → pcx-…`
   - Route table của VPC B (route table chính hoặc tạo riêng và gắn subnet): `10.20.0.0/16 → pcx-…`

Câu hỏi tư duy:
- Thử tạo VPC thứ ba có CIDR `10.20.0.0/16` rồi peering với VPC A → lỗi vì sao? (CIDR chồng nhau.)
- A ↔ B và B ↔ C đã peering; A có nói chuyện được với C không? (**Không** – peering không bắc cầu. Giải pháp khi có nhiều VPC: **Transit Gateway**.)
- Khi cần nối 20 VPC: peering full-mesh cần bao nhiêu kết nối? (n(n−1)/2 = 190 → dùng TGW.)
- Peering cùng Region qua AZ khác nhau có tính phí transfer không? (Có tính phí data giữa AZ; trong cùng AZ qua private IP thì không.)

### N4. VPC Flow Logs
Tạo Flow Logs cho `saa-lab02-vpc`: **filter = All** (hoặc Reject), đích **S3** `saa-lab02-<ACCOUNT_ID>-flowlogs` hoặc **CloudWatch Logs**.
Hỏi: Flow Logs cho biết *gì* và *không* cho biết gì? (metadata kết nối: nguồn, đích, cổng, ACCEPT/REJECT – **không** có nội dung gói; khác **Traffic Mirroring**.) Muốn biết SG hay NACL đã chặn thì xem gì? (cả hai đều ra `REJECT`; kết hợp quy tắc để suy ra – NACL stateless nên thấy REJECT cả chiều trả về.)

### Câu hỏi nâng cao
6. Một EC2 ở private subnet cần gọi DynamoDB mà không qua Internet và không tốn NAT: dùng gì? (Gateway endpoint cho DynamoDB – miễn phí.) Còn gọi SQS/SNS/Secrets Manager? (**Interface endpoint** – PrivateLink, tính phí theo giờ + GB.)
7. Endpoint Gateway có truy cập được từ on-premises qua VPN/Direct Connect không? (Không. Dùng Interface endpoint hoặc proxy.)
8. Muốn log tách riêng chiều bị REJECT của một subnet duy nhất? (Flow Logs có thể tạo ở mức **subnet** hoặc **ENI**, và chọn filter REJECT.)

## Verify & Cleanup
```bash
bash verify.sh               # phần cơ bản
bash verify.sh --advanced    # thêm N1–N4
bash cleanup.sh              # xoá cả VPC B, peering, bucket phần nâng cao
```
