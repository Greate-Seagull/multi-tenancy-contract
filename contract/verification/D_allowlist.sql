-- Allowlist cho D_catalog_guard.sql. Mỗi mục BẮT BUỘC có lý do.
-- Mục không còn khớp vi phạm nào sẽ làm test fail (D0-stale) để allowlist không phình ra.
--
-- Quy ước cột object:
--   bảng/view          'schema.table'
--   FK / constraint    'schema.table.constraint_name'
--   unique/PK index    'schema.table.index_name'
--   hàm                'schema.func(arg_types)'      (đúng như pg_get_function_identity_arguments)
--   role               tên role
--   schema             tên schema
--
-- check_id: D0, D0-exec, D23, D23-notnull, D23-global, D23-inherit, D24-role, D24-priv,
--           D24-global-write, D24-flyway, D24-owner, D24-member, D25, D26,
--           D-FK, D-UNIQUE, D-VIEW, D-MATVIEW, D-SECDEF, D-SECDEF-OWNER, D-SECDEF-PATH
CREATE TEMP TABLE allow (
  check_id text NOT NULL,
  object   text NOT NULL,
  reason   text NOT NULL CHECK (length(btrim(reason)) > 0),
  PRIMARY KEY (check_id, object)
);

INSERT INTO allow (check_id, object, reason) VALUES
    ('D23-global', 'platform.flyway_schema_history', 'Flyway quản lý, không phải dữ liệu tenant')
    , ('D23-global', 'test.flyway_schema_history', 'Flyway quản lý, không phải dữ liệu tenant')
-- , ('D23-global', 'public.provinces', 'danh mục dùng chung, app chỉ đọc')
-- , ('D-FK', 'public.order_item.fk_order_item_product', 'trỏ bảng danh mục dùng chung')
-- , ('D-SECDEF', 'public.some_fn(uuid)', 'lý do cần SECURITY DEFINER')
;