-- Contract test nhóm D: guard trên catalog của DB thật. Chỉ đọc; gom TẤT CẢ vi phạm rồi fail một lần.
-- Biến psql: :app = tên role app. Cần bảng tạm `allow` từ D_allowlist.sql.
SET client_min_messages = warning;

CREATE TEMP TABLE app_role AS
SELECT oid, rolname, rolsuper, rolbypassrls, rolcreaterole FROM pg_roles WHERE rolname = :'app';
DO $$
BEGIN
  IF (SELECT count(*) FROM app_role) <> 1 THEN
    RAISE EXCEPTION '[D0] không tìm thấy role app';
END IF;
END $$;

-- ---- Phạm vi: mọi schema người dùng (bỏ hệ thống, contract_test*), bỏ đối tượng thuộc extension
CREATE TEMP TABLE scope_ns AS
SELECT n.oid, n.nspname, n.nspowner FROM pg_namespace n
WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' AND n.nspname NOT LIKE 'contract\_test%';

CREATE TEMP TABLE scope_rel AS
SELECT c.oid, n.nspname, c.relname, c.relkind, c.relowner, c.relrowsecurity, c.relforcerowsecurity,
       c.relispartition, c.reloptions, n.nspname || '.' || c.relname AS fqn
FROM pg_class c JOIN scope_ns n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p','v','m','f')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e');

CREATE TEMP TABLE tenant_rel AS
SELECT r.*, a.attnum AS tenant_attnum, a.attnotnull AS tenant_notnull
FROM scope_rel r
         JOIN pg_attribute a ON a.attrelid = r.oid AND a.attname = 'tenant_id' AND a.attnum > 0 AND NOT a.attisdropped
WHERE r.relkind IN ('r','p');

CREATE TEMP TABLE global_rel AS
SELECT r.* FROM scope_rel r
WHERE r.relkind IN ('r','p') AND NOT EXISTS (SELECT 1 FROM tenant_rel t WHERE t.oid = r.oid);

CREATE TEMP TABLE scope_fn AS
SELECT p.oid, p.prosecdef, p.proowner, p.proconfig,
       n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS fqn
FROM pg_proc p JOIN scope_ns n ON n.oid = p.pronamespace
WHERE NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e');

CREATE TEMP TABLE viol (check_id text, object text, detail text);

-- ---- D0: đối tượng của contract tồn tại và app dùng được hàm
INSERT INTO viol
SELECT 'D0', 'current_tenant_id()', 'không resolve được hàm qua search_path'
    WHERE to_regprocedure('current_tenant_id()') IS NULL
UNION ALL
SELECT 'D0', 'apply_tenant_rls(regclass)', 'không resolve được procedure qua search_path'
    WHERE to_regprocedure('apply_tenant_rls(regclass)') IS NULL
UNION ALL
SELECT 'D0-exec', 'current_tenant_id()', 'app thiếu EXECUTE: mọi truy vấn bảng tenant sẽ lỗi'
    WHERE to_regprocedure('current_tenant_id()') IS NOT NULL
    AND NOT has_function_privilege((SELECT oid FROM app_role), to_regprocedure('current_tenant_id()'), 'EXECUTE');

-- ---- D23: cấu trúc RLS của mọi bảng tenant (kể cả partition) và phân loại bảng
INSERT INTO viol
SELECT 'D23', t.fqn, 'chưa bật ROW LEVEL SECURITY' FROM tenant_rel t WHERE NOT t.relrowsecurity
UNION ALL
SELECT 'D23', t.fqn, 'chưa bật FORCE ROW LEVEL SECURITY' FROM tenant_rel t WHERE NOT t.relforcerowsecurity
UNION ALL
SELECT 'D23', t.fqn, 'policy lạ: ' || p.polname
FROM tenant_rel t JOIN pg_policy p ON p.polrelid = t.oid WHERE p.polname <> 'tenant_isolation'
UNION ALL
SELECT 'D23', t.fqn, 'thiếu policy tenant_isolation'
FROM tenant_rel t
WHERE NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = t.oid AND p.polname = 'tenant_isolation')
UNION ALL
SELECT 'D23', t.fqn, 'tenant_isolation sai chuẩn (cmd ALL, PERMISSIVE, mọi role, USING và WITH CHECK dùng current_tenant_id())'
FROM tenant_rel t JOIN pg_policy p ON p.polrelid = t.oid AND p.polname = 'tenant_isolation'
WHERE p.polcmd <> '*' OR NOT p.polpermissive OR p.polroles <> '{0}'::oid[]
     OR p.polqual IS NULL OR p.polwithcheck IS NULL
     OR pg_get_expr(p.polqual, p.polrelid)      NOT LIKE '%tenant_id%current_tenant_id()%'
     OR pg_get_expr(p.polwithcheck, p.polrelid) NOT LIKE '%tenant_id%current_tenant_id()%'
