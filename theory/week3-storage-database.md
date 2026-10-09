# Tuần 3 – Storage & Database

**Mục tiêu:** nhìn use case là chọn đúng loại lưu trữ / cơ sở dữ liệu, và hiểu HA/DR/scale/chi phí của từng loại.
**Lab đi kèm:** `labs/lab03-s3-dynamodb`

> Ký hiệu: **💡 Kinh nghiệm thực tế** · **🎯 Mẹo thi** · **⚠️ Hay nhầm**.
> Tuần này nhiều số liệu. Đừng học thuộc hết – ưu tiên các số được **in đậm** (hay ra đề).

---

## PHẦN A – STORAGE

### 0. Ba kiểu lưu trữ – chọn đúng ngay từ đầu

| Kiểu | Truy cập | Dịch vụ | Ví dụ |
|---|---|---|---|
| **Block** | Như ổ đĩa gắn vào 1 máy, OS tự format | EBS, Instance Store | Boot volume, DB tự cài trên EC2 |
| **File** | Thư mục/file qua NFS/SMB, nhiều máy dùng chung | EFS, FSx | Thư mục upload dùng chung, home directory, CMS |
| **Object** | Qua HTTP API (PUT/GET), không sửa một phần file | S3 | Ảnh, video, backup, data lake, static website |

---

### 1. Amazon S3 (object storage)

#### 1.1 Cơ bản
- **Bucket**: tên **duy nhất toàn cầu** (3–63 ký tự, chữ thường, số, `-`, `.`), nằm ở **1 Region**.
- **Object** = key (đường dẫn đầy đủ, vd. `logs/2026/10/09/app.log`) + data + metadata + tag + version ID. "Thư mục" chỉ là **prefix** của key.
- Kích thước object tối đa **5 TB**; một lần PUT tối đa **5 GB**; > 100 MB **nên** dùng **multipart upload**, > 5 GB **bắt buộc**.
- **Strong read-after-write consistency** cho mọi thao tác (PUT, DELETE, LIST) – ghi xong đọc là thấy ngay.
- Độ bền **99,999999999% (11 số 9)** cho mọi class (trừ class 1 AZ khi mất AZ).

#### 1.2 Hiệu năng
- Tối thiểu **3.500 PUT/COPY/POST/DELETE** và **5.500 GET/HEAD mỗi giây trên mỗi prefix**. Không giới hạn số prefix → dữ liệu chia nhiều prefix scale gần như vô hạn (S3 tự phân vùng; khi tăng đột ngột có thể gặp `503 Slow Down` tạm thời → retry với backoff).
- **Multipart upload**: chia phần (5 MB – 5 GB/phần, tối đa 10.000 phần), upload song song, phần lỗi upload lại riêng.
- **Byte-range fetch**: đọc song song nhiều đoạn của một object lớn; hoặc chỉ đọc phần header.
- **S3 Transfer Acceleration**: upload/download từ xa đi vào **edge location** rồi chạy trên backbone AWS (bucket phải bật; tên bucket không chứa dấu chấm).
- **S3 Express One Zone** (*directory bucket*): độ trễ một chữ số ms, tới hàng trăm nghìn request/giây, **1 AZ** → dữ liệu nóng cho ML/analytics, đặt cùng AZ với compute.

#### 1.3 Storage classes

| Class | Dùng khi | Availability (thiết kế) | Lưu tối thiểu | Phí lấy dữ liệu | Ghi nhớ |
|---|---|---|---|---|---|
| **Standard** | Truy cập thường xuyên | 99,99% | — | Không | Mặc định, ≥ 3 AZ |
| **Intelligent-Tiering** | Mẫu truy cập **không rõ / thay đổi** | 99,9% | — | **Không** | Phí giám sát nhỏ/object; tự chuyển tầng: Frequent → Infrequent (30 ngày không truy cập) → Archive Instant (90 ngày); có thể bật thêm Archive Access / Deep Archive Access. Object < 128 KB không được chuyển tầng |
| **Standard-IA** | Ít truy cập nhưng cần lấy **ngay** | 99,9% | 30 ngày | Có (theo GB) | Tính tối thiểu 128 KB/object |
| **One Zone-IA** | Như IA, dữ liệu **tái tạo được** | 99,5% | 30 ngày | Có | **1 AZ** – mất AZ là mất dữ liệu; rẻ hơn IA ~20% |
| **Glacier Instant Retrieval** | Lưu trữ, truy cập ~1 lần/quý, cần **mili-giây** | 99,9% | 90 ngày | Có (cao hơn IA) | Ảnh y tế, tin tức cũ |
| **Glacier Flexible Retrieval** | Lưu trữ, chấp nhận **chờ phút–giờ** | 99,99% | 90 ngày | Tuỳ tốc độ | **Expedited 1–5 phút**, **Standard 3–5 giờ**, **Bulk 5–12 giờ** (bulk miễn phí) |
| **Glacier Deep Archive** | Lưu trữ **lâu dài rẻ nhất** (7–10 năm, tuân thủ) | 99,99% | **180 ngày** | Có | **Standard ~12 giờ**, **Bulk ~48 giờ** |

> Object ở Glacier Flexible / Deep Archive **không đọc trực tiếp** được: phải **restore** (tạo bản tạm) rồi mới GET.

#### 1.4 Lifecycle rules
- **Transition**: chuyển class theo tuổi (vd. 30 ngày → Standard-IA, 90 ngày → Glacier IR, 365 ngày → Deep Archive).
- **Expiration**: xoá object hiện hành sau N ngày; xoá **noncurrent version** sau N ngày; dọn **expired delete marker**; **abort incomplete multipart upload** sau N ngày.
- Lọc theo prefix, tag, kích thước object.
- Ràng buộc: chuyển Standard → Standard-IA/One Zone-IA cần object **≥ 30 ngày** tuổi; chuyển theo "thác nước" xuống dưới, không chuyển ngược lên bằng lifecycle.

Ví dụ rule (lab03 làm tương tự):
```json
{
  "Rules": [{
    "ID": "logs-tiering",
    "Filter": { "Prefix": "logs/" },
    "Status": "Enabled",
    "Transitions": [
      { "Days": 30,  "StorageClass": "STANDARD_IA" },
      { "Days": 180, "StorageClass": "DEEP_ARCHIVE" }
    ],
    "Expiration": { "Days": 2555 },
    "NoncurrentVersionExpiration": { "NoncurrentDays": 30 },
    "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
  }]
}
```

