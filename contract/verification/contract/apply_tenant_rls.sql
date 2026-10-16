-- Contract test nhóm B: platform.apply_tenant_rls(regclass)
--
-- Chạy bằng ROLE MIGRATOR, trên môi trường test, KHÔNG dùng --single-transaction:
--   psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f apply_tenant_rls.sql
-- Không cần biến -v hay env nào khác. Toàn bộ test nằm trong BEGIN ... ROLLBACK.
--
-- TIỀN ĐỀ NGOÀI FILE (bước dựng môi trường test, chạy bằng admin, một lần):
--   * Bảng contract_fixture.foreign_owned thuộc một role KHÁC migrator; migrator có USAGE trên schema
--     contract_fixture và không là thành viên role sở hữu bảng. Để B14 bắt được cả SECURITY DEFINER,
--     bảng nên thuộc owner của procedure (platform_owner) nếu role này khác migrator.
--
-- QUYẾT ĐỊNH CONTRACT: gom hết ở bảng contract_test.decisions bên dưới. Muốn đổi contract thì sửa đúng một chỗ.
--
-- Mục lục: B0 tiền đề | B16 metadata | B14 quyền | B7-B9 cơ bản | B10 drift | B11 đầu vào thiếu cột/sai kiểu
--          B12 tên đặc biệt | B13 partition | B17-B18 sai loại đối tượng/NULL | B19-B20 search_path
--          B21 tenant_id nullable | B22 policy khác tên | B23-B24 bảo toàn ACL/index/dữ liệu

SET client_min_messages = warning;
SET search_path = pg_catalog, pg_temp;

-- B0. Tiền đề: migrator không có quyền thừa (nếu có thì FORCE và các test quyền vô nghĩa) và fixture đã dựng
DO $$
DECLARE r pg_roles%ROWTYPE; n int; fx pg_class%ROWTYPE;
BEGIN
SELECT * INTO STRICT r FROM pg_roles WHERE rolname = current_user;
IF r.rolsuper OR r.rolbypassrls THEN
    RAISE EXCEPTION '[B0] role % là superuser/BYPASSRLS', current_user;
END IF;
  IF r.rolcreaterole OR r.rolcreatedb OR r.rolreplication THEN
    RAISE EXCEPTION '[B0] role % có CREATEROLE/CREATEDB/REPLICATION', current_user;
END IF;
SELECT count(*) INTO n FROM pg_auth_members WHERE member = r.oid;
IF n <> 0 THEN
    RAISE EXCEPTION '[B0] role % là thành viên của % role khác', current_user, n;
END IF;

  IF to_regnamespace('contract_fixture') IS NULL THEN
    RAISE EXCEPTION '[B0] thiếu schema contract_fixture: chạy bước dựng môi trường test bằng admin trước';
END IF;
  IF NOT has_schema_privilege('contract_fixture', 'USAGE') THEN
    RAISE EXCEPTION '[B0] migrator thiếu USAGE trên contract_fixture (B14 sẽ pass giả vì lỗi quyền schema)';
END IF;
  IF to_regclass('contract_fixture.foreign_owned') IS NULL THEN
    RAISE EXCEPTION '[B0] thiếu bảng contract_fixture.foreign_owned';
END IF;
SELECT * INTO STRICT fx FROM pg_class WHERE oid = 'contract_fixture.foreign_owned'::regclass;
IF fx.relkind <> 'r' THEN
    RAISE EXCEPTION '[B0] contract_fixture.foreign_owned phải là bảng thường';
END IF;
  IF fx.relowner = r.oid OR pg_has_role(current_user, fx.relowner, 'MEMBER') THEN
    RAISE EXCEPTION '[B0] contract_fixture.foreign_owned phải thuộc role khác migrator và migrator không là thành viên';
END IF;
END $$;

BEGIN;

CREATE SCHEMA contract_test;

