## Pipeline

| # | Bước | Chạy bằng | Nội dung chính | Cổng kiểm tra (gate) |
|---|---|---|---|---|
| 0 | **Chuẩn hóa** (làm một lần, lưu trong repo) | Con người | Danh sách bảng global và bảng tenant, template policy, quy ước đặt tên, kiểu ID (UUID thay vì serial) | Review |
| 1 | **Dựng database** | IaC (Terraform...) | `pg_hba`, TLS, `scram-sha-256`, logging, `shared_preload_libraries`, `max_prepared_transactions=0`, mã hóa backup/WAL/snapshot, replica | Kiểm tra `SHOW`/`pg_settings` so với baseline |
| 2 | **Bootstrap** | `postgres`, từ mạng quản trị | Tạo role và thuộc tính, `REVOKE ... FROM PUBLIC`, tạo schema thuộc `app_owner`, `ALTER DEFAULT PRIVILEGES`, `ALTER ROLE ... SET`, hàm helper RLS | Audit catalog: thuộc tính role, membership, ACL |
| 3 | **Migrate** | `app_migrator` → `SET ROLE app_owner` | DDL, bật RLS, policy, data migration | Lint migration trước khi chạy, audit catalog sau khi chạy |
| 4 | **Kết nối runtime** | Code service | Thư viện truy cập DB, pool, xử lý lỗi | Test cách ly xuyên tenant |
| 5 | **Vận hành liên tục** | Job định kỳ | Audit drift, xoay mật khẩu, backup/restore, log, dữ liệu dev | Cảnh báo |

## Quy chuẩn

| Thành phần | Dạng chạy được | Chặn lỗi nào |
|---|---|---|
| Template policy / helper `enable_tenant_rls()` | SQL | Quên RLS, quên `WITH CHECK` (4.5) |
| Danh sách bảng global và bảng tenant | Manifest (YAML/JSON) | Bảng mới không được phân loại (4.1) |
| Quy tắc lint migration | Script chạy trong CI | `DISABLE RLS`, `SECURITY DEFINER`, view thiếu `security_invoker` (4.3) |
| Audit catalog | Truy vấn SQL kèm kết quả mong đợi | Drift ở role và quyền (4.7) |
| Baseline cấu hình Postgres | File so sánh với `pg_settings` | Cấu hình cluster sai (4.6) |
| Bộ test cách ly xuyên tenant | Test suite | Lỗi ở mọi tầng |

## Các bước cần chuẩn hóa

