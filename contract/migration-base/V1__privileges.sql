-- Database: thu quyền mặc định của PUBLIC (gồm CONNECT, TEMP), chỉ cấp CONNECT cho role cần
REVOKE ALL ON DATABASE app FROM PUBLIC
GRANT CONNECT ON DATABASE app TO app_migrator, app_user
-- Ép RLS luôn bật cho mọi phiên của database này
ALTER DATABASE app SET row_security = on