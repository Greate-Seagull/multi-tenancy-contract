# ADR-0005: Repo chuẩn dùng chung và cách phân bổ nội dung giữa các repo

- Trạng thái: Accepted
- Ngày: 2026-10-12

## Bối cảnh
Bước chuẩn hóa chỉ giảm sai sót khi được cưỡng chế bằng máy. Có 13 service nên chuẩn cần viết một lần và dùng lại.

## Quyết định
Dùng repo riêng cho chuẩn dùng chung, có version (semver, tag bất biến). Phân bổ:

| Nội dung | Repo |
|---|---|
| Template policy, helper SQL, quy tắc lint, truy vấn audit, baseline cấu hình, bộ test cách ly, workflow, runner image, thư viện, scaffold | Repo chuẩn |
| Dựng database, bootstrap tạo role | Repo hạ tầng, quyền hạn chế (chỉ người được phép dùng `postgres`) |
| Migration, manifest phân loại bảng, `service.yaml` | Repo service. Thêm bảng thì sửa migration và manifest trong cùng một PR, CI kiểm tra khớp nhau |

Mọi quy tắc phải có thành phần chạy được (lint, audit, test). Ngoại lệ phải có lý do, người duyệt và ngày hết hạn.

## Hệ quả
- Tốt: chuẩn thống nhất, nâng cấp bằng đổi tag.
- Rủi ro: service dùng bản chuẩn cũ (cần CI cảnh báo), service bỏ qua quy tắc cho tiện (cần cơ chế ngoại lệ), thay đổi chuẩn làm vỡ service (chạy thử trên các service hiện có trước khi phát hành).

## Liên quan
ADR-0007, ADR-0015.
