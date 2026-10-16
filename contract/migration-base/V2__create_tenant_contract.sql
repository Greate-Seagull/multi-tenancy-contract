CREATE OR REPLACE FUNCTION current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;

CREATE OR REPLACE PROCEDURE apply_tenant_rls(p_table regclass)
LANGUAGE plpgsql AS $$
BEGIN
EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', p_table);
EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %s', p_table);
EXECUTE format($p$
    CREATE POLICY tenant_isolation ON %s
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id())
    $p$, p_table);
END $$;