SET client_min_messages = warning;
CREATE SCHEMA contract_test_c;

CREATE TABLE contract_test_c.items          (id int PRIMARY KEY, tenant_id uuid NOT NULL, val text NOT NULL);
CREATE TABLE contract_test_c.items_nullable (id int PRIMARY KEY, tenant_id uuid,          val text);
CALL apply_tenant_rls('contract_test_c.items');
CALL apply_tenant_rls('contract_test_c.items_nullable');

GRANT USAGE ON SCHEMA contract_test_c TO :"app";
GRANT SELECT, INSERT, UPDATE, DELETE
      ON contract_test_c.items, contract_test_c.items_nullable TO :"app";

CREATE FUNCTION contract_test_c.expect_sqlstate(tag text, stmt text, expected text) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE ok boolean := false;
BEGIN
BEGIN
EXECUTE stmt;
EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> expected THEN
      RAISE EXCEPTION '[%] kỳ vọng SQLSTATE %, nhận % (%)', tag, expected, SQLSTATE, SQLERRM;
END IF;
    ok := true;
END;
  IF NOT ok THEN
    RAISE EXCEPTION '[%] kỳ vọng lỗi % nhưng câu lệnh chạy được: %', tag, expected, stmt;
END IF;
END $$;

CREATE FUNCTION contract_test_c.expect_rows(tag text, stmt text, expected bigint) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
EXECUTE stmt;
GET DIAGNOSTICS n = ROW_COUNT;
IF n <> expected THEN
    RAISE EXCEPTION '[%] kỳ vọng % row, nhận %: %', tag, expected, n, stmt;
END IF;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA contract_test_c TO :"app";

SET app.tenant_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
INSERT INTO contract_test_c.items VALUES
                                      (1, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'seed'),
                                      (2, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'seed'),
                                      (3, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'seed');
INSERT INTO contract_test_c.items_nullable VALUES (101, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'seed');
SET app.tenant_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
INSERT INTO contract_test_c.items VALUES
                                      (11, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'seed'),
                                      (12, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'seed');
INSERT INTO contract_test_c.items_nullable VALUES (111, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'seed');
RESET app.tenant_id;