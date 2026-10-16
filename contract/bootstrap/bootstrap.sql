-- Chạy bằng postgres (superuser). Chạy lại nhiều lần vẫn an toàn.
CREATE ROLE app_owner
CREATE ROLE app_migrator
CREATE ROLE app_user

-- Đồng bộ thuộc tính (role đã tồn tại từ trước vẫn bị đưa về đúng chuẩn)
ALTER ROLE app_owner NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION INHERIT
ALTER ROLE app_migrator LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION INHERIT CONNECTION LIMIT 2
ALTER ROLE app_user LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION INHERIT

-- app_migrator là thành viên app_owner (chạy DDL bằng quyền owner)
GRANT app_owner TO app_migrator

-- app_user: không là thành viên role nào, ép RLS luôn bật
ALTER ROLE app_user SET row_security = on
REVOKE app_owner FROM app_user
REVOKE app_owner FROM app_user