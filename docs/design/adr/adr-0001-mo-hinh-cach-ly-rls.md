# ADR-0001: Mô hình cách ly tenant: chung bảng + `tenant_id` + RLS

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
Hệ thống có nhiều tenant nhỏ, ưu tiên chi phí phát triển. Lỗi nghiêm trọng nhất là rò rỉ dữ liệu giữa các tenant (đọc, ghi, suy ra gián tiếp). Tài liệu "Tenant isolation" đã so sánh 7 giải pháp.

## Quyết định
Dùng giải pháp 2: chung bảng, mỗi bảng tenant có `tenant_id`, Postgres ép buộc bằng Row Level Security (`ENABLE` + `FORCE`, policy có `USING` và `WITH CHECK`). Tenant được xác định qua biến phiên `app.tenant_id` đặt bằng `SET LOCAL`.

## Hệ quả
- Tốt: database là hàng rào, code ứng dụng sót `WHERE` cũng không lộ. Rẻ, dễ mở rộng số tenant.
- Đánh đổi: RLS thêm chi phí truy vấn. Phải quản lý biến phiên cẩn thận với connection pool (xem ADR-0012). Superuser, `BYPASSRLS` và owner không `FORCE` bỏ qua RLS (xem ADR-0003). Noisy neighbor vẫn còn (xem ADR-0013).
- **Giới hạn đã biết:** `app_user` tự `SET` được `app.tenant_id`, nên RLS chỉ chống lỗi *quên điều kiện*, không chống kẻ chạy được SQL tùy ý (SQL injection, RCE). Service không được nhận SQL thô, và service bị chiếm được coi là mất cách ly.
- Cách ly phải áp dụng cả ngoài database (cache, file, log, search index, hàng đợi, backup). Phạm vi ngoài database chưa nằm trong bộ ADR này (xem "Vấn đề còn mở" ở mục lục).

## Phương án đã xét
Giải pháp 1 (chỉ điều kiện ở ứng dụng, không có hàng rào), 3 (schema theo tenant, migration lặp và catalog phình), 4-5 (database/cluster theo tenant, không hợp nhiều tenant nhỏ), 6 (hybrid, phức tạp nhất, có thể dùng sau cho tenant lớn), 7 (sharding, không tự cách ly).
