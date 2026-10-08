# Lab 01 – Web app chịu lỗi: IAM Role + ALB + Auto Scaling (2 AZ)

**Thời gian:** ~60–90 phút | **Chi phí ước tính:** thấp (2× t3.micro + 1 ALB) – **nhớ chạy `cleanup.sh`**
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

## Verify
```bash
bash verify.sh
```
Script kiểm tra: IAM role + policy, SG đúng nguyên tắc (web chỉ nhận từ ALB, không mở world), launch template (instance profile, IMDSv2), ALB đa AZ, TG/health, ASG (min≥2, đa AZ, ELB health check, scaling policy), và **gửi request thật** tới ALB để chắc chắn có ≥2 instance khác nhau trả lời.

## Cleanup (bắt buộc)
```bash
bash cleanup.sh
```

## Câu hỏi suy ngẫm
1. Nếu 1 AZ mất hoàn toàn, hệ thống còn phục vụ được không? Vì sao?
2. Vì sao web SG tham chiếu SG của ALB thay vì CIDR?
3. Nếu muốn app truy cập Internet từ private subnet thì cần thêm gì? (xem Lab 02)
4. Nếu đổi ALB sang NLB thì thay đổi gì ở SG và health check?
