**Tiền đề:** mọi test hành vi phải chạy bằng role app (không superuser, không `BYPASSRLS`). Superuser và `BYPASSRLS` bỏ qua RLS, nên test chạy bằng role đó sẽ pass giả.

## A. `current_tenant_id()`
1. **GUC chưa set → `NULL`, không lỗi.** Vì có `missing_ok=true`, đây là nền của fail-closed.
2. **GUC = `''` → `NULL`.** Sau `SET LOCAL` kết thúc, GUC có thể còn lại chuỗi rỗng trên connection pool.
3. **UUID hợp lệ → trả đúng uuid** (kể cả chữ hoa).
4. **Chuỗi không phải uuid → lỗi `22P02`.** Chốt hành vi này trong contract: query fail to, không rò dữ liệu.
5. **`SET LOCAL` không rò qua transaction sau trên cùng connection.** Tx1 set tenant A rồi commit, tx2 không set thì phải ra `NULL`.
6. **Metadata: `provolatile='s'`, `proparallel='s'`, không `SECURITY DEFINER`.** Ai đó đổi thành `VOLATILE` sẽ làm hàm bị gọi từng row và mất index.

## B. `apply_tenant_rls()` – cấu trúc
7. **Sau khi gọi: `relrowsecurity` và `relforcerowsecurity` đều `true`.** Thiếu `FORCE` thì owner bypass RLS.
8. **Đúng 1 policy `tenant_isolation`, `cmd = ALL`, `qual` và `with_check` đều khác NULL và chứa `current_tenant_id()`.** Chặn drift, ví dụ ai đó xóa `WITH CHECK`.
9. **Gọi 2 lần: không lỗi, vẫn 1 policy.** Migration phải idempotent.
10. **Policy bị sửa tay (`USING (true)`), gọi lại thì được khôi phục.** Đó là mục đích của `DROP POLICY IF EXISTS`.
11. **Bảng thiếu cột `tenant_id` (hoặc sai kiểu) → lỗi, và RLS không bị bật dở.** Test tính atomic của DDL trong transaction.
12. **Tên bảng đặc biệt:** schema khác, chữ hoa/quoted. Vì `%s` với `regclass` dễ vỡ ở quoting.
13. **Bảng partitioned: áp lên parent không bảo vệ query trực tiếp vào partition.** Test để biết partition có phải gọi riêng không.

## C. Hành vi cách ly (quan trọng nhất)
14. **Tenant A chỉ thấy row A, B chỉ thấy row B** (`SELECT`).
15. **Không set tenant → 0 row.** Đây là fail-closed.
16. **`INSERT` với `tenant_id` của tenant khác → bị từ chối (`42501`); với tenant mình → OK.** Test `WITH CHECK`.
17. **`INSERT` với `tenant_id = NULL` → bị từ chối.** Row NULL sẽ thành "mồ côi", không ai thấy.
18. **`UPDATE`/`DELETE` row tenant khác → 0 row bị ảnh hưởng.**
19. **`UPDATE ... SET tenant_id = <tenant khác>` → bị từ chối.** Chống "đẩy" row sang tenant khác.
20. **`RETURNING`, `SELECT FOR UPDATE`, `INSERT ... ON CONFLICT DO UPDATE` không chạm/lộ row tenant khác.**
21. **Owner (role migrate) không set tenant → 0 row.** Xác nhận `FORCE` có tác dụng thật.
22. **Hai connection đồng thời với 2 tenant khác nhau không lẫn nhau.**

## D. Guard cho pipeline và phân quyền
23. **Quét catalog: mọi bảng có cột `tenant_id` phải có RLS + FORCE + policy `tenant_isolation`** (có allowlist cho bảng ngoại lệ). Đây là test quan trọng nhất cho pipeline, vì bắt trường hợp quên gọi `apply_tenant_rls` ở migration mới.
24. **Role app: không phải owner, không `BYPASSRLS`, không superuser; không `ALTER TABLE`, `DISABLE RLS`, `DROP POLICY`, `TRUNCATE`.** Nếu không thì RLS chỉ là trang trí.
25. **`apply_tenant_rls` không `EXECUTE` được bởi role app** (mặc định `PUBLIC` có quyền execute).
26. **App role không tạo được hàm `current_tenant_id` trong schema đứng trước ở `search_path`.** Chống search_path hijack, vì policy resolve hàm theo tên.
27. **`EXPLAIN` truy vấn theo tenant dùng index có `tenant_id`, và `current_tenant_id()` được tính 1 lần (InitPlan).** Bắt regression về hiệu năng.

## Gap test (tùy chọn, chỉ làm nếu schema của bạn có)
- **Unique constraint không gồm `tenant_id`:** 2 tenant cùng business key sẽ xung đột, và lỗi unique làm lộ sự tồn tại của row tenant khác.
- **FK không gồm `tenant_id`:** RI check bypass RLS, nên row tenant A tham chiếu được parent của tenant B.
- **View trên bảng tenant:** view chạy quyền owner nên bypass RLS, trừ khi `security_invoker = true` (PG15+).