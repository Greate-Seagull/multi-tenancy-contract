# ADR-0013: Side channel: biện pháp giảm thiểu và rủi ro chấp nhận

- Trạng thái: Proposed
- Ngày: 2026-10-12

## Bối cảnh
RLS không chặn được suy luận gián tiếp qua thời gian, khóa, lỗi ràng buộc, sequence, thống kê (mục 4.9). Pipeline không loại bỏ hết được, chỉ giảm bằng thiết kế.

## Quyết định
Biện pháp bắt buộc:
- UUID thay vì sequence cho ID.
- Unique và FK luôn gồm `tenant_id`, nên lỗi ràng buộc không lộ dòng của tenant khác.
- Lỗi Postgres không trả nguyên ra ngoài, 404 thay vì 403.
- Không cấp `pg_stat_*`, `pg_stats`, `pg_stat_statements` cho `app_user`. `EXPLAIN` chỉ ở môi trường dev.
- `statement_timeout`, `idle_in_transaction_session_timeout`, `CONNECTION LIMIT`, rate limit theo tenant.
- Hàm dùng trong policy và `WHERE` phải leakproof hoặc tránh hàm tùy ý có thể lỗi trên dòng chưa được lọc.

Rủi ro còn lại được **ghi nhận, không cam kết đã loại bỏ**: timing theo tải chung (CPU, I/O, buffer cache), thời gian thực thi theo giá trị, khóa dòng, autovacuum, kích thước bảng và WAL. Nếu có tenant đòi hỏi cao hơn, chuyển sang tầng cách ly mạnh hơn (hybrid) qua ADR riêng.

## Hệ quả
Giảm bề mặt tấn công với chi phí thấp, đồng thời nêu rõ giới hạn với khách hàng và đội bảo mật.

## Liên quan
ADR-0001, ADR-0006, ADR-0012.
