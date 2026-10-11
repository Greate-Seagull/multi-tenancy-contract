# Sử dụng một image Alpine siêu nhỏ chỉ chứa psql client
# Bạn có thể chọn image từ Docker Hub như `alpine/psql` hoặc tự build.
# Ví dụ với `alpine/psql`:
FROM alpine/psql:18.6

USER root
RUN adduser -D -u 10001 psql

COPY --chmod=755 bootstrap.sh /opt/bootstrap/bootstrap.sh
COPY bootstrap.sql /opt/bootstrap/bootstrap.sql

USER 10001

ENTRYPOINT ["/opt/bootstrap/bootstrap.sh"]