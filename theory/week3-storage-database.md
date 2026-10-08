# Tuần 3 – Storage & Database

**Mục tiêu:** nhìn use case là chọn đúng loại lưu trữ / cơ sở dữ liệu, và hiểu HA/DR/scale của từng loại.
**Lab đi kèm:** `labs/lab03-s3-dynamodb`

---

## PHẦN A – STORAGE

### 1. Amazon S3 (object storage)

- Bucket tên **duy nhất toàn cầu**, nằm trong 1 Region; object tối đa **5 TB**. Upload 1 lần (PUT) tối đa 5 GB; >100 MB nên dùng **multipart upload**, >5 GB **bắt buộc**.
- **Strong read-after-write consistency** cho mọi thao tác.
- Hiệu năng: tối thiểu **3.500 PUT/COPY/POST/DELETE** và **5.500 GET/HEAD mỗi giây trên mỗi prefix**. Tăng tốc đọc: **byte-range fetch**; tăng tốc upload xa: **S3 Transfer Acceleration**.

#### Storage classes
| Class | Dùng khi | Ghi nhớ |
|---|---|---|
| **Standard** | Truy cập thường xuyên | Mặc định, 11 số 9 độ bền, ≥3 AZ |
| **Intelligent-Tiering** | Mẫu truy cập **không rõ/đổi** | Tự chuyển tier, không phí retrieval |
| **Standard-IA** | Ít truy cập, cần lấy nhanh | Tối thiểu 30 ngày, 128 KB |
| **One Zone-IA** | Như IA, dữ liệu tái tạo được | **1 AZ** (mất nếu AZ hỏng), rẻ hơn |
| **Glacier Instant Retrieval** | Lưu trữ, truy cập ~1 lần/quý, cần mili-giây | Tối thiểu 90 ngày |
| **Glacier Flexible Retrieval** | Lưu trữ, chấp nhận chờ | Expedited 1–5 phút, Standard 3–5 giờ, Bulk 5–12 giờ; tối thiểu 90 ngày |
| **Glacier Deep Archive** | Lưu trữ lâu dài rẻ nhất | Lấy ~12 giờ (bulk ~48 giờ); tối thiểu 180 ngày |

- **Lifecycle rules**: chuyển class/xoá theo tuổi object, quản lý version cũ, dọn multipart dang dở. (Standard → IA yêu cầu object đã ≥ 30 ngày.)

#### Tính năng cần nhớ
- **Versioning**: bảo vệ khỏi xoá/ghi đè nhầm; xoá = tạo *delete marker*. Một khi bật chỉ có thể *suspend*.
- **Replication**: **CRR** (khác Region) / **SRR** (cùng Region); cần **bật versioning cả hai bucket**; chỉ sao chép object **mới** sau khi bật (dữ liệu cũ dùng Batch Replication). **S3 RTC** cam kết 15 phút.
- **Encryption**: SSE-S3 (mặc định cho object mới), **SSE-KMS** (audit CloudTrail, có giới hạn quota KMS), SSE-C (khách tự giữ khoá), DSSE-KMS; hoặc client-side. Ép HTTPS bằng policy `aws:SecureTransport`.
- **Bảo mật truy cập**: **Block Public Access** (cấp account/bucket), bucket policy, IAM, ACL (nên tắt), **pre-signed URL**, **Access Points**, **VPC endpoint policy**.
- **Object Lock** (WORM): *Governance* (người có quyền đặc biệt vẫn gỡ được) vs *Compliance* (không ai gỡ được, kể cả root); **Legal hold**; **Glacier Vault Lock** cho policy bất biến.
- **Event Notifications** → SNS, SQS, Lambda, EventBridge.
- **Static website hosting**: HTTP, public; muốn private + HTTPS + custom domain → **CloudFront + OAC**.
- **S3 Select / Glacier Select**, **Storage Lens**, **Inventory**, **Requester Pays**, **Multi-Region Access Points**.

### 2. Các dịch vụ lưu trữ khác
| Dịch vụ | Loại | Dùng khi |
|---|---|---|
| **EBS** | Block, 1 AZ, 1 instance | Boot volume, DB trên EC2 |
| **EFS** | File **NFS**, Linux, đa AZ, auto scale; Standard/IA, Elastic/Provisioned throughput | Chia sẻ file giữa nhiều EC2/container |
| **FSx for Windows File Server** | SMB, tích hợp AD | Windows shares |
| **FSx for Lustre** | File hiệu năng cao, tích hợp S3 | HPC, ML, xử lý video |
| **FSx for NetApp ONTAP / OpenZFS** | Di chuyển NAS NFS/SMB/iSCSI | Lift-and-shift NAS |
| **Storage Gateway** | Lai on-prem ↔ AWS: *S3 File*, *FSx File*, *Volume (cached/stored)*, *Tape* | Mở rộng/backup on-prem lên cloud |
| **DataSync** | Chuyển dữ liệu **online**, theo lịch, NFS/SMB/HDFS/S3… | Di chuyển khối lượng lớn qua mạng |
| **Transfer Family** | SFTP/FTPS/FTP vào S3/EFS | Đối tác dùng FTP |
| **Snow Family** (Snowball Edge…) | Chuyển/xử lý **offline** TB–PB | Mạng chậm/không có (kiểm tra trạng thái sản phẩm mới nhất) |
| **AWS Backup** | Backup tập trung đa dịch vụ, policy, cross-region/account, Vault Lock | Tuân thủ backup |