-- ---------------------------------------------------------------------------------------------
-- Quyết định contract (sửa ở đây nếu contract khác)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE contract_test.decisions (k text PRIMARY KEY, v text NOT NULL);
INSERT INTO contract_test.decisions (k, v) VALUES
                                               ('other_policies',          'drop'),          -- B22: policy khác tên đã có sẵn: 'drop' (xóa) | 'keep' (giữ)
                                               ('nullable_tenant_id',      'accept'),        -- B21/B24: cột tenant_id cho phép NULL: 'accept' | 'reject'
                                               ('partition_cascade',       'no'),            -- B13: áp lên parent có lan xuống partition: 'no' | 'yes'
                                               ('tenant_guc',              'app.tenant_id'), -- B10/B22/B23: GUC mà platform.current_tenant_id() đọc (CẦN XÁC NHẬN)
                                               ('sqlstate_missing_column', '42703'),         -- B11: bảng thiếu cột tenant_id
                                               ('sqlstate_wrong_type',     '42883'),         -- B11: tenant_id sai kiểu (text = uuid)
                                               ('sqlstate_invalid_kind',   '42809'),         -- B17: đối số không phải bảng
                                               ('sqlstate_null_arg',       '22004'),         -- B18: đối số NULL
                                               ('sqlstate_nullable_reject','P0001');         -- B21: chỉ dùng khi nullable_tenant_id = 'reject'

CREATE FUNCTION contract_test.decision(p_key text) RETURNS text
    LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $f$
DECLARE r text;
BEGIN
SELECT d.v INTO STRICT r FROM contract_test.decisions d WHERE d.k = p_key;
RETURN r;
END $f$;

-- ---------------------------------------------------------------------------------------------
-- Hàm dùng chung
-- ---------------------------------------------------------------------------------------------

-- Policy chuẩn: RLS ENABLE+FORCE; đúng 1 policy tenant_isolation (trừ khi allow_others);
-- ALL, PERMISSIVE, mọi role; USING = WITH CHECK, khớp chính xác `tenant_id = platform.current_tenant_id()`
-- (cho phép dạng bọc (SELECT ...) và đảo vế), và phụ thuộc đúng hàm platform.current_tenant_id() qua pg_depend.
-- Nếu deparse của phiên bản Postgres khác dạng dưới đây thì chỉ cần chỉnh regex ở đây.
CREATE FUNCTION contract_test.assert_std_policy(rel regclass, label text, allow_others boolean DEFAULT false)
    RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $f$
DECLARE
c pg_class%ROWTYPE;
  p pg_policy%ROWTYPE;
  n_all int;
  n_std int;
  q text;
  w text;
  fn oid;
  fn_re text := '(platform\.current_tenant_id\(\)|\( SELECT platform\.current_tenant_id\(\) AS current_tenant_id\))';
  expr_re text;
BEGIN
  expr_re := '^\((tenant_id = ' || fn_re || '|' || fn_re || ' = tenant_id)\)$';

SELECT * INTO STRICT c FROM pg_class WHERE oid = rel;
IF NOT c.relrowsecurity      THEN RAISE EXCEPTION '[%] %: thiếu ENABLE ROW LEVEL SECURITY', label, rel; END IF;
  IF NOT c.relforcerowsecurity THEN RAISE EXCEPTION '[%] %: thiếu FORCE ROW LEVEL SECURITY', label, rel; END IF;

SELECT count(*) INTO n_all FROM pg_policy WHERE polrelid = rel;
SELECT count(*) INTO n_std FROM pg_policy WHERE polrelid = rel AND polname = 'tenant_isolation';
IF n_std <> 1 THEN RAISE EXCEPTION '[%] %: phải có đúng 1 policy tenant_isolation, hiện có %', label, rel, n_std; END IF;
  IF NOT allow_others AND n_all <> 1 THEN
    RAISE EXCEPTION '[%] %: phải có đúng 1 policy, hiện có %', label, rel, n_all;
END IF;

