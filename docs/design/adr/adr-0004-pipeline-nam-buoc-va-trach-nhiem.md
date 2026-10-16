# ADR-0004: Pipeline 5 bước (cộng bước 0) và phân chia trách nhiệm

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
Pipeline ban đầu (dựng database, bootstrap, migrate) chỉ kiểm soát trạng thái tĩnh. Thiếu phần kết nối từ service, kiểm chứng, phát hiện drift và vận hành.

## Quyết định

| # | Bước | Chịu trách nhiệm | Kích hoạt | Chạy khi nào |
|---|---|---|---|---|
| 0 | Chuẩn hóa (repo chuẩn) | Đội nền tảng | Đội nền tảng | Khi chuẩn đổi, phát hành có version, chạy thử trên service hiện có |
| 1 | Dựng database | Đội nền tảng (repo hạ tầng) | Bot mở PR từ `service.yaml`, đội nền tảng duyệt | Service mới hoặc đổi tham số hạ tầng |
| 2 | Bootstrap | Đội nền tảng (`postgres`, mạng quản trị) | Pipeline hạ tầng sau bước 1 | Một lần sau khi dựng, chạy lại khi nâng version chuẩn hoặc phát hiện drift |
| 3 | Migrate | Đội service (migration), đội nền tảng (workflow, quy tắc) | PR chạy `verify`, merge chạy `deploy` | Mỗi PR và mỗi lần phát hành, production cần người duyệt |
| 4 | Kết nối runtime | Đội service (dùng), đội nền tảng (thư viện, profile pool) | Khi build/deploy service | `verify` kiểm tra test cách ly và quét code gọi pool trực tiếp |
| 5 | Vận hành liên tục | Đội nền tảng | Lịch ở repo chuẩn, Prometheus/Alertmanager | Audit drift hằng ngày, kiểm tra restore định kỳ, xoay mật khẩu theo chu kỳ |

Nguyên tắc:
- Mỗi bước có cổng kiểm tra đi kèm (không dồn về cuối).
- Đội service không có quyền ở bước 1, 2, 5, chỉ tác động qua `service.yaml` có giới hạn và migration.
- Bootstrap phải idempotent để dùng như bước reconcile.
- Chuẩn hóa phần bảo vệ, không chuẩn hóa phần nghiệp vụ. Càng gần đặc quyền càng ít phần để service tự chọn.

## Hệ quả
Rõ ai làm gì, nhưng đội nền tảng trở thành điểm tập trung công việc và cần đủ nhân lực.

## Liên quan
ADR-0005, ADR-0008, ADR-0014.
