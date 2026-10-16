# ADR-0002: Mỗi service một database, mỗi database một cluster riêng, on-prem trước

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
Dự kiến 13 loại service, có khả năng scale độc lập. Cần quyết định các database nằm chung hay riêng cluster, và chạy ở đâu.

## Quyết định
- Mỗi service có một database riêng, mỗi database nằm trên một cluster riêng.
- Triển khai on-prem trước, cân nhắc cloud sau.
- Tên role vẫn nhận tham số tiền tố (mặc định `app_`) để sau này gom service vào cluster chung hoặc chuyển lên cloud không phải viết lại bootstrap.
- Phải tách "contract" (bootstrap SQL, hàm, audit) khỏi "cách dựng" (CNPG on-prem, module cloud sau này). Service chỉ thấy contract.

## Hệ quả
- Tốt: hết noisy neighbor ở mức cluster, kết nối và `max_connections` riêng, phạm vi lỗi cấu hình (`pg_hba`, log, `wal_level`) và lộ credential `postgres` giới hạn trong một service. Backup/PITR và nâng cấp theo từng service.
- Đánh đổi: chi phí hạ tầng và công vận hành tăng theo số service, bắt buộc tự động hóa (xem ADR-0011).
- Tên role `app_user`, `app_owner` giữ nguyên, không cần tiền tố theo service khi mỗi service một cluster.

## Phương án đã xét
Cluster chung (nhiều database/cluster, rẻ hơn nhưng lỗi cấu hình và lộ `postgres` ảnh hưởng mọi service). Phân tầng (mặc định chung, service nhạy cảm tách riêng): hợp lý nhưng không chọn vì đã có 13 service cần scale độc lập.

## Liên quan
ADR-0001, ADR-0011.