SELECT * INTO STRICT p FROM pg_policy WHERE polrelid = rel AND polname = 'tenant_isolation';
IF p.polcmd <> '*'             THEN RAISE EXCEPTION '[%] %: cmd phải là ALL, hiện là %', label, rel, p.polcmd; END IF;
  IF NOT p.polpermissive         THEN RAISE EXCEPTION '[%] %: phải PERMISSIVE', label, rel; END IF;
  IF p.polroles <> '{0}'::oid[]  THEN RAISE EXCEPTION '[%] %: policy phải áp cho mọi role (PUBLIC), hiện là %', label, rel, p.polroles; END IF;

  q := pg_get_expr(p.polqual, p.polrelid);
  w := pg_get_expr(p.polwithcheck, p.polrelid);
  IF q IS NULL THEN RAISE EXCEPTION '[%] %: thiếu USING', label, rel; END IF;
  IF w IS NULL THEN RAISE EXCEPTION '[%] %: thiếu WITH CHECK', label, rel; END IF;
  IF q <> w    THEN RAISE EXCEPTION '[%] %: USING và WITH CHECK khác nhau: % <> %', label, rel, q, w; END IF;
  IF q !~ expr_re THEN RAISE EXCEPTION '[%] %: biểu thức policy không khớp chính xác: %', label, rel, q; END IF;

  fn := 'platform.current_tenant_id()'::regprocedure;
  IF NOT EXISTS (SELECT 1 FROM pg_depend d
                 WHERE d.classid = 'pg_policy'::regclass AND d.objid = p.oid
                   AND d.refclassid = 'pg_proc'::regclass AND d.refobjid = fn) THEN
    RAISE EXCEPTION '[%] %: policy không phụ thuộc platform.current_tenant_id()', label, rel;
END IF;
  IF EXISTS (SELECT 1 FROM pg_depend d JOIN pg_proc pr ON pr.oid = d.refobjid
             WHERE d.classid = 'pg_policy'::regclass AND d.objid = p.oid
               AND d.refclassid = 'pg_proc'::regclass
               AND pr.proname = 'current_tenant_id' AND pr.oid <> fn) THEN
    RAISE EXCEPTION '[%] %: policy trỏ tới hàm current_tenant_id() khác platform.current_tenant_id()', label, rel;
END IF;
END $f$;

-- Kiểm chức năng trên bảng có cột (id int, tenant_id uuid): tenant B không thấy dòng của A,
-- không ghi được dòng mang tenant_id của A, tenant A thấy lại dòng của mình.
CREATE FUNCTION contract_test.assert_isolation(rel regclass, label text)
    RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $f$
DECLARE
guc text := contract_test.decision('tenant_guc');
  ta uuid := '00000000-0000-0000-0000-00000000000a';
  tb uuid := '00000000-0000-0000-0000-00000000000b';
  rid int := 2147000001;
  n int;
  blocked boolean := false;
BEGIN
  PERFORM set_config(guc, ta::text, true);
EXECUTE format('INSERT INTO %s (id, tenant_id) VALUES (%s, %L)', rel, rid, ta);

PERFORM set_config(guc, tb::text, true);
EXECUTE format('SELECT count(*) FROM %s WHERE id = %s', rel, rid) INTO n;
IF n <> 0 THEN RAISE EXCEPTION '[%] %: tenant B thấy dòng của tenant A', label, rel; END IF;

BEGIN
EXECUTE format('INSERT INTO %s (id, tenant_id) VALUES (%s, %L)', rel, rid + 1, ta);
EXCEPTION WHEN insufficient_privilege THEN
    blocked := true;
END;
  IF NOT blocked THEN RAISE EXCEPTION '[%] %: tenant B ghi được dòng mang tenant_id của A (thiếu WITH CHECK?)', label, rel; END IF;

  PERFORM set_config(guc, ta::text, true);
EXECUTE format('SELECT count(*) FROM %s WHERE id = %s', rel, rid) INTO n;
IF n <> 1 THEN RAISE EXCEPTION '[%] %: tenant A không thấy dòng của chính mình (có %)', label, rel, n; END IF;
EXECUTE format('DELETE FROM %s WHERE id = %s', rel, rid);
END $f$;

-- Gọi apply rồi kiểm chuẩn + chức năng (dùng cho các ca drift)
CREATE PROCEDURE contract_test.check_restore(rel regclass, label text)
    LANGUAGE plpgsql AS $f$
