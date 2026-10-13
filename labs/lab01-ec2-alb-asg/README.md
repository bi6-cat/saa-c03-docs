# Lab 01 – Web app chịu lỗi: IAM Role + ALB + Auto Scaling (2 AZ)

**Thời gian:** ~60–90 phút (+~90–120 phút phần nâng cao, +~15 phút game day) | **Chi phí ước tính:** thấp (2× t3.micro + 1 ALB; phần nâng cao thêm Lambda và Spot, gần như 0) – **nhớ chạy `cleanup.sh` trong ngày**
**Liên quan lý thuyết:** `theory/week1-iam-ec2-elb-asg.md`

## Mục tiêu
Dựng kiến trúc: `Internet → ALB (2 AZ) → ASG (≥2 EC2, chỉ nhận traffic từ ALB)`, instance dùng IAM Role (không access key), kiểm chứng ASG tự chữa lành.

## Quy ước tên (BẮT BUỘC – verify.sh tìm theo tên)
| Tài nguyên | Tên |
|---|---|
| IAM role (cho EC2) | `saa-lab01-ec2-role` |
| Security group của ALB | `saa-lab01-alb-sg` |
| Security group của web | `saa-lab01-web-sg` |
| Launch template | `saa-lab01-lt` |
| Target group | `saa-lab01-tg` |
| Application Load Balancer | `saa-lab01-alb` |
| Auto Scaling group | `saa-lab01-asg` |

Dùng **default VPC** của region là đủ cho lab này (Lab 02 mới tự dựng VPC). Gắn tag `Project=saa-lab` cho mọi thứ nếu có thể.

---

## Bước 1 – IAM Role cho EC2
1. IAM → Roles → Create role → *AWS service* → **EC2**.
2. Gắn policy **`AmazonS3ReadOnlyAccess`** (chỉ để luyện; trong thực tế cấp quyền hẹp hơn).
3. Tên role: `saa-lab01-ec2-role`. (Console tự tạo *instance profile* cùng tên.)

> Câu hỏi: tại sao không dùng access key trong user data?

## Bước 2 – Security Groups (VPC = default VPC)
1. `saa-lab01-alb-sg`: inbound **HTTP 80** từ `0.0.0.0/0`.
2. `saa-lab01-web-sg`: inbound **HTTP 80** với *Source = security group `saa-lab01-alb-sg`* (không phải CIDR!). **Không mở SSH** ra `0.0.0.0/0`.

## Bước 3 – Launch Template `saa-lab01-lt`
- AMI: **Amazon Linux 2023**; Instance type: `t3.micro` (hoặc loại thuộc Free Tier của tài khoản bạn).
- Security group: `saa-lab01-web-sg`.
- Advanced details → **IAM instance profile**: `saa-lab01-ec2-role`.
- Advanced details → **Metadata version: V2 only (token required)** (IMDSv2).
- **User data**:
```bash
#!/bin/bash
dnf install -y httpd
systemctl enable --now httpd
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
echo "<h1>saa-lab01 | $IID | $AZ</h1>" > /var/www/html/index.html
```

## Bước 4 – Target Group & ALB
1. Target group `saa-lab01-tg`: kiểu **Instances**, HTTP:80, health check path `/`.
   (Không đăng ký target thủ công – ASG sẽ làm.)
2. ALB `saa-lab01-alb`: **Internet-facing**, IPv4, chọn **ít nhất 2 AZ (2 subnet)**, SG `saa-lab01-alb-sg`, listener **HTTP:80 → forward `saa-lab01-tg`**.

## Bước 5 – Auto Scaling Group `saa-lab01-asg`
- Launch template: `saa-lab01-lt`; chọn **ít nhất 2 subnet khác AZ** (default VPC).
- Gắn load balancer: **Attach to an existing load balancer → target group `saa-lab01-tg`**.
- Health checks: bật **ELB** health check.
- Group size: **min 2, desired 2, max 4**.
- Scaling policy: **Target tracking – Average CPU = 50%** (hoặc ALB request count per target).

## Bước 6 – Thử nghiệm bằng tay
1. Đợi target trong TG chuyển **healthy** (vài phút), mở `http://<DNS của ALB>` và F5 nhiều lần: thấy `instance-id`/AZ đổi luân phiên.
2. **Thử phá**: EC2 Console → terminate 1 instance. Quan sát ASG Activity: nó tạo instance mới để về lại `desired=2`.
3. Thử truy cập thẳng public IP của một instance (nếu có) trên cổng 80 → **không vào được** (SG chỉ cho ALB).


