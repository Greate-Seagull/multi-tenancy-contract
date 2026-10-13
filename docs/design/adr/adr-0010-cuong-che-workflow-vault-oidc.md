# ADR-0010: Cưỡng chế workflow và cấp credential bằng Vault + OIDC

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
Reusable workflow chỉ đảm bảo các bước, còn secret, environment và reviewer cấu hình ở repo service. Admin service có thể gỡ reviewer hoặc tự viết workflow riêng. Credential `app_migrator` không được nằm trong secret của GitHub.

## Quyết định
- Dùng **Vault** làm nguồn credential, xác thực bằng token OIDC của GitHub. Role Vault chỉ cấp khi claim `job_workflow_ref` trỏ đúng workflow `deploy` của repo chuẩn (đúng tag), kèm điều kiện `environment` là production và ref là `main`.
- Credential cho `app_migrator` là **credential động, sống ngắn**, khớp với `VALID UNTIL`. `app_user` dùng secret ở đường dẫn riêng, không dùng chung với `app_migrator`.
- Với con đường B (Kubernetes Job): workflow xin **wrapping token dùng một lần**, chuyển cho Job, Job tự mở để lấy credential. Không chuyển nguyên credential qua Secret hoặc biến môi trường.
- Org ruleset bắt buộc `verify` chạy trên PR (required workflow). Pin reusable workflow theo SHA hoặc tag bất biến, CI cảnh báo khi dùng bản quá cũ.
- Credential `app_migrator` chỉ cấp từ runner/Job trong mạng quản trị/CI (khớp `pg_hba`). Vì dùng github.com, Vault phải nhận được token OIDC từ GitHub (cần quyết định vị trí đặt Vault hoặc đường mạng, xem ADR-0016, câu hỏi còn mở).
- Hợp đồng credential cho service: đường dẫn secret chuẩn và hành vi nạp lại khi xoay mật khẩu nằm trong thư viện (ADR-0012).

## Hệ quả
Service không thể tự viết workflow để lấy credential production. Đánh đổi: phải vận hành Vault, và cần cấu hình mạng giữa GitHub, Vault, runner, cụm.

## Liên quan
ADR-0003, ADR-0008.