BEGIN
CALL platform.apply_tenant_rls(rel);
PERFORM contract_test.assert_std_policy(rel, label);
  PERFORM contract_test.assert_isolation(rel, label);
END $f$;

-- Gọi apply, mong lỗi với SQLSTATE nằm trong danh sách (phân tách bằng dấu phẩy); không lỗi hoặc sai mã thì fail.
-- Lưu ý: lỗi đã rollback subtransaction nên không dùng để kiểm "không để lại gì".
CREATE FUNCTION contract_test.expect_apply_error(rel regclass, expected text, label text)
    RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
BEGIN
EXECUTE format('CALL platform.apply_tenant_rls(%L::regclass)', rel::text);
EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = ANY (string_to_array(expected, ',')) THEN
      RETURN;
END IF;
    RAISE EXCEPTION '[%] SQLSTATE sai: mong đợi %, nhận % (%)', label, expected, SQLSTATE, SQLERRM;
END;
  RAISE EXCEPTION '[%] phải báo lỗi (SQLSTATE %) nhưng gọi thành công', label, expected;
END $f$;

-- B16. Metadata procedure: đúng 1 overload (regclass), prokind=p, SECURITY INVOKER, owner platform_owner,
--      không đặt row_security. Đây là test bắt SECURITY DEFINER bằng metadata; bỏ nếu A6 đã có apply_tenant_rls.
DO $$
DECLARE n int; p pg_proc%ROWTYPE;
BEGIN
SELECT count(*) INTO n FROM pg_proc
WHERE pronamespace = 'platform'::regnamespace AND proname = 'apply_tenant_rls';
IF n <> 1 THEN RAISE EXCEPTION '[B16] phải có đúng 1 overload apply_tenant_rls, hiện có %', n; END IF;

SELECT * INTO STRICT p FROM pg_proc
WHERE pronamespace = 'platform'::regnamespace AND proname = 'apply_tenant_rls';
IF p.prokind <> 'p' THEN RAISE EXCEPTION '[B16] phải là procedure (prokind=p), hiện là %', p.prokind; END IF;
  IF p.prosecdef THEN RAISE EXCEPTION '[B16] phải là SECURITY INVOKER'; END IF;
  IF p.proargtypes::text <> 'regclass'::regtype::oid::text THEN
    RAISE EXCEPTION '[B16] chữ ký phải là (regclass), hiện là (%)', pg_get_function_identity_arguments(p.oid);
END IF;
  IF pg_get_userbyid(p.proowner) <> 'platform_owner' THEN
    RAISE EXCEPTION '[B16] owner phải là platform_owner, hiện là %', pg_get_userbyid(p.proowner);
END IF;
  IF EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}'::text[])) c WHERE c LIKE 'row_security=%') THEN
    RAISE EXCEPTION '[B16] proconfig không được đặt row_security';
END IF;
END $$;

-- B14. Migrator gọi trên bảng của role khác: phải lỗi 42501 (invoker không có quyền sở hữu).
--      Nếu fixture thuộc owner procedure (platform_owner khác migrator) thì test này còn bắt được SECURITY DEFINER.
DO $$
BEGIN
  PERFORM contract_test.expect_apply_error('contract_fixture.foreign_owned'::regclass, '42501', 'B14');
END $$;

CREATE TABLE contract_test.t_basic (id int PRIMARY KEY, tenant_id uuid NOT NULL);

-- B7. Sau khi gọi: ENABLE và FORCE đều bật (thiếu FORCE thì owner bypass RLS)
DO $$
DECLARE r pg_class%ROWTYPE;
BEGIN
SELECT * INTO STRICT r FROM pg_class WHERE oid = 'contract_test.t_basic'::regclass;
IF r.relrowsecurity OR r.relforcerowsecurity THEN
    RAISE EXCEPTION '[B7] tiền đề sai: bảng mới đã có RLS';
END IF;

CALL platform.apply_tenant_rls('contract_test.t_basic');

