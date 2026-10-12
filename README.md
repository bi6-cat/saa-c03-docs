# SAA-C03 – Bộ tài liệu tự học 8 tuần

Cấu trúc:

```
saa-c03/
├── README.md                  <- bạn đang đọc
├── theory/                    <- lý thuyết theo tuần (đọc → tự kiểm tra)
│   ├── week1-iam-ec2-elb-asg.md
│   ├── week2-networking.md
│   ├── week3-storage-database.md
│   ├── week4-decoupling-serverless.md
│   ├── week5-security.md
│   ├── week6-resilience-dr-cost.md
│   └── week7-8-exam-playbook.md
└── labs/                      <- lab thực hành, mỗi lab có verify.sh + cleanup.sh
    ├── _common.sh
    ├── lab01-ec2-alb-asg/
    ├── lab02-vpc/
    ├── lab03-s3-dynamodb/
    ├── lab04-sns-sqs-lambda/
    ├── lab05-security/
    └── lab06-cloudfront-dr/
```

## Cách học mỗi tuần (khoảng 10–12 giờ)

1. **2–3 giờ**: xem video khoá chính (Maarek/Cantrill) của phần đó.
2. **3 giờ**: đọc file `theory/weekN-*.md`, ghi chú chỗ chưa rõ, tự trả lời mục *Tự kiểm tra*.
   Trong file lý thuyết: **💡 Kinh nghiệm thực tế** = điều hay gặp khi vận hành hệ thống thật; **🎯 Mẹo thi** = cách đề hay hỏi; **⚠️ Hay nhầm** = cặp khái niệm dễ lẫn.
3. **3–4 giờ**: làm `labs/labNN-*` → chạy `verify.sh` cho tới khi **toàn bộ PASS**.
4. **Luôn luôn**: chạy `cleanup.sh` khi xong lab.
5. **1–2 giờ**: làm 1 bộ câu hỏi (Tutorials Dojo / Skill Builder) cho chủ đề của tuần, ghi vào sổ lỗi.

| Tuần | Lý thuyết | Lab |
|---|---|---|
| 1 | week1 | lab01 |
| 2 | week2 | lab02 |
| 3 | week3 | lab03 |
| 4 | week4 | lab04 |
| 5 | week5 | lab05 |
| 6 | week6 | lab06 |
| 7–8 | week7-8 (luyện đề, ôn) | làm lại lab nào còn yếu |

## Chuẩn bị môi trường lab (làm 1 lần, ~30 phút)

> **Quy tắc an toàn tiền bạc – làm TRƯỚC khi tạo bất cứ thứ gì**

1. **Tài khoản AWS cá nhân** (không dùng tài khoản công ty). Bật **MFA cho root user**, sau đó **không dùng root để làm lab**.
2. Tạo **IAM Identity Center user** (khuyên dùng) hoặc **IAM user** có MFA, gắn quyền `AdministratorAccess` *cho tài khoản lab riêng này*. Dùng user này cho cả Console lẫn CLI.
3. **Billing → Budgets**: tạo budget hàng tháng (ví dụ 10 USD), báo email ở 50% / 80% / 100%. (Lab 06 sẽ kiểm tra lại việc này.)
4. Bật **Billing → Billing preferences → Receive Free Tier usage alerts**.
5. Cài **AWS CLI v2**, `jq`, `curl`, rồi:
   ```bash
   aws configure sso        # hoặc: aws configure
   aws sts get-caller-identity   # phải in ra Account của bạn
   ```
6. Mặc định các lab dùng region **`ap-southeast-1` (Singapore)**. Muốn đổi: `export AWS_REGION=ap-southeast-2`.
   Đa số script đọc biến `AWS_REGION`; hãy dùng **đúng một region** trong cả lab (trừ Lab 06 có thêm DR region, đọc từ biến `DR_REGION`, mặc định `ap-southeast-2`; phải khác `AWS_REGION` và dùng cùng giá trị khi chạy cả `verify.sh` lẫn `cleanup.sh`).

> Tài khoản AWS mới hiện có thể ở "Free plan" dùng credit thay vì Free Tier 12 tháng cũ – vào **Billing** xem tài khoản của bạn thuộc loại nào và credit còn bao nhiêu.

### Dịch vụ dễ "ngốn" tiền (nhớ xoá ngay)
NAT Gateway (~0,05 USD/giờ), ALB (có phí theo giờ), RDS/Aurora, Elastic IP không gắn, EBS/Snapshot bỏ quên, KMS key (1 USD/tháng), Secrets Manager secret (0,4 USD/tháng), instance chạy quên tắt.
**Lab này cố ý tránh NAT Gateway và RDS.**

## Cách chạy verify / cleanup

```bash
cd ~/saa-c03/labs/lab01-ec2-alb-asg
bash verify.sh      # chấm lab: in [PASS]/[FAIL] cho từng yêu cầu
bash cleanup.sh     # xoá hết tài nguyên lab (hỏi xác nhận)
```

- Tên tài nguyên **phải đúng như đề bài** (ví dụ `saa-lab01-alb`), vì script tìm theo tên.
- `verify.sh` chỉ **đọc** cấu hình và gửi vài request kiểm thử; một số lab ghi/xoá vài object/item thử nghiệm (có ghi rõ trong lab).
- `cleanup.sh` chỉ xoá tài nguyên mang tên `saa-labNN-*` (và bucket `saa-labNN-<account-id>...`), nhưng vẫn **hãy đọc script trước khi chạy** – đây là tài khoản của bạn.

## Lưu ý trung thực

- Các script được viết theo tài liệu AWS CLI v2 nhưng **chưa được chạy trên tài khoản AWS thật** (người viết không có credential của bạn). Đã kiểm tra cú pháp bash. Nếu một check báo FAIL mà bạn chắc cấu hình đúng, hãy xem dòng lệnh trong `verify.sh` và báo lại để chỉnh.
- Giao diện Console AWS thay đổi thường xuyên: các bước lab ghi *cần cấu hình gì*, tên nút có thể khác chút.
- Nội dung lý thuyết nhằm bám exam guide SAA-C03; **luôn đối chiếu với [exam guide chính thức](https://docs.aws.amazon.com/aws-certification/latest/examguides/solutions-architect-associate-03.html)** và tài liệu AWS khi có chi tiết số liệu (giới hạn, giá) – những thứ này AWS đổi theo thời gian.
