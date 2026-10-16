Đặc điểm quan trọng nhất: Cách ly dữ liệu giữa các tenant (tenant isolation).

Lỗi nghiêm trọng nhất: Rò rỉ dữ liệu giữa các tenant.

Định nghĩa: tenant A không thể làm bất kỳ thao tác nào sau đây trên dữ liệu của tenant B:
- Đọc: xem, tìm kiếm, liệt kê, xuất (export) dữ liệu.
- Ghi: tạo mới, sửa, xóa dữ liệu.
- Suy ra gián tiếp: đoán sự tồn tại qua ID (ví dụ đổi /orders/123 thành /orders/124 thì phải báo “không tìm thấy”, không phải “không có quyền”), qua số liệu thống kê chung, hoặc qua thông báo lỗi.

Đặc điểm: Cách ly phải áp dụng ở mọi nơi dữ liệu đi qua, không chỉ database:
- Cache (khóa cache phải có tenant_id).
- File lưu trữ (thư mục/bucket riêng hoặc tiền tố theo tenant).
- Log, báo cáo, search index, hàng đợi tin nhắn.
- Backup/khôi phục: khôi phục cho tenant này không được ảnh hưởng tenant khác.

Yêu cầu:
1. Cách lý ở database (Postgres)
- Các câu lệnh cần cách ly:

| Nhóm | Câu lệnh | Cần cách ly? | Vì sao |
|---|---|---|---|
| **DDL** | `CREATE TABLE` | Có | Cấu trúc bảng dùng chung cho mọi tenant, tenant không được tự tạo hay thay đổi. |
| | `ALTER TABLE` | Có | Đổi cột hoặc ràng buộc ảnh hưởng đến dữ liệu của tất cả tenant. |
| | `DROP` | Có | Xóa bảng, schema hay index sẽ mất dữ liệu của mọi tenant. |
| | `TRUNCATE` | Có | Xóa toàn bộ dòng của bảng, không phân biệt tenant. |
| | `CREATE INDEX` | Có | Khóa bảng khi tạo và có thể làm chậm tenant khác. |
| | `CREATE VIEW` | Có | View có thể đọc dữ liệu vượt phạm vi tenant. |
| | `CREATE FUNCTION / PROCEDURE / TRIGGER` | Có | Code chạy trong database có thể đọc hoặc ghi dữ liệu mọi tenant. |
| | `CREATE POLICY / ALTER POLICY / DROP POLICY` | Có | Policy chính là hàng rào cách ly, sửa được là phá được. |
| | `CREATE SCHEMA / CREATE DATABASE` | Có | Là ranh giới cách ly, tenant không được tự tạo hay mở rộng. |
| | `COMMENT` | Không | Chỉ là ghi chú metadata, không chứa dữ liệu tenant. |
| **DML** | `INSERT` | Có | Tránh ghi dữ liệu vào sai tenant. |
| | `UPDATE` | Có | Tránh sửa dòng của tenant khác, hoặc đổi `tenant_id` để "chuyển" dòng sang tenant khác. |
| | `DELETE` | Có | Tránh xóa dữ liệu của tenant khác. |
| | `MERGE` | Có | Gồm cả đọc lẫn ghi (insert, update, delete) nên rủi ro của cả ba. |
| | `COPY` | Có | Nhập hoặc xuất hàng loạt, dễ kéo theo dữ liệu của tenant khác. |
| **DQL** | `SELECT` | Có | Tránh đọc dữ liệu của tenant khác. |
| | `SELECT ... FOR UPDATE / FOR SHARE` | Có | Khóa dòng của tenant khác sẽ chặn hoạt động của họ. |
| | `WITH` (CTE) | Có | Là truy vấn đọc (hoặc ghi) như bình thường. |
| | `EXPLAIN [ANALYZE]` | Có | Kế hoạch thực thi và thống kê có thể làm lộ thông tin về dữ liệu của tenant khác. |
| **DCL** | `GRANT` | Có | Cấp quyền sai có thể mở đường truy cập chéo tenant. |
| | `REVOKE` | Có | Thu hồi sai có thể làm mất quyền của tenant khác, hoặc để sót quyền thừa. |
| | `CREATE ROLE / ALTER ROLE / DROP ROLE` | Có | Role có thuộc tính đặc biệt (superuser, bypass RLS) sẽ xuyên qua mọi cách ly. |
| | `ALTER DEFAULT PRIVILEGES` | Có | Quyết định quyền mặc định của các đối tượng tạo sau này. |
| **TCL** | `BEGIN / COMMIT / ROLLBACK` | Không | Chỉ điều khiển ranh giới transaction của chính phiên đó. |
| | `SAVEPOINT / ROLLBACK TO / RELEASE` | Không | Tương tự, chỉ tác động trong transaction của chính mình. |
| | `SET TRANSACTION` | Không | Chỉ đổi mức cô lập hoặc chế độ của transaction hiện tại. |
| | `SET / SET LOCAL` | Có | Nếu lưu `tenant_id` trong biến phiên, giá trị còn sót sẽ làm phiên sau dùng nhầm tenant. |
| | `PREPARE TRANSACTION / COMMIT PREPARED / ROLLBACK PREPARED` | Có | Transaction tồn tại độc lập với kết nối, phiên khác có thể commit hoặc hủy nhầm, và nó giữ khóa lâu dài. |

- Các vai trò:

| Vai trò | Mức độ | Lý do |
|---|---|---|
| **Superuser / admin hạ tầng** (`postgres`) | Bắt buộc | Quản trị cluster, tạo extension, backup. Chỉ dùng thủ công khi cần, tuyệt đối không dùng cho ứng dụng vì bỏ qua mọi RLS. |
| **Owner của schema/bảng** (`app_owner`) | Bắt buộc | Sở hữu đối tượng và là chủ thể duy nhất được chạy DDL. Tách khỏi role ứng dụng để role ứng dụng không tự sửa được policy. |
| **Migration** (`app_migrator`) | Bắt buộc | Chạy DDL khi triển khai phiên bản mới (tạo bảng, bật RLS, tạo policy). Chỉ hoạt động trong pipeline triển khai. |
| **Ứng dụng** (`app_user`) | Bắt buộc | Role mà ứng dụng dùng để chạy DML/DQL thay mặt tenant. Không phải owner, không superuser, không `BYPASSRLS`, nên bị RLS áp dụng đầy đủ. |
| **Đọc-chỉ cho báo cáo** (`app_readonly`) | Không bắt buộc, nhưng cần trong tương lai | Phục vụ báo cáo, BI, replica đọc mà không có quyền ghi. Vẫn bị RLS để không lộ dữ liệu chéo tenant. |
| **Quản trị nền tảng** (`platform_admin`, `BYPASSRLS`) | Không bắt buộc, nhưng cần trong tương lai | Dành cho hỗ trợ kỹ thuật, tác vụ xuyên tenant (thống kê toàn hệ thống, gộp dữ liệu, chuyển tenant). Cần có audit log vì bỏ qua cách ly. |
| **Sao lưu / phục hồi** (`backup`) | Không bắt buộc, nhưng cần trong tương lai | Chạy `pg_dump`/`pg_basebackup` với quyền tối thiểu, tách khỏi superuser. |
| **Giám sát** (`monitor`, dùng `pg_monitor`) | Không bắt buộc, nhưng cần trong tương lai | Đọc thống kê hiệu năng (`pg_stat_*`) mà không cần đọc dữ liệu tenant. |
| **Replication** (`replicator`) | Không bắt buộc, nhưng cần trong tương lai | Phục vụ replica/HA khi hệ thống lớn lên. |
| **Role riêng cho từng tenant** (`tenant_<id>`) | Không bắt buộc, nhưng cần trong tương lai | Chỉ cần nếu chuyển sang mô hình mỗi tenant một schema/database, hoặc tenant lớn đòi cách ly mạnh hơn. |
| **Audit / bảo mật** (`auditor`) | Không bắt buộc, nhưng cần trong tương lai | Đọc nhật ký truy cập để kiểm tra tuân thủ, tách biệt khỏi người vận hành. |

