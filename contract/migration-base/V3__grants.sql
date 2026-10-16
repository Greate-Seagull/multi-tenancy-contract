REVOKE EXECUTE ON PROCEDURE apply_tenant_rls(regclass) FROM PUBLIC;

GRANT USAGE ON SCHEMA platform TO app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE app_user
GRANT EXECUTE ON FUNCTION current_tenant_id() TO app_user;