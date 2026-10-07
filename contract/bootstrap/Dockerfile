# Image bootstrap: tạo role + database.
# Client gợi database đã có trong file bootstrap.sh
# Đổi major Postgres: docker build --build-arg PG_IMAGE=postgres:18-bookworm .
ARG PG_IMAGE=postgres:18-bookworm
FROM ${PG_IMAGE}
COPY --chmod=755 bootstrap.sh /opt/bootstrap/bootstrap.sh
COPY bootstrap.sql /opt/bootstrap/bootstrap.sql
USER postgres
# Ghi đè ENTRYPOINT của image postgres (nếu không nó sẽ khởi động server)
ENTRYPOINT ["/opt/bootstrap/bootstrap.sh"]