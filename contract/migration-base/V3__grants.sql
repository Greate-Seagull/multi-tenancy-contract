REVOKE EXECUTE ON PROCEDURE apply_tenant_rls(regclass) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION current_tenant_id() TO app_user;