---

## PHẦN B – DATABASE

### 3. Chọn database theo use case (bảng quan trọng nhất của tuần)
| Nhu cầu | Dịch vụ |
|---|---|
| Quan hệ OLTP, SQL | **RDS** (MySQL, PostgreSQL, MariaDB, Oracle, SQL Server, Db2), **Aurora** |
| Quan hệ hiệu năng cao, cloud-native | **Aurora** (MySQL/PostgreSQL compatible) |
| Key-value/document, độ trễ ms, scale vô hạn | **DynamoDB** |
| Cache trong bộ nhớ | **ElastiCache** (Redis/Valkey, Memcached), **DAX** (cho DynamoDB), MemoryDB (Redis bền) |
| Data warehouse, OLAP, SQL phân tích | **Redshift** |
| Query SQL trực tiếp trên S3, không server | **Athena** |
| ETL / catalog | **Glue** |
| Tìm kiếm, log analytics | **OpenSearch Service** |
| Đồ thị (graph) | **Neptune** |
| MongoDB-compatible | **DocumentDB** |
| Cassandra-compatible | **Keyspaces** |
| Chuỗi thời gian | **Timestream** |
| Sổ cái bất biến | QLDB (đang bị AWS dừng hỗ trợ – ưu tiên Aurora PostgreSQL + audit); đề cũ vẫn có thể nhắc |

### 4. RDS
- **Multi-AZ**: standby **đồng bộ** ở AZ khác, **failover tự động** (1–2 phút, DNS endpoint đổi). Mục đích **HA/DR, không phải scale đọc**. Standby không phục vụ đọc (trừ Multi-AZ DB *cluster* có 2 readable standby).
- **Read Replica**: **bất đồng bộ**, để **scale đọc**, tối đa 5 (RDS MySQL/MariaDB/PostgreSQL…), có thể **cross-Region**, có thể **promote** thành DB độc lập (DR). Truy cập qua endpoint riêng.
- **Backup**: automated (1–35 ngày, Point-in-Time Recovery) + manual snapshot (giữ đến khi xoá). Restore luôn tạo **instance mới**.
- **Mã hoá at rest** (KMS) phải bật **lúc tạo**; DB chưa mã hoá → snapshot → copy có mã hoá → restore. Mã hoá in-transit bằng SSL/TLS. Hỗ trợ **IAM database authentication**.
- **RDS Proxy**: gom connection pool, giảm failover time, tốt với Lambda; dùng Secrets Manager/IAM.
- **Storage Auto Scaling**; **RDS Custom** (Oracle/SQL Server cần truy cập OS).

### 5. Aurora
- Lưu trữ phân tán **6 bản sao qua 3 AZ**, tự mở rộng tới **128 TiB**, ghi vẫn hoạt động khi mất 2 bản, đọc vẫn hoạt động khi mất 3 bản.
- Tới **15 Aurora Replicas**, failover nhanh (<30 giây thường), **Reader endpoint** cân bằng đọc, **Custom endpoints**.
- **Aurora Serverless v2**: tự co giãn theo tải, tải khó đoán.
- **Aurora Global Database**: cross-Region, replication <1 giây, RTO ~ 1 phút khi promote region phụ (DR + đọc toàn cầu).
- **Backtrack** (MySQL): tua lại thời điểm không cần restore. **Aurora Cloning**: sao chép nhanh. **Parallel Query**, **Machine Learning integration**.

### 6. DynamoDB
- NoSQL key-value/document, managed, đa AZ, độ trễ một chữ số ms.
- **Khoá**: Partition key (+ Sort key tuỳ chọn). Thiết kế partition key **phân phối đều** để tránh *hot partition*.
- **Capacity**: *On-demand* (tải khó đoán, trả theo request) vs *Provisioned* (RCU/WCU, có auto scaling; rẻ hơn khi ổn định). 1 RCU = 1 lần đọc strongly consistent 4 KB/giây (eventually: 2 lần); 1 WCU = ghi 1 KB/giây.
- **Index**: **GSI** (khoá khác, tạo/thêm bất cứ lúc nào, đọc eventually consistent) vs **LSI** (cùng partition key, khác sort key, **chỉ tạo lúc tạo bảng**, tối đa 5).
- **Tính năng**: **DynamoDB Streams** (+ Lambda), **TTL** (tự xoá item hết hạn, miễn phí), **PITR** (35 ngày), **On-demand backup**, **Global Tables** (đa Region, multi-active), **Transactions**, **DAX** (cache vi giây, tương thích API), **Export/Import S3**, mã hoá mặc định.
- Item tối đa **400 KB** → file lớn lưu S3, lưu con trỏ trong DynamoDB.
- Truy vấn: `Query` (theo key – nhanh) ≫ `Scan` (quét toàn bảng – tốn).

