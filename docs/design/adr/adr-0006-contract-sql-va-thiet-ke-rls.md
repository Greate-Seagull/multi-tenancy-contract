# ADR-0006: Contract SQL: helper RLS, `current_tenant()` và quy tắc thiết kế bảng

- Trạng thái: Proposed
- Ngày: 2026-10-12

## Bối cảnh
Nếu mỗi migration tự viết policy thì dễ quên `tenant_id`, `FORCE`, `WITH CHECK` (mục 4.5). Policy cần hoạt động đúng cả khi biến phiên chưa được đặt.

## Quyết định
Repo chuẩn cung cấp các hàm SQL cài trong bootstrap:
- `enable_tenant_rls('<bảng>', <biến thể>)`: đảm bảo có cột `tenant_id`, `ENABLE` + `FORCE`, policy `USING` và `WITH CHECK`, grant hẹp cho `app_user` (không gồm `tenant_id` trong cột được `UPDATE`). Biến thể có sẵn: bảng tenant, bảng con, bảng nối, bảng có `memberships`.
- `current_tenant()`: dùng `current_setting('app.tenant_id', true)`, trả NULL khi chưa đặt để policy chặn hết (fail closed).
- Hàm helper là `SECURITY INVOKER`, owner `app_owner`, `REVOKE EXECUTE FROM PUBLIC`. Hàm `SECURITY DEFINER` bị cấm vì bỏ qua RLS.

Quy tắc thiết kế bảng:
- Mọi bảng phải được phân loại trong manifest: global, tenant, bảng nối, bảng con, kỹ thuật (mục 4.1).
- Unique và FK luôn gồm `tenant_id` (FK kép).
- ID dùng UUID, không dùng serial.
- Cấm materialized view, view phải có `security_invoker = true`. Partition con và bảng `INHERITS` phải có RLS riêng.
- `CREATE EXTENSION` chỉ qua ngoại lệ có duyệt.

## Hệ quả
Migration ngắn hơn và đồng nhất. Nhược điểm: mọi trường hợp đặc biệt phải thêm biến thể vào helper hoặc xin ngoại lệ.

## Liên quan
ADR-0001, ADR-0003, ADR-0008, ADR-0013.