## Câu hỏi suy ngẫm
1. Nếu 1 AZ mất hoàn toàn, hệ thống còn phục vụ được không? Vì sao?
2. Vì sao web SG tham chiếu SG của ALB thay vì CIDR?
3. Nếu muốn app truy cập Internet từ private subnet thì cần thêm gì? (xem Lab 02)
4. Nếu đổi ALB sang NLB thì thay đổi gì ở SG và health check?

---

## PHẦN NÂNG CAO (chấm bằng `bash verify.sh --advanced`)

Làm sau khi phần cơ bản đã PASS hoàn toàn. Mục tiêu: biến bài "dựng được" thành bài **vận hành được** – truy cập không SSH, tối ưu chi phí bằng Spot, triển khai bản mới không downtime, routing L7, scaling theo lịch và theo tải. Đây đều là các mẫu hay ra trong đề SAA.

**Thời gian thêm:** ~90–120 phút. **Chi phí thêm:** rất nhỏ (Lambda và SSM miễn phí ở mức này; Spot rẻ hơn On-Demand; instance refresh và scheduled scaling chạy thêm 1 instance trong thời gian ngắn).

> ⚠️ **Làm đúng thứ tự N1 → N6.** Thứ tự có chủ ý: N3 (instance refresh) thay toàn bộ instance để áp dụng thay đổi của N1–N2 cùng lúc; N4 đổi health check sang `/health` – nếu làm **trước** khi bản v2 (có `/health`) chạy xong, mọi target sẽ unhealthy và ALB trả lỗi 5xx cho toàn bộ người dùng. Đây chính là một sự cố thật hay gặp khi deploy.

| Tài nguyên | Tên (BẮT BUỘC) |
|---|---|
| Lambda function | `saa-lab01-api` (Python 3.12+, code trong [`api_function.py`](api_function.py)) |
| Target group cho Lambda | `saa-lab01-api-tg` (target type **Lambda function**) |
| Scheduled action giờ làm việc | `saa-lab01-business-hours` |
| Scheduled action ngoài giờ | `saa-lab01-after-hours` |

