# Test cách ly tenant – nhóm TBL (pytest + psycopg)

Tự động hóa 7 test case `TC-TBL-01 … TC-TBL-07` (mục 4.1, "Bảng không có tenant_id") bằng pytest + psycopg 3 trên PostgreSQL.

## Cách hoạt động

1. Bộ test **tự dựng một schema mẫu** (`tbl_fixture`) bằng `ADMIN_DSN`: bảng nghiệp vụ thực tế (orders, order_items, products, tags, product_tags, memberships, tenants...), RLS, FK kép, phân quyền hẹp cho `app_user`, kèm dữ liệu của 2 tenant A và B.
2. Mọi test chạy bằng **`app_user`** (`APP_USER_DSN`), đặt tenant bằng `set_config('app.tenant_id', <uuid>, true)` (tương đương `SET LOCAL`).
3. Mỗi test chạy trong một transaction và **luôn ROLLBACK**: không để lại dữ liệu, không rò trạng thái sang test khác.
4. Xong thì **xóa schema mẫu** (đặt `KEEP_FIXTURE=1` để giữ lại và tự soi bằng psql).

## Chuẩn bị (một lần)

Cần Python 3.10 trở lên.

```bash
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

## Biến môi trường

| Biến | Bắt buộc | Ý nghĩa |
|---|---|---|
| `APP_USER_DSN` | có | Chuỗi kết nối bằng role `app_user` (lấy từ k3s secret). Phải là role thường: không SUPERUSER, không BYPASSRLS, nếu không bộ test dừng ngay. |
| `ADMIN_DSN` | có | Chỉ dùng để dựng/xóa schema mẫu. Phải là superuser (hoặc có BYPASSRLS). **Chỉ trỏ vào DB test/staging.** |
| `FIXTURE_SCHEMA` | không | Tên schema mẫu, mặc định `tbl_fixture`. Bắt buộc bắt đầu bằng `tbl_`. |
| `OWNER_ROLE` | không | Role sở hữu đối tượng, mặc định `app_owner`. |
| `KEEP_FIXTURE` | không | `1` = không xóa schema mẫu sau khi chạy (để debug). |

Mẫu DSN: `postgresql://app_user:MATKHAU@host:5432/appdb?sslmode=require`. Xem `.env.example`.
Trên k3s, đưa vào Job/Pod bằng `secretKeyRef`:

```yaml
env:
  - name: APP_USER_DSN
    valueFrom: { secretKeyRef: { name: pg-app-user, key: dsn } }
  - name: ADMIN_DSN
    valueFrom: { secretKeyRef: { name: pg-admin, key: dsn } }
```

## Chạy

```bash
pytest                      # toàn bộ 7 case TBL
pytest -k tbl_03            # chỉ TC-TBL-03
pytest -m p0                # chỉ test ưu tiên P0 (p0, p1, p2, p3)
pytest -k "tbl_05 and A_"   # lọc theo tên test
```

## Chạy bằng Docker (không cần cài Python, không kèm DB)

Image chỉ chứa code test; DB là tài nguyên có sẵn, truyền vào lúc chạy. Container chạy xong là thoát, **exit code chính là kết quả** (0 = đạt hết, 1 = có test FAIL, 2 = lỗi cấu hình/kết nối DB).

```bash
docker build -t tenant-isolation-tests:latest .

mkdir -p reports && chmod 777 reports        # để user trong container (UID 10001) ghi được log
docker run --rm \
  -e APP_USER_DSN='postgresql://app_user:MATKHAU@db-host:5432/appdb?sslmode=require' \
  -e ADMIN_DSN='postgresql://postgres:MATKHAU@db-host:5432/appdb?sslmode=require' \
  -v "$PWD/reports:/app/reports" \
  tenant-isolation-tests:latest

# Tham số thêm được đưa thẳng cho pytest:
docker run --rm --env-file .env -v "$PWD/reports:/app/reports" tenant-isolation-tests:latest -m p0
docker run --rm --env-file .env -v "$PWD/reports:/app/reports" tenant-isolation-tests:latest -k tbl_03
```

* DB chạy ngay trên máy host: thêm `--network host` (Linux) hoặc dùng `host.docker.internal` làm host trong DSN (Docker Desktop).
* `--env-file .env` dùng file `.env` dạng `TÊN=giá trị` (không có `export`, không có dấu nháy).
* Cần chứng chỉ riêng cho TLS: mount file CA vào container và thêm `sslrootcert=/certs/ca.pem` vào DSN.
* Không mount `reports` thì vẫn chạy bình thường, chỉ là log đầy đủ nằm trong container và mất khi container xóa (log vẫn in ra màn hình).
* Trên k3s: chạy bằng `Job` với `restartPolicy: Never`, `backoffLimit: 0`; DSN lấy từ secret như phần trên; mount một `emptyDir` vào `/app/reports` nếu cần ghi log (xem log bằng `kubectl logs job/<tên>`).

## Đọc kết quả và log

* **Màn hình**: mỗi test có banner `━━ TC-TBL-03 [P0] ...` (mong đợi gì), tiếp theo từng bước dạng `[A] SELECT ... -> 1 dòng [...]` hoặc `[A] INSERT ... -> LỖI InsufficientPrivilege (SQLSTATE 42501)`, rồi `Kết quả: PASS/FAIL`. Cuối cùng là **bảng tổng hợp theo mã TC**.
* `reports/latest.log`: log đầy đủ mức DEBUG (có cả câu SQL và tham số), ghi đè mỗi lần chạy.
* `reports/summary.txt`: bảng tổng hợp theo TC.
* `reports/junit.xml`: dùng cho CI.
* Khi FAIL, thông báo nói rõ *thấy gì* và *đáng lẽ phải thấy gì*, ví dụ: `lọt dòng của tenant khác: [...]`.

Mật khẩu **không bao giờ** được ghi vào log (chỉ ghi host, db, user).

## Cấu trúc

```
conftest.py              dựng/xóa schema mẫu, kết nối app_user, banner, bảng tổng hợp
helpers.py               TenantSession (đặt tenant, log, kỳ vọng lỗi), dữ liệu seed cố định
sql/fixture_schema.sql   schema + RLS + quyền + dữ liệu mẫu
tests/test_tbl.py        TC-TBL-01 … 07  (tên test dạng test_tbl_<số>_...)
```

## Bảo trì

* **Thêm kịch bản cho một TC**: thêm hàm `test_tbl_0X_...` trong `tests/test_tbl.py`, gắn `@tc(*TBL0X)`.
* **Thêm bảng mẫu**: sửa `sql/fixture_schema.sql` (lưu ý: file xử lý bằng `str.format`, không viết dấu ngoặc nhọn ngoài các placeholder).
* **Muốn test trên bảng thật của hệ thống** thay vì bảng mẫu: đổi tên bảng trong `tests/test_tbl.py` và bỏ fixture `schema`.
* TC-TBL-06 hiện kiểm tra theo hướng "app_user bị **từ chối**" (một trong hai kỳ vọng "bị từ chối hoặc đã tách tenant"). Nếu nhóm chọn hướng "tách tenant", cần sửa test này.
* Test an toàn: schema mẫu chỉ bị xóa nếu mang nhãn do bộ test tạo, nên không thể ghi đè schema thật.