| # | Bước | Cần chuẩn hóa? | Phần chuẩn hóa (repo chuẩn) | Phần service tự quyết | Vì sao |
|---|---|---|---|---|---|
| 0 | **Chuẩn hóa** | Là chính nó | Template policy, quy tắc lint, truy vấn audit, baseline cấu hình, bộ test cách ly, quy ước đặt tên | Không có | Đây là nguồn gốc của mọi chuẩn bên dưới. Phải chạy được bằng máy, nếu không chỉ là tài liệu. |
| 1 | **Dựng database** | Có (module dùng chung, tham số hóa) | Module IaC: `pg_hba`, TLS, `scram-sha-256`, logging, `max_prepared_transactions=0`, mã hóa backup/WAL, replica | Kích thước máy, tên, mạng, môi trường | Mỗi service một database nên bước này lặp N lần. Một tham số cluster sai (mục 4.6) là lỗi lặp ở mọi service, và khó phát hiện bằng mắt. |
| 2 | **Bootstrap** | Có, mức cao nhất | Tên role, thuộc tính, membership, `REVOKE ... FROM PUBLIC`, owner của schema, `ALTER DEFAULT PRIVILEGES`, `ALTER ROLE ... SET`, helper `enable_tenant_rls()` và `current_tenant()` | Tên database, tên schema, `CONNECTION LIMIT` theo kích thước pool | Đây là nơi tạo hàng rào cách ly. Role lệch chuẩn (mục 4.7) làm vô hiệu mọi policy. Bước này cũng chỉ do `postgres` chạy nên không thể để từng service tự viết. |
| 3.1 | **Migrate: lint** | Có (quy tắc) | Bộ quy tắc, parser, cơ chế ngoại lệ có người duyệt và có hạn | File migration, manifest phân loại bảng | Quy tắc phải thống nhất, nếu không service nào cũng có thể nới lỏng. |
| 3.2 | **Migrate: build image** | Có (runner, workflow) | Runner, cách ký image, pin theo digest | Thư mục migration | Service không được bỏ bớt bước hay thay runner. |
| 3.3 | **Migrate: test cluster** | Có | Dựng cluster bằng đúng bootstrap của repo chuẩn, audit catalog, test cách ly với `app_user` thật | Dữ liệu giả của ít nhất hai tenant, test riêng của nghiệp vụ | Test chỉ có giá trị khi cluster giống thật. Nếu mỗi service tự dựng cluster thì test xanh nhưng production vẫn lệch. |
| 3.4 | **Migrate: chạy thật** | Có | Preflight audit, phê duyệt, concurrency, snapshot, post-check, ghi vết, trust policy OIDC | Thời điểm chạy, người duyệt cụ thể | Ranh giới đặc quyền nằm ở đây: credential `app_migrator` chỉ được cấp khi đúng workflow của repo chuẩn. |
| 3.x | **Migration file và manifest bảng** | **Không** (chỉ chuẩn hóa quy ước) | Quy ước đặt tên, cấu trúc thư mục, schema của manifest | Nội dung migration, bảng nào global, bảng nào tenant | Đây là nghiệp vụ riêng của từng service. Chuẩn chỉ kiểm tra, không viết thay. |
| 4 | **Kết nối runtime** | Có một phần | Thư viện wrapper (mở transaction, `SET LOCAL` ngay đầu), cấu hình pool/PgBouncer, ánh xạ lỗi thành thông báo chung, cấm `SET` không `LOCAL` | Câu truy vấn, ORM, logic nghiệp vụ | Mục 4.8 cho thấy phần lớn rò rỉ đến từ trạng thái phiên và pool. Đây là việc lặp lại, dễ sai, nên làm một lần dùng chung. |
| 5 | **Vận hành liên tục** | Có | Job audit drift quét mọi service, xoay mật khẩu, kiểm tra backup/restore, cấu hình log, ẩn danh dữ liệu dev/test | Lịch bảo trì riêng nếu cần | Job phải chạy từ repo chuẩn, vì service có thể tắt job của chính nó. Mục 4.10 (backup, log, replica, dev/test) không thuộc bước nào khác. |

## Nhóm tham số của service

### 1. Định danh và phạm vi

| Tham số | Giới hạn | Ghi chú |
|---|---|---|
| Tên service | Đúng mẫu đặt tên | Gốc để sinh mọi tên khác |
| Môi trường (dev/test/staging/prod) | Danh sách cố định | Quyết định mức chặt của các cổng |
| Tên database, tên schema | Sinh từ tên service | Service không đặt tự do |
| Tiền tố tên role | Sinh từ tên service | Xem lưu ý bên dưới |

### 2. Hạ tầng database (bước 1)

| Tham số | Giới hạn |
|---|---|
| Cấu hình máy (CPU, RAM) | Theo bậc cho phép |
| Dung lượng đĩa, IOPS | Có trần |
| Phiên bản Postgres | Chỉ các bản chuẩn đang hỗ trợ (từ 15 trở lên theo mục 4.6) |
| Region, AZ, VPC/subnet | Danh sách được duyệt |
| Số replica, bật HA | Có thể tăng, không được tắt nếu là prod |
| Thời gian giữ backup | Chỉ **tăng** so với mức tối thiểu |
| Cửa sổ bảo trì | Tự chọn |

### 3. Bootstrap (bước 2)

| Tham số | Giới hạn |
|---|---|
| `CONNECTION LIMIT` của `app_user` | Theo kích thước pool, có trần theo bậc máy |
| `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` của `app_user` | Khoảng cho phép, bắt buộc có giá trị |
| Chu kỳ xoay mật khẩu (`VALID UNTIL`) | Tối đa N ngày |
| Số schema nghiệp vụ | Tên sinh từ chuẩn |

### 4. Migrate (bước 3)

| Tham số | Giới hạn |
|---|---|
| Nội dung migration | Qua lint và audit |
| Manifest phân loại bảng (global, tenant, bảng nối) | Mọi bảng phải được phân loại, CI kiểm tra khớp với migration |
| Danh sách cột được `UPDATE` theo từng bảng | Không được chứa `tenant_id` |
| Tham số của helper `enable_tenant_rls()` | Chỉ các biến thể có sẵn trong template (bảng con, bảng nối, bảng có `memberships`) |
| `lock_timeout`, `statement_timeout` của migration | Có trần |
| Kích thước lô của data migration | Có trần, chạy theo từng tenant |
| Yêu cầu ngoại lệ lint | Có lý do, người duyệt, ngày hết hạn |
| Yêu cầu extension | Chỉ qua ngoại lệ, vì mục 4.5 coi extension là nguồn rò rỉ |
| Thời điểm chạy, người duyệt cụ thể | Người duyệt phải thuộc nhóm được phép |

### 5. Kiểm thử (bước 3.3)

| Tham số | Giới hạn |
|---|---|
| Dữ liệu giả của ít nhất hai tenant | Bắt buộc, service viết phần dữ liệu theo nghiệp vụ |
| Test nghiệp vụ riêng | Tùy ý, chạy thêm vào bộ test chuẩn, không thay thế |
| Nguồn schema production để chạy kịch bản (b) | Dump schema-only hoặc snapshot đã ẩn danh |

### 6. Kết nối runtime (bước 4)

| Tham số | Giới hạn |
|---|---|
| Cách xác định tenant của request (claim JWT, subdomain, header...) | Tự chọn, nhưng giá trị đi vào wrapper phải qua xác thực |
| Kích thước pool phía service | Không vượt `CONNECTION LIMIT` chia cho số replica |
| Timeout cho mỗi request | Không vượt `statement_timeout` |
| Chính sách retry | Tự chọn, nhưng không retry lệnh ghi không idempotent |
| Rate limit theo tenant | Tự chọn, cần có (giảm noisy neighbor, mục 4.9) |
| Nội dung thông báo lỗi trả ra ngoài | Tự chọn, nhưng không được chứa message gốc của Postgres |

### 7. Vận hành (bước 5)

| Tham số | Giới hạn |
|---|---|
| Ngưỡng cảnh báo bổ sung | Chỉ **thêm** hoặc chặt hơn ngưỡng chuẩn |
| Thời gian giữ log | Có trần (log chứa giá trị, mục 4.10) |
| Lịch bảo trì riêng | Không trùng giờ audit drift |
| Đề xuất chuyển tenant lớn sang tầng riêng (hybrid) | Cần duyệt, vì đổi mô hình cách ly |

## Interface

| # | Thứ service dùng | Service dùng để làm gì | Vì sao cần | Dạng phát hành |
|---|---|---|---|---|
| 1 | **Thư viện truy cập DB (client library)** | Mở transaction, `SET LOCAL app.tenant_id` ngay đầu, quản lý pool, ánh xạ lỗi Postgres thành lỗi chung, cấm `SET` không `LOCAL` | Mục 4.8 cho thấy phần lớn rò rỉ đến từ trạng thái phiên và pool. 13 service tự viết thì sẽ có 13 cách sai khác nhau | Gói theo từng ngôn ngữ, hoặc một proxy/sidecar nếu ngôn ngữ quá đa dạng |
| 2 | **Hợp đồng credential** | Biết lấy mật khẩu `app_user` từ đâu, định dạng chuỗi kết nối, cách nhận biết và nạp lại khi xoay mật khẩu | `VALID UNTIL` bắt buộc xoay mật khẩu, nên service phải chịu được việc đổi credential mà không restart thủ công | Tài liệu và đường dẫn secret chuẩn (ví dụ Vault), kèm hành vi nạp lại trong thư viện |
| 3 | **Schema của manifest bảng** | Khai báo từng bảng là global, tenant, bảng nối hay bảng con, cột nào được `UPDATE` | Lint và audit cần một nguồn khai báo máy đọc được. Đây là file thứ hai, tách khỏi `service.yaml` vì nó gắn với migration | JSON Schema và ví dụ |
| 4 | **Bộ khung dự án (scaffold)** | Tạo service mới với cấu trúc thư mục, migration mẫu, manifest mẫu, cấu hình CI sẵn | Giảm khác biệt giữa 13 service, và service mới không thể quên bước nào | Template repo hoặc CLI sinh dự án |
| 5 | **CLI phát triển cục bộ** | Chạy lint trước khi push, sinh migration thêm bảng tenant (gọi `enable_tenant_rls`), chạy audit trên DB local | Dev nhận lỗi ngay trên máy thay vì chờ CI | Một binary hoặc image |
| 6 | **Môi trường local giống thật** | Dựng Postgres local đã chạy bootstrap chuẩn, có đủ role | Nếu dev chạy bằng `postgres` hoặc role khác, lỗi phân quyền chỉ lộ ở CI | `docker-compose` hoặc image do repo chuẩn phát hành |
| 7 | **Bộ test cách ly (test kit)** | Mở rộng bộ test chuẩn bằng test của chính mình: dữ liệu mẫu hai tenant, hàm chạy truy vấn dưới danh nghĩa `app_user` của tenant A rồi thử đọc, ghi dữ liệu tenant B | Ở bước 3.3 chỉ chạy bộ chuẩn. Service cần công cụ để kiểm tra cả truy vấn nghiệp vụ của mình | Thư viện test theo ngôn ngữ, hoặc fixture SQL |
| 8 | **Cấu hình pool chuẩn** | Dùng profile PgBouncer hoặc cấu hình pool đúng (transaction mode, reset khi trả kết nối) | Sai cấu hình pool là nguồn rò rỉ ở mục 4.8, và ở on-prem thường do service tự dựng | Template Helm/Ansible, hoặc file cấu hình mẫu |
| 9 | **Hợp đồng quan sát (observability)** | Ghi log theo định dạng chuẩn (có `tenant_id`, không có giá trị dữ liệu), xuất metric chuẩn, nhận dashboard và alert sẵn | Mục 4.10 coi log là nơi rò rỉ. Cần thống nhất ghi gì, không ghi gì | Tài liệu, logger wrapper, dashboard dạng code |
| 10 | **Quy trình đăng ký ngoại lệ và onboarding** | Xin ngoại lệ lint, xin cấp cluster mới, xin thay đổi tham số vượt khoảng | Ngoại lệ cần có lý do, người duyệt, hạn. Nếu không có đường chính thức thì dev sẽ tìm đường tắt | Issue template và PR template ở repo chuẩn |
| 11 | **Chính sách version và tương thích** | Biết bản workflow nào đi với bản bootstrap nào và bản thư viện nào, đọc changelog, lộ trình ngừng hỗ trợ | Với 13 service nâng cấp độc lập, nếu không có ma trận tương thích thì mỗi lần đổi chuẩn là một lần đoán mò | `CHANGELOG`, semver, bảng tương thích |
| 12 | **Reusable workflow** | | | |
| 13 | **Sql contract** | | | |
| 14 | **File tham số** | | | |

### Hai thứ nên cân nhắc thêm

| Thứ | Lý do | Ghi chú |
|---|---|---|
| **Công cụ vòng đời tenant** (thêm, xóa, xuất, khôi phục dữ liệu một tenant, chạy tác vụ xuyên tenant bằng `platform_admin`) | Mục 1 yêu cầu khôi phục tenant này không ảnh hưởng tenant khác, và `platform_admin` cần audit. Nếu mỗi service tự viết thì thao tác xuyên tenant sẽ rải rác | Có thể để sau, nhưng cần quyết định sớm là nó thuộc repo chuẩn hay từng service |
| **Helper cách ly ngoài database** (khóa cache, tiền tố file, header hàng đợi, filter search index) | Mục 1 nói cách ly phải áp dụng cho cache, file, hàng đợi, search. Repo hiện chỉ lo database | Đây là quyết định về phạm vi. Nếu thêm vào thì đổi tên và mục tiêu của repo từ "chuẩn Postgres" thành "chuẩn tenant isolation" |


## Phân chia job

| # | Bước | Ai chịu trách nhiệm | Ai kích hoạt | Chạy khi nào |
|---|---|---|---|---|
| 0 | Chuẩn hóa (repo chuẩn) | Đội nền tảng | Đội nền tảng | Khi chuẩn đổi, phát hành bản mới có version, chạy thử trên các service hiện có trước khi phát hành |
| 1 | Dựng database (manifest CNPG sinh từ `service.yaml`) | Đội nền tảng (repo hạ tầng) | Bot mở PR từ `service.yaml` sang repo hạ tầng, đội nền tảng duyệt | Khi có service mới, hoặc khi `service.yaml` đổi nhóm hạ tầng (cấu hình máy, replica, backup) |
| 2 | Bootstrap (role, quyền, helper RLS) | Đội nền tảng (`postgres`, từ mạng quản trị) | Pipeline hạ tầng, ngay sau bước 1 | Một lần sau khi dựng, rồi chạy lại khi nâng version repo chuẩn hoặc khi audit phát hiện drift |
| 3 | Migrate (`verify` và `deploy`) | Đội service (viết migration), đội nền tảng (workflow và quy tắc) | Đội service: PR chạy `verify`, merge vào `main` chạy `deploy` | Mỗi PR và mỗi lần phát hành bản mới. Production cần người duyệt thuộc nhóm được phép |
| 4 | Kết nối runtime (thư viện, pool) | Đội service (dùng thư viện), đội nền tảng (viết thư viện và profile pool) | Đội service khi nâng version thư viện | Mỗi lần build/deploy service. `verify` chạy test cách ly và quét code gọi pool trực tiếp |
| 5 | Vận hành liên tục (audit drift, xoay mật khẩu, backup/restore, log) | Đội nền tảng | Lịch ở repo chuẩn và Prometheus/Alertmanager | Audit drift hằng ngày, kiểm tra restore định kỳ, xoay mật khẩu theo chu kỳ `VALID UNTIL` |

| Workflow | Kích hoạt | Nội dung | Credential |
|---|---|---|---|
| `verify` | Mỗi PR | Kiểm tra `service.yaml` theo schema, lint, build image, dựng test cluster, audit, test cách ly, quét code | Không có credential production |
| `deploy` | Merge vào `main` | Chạy lại `verify` rồi preflight, phê duyệt, snapshot, migrate thật, post-check | `app_migrator`, cấp qua OIDC |

## Công nghệ

| Cách | Ưu | Nhược |
|---|---|---|
| Repo hạ tầng định kỳ đọc `service.yaml` của từng service (pull) | Service không có đường nào tới quyền cao | Chậm hơn, cần danh sách service |
| Bot mở PR sang repo hạ tầng khi `service.yaml` đổi | Có review của người giữ quyền | Thêm một bot phải bảo trì |
| Workflow của service kích hoạt workflow bên hạ tầng | Nhanh | Cần token liên repo, dễ trở thành đường leo thang |

Tôi nghiêng về cách 2, hoặc cách 1 nếu số service ít thay đổi.

## Công nghệ phổ biến và đánh đổi

### 1. Nền tảng workflow

| Công nghệ | Ưu | Nhược |
|---|---|---|
| **GitHub Actions** (reusable workflow) | Có sẵn OIDC với `job_workflow_ref`, org ruleset bắt buộc workflow, hệ sinh thái lớn | Cần self-hosted runner để tới DB on-prem. Reusable workflow bị giới hạn độ sâu lồng nhau. Quyền environment cấu hình ở repo service |
| **GitLab CI** (include, component) | Tích hợp sẵn registry và quản lý runner, chạy tốt on-prem | Cưỡng chế dùng đúng template yếu hơn, phải dựa vào cấu hình cấp group |
| **Jenkins** (shared library) | Rất linh hoạt, quen thuộc on-prem | Công bảo trì cao, cưỡng chế phụ thuộc kỷ luật, không có OIDC chuẩn |
| **Tekton / Argo Workflows** | Chạy gốc trên Kubernetes, tách quyền theo namespace tốt | Phải tự dựng nhiều thứ (trigger, UI, quản lý secret), đường cong học dài |
| **GitOps (Argo CD, Flux)** cho bước deploy | Trạng thái khai báo, có kiểm toán | Không thay được CI. Migration là tác vụ một lần, nên dùng hook (PreSync) thì khó theo dõi lỗi |

### 2. Công cụ migration

| Công cụ | Ưu | Nhược |
|---|---|---|
| **Flyway** | SQL thuần, độc lập ngôn ngữ, đơn giản, có checksum | Một số tính năng (undo, kiểm tra drift) nằm ở bản trả phí, cần kiểm tra lại theo phiên bản |
| **Liquibase** | Nhiều tính năng (rollback, diff), định dạng đa dạng | Nặng, định dạng XML/YAML dễ làm lint khó hơn SQL thuần |
| **Atlas** | Có lint và phát hiện drift gốc, hỗ trợ mô hình khai báo | Mới hơn, một số bộ kiểm tra nằm ở bản trả phí, cần kiểm tra lại |
| **golang-migrate** | Nhẹ, một binary, dễ đóng gói vào image | Ít tính năng, tự bổ sung khóa, kiểm tra, ghi vết |
| **Alembic / Prisma / ORM-native** | Tiện cho dev, gắn với model | Gắn ngôn ngữ nên 13 service khác ngôn ngữ sẽ khác công cụ. Có thể sinh SQL do máy viết, khó lint |

### 3. Lint migration

| Công nghệ | Ưu | Nhược |
|---|---|---|
| **Squawk** | Chuyên cho Postgres, bắt các lệnh gây khóa bảng | Không biết quy tắc tenant (RLS, `security_invoker`) |
| **Quy tắc tự viết trên parser Postgres** (libpg_query, pglast) | Bắt đúng quy tắc của bạn, nhìn được AST | Tự bảo trì |
| **sqlfluff** | Phổ biến, nhiều dialect | Thiên về định dạng, không đủ cho an toàn |
| **OPA/Conftest** trên AST | Quy tắc khai báo, có thể dùng chung với kiểm tra hạ tầng | Phải tự dựng bước chuyển SQL sang AST |

### 4. Test cluster (bước 3.3)

| Công nghệ | Ưu | Nhược |
|---|---|---|
| **Service container của runner** | Đơn giản nhất | Khó chạy được đúng bootstrap on-prem, môi trường rất khác thật |
| **Testcontainers** | Chạy cả local lẫn CI, dùng được từ nhiều ngôn ngữ | Mỗi lần dựng lại, chậm khi schema lớn |
| **Cụm tạm trên Kubernetes** (ví dụ CloudNativePG) | Gần production nhất, bắt được lỗi cấu hình | Chậm, tốn tài nguyên, cần cụm dành riêng cho CI |
| **VM/cụm dựng bằng chính Ansible của hạ tầng** | Đúng một mã nguồn với production | Chậm nhất, khó chạy trên mỗi PR |
| **pgTAP** (bộ kiểm tra) | Viết kiểm tra audit và cách ly ngay bằng SQL | Chỉ là khung kiểm tra, vẫn cần một trong các cách dựng ở trên |

### 5. Nơi chạy migration thật

| Công nghệ | Ưu | Nhược |
|---|---|---|
| **Self-hosted runner trên VM** | Dễ nối vào mạng quản trị | Phải dọn dẹp giữa các lần chạy, dễ để lại credential |
| **Self-hosted runner trên Kubernetes** (như ARC) | Mỗi job một pod mới, sạch sau mỗi lần | Cần cụm và cấu hình mạng tới DB |
| **Kubernetes Job do workflow tạo** (con đường B) | Tách quyền bằng ServiceAccount và NetworkPolicy | Thêm một lớp, log và lỗi khó theo dõi hơn |

### 6. Credential của `app_migrator`

| Công nghệ | Ưu | Nhược |
|---|---|---|
| **Vault, dùng OIDC/JWT của GitHub** | Chỉ cấp credential khi `job_workflow_ref` đúng. Có thể cấp **credential động, sống ngắn**, nên không còn mật khẩu cố định | Phải vận hành Vault |
| **Kubernetes Secret / External Secrets** | Đơn giản | Mật khẩu cố định, khó ràng buộc theo workflow |
| **Secret của GitHub** | Dễ nhất | Admin repo service đọc hoặc dùng được, trái mục tiêu cưỡng chế |

### 7. Dựng database và bootstrap (bước 1, 2)

| Công nghệ | Ưu | Nhược |
|---|---|---|
| **Ansible** | Hợp VM on-prem, idempotent, chạy được cả SQL bootstrap | Phải tự quản lý trạng thái và drift |
| **Terraform** (kèm provider PostgreSQL) | Có trạng thái, dễ chuyển lên cloud | Mật khẩu role nằm trong state. Trên on-prem thường chỉ dựng được phần hạ tầng bên dưới |
| **Operator Kubernetes** (CloudNativePG, Zalando, Crunchy) | Tự lo HA, backup, nâng cấp | Chỉ khi chạy Postgres trên Kubernetes, ít kiểm soát `pg_hba` ở mức thấp |
| **Patroni trên VM** | Trưởng thành, nhiều người dùng on-prem | Tự vận hành, cần Ansible đi kèm |

### 8. Audit drift định kỳ (bước 5)

| Cách | Ưu | Nhược |
|---|---|---|
| **Workflow chạy theo lịch ở repo chuẩn** | Cùng công cụ với phần còn lại, dễ viết | Cần runner có đường tới mọi cluster, cảnh báo đi qua đường phụ |
| **CronJob/exporter trong hạ tầng + Prometheus/Alertmanager** | Vào luôn hệ thống giám sát có sẵn, theo dõi liên tục | Phải viết exporter cho các truy vấn audit |
| **Công cụ audit chuyên dụng** (ví dụ pgAudit cho nhật ký truy cập) | Ghi lại ai làm gì | Là nhật ký, không thay cho đối chiếu catalog với chuẩn |

## Công nghệ đã chốt:
| Bước | Công nghệ |
|---|---|
| workflow | Github actions (github.com) |
| migration | Flyway |
| linter | Squawk |
| test cluster | Cụm tạm Kube trên runner |
| migrator | Kube job do workflow tạo |
| secret manager | Vault |
| bootsrap | CNPG |
| audit | Prometheus |