### N1. Session Manager thay cho SSH (không key pair, không mở port)
1. Role `saa-lab01-ec2-role` → gắn thêm managed policy **`AmazonSSMManagedInstanceCore`**.
2. Launch template **không dùng key pair** (làm ở bản v2 – mục N3).
3. Sau N3, vào **EC2 → chọn instance → Connect → Session Manager**, hoặc CLI (cần cài *session-manager-plugin*):
   ```bash
   aws ssm start-session --target <instance-id>
   ```
   Trong phiên, thử:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://169.254.169.254/latest/meta-data/   # 401: IMDSv2 bắt buộc token
   curl -s localhost/health                                                          # ok
   ```

Hỏi: Session Manager cần những gì để hoạt động khi instance ở **private subnet không có NAT**? (Interface endpoint `ssm`, `ssmmessages`, `ec2messages`.) Vì sao nó tốt hơn bastion về audit? (Phiên được log vào CloudTrail, có thể ghi toàn bộ nội dung phiên vào S3/CloudWatch Logs; quyền kiểm soát bằng IAM thay vì SSH key.)

### N2. Mixed instances: On-Demand nền + Spot (tối ưu chi phí)
ASG `saa-lab01-asg` → **Edit → Instance type requirements → Override launch template**:
- Chọn **ít nhất 2 loại instance**, ví dụ `t3.micro`, `t3a.micro` (thêm `t2.micro` nếu muốn).
- **Instance purchase options**: On-Demand **base capacity = 1**, phần vượt base **0% On-Demand / 100% Spot**.
- **Allocation strategy (Spot)**: **price-capacity-optimized**.
- Bật **Capacity rebalancing**.

Thay đổi này **không tự thay instance đang chạy** – instance refresh ở N3 sẽ làm việc đó.

Hỏi: vì sao cần ≥ 2 loại instance? (Mỗi loại × AZ là một *Spot pool* riêng; nhiều pool → ít bị thu hồi đồng loạt.) Vì sao giữ On-Demand base = 1? (Luôn còn ít nhất 1 instance không bị thu hồi.) Spot bị thu hồi thì có bao nhiêu thời gian cảnh báo? (2 phút; *rebalance recommendation* có thể báo sớm hơn – đó là việc của Capacity rebalancing.)

### N3. Launch template v2 + Instance refresh (triển khai không downtime)
1. Launch template `saa-lab01-lt` → **Actions → Modify template (Create new version)**:
   - **Key pair: Don't include in launch template** (N1).
   - **Storage**: root volume loại **gp3**, **Encrypted = Yes** (key mặc định `aws/ebs` là đủ). Kích thước để trống hoặc ≥ kích thước snapshot của AMI.
     *Cách khác:* bật **EC2 → Settings → EBS encryption by default** cho Region (verify chấp nhận cả hai; lưu ý cài đặt này áp dụng cho cả account và `cleanup.sh` không tắt lại).
   - **Metadata version: V2 only** (ở phần nâng cao, verify bắt buộc thay vì chỉ cảnh báo).
   - **User data** (bản v2 – thêm `/health` và loại instance Spot/On-Demand):
   ```bash
   #!/bin/bash
   dnf install -y httpd
   TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
   md() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
   echo "<h1>saa-lab01 v2 | $(md instance-id) | $(md placement/availability-zone) | $(md instance-life-cycle)</h1>" > /var/www/html/index.html
   echo ok > /var/www/html/health
   systemctl enable --now httpd
   ```
2. **Set default version** = version vừa tạo. Trong ASG, *Launch template version* để **Default** (hoặc **Latest**).
   > Thực tế nên dùng **Default**: bạn chủ động quyết định khi nào bản mới được dùng, thay vì mọi version mới tạo đều lập tức có hiệu lực như **Latest**.
3. ASG → **Instance refresh → Start instance refresh**:
   - Instance replacement method: **Launch before terminating** (min healthy 100%, max healthy 200%) – tạo instance mới trước, healthy rồi mới tắt instance cũ.
   - Instance warmup: 60–120 giây. Có thể bật **Auto rollback** nếu instance mới không healthy.
4. Theo dõi tab *Instance refresh* tới khi **Successful**, rồi F5 trang ALB: mọi response đều là `v2`, có response hiển thị `spot`.

Hỏi: vì sao không SSH vào từng instance để sửa? (Instance mới do ASG tạo sẽ lại là bản cũ; nguồn sự thật phải là launch template/AMI.) Khác biệt giữa *min healthy 50%* và *launch before terminating*? (50%: thay từng nửa, có lúc chỉ còn một nửa năng lực; launch-before-terminating: không giảm năng lực nhưng tạm thời chạy nhiều instance hơn, tốn hơn chút.) Khi nào nên dùng **blue/green** với hai target group thay vì instance refresh? (Cần chuyển đổi/rollback tức thì, hoặc test bản mới trước khi nhận traffic thật.)

### N4. Health check và draining cho target group
**Chỉ làm khi N3 đã Successful** (đã có `/health` trên mọi instance).

Target group `saa-lab01-tg`:
- **Health checks → Edit**: path **`/health`**, interval **10 giây**, healthy threshold **2**, unhealthy threshold **2**.
- **Attributes → Edit**: **Deregistration delay = 30 giây** (mặc định 300).

Hỏi: vì sao `/health` nên nhẹ và **không** gọi xuống database? (DB chậm → mọi target cùng unhealthy → toàn bộ hệ thống sập theo, tức cascading failure.) Deregistration delay quá dài hay quá ngắn có hại gì? (Dài: deploy/scale-in chậm. Ngắn hơn thời gian xử lý request: request đang chạy bị cắt.) **Health check grace period** của ASG dùng để làm gì? (Không đánh giá health trong lúc instance còn đang boot/cài đặt, tránh vòng lặp tạo rồi xoá instance.)

### N5. Routing theo path: Lambda target + fixed response
1. Tạo Lambda **`saa-lab01-api`**, Python 3.12+, để Console tạo role mặc định, dán code [`api_function.py`](api_function.py), **Deploy**.
2. Target group **`saa-lab01-api-tg`**, target type **Lambda function**, đăng ký function `saa-lab01-api`. (Console tự thêm **resource-based policy** cho Lambda cho phép `elasticloadbalancing.amazonaws.com` gọi – verify kiểm tra điều này.)
3. ALB `saa-lab01-alb` → listener **HTTP:80 → Manage rules → Add rule**:

| Priority | Điều kiện | Hành động |
|---|---|---|
| 10 | Path = **`/api/*`** | Forward → `saa-lab01-api-tg` |
| 20 | Path = **`/admin*`** | **Return fixed response**: **403**, `text/plain`, nội dung `Forbidden by ALB` |
| Default | (còn lại) | Forward → `saa-lab01-tg` |

4. Thử:
```bash
ALB=<DNS của ALB>
curl -s http://$ALB/api/orders?id=1     # JSON từ Lambda: "source": "lambda"
curl -i http://$ALB/admin                # 403 do chính ALB trả, không tới instance nào
curl -s http://$ALB/                     # vẫn là trang v2 từ EC2
```
Hỏi: NLB có làm được routing theo path không? (Không – NLB là L4.) Muốn chặn `/admin` theo IP hoặc chống SQL injection thì dùng gì? (Rule điều kiện *source IP* trên ALB, hoặc **AWS WAF** gắn vào ALB.) Muốn có xác thực người dùng trước khi vào `/api/*` mà không sửa code? (Action **authenticate-cognito/oidc** của ALB.)

### N6. Scaling theo lịch và theo số request
1. ASG → **Automatic scaling → Scheduled actions → Create** (chọn time zone **Asia/Ho_Chi_Minh**):

| Tên | Recurrence | Min | Max | Desired |
|---|---|---|---|---|
| `saa-lab01-business-hours` | `0 8 * * MON-FRI` | 2 | 4 | **3** |
| `saa-lab01-after-hours` | `0 20 * * MON-FRI` | 2 | 4 | **2** |

   > Nếu để lab chạy qua 8h sáng ngày làm việc, ASG sẽ chạy 3 instance – một lý do nữa để `cleanup.sh` ngay trong ngày.
2. Thêm **dynamic scaling policy** thứ hai: **Target tracking**, metric **Application Load Balancer request count per target**, target group `saa-lab01-tg`, giá trị **100**.
3. (Tuỳ chọn, thử tải thật) Bắn request và xem ASG scale-out trong *Activity*:
```bash
for i in $(seq 1 20000); do curl -s -o /dev/null http://$ALB/ & [ $((i % 50)) -eq 0 ] && wait; done
```

Hỏi: có hai target tracking policy (CPU 50% và request 100/target) thì ASG scale-out/scale-in thế nào? (Scale-out khi **bất kỳ** policy nào yêu cầu; scale-in chỉ khi **tất cả** đồng ý – ưu tiên an toàn.) Tải tăng đúng giờ mỗi ngày nhưng app khởi động mất 10 phút: chọn gì? (**Scheduled** hoặc **Predictive scaling**, kết hợp **warm pool**.) Khi nào cần **step scaling** thay vì target tracking? (Cần phản ứng khác nhau theo mức vượt ngưỡng, hoặc metric không tỉ lệ với số instance.)

---

## GAME DAY (chạy bằng `bash verify.sh --chaos`)

> ⚠️ Chế độ này **cố ý làm hỏng** hệ thống của bạn (dừng web server trên một instance, terminate một instance khác) rồi đo xem kiến trúc tự phục hồi thế nào. Mất ~10–15 phút. Cần đã làm **N1** (dùng SSM Run Command) và nên làm xong **N4** (health check nhanh, draining 30 giây) để kết quả có ý nghĩa.

| Kịch bản | Script làm gì | Kỳ vọng | Bài học |
|---|---|---|---|
| **C1. App chết, máy vẫn sống** | Dùng **SSM Run Command** chạy `systemctl stop httpd` trên 1 instance | ALB đánh dấu target unhealthy, **ASG tự thay instance** | Instance vẫn "running" nên EC2 status check vẫn OK. Chỉ khi ASG dùng **ELB health check** thì nó mới biết app đã chết. Một ít lỗi 5xx trong khoảng `interval × unhealthy threshold` là bình thường. |
| **C2. Scale-in / thay máy có kế hoạch** | Terminate 1 instance qua API của ASG (giữ nguyên desired) | **0 request lỗi**, ASG tạo instance thay thế | ASG rút instance khỏi target group và chờ **deregistration delay** trước khi tắt, nên request đang chạy không bị cắt. |

Thử so sánh: đặt tạm *Health check type* của ASG về **EC2** rồi chạy lại C1 → instance chết app **không bao giờ** được thay, ALB chỉ còn 1 target healthy. Nhớ đặt lại **ELB** sau khi thử.

---

## Câu hỏi tình huống (dạng đề thi)

<details><summary>1. Web app chạy trong ASG sau ALB. Người dùng bị đăng xuất ngẫu nhiên mỗi khi ASG scale-in. Cách khắc phục <b>bền vững</b> nhất?</summary>

Đưa session ra ngoài instance: **ElastiCache (Redis)** hoặc **DynamoDB**. Sticky session chỉ là chữa cháy – instance bị terminate thì session vẫn mất, và tải phân bố lệch.
</details>

<details><summary>2. Batch xử lý ảnh chạy 6 giờ mỗi đêm, chịu được gián đoạn, cần rẻ nhất. Thiết kế compute?</summary>

ASG/EC2 Fleet dùng **Spot** với **nhiều loại instance**, chiến lược **price-capacity-optimized**, công việc lấy từ **SQS** (bị thu hồi thì message tự hiện lại cho worker khác). Không dùng Reserved/Savings Plans vì chỉ chạy vài giờ.
</details>

<details><summary>3. Đối tác cần whitelist <b>IP tĩnh</b> của ứng dụng, nhưng ứng dụng cần routing theo path. Thiết kế?</summary>

**NLB (Elastic IP mỗi AZ) → ALB** làm target của NLB (ALB-type target group), hoặc **Global Accelerator** (2 IP anycast tĩnh) trỏ tới ALB. ALB không có IP tĩnh.
</details>

<details><summary>4. Sau khi deploy, ASG liên tục tạo rồi terminate instance mới. Nguyên nhân thường gặp?</summary>

ELB health check fail: sai path/port, SG của instance không cho SG của ALB vào, user data lỗi, hoặc **health check grace period** quá ngắn so với thời gian khởi động. Xem *Activity history* của ASG và lý do unhealthy trong target group.
</details>

<details><summary>5. Ứng dụng cần vá AMI hằng tháng cho 50 instance trong ASG, không downtime, có rollback tự động. Dùng gì?</summary>

Tạo AMI mới (ví dụ bằng **EC2 Image Builder**) → **launch template version mới** → **Instance refresh** với min healthy phù hợp, bật **auto rollback** (có thể kèm CloudWatch alarm). Không SSH vá tay.
</details>

<details><summary>6. Ứng dụng nội bộ khởi động mất 8 phút; mỗi sáng 9h tải tăng gấp 5 trong 15 phút đầu và người dùng bị chậm. Cải thiện?</summary>

**Scheduled scaling** (hoặc **Predictive scaling**) để có đủ instance trước 9h, kết hợp **warm pool** để giảm thời gian scale-out. Target tracking một mình phản ứng quá chậm với app khởi động lâu.
</details>

<details><summary>7. Đội bảo mật yêu cầu: không mở port 22, mọi phiên quản trị phải được ghi lại, instance ở private subnet không có NAT. Thiết kế?</summary>

**SSM Session Manager** + role `AmazonSSMManagedInstanceCore` + **interface VPC endpoint** `ssm`, `ssmmessages`, `ec2messages`; bật ghi log phiên vào S3/CloudWatch Logs. Không cần bastion.
</details>

<details><summary>8. Một ALB, hai phiên bản ứng dụng; muốn chuyển 10% traffic sang bản mới để thử rồi tăng dần. Cách nào không cần DNS?</summary>

Listener rule **forward tới 2 target group có trọng số** (weighted target groups, ví dụ 90/10). Route 53 weighted routing cũng làm được nhưng chịu ảnh hưởng của DNS cache/TTL.
</details>

---

## Verify
```bash
bash verify.sh               # phần cơ bản; có gửi request thật tới ALB
bash verify.sh --advanced    # thêm N1–N6 (đọc cấu hình + gửi request thật)
bash verify.sh --chaos       # GAME DAY: cố ý làm hỏng rồi đo khả năng tự phục hồi (~10–15 phút)
bash verify.sh --advanced --chaos   # chấm tất cả
```
Phần cơ bản kiểm tra: IAM role + policy, SG đúng nguyên tắc (web chỉ nhận từ ALB, không mở world cả IPv4 lẫn IPv6), launch template (instance profile, IMDSv2), ALB đa AZ, TG/health, ASG (min≥2, đa AZ, ELB health check, scaling policy), và **gửi request thật** tới ALB để chắc chắn có ≥2 instance khác nhau trả lời.

## Cleanup (bắt buộc)
```bash
bash cleanup.sh
```
Xoá ASG (kèm instance, scheduled action, scaling policy), ALB (kèm listener rule), 2 target group, Lambda `saa-lab01-api` + role và log group do Console tạo, launch template, 2 SG, role EC2. **Không** tắt *EBS encryption by default* nếu bạn đã bật (nên giữ bật).
