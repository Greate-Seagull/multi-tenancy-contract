# ADR-0003: Mô hình role và phân quyền

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
RLS chỉ có tác dụng khi role không thể bỏ qua hoặc tự sửa nó. Mục 3 và 4.7 của tài liệu liệt kê các lệch cấu hình làm vô hiệu cách ly.

## Quyết định
Bốn role bắt buộc, tên nhận tiền tố qua tham số:

| Role | Dùng bởi | Thuộc tính chính |
|---|---|---|
| `postgres` | DBA/pipeline hạ tầng, thủ công | Superuser. Không dùng cho ứng dụng, chỉ kết nối từ mạng quản trị |
| `app_owner` | Không đăng nhập | `NOLOGIN`, sở hữu mọi bảng, view, function, sequence. Bảng `FORCE ROW LEVEL SECURITY` |
| `app_migrator` | Job migration | Thành viên `app_owner`, `CONNECTION LIMIT` 1-2, `VALID UNTIL`, chỉ kết nối từ mạng quản trị/CI |
| `app_user` | Service | `NOSUPERUSER`, `NOBYPASSRLS`, không là thành viên role nào, `ALTER ROLE ... SET row_security = on` |

Các quy tắc đi kèm:
- Không cấp `pg_read_all_data`, `pg_write_all_data`, `pg_*_server_*`, `pg_monitor`, `pg_signal_backend` cho `app_user`.
- `REVOKE ... FROM PUBLIC` ở database và schema, `REVOKE TEMP` cho PUBLIC. `app_user` chỉ có `SELECT, INSERT, UPDATE, DELETE` (không `TRUNCATE`, `REFERENCES`, `TRIGGER`), `UPDATE` theo cột và không gồm `tenant_id`.
- `ALTER DEFAULT PRIVILEGES FOR ROLE app_owner` để đối tượng mới có quyền hẹp.
- `app_migrator` phải chạy DDL với `SET ROLE app_owner` (đặt `ALTER ROLE app_migrator SET role = app_owner` hoặc `PGOPTIONS`).
- Các role `app_readonly`, `platform_admin`, `backup`, `monitor`, `replicator`, `auditor` là "cần trong tương lai", chỉ thêm khi có nhu cầu, mỗi cái qua ADR riêng.

## Hệ quả
- Tốt: ranh giới rõ, `app_user` không tự sửa được policy, đối tượng mới có quyền đúng.
- Đánh đổi: bootstrap phức tạp hơn, và cần audit catalog định kỳ để phát hiện lệch (xem ADR-0014).

## Liên quan
ADR-0006, ADR-0010, ADR-0014.
