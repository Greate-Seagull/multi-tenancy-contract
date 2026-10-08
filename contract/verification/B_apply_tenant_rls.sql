-- Contract test nhóm B: apply_tenant_rls()
-- Chạy bằng ROLE MIGRATOR (owner database), trên môi trường test, KHÔNG dùng --single-transaction:
--   psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f B_apply_tenant_rls.sql
-- Toàn bộ test nằm trong BEGIN ... ROLLBACK: không để lại schema/bảng nào.
-- Procedure gọi theo search_path; nếu nằm schema riêng, sed 'apply_tenant_rls(' thành 'platform.apply_tenant_rls('.

SET client_min_messages = warning;

-- B0. Tiền đề: migrator không phải superuser/BYPASSRLS (nếu có thì FORCE vô nghĩa)
DO $$
DECLARE r pg_roles%ROWTYPE;
BEGIN
SELECT * INTO STRICT r FROM pg_roles WHERE rolname = current_user;
IF r.rolsuper OR r.rolbypassrls THEN
    RAISE EXCEPTION '[B0] role % là superuser/BYPASSRLS', current_user;
END IF;
END $$;

BEGIN;

CREATE SCHEMA contract_test;
CREATE TABLE contract_test.t_basic (id int PRIMARY KEY, tenant_id uuid NOT NULL);

-- B7. Sau khi gọi: ENABLE và FORCE đều bật (thiếu FORCE thì owner bypass RLS)
DO $$
DECLARE r pg_class%ROWTYPE;
BEGIN
SELECT * INTO STRICT r FROM pg_class WHERE oid = 'contract_test.t_basic'::regclass;
IF r.relrowsecurity OR r.relforcerowsecurity THEN
    RAISE EXCEPTION '[B7] tiền đề sai: bảng mới đã có RLS';
END IF;

CALL apply_tenant_rls('contract_test.t_basic');

SELECT * INTO STRICT r FROM pg_class WHERE oid = 'contract_test.t_basic'::regclass;
IF NOT r.relrowsecurity      THEN RAISE EXCEPTION '[B7] thiếu ENABLE ROW LEVEL SECURITY'; END IF;
  IF NOT r.relforcerowsecurity THEN RAISE EXCEPTION '[B7] thiếu FORCE ROW LEVEL SECURITY'; END IF;
END $$;

-- B8. Đúng 1 policy tenant_isolation: ALL, PERMISSIVE, mọi role, có USING và WITH CHECK dùng current_tenant_id()
DO $$
DECLARE n int; p pg_policies%ROWTYPE;
BEGIN
SELECT count(*) INTO n FROM pg_policies
WHERE schemaname = 'contract_test' AND tablename = 't_basic';
IF n <> 1 THEN RAISE EXCEPTION '[B8] phải có đúng 1 policy, hiện có %', n; END IF;

SELECT * INTO STRICT p FROM pg_policies
WHERE schemaname = 'contract_test' AND tablename = 't_basic' AND policyname = 'tenant_isolation';
IF p.cmd <> 'ALL'                 THEN RAISE EXCEPTION '[B8] cmd phải là ALL, hiện là %', p.cmd; END IF;
  IF p.permissive <> 'PERMISSIVE'   THEN RAISE EXCEPTION '[B8] phải PERMISSIVE'; END IF;
  IF p.roles <> '{public}'::name[]  THEN RAISE EXCEPTION '[B8] policy phải áp cho mọi role, hiện là %', p.roles; END IF;
  IF p.qual IS NULL OR p.qual NOT LIKE '%tenant_id%current_tenant_id()%' THEN
    RAISE EXCEPTION '[B8] USING sai hoặc thiếu: %', p.qual;
END IF;
  IF p.with_check IS NULL OR p.with_check NOT LIKE '%tenant_id%current_tenant_id()%' THEN
    RAISE EXCEPTION '[B8] WITH CHECK sai hoặc thiếu: %', p.with_check;
END IF;
END $$;

-- B9. Gọi lại nhiều lần: không lỗi, vẫn đúng 1 policy, cờ RLS vẫn bật
DO $$
DECLARE n int; r pg_class%ROWTYPE;
BEGIN
CALL apply_tenant_rls('contract_test.t_basic');
CALL apply_tenant_rls('contract_test.t_basic');
SELECT count(*) INTO n FROM pg_policy WHERE polrelid = 'contract_test.t_basic'::regclass;
IF n <> 1 THEN RAISE EXCEPTION '[B9] sau khi gọi lại phải còn đúng 1 policy, hiện có %', n; END IF;
SELECT * INTO STRICT r FROM pg_class WHERE oid = 'contract_test.t_basic'::regclass;
IF NOT (r.relrowsecurity AND r.relforcerowsecurity) THEN RAISE EXCEPTION '[B9] cờ RLS bị mất'; END IF;
END $$;