> 💡 **Kinh nghiệm thực tế – chi phí S3**
> - **Object nhỏ + lifecycle sang IA/Glacier có thể đắt hơn**: IA tính tối thiểu 128 KB/object, Glacier thêm metadata ~40 KB/object và phí request chuyển class tính **theo từng object**. Hàng triệu file 10 KB → gom (tar/zip/Parquet) trước khi archive.
> - Thời gian lưu tối thiểu: xoá object ở Glacier Deep Archive sau 30 ngày vẫn bị tính đủ 180 ngày.
> - Bật versioning mà **không** có rule xoá noncurrent version → dung lượng (và hoá đơn) tăng âm thầm mỗi lần ghi đè.
> - **Incomplete multipart upload** vô hình trong `ls` nhưng vẫn tính tiền → luôn có rule abort.
> - Dùng **S3 Storage Lens** để thấy bucket nào lớn, bao nhiêu % noncurrent, bao nhiêu multipart dở dang.
> - Không chắc mẫu truy cập → **Intelligent-Tiering** gần như luôn là lựa chọn an toàn cho object > 128 KB.

#### 1.5 Versioning & bảo vệ dữ liệu
- **Versioning**: mỗi lần ghi đè tạo version mới; DELETE (không chỉ định version) tạo **delete marker** (object "biến mất" nhưng khôi phục được bằng cách xoá marker). Đã bật thì chỉ có thể **suspend**, không tắt hẳn.
- **MFA Delete**: yêu cầu MFA khi xoá vĩnh viễn version / đổi trạng thái versioning. Chỉ **root** bật được, qua CLI/API.
- **Object Lock** (WORM – write once read many), cần versioning:
  - *Governance mode*: người có quyền đặc biệt (`s3:BypassGovernanceRetention`) vẫn gỡ/rút ngắn được → dùng để thử nghiệm, chống xoá nhầm.
  - *Compliance mode*: **không ai** xoá/sửa được trong thời hạn, **kể cả root**, không rút ngắn được → yêu cầu pháp lý (SEC 17a-4…).
  - *Legal hold*: khoá vô thời hạn tới khi gỡ, độc lập với retention.
- **Glacier Vault Lock**: khoá **policy** của Glacier vault (bất biến sau khi lock).

#### 1.6 Replication
- **CRR** (Cross-Region) / **SRR** (Same-Region): **bật versioning ở cả hai bucket**, cần IAM role cho S3.
- Chỉ sao chép object **mới** sau khi bật rule; dữ liệu cũ → **S3 Batch Replication**.
- **Delete marker** mặc định **không** sao chép (tuỳ chọn bật); **xoá một version cụ thể không bao giờ** được sao chép (chống xoá có chủ đích lan sang bản DR).
- **Không bắc cầu**: A→B, B→C thì object từ A sang B **không** tự sang C.
- **S3 RTC** (Replication Time Control): cam kết 99,99% object sao chép trong **15 phút**, có metric/thông báo.
- Có thể đổi owner/storage class ở đích (vd. bản DR để Glacier/IA cho rẻ), sao chép object mã hoá SSE-KMS (chỉ định key đích).
- Use case: DR, tuân thủ lưu ở 2 Region, giảm độ trễ đọc, gộp log từ nhiều bucket (SRR), sao chép giữa môi trường prod → test.

#### 1.7 Mã hoá
| Kiểu | Ai giữ khoá | Ghi chú |
|---|---|---|
| **SSE-S3** | AWS (AES-256) | **Mặc định cho mọi object mới** từ 2023 |
| **SSE-KMS** | KMS (AWS managed `aws/s3` hoặc **CMK** của bạn) | Audit CloudTrail từng lần dùng khoá, tách quyền (phải có quyền KMS mới đọc được). Có quota request KMS → bật **S3 Bucket Key** để giảm tới ~99% số lần gọi KMS |
| **DSSE-KMS** | KMS, mã hoá 2 lớp | Yêu cầu tuân thủ "dual-layer" |
| **SSE-C** | **Khách hàng** gửi khoá trong mỗi request (HTTPS bắt buộc) | AWS không lưu khoá; mất khoá = mất dữ liệu |
| **Client-side** | Khách hàng mã hoá trước khi upload | AWS không bao giờ thấy plaintext |

- **In transit**: ép HTTPS bằng bucket policy `aws:SecureTransport = false → Deny` (lab03).
- Ép mọi upload phải dùng SSE-KMS: bucket policy Deny `s3:PutObject` nếu header `s3:x-amz-server-side-encryption` khác `aws:kms` (hoặc đặt default encryption là SSE-KMS).

#### 1.8 Kiểm soát truy cập
- **Block Public Access** (cấp account và bucket) – bật mặc định cho bucket mới; là "cầu dao tổng" ghi đè mọi policy/ACL công khai.
- **Bucket policy** (resource-based): cross-account, ép điều kiện (TLS, VPC endpoint, IP, Org).
- **IAM policy**: quyền của user/role trong account.
- **ACL**: cơ chế cũ → đặt **Object Ownership = Bucket owner enforced** (tắt ACL).
- **Pre-signed URL**: URL có chữ ký tạm thời, mang quyền của người ký. Hết hạn tối đa **7 ngày** (ký bằng IAM user SigV4); ký bằng credential tạm của role thì hết hạn **sớm hơn** khi session hết hạn.
- **S3 Access Points**: mỗi ứng dụng/team một endpoint với policy riêng (thay vì một bucket policy khổng lồ); có thể giới hạn chỉ truy cập từ một VPC.
- **Multi-Region Access Points**: một endpoint toàn cầu, tự route tới bucket gần nhất, kết hợp CRR → failover giữa Region.

> 💡 **Kinh nghiệm thực tế – upload trực tiếp từ trình duyệt**: Backend (Lambda) cấp **pre-signed PUT URL** → trình duyệt upload thẳng lên S3 → S3 Event kích hoạt xử lý. Server không phải chuyển tiếp file lớn, rẻ và scale tốt. Đặt key theo `uploads/<userId>/<uuid>` và giới hạn `Content-Type`/kích thước bằng POST policy nếu cần.

#### 1.9 Tính năng khác cần biết
- **Event Notifications** → SNS, SQS, Lambda, hoặc **EventBridge** (lọc linh hoạt hơn, nhiều target, archive/replay). Giao *ít nhất một lần*, thường trong vài giây.
- **Static website hosting**: endpoint **HTTP**, bucket phải public → muốn **HTTPS + custom domain + bucket private** → **CloudFront + OAC** (lab06).
- **CORS**: cấu hình khi web ở domain A gọi object ở bucket B từ trình duyệt.
- **Requester Pays**: người tải trả phí request + data transfer (chia sẻ dataset lớn).
- **S3 Select / Glacier Select**: lọc bằng SQL phía server (AWS đã hạn chế cho khách hàng mới – Athena là lựa chọn thay thế).
- **S3 Inventory** (danh sách object CSV/Parquet hằng ngày), **S3 Batch Operations** (thao tác hàng loạt: copy, tag, restore, Lambda trên hàng tỷ object), **Storage Lens** (thống kê toàn Org).
- **Object tags**: dùng cho lifecycle, phân quyền ABAC, phân bổ chi phí.

---

### 2. File storage: EFS & FSx

#### 2.1 Amazon EFS
- **NFS v4.1** managed cho **Linux** (không hỗ trợ Windows), tự co giãn dung lượng (trả theo GB dùng thật), hàng nghìn client cùng lúc, trải **nhiều AZ** (Regional) hoặc **One Zone** (rẻ hơn).
- **Mount target**: 1 cái/AZ trong VPC, có SG → mở **TCP 2049** từ SG của client.
- **Storage classes**: Standard, Infrequent Access (IA), Archive + **lifecycle management** (vd. 30 ngày không đọc → IA).
- **Throughput mode**: **Elastic** (khuyên dùng, tự scale, trả theo dùng), Provisioned (đặt trước MB/s), Bursting (theo dung lượng – cũ).
- **Performance mode**: General Purpose (mặc định, độ trễ thấp) vs Max I/O (cũ, cho song song cực lớn nhưng độ trễ cao hơn).
- Dùng được từ EC2, ECS (cả Fargate), EKS, Lambda; truy cập từ on-prem qua VPN/DX.
- **EFS Access Points**: ép UID/GID và thư mục gốc cho từng ứng dụng.
- **EFS Replication** sang Region khác (DR); AWS Backup.

> 💡 EFS Standard đắt hơn EBS gp3 nhiều lần/GB. Đừng dùng EFS chỉ vì "tiện" cho một máy duy nhất. Bật lifecycle IA/Archive cho dữ liệu nguội – thường giảm phần lớn chi phí.

#### 2.2 Amazon FSx

| Dịch vụ | Giao thức | Điểm mạnh | Use case |
|---|---|---|---|
| **FSx for Windows File Server** | **SMB**, NTFS | Tích hợp **Active Directory**, ACL Windows, DFS Namespaces, shadow copies, dedup, **Multi-AZ** | File share Windows, home folder, SharePoint, SQL Server |
| **FSx for Lustre** | Lustre (Linux, POSIX) | Hàng trăm GB/s, triệu IOPS, độ trễ sub-ms; **liên kết S3** (lazy load từ S3, ghi kết quả về S3). *Scratch* (tạm, không sao chép, rẻ) vs *Persistent* (sao chép trong AZ) | **HPC, ML training, xử lý video, mô phỏng tài chính** |
| **FSx for NetApp ONTAP** | NFS, SMB, **iSCSI** (đa giao thức) | Snapshot, clone tức thời, SnapMirror, nén/dedup, tiering tự động | **Lift-and-shift NAS NetApp**, workload cần cả Windows và Linux |
| **FSx for OpenZFS** | NFS | Hiệu năng cao, snapshot/clone ZFS | Di chuyển ZFS/Linux NAS |

> 🎯 Từ khoá → đáp án: "SMB / Windows / Active Directory" → **FSx for Windows**. "HPC / ML / Lustre / xử lý dữ liệu từ S3 tốc độ cao" → **FSx for Lustre**. "NFS dùng chung cho Linux, serverless, tự co giãn" → **EFS**. "NetApp / đa giao thức / iSCSI" → **FSx for ONTAP**.

---

### 3. Hybrid & di chuyển dữ liệu

| Dịch vụ | Làm gì | Dùng khi |
|---|---|---|
| **Storage Gateway – S3 File Gateway** | Máy ảo on-prem expose **NFS/SMB**, file lưu thành object S3, cache cục bộ | App on-prem ghi file nhưng muốn dữ liệu nằm ở S3 (rồi lifecycle/analytics) |
| **Storage Gateway – FSx File Gateway** | Cache cục bộ cho FSx for Windows | (AWS đã ngừng cho khách hàng mới – đề cũ vẫn có thể nhắc) |
| **Storage Gateway – Volume Gateway** | Ổ **iSCSI**: *Cached* (dữ liệu chính ở AWS, cache nóng ở on-prem) / *Stored* (dữ liệu chính ở on-prem, backup snapshot lên AWS) | Mở rộng dung lượng block, backup volume on-prem |
| **Storage Gateway – Tape Gateway** | Thư viện băng ảo (**VTL**) cho phần mềm backup sẵn có, băng lưu ở S3/Glacier/Deep Archive | **Thay băng từ vật lý** mà không đổi phần mềm backup |
| **DataSync** | Chuyển dữ liệu **online**, nhanh, có lịch, giữ metadata/quyền; NFS, SMB, HDFS, object storage khác → S3/EFS/FSx (và giữa các dịch vụ AWS) | Di chuyển / đồng bộ định kỳ khối lượng lớn qua mạng (VPN/DX/Internet) |
| **Transfer Family** | Endpoint **SFTP/FTPS/FTP/AS2** managed, lưu vào S3/EFS | Đối tác chỉ biết gửi file qua SFTP |
| **Snow Family** (Snowball Edge…) | Thiết bị vật lý chuyển **offline** TB–PB, có compute ở edge | Mạng chậm/không có; (AWS đã thu hẹp dòng Snow – kiểm tra tình trạng hiện tại) |
| **AWS Backup** | Backup tập trung đa dịch vụ (EC2, EBS, RDS, Aurora, DynamoDB, EFS, FSx, S3…), policy, cross-Region/cross-account, **Vault Lock** | Tuân thủ backup tập trung (chi tiết tuần 6) |

**Ước lượng nhanh "online hay offline"**: 100 TB qua đường 1 Gbps dùng hết công suất ≈ 100×8×10¹²/10⁹ ≈ 800.000 giây ≈ **9–10 ngày** (thực tế lâu hơn). Nếu hạn chót gấp hoặc đường truyền yếu/chia sẻ → Snow; nếu đường DX 10 Gbps rảnh → DataSync vài ngày.

> 🎯 "Chuyển dữ liệu một lần, hàng trăm TB, mạng chậm" → **Snowball Edge**. "Đồng bộ định kỳ NFS on-prem lên S3/EFS" → **DataSync**. "App on-prem cần truy cập file như NFS nhưng lưu ở S3" → **S3 File Gateway**. "Thay hệ thống backup băng từ" → **Tape Gateway**.

---

## PHẦN B – DATABASE

### 4. Chọn database theo use case (bảng quan trọng nhất của tuần)

| Nhu cầu | Dịch vụ |
|---|---|
| Quan hệ OLTP, SQL, transaction, join | **RDS** (MySQL, PostgreSQL, MariaDB, Oracle, SQL Server, Db2), **Aurora** |
| Quan hệ hiệu năng cao, cloud-native, HA mạnh | **Aurora** (MySQL/PostgreSQL compatible) |
| Key-value/document, độ trễ ms ở mọi quy mô, serverless | **DynamoDB** |
| Cache trong bộ nhớ, session | **ElastiCache** (Valkey/Redis OSS, Memcached), **DAX** (riêng cho DynamoDB) |
| DB chính tương thích Redis, bền | **MemoryDB** |
| Data warehouse, OLAP, BI | **Redshift** |
| SQL ad-hoc trực tiếp trên S3, serverless | **Athena** |
| ETL / data catalog | **Glue** |
| Tìm kiếm full-text, log analytics | **OpenSearch Service** |
| Đồ thị (graph) – mạng xã hội, gợi ý, phát hiện gian lận | **Neptune** |
| Document tương thích MongoDB | **DocumentDB** |
| Wide-column tương thích Cassandra | **Keyspaces** |
| Chuỗi thời gian (IoT, metric) | **Timestream** |
| Sổ cái bất biến | QLDB (AWS đã dừng hỗ trợ – ưu tiên Aurora PostgreSQL + audit); đề cũ vẫn có thể nhắc |

> 💡 **Kinh nghiệm thực tế – câu hỏi để chọn DB**
> 1. Dữ liệu có quan hệ, cần join/transaction phức tạp, schema ổn định? → quan hệ (RDS/Aurora).
> 2. Truy cập chủ yếu theo **key đã biết**, cần scale lớn/độ trễ ổn định, mẫu truy vấn biết trước? → DynamoDB.
> 3. Truy vấn phân tích trên lượng lớn (quét, tổng hợp)? → Redshift/Athena, **đừng** chạy báo cáo nặng trên DB OLTP chính (dùng read replica hoặc đẩy sang warehouse).
> 4. "Thiết kế DynamoDB bắt đầu từ **access pattern**, thiết kế SQL bắt đầu từ **dữ liệu**." Nếu bạn chưa biết sẽ truy vấn thế nào, DynamoDB sẽ khó chịu.

---

### 5. Amazon RDS

#### 5.1 Tổng quan
- DB quan hệ managed: AWS lo cài đặt, patch OS/engine (trong **maintenance window**), backup, giám sát, failover. **Bạn không SSH** vào được (trừ **RDS Custom** cho Oracle/SQL Server cần quyền OS).
- Đặt trong **DB subnet group** (subnet ở ≥ 2 AZ, thường private). Bật `Publicly accessible = No`.
- Storage: gp3/io2, **Storage Auto Scaling** (tự tăng dung lượng khi sắp đầy, đặt trần).

#### 5.2 Multi-AZ – để **HA**

| | Multi-AZ **DB instance** | Multi-AZ **DB cluster** |
|---|---|---|
| Kiến trúc | 1 primary + **1 standby** ở AZ khác | 1 writer + **2 reader standby** ở 3 AZ |
| Sao chép | **Đồng bộ** | Bán đồng bộ (semi-sync) |
| Standby đọc được? | **Không** | **Có** |
| Failover | ~1–2 phút, **DNS endpoint giữ nguyên**, trỏ sang standby | Thường < 35 giây |
| Engine | Mọi engine | MySQL, PostgreSQL |

- Failover tự động khi: AZ sự cố, primary hỏng, đổi instance type, patch OS, bạn reboot "with failover".
- Backup chụp từ standby → giảm ảnh hưởng I/O lên primary.
- Chuyển Single-AZ → Multi-AZ: **không downtime** (snapshot ngầm → dựng standby).

#### 5.3 Read Replica – để **scale đọc**
- Sao chép **bất đồng bộ** → có **replication lag** (đọc có thể thấy dữ liệu cũ vài giây).
- Tới **15 replica** (MySQL/MariaDB/PostgreSQL; Oracle/SQL Server ít hơn – đề cũ hay ghi "5"). Mỗi replica có **endpoint riêng** → ứng dụng phải tự chia đọc/ghi.
- Có thể **cross-Region** (DR + đọc gần người dùng), có thể **promote** thành DB độc lập (thao tác một chiều).
- Replica có thể bật Multi-AZ cho chính nó.
- Data transfer replica **cùng Region miễn phí**, khác Region tính phí.

> ⚠️ **Hay nhầm số 1 của đề**: Multi-AZ = HA/DR (standby không phục vụ đọc ở kiểu instance). Read Replica = scale đọc. Muốn cả hai → Multi-AZ + read replica (hoặc Aurora).

#### 5.4 Backup & restore
- **Automated backup**: snapshot hằng ngày + **transaction log mỗi 5 phút** → **Point-in-Time Recovery** tới bất kỳ giây nào trong retention (**0–35 ngày**; 0 = tắt), RPO ~5 phút.
- **Manual snapshot**: giữ tới khi bạn xoá (kể cả sau khi xoá DB). Copy sang Region khác, chia sẻ cho account khác.
- **Restore luôn tạo DB instance MỚI** (endpoint mới) → ứng dụng phải trỏ sang (hoặc đổi DNS CNAME nội bộ).
- Xoá DB: chọn tạo **final snapshot** (khuyên dùng với prod).

#### 5.5 Bảo mật
- **Mã hoá at rest** (KMS) **chọn lúc tạo**; không bật thêm sau được. Replica/snapshot của DB mã hoá cũng mã hoá. DB chưa mã hoá → **snapshot → copy snapshot có mã hoá → restore** → chuyển ứng dụng.
- **In transit**: SSL/TLS (có thể ép bằng tham số `rds.force_ssl` / `require_secure_transport`).
- **IAM database authentication** (MySQL, PostgreSQL, MariaDB): đăng nhập bằng token IAM (hạn 15 phút) thay mật khẩu.
- Mật khẩu master: để RDS **quản lý trong Secrets Manager** (tự rotation).
- SG của DB chỉ cho phép SG của tầng app.

#### 5.6 Công cụ đi kèm
- **RDS Proxy**: connection pool managed, đặt giữa app và DB. Giảm cạn connection (đặc biệt **Lambda**), giảm thời gian failover (giữ kết nối client, tự chuyển sang DB mới), ép IAM auth + Secrets Manager. Chỉ truy cập trong VPC.
- **Blue/Green Deployments**: dựng môi trường "green" đồng bộ với prod để nâng cấp major version/đổi schema/tham số, **switchover thường dưới 1 phút**.
- **Performance Insights / Database Insights**, **Enhanced Monitoring** (metric OS mỗi 1 giây).
- **Parameter group** (tham số engine), **option group** (tính năng bổ sung, vd. Oracle TDE).

> 💡 **Kinh nghiệm thực tế – RDS**
> - DB dev/test **stop** được tối đa **7 ngày**, sau đó AWS **tự start lại** (và bắt đầu tính tiền). Muốn tắt lâu: snapshot rồi xoá, hoặc dùng lịch stop tự động.
> - Bảo trì: đặt maintenance window vào giờ thấp điểm; Multi-AZ giúp patch gần như không downtime (patch standby → failover → patch primary cũ).
> - "Too many connections" từ Lambda → **RDS Proxy**, không phải tăng instance.
> - Truy vấn báo cáo nặng làm chậm prod → chuyển sang **read replica** hoặc warehouse.
> - Đổi instance class gây vài phút gián đoạn (giảm còn vài chục giây với Multi-AZ). Lên kế hoạch.

---

### 6. Amazon Aurora

#### 6.1 Kiến trúc lưu trữ
- Tách **compute** và **storage**. Storage phân tán **6 bản sao qua 3 AZ**, quorum: **ghi cần 4/6**, **đọc cần 3/6** → vẫn ghi được khi mất 2 bản (cả 1 AZ), vẫn đọc khi mất 3 bản.
- Tự mở rộng theo bước 10 GiB tới **128 TiB** (AWS có thể đã nâng); tự sửa block hỏng (self-healing). Trả theo dung lượng dùng thật.
- Tương thích **MySQL** và **PostgreSQL** (không có Oracle/SQL Server).

#### 6.2 Replica & endpoint
- Tới **15 Aurora Replica** dùng **chung storage** → độ trễ sao chép thường **< 100 ms**, replica vừa scale đọc vừa là ứng viên failover.
- Failover tới replica thường **< 30 giây** (ưu tiên theo **failover tier** 0–15). Không có replica → Aurora tạo lại instance mới (lâu hơn nhiều).
- **Endpoint**:
  - **Cluster (writer) endpoint**: luôn trỏ tới writer hiện tại.
  - **Reader endpoint**: cân bằng kết nối qua các replica.
  - **Custom endpoint**: nhóm replica riêng (vd. replica cấu hình lớn cho báo cáo).
  - **Instance endpoint**: một instance cụ thể (ít dùng).
- **Aurora Auto Scaling**: tự thêm/bớt replica theo CPU/kết nối.

#### 6.3 Biến thể & tính năng
- **Aurora Serverless v2**: tự co giãn compute theo bước nhỏ (đơn vị **ACU**), scale trong vài giây; có thể trộn instance provisioned và serverless trong một cluster. Hợp tải **biến động/khó đoán**, dev/test, SaaS nhiều tenant.
- **Aurora Global Database**: 1 Region chính (ghi) + các Region phụ (chỉ đọc), sao chép ở tầng storage, độ trễ thường **< 1 giây**; promote Region phụ khi thảm hoạ với **RTO ~1 phút**, RPO tính bằng giây; *switchover* có kế hoạch không mất dữ liệu; *write forwarding* cho phép Region phụ gửi lệnh ghi về Region chính.
- **Backtrack** (MySQL): "tua" DB về thời điểm trước (tới 72 giờ) **không cần restore** – sửa lỗi DELETE nhầm trong vài phút.
- **Cloning**: copy-on-write, tạo bản sao DB lớn trong vài phút, chỉ trả phần thay đổi → tạo môi trường test từ prod.
- **Aurora I/O-Optimized**: không tính phí I/O, giá storage/compute cao hơn → lợi khi I/O chiếm > ~25% chi phí Aurora.
- **Zero-ETL** sang Redshift; **Machine Learning integration** (gọi SageMaker/Bedrock từ SQL); **Parallel Query**.

> 🎯 **Mẹo thi – RDS vs Aurora**: "HA tốt nhất, failover nhanh nhất, nhiều replica, tự mở rộng storage" → **Aurora**. "DR đa Region với RPO giây, RTO phút" → **Aurora Global Database**. "Tải không đoán trước, giảm chi phí khi nhàn rỗi" → **Aurora Serverless v2**. "Oracle/SQL Server" → **RDS** (Aurora không có). "Cần quyền OS/tuỳ biến engine" → **RDS Custom** hoặc EC2.

---

### 7. Amazon DynamoDB

#### 7.1 Mô hình dữ liệu
- NoSQL key-value/document, serverless, **đa AZ** sẵn, độ trễ **một chữ số ms** ở mọi quy mô.
- **Bảng → item → attribute**; không cần schema ngoài khoá chính.
- **Primary key**:
  - *Partition key* (simple) – vd. `userId`.
  - *Partition key + Sort key* (composite) – vd. `userId` + `orderDate` → `Query` các đơn của 1 user theo khoảng ngày.
- Partition key phải có **cardinality cao, phân phối đều** để tránh **hot partition** (vd. đừng dùng `status` = `ACTIVE/INACTIVE` hay ngày hiện tại làm partition key cho bảng ghi nhiều).
- Item tối đa **400 KB** → file lớn để S3, DynamoDB lưu con trỏ (key S3) + metadata.

#### 7.2 Capacity
| Mode | Cách tính | Dùng khi |
|---|---|---|
| **On-demand** | Trả theo request, tự scale tức thì | Tải **không đoán trước**, bùng nổ, bảng mới, dev/test |
| **Provisioned** (+ Auto Scaling) | Đặt **RCU/WCU**, trả theo giờ | Tải **ổn định/dự đoán được** → rẻ hơn đáng kể; có Reserved Capacity |

**Công thức** (phải tính được):
- **1 RCU** = 1 lần đọc **strongly consistent** item ≤ **4 KB**/giây, hoặc **2** lần đọc **eventually consistent**. Transactional read = 2 RCU.
- **1 WCU** = 1 lần ghi item ≤ **1 KB**/giây. Transactional write = 2 WCU.
- Làm tròn **lên** theo khối 4 KB (đọc) / 1 KB (ghi).

Ví dụ:
- 10 lần đọc strongly consistent/giây, item 6 KB → mỗi item = ⌈6/4⌉ = 2 RCU → **20 RCU**. Eventually consistent → **10 RCU**.
- 50 lần ghi/giây, item 2,5 KB → ⌈2,5⌉ = 3 WCU → **150 WCU**.

Vượt capacity → `ProvisionedThroughputExceededException` (SDK tự retry với backoff). Có **burst capacity** (tích luỹ 5 phút không dùng) và **adaptive capacity** (tự dồn capacity cho partition nóng) nhưng không thay được thiết kế key tốt.

#### 7.3 Đọc dữ liệu & index
- **GetItem** (theo khoá chính đầy đủ), **Query** (theo partition key + điều kiện sort key – **hiệu quả**), **Scan** (quét **toàn bảng** – tốn RCU, chậm; tránh trên bảng lớn, nếu bắt buộc dùng *parallel scan* lúc thấp điểm).
- **Eventually consistent** (mặc định, rẻ một nửa) vs **strongly consistent** (đọc mới nhất, chỉ trên bảng/LSI, không có trên GSI).

| | **GSI** (Global Secondary Index) | **LSI** (Local Secondary Index) |
|---|---|---|
| Khoá | Partition key + sort key **bất kỳ** | **Cùng partition key**, sort key khác |
| Tạo khi nào | **Bất cứ lúc nào** | **Chỉ lúc tạo bảng** |
| Số lượng | Tới 20/bảng (mặc định) | Tới 5/bảng |
| Đọc | Chỉ eventually consistent | Eventually hoặc strongly |
| Capacity | **Riêng** (phải cấp đủ WCU cho GSI, nếu không throttle ngược cả bảng chính) | Dùng chung với bảng |

#### 7.4 Tính năng
- **DynamoDB Streams**: luồng thay đổi item (giữ **24 giờ**) → Lambda (trigger), sao chép, cập nhật bảng tổng hợp, gửi thông báo. Tuỳ chọn ghi KEYS_ONLY / NEW_IMAGE / OLD_IMAGE / NEW_AND_OLD_IMAGES. (Có thể dùng thêm *Kinesis Data Streams for DynamoDB* khi cần giữ lâu hơn/nhiều consumer.)
- **TTL**: đặt attribute thời điểm hết hạn (epoch giây) → DynamoDB **tự xoá miễn phí** (không tốn WCU), nhưng **không tức thì** (có thể trễ tới vài ngày) → khi đọc vẫn nên lọc item đã hết hạn. Item xoá do TTL xuất hiện trong Streams → lưu trữ sang S3 trước khi mất.
- **Backup**: **PITR** (khôi phục tới từng giây trong tối đa **35 ngày**), **on-demand backup** (giữ tới khi xoá), AWS Backup. Restore luôn ra **bảng mới**.
- **Global Tables**: bảng đa Region **multi-active** (đọc/ghi ở mọi Region), sao chép thường < 1 giây, giải xung đột *last writer wins* (AWS đã bổ sung chế độ nhất quán mạnh đa Region – kiểm tra doc). Use case: ứng dụng toàn cầu, DR RPO/RTO gần 0.
- **Transactions**: ACID trên nhiều item/bảng (`TransactWriteItems`, `TransactGetItems`).
- **DAX**: cache trong bộ nhớ **tương thích API DynamoDB** (đổi client SDK, không sửa logic), độ trễ **micro-giây** cho đọc lặp; chạy trong VPC; chỉ cache đọc eventually consistent.
- **Export to S3** (cần PITR, không tốn RCU) → phân tích bằng Athena; **Import from S3**; zero-ETL sang Redshift/OpenSearch.
- **Table class Standard-IA**: storage rẻ hơn nhiều cho bảng lớn ít truy cập.
- Mã hoá **mặc định** at rest (AWS owned key / AWS managed / CMK).
- **Fine-grained access**: IAM condition `dynamodb:LeadingKeys` → mỗi user chỉ đọc/ghi item có partition key = ID của họ (kết hợp Cognito Identity Pool).

> 💡 **Kinh nghiệm thực tế – DynamoDB**
> - Viết ra **danh sách access pattern** trước ("lấy đơn của user X theo ngày", "lấy đơn theo trạng thái"…) rồi mới thiết kế PK/SK/GSI. Thêm GSI sau được, nhưng đổi khoá chính bảng là phải migrate.
> - Bảng mới hoặc chưa rõ tải → **on-demand**; khi tải ổn định vài tuần → cân nhắc provisioned + auto scaling để giảm chi phí.
> - `Scan` + `FilterExpression` vẫn **tính RCU cho toàn bộ dữ liệu quét**, không phải chỉ phần được trả về.
> - Lab03 cho bạn thử GSI, TTL, PITR – để ý TTL không xoá ngay.

---

### 8. ElastiCache & MemoryDB

| | **Valkey / Redis OSS** | **Memcached** |
|---|---|---|
| Multi-AZ, replica, **failover tự động** | Có | Không |
| Persistence / backup / restore | Có (snapshot) | **Không** |
| Kiểu dữ liệu | String, hash, list, set, **sorted set**, stream, pub/sub, geo… | Chỉ key-value đơn giản |
| Sharding | Có (*cluster mode enabled*) | Có (phía client) |
| Đa luồng | (Redis đơn luồng chính) | **Có** |
| Đa Region | **Global Datastore** | Không |
| Dùng khi | Cache + **session** + **leaderboard** (sorted set) + rate limiting + pub/sub, cần HA | Cache đơn giản, mất dữ liệu cũng không sao, scale ngang nhiều node |

- **ElastiCache Serverless**: không cần chọn node/shard, tự scale.
- Bảo mật: chạy trong VPC, SG, **in-transit/at-rest encryption**, **AUTH/RBAC** (Valkey/Redis).
- **MemoryDB**: tương thích Redis/Valkey nhưng **bền** (transaction log đa AZ) → dùng làm **DB chính** in-memory, không chỉ cache.

**Chiến lược cache**
| Chiến lược | Cách làm | Ưu | Nhược |
|---|---|---|---|
| **Lazy loading / cache-aside** | Đọc cache; miss → đọc DB → ghi vào cache | Chỉ cache dữ liệu thực sự dùng; cache hỏng app vẫn chạy | Miss lần đầu chậm (3 bước); dữ liệu có thể cũ |
| **Write-through** | Ghi DB đồng thời cập nhật cache | Cache luôn mới | Ghi chậm hơn; cache chứa cả dữ liệu không ai đọc |
| **TTL** | Đặt hạn cho key | Giới hạn độ cũ và dung lượng | Chọn TTL hợp lý là nghệ thuật |

> 💡 **Kinh nghiệm thực tế**: luôn đặt **TTL** cho key (kể cả write-through) để tránh dữ liệu "mồ côi"; cẩn thận **thundering herd** (key hot hết hạn, hàng nghìn request cùng đập DB) – thêm jitter cho TTL hoặc khoá "chỉ một request được nạp lại cache". Theo dõi `Evictions` và `CacheHitRate`.

---

### 9. Phân tích dữ liệu: Redshift, Athena, Glue & bạn bè

#### 9.1 Redshift
- Data warehouse **columnar**, **MPP** (xử lý song song nhiều node), SQL (dựa trên PostgreSQL), cho **OLAP/BI** – tổng hợp hàng tỷ dòng.
- Kiến trúc: leader node + compute node; **RA3** tách storage (Redshift Managed Storage trên S3) → scale compute độc lập. **Redshift Serverless** (trả theo RPU-giờ khi chạy).
- **Spectrum**: query dữ liệu ngay trên S3 (data lake) kết hợp với bảng trong Redshift.
- **Concurrency Scaling** (thêm cluster tạm khi nhiều truy vấn đồng thời), **Data Sharing** (chia sẻ dữ liệu live giữa cluster/account), **Zero-ETL** từ Aurora/RDS/DynamoDB.
- HA/DR: snapshot tự động/thủ công lên S3, **copy snapshot sang Region khác** tự động, **Multi-AZ** (RA3).
- Nạp dữ liệu: **`COPY` từ S3** (song song, nhanh nhất – chia nhiều file), Firehose, DMS, zero-ETL. Tránh `INSERT` từng dòng.

#### 9.2 Athena
- **Serverless SQL trên S3** (engine Trino/Presto), trả theo **dữ liệu quét** (~5 USD/TB).
- Giảm chi phí và tăng tốc: định dạng **cột (Parquet/ORC)** + **nén** + **partition** (theo `year/month/day`) + chỉ `SELECT` cột cần. Chuyển CSV → Parquet bằng **CTAS** hoặc Glue.
- **Workgroups** để giới hạn dữ liệu quét/chi phí theo team. **Federated query** (qua Lambda connector) tới RDS, DynamoDB, on-prem…
- Use case: query log (ALB, CloudTrail, VPC Flow Logs, S3 access logs), ad-hoc, data lake.

#### 9.3 Glue, Lake Formation, EMR, OpenSearch, QuickSight
- **Glue**: **Data Catalog** (metadata bảng, dùng chung cho Athena/Redshift Spectrum/EMR), **Crawler** (tự đọc S3 và tạo bảng), **ETL job** serverless (Spark/Python), job bookmarks (chỉ xử lý dữ liệu mới), **DataBrew** (làm sạch dữ liệu không code).
- **Lake Formation**: dựng & **quản trị quyền** data lake ở mức **cột/hàng/ô**, tập trung trên Glue Catalog.
- **EMR**: Hadoop/Spark/Hive/Presto managed trên EC2 (hoặc EMR Serverless, EMR on EKS). Mẹo chi phí: master/core On-Demand, **task node Spot**.
- **OpenSearch Service**: tìm kiếm full-text, log analytics + Dashboards; thường nhận dữ liệu từ Firehose/DynamoDB Streams. Không dùng làm DB chính.
- **QuickSight**: BI dashboard serverless (engine **SPICE** in-memory), nhúng dashboard vào app.

**Kiến trúc data lake điển hình**:
`Nguồn → Kinesis Firehose / DMS / DataSync → S3 (raw) → Glue ETL → S3 (Parquet, partition) → Glue Catalog → Athena / Redshift Spectrum / EMR → QuickSight`, quyền bằng Lake Formation.

> 🎯 "SQL trên S3, không hạ tầng, trả theo truy vấn" → **Athena**. "Báo cáo BI phức tạp, join lớn, nhiều người dùng đồng thời, dữ liệu có cấu trúc" → **Redshift**. "Tìm kiếm full-text" → **OpenSearch**. "Spark/Hadoop" → **EMR** (hoặc Glue cho ETL serverless). "Phân quyền cột/hàng cho data lake" → **Lake Formation**.

---

### 10. Di chuyển database
- **DMS (Database Migration Service)**: replication instance đọc từ source endpoint, ghi vào target endpoint. **Full load + CDC** (sao chép thay đổi liên tục) → cắt chuyển với downtime tối thiểu. Hỗ trợ **đồng nhất** (MySQL → RDS MySQL) và **khác engine** (Oracle → Aurora PostgreSQL). Có **DMS Serverless**.
- **SCT (Schema Conversion Tool)** / **DMS Schema Conversion**: chuyển schema, stored procedure khi **khác engine**. Đồng nhất thì không cần.
- Có thể dùng DMS để nạp liên tục từ DB vào S3/Kinesis/Redshift (CDC cho data lake).
- **Application Migration Service (MGN)**: lift-and-shift **server** (sao chép block liên tục).
- Native tools vẫn hợp lệ: `mysqldump`, `pg_dump`, backup `.bak` SQL Server lên S3 rồi restore vào RDS…

> 💡 **Kinh nghiệm thực tế**: migration DB lớn thường = **restore bản backup native làm "full load"** (nhanh hơn) rồi dùng **DMS CDC** bắt kịp phần thay đổi; kiểm tra dữ liệu (DMS data validation); cắt chuyển vào giờ thấp điểm. Dịch chuyển dữ liệu nhiều TB qua mạng chậm → Snowball cho full load + DMS CDC.

---

## Bẫy thường gặp
1. Multi-AZ ≠ scale đọc. **Read replica** mới scale đọc (trừ Multi-AZ DB cluster có reader).
2. "DR cross-Region cho RDS/Aurora" → cross-Region read replica / **Aurora Global Database**.
3. "Nhiều EC2 Linux dùng chung file" → **EFS**; "Windows SMB/AD" → **FSx for Windows**; "HPC/ML" → **FSx for Lustre**.
4. "Lưu trữ lâu dài, truy cập hiếm, rẻ nhất" → **Glacier Deep Archive**; "mẫu truy cập khó đoán" → **Intelligent-Tiering**; "cần lấy ngay dù hiếm truy cập" → **Glacier Instant Retrieval / Standard-IA**.
5. "Không được xoá/sửa trong N năm (compliance), kể cả admin" → **S3 Object Lock – Compliance mode**.
6. "Giảm độ trễ đọc DynamoDB còn micro-giây, ít sửa code" → **DAX**. "Cache cho RDS" → **ElastiCache**.
7. "Tải DynamoDB bùng nổ, không đoán trước" → **On-demand**.
8. "Query log S3 bằng SQL, không hạ tầng" → **Athena**; "kho dữ liệu phân tích lớn" → **Redshift**.
9. Mã hoá RDS phải bật khi tạo; muốn mã hoá DB có sẵn phải đi qua snapshot → copy có mã hoá → restore.
10. "Chuyển 100 TB, mạng chậm" → Snow Family; "online, lặp lại" → DataSync.
11. "Lambda làm cạn connection RDS" → **RDS Proxy**.
12. "Khôi phục DB về 10 phút trước khi xoá nhầm" → **PITR** (RDS/DynamoDB) hoặc **Backtrack** (Aurora MySQL, nhanh nhất).
13. "Dữ liệu dễ tái tạo, ít truy cập, rẻ" → **S3 One Zone-IA** (nhưng không dùng cho dữ liệu duy nhất).
14. "Cần upload file > 5 GB" → **multipart upload**; "upload từ khắp thế giới chậm" → **Transfer Acceleration**.
15. "Session người dùng cho ứng dụng nhiều instance, HA" → **ElastiCache Redis/Valkey** hoặc **DynamoDB**.
16. "Bản sao S3 ở Region khác phải xuất hiện trong 15 phút (SLA)" → **CRR + S3 RTC**.
17. "Thay băng từ, giữ nguyên phần mềm backup" → **Tape Gateway**.

---

## Tự kiểm tra

1. Khác biệt Multi-AZ và Read Replica ở RDS (đồng bộ/bất đồng bộ, mục đích)?
2. Bạn có dữ liệu log truy cập hiếm sau 30 ngày, phải giữ 7 năm với chi phí thấp nhất và có thể chờ 12 giờ để lấy. Dùng class nào và cấu hình gì?
3. LSI và GSI khác nhau thế nào? Cái nào thêm sau khi tạo bảng được?
4. Làm sao đảm bảo mọi truy cập S3 phải qua HTTPS?
5. Aurora lưu bao nhiêu bản sao ở bao nhiêu AZ? Mất bao nhiêu bản thì vẫn ghi được?
6. Dùng ElastiCache nào khi cần failover tự động và persistence?
7. Có DB RDS chưa mã hoá, cần mã hoá. Các bước?
8. Muốn 2 Region cùng đọc/ghi DynamoDB với độ trễ thấp?
9. Tính RCU: 20 lần đọc strongly consistent/giây, item 9 KB. Nếu eventually consistent?
10. Tính WCU: 100 lần ghi/giây, item 1,5 KB.
11. Bật CRR từ bucket A sang B. Object có trong A từ trước có được sao chép không? Nếu ai đó xoá vĩnh viễn một version ở A thì B có bị xoá không?
12. Ứng dụng upload ảnh từ trình duyệt; bạn không muốn ảnh đi qua server. Thiết kế?
13. Athena query tốn quá nhiều tiền. Ba cách giảm?
14. Ứng dụng có 50.000 file video cần chia sẻ cho 30 instance Windows dùng AD. Chọn gì?
15. Một DB Aurora MySQL bị chạy lệnh `DELETE` thiếu `WHERE` 5 phút trước. Cách khôi phục nhanh nhất?

<details><summary>Đáp án</summary>

1. Multi-AZ: đồng bộ, HA/failover tự động, standby không để đọc (kiểu instance). Read Replica: bất đồng bộ, scale đọc, endpoint riêng, có thể cross-Region/promote.
2. Lifecycle: Standard → **Glacier Deep Archive** sau 30 ngày; expiration sau ~2.555 ngày (7 năm). (Deep Archive lấy Standard ~12 giờ.) Nếu cần chống xoá: thêm Object Lock.
3. LSI: cùng partition key, khác sort key, chỉ tạo lúc tạo bảng, cho phép strongly consistent. GSI: khoá bất kỳ, thêm sau được, capacity riêng, chỉ eventually consistent.
4. Bucket policy `Deny` `s3:*` khi `aws:SecureTransport = false`.
5. 6 bản sao qua 3 AZ. Ghi cần 4/6 → mất tối đa 2 bản vẫn ghi được (đọc cần 3/6).
6. ElastiCache for Valkey/Redis OSS (Multi-AZ + replica + snapshot).
7. Snapshot → copy snapshot bật encryption (chọn KMS key) → restore thành instance mới → chuyển ứng dụng sang endpoint mới.
8. DynamoDB Global Tables.
9. ⌈9/4⌉ = 3 RCU/lần × 20 = **60 RCU**. Eventually consistent: **30 RCU**.
10. ⌈1,5⌉ = 2 WCU/lần × 100 = **200 WCU**.
11. Không – dữ liệu cũ cần **S3 Batch Replication**. Xoá version cụ thể **không** được sao chép (B vẫn giữ).
12. API (Lambda) cấp **pre-signed URL** → trình duyệt PUT thẳng lên S3 → S3 Event → xử lý (Lambda/SQS).
13. Chuyển sang **Parquet/ORC** + nén; **partition** dữ liệu và lọc theo partition; chỉ chọn cột cần; giới hạn bằng workgroup.
14. **FSx for Windows File Server** (SMB + AD), Multi-AZ.
15. **Aurora Backtrack** (nếu đã bật) – tua lại vài phút, không cần restore; nếu không có backtrack → PITR ra cluster mới rồi lấy dữ liệu về.
</details>

## Tài liệu nên đọc thêm
- FAQ: S3, EFS, FSx, RDS, Aurora, DynamoDB, ElastiCache, Storage Gateway.
- Doc: "Amazon S3 storage classes", "Managing your storage lifecycle", "Replicating objects", "Aurora DB cluster – high availability", "DynamoDB read/write capacity modes", "Best practices for designing and using partition keys effectively", "Caching strategies" (ElastiCache).
- Well-Architected: Reliability pillar – phần dữ liệu & backup; Performance Efficiency – "Data management".