UNION ALL
SELECT 'D23-notnull', t.fqn, 'cột tenant_id cho phép NULL' FROM tenant_rel t WHERE NOT t.tenant_notnull
UNION ALL
SELECT 'D23-global', g.fqn, 'bảng không có cột tenant_id và chưa được khai báo là bảng global' FROM global_rel g
UNION ALL
SELECT 'D23-inherit', ch.fqn, 'kế thừa kiểu cũ (INHERITS) từ ' || pa.fqn
FROM pg_inherits i
         JOIN scope_rel ch ON ch.oid = i.inhrelid
         JOIN scope_rel pa ON pa.oid = i.inhparent
WHERE pa.relkind = 'r';

-- ---- D24: quyền và đặc quyền của role app
INSERT INTO viol
SELECT 'D24-role', a.rolname,
       concat_ws(', ', CASE WHEN a.rolsuper      THEN 'SUPERUSER'  END,
                 CASE WHEN a.rolbypassrls  THEN 'BYPASSRLS'  END,
                 CASE WHEN a.rolcreaterole THEN 'CREATEROLE' END)
FROM app_role a WHERE a.rolsuper OR a.rolbypassrls OR a.rolcreaterole;

INSERT INTO viol   -- quyền ngoài DML trên mọi bảng/view (TRUNCATE phá cách ly vì RLS không áp dụng cho nó)
SELECT 'D24-priv', r.fqn, 'app có quyền ' || string_agg(p, ', ' ORDER BY p)
FROM scope_rel r CROSS JOIN app_role a
                 CROSS JOIN LATERAL unnest(
                                           CASE WHEN current_setting('server_version_num')::int >= 170000
         THEN ARRAY['TRUNCATE','REFERENCES','TRIGGER','MAINTAIN']
         ELSE ARRAY['TRUNCATE','REFERENCES','TRIGGER'] END) AS p
WHERE has_table_privilege(a.oid, r.oid, p)
GROUP BY r.fqn;

INSERT INTO viol
SELECT 'D24-global-write', g.fqn, 'bảng global mà app được INSERT/UPDATE/DELETE'
FROM global_rel g
WHERE g.relname <> 'flyway_schema_history'
  AND has_table_privilege((SELECT oid FROM app_role), g.oid, 'INSERT,UPDATE,DELETE');

INSERT INTO viol
SELECT 'D24-flyway', r.fqn, 'app có quyền trên bảng lịch sử migration'
FROM scope_rel r
WHERE r.relname = 'flyway_schema_history'
  AND has_table_privilege((SELECT oid FROM app_role), r.oid, 'SELECT,INSERT,UPDATE,DELETE');

INSERT INTO viol   -- app không sở hữu gì (owner có thể DISABLE RLS, DROP POLICY, thay hàm)
SELECT 'D24-owner', n.nspname || '.' || c.relname, 'app là owner (relkind ' || c.relkind::text || ')'
FROM pg_class c JOIN scope_ns n ON n.oid = c.relnamespace
WHERE c.relowner = (SELECT oid FROM app_role)
UNION ALL
SELECT 'D24-owner', f.fqn, 'app là owner của hàm'
FROM scope_fn f WHERE f.proowner = (SELECT oid FROM app_role)
UNION ALL
SELECT 'D24-owner', s.nspname, 'app là owner của schema'
FROM scope_ns s WHERE s.nspowner = (SELECT oid FROM app_role)
UNION ALL
SELECT 'D24-owner', current_database(), 'app là owner của database'
FROM pg_database WHERE datname = current_database() AND datdba = (SELECT oid FROM app_role);

INSERT INTO viol   -- app không là thành viên role nào (chặn SET ROLE và quyền thừa hưởng)
SELECT 'D24-member', r.rolname, 'app là thành viên (trực tiếp hoặc gián tiếp)'
FROM pg_roles r, app_role a
WHERE r.oid <> a.oid AND pg_has_role(a.oid, r.oid, 'MEMBER');

-- ---- D25, D26
INSERT INTO viol
SELECT 'D25', 'apply_tenant_rls(regclass)',
       'app có quyền EXECUTE (thường do PUBLIC mặc định; REVOKE EXECUTE ... FROM PUBLIC)'
    WHERE to_regprocedure('apply_tenant_rls(regclass)') IS NOT NULL
    AND has_function_privilege((SELECT oid FROM app_role), to_regprocedure('apply_tenant_rls(regclass)'), 'EXECUTE');

INSERT INTO viol   -- hygiene: bảng app tự tạo trong schema nghiệp vụ sẽ không có RLS
SELECT 'D26', s.nspname, 'app có quyền CREATE trên schema'
FROM scope_ns s WHERE has_schema_privilege((SELECT oid FROM app_role), s.oid, 'CREATE');

