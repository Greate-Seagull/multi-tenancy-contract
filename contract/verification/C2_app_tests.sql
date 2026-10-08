SET client_min_messages = warning;

-- C0. Tiền đề: app không superuser/BYPASSRLS và không sở hữu bảng
DO $$
DECLARE r pg_roles%ROWTYPE;
BEGIN
SELECT * INTO STRICT r FROM pg_roles WHERE rolname = current_user;
IF r.rolsuper OR r.rolbypassrls THEN
    RAISE EXCEPTION '[C0] role % là superuser/BYPASSRLS', current_user;
END IF;
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'contract_test_c' AND tableowner = current_user) THEN
    RAISE EXCEPTION '[C0] role app không được là owner của bảng';
END IF;
END $$;

-- C15. Không set tenant -> 0 row (GUC chưa set, rồi GUC rỗng), có đối chứng để không pass giả
DO $$
BEGIN
  IF (SELECT count(*) FROM contract_test_c.items) <> 0
     OR (SELECT count(*) FROM contract_test_c.items_nullable) <> 0 THEN
    RAISE EXCEPTION '[C15] GUC chưa set phải thấy 0 row';
END IF;
  PERFORM set_config('app.tenant_id', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
  IF (SELECT count(*) FROM contract_test_c.items) = 0 THEN
    RAISE EXCEPTION '[C15] đối chứng: tenant A phải thấy dữ liệu';
END IF;
  PERFORM set_config('app.tenant_id', '', true);
  IF (SELECT count(*) FROM contract_test_c.items) <> 0 THEN
    RAISE EXCEPTION '[C15] GUC rỗng phải thấy 0 row';
END IF;
END $$;

-- C14. SELECT: mỗi tenant chỉ thấy row của mình
DO $$
DECLARE ta constant text := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
        tb constant text := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
BEGIN
  PERFORM set_config('app.tenant_id', ta, true);
  IF (SELECT array_agg(id ORDER BY id) FROM contract_test_c.items) IS DISTINCT FROM ARRAY[1,2,3] THEN
    RAISE EXCEPTION '[C14] tenant A phải thấy đúng id 1,2,3';
END IF;
  IF (SELECT count(*) FROM contract_test_c.items WHERE tenant_id = tb::uuid) <> 0
     OR (SELECT count(*) FROM contract_test_c.items WHERE id IN (11, 12)) <> 0 THEN
    RAISE EXCEPTION '[C14] tenant A lọc thẳng row của B vẫn phải ra 0';
END IF;
  IF (SELECT array_agg(id) FROM contract_test_c.items_nullable) IS DISTINCT FROM ARRAY[101] THEN
    RAISE EXCEPTION '[C14] items_nullable: tenant A phải thấy đúng id 101';
END IF;

  PERFORM set_config('app.tenant_id', tb, true);
  IF (SELECT array_agg(id ORDER BY id) FROM contract_test_c.items) IS DISTINCT FROM ARRAY[11,12] THEN
    RAISE EXCEPTION '[C14] tenant B phải thấy đúng id 11,12';
END IF;
  IF (SELECT array_agg(id) FROM contract_test_c.items_nullable) IS DISTINCT FROM ARRAY[111] THEN
    RAISE EXCEPTION '[C14] items_nullable: tenant B phải thấy đúng id 111';
END IF;
END $$;

-- C16. INSERT: WITH CHECK chặn tenant khác và khi chưa set tenant; tenant mình thì được
BEGIN;
DO $$
DECLARE ta constant text := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
        tb constant text := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
BEGIN
  PERFORM set_config('app.tenant_id', ta, true);
  PERFORM contract_test_c.expect_rows('C16 insert tenant mình',
    format('INSERT INTO contract_test_c.items VALUES (21, %L, ''ok'')', ta), 1);
  PERFORM contract_test_c.expect_sqlstate('C16 insert tenant khác',
    format('INSERT INTO contract_test_c.items VALUES (22, %L, ''x'')', tb), '42501');

  PERFORM set_config('app.tenant_id', '', true);
  PERFORM contract_test_c.expect_sqlstate('C16 insert khi chưa set tenant',
    format('INSERT INTO contract_test_c.items VALUES (23, %L, ''x'')', ta), '42501');
END $$;
ROLLBACK;

-- C17. INSERT tenant_id = NULL bị từ chối ngay cả khi cột cho phép NULL (không nhờ NOT NULL)
BEGIN;
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
  PERFORM contract_test_c.expect_sqlstate('C17 NULL tenant (cột nullable)',
    'INSERT INTO contract_test_c.items_nullable VALUES (121, NULL, ''x'')', '42501');
END $$;
ROLLBACK;

-- C18. UPDATE/DELETE row tenant khác -> 0 row bị ảnh hưởng; không WHERE chỉ chạm row của mình
BEGIN;
DO $$
DECLARE ta constant text := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
        tb constant text := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
BEGIN
  PERFORM set_config('app.tenant_id', ta, true);
  PERFORM contract_test_c.expect_rows('C18 update row tenant khác',
    'UPDATE contract_test_c.items SET val = ''hacked'' WHERE id IN (11, 12)', 0);
  PERFORM contract_test_c.expect_rows('C18 delete row tenant khác',
    'DELETE FROM contract_test_c.items WHERE id IN (11, 12)', 0);
  PERFORM contract_test_c.expect_rows('C18 update không WHERE',
    'UPDATE contract_test_c.items SET val = ''mine''', 3);
  PERFORM contract_test_c.expect_rows('C18 delete không WHERE',
    'DELETE FROM contract_test_c.items', 3);

  PERFORM set_config('app.tenant_id', tb, true);   -- đối chứng: dữ liệu B nguyên vẹn
  IF (SELECT count(*) FROM contract_test_c.items WHERE val = 'seed') <> 2 THEN
    RAISE EXCEPTION '[C18] dữ liệu tenant B bị thay đổi';
END IF;
END $$;
ROLLBACK;

-- C19. UPDATE tenant_id sang tenant khác (hoặc NULL) bị từ chối
BEGIN;
DO $$
DECLARE ta constant text := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
        tb constant text := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
BEGIN
  PERFORM set_config('app.tenant_id', ta, true);
  PERFORM contract_test_c.expect_sqlstate('C19 đẩy row sang tenant B',
    format('UPDATE contract_test_c.items SET tenant_id = %L WHERE id = 1', tb), '42501');
  PERFORM contract_test_c.expect_sqlstate('C19 đổi tenant_id thành NULL',
    'UPDATE contract_test_c.items_nullable SET tenant_id = NULL WHERE id = 101', '42501');
  PERFORM contract_test_c.expect_rows('C19 đối chứng: giữ nguyên tenant mình',
    format('UPDATE contract_test_c.items SET tenant_id = %L WHERE id = 1', ta), 1);
END $$;
ROLLBACK;

-- C20. FOR UPDATE, RETURNING, ON CONFLICT không chạm/lộ row tenant khác
BEGIN;
DO $$
DECLARE ta constant text := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
        tb constant text := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
        ids int[];
BEGIN
  PERFORM set_config('app.tenant_id', ta, true);

  PERFORM contract_test_c.expect_rows('C20 FOR UPDATE row tenant khác',
    'SELECT * FROM contract_test_c.items WHERE id IN (11, 12) FOR UPDATE', 0);
  PERFORM contract_test_c.expect_rows('C20 FOR UPDATE row của mình',
    'SELECT * FROM contract_test_c.items FOR UPDATE', 3);

WITH u AS (UPDATE contract_test_c.items SET val = 'r' RETURNING id)
SELECT array_agg(id ORDER BY id) INTO ids FROM u;
IF ids IS DISTINCT FROM ARRAY[1,2,3] THEN
    RAISE EXCEPTION '[C20] UPDATE ... RETURNING phải chỉ trả row của tenant A, nhận %', ids;
END IF;
WITH d AS (DELETE FROM contract_test_c.items WHERE id IN (3, 11, 12) RETURNING id)
SELECT array_agg(id ORDER BY id) INTO ids FROM d;
IF ids IS DISTINCT FROM ARRAY[3] THEN
    RAISE EXCEPTION '[C20] DELETE ... RETURNING phải chỉ trả row của tenant A, nhận %', ids;
END IF;

  PERFORM contract_test_c.expect_sqlstate('C20 ON CONFLICT DO UPDATE đè row tenant khác',
    format('INSERT INTO contract_test_c.items VALUES (11, %L, ''hijack'') '
           'ON CONFLICT (id) DO UPDATE SET val = EXCLUDED.val', ta), '42501');
  PERFORM contract_test_c.expect_rows('C20 ON CONFLICT DO UPDATE row của mình',
    format('INSERT INTO contract_test_c.items VALUES (1, %L, ''up'') '
           'ON CONFLICT (id) DO UPDATE SET val = EXCLUDED.val', ta), 1);

  PERFORM set_config('app.tenant_id', tb, true);   -- đối chứng: dữ liệu B nguyên vẹn
  IF (SELECT count(*) FROM contract_test_c.items WHERE val = 'seed') <> 2 THEN
    RAISE EXCEPTION '[C20] dữ liệu tenant B bị thay đổi';
END IF;
END $$;
ROLLBACK;