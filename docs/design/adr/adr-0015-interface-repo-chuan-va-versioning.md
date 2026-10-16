# ADR-0015: Interface repo chuẩn cung cấp cho service và chính sách version

- Trạng thái: Proposed
- Ngày: 2026-10-12

## Bối cảnh
Cần xác định rõ service dùng gì của repo chuẩn. Migration runner image nằm sau reusable workflow nên service chỉ thấy qua tag version.

## Quyết định
Repo chuẩn cung cấp 14 thứ cho service:

| # | Thứ cung cấp | Trạng thái |
|---|---|---|
| 1 | Reusable workflow (`verify`, `deploy`) | Quyết định (ADR-0008) |
| 2 | File tham số `service.yaml` + schema | Quyết định (ADR-0007) |
| 3 | Hàm SQL của contract | Đề xuất (ADR-0006) |
| 4 | Thư viện truy cập DB | Đề xuất (ADR-0012) |
| 5 | Hợp đồng credential (đường dẫn secret, nạp lại khi xoay) | Đề xuất (ADR-0010) |
| 6 | Schema manifest bảng | Đề xuất (ADR-0006) |
| 7 | Bộ khung dự án (scaffold) | Đề xuất |
| 8 | CLI phát triển cục bộ (lint, sinh migration, audit local) | Đề xuất |
| 9 | Môi trường local giống thật (Postgres đã chạy bootstrap chuẩn) | Đề xuất |
| 10 | Test kit cách ly (fixture hai tenant, chạy truy vấn dưới danh nghĩa `app_user`) | Đề xuất |
| 11 | Profile cấu hình pool chuẩn (PgBouncer) | Đề xuất (ADR-0012) |
| 12 | Hợp đồng quan sát (log có `tenant_id`, không có giá trị dữ liệu, metric, dashboard) | Làm khi cần |
| 13 | Quy trình ngoại lệ và onboarding (issue/PR template) | Làm khi cần |
| 14 | Chính sách version: semver, `CHANGELOG`, bảng tương thích giữa workflow, bootstrap, thư viện, lộ trình ngừng hỗ trợ | Đề xuất |

Thứ tự: cần trước khi service đầu tiên dùng là 1-7, 10, 14. Làm song song hoặc ngay sau là 8, 9, 11. Làm khi có nhu cầu thật là 12, 13.

Nên cân nhắc thêm (chưa quyết định): công cụ vòng đời tenant (thêm, xóa, xuất, khôi phục, tác vụ xuyên tenant bằng `platform_admin`), và helper cách ly ngoài database (khóa cache, tiền tố file, header hàng đợi, filter search index). Phần sau đổi phạm vi repo từ "chuẩn Postgres" thành "chuẩn tenant isolation".

## Hệ quả
Service có đường chính thức cho mọi việc, giảm khác biệt giữa 13 service. Đổi lại, repo chuẩn có nhiều thành phần phải duy trì và cần ma trận tương thích rõ ràng.

## Liên quan
ADR-0005, ADR-0006, ADR-0007, ADR-0008, ADR-0012.