### 7. ElastiCache
| | Redis (Valkey) | Memcached |
|---|---|---|
| Multi-AZ/failover, replica | Có | Không |
| Persistence/backup | Có | Không |
| Cấu trúc dữ liệu (sorted set, pub/sub…) | Có | Chỉ key-value |
| Đa luồng | Không | Có |
| Dùng khi | Cache + session + leaderboard, cần HA | Cache đơn giản, scale ngang nhiều node |
- Mẫu cache: *lazy loading* (cache-aside) vs *write-through*. Dùng để giảm tải DB và độ trễ; lưu **session** để app stateless.

### 8. Redshift, Athena và phân tích
- **Redshift**: columnar, MPP, SQL, OLAP/BI; **Redshift Spectrum** query S3; snapshot cross-Region; Multi-AZ; **Serverless**.
- **Athena**: serverless, query S3 bằng SQL (Presto/Trino), trả theo dữ liệu quét → dùng **Parquet/ORC + partition** để giảm chi phí.
- **Kinesis Data Firehose / Data Streams**: tuần 4. **Lake Formation**: quản trị data lake. **QuickSight**: BI dashboard. **EMR**: Hadoop/Spark.

### 9. Di chuyển DB
- **DMS (Database Migration Service)** + **SCT (Schema Conversion Tool)**: di chuyển DB liên tục (CDC), đồng nhất hoặc **khác engine** (Oracle → Aurora PostgreSQL).
- **AWS Application Migration Service (MGN)**: lift-and-shift server.

---

## Bẫy thường gặp
1. Multi-AZ ≠ scale đọc. **Read replica** mới scale đọc.
2. "DR cross-Region cho RDS/Aurora" → cross-Region read replica / **Aurora Global Database**.
3. "Nhiều EC2 Linux dùng chung file" → **EFS**; "Windows SMB" → **FSx for Windows**; "HPC" → **FSx for Lustre**.
4. "Lưu trữ lâu dài, truy cập hiếm, rẻ nhất" → **Glacier Deep Archive**; "mẫu truy cập khó đoán" → **Intelligent-Tiering**.
5. "Không được xoá/sửa trong N năm (compliance)" → **S3 Object Lock – Compliance mode**.
6. "Giảm độ trễ đọc DynamoDB còn micro-giây" → **DAX**.
7. "Tải DynamoDB bùng nổ, không đoán trước" → **On-demand**.
8. "Query log S3 bằng SQL, không hạ tầng" → **Athena**; "kho dữ liệu phân tích lớn" → **Redshift**.
9. Mã hoá RDS phải bật khi tạo; muốn mã hoá DB có sẵn phải đi qua snapshot.
10. "Chuyển 100 TB, mạng chậm" → Snow Family; "online, lặp lại" → DataSync.

---

## Tự kiểm tra

1. Khác biệt Multi-AZ và Read Replica ở RDS (đồng bộ/bất đồng bộ, mục đích)?
2. Bạn có dữ liệu log truy cập hiếm sau 30 ngày, phải giữ 7 năm với chi phí thấp nhất và có thể chờ 12 giờ để lấy. Dùng class nào và cấu hình gì?
3. LSI và GSI khác nhau thế nào? Cái nào thêm sau khi tạo bảng được?
4. Làm sao đảm bảo mọi truy cập S3 phải qua HTTPS?
5. Aurora lưu bao nhiêu bản sao ở bao nhiêu AZ?
6. Dùng ElastiCache nào khi cần failover tự động và persistence?
7. Có DB RDS chưa mã hoá, cần mã hoá. Các bước?
8. Muốn 2 Region cùng đọc/ghi DynamoDB với độ trễ thấp?

<details><summary>Đáp án</summary>

1. Multi-AZ: đồng bộ, HA/failover, standby không để đọc. Read Replica: bất đồng bộ, scale đọc, có thể cross-Region/promote.
2. Lifecycle: Standard → Glacier Deep Archive (ví dụ sau 30 ngày); giữ 7 năm (lifecycle expiration sau ~2555 ngày).
3. LSI: cùng partition key, khác sort key, chỉ tạo lúc tạo bảng. GSI: khoá bất kỳ, thêm sau được.
4. Bucket policy `Deny` khi `aws:SecureTransport = false`.
5. 6 bản sao qua 3 AZ.
6. ElastiCache for Redis (Multi-AZ + replica + persistence).
7. Snapshot → copy snapshot bật encryption (chọn KMS key) → restore thành instance mới → chuyển ứng dụng sang endpoint mới.
8. DynamoDB Global Tables.
</details>

## Tài liệu nên đọc thêm
- FAQ: S3, RDS, Aurora, DynamoDB, ElastiCache. Doc: "S3 storage classes", "Aurora DB cluster – high availability", "DynamoDB read/write capacity modes".
- Well-Architected: Reliability pillar – phần dữ liệu & backup.
