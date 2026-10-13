# ADR-0007: `service.yaml` và ranh giới tham số service được tác động

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
13 service cần tự cấu hình một số thứ nhưng không được làm yếu các biện pháp bảo vệ.

## Quyết định
Tất cả tham số nằm trong một file `service.yaml` ở repo service, được kiểm tra theo JSON Schema của repo chuẩn (kiểu, khoảng cho phép, mặc định). Vượt khoảng thì pipeline đỏ.

Service được tác động (có giới hạn):
- Định danh: tên service, môi trường (tên database, schema, role sinh từ tên service).
- Hạ tầng (bước 1): cấu hình máy theo bậc, dung lượng, phiên bản Postgres chuẩn, số replica, thời gian giữ backup (chỉ tăng), cửa sổ bảo trì.
- Bootstrap: `CONNECTION LIMIT`, timeout của `app_user`, chu kỳ xoay mật khẩu.
- Migrate: nội dung migration, manifest bảng, cột được `UPDATE`, biến thể helper, timeout và kích thước lô, yêu cầu ngoại lệ.
- Kiểm thử: dữ liệu giả của ít nhất hai tenant, test nghiệp vụ.
- Runtime: cách xác định tenant (giá trị phải qua xác thực), kích thước pool (không vượt `CONNECTION LIMIT` chia số replica), retry, rate limit theo tenant.
- Vận hành: ngưỡng cảnh báo bổ sung (chỉ chặt hơn), thời gian giữ log (có trần).

Service không được tác động: thuộc tính role, membership, quyền `pg_*`, `pg_hba`, TLS, `password_encryption`, `shared_preload_libraries`, `max_prepared_transactions`, tên biến `app.tenant_id`, nội dung policy (chỉ chọn biến thể), việc bỏ hay tắt bước workflow, credential `app_migrator`, trust policy OIDC, và việc dùng `PREPARE TRANSACTION`, `SECURITY DEFINER`, materialized view, `SET` không `LOCAL`.

Thay đổi nhóm hạ tầng trong `service.yaml` chỉ được kiểm tra schema ở workflow service, việc áp dụng do repo hạ tầng nhận qua bot mở PR (có review).

## Hệ quả
Có tham số nhưng không có tùy chọn bỏ qua. Bậc kích thước chuẩn (S/M/L) nên dùng thay cho cấu hình máy tự do để giảm số trường hợp cần kiểm thử (đề xuất, chưa chốt).

## Liên quan
ADR-0004, ADR-0005.
