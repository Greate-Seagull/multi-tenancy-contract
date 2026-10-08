SET client_min_messages = warning;

-- C21
DO $$
BEGIN
  IF (SELECT count(*) FROM pg_tables
       WHERE schemaname = 'contract_test_c' AND tableowner = current_user) <> 2 THEN
    RAISE EXCEPTION '[C21] tiền đề sai: migrator phải là owner của cả 2 bảng';
  END IF;

  IF (SELECT count(*) FROM contract_test_c.items) <> 0
     OR (SELECT count(*) FROM contract_test_c.items_nullable) <> 0 THEN
    RAISE EXCEPTION '[C21] owner chưa set tenant phải thấy 0 row (FORCE RLS không có tác dụng?)';
  END IF;

  PERFORM set_config('app.tenant_id', '', true);
  IF (SELECT count(*) FROM contract_test_c.items) <> 0 THEN
    RAISE EXCEPTION '[C21] owner với GUC rỗng phải thấy 0 row';
  END IF;

  PERFORM contract_test_c.expect_sqlstate('C21 owner insert khi chưa set tenant',
    'INSERT INTO contract_test_c.items VALUES (31, ''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'', ''x'')', '42501');

  PERFORM set_config('app.tenant_id', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
  IF (SELECT count(*) FROM contract_test_c.items) <> 3 THEN
    RAISE EXCEPTION '[C21] đối chứng: owner đặt tenant A phải thấy 3 row';
  END IF;
END $$;