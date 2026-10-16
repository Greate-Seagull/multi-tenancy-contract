DO $$
BEGIN
    -- Database: thu quyền mặc định của PUBLIC (gồm CONNECT, TEMP), chỉ cấp CONNECT cho role cần
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO app_migrator, app_user', current_database());
    -- Ép RLS luôn bật cho mọi phiên của database này
    EXECUTE format('ALTER DATABASE %I SET row_security = on', current_database());
    EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM app_user', current_database());
END $$;

GRANT USAGE ON SCHEMA contract, service TO app_user;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA contract, service
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA contract, service
  GRANT USAGE, SELECT ON SEQUENCES TO app_user;