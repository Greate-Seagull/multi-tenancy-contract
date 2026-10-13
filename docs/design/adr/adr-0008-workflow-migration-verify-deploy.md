# ADR-0008: Workflow migration: hai reusable workflow `verify` và `deploy` trên GitHub Actions

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
Service cần một đường migrate đồng nhất, không tự bỏ bước. Con đường migrate được chọn là CI/CD (A) và Kubernetes Job do workflow tạo (B). Loại bỏ migrate lúc khởi động service và chạy tay (credential `app_migrator` sẽ nằm ở service hoặc không có review).

## Quyết định
Dùng GitHub Actions (github.com) với hai reusable workflow cùng gọi runner image có version của repo chuẩn:

| Workflow | Kích hoạt | Nội dung | Credential production |
|---|---|---|---|
| `verify` | Mỗi PR | Kiểm tra `service.yaml`, lint, build image, dựng cụm tạm, audit, test cách ly, quét code | Không |
| `deploy` | Merge vào `main` | Gọi `verify`, rồi preflight audit, phê duyệt, snapshot, migrate thật, post-check, ghi vết | `app_migrator` qua Vault |

Chi tiết:
- Công cụ migration: **Flyway** (SQL thuần). Lint: **Squawk** cộng quy tắc tự viết trên parser Postgres, cấm `DO $$` và `EXECUTE` động, chặn sửa migration đã áp dụng (checksum), chặn `DROP COLUMN`/`RENAME` cùng bản phát hành (expand/contract).
- Image build một lần, các bước sau dùng đúng digest, ký bằng cosign, pin runner theo digest. `verify` trả digest qua output cho `deploy`.
- `deploy` chạy lại `verify` vì `main` có thể đã khác lúc PR được kiểm tra.
- Production: environment có reviewer, concurrency một lần chạy mỗi database và không hủy giữa chừng, `lock_timeout` và `statement_timeout`, snapshot hoặc mốc PITR trước khi chạy, kế hoạch roll-forward (không rollback). Data migration chạy theo từng tenant với `SET LOCAL`, không tắt RLS.
- Con đường A: self-hosted runner. Con đường B: workflow tạo Kubernetes Job. Chọn bằng input `mode`, cùng một image đã ký.
- Gộp thành một workflow là khả thi nếu Vault ràng buộc theo claim, nhưng ranh giới credential khi đó phụ thuộc cấu hình thay vì ranh giới file, nên chọn tách.

## Hệ quả
Phản hồi sớm ở PR, ranh giới credential rõ. Cần runner self-hosted có đường mạng tới mạng quản trị, và org ruleset bắt buộc `verify` là required check.

## Liên quan
ADR-0009, ADR-0010.
