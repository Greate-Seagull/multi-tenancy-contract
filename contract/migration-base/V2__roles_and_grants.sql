GRANT USAGE ON SCHEMA platform TO ${app_user};
GRANT EXECUTE ON FUNCTION current_tenant_id() TO ${app_user};
REVOKE EXECUTE ON PROCEDURE apply_tenant_rls(regclass) FROM PUBLIC;