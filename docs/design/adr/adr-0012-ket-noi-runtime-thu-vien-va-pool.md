# ADR-0012: Kết nối runtime: thư viện truy cập DB và cấu hình pool

- Trạng thái: Proposed
- Ngày: 2026-10-12

## Bối cảnh
Mục 4.8 cho thấy phần lớn rò rỉ đến từ trạng thái phiên và connection pool. 13 service tự viết sẽ có nhiều cách sai khác nhau. Lưu ý: PgBouncer chế độ transaction mặc định **không** chạy `server_reset_query`, nên không dựa vào `DISCARD ALL`.

## Quyết định
- Chỉ có một đường vào database: **thư viện truy cập DB** của repo chuẩn, mở transaction, `SET LOCAL app.tenant_id` ngay dòng đầu, rồi mới chạy truy vấn. Cấm code gọi pool trực tiếp (kiểm tra bằng quét code ở `verify`).
- Không để trạng thái phiên tồn tại: chỉ `SET LOCAL`, cấm `SET` không `LOCAL`, bảng tạm, `LISTEN`, `CURSOR WITH HOLD`, advisory lock mức phiên. Kiểm tra bằng test.
- Pool: PgBouncer chế độ transaction, profile cấu hình chuẩn. Prepared statement ở cấp giao thức chỉ dùng khi bản PgBouncer hỗ trợ ở chế độ transaction.
- Lỗi Postgres được ánh xạ thành lỗi chung, không trả message gốc ra ngoài. Trả 404 thay vì 403 với tài nguyên của tenant khác.
- Thư viện nạp lại credential `app_user` khi xoay mật khẩu mà không restart thủ công.
- Service không nhận SQL thô, dùng truy vấn tham số hóa/ORM.
- Hình thức phát hành (thư viện theo ngôn ngữ hay proxy/sidecar chung) **chưa quyết định**, phụ thuộc số ngôn ngữ của 13 service.

## Hệ quả
Một chỗ sửa cho mọi service. Đánh đổi: phải duy trì thư viện cho từng ngôn ngữ hoặc vận hành thêm một thành phần proxy.

## Liên quan
ADR-0001, ADR-0013, ADR-0015.
