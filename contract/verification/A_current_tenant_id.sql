-- Contract test current_tenant_id()
-- Chạy bằng ROLE APP, trên session mới, KHÔNG dùng --single-transaction:
--   psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f A_current_tenant_id.sql

-- A0. Tiền đề: role app không phải superuser/BYPASSRLS (nếu không, test RLS pass giả)
DO $$
DECLARE r pg_roles%ROWTYPE;
BEGIN
SELECT * INTO STRICT r FROM pg_roles WHERE rolname = current_user;
IF r.rolsuper OR r.rolbypassrls THEN
    RAISE EXCEPTION '[A0] role % là superuser/BYPASSRLS', current_user;
END IF;
END $$;

-- A1. GUC chưa set -> NULL, không lỗi (phải chạy đầu tiên, khi session chưa từng set GUC)
DO $$
BEGIN
  IF current_tenant_id() IS NOT NULL THEN
    RAISE EXCEPTION '[A1] GUC chưa set phải trả NULL';
END IF;
END $$;

-- A2. GUC = '' -> NULL
SET app.tenant_id = '';
DO $$
BEGIN
  IF current_tenant_id() IS NOT NULL THEN
    RAISE EXCEPTION '[A2] GUC rỗng phải trả NULL';
END IF;
END $$;

-- A3. UUID hợp lệ -> đúng uuid (chữ thường và chữ hoa)
DO $$
DECLARE t uuid := gen_random_uuid();
BEGIN
  PERFORM set_config('app.tenant_id', t::text, false);
  IF current_tenant_id() IS DISTINCT FROM t THEN
    RAISE EXCEPTION '[A3] uuid chữ thường: kỳ vọng %, nhận %', t, current_tenant_id();
END IF;
  PERFORM set_config('app.tenant_id', upper(t::text), false);
  IF current_tenant_id() IS DISTINCT FROM t THEN
    RAISE EXCEPTION '[A3] uuid chữ hoa: kỳ vọng %, nhận %', t, current_tenant_id();
END IF;
END $$;

-- A4. Chuỗi không phải uuid -> lỗi 22P02 (fail to, không rò dữ liệu)
DO $$
DECLARE bad text;
BEGIN
  FOREACH bad IN ARRAY ARRAY['not-a-uuid', '123', '00000000-0000-0000-0000-00000000000g'] LOOP
    PERFORM set_config('app.tenant_id', bad, false);
BEGIN
      PERFORM current_tenant_id();
      RAISE EXCEPTION '[A4] giá trị "%" phải gây lỗi 22P02 nhưng không lỗi', bad;
EXCEPTION WHEN SQLSTATE '22P02' THEN
      NULL; -- đúng kỳ vọng
END;
END LOOP;
END $$;

-- A5. SET LOCAL không rò sang transaction sau trên cùng session (commit và rollback)
SET app.tenant_id = '';

BEGIN;
SET LOCAL app.tenant_id = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  IF current_tenant_id() IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'::uuid THEN
    RAISE EXCEPTION '[A5] trong tx phải thấy tenant vừa SET LOCAL';
END IF;
END $$;
COMMIT;
DO $$
BEGIN
  IF current_tenant_id() IS NOT NULL THEN
    RAISE EXCEPTION '[A5] sau COMMIT, SET LOCAL bị rò: %', current_tenant_id();
END IF;
END $$;

BEGIN;
SET LOCAL app.tenant_id = '22222222-2222-2222-2222-222222222222';
ROLLBACK;
DO $$
BEGIN
  IF current_tenant_id() IS NOT NULL THEN
    RAISE EXCEPTION '[A5] sau ROLLBACK, SET LOCAL bị rò: %', current_tenant_id();
END IF;
END $$;

-- A6. Metadata: LANGUAGE sql, STABLE, PARALLEL SAFE, không SECURITY DEFINER, trả uuid, không tham số
DO $$
DECLARE p pg_proc%ROWTYPE; lang text;
BEGIN
SELECT * INTO STRICT p FROM pg_proc WHERE oid = 'current_tenant_id()'::regprocedure;
SELECT lanname INTO lang FROM pg_language WHERE oid = p.prolang;
IF p.provolatile <> 's'            THEN RAISE EXCEPTION '[A6] phải STABLE, hiện là %', p.provolatile; END IF;
  IF p.proparallel <> 's'            THEN RAISE EXCEPTION '[A6] phải PARALLEL SAFE, hiện là %', p.proparallel; END IF;
  IF p.prosecdef                     THEN RAISE EXCEPTION '[A6] không được SECURITY DEFINER'; END IF;
  IF p.prorettype <> 'uuid'::regtype THEN RAISE EXCEPTION '[A6] phải trả uuid'; END IF;
  IF p.pronargs <> 0                 THEN RAISE EXCEPTION '[A6] không được có tham số'; END IF;
  IF lang <> 'sql'                   THEN RAISE EXCEPTION '[A6] phải LANGUAGE sql, hiện là %', lang; END IF;
END $$;

\echo 'Contract A (current_tenant_id): PASS'