- Bối cảnh: Đảm bảo bảo mật cho tenant ở database
- Quyết định: Bootstrap database bằng k3s
- Lý do:
  - Tách biệt quyền migration với quyền vận hành app.
  - Không làm ảnh hưởng đến app trong lúc migrate.
- Trade-off:
  - Tăng độ phức tạp và thời gian triển khai và bảo trì.
    