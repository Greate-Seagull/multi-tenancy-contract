# ADR-0014: Vận hành liên tục: audit drift, giám sát, backup, log, xoay mật khẩu

- Trạng thái: Proposed
- Ngày: 2026-10-12

## Bối cảnh
Pipeline chạy một lần không phát hiện được thay đổi ngoài pipeline (sửa tay, console, DBA) thuộc nhóm trao quyền gián tiếp (mục 4.7), và dữ liệu ngoài bảng (mục 4.10) không thuộc bước nào khác.

## Quyết định
Do đội nền tảng sở hữu, chạy từ repo chuẩn (không đặt trong repo service vì service có thể tắt job của chính mình):
- **Audit drift hằng ngày** cho mọi cluster: thuộc tính role, membership, ACL, RLS, owner, cấu hình (`pg_settings` so với baseline), `pg_hba`. Triển khai bằng CronJob/exporter xuất metric vào **Prometheus**, cảnh báo qua Alertmanager. Khi lệch, chạy lại bootstrap như reconcile.
- Cảnh báo cấu hình và role gửi đội nền tảng, cảnh báo kết nối và tải gửi đội service.
- **Xoay mật khẩu** theo `VALID UNTIL` (credential động qua Vault, ADR-0010).
- **Backup/WAL archive:** mã hóa, hạn chế quyền truy cập, kiểm tra restore định kỳ, khôi phục tenant này không ảnh hưởng tenant khác.
- **Log:** tham số log không ghi giá trị tham số, thời gian giữ có trần, quyền đọc hạn chế. `shared_preload_libraries` chỉ nạp thành phần được duyệt (`pg_stat_statements`, `auto_explain` thu thập câu lệnh nên cần kiểm soát quyền đọc).
- **Dev/test:** dữ liệu production phải ẩn danh trước khi nạp vào môi trường kém bảo mật.
- Thay đổi khẩn cấp chạy tay phải ghi lại, sau đó đưa vào migration, audit sẽ đối chiếu.

## Hệ quả
Phát hiện lệch cấu hình sớm. Cần viết exporter cho các truy vấn audit và duy trì hạ tầng giám sát.

## Liên quan
ADR-0003, ADR-0004, ADR-0010, ADR-0011.