-- ---- FK: giữa hai bảng tenant phải composite (có tenant_id hai phía); FK RI bỏ qua RLS
INSERT INTO viol
SELECT 'D-FK', ch.fqn || '.' || c.conname,
       CASE WHEN ct.oid IS NULL
                THEN 'bảng global trỏ tới bảng tenant ' || pa.fqn
            ELSE 'FK tenant→tenant không gồm tenant_id ở cả hai phía (dùng FK composite) → ' || pa.fqn END
FROM pg_constraint c
         JOIN scope_rel ch ON ch.oid = c.conrelid
         JOIN scope_rel pa ON pa.oid = c.confrelid
         LEFT JOIN tenant_rel ct ON ct.oid = ch.oid
         LEFT JOIN tenant_rel pt ON pt.oid = pa.oid
WHERE c.contype = 'f' AND c.conparentid = 0
  AND ( (ct.oid IS NULL AND pt.oid IS NOT NULL)
    OR (ct.oid IS NOT NULL AND pt.oid IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM generate_subscripts(c.conkey, 1) i
        WHERE c.conkey[i] = ct.tenant_attnum AND c.confkey[i] = pt.tenant_attnum)) );

-- ---- UNIQUE/PK của bảng tenant phải gồm tenant_id (ngoại lệ: PK một cột kiểu uuid)
INSERT INTO viol
SELECT 'D-UNIQUE', t.fqn || '.' || ic.relname, 'unique/PK không gồm tenant_id trong các cột khóa'
FROM pg_index i
         JOIN tenant_rel t ON t.oid = i.indrelid
         JOIN pg_class ic ON ic.oid = i.indexrelid
WHERE i.indisunique AND NOT ic.relispartition
  AND NOT (t.tenant_attnum = ANY ((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts]))
    AND NOT (i.indisprimary AND i.indnkeyatts = 1 AND
             (SELECT a.atttypid FROM pg_attribute a
               WHERE a.attrelid = t.oid
                 AND a.attnum = (string_to_array(i.indkey::text, ' ')::int2[])[1]) = 'uuid'::regtype);

-- ---- View và materialized view
INSERT INTO viol
SELECT 'D-VIEW', v.fqn, 'view không security_invoker, owner ' || o.rolname || ' là superuser/BYPASSRLS'
FROM scope_rel v JOIN pg_roles o ON o.oid = v.relowner
WHERE v.relkind = 'v' AND (o.rolsuper OR o.rolbypassrls)
  AND coalesce(array_to_string(v.reloptions, ','), '') !~ 'security_invoker=(true|on|1|yes|t)'
UNION ALL
SELECT 'D-MATVIEW', v.fqn, 'materialized view không áp được RLS'
FROM scope_rel v WHERE v.relkind = 'm';

-- ---- SECURITY DEFINER
INSERT INTO viol
SELECT 'D-SECDEF', f.fqn, 'SECURITY DEFINER chưa nằm trong allowlist' FROM scope_fn f WHERE f.prosecdef
UNION ALL
SELECT 'D-SECDEF-OWNER', f.fqn, 'SECURITY DEFINER có owner ' || o.rolname || ' là superuser/BYPASSRLS'
FROM scope_fn f JOIN pg_roles o ON o.oid = f.proowner
WHERE f.prosecdef AND (o.rolsuper OR o.rolbypassrls)
UNION ALL
SELECT 'D-SECDEF-PATH', f.fqn, 'SECURITY DEFINER chưa cố định search_path (SET search_path = ...)'
FROM scope_fn f
WHERE f.prosecdef
  AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(f.proconfig, '{}'::text[])) s WHERE s LIKE 'search_path=%');

-- ---- Kết quả: bỏ vi phạm đã allowlist; allowlist không còn khớp thì báo lỗi thời
CREATE TEMP TABLE final AS
SELECT v.check_id, v.object, v.detail FROM viol v
WHERE NOT EXISTS (SELECT 1 FROM allow a WHERE a.check_id = v.check_id AND a.object = v.object)
UNION ALL
SELECT 'D0-stale', a.check_id || ' ' || a.object, 'allowlist lỗi thời (không còn vi phạm nào khớp): ' || a.reason
FROM allow a
WHERE NOT EXISTS (SELECT 1 FROM viol v WHERE v.check_id = a.check_id AND v.object = a.object);

SELECT count(*) > 0 AS has_viol FROM final \gset
                                         \if :has_viol
SELECT check_id, object, detail FROM final ORDER BY check_id, object, detail;
DO $$ BEGIN RAISE EXCEPTION 'Contract D: có vi phạm, xem danh sách ở trên'; END $$;
\endif

SELECT (SELECT count(*) FROM tenant_rel) AS tn, (SELECT count(*) FROM global_rel) AS gn,
       (SELECT count(*) FROM allow) AS an \gset
\echo 'Contract D (catalog guard): PASS —' :tn 'bảng tenant,' :gn 'bảng global,' :an 'mục allowlist'