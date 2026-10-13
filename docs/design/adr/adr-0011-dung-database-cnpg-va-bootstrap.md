# ADR-0011: Dựng database bằng CloudNativePG và cách chạy bootstrap

- Trạng thái: Proposed (cần PoC, StackGres còn đang cân nhắc)
- Ngày: 2026-10-12

## Bối cảnh
Postgres chạy trên Kubernetes on-prem, mỗi service một cluster (ADR-0002). Bước 1 và 2 phải tự động và lặp lại được cho 13 cluster.

## Quyết định
- Dùng **CloudNativePG (CNPG)**. Manifest `Cluster` được sinh từ `service.yaml` (ADR-0007) và áp dụng qua repo hạ tầng.
- Role khai báo qua `managed.roles` ở mức có thể, phần còn lại (`REVOKE`, `ALTER DEFAULT PRIVILEGES`, helper SQL) do bootstrap của repo chuẩn.
- SQL khởi tạo của CNPG chỉ chạy một lần, nên bootstrap chạy lại như reconcile qua một **Job `exec` vào pod primary bằng socket cục bộ** (quyền kiểm soát bằng RBAC `pods/exec`), không mở mật khẩu superuser ra mạng.
- Extension gắn với image, thêm extension là đổi image và qua review.
- Backup/WAL archive qua Barman Cloud tới object storage kiểu S3 (MinIO/Ceph on-prem), phải mã hóa và hạn chế quyền (mục 4.10).

**PoC bắt buộc trước khi chốt**, với CNPG hoặc StackGres:
1. Tạo `app_owner` (`NOLOGIN`) và `app_migrator` là thành viên, đủ thuộc tính mục 3.6.2.
2. Kiểm soát `pg_hba` (operator tự chèn quy tắc, thứ tự dòng quan trọng).
3. Chạy được `REVOKE ... FROM PUBLIC` và `ALTER DEFAULT PRIVILEGES`.
4. Đặt `max_prepared_transactions=0`, TLS, `scram-sha-256`, log đúng chuẩn.
5. Chạy lại bootstrap khi phát hiện drift.

## Phương án đã xét
- **StackGres** (Patroni + sidecar, CRD cấu hình tách riêng, có web console, giấy phép AGPLv3 bản community): hợp nếu cần web console, nhiều extension linh hoạt hoặc cấu hình chuẩn dùng chung. Thiên lệch về CNPG ở đây vì extension gắn image (chặt hơn, phù hợp mục 4.5-4.6), role khai báo giúp chống drift, ít sidecar hơn nên nhẹ hơn khi có 13 cluster. Thông tin so sánh dựa trên hiểu biết chung, cần kiểm chứng ở PoC.
- Zalando, Crunchy: chưa đánh giá chi tiết.
- Patroni trên VM + Ansible: không chọn vì đã chọn Kubernetes.

## Liên quan
ADR-0002, ADR-0003, ADR-0014.