SELECT * INTO STRICT r FROM pg_class WHERE oid = 'contract_test.t_basic'::regclass;
IF NOT r.relrowsecurity      THEN RAISE EXCEPTION '[B7] thiếu ENABLE ROW LEVEL SECURITY'; END IF;
  IF NOT r.relforcerowsecurity THEN RAISE EXCEPTION '[B7] thiếu FORCE ROW LEVEL SECURITY'; END IF;
END $$;

-- B8. Policy chuẩn (khớp chính xác, USING = WITH CHECK, phụ thuộc đúng hàm) và cách ly thật sự
DO $$
BEGIN
  PERFORM contract_test.assert_std_policy('contract_test.t_basic', 'B8');
  PERFORM contract_test.assert_isolation('contract_test.t_basic', 'B8');
END $$;

-- B9. Gọi lại nhiều lần: không lỗi, vẫn đúng 1 policy chuẩn, cờ RLS vẫn bật
DO $$
BEGIN
CALL platform.apply_tenant_rls('contract_test.t_basic');
CALL platform.apply_tenant_rls('contract_test.t_basic');
PERFORM contract_test.assert_std_policy('contract_test.t_basic', 'B9');
END $$;

-- B10. Drift: mỗi biến thể sửa tay một kiểu, gọi lại phải khôi phục đủ chuẩn và chạy đúng chức năng
-- B10a. USING (true), mất WITH CHECK, NO FORCE
CREATE TABLE contract_test.t_drift_a (id int PRIMARY KEY, tenant_id uuid NOT NULL);
CALL platform.apply_tenant_rls('contract_test.t_drift_a');
DROP POLICY tenant_isolation ON contract_test.t_drift_a;
CREATE POLICY tenant_isolation ON contract_test.t_drift_a USING (true);
ALTER TABLE contract_test.t_drift_a NO FORCE ROW LEVEL SECURITY;
CALL contract_test.check_restore('contract_test.t_drift_a', 'B10a-using-true');

-- B10b. RESTRICTIVE
CREATE TABLE contract_test.t_drift_b (id int PRIMARY KEY, tenant_id uuid NOT NULL);
CALL platform.apply_tenant_rls('contract_test.t_drift_b');
DROP POLICY tenant_isolation ON contract_test.t_drift_b;
CREATE POLICY tenant_isolation ON contract_test.t_drift_b AS RESTRICTIVE USING (true) WITH CHECK (true);
CALL contract_test.check_restore('contract_test.t_drift_b', 'B10b-restrictive');

-- B10c. Chỉ áp cho một role cụ thể (không phải PUBLIC)
CREATE TABLE contract_test.t_drift_c (id int PRIMARY KEY, tenant_id uuid NOT NULL);
CALL platform.apply_tenant_rls('contract_test.t_drift_c');
DROP POLICY tenant_isolation ON contract_test.t_drift_c;
CREATE POLICY tenant_isolation ON contract_test.t_drift_c TO CURRENT_USER USING (true) WITH CHECK (true);
CALL contract_test.check_restore('contract_test.t_drift_c', 'B10c-to-role');

-- B10d. DISABLE ROW LEVEL SECURITY (policy còn nguyên)
CREATE TABLE contract_test.t_drift_d (id int PRIMARY KEY, tenant_id uuid NOT NULL);
CALL platform.apply_tenant_rls('contract_test.t_drift_d');
ALTER TABLE contract_test.t_drift_d DISABLE ROW LEVEL SECURITY;
CALL contract_test.check_restore('contract_test.t_drift_d', 'B10d-disable-rls');

-- B11. Bảng thiếu cột tenant_id / sai kiểu: phải lỗi đúng SQLSTATE đã chốt trong contract
CREATE TABLE contract_test.t_no_tenant  (id int);
CREATE TABLE contract_test.t_wrong_type (id int, tenant_id text);
DO $$
BEGIN
  PERFORM contract_test.expect_apply_error('contract_test.t_no_tenant'::regclass,
            contract_test.decision('sqlstate_missing_column'), 'B11-missing-column');
  PERFORM contract_test.expect_apply_error('contract_test.t_wrong_type'::regclass,
            contract_test.decision('sqlstate_wrong_type'), 'B11-wrong-type');
