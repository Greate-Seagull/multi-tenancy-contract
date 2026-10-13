# syntax=docker/dockerfile:1
#
# Image chạy bộ test cách ly tenant (nhóm TBL) như MỘT LỆNH CHẠY-RỒI-THOÁT:
#   - KHÔNG chứa database; mọi kết nối đi tới DB có sẵn qua APP_USER_DSN / ADMIN_DSN lúc chạy.
#   - Exit code = kết quả pytest (0 = đạt hết, 1 = có test FAIL, 2 = lỗi cấu hình/kết nối) -> dùng được cho CI, k3s Job.
#   - Không có secret nào được "nướng" vào image.
#
# Build:  docker build -t tenant-isolation-tests:latest .
# Run:    xem phần "Chạy bằng Docker" trong README.md

FROM python:3.12-slim

LABEL org.opencontainers.image.title="tenant-isolation-tests" \
      org.opencontainers.image.description="Test cách ly tenant (pytest + psycopg) chạy trên PostgreSQL có sẵn; không kèm DB"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTEST_ADDOPTS="-p no:cacheprovider"

# Chạy bằng user thường (không root); UID cố định để dễ cấp quyền cho volume reports
RUN groupadd --system --gid 10001 tester \
 && useradd --system --uid 10001 --gid tester --no-create-home --shell /usr/sbin/nologin tester

WORKDIR /app

# Cài thư viện trước để tận dụng cache layer khi chỉ sửa code test
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY pytest.ini conftest.py helpers.py ./
COPY sql/ sql/
COPY tests/ tests/

# Nơi ghi log/kết quả (mount volume vào đây để lấy ra ngoài)
RUN mkdir -p /app/reports && chown tester:tester /app/reports

USER 10001:10001

# Tham số truyền thêm khi chạy sẽ được đưa thẳng cho pytest, ví dụ: -m p0   hoặc   -k tbl_03
ENTRYPOINT ["python", "-m", "pytest"]
