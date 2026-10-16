- các secret manager chỉ được phép sinh credentials ngắn hạn như (username/password), tuyệt đối không được động vào quyền (privilege) ví dụ role ở database.
- ưu tiên hiệu lực theo ttl cho credentials, nếu role càng cao ttl càng ngắn.
- mỗi instance của service dùng chung role nhưng có credentials riêng.
- cần audit instance nào dùng credentials nào.
- tương thích với GitOps.

1. Vault tạo credentials.
2. Người xin cấp credentials giữ.