END $$;

-- B12. Tên đặc biệt: chữ hoa, khoảng trắng, từ khóa, dấu ", ký tự %, schema khác
CREATE SCHEMA "Weird Schema";
DO $$
DECLARE c record; rel regclass;
BEGIN
FOR c IN SELECT * FROM (VALUES
                            ('contract_test', 'Mixed Case'),
                            ('contract_test', 'order'),
                            ('contract_test', 'a"b'),
                            ('contract_test', '100%s'),
                            ('Weird Schema',  'plain'),
                            ('Weird Schema',  'Mixed Case')
                       ) AS v(s, t)
    LOOP
    EXECUTE format('CREATE TABLE %I.%I (id int, tenant_id uuid NOT NULL)', c.s, c.t);
rel := format('%I.%I', c.s, c.t)::regclass;
CALL platform.apply_tenant_rls(rel);
PERFORM contract_test.assert_std_policy(rel, 'B12');
END LOOP;
END $$;

-- B13. Bảng partitioned: hành vi lan xuống partition theo contract (decisions.partition_cascade)
CREATE TABLE contract_test.p (id int, tenant_id uuid NOT NULL) PARTITION BY HASH (tenant_id);
CREATE TABLE contract_test.p_0 PARTITION OF contract_test.p FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE contract_test.p_1 PARTITION OF contract_test.p FOR VALUES WITH (MODULUS 2, REMAINDER 1);
DO $$
DECLARE v_cascade text := contract_test.decision('partition_cascade'); part text; prel regclass;
BEGIN
  IF v_cascade NOT IN ('yes', 'no') THEN RAISE EXCEPTION '[B13] decisions.partition_cascade không hợp lệ: %', v_cascade; END IF;

CALL platform.apply_tenant_rls('contract_test.p');
PERFORM contract_test.assert_std_policy('contract_test.p', 'B13-parent');

  FOREACH part IN ARRAY ARRAY['p_0', 'p_1'] LOOP
    prel := format('contract_test.%I', part)::regclass;
    IF v_cascade = 'no' THEN
      IF EXISTS (SELECT 1 FROM pg_class WHERE oid = prel AND relrowsecurity)
         OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = prel) THEN
        RAISE EXCEPTION '[B13] % đã có RLS/policy dù contract chốt không cascade (procedure cascade, hoặc Postgres đổi hành vi)', part;
END IF;
CALL platform.apply_tenant_rls(prel);
END IF;
    PERFORM contract_test.assert_std_policy(prel, 'B13-' || part);
END LOOP;
END $$;

-- B17-B18. Đối số không phải bảng (view, sequence) hoặc NULL: phải lỗi tường minh, không im lặng no-op
CREATE TABLE contract_test.t_kind_base (id int, tenant_id uuid NOT NULL);
CREATE VIEW contract_test.v_kind AS SELECT id, tenant_id FROM contract_test.t_kind_base;
CREATE SEQUENCE contract_test.s_kind;
DO $$
BEGIN
  PERFORM contract_test.expect_apply_error('contract_test.v_kind'::regclass,
            contract_test.decision('sqlstate_invalid_kind'), 'B17-view');
  -- sequence không có cột tenant_id nên chấp nhận thêm lỗi thiếu cột tùy thứ tự kiểm tra của procedure
  PERFORM contract_test.expect_apply_error('contract_test.s_kind'::regclass,
            contract_test.decision('sqlstate_invalid_kind') || ',' || contract_test.decision('sqlstate_missing_column'),
            'B17-sequence');
  PERFORM contract_test.expect_apply_error(NULL::regclass, contract_test.decision('sqlstate_null_arg'), 'B18-null');
END $$;

-- B19-B20. search_path: hàm current_tenant_id() giả nằm sẵn ở contract_test; policy vẫn phải trỏ platform.current_tenant_id().
--   #1 contract_test đứng đầu path, gọi bằng tên có schema
--   #2 bảng nằm trong path, gọi bằng tên không schema
--   #3 search_path rỗng, gọi bằng tên có schema
CREATE FUNCTION contract_test.current_tenant_id() RETURNS uuid LANGUAGE sql AS $f$ SELECT NULL::uuid $f$;
DO $$
DECLARE s record; base text := 'pg_catalog, pg_temp'; tname text;
BEGIN
FOR s IN SELECT * FROM (VALUES
                            (1, 'contract_test, pg_catalog', true),
                            (2, 'contract_test, pg_catalog', false),
                            (3, '',                          true)
                       ) AS v(n, sp, qualified) ORDER BY n
             LOOP
    tname := format('t_sp_%s', s.n);
EXECUTE format('CREATE TABLE contract_test.%I (id int, tenant_id uuid NOT NULL)', tname);

PERFORM set_config('search_path', s.sp, true);
    IF s.qualified THEN
      EXECUTE format('CALL platform.apply_tenant_rls(%L::regclass)', 'contract_test.' || tname);
ELSE
      EXECUTE format('CALL platform.apply_tenant_rls(%L::regclass)', tname);
END IF;
    PERFORM set_config('search_path', base, true);

    PERFORM contract_test.assert_std_policy(format('contract_test.%I', tname)::regclass, 'B19-B20 #' || s.n);
END LOOP;
END $$;

-- B21. Cột tenant_id cho phép NULL: theo contract (decisions.nullable_tenant_id)
CREATE TABLE contract_test.t_nullable (id int PRIMARY KEY, tenant_id uuid);
DO $$
DECLARE v_mode text := contract_test.decision('nullable_tenant_id');
BEGIN
  IF v_mode = 'reject' THEN
    PERFORM contract_test.expect_apply_error('contract_test.t_nullable'::regclass,
              contract_test.decision('sqlstate_nullable_reject'), 'B21-nullable-reject');
  ELSIF v_mode = 'accept' THEN
    CALL platform.apply_tenant_rls('contract_test.t_nullable');
    PERFORM contract_test.assert_std_policy('contract_test.t_nullable', 'B21-nullable-accept');
    PERFORM contract_test.assert_isolation('contract_test.t_nullable', 'B21-nullable-accept');
ELSE
    RAISE EXCEPTION '[B21] decisions.nullable_tenant_id không hợp lệ: %', v_mode;
END IF;
END $$;

-- B22. Bảng đã có policy khác tên (allow_all PERMISSIVE): theo contract (decisions.other_policies)
CREATE TABLE contract_test.t_other_policy (id int PRIMARY KEY, tenant_id uuid NOT NULL);
CREATE POLICY allow_all ON contract_test.t_other_policy FOR ALL USING (true) WITH CHECK (true);
DO $$
DECLARE v_mode text := contract_test.decision('other_policies');
BEGIN
CALL platform.apply_tenant_rls('contract_test.t_other_policy');
IF v_mode = 'drop' THEN
    PERFORM contract_test.assert_std_policy('contract_test.t_other_policy', 'B22-drop');
    PERFORM contract_test.assert_isolation('contract_test.t_other_policy', 'B22-drop');
  ELSIF v_mode = 'keep' THEN
    -- Giữ allow_all (PERMISSIVE, USING true) nghĩa là cách ly không còn được đảm bảo; chỉ kiểm policy chuẩn và allow_all còn đó
    PERFORM contract_test.assert_std_policy('contract_test.t_other_policy', 'B22-keep', true);
    IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'contract_test.t_other_policy'::regclass AND polname = 'allow_all') THEN
      RAISE EXCEPTION '[B22] contract chốt giữ policy khác nhưng allow_all đã bị xóa';
END IF;
ELSE
    RAISE EXCEPTION '[B22] decisions.other_policies không hợp lệ: %', v_mode;
END IF;
END $$;

-- B23-B24. Bảo toàn: ACL, index, dữ liệu (kể cả dòng tenant_id NULL nếu contract chấp nhận) không đổi sau apply
DO $$
DECLARE
guc text := contract_test.decision('tenant_guc');
  nullable boolean := (contract_test.decision('nullable_tenant_id') = 'accept');
  ta uuid := '00000000-0000-0000-0000-00000000000a';
  tb uuid := '00000000-0000-0000-0000-00000000000b';
  acl_before text; acl_after text;
  idx_before text; idx_after text;
  md5_before text; md5_after text;
  total_before int; total_after int; n int;
BEGIN
EXECUTE format('CREATE TABLE contract_test.t_preserve (id int PRIMARY KEY, tenant_id uuid %s, note text)',
               CASE WHEN nullable THEN '' ELSE 'NOT NULL' END);
CREATE INDEX t_preserve_note_idx ON contract_test.t_preserve (note);
GRANT SELECT ON contract_test.t_preserve TO PUBLIC;
INSERT INTO contract_test.t_preserve (id, tenant_id, note) VALUES (1, ta, 'a1'), (2, ta, 'a2'), (3, tb, 'b1');
IF nullable THEN
    INSERT INTO contract_test.t_preserve (id, tenant_id, note) VALUES (4, NULL, 'no-tenant');
END IF;

SELECT relacl::text INTO acl_before FROM pg_class WHERE oid = 'contract_test.t_preserve'::regclass;
SELECT string_agg(indexdef, E'\n' ORDER BY indexname) INTO idx_before
FROM pg_indexes WHERE schemaname = 'contract_test' AND tablename = 't_preserve';
SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY id), '')), count(*) INTO md5_before, total_before
FROM contract_test.t_preserve t;

CALL platform.apply_tenant_rls('contract_test.t_preserve');

SELECT relacl::text INTO acl_after FROM pg_class WHERE oid = 'contract_test.t_preserve'::regclass;
SELECT string_agg(indexdef, E'\n' ORDER BY indexname) INTO idx_after
FROM pg_indexes WHERE schemaname = 'contract_test' AND tablename = 't_preserve';
IF acl_before IS DISTINCT FROM acl_after THEN RAISE EXCEPTION '[B23] ACL bị đổi: % -> %', acl_before, acl_after; END IF;
  IF idx_before IS DISTINCT FROM idx_after THEN RAISE EXCEPTION '[B23] index bị đổi'; END IF;

  -- B24. Dưới RLS: mỗi tenant chỉ thấy dòng của mình, dòng NULL không thấy ở tenant nào
  PERFORM set_config(guc, ta::text, true);
SELECT count(*) INTO n FROM contract_test.t_preserve;
IF n <> 2 THEN RAISE EXCEPTION '[B24] tenant A phải thấy đúng 2 dòng, thấy %', n; END IF;
  PERFORM set_config(guc, tb::text, true);
SELECT count(*) INTO n FROM contract_test.t_preserve;
IF n <> 1 THEN RAISE EXCEPTION '[B24] tenant B phải thấy đúng 1 dòng, thấy %', n; END IF;

  -- Owner không bị FORCE thì thấy toàn bộ: dữ liệu phải còn nguyên (kể cả dòng NULL)
ALTER TABLE contract_test.t_preserve NO FORCE ROW LEVEL SECURITY;
SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY id), '')), count(*) INTO md5_after, total_after
FROM contract_test.t_preserve t;
IF total_before <> total_after OR md5_before <> md5_after THEN
    RAISE EXCEPTION '[B24] dữ liệu bị đổi sau apply (% dòng -> % dòng)', total_before, total_after;
END IF;

CALL platform.apply_tenant_rls('contract_test.t_preserve');
PERFORM contract_test.assert_std_policy('contract_test.t_preserve', 'B24');
END $$;

ROLLBACK;

-- Xác nhận test không để lại gì
DO $$
BEGIN
  IF to_regnamespace('contract_test') IS NOT NULL OR to_regnamespace('"Weird Schema"') IS NOT NULL THEN
    RAISE EXCEPTION '[B] test để lại schema sau ROLLBACK';
END IF;
END $$;

\echo 'Contract B (apply_tenant_rls): PASS'