DO $$
BEGIN
    -- Database: thu quyền mặc định của PUBLIC (gồm CONNECT, TEMP), chỉ cấp CONNECT cho role cần
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO app_migrator, app_user', current_database());
    -- Ép RLS luôn bật cho mọi phiên của database này
    EXECUTE format('ALTER DATABASE %I SET row_security = on', current_database());
END $$;