- Các vai trò cần cách ly:

| Vai trò | Cần cách ly? | Lý do |
|---|---|---|
| `app_user` | Có | Chạy DML/DQL thay mặt tenant, nên phải bị RLS chặn truy cập chéo tenant. |
| `app_owner` / `app_migrator` | Có | Có `FORCE ROW LEVEL SECURITY` nên owner cũng bị RLS. Hai role này chỉ làm DDL, không nên đọc hay ghi dữ liệu tenant. |
| `postgres` (superuser) | Không | Superuser luôn bỏ qua RLS, không thể cách ly bằng policy. Chỉ kiểm soát bằng cách hạn chế dùng thủ công và ghi log. |

- Các vai trò với đối tượng sử dụng:

| Vai trò | Ai dùng |
|---|---|
| `app_user| service |
| `app_migrator` (qua `app_owner`) | Pipeline triển khai/migration của service. |
| `postgres` | DBA, dùng thủ công khi cần. |
| `app_owner` | Không đăng nhập trực tiếp, chỉ là chủ sở hữu đối tượng. |

- Phân quyền với các câu lệnh:

| Nhóm | Câu lệnh | Vai trò được phép |
|---|---|---|
| **DDL** | `CREATE TABLE`, `ALTER TABLE`, `DROP` | `app_migrator` (qua `app_owner`), `postgres` |
| | `TRUNCATE` | `app_migrator` (qua `app_owner`), `postgres` |
| | `CREATE INDEX` | `app_migrator` (qua `app_owner`), `postgres` |
| | `CREATE VIEW`, `CREATE FUNCTION / PROCEDURE / TRIGGER` | `app_migrator` (qua `app_owner`), `postgres` |
| | `CREATE POLICY / ALTER POLICY / DROP POLICY` | `app_migrator` (qua `app_owner`), `postgres` |
| | `CREATE SCHEMA` | `app_migrator`, `postgres` |
| | `CREATE DATABASE` | `postgres` |
| | `COMMENT` | `app_migrator` (qua `app_owner`), `postgres` |
| **DML** | `INSERT`, `UPDATE`, `DELETE`, `MERGE` | `app_user` |
| | `COPY ... FROM STDIN` / `COPY (SELECT ...) TO STDOUT` | `app_user` |
| **DQL** | `SELECT`, `SELECT ... FOR UPDATE / FOR SHARE`, `WITH` | `app_user` |
| | `EXPLAIN [ANALYZE]` | `app_migrator`, `postgres` (`app_user` chỉ ở môi trường dev) |
| **DCL** | `GRANT`, `REVOKE` | `app_migrator` (qua `app_owner`), `postgres` |
| | `ALTER DEFAULT PRIVILEGES` | `app_migrator` (qua `app_owner`), `postgres` |
| | `CREATE ROLE / ALTER ROLE / DROP ROLE` | `postgres` |
| **TCL** | `BEGIN / COMMIT / ROLLBACK` | Cả 4 vai trò |
| | `SAVEPOINT / ROLLBACK TO / RELEASE` | Cả 4 vai trò |
| | `SET TRANSACTION` | Cả 4 vai trò |
| | `SET LOCAL app.tenant_id` (và `SET` / `set_config`) | `app_user` |
| | `PREPARE TRANSACTION / COMMIT PREPARED / ROLLBACK PREPARED` | Không vai trò nào (không dùng) |

Giải pháp:
- Nhiều tenant nhỏ và ưu tiên chi phí phát triển nên giải pháp 2 là hợp lý.

| Giải pháp | Mức cách ly | Ưu điểm | Trade-off |
|---|---|---|---|
| **1. Chung bảng + `tenant_id` + điều kiện ở ứng dụng** | Yếu | Đơn giản, rẻ nhất, dễ migrate, hỗ trợ hàng chục nghìn tenant. | Chỉ cần quên một `WHERE tenant_id` là rò rỉ dữ liệu. Không có hàng rào ở database. |
| **2. Chung bảng + `tenant_id` + RLS** | Trung bình đến khá | Database ép buộc cách ly, code ứng dụng sót cũng không lộ. Vẫn rẻ và dễ mở rộng số tenant. | Phải quản lý biến phiên (`SET LOCAL`) cẩn thận với connection pool. RLS thêm chi phí truy vấn. Superuser, `BYPASSRLS` và owner (nếu không `FORCE`) bỏ qua được. Noisy neighbor vẫn còn. |
| **3. Mỗi tenant một schema** | Khá | Tách rõ bảng, index, dễ backup/xóa/di chuyển từng tenant. Có thể đặt quyền theo schema. | Số schema lớn (hàng nghìn) làm catalog phình, migration phải chạy lặp trên từng schema, pg_dump và autovacuum chậm. Connection pool khó dùng `search_path` theo tenant. |
| **4. Mỗi tenant một database (cùng cluster)** | Mạnh | Cách ly gần như hoàn toàn, role và quyền kết nối riêng, backup/restore theo tenant dễ. | Mỗi database có kết nối và bộ nhớ riêng, không truy vấn chéo được, migration chạy N lần. Không phù hợp khi có nhiều tenant nhỏ. |
| **5. Mỗi tenant một cluster/instance riêng** | Rất mạnh | Cách ly tài nguyên (CPU, RAM, I/O), không còn noisy neighbor, tùy chỉnh cấu hình và phiên bản theo tenant, đáp ứng yêu cầu tuân thủ khắt khe. | Chi phí và công vận hành cao nhất, khó mở rộng số tenant, cần công cụ tự động hóa (provisioning, giám sát, nâng cấp). |
| **6. Hybrid (phân tầng)** | Linh hoạt | Tenant nhỏ dùng chung bảng + RLS, tenant lớn hoặc nhạy cảm tách schema/database/cluster riêng. Cân bằng chi phí và cách ly. | Phức tạp nhất: phải có lớp định tuyến tenant, quy trình di chuyển tenant giữa các tầng, và nhiều cách vận hành song song. |
| **7. Sharding theo tenant** (ví dụ Citus) | Tùy mô hình bên dưới | Mở rộng ngang, tenant được phân bổ vào các node, truy vấn theo tenant chỉ chạm một shard. | Không tự cách ly dữ liệu, vẫn cần RLS hoặc điều kiện `tenant_id`. Thêm độ phức tạp hạ tầng, truy vấn chéo shard và transaction phân tán bị hạn chế. |

- Đặc điểm cần có của các vai trò

| Vai trò | Tạo ở đâu | Khi nào | Do ai |
|---|---|---|---|
| `postgres` | Cấp **cluster** | Lúc khởi tạo cluster (`initdb`), hoặc là tài khoản master của dịch vụ managed | Hệ thống tự tạo |
| `app_owner` | Cấp **cluster** (role dùng chung mọi database) | Bước bootstrap, trước migration đầu tiên | `postgres` (DBA hoặc script hạ tầng như Terraform/Ansible) |
| `app_migrator` | Cấp cluster | Bước bootstrap, sau `app_owner` | `postgres` |
| `app_user` | Cấp cluster | Bước bootstrap, sau khi `app_owner` tạo xong schema | `postgres` |

    - Thuộc tính role (role attributes)

| Thuộc tính | `postgres` | `app_owner` | `app_migrator` | `app_user` |
|---|---|---|---|---|
| `LOGIN` | Có (dùng thủ công) | **NOLOGIN** | Có | Có |
| `SUPERUSER` | Có | **NOSUPERUSER** | **NOSUPERUSER** | **NOSUPERUSER** |
| `BYPASSRLS` | Có (mặc định của superuser) | **NOBYPASSRLS** | **NOBYPASSRLS** | **NOBYPASSRLS** |
| `CREATEDB` | Có | NOCREATEDB | NOCREATEDB | NOCREATEDB |
| `CREATEROLE` | Có | NOCREATEROLE | NOCREATEROLE | NOCREATEROLE |
| `REPLICATION` | Có | NOREPLICATION | NOREPLICATION | NOREPLICATION |
| `INHERIT` | Có | Có | Có (để thừa hưởng quyền `app_owner`) | Có, nhưng không là thành viên role nào |
| `CONNECTION LIMIT` | Không giới hạn | Không áp dụng | Thấp (1-2) | Đặt theo kích thước pool |
| Mật khẩu | `scram-sha-256` | Không cần | `scram-sha-256` hoặc chứng chỉ | `scram-sha-256` hoặc chứng chỉ |
| `VALID UNTIL` | Không bắt buộc | Không áp dụng | Nên đặt, xoay vòng định kỳ | Nên đặt, xoay vòng định kỳ |

    - Quan hệ thành viên và quyền cần có

| Yêu cầu | Áp dụng cho | Lý do |
|---|---|---|
| `app_migrator` là thành viên `app_owner` (`GRANT app_owner TO app_migrator`) | `app_migrator` | Chạy DDL bằng quyền owner mà không cần đăng nhập `app_owner`. |
| `app_user` **không** là thành viên của bất kỳ role nào | `app_user` | Tránh thừa hưởng quyền owner qua `INHERIT`. |
| Không cấp `pg_read_all_data`, `pg_write_all_data` | `app_user` | Cấp quyền đọc/ghi mọi bảng, vượt kiểm soát `GRANT` từng bảng. |
| Không cấp `pg_read_server_files`, `pg_write_server_files`, `pg_execute_server_program` | `app_user`, `app_migrator` | Cho đọc/ghi file hoặc chạy lệnh trên server, vượt khỏi database. |
| Không cấp `pg_monitor`, `pg_read_all_stats`, `pg_signal_backend`, `pg_checkpoint`, `pg_maintain` | `app_user` | Lộ thống kê/câu lệnh của tenant khác, hoặc can thiệp vào phiên khác. |
| `app_owner` sở hữu mọi bảng, view, function, sequence | `app_owner` | Để `app_user` không phải owner, nên không tự `ALTER` hay tắt RLS được. |
| `ALTER TABLE ... FORCE ROW LEVEL SECURITY` | Bảng do `app_owner` sở hữu | Owner cũng bị RLS. |
| `REVOKE ALL ON DATABASE ... FROM PUBLIC`, rồi chỉ `GRANT CONNECT` cho role cần | Database | Mặc định `PUBLIC` được `CONNECT` và `TEMP`. |
| `REVOKE TEMP ON DATABASE ... FROM PUBLIC` | `app_user` | Chặn bảng tạm sót lại trong connection pool. |
| `REVOKE CREATE ON SCHEMA public FROM PUBLIC`, `GRANT USAGE` (không `CREATE`) trên schema service cho `app_user` | Schema | Role ứng dụng không được tạo đối tượng. |
| Chỉ `GRANT SELECT, INSERT, UPDATE, DELETE` trên bảng, `USAGE` trên sequence nếu có | `app_user` | Không `TRUNCATE`, `REFERENCES`, `TRIGGER`. |
| Column-level `GRANT UPDATE (...)` không gồm `tenant_id` | `app_user` | Chặn đổi `tenant_id` của dòng. |
| `ALTER ROLE app_user SET row_security = on` | `app_user` | Nếu RLS bị tắt, truy vấn báo lỗi thay vì lộ dữ liệu. |
| `ALTER DEFAULT PRIVILEGES FOR ROLE app_owner ...` | `app_owner` | Đối tượng tạo sau này tự có đúng quyền hẹp cho `app_user`. |
| `pg_hba.conf` giới hạn IP/phương thức xác thực theo từng role | Cluster | `postgres` và `app_migrator` chỉ cho kết nối từ mạng quản trị/CI, không từ mạng ứng dụng. |

Các trường hợp:
- Không phải bảng nào cũng có tenant_id

| Loại bảng | Có `tenant_id`? | Ví dụ / Lý do |
|---|---|---|
| **Dữ liệu tham chiếu dùng chung** | Không | Quốc gia, tiền tệ, múi giờ, mã tỉnh/thành. Mọi tenant dùng chung, dữ liệu không thuộc riêng ai. |
| **Cấu hình/danh mục của nền tảng** | Không | Gói dịch vụ (plans), tính năng (feature flags) toàn hệ thống, mẫu email mặc định. |
| **Bảng chính của tenant** | Không (nhưng chính nó là tenant) | Bảng `tenants` có `id` chính là tenant id. |
| **Bảng con chỉ truy cập qua bảng cha** | Không bắt buộc | `order_items` có thể suy ra tenant từ `orders`. Tuy nhiên với RLS vẫn nên thêm `tenant_id` để policy lọc trực tiếp, không phải join. |
| **Bảng nối (many-to-many)** | Không bắt buộc | Bảng nối giữa hai bảng đã thuộc cùng tenant. Cũng nên thêm để dùng FK kép. |
| **Bảng kỹ thuật của hệ thống** | Không | Lịch sử migration (`schema_migrations`), bảng khóa phân tán, hàng đợi job nội bộ. |
| **Dữ liệu người dùng xuyên tenant** | Không | Tài khoản đăng nhập mà một người thuộc nhiều tenant (có bảng `memberships` nối người dùng với tenant, bảng này mới có `tenant_id`). |

- Rò rỉ tenant ở service sử dụng qua app user

| Lệnh | Trường hợp rò rỉ |
|---|---|
| `SET` / `SET LOCAL` / `set_config` | `app_user` tự đổi được `app.tenant_id`. Nếu có SQL injection hoặc cho chạy SQL tùy ý, kẻ tấn công đổi sang tenant khác và RLS cho qua. Đây là lỗ hổng lớn nhất. |
| `SET` (không `LOCAL`) | Với connection pool, giá trị cũ còn sót, request của tenant sau chạy nhầm tenant trước. |
| `UPDATE` | Nếu được cấp `UPDATE` trên mọi cột, có thể đổi `tenant_id` để chuyển dòng sang tenant khác (khi policy thiếu `WITH CHECK`). |
| `INSERT` | Thiếu `WITH CHECK` thì ghi được dữ liệu vào tenant khác. |
| `INSERT`, `UPDATE` (lỗi ràng buộc) | Lỗi trùng unique hoặc vi phạm FK (khi ràng buộc không gồm `tenant_id`) báo cho biết dòng của tenant khác có tồn tại. Thông báo lỗi còn có thể chứa giá trị cụ thể. |
| `SELECT` trên view | View không có `security_invoker = true` chạy bằng quyền owner và bỏ qua RLS. |
| `SELECT` trên materialized view | Không hỗ trợ RLS, nên chứa dữ liệu mọi tenant. |
| Gọi function `SECURITY DEFINER` | Chạy bằng quyền owner nên bỏ qua RLS. |
| `SELECT` với hàm/toán tử tùy ý trong `WHERE` | Hàm không "leakproof" có thể bị planner chạy trên dòng của tenant khác trước khi RLS lọc, rồi lộ giá trị qua thông báo lỗi. |
| `SELECT` trên catalog (`pg_stats`, `pg_stat_statements`, `pg_class`...) | Lộ tên bảng, giá trị thống kê, nội dung câu lệnh của tenant khác. |
| `EXPLAIN [ANALYZE]` (dev) | Số dòng, kế hoạch thực thi cho biết lượng dữ liệu của tenant khác. |
| `SELECT nextval()` / `INSERT` dùng sequence | Giá trị tăng dần cho biết tổng số dòng toàn hệ thống và đoán được ID. |
| `SELECT ... FOR UPDATE / FOR SHARE` | Bị chặn do khóa của tenant khác, nên suy ra được hoạt động của họ (side channel về thời gian). |
| `COPY` | Nếu cấp quyền `pg_read_server_files` / `pg_write_server_files` / `pg_execute_server_program` thì đọc ghi file trên server, vượt hẳn khỏi database. |
| `LISTEN` / `NOTIFY` | Kênh thông báo dùng chung cả database, `app_user` nghe được thông báo của tenant khác nếu kênh không tách theo tenant. |
| `CREATE TEMP TABLE` | Quyền `TEMP` mặc định có sẵn, bảng tạm sót lại trong connection pool lộ dữ liệu cho request sau. |
| `PREPARE` / prepared statement | Kế hoạch lưu theo phiên, có thể còn sót khi dùng chung connection nếu không `DISCARD ALL`. |
| `BEGIN ... COMMIT` | Quên đặt `SET LOCAL` ngay đầu transaction thì các câu lệnh đầu chạy với tenant cũ hoặc không có tenant. |

- Rò rỉ tenant ở service sử dụng qua app migrator

| Lệnh | Trường hợp rò rỉ |
|---|---|
| `CREATE POLICY / ALTER POLICY / DROP POLICY` | Viết policy sai (thiếu `WITH CHECK`, điều kiện sai) hoặc xóa policy thì RLS không còn chặn. |
| `ALTER TABLE ... DISABLE ROW LEVEL SECURITY` | Tắt RLS trên bảng, mọi tenant thấy dữ liệu nhau. |
| `ALTER TABLE ... NO FORCE ROW LEVEL SECURITY` | Owner (và `app_migrator` qua owner) bỏ qua RLS, đọc được dữ liệu mọi tenant. |
| `CREATE TABLE` | Quên `tenant_id`, quên bật RLS/`FORCE`, quên tạo policy, nên bảng mới lộ dữ liệu. |
| `CREATE VIEW` | Thiếu `security_invoker = true`, view chạy bằng quyền owner và bỏ qua RLS. |
| `CREATE MATERIALIZED VIEW` | Không hỗ trợ RLS, chứa dữ liệu mọi tenant. |
| `CREATE FUNCTION / PROCEDURE` | Dùng `SECURITY DEFINER` thì chạy bằng quyền owner, bỏ qua RLS. |
| `CREATE TRIGGER` | Trigger có thể đọc, ghi dữ liệu chéo tenant, hoặc đổi `tenant_id`. |
| `ALTER TABLE ... ADD CONSTRAINT UNIQUE`, `CREATE UNIQUE INDEX` | Không gồm `tenant_id` thì lỗi trùng khóa làm lộ sự tồn tại dữ liệu tenant khác. |
| `ALTER TABLE ... ADD FOREIGN KEY` | Không dùng FK kép `(tenant_id, ...)` thì tham chiếu chéo tenant được, và lỗi FK lộ thông tin. |
| `ALTER TABLE ... ALTER COLUMN` (đổi kiểu, `DROP COLUMN tenant_id`) | Làm hỏng hoặc xóa cột `tenant_id` mà policy đang dùng. |
| `ALTER TABLE ... OWNER TO` | Đổi owner sang role khác (nếu có quyền) làm lệch cấu hình `FORCE` RLS và phân quyền. |
| `GRANT` | Cấp quá rộng cho `app_user` (`TRUNCATE`, `UPDATE` cả cột `tenant_id`, `pg_read_all_data`). |
| `GRANT app_owner TO app_user` | `app_user` thừa hưởng quyền owner. |
| `ALTER DEFAULT PRIVILEGES` | Đối tượng mới tự cấp quyền rộng cho `app_user` hoặc `PUBLIC`. |
| `REVOKE` | Thu hồi sót, vẫn để quyền thừa của `PUBLIC` (`TEMP`, `CREATE` trên schema). |
| `CREATE SCHEMA` | Schema mới có quyền mặc định mở, hoặc `search_path` bị lệch. |
| `CREATE EXTENSION` | Extension (nếu được phép) có thể thêm hàm chạy với quyền cao hoặc bỏ qua RLS. |
| `CREATE SEQUENCE` / dùng serial | ID tăng dần lộ tổng số dòng, đoán được ID. |
| `INSERT`, `UPDATE`, `DELETE`, `COPY`, `SELECT` (data migration) | Chạy migration dữ liệu qua owner mà không có `tenant_id` đúng, sửa nhầm hoặc nhập nhầm dòng của tenant khác. Đọc được dữ liệu vì `FORCE` RLS chỉ áp dụng khi đã đặt `app.tenant_id`, còn nếu không đặt thì thường thấy 0 dòng hoặc lỗi, dẫn đến hay phải tắt RLS tạm thời. |
| `TRUNCATE`, `DROP` | Mất dữ liệu của mọi tenant (thuộc về tính toàn vẹn, không phải rò rỉ). |
| `SET ROLE` / `SET SESSION AUTHORIZATION` | Chuyển sang role có quyền cao hơn nếu được cấp thành viên. |
| `EXPLAIN [ANALYZE]` | Lộ kế hoạch và số dòng của mọi tenant khi chạy bằng quyền cao. |
| Log của migration (lỗi, câu lệnh có giá trị) | Tool migration ghi giá trị dữ liệu vào log CI. |

- Rò rỉ tenant ở service qua các role khác trong database.

| Nhóm rò rỉ chung | Áp dụng cho role | Lý do |
|---|---|---|
| **Bỏ qua RLS** (`SUPERUSER`, `BYPASSRLS`, owner không `FORCE`) | `postgres`, `platform_admin`, `app_owner` | RLS không chặn, đọc/ghi được dữ liệu mọi tenant. |
| **Đọc dữ liệu vật lý** (không qua truy vấn bảng) | `backup`, `replicator`, `postgres` | `pg_dump`, `pg_basebackup`, WAL, replica chứa dữ liệu mọi tenant. |
| **Đọc metadata và thống kê** | `monitor`, `app_readonly`, `auditor` | `pg_stat_statements`, `pg_stats`, `pg_stat_activity` lộ nội dung câu lệnh, giá trị, hoạt động của tenant khác. |
| **Quyền vượt khỏi database** | Role có `pg_read_server_files`, `pg_execute_server_program` | Đọc file, chạy lệnh trên server, truy cập dữ liệu và thông tin xác thực ngoài RLS. |
| **Thừa hưởng quyền** (`INHERIT`, `SET ROLE`) | Mọi role là thành viên role khác | Có thêm quyền của role cha, kể cả quyền bỏ qua RLS. |
| **Quyền cấp rộng** (`pg_read_all_data`, `GRANT` trên bảng không RLS) | `app_readonly`, `monitor` | Đọc mọi bảng không qua kiểm soát từng tenant. |
| **Đối tượng bỏ qua RLS** (view `DEFINER`, function `SECURITY DEFINER`, materialized view) | Mọi role được `SELECT` hoặc `EXECUTE` | Truy cập qua đối tượng này không bị RLS. |
| **Trạng thái dùng chung** (`LISTEN/NOTIFY`, bảng tạm, prepared statement, connection pool) | Mọi role dùng chung kết nối | Dữ liệu sót lại giữa các phiên. |
| **Side channel** (thời gian, khóa, sequence, thông báo lỗi) | Mọi role chạy truy vấn | Suy ra thông tin mà không đọc trực tiếp. |
| **Thông tin xác thực bị lộ** | Mọi role | Lộ mật khẩu hoặc chứng chỉ của role mạnh thì mọi cách ly đều vô hiệu. |

- Đối tượng mới làm rò rỉ tenant.

| Đối tượng mới | Trường hợp rò rỉ |
|---|---|
| **Bảng mới** | Quên cột `tenant_id`, quên `ENABLE` hoặc `FORCE ROW LEVEL SECURITY`, quên tạo policy. Bảng đã bật RLS nhưng chưa có policy thì mặc định chặn hết, còn bảng chưa bật RLS thì mọi tenant thấy nhau. |
| **Bảng mới (quyền)** | `ALTER DEFAULT PRIVILEGES` thiếu hoặc quá rộng, nên `app_user` hoặc `PUBLIC` có quyền thừa (`TRUNCATE`, `UPDATE` cả cột `tenant_id`). |
| **Bảng mới (owner)** | Bảng không do `app_owner` sở hữu, nên không nằm trong cấu hình `FORCE` RLS và phân quyền chuẩn. |
| **Bảng con / bảng nối mới** | Không có `tenant_id`, hoặc FK không phải FK kép nên tham chiếu chéo tenant được. |
| **Partition mới** | Bảng cha có RLS nhưng truy cập trực tiếp vào partition con thì policy của cha không áp dụng. Partition mới phải có RLS riêng hoặc không cấp quyền trực tiếp. |
| **Bảng kế thừa / bảng con tạo bằng `INHERITS`** | Tương tự partition, RLS của bảng cha không áp dụng cho bảng con khi truy cập trực tiếp. |
| **Cột mới trong bảng cũ** | Cột nhạy cảm không được kiểm soát bởi `GRANT` cột, hoặc cột chứa dữ liệu liên quan tenant mà policy không bao phủ. |
| **Index / unique mới** | Không gồm `tenant_id`, nên lỗi trùng khóa lộ sự tồn tại dữ liệu tenant khác. |
| **Ràng buộc mới (FK, CHECK, EXCLUDE)** | Không có `tenant_id` thì thông báo lỗi lộ giá trị hoặc sự tồn tại của dòng tenant khác. |
| **View mới** | Thiếu `security_invoker = true` nên chạy bằng quyền owner và bỏ qua RLS. |
| **Materialized view mới** | Không hỗ trợ RLS, chứa dữ liệu mọi tenant. |
| **Function / procedure mới** | `SECURITY DEFINER` bỏ qua RLS. Hàm không leakproof dùng trong policy hoặc `WHERE` có thể lộ giá trị qua thông báo lỗi. |
| **Trigger mới** | Đọc, ghi dữ liệu chéo tenant, hoặc đổi `tenant_id`. |
| **Sequence mới** | ID tăng dần lộ tổng số dòng và đoán được ID. Quyền `USAGE` cấp dùng chung. |
| **Schema mới** | `PUBLIC` mặc định có thể `USAGE` hoặc `CREATE`, `search_path` bị lệch khiến gọi nhầm đối tượng. |
| **Extension mới** | Thêm hàm, view, bảng không có RLS, hoặc hàm chạy với quyền cao, hoặc view thống kê lộ dữ liệu. |
| **Kiểu dữ liệu / operator mới** | Operator hoặc hàm tùy chỉnh bị planner chạy trước khi RLS lọc, lộ giá trị. |
| **Policy mới hoặc sửa policy** | Điều kiện sai, thiếu `WITH CHECK`, thiếu policy cho một loại lệnh (`SELECT`, `UPDATE`...), hoặc policy `PERMISSIVE` mới làm nới lỏng policy cũ (các policy permissive được cộng bằng OR). |
| **Role mới / thành viên role mới** | Role có `BYPASSRLS`, `SUPERUSER`, hoặc được cấp thành viên role mạnh. |
| **Kênh `LISTEN/NOTIFY` mới** | Tên kênh không theo tenant nên tenant khác nghe được. |
| **Publication / replication slot mới** | Chia sẻ dữ liệu mọi tenant ra ngoài (replica, CDC) mà không có RLS. |
| **Foreign table / FDW mới** | Truy cập dữ liệu ngoài database, không áp dụng RLS của Postgres. |

- Rỏ rỉ tenant cấp cluster

| Cấu hình | Trường hợp rò rỉ |
|---|---|
| **`pg_hba.conf`: phạm vi IP** | Cho phép `postgres`, `app_migrator` kết nối từ mạng ứng dụng hoặc `0.0.0.0/0`, nên role mạnh bị tấn công từ xa. |
| **`pg_hba.conf`: phương thức xác thực** | Dùng `trust`, `md5`, hoặc `password` thay vì `scram-sha-256` hoặc chứng chỉ, nên lộ hoặc bị đoán mật khẩu. |
| **`pg_hba.conf`: thứ tự dòng** | Dòng rộng đứng trước dòng hẹp nên quy tắc chặt bị bỏ qua (Postgres dùng dòng khớp đầu tiên). |
| **`pg_hba.conf`: database/role `all`** | Role ứng dụng kết nối được vào database khác, hoặc kết nối vào database của tenant khác trong mô hình tách database. |
| **`ssl` / TLS tắt** | Dữ liệu và mật khẩu truyền không mã hóa, bị nghe lén. |
| **`password_encryption`** | Đặt `md5` nên hash yếu, dễ bị bẻ khóa khi lộ. |
| **`listen_addresses`** | Lắng nghe mọi interface, mở cổng ra ngoài mạng dự kiến. |
| **`log_statement`, `log_min_duration_statement`, `log_parameter_max_length`** | Ghi nội dung câu lệnh kèm giá trị tham số của mọi tenant vào log chung. |
| **`log_min_error_statement`, `log_error_verbosity`** | Log lỗi chứa câu lệnh và giá trị dữ liệu của tenant. |
| **`log_connections`, `log_line_prefix`** | Thiếu thông tin role, database, IP nên không truy vết được truy cập đặc quyền (rò rỉ khó phát hiện). |
| **`shared_preload_libraries`** | Nạp `pg_stat_statements`, `auto_explain` thu thập câu lệnh và kế hoạch chứa giá trị của mọi tenant. |
| **`auto_explain.*`** | Ghi kế hoạch và tham số của truy vấn vào log. |
| **`pg_stat_statements.track`, `track_activity_query_size`** | Lưu nội dung truy vấn dùng chung, role có quyền đọc thấy được. |
| **`track_activities`, `track_io_timing`** | `pg_stat_activity` lộ câu lệnh đang chạy, thống kê I/O tạo side channel. |
| **`row_security`** | Đặt `off` ở cấp cluster hoặc role thì truy vấn trên bảng RLS báo lỗi hoặc bỏ qua tùy ngữ cảnh (không bao giờ nên tắt trên cấu hình mặc định). |
| **`session_preload_libraries`, `local_preload_libraries`** | Nạp thư viện tùy ý cho phiên, chạy mã ngoài kiểm soát. |
| **`allow_system_table_mutations`, `allow_alter_system`** | Cho sửa catalog hoặc đổi cấu hình hệ thống từ SQL, phá mọi cách ly. |
| **`max_prepared_transactions`** | Lớn hơn 0 nên cho phép transaction treo giữ khóa và trạng thái (nên đặt 0 nếu không dùng). |
| **`max_connections`, `superuser_reserved_connections`** | Một tenant chiếm hết kết nối gây noisy neighbor, hết kết nối dự phòng cho quản trị. |
| **`default_transaction_isolation`, `search_path` mặc định** | `search_path` mặc định chứa `public` hoặc schema không tin cậy nên gọi nhầm đối tượng (hàm giả mạo). |
| **`wal_level`, `archive_mode`, `archive_command`** | WAL và bản lưu trữ chứa dữ liệu mọi tenant, đích lưu trữ không mã hóa hoặc quyền truy cập rộng. |
| **`max_wal_senders`, `max_replication_slots`, `hot_standby`** | Mở đường replica/CDC sao chép toàn bộ dữ liệu ra ngoài RLS. |
| **`ssl_*` / `data_directory` / `unix_socket_permissions`** | Quyền thư mục dữ liệu hoặc socket rộng nên tiến trình khác trên máy đọc được file dữ liệu. |
| **`dynamic_library_path`, `extension_destdir`, `create_extension` quyền** | Cho nạp extension không tin cậy. |
| **Trusted extensions** | Role có `CREATE` trên database cài được extension "trusted", mở thêm hàm không kiểm soát. |
| **Quyền mặc định của `PUBLIC`** (`CONNECT`, `TEMP` trên database, `USAGE` trên schema `public`) | Role nào cũng kết nối và tạo bảng tạm. Ở Postgres 15 trở lên `PUBLIC` đã bị thu `CREATE` trên schema `public`, nhưng database nâng cấp từ bản cũ có thể còn quyền cũ. |
| **Template database (`template1`)** | Đối tượng hoặc quyền đặt ở đây được sao chép vào mọi database mới. |
| **Cấu hình dịch vụ managed** (tham số group, role master, quyền `rds_superuser`...) | Role đặc quyền của nhà cung cấp, snapshot/backup tự động, truy cập từ console. |

- Trao quyền làm rò rỉ gián tiếp tenant.

| Nhóm lệch | Trường hợp | Hậu quả |
|---|---|---|
| **Thuộc tính role** | `app_user` hoặc `app_migrator` bị gán `SUPERUSER` hoặc `BYPASSRLS` (ví dụ để chữa cháy lỗi RLS rồi quên thu hồi) | Bỏ qua mọi policy, đọc/ghi được dữ liệu mọi tenant. |
| | `app_owner` bị đổi thành `LOGIN`, hoặc đặt mật khẩu | Có đường đăng nhập trực tiếp bằng role sở hữu bảng, sửa được policy. |
| | `CREATEROLE` được cấp cho role không phải `postgres` | Tự tạo role mới hoặc tự cấp thành viên role mạnh (từ PG16, `CREATEROLE` bị hạn chế hơn nhưng vẫn quản lý được role do nó tạo). |
| | `CREATEDB`, `REPLICATION` bị bật cho role ứng dụng | Tạo database tùy ý, hoặc sao chép toàn bộ dữ liệu ra ngoài RLS. |
| | `CONNECTION LIMIT` bị bỏ hoặc nới | Một tenant chiếm hết kết nối (noisy neighbor). |
| | `VALID UNTIL` hết hạn hoặc không đặt, mật khẩu không xoay vòng | Mật khẩu cũ bị lộ vẫn dùng được. |
| | `ALTER ROLE ... SET` (cấu hình riêng role) bị đổi: `row_security = off`, `search_path` lạ, `session_replication_role = replica` | Tắt RLS và trigger, hoặc gọi nhầm đối tượng giả mạo. |
| | `session_replication_role = replica` cho role ứng dụng | Vô hiệu hóa trigger (kể cả trigger chặn đổi `tenant_id`) và kiểm tra FK. |
| **Thành viên role** | `app_user` được `GRANT` thành viên `app_owner`, `app_migrator` hoặc role đặc quyền | Thừa hưởng quyền owner, đổi policy, bỏ qua `FORCE` RLS. |
| | `app_user` được cấp `pg_read_all_data`, `pg_write_all_data` | Đọc/ghi mọi bảng ngoài kiểm soát `GRANT` (RLS vẫn áp dụng, nhưng quyền bảng thì mở hết, kể cả bảng dùng chung hoặc bảng kỹ thuật). |
| | Cấp `pg_read_server_files`, `pg_write_server_files`, `pg_execute_server_program` | Đọc/ghi file, chạy lệnh trên server. |
| | Cấp `pg_monitor`, `pg_read_all_stats`, `pg_signal_backend`, `pg_checkpoint`, `pg_maintain` | Lộ nội dung câu lệnh của tenant khác, kết thúc phiên của họ, hoặc chạy bảo trì trên bảng. |
| | Thành viên role với `WITH SET TRUE` / `INHERIT TRUE` ngoài ý muốn (PG16+) | Chuyển (`SET ROLE`) sang role mạnh hơn. |
| **Quyền trên bảng** | `GRANT TRUNCATE`, `REFERENCES`, `TRIGGER` cho `app_user` | `TRUNCATE` bỏ qua RLS, xóa dữ liệu mọi tenant. `REFERENCES`, `TRIGGER` lộ sự tồn tại dòng hoặc gắn mã tùy ý. |
| | `GRANT UPDATE` toàn bảng (thay vì theo cột, bỏ `tenant_id`) | Đổi `tenant_id` để chuyển dòng sang tenant khác (nếu policy thiếu `WITH CHECK`). |
| | `GRANT ... WITH GRANT OPTION` | `app_user` tự cấp quyền tiếp cho role khác. |
| | `GRANT` trực tiếp lên bảng mới tạo ngoài pipeline | Bảng chưa qua kiểm tra RLS/policy vẫn truy cập được. |
| | Quyền cấp cho `PUBLIC` (`SELECT` trên bảng hoặc `EXECUTE` trên function) | Mọi role đều đọc được. |
| **Quyền schema / database** | `GRANT CREATE ON SCHEMA` hoặc `CREATE ON DATABASE` cho `app_user` | Tạo view, function `SECURITY DEFINER`, hoặc hàm giả mạo đặt trước trong `search_path`. |
| | Không còn `REVOKE TEMP ... FROM PUBLIC` | Bảng tạm sót lại trong connection pool. |
| | `GRANT CONNECT` lên database khác | Kết nối vào database không thuộc phạm vi service. |
| **Owner đối tượng** | Bảng, view, function đổi owner sang role khác (hoặc do `app_user`/`postgres` tạo ra) | Đối tượng nằm ngoài `FORCE` RLS và phân quyền chuẩn. Owner là `postgres` thì bỏ qua RLS. |
| | Đối tượng do `app_migrator` tạo mà không `SET ROLE app_owner` | Owner là `app_migrator` thay vì `app_owner`, lệch cấu hình chuẩn. |
| **Quyền mặc định** | `ALTER DEFAULT PRIVILEGES` bị đổi hoặc thiếu | Đối tượng mới tự có quyền quá rộng hoặc cho `PUBLIC`. |
| **Quyền function / sequence** | `EXECUTE` trên function `SECURITY DEFINER` còn cho `PUBLIC` (mặc định của Postgres) | Role nào cũng gọi được hàm chạy bằng quyền owner. |
| | `USAGE`, `UPDATE` trên sequence cấp dùng chung | Đọc/đặt lại giá trị sequence, lộ hoặc phá ID. |
| **Hạ tầng** | Thay đổi bằng console của dịch vụ managed, hoặc DBA sửa thủ công ngoài pipeline | Không có trong code, không có review, không được phát hiện. |

- Dùng chung connection làm rò rỉ tenant:

| Trạng thái phiên | Trường hợp rò rỉ |
|---|---|
| **Biến `app.tenant_id` (`SET` không `LOCAL`)** | Giá trị tenant cũ còn sót, request sau chạy với tenant trước và RLS cho qua. |
| **`app.tenant_id` chưa được đặt** | Request đầu transaction chạy khi biến còn giá trị cũ hoặc rỗng. Policy dùng `current_setting('app.tenant_id')` có thể lỗi hoặc lọc sai. |
| **Đặt `tenant_id` ngoài transaction** | Với PgBouncer chế độ transaction, `SET` ở một transaction và truy vấn ở transaction khác có thể rơi vào kết nối khác, nên chạy nhầm tenant hoặc không có tenant. |
| **`SET LOCAL` rồi `COMMIT` sớm trong cùng request** | Các câu lệnh sau `COMMIT` không còn biến, chạy sai tenant. |
| **`SET ROLE` / `SET SESSION AUTHORIZATION`** | Role đã chuyển còn sót, request sau chạy bằng quyền khác. |
| **Tham số phiên khác** (`search_path`, `row_security`, `session_replication_role`, `statement_timeout`) | Giá trị còn sót ảnh hưởng request sau: gọi nhầm đối tượng, tắt trigger, hoặc đổi hành vi truy vấn. |
| **Bảng tạm (`CREATE TEMP TABLE`)** | Dữ liệu tenant A còn trong bảng tạm, tenant B đọc được nếu trùng tên bảng. Bảng tạm cũng có thể che (shadow) bảng thật nếu đứng trước trong `search_path`. |
| **Prepared statement (`PREPARE`, protocol-level)** | Kế hoạch và tham số còn lưu theo phiên. Có thể chạy lại câu lệnh của tenant trước, hoặc trùng tên prepared statement gây lỗi/chạy sai. Generic plan có thể được cache với giả định không đúng tenant. |
| **Cursor (`DECLARE ... CURSOR WITH HOLD`)** | Con trỏ giữ kết quả của tenant A sau khi transaction kết thúc. |
| **`LISTEN`** | Kết nối còn đăng ký kênh của tenant A, nhận thông báo của họ trong request của tenant B. |
| **Advisory lock (`pg_advisory_lock`)** | Khóa mức phiên còn sót, chặn tenant khác (noisy neighbor) hoặc tiết lộ qua thời gian chờ. |
| **Giá trị sequence (`currval`, `lastval`)** | `lastval()` trả về giá trị do request trước sinh ra, lộ ID của tenant khác. |
| **Transaction chưa đóng** (`idle in transaction`) | Transaction còn mở giữ snapshot, khóa và biến `SET LOCAL` của tenant trước. |
| **Biến tùy chỉnh khác (`SET` / `set_config` cho audit, user_id...)** | Giá trị `app.user_id`, `app.role` sót lại dẫn đến ghi audit sai hoặc policy dựa trên các biến này lọc sai. |
| **Lỗi trong transaction đã abort** | Sau lỗi, transaction ở trạng thái aborted nếu pool không `ROLLBACK`, request sau nhận lỗi hoặc hành vi bất thường. |
| **Kết nối trả lại pool khi request bị hủy/timeout giữa chừng** | Lệnh còn chạy trên kết nối, hoặc trạng thái chưa được dọn dẹp. |
| **Prepared transaction (`PREPARE TRANSACTION`)** | Tồn tại độc lập với kết nối, giữ khóa và trạng thái của tenant lâu dài. |
| **Session pooling dùng lại kết nối dài hạn** | Mọi trạng thái trên cộng dồn qua nhiều tenant liên tiếp. |
| **Pool dùng chung giữa các service hoặc role** | Kết nối do role khác thiết lập còn sót thuộc tính (ví dụ `SET ROLE`). |

- Side channel làm rò rỉ tenant:

| Kênh | Trường hợp rò rỉ |
|---|---|
| **Thời gian phản hồi** | Truy vấn trên bảng lớn của tenant khác làm chậm truy vấn của mình (dùng chung CPU, I/O, buffer cache). Đo độ trễ suy ra lượng dữ liệu hoặc hoạt động của họ. |
| **Thời gian thực thi theo giá trị** | RLS lọc sau khi planner đã quét, nên truy vấn dò giá trị (`WHERE email = ...`) chạy lâu hay nhanh tùy dữ liệu tenant khác có khớp hay không. |
| **Khóa dòng và khóa bảng** | `SELECT ... FOR UPDATE`, `UPDATE` bị chặn bởi khóa của tenant khác, nên thời gian chờ cho biết họ đang thao tác. |
| **Advisory lock** | Khóa dùng chung theo khóa số nguyên, lock trùng khóa với tenant khác nên bị chặn và suy ra hoạt động. |
| **Lỗi ràng buộc unique / FK / exclusion** | Lỗi "đã tồn tại" hoặc "vi phạm khóa ngoại" cho biết dòng của tenant khác có thật. Thông báo lỗi còn có thể chứa giá trị. |
| **Thông báo lỗi từ hàm không leakproof** | Planner chạy hàm/toán tử trên dòng chưa được RLS lọc, lỗi (chia cho 0, ép kiểu) in ra giá trị của dòng tenant khác. |
| **Giá trị sequence** | `nextval` tăng theo toàn hệ thống nên lộ tốc độ tạo dòng và tổng số dòng của tenant khác. ID tuần tự dễ đoán. |
| **Thống kê và catalog** | `pg_stats`, `pg_class.reltuples`, `pg_stat_user_tables`, `pg_total_relation_size` lộ số dòng, kích thước, phân phối giá trị (most common values) của bảng chung. |
| **`pg_stat_statements`, `pg_stat_activity`** | Lộ nội dung câu lệnh, tham số, câu đang chạy của tenant khác. |
| **`EXPLAIN` / `EXPLAIN ANALYZE`** | Số dòng ước tính và thực tế, kế hoạch chọn index cho biết lượng và phân phối dữ liệu tenant khác. |
| **Kế hoạch thực thi và thống kê dùng chung** | Planner dùng thống kê toàn bảng (không theo tenant), nên kế hoạch thay đổi khi dữ liệu tenant khác thay đổi, quan sát được qua thời gian. |
| **Autovacuum và bloat** | Vacuum chạy do hoạt động của tenant khác làm chậm hoặc đổi hiệu năng, quan sát được. |
| **Kích thước bảng, index, WAL** | Hàm kích thước hoặc độ trễ replication tăng theo hoạt động ghi của tenant khác. |
| **Số kết nối và hàng đợi** | Hết `max_connections` hay chờ trong pool cho biết tenant khác đang tải nặng. |
| **`LISTEN / NOTIFY`** | Kênh dùng chung, nội dung hoặc tần suất thông báo lộ hoạt động. |
| **Thứ tự và phân trang** | Thứ tự kết quả hoặc cursor dựa trên ID toàn cục cho biết khoảng cách ID, tức số dòng của tenant khác xen giữa. |
| **Thông báo `affected rows`, `COUNT`** | Thông báo số dòng ảnh hưởng hay `COUNT(*)` cho cấp độ chi tiết vượt phạm vi tenant nếu một số dòng bị lọc theo cách không nhất quán. |
| **Cache (shared buffers, cache ứng dụng)** | Dữ liệu tenant khác đã nằm sẵn trong cache làm truy vấn nhanh hơn, đo được qua thời gian. |
| **Timeout và `statement_timeout`** | Truy vấn bị hủy khi tenant khác chiếm tài nguyên, cho biết mức tải. |
| **Kích thước phản hồi và số lần retry** | Tầng ứng dụng, nhưng phản ánh trạng thái database. |

- Dữ liệu nằm ngoài bảng làm rò rỉ tenant:

| Nơi chứa | Trường hợp rò rỉ |
|---|---|
| **WAL (write-ahead log)** | Chứa mọi thay đổi của mọi tenant. Ai đọc được file WAL, hoặc dùng logical decoding (`pg_logical_slot_get_changes`), thấy toàn bộ dữ liệu ngoài RLS. |
| **File dữ liệu (`data_directory`)** | Quyền thư mục rộng, hoặc truy cập từ OS (người có quyền trên máy chủ, snapshot ổ đĩa) đọc được dữ liệu thô của mọi tenant. |
| **Backup logic (`pg_dump`)** | File dump chứa dữ liệu mọi tenant (trừ khi dump dưới role bị RLS), lưu ở nơi quyền rộng hoặc không mã hóa. |
| **Backup vật lý (`pg_basebackup`, snapshot)** | Bản sao toàn bộ cluster, gồm cả dữ liệu mọi tenant. Role `backup` hoặc người giữ file đọc được tất cả. |
| **Archive WAL (`archive_command`, PITR)** | Kho lưu trữ WAL lâu dài, quyền truy cập và mã hóa là điểm yếu. |
| **Replica / standby** | Bản sao toàn bộ dữ liệu, role `replicator` hoặc người có quyền trên replica đọc được. Replica đọc-chỉ không thừa hưởng cách ly nếu cấu hình role khác nhau. |
| **Replication slot, publication, CDC** | Luồng thay đổi gửi ra hệ thống ngoài (Debezium, Kafka) chứa dữ liệu mọi tenant, không có RLS. |
| **Log của Postgres** | `log_statement`, `log_min_error_statement`, `log_parameter_max_length` ghi câu lệnh và giá trị tham số. Thông báo lỗi chứa giá trị dòng dữ liệu. Log thường lưu chung, quyền đọc rộng. |
| **`pg_stat_statements`, `auto_explain`** | Lưu nội dung câu lệnh, tham số và kế hoạch của mọi tenant ngoài bảng dữ liệu. |
| **Bảng tạm và file tạm** | Bảng tạm, file sort/hash spill (`base/pgsql_tmp`) chứa dữ liệu trung gian của truy vấn. |
| **Shared buffers và bộ nhớ** | Dữ liệu nằm trong bộ nhớ dùng chung. Core dump, swap, hoặc dump bộ nhớ của tiến trình lộ dữ liệu. |
| **Large Objects (`pg_largeobject`)** | Lưu ngoài bảng thường, chỉ kiểm soát bằng quyền lớn object, không có RLS. |
| **TOAST** | Lưu nội bộ theo bảng chính, nhưng lộ qua đường vật lý (file, backup) như dữ liệu bảng. |
| **Foreign table / FDW** | Dữ liệu ở hệ thống ngoài (database khác, file, API) không áp dụng RLS của Postgres. Thông tin kết nối (user mapping) chứa mật khẩu. |
| **Extension lưu trữ ngoài** (full-text, `pg_trgm`, vector, PostGIS) | Index chứa giá trị của mọi tenant. Index vật lý đọc được qua extension kiểm tra trang (`pageinspect`, `pg_buffercache`). |
| **`pageinspect`, `pg_buffercache`, `pgstattuple`, `pg_visibility`** | Đọc nội dung trang, bộ đệm hoặc thống kê vật lý, bỏ qua RLS (cần quyền cao, nhưng nếu cấp thì lộ). |
| **`COPY ... TO PROGRAM` / `TO file`, `pg_read_server_files`** | Xuất hoặc đọc file trên server, tạo bản sao dữ liệu ngoài kiểm soát của database. |
| **Export, báo cáo, file CSV** | File xuất của một tenant chứa lẫn dữ liệu tenant khác nếu truy vấn sai, hoặc lưu ở thư mục dùng chung. |
| **Ngoài database nhưng cùng dữ liệu** (data warehouse, ETL, search index, cache) | Dữ liệu sao chép sang hệ thống khác, mất cách ly nếu không mang theo `tenant_id` và quyền tương ứng. |
| **Thông tin xác thực** (`pg_authid`, `.pgpass`, biến môi trường, secret manager) | Lộ mật khẩu role mạnh thì mọi cách ly vô hiệu, dù không phải "dữ liệu tenant". |
| **Snapshot của dịch vụ managed** | Snapshot tự động, bản sao chia sẻ giữa tài khoản, hoặc truy cập từ console của nhà cung cấp. |
| **Môi trường dev/test** | Bản sao dữ liệu production không ẩn danh được nạp vào môi trường kém bảo mật. |