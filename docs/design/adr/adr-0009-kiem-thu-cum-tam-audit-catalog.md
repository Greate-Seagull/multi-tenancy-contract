# ADR-0009: Kiểm thử: cụm tạm Kubernetes, audit catalog và test cách ly

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
Lint chỉ là lớp sớm và có điểm mù. Lớp quyết định phải kiểm tra kết quả thực tế. Test chỉ có giá trị khi môi trường giống production.

## Quyết định
- Dựng cụm tạm Kubernetes trên runner cho mỗi lần chạy `verify`, cài **đúng phiên bản operator và manifest** như production (chỉ giảm kích thước), chạy **đúng bootstrap** của repo chuẩn.
- Chạy hai kịch bản: (a) từ database trống chạy toàn bộ chuỗi migration, (b) từ schema hiện tại của production (schema-only dump hoặc snapshot ẩn danh) lên bản mới.
- Nạp dữ liệu giả của ít nhất hai tenant.
- Sau migrate chạy: audit catalog (thuộc tính role, membership, ACL, RLS `ENABLE`/`FORCE`, policy có `WITH CHECK`, owner đúng, view có `security_invoker`), test cách ly bằng `app_user` thật (tenant A đọc, ghi, đổi `tenant_id`, `COPY`, gọi view/function trên dữ liệu tenant B), đo thời gian giữ khóa. Kiểm tra bằng pgTAP hoặc tương đương.
- Production chỉ audit bằng catalog, không ghi dữ liệu test vào tenant thật.
- Runner của cụm tạm không nằm cùng cụm hay cùng mạng với database production. Nếu cần quyền đặc quyền (kind/DinD), dùng cụm CI riêng, mỗi run một namespace hoặc vcluster.

## Hệ quả
Bắt được lỗi cấu hình, lỗi dữ liệu sẵn có và lỗi cách ly trước khi deploy. Đánh đổi: chậm và tốn tài nguyên hơn container Postgres đơn thuần. Có thể chạy bản nhẹ cho mỗi PR và bản đầy đủ trước deploy nếu thời gian quá dài (chưa quyết định).

## Liên quan
ADR-0003, ADR-0008, ADR-0011.