-- B10. Drift: policy bị sửa tay (USING (true), mất WITH CHECK) và NO FORCE -> gọi lại phải khôi phục
DROP POLICY tenant_isolation ON contract_test.t_basic;
CREATE POLICY tenant_isolation ON contract_test.t_basic USING (true);
ALTER TABLE contract_test.t_basic NO FORCE ROW LEVEL SECURITY;
DO $$
DECLARE p pg_policies%ROWTYPE; r pg_class%ROWTYPE;
BEGIN
CALL apply_tenant_rls('contract_test.t_basic');
SELECT * INTO STRICT p FROM pg_policies
WHERE schemaname = 'contract_test' AND tablename = 't_basic' AND policyname = 'tenant_isolation';
IF p.qual NOT LIKE '%current_tenant_id()%' THEN RAISE EXCEPTION '[B10] USING chưa được khôi phục: %', p.qual; END IF;
  IF p.with_check IS NULL                    THEN RAISE EXCEPTION '[B10] WITH CHECK chưa được khôi phục'; END IF;
SELECT * INTO STRICT r FROM pg_class WHERE oid = 'contract_test.t_basic'::regclass;
IF NOT r.relforcerowsecurity THEN RAISE EXCEPTION '[B10] FORCE chưa được bật lại'; END IF;
END $$;

-- B11. Bảng thiếu cột tenant_id / sai kiểu: phải lỗi, và sau khi hoàn tác không còn RLS dở dang
CREATE TABLE contract_test.t_no_tenant   (id int);
CREATE TABLE contract_test.t_wrong_type  (id int, tenant_id text);
DO $$
DECLARE t text; r pg_class%ROWTYPE;
BEGIN
  FOREACH t IN ARRAY ARRAY['t_no_tenant', 't_wrong_type'] LOOP
BEGIN
CALL apply_tenant_rls(format('contract_test.%I', t)::regclass);
RAISE EXCEPTION '[B11] bảng % phải làm apply_tenant_rls báo lỗi', t;
EXCEPTION WHEN undefined_column OR undefined_function THEN
      NULL; -- 42703 (thiếu cột) hoặc 42883 (text = uuid)
END;
SELECT * INTO STRICT r FROM pg_class WHERE oid = format('contract_test.%I', t)::regclass;
IF r.relrowsecurity OR r.relforcerowsecurity
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = r.oid) THEN
      RAISE EXCEPTION '[B11] bảng % bị bật RLS dở dang sau khi lỗi', t;
END IF;
END LOOP;
END $$;

-- B12. Tên đặc biệt: chữ hoa, khoảng trắng, từ khóa, dấu ", ký tự %, schema khác
CREATE SCHEMA "Weird Schema";
DO $$
DECLARE c record; rel regclass; r pg_class%ROWTYPE;
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
CALL apply_tenant_rls(rel);
SELECT * INTO STRICT r FROM pg_class WHERE oid = rel;
IF NOT (r.relrowsecurity AND r.relforcerowsecurity) THEN
      RAISE EXCEPTION '[B12] %.%: cờ RLS không bật', c.s, c.t;
END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = rel AND polname = 'tenant_isolation') THEN
      RAISE EXCEPTION '[B12] %.%: thiếu policy tenant_isolation', c.s, c.t;
END IF;
END LOOP;
END $$;

-- B13. Bảng partitioned: áp lên parent KHÔNG lan xuống partition (phải gọi riêng cho từng partition)
CREATE TABLE contract_test.p (id int, tenant_id uuid NOT NULL) PARTITION BY HASH (tenant_id);
CREATE TABLE contract_test.p_0 PARTITION OF contract_test.p FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE contract_test.p_1 PARTITION OF contract_test.p FOR VALUES WITH (MODULUS 2, REMAINDER 1);
DO $$
DECLARE part text; r pg_class%ROWTYPE;
BEGIN
CALL apply_tenant_rls('contract_test.p');

SELECT * INTO STRICT r FROM pg_class WHERE oid = 'contract_test.p'::regclass;
IF NOT (r.relrowsecurity AND r.relforcerowsecurity) THEN RAISE EXCEPTION '[B13] parent không bật RLS'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = r.oid AND polname = 'tenant_isolation') THEN
    RAISE EXCEPTION '[B13] parent thiếu policy';
END IF;

  FOREACH part IN ARRAY ARRAY['p_0', 'p_1'] LOOP
SELECT * INTO STRICT r FROM pg_class WHERE oid = format('contract_test.%I', part)::regclass;
IF r.relrowsecurity OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = r.oid) THEN
      RAISE EXCEPTION '[B13] % đã tự có RLS/policy: hành vi partition của Postgres đã đổi, xem lại contract', part;
END IF;
CALL apply_tenant_rls(format('contract_test.%I', part)::regclass);
SELECT * INTO STRICT r FROM pg_class WHERE oid = format('contract_test.%I', part)::regclass;
IF NOT (r.relrowsecurity AND r.relforcerowsecurity) THEN
      RAISE EXCEPTION '[B13] % gọi riêng nhưng RLS không bật', part;
END IF;
END LOOP;
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