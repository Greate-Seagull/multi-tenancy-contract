"""Nhóm PRV – Phân quyền theo câu lệnh và vai trò (tài liệu mục 3.1, 3.5).

FILE MỚI: không sửa file nhóm khác; dùng lại fixture (settings, schema, app_conn) và helpers sẵn có.

Biến môi trường riêng của nhóm này (ngoài APP_USER_DSN, ADMIN_DSN):
  APP_MIGRATOR_DSN  DSN của role app_migrator. Thiếu -> test cần nó được SKIP (có ghi lý do).
  APP_ENV           dev | prod. Chỉ TC-PRV-14 cần. Thiếu -> PRV-14 SKIP.

Quy ước: chạy riêng một case:  pytest -k prv_03   |   cả nhóm: pytest tests/test_prv.py
Mọi câu lệnh "thử phá" đều chạy trong transaction rồi ROLLBACK (hoặc bị từ chối), không để lại dữ liệu.
"""
from __future__ import annotations

import contextlib
import logging
import os

import psycopg
import pytest
from psycopg import errors as pgerr
from psycopg import sql

from helpers import (
    ORDER_A1, ORDER_A2, ORDER_B1, OTHER_TENANT, OWN_ORDER, TENANT_A, TENANT_B, TENANT_LABEL,
    TenantSession, tc,
)

pytestmark = pytest.mark.prv
log = logging.getLogger("prv")

TENANTS = [pytest.param(TENANT_A, id="tenant_A"), pytest.param(TENANT_B, id="tenant_B")]
OWN_ORDERS = {TENANT_A: {ORDER_A1, ORDER_A2}, TENANT_B: {ORDER_B1}}


# ---------------------------------------------------------------------------
# Công cụ riêng của nhóm PRV
# ---------------------------------------------------------------------------
def _flat(text: str, limit: int = 200) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 3] + "..."


def _first_line(exc: Exception) -> str:
    return str(exc).strip().splitlines()[0]


def session(conn, tenant_id, role: str) -> TenantSession:
    """TenantSession có nhãn log gồm cả vai trò, ví dụ [app_migrator] hoặc [app_user/A]."""
    s = TenantSession(conn, tenant_id)
    s.label = f"{role}/{TENANT_LABEL[tenant_id]}" if tenant_id else role
    return s


def open_role(role: str, settings) -> psycopg.Connection:
    """Mở kết nối autocommit MỚI theo vai trò (người gọi phải đóng). Thiếu DSN -> skip."""
    if role == "app_user":
        dsn = settings.app_dsn
    elif role == "app_migrator":
        dsn = settings.migrator_dsn
        if not dsn:
            pytest.skip("Thiếu APP_MIGRATOR_DSN – bỏ qua test cần role app_migrator")
    elif role in ("postgres", "app_owner"):
        dsn = settings.admin_dsn
    else:
        raise ValueError(role)
    conn = psycopg.connect(dsn, autocommit=True, application_name="tbl-isolation-tests")
    if role == "app_owner":  # app_owner là NOLOGIN -> vào bằng SET ROLE từ ADMIN
        conn.execute(sql.SQL("SET ROLE {}").format(sql.Identifier(settings.owner_role)))
    log.info("[%s] mở kết nối: user=%s", role, conn.execute("SELECT current_user").fetchone()[0])
    return conn


def expect_error(conn, label: str, statement: str, expected, cleanup: str | None = None):
    """Chạy trên kết nối autocommit; PHẢI lỗi thuộc `expected` (class hoặc tuple class)."""
    expected = (expected,) if isinstance(expected, type) else tuple(expected)
    names = "/".join(e.__name__ for e in expected)
    log.debug("[%s] SQL: %s", label, statement)
    try:
        conn.execute(statement)
    except psycopg.Error as exc:
        log.info("[%s] %s -> LỖI %s (SQLSTATE %s): %s",
                 label, _flat(statement), type(exc).__name__, exc.sqlstate, _first_line(exc))
        if not isinstance(exc, expected):
            raise AssertionError(f"[{label}] mong đợi {names} nhưng nhận {type(exc).__name__} "
                                 f"(SQLSTATE {exc.sqlstate}): {_first_line(exc)}\n  SQL: {_flat(statement)}") from exc
        return exc
    log.info("[%s] %s -> CHẠY THÀNH CÔNG", label, _flat(statement))
    if cleanup:
        with contextlib.suppress(psycopg.Error):
            conn.execute(cleanup)
    raise AssertionError(f"[{label}] mong đợi lỗi {names} nhưng câu lệnh CHẠY THÀNH CÔNG\n  SQL: {_flat(statement)}")


def role_conn(role: str, request):
    """Kết nối dùng chung (không autocommit) của app_user hoặc app_migrator."""
    return request.getfixturevalue({"app_user": "app_conn", "app_migrator": "migrator_conn"}[role])


def denied(params: dict) -> list:
    return [pytest.param(v, id=k) for k, v in params.items()]


def assert_app_user_denied(app_conn, schema, settings, statement: str):
    with session(app_conn, TENANT_A, "app_user") as s:
        s.expect_denied(statement.format(s=schema, owner=settings.owner_role))


@pytest.fixture(scope="session")
def migrator_conn(schema, settings):
    dsn = settings.migrator_dsn
    if not dsn:
        pytest.skip("Thiếu APP_MIGRATOR_DSN – bỏ qua test cần role app_migrator")
    conn = psycopg.connect(dsn, application_name="tbl-isolation-tests")
    log.info("APP_MIGRATOR kết nối: host=%s db=%s user=%s", conn.info.host, conn.info.dbname, conn.info.user)
    if conn.execute("SELECT rolsuper FROM pg_roles WHERE rolname = current_user").fetchone()[0]:
        conn.close()
        pytest.exit("Role của APP_MIGRATOR_DSN là SUPERUSER – test phân quyền vô nghĩa", returncode=2)
    conn.rollback()
    yield conn
    conn.close()


# ===========================================================================
# TC-PRV-01 – CREATE/ALTER/DROP TABLE
# ===========================================================================
PRV01 = ("TC-PRV-01", "P0", "app_user không chạy được CREATE/ALTER/DROP TABLE", "permission denied")
PRV01_SQL = {
    "create_table": "CREATE TABLE {s}.prv_probe (id int)",
    "alter_add_column": "ALTER TABLE {s}.orders ADD COLUMN prv_probe int",
    "alter_rename": "ALTER TABLE {s}.orders RENAME TO orders_renamed",
    "alter_disable_rls": "ALTER TABLE {s}.orders DISABLE ROW LEVEL SECURITY",
    "alter_no_force_rls": "ALTER TABLE {s}.orders NO FORCE ROW LEVEL SECURITY",
    "drop_table": "DROP TABLE {s}.orders",
    "drop_table_child": "DROP TABLE {s}.order_items",
}


@tc(*PRV01)
@pytest.mark.parametrize("statement", denied(PRV01_SQL))
def test_prv_01_table_ddl_denied(app_conn, schema, settings, statement):
    assert_app_user_denied(app_conn, schema, settings, statement)


# ===========================================================================
# TC-PRV-02 – TRUNCATE
# ===========================================================================
PRV02 = ("TC-PRV-02", "P0", "app_user không chạy được TRUNCATE", "permission denied")


@tc(*PRV02)
@pytest.mark.parametrize("table", ["orders", "order_items", "memberships", "tenants", "countries"])
def test_prv_02_truncate_denied(app_conn, schema, settings, table):
    assert_app_user_denied(app_conn, schema, settings, f"TRUNCATE {{s}}.{table}")


# ===========================================================================
# TC-PRV-03 – INDEX / VIEW / FUNCTION / PROCEDURE / TRIGGER
# ===========================================================================
PRV03 = ("TC-PRV-03", "P0", "app_user không CREATE INDEX / VIEW / FUNCTION / PROCEDURE / TRIGGER", "permission denied")
PRV03_SQL = {
    "create_index": "CREATE INDEX prv_probe_idx ON {s}.orders (code)",
    "create_view": "CREATE VIEW {s}.prv_probe_v AS SELECT 1 AS x",
    "create_function": "CREATE FUNCTION {s}.prv_probe_f() RETURNS int LANGUAGE sql AS 'SELECT 1'",
    "create_procedure": "CREATE PROCEDURE {s}.prv_probe_p() LANGUAGE sql AS 'SELECT 1'",
    "create_trigger": "CREATE TRIGGER prv_probe_t BEFORE UPDATE ON {s}.orders FOR EACH ROW "
                      "EXECUTE FUNCTION suppress_redundant_updates_trigger()",
}


@tc(*PRV03)
@pytest.mark.parametrize("statement", denied(PRV03_SQL))
def test_prv_03_object_ddl_denied(app_conn, schema, settings, statement):
    assert_app_user_denied(app_conn, schema, settings, statement)


# ===========================================================================
# TC-PRV-04 – POLICY
# ===========================================================================
PRV04 = ("TC-PRV-04", "P0", "app_user không CREATE/ALTER/DROP POLICY", "permission denied (không phải owner)")
PRV04_SQL = {
    "create_policy": "CREATE POLICY prv_probe ON {s}.orders USING (true)",
    "alter_policy": "ALTER POLICY tenant_isolation ON {s}.orders USING (true)",
    "drop_policy": "DROP POLICY tenant_isolation ON {s}.orders",
}


@tc(*PRV04)
@pytest.mark.parametrize("statement", denied(PRV04_SQL))
def test_prv_04_policy_ddl_denied(app_conn, schema, settings, statement):
    assert_app_user_denied(app_conn, schema, settings, statement)


# ===========================================================================
# TC-PRV-05 – SCHEMA / DATABASE
# ===========================================================================
PRV05 = ("TC-PRV-05", "P0", "app_user không CREATE SCHEMA / DATABASE", "permission denied")
PRV05_SQL = {
    "create_schema": "CREATE SCHEMA prv_probe_schema",
    "drop_fixture_schema": "DROP SCHEMA {s} CASCADE",
}


@tc(*PRV05)
@pytest.mark.parametrize("statement", denied(PRV05_SQL))
def test_prv_05_schema_ddl_denied(app_conn, schema, settings, statement):
    assert_app_user_denied(app_conn, schema, settings, statement)


@tc(*PRV05)
def test_prv_05_create_database_denied(settings):
    # CREATE DATABASE không chạy được trong transaction -> dùng kết nối autocommit riêng
    with contextlib.closing(open_role("app_user", settings)) as conn:
        expect_error(conn, "app_user", "CREATE DATABASE tbl_prv_probe_db", pgerr.InsufficientPrivilege,
                     cleanup="DROP DATABASE IF EXISTS tbl_prv_probe_db")


# ===========================================================================
# TC-PRV-06 – GRANT / REVOKE / ALTER DEFAULT PRIVILEGES
# ===========================================================================
PRV06 = ("TC-PRV-06", "P0", "app_user không GRANT/REVOKE/ALTER DEFAULT PRIVILEGES",
         "permission denied (hoặc PostgreSQL chỉ cảnh báo và quyền KHÔNG đổi)")
ACL_STATEMENTS = {
    "grant_truncate_to_self": ("GRANT TRUNCATE ON {s}.orders TO CURRENT_USER", "orders"),
    "grant_select_to_public": ("GRANT SELECT ON {s}.orders TO PUBLIC", "orders"),
    "grant_all_job_queue": ("GRANT ALL ON {s}.job_queue TO CURRENT_USER", "job_queue"),
    "revoke_own_insert": ("REVOKE INSERT ON {s}.orders FROM CURRENT_USER", "orders"),
}
PRV06_DENIED = {
    "alter_default_privileges_grant":
        "ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA {s} GRANT ALL ON TABLES TO PUBLIC",
    "alter_default_privileges_revoke": "ALTER DEFAULT PRIVILEGES FOR ROLE {owner} REVOKE ALL ON TABLES FROM PUBLIC",
    "grant_owner_role_to_self": "GRANT {owner} TO CURRENT_USER",
}


@tc(*PRV06)
@pytest.mark.parametrize("statement, table", [pytest.param(sq, t, id=k) for k, (sq, t) in ACL_STATEMENTS.items()])
def test_prv_06_grant_revoke_has_no_effect(app_conn, schema, statement, table):
    """Với bảng mà app_user đã có một phần quyền, PostgreSQL chỉ CẢNH BÁO thay vì báo lỗi,
    nên test kiểm tra kết quả cuối cùng: ACL của bảng không đổi."""
    acl_sql = "SELECT relacl::text FROM pg_class WHERE oid = to_regclass(%s)"
    with session(app_conn, TENANT_A, "app_user") as s:
        before = s.query(acl_sql, (f"{schema}.{table}",))[0][0]
        try:
            with s.conn.transaction():
                s.conn.execute(statement.format(s=schema))
            outcome = "chạy được nhưng PostgreSQL chỉ cảnh báo (không có hiệu lực)"
        except pgerr.InsufficientPrivilege as exc:
            outcome = f"bị từ chối (SQLSTATE {exc.sqlstate}): {_first_line(exc)}"
        log.info("[app_user/A] %s -> %s", _flat(statement.format(s=schema)), outcome)
        after = s.query(acl_sql, (f"{schema}.{table}",))[0][0]
    assert before == after, f"ACL của {table} bị đổi!\n  trước: {before}\n  sau  : {after}"


@tc(*PRV06)
@pytest.mark.parametrize("statement", denied(PRV06_DENIED))
def test_prv_06_default_privileges_and_role_grant_denied(app_conn, schema, settings, statement):
    assert_app_user_denied(app_conn, schema, settings, statement)


# ===========================================================================
# TC-PRV-07 – CREATE/ALTER/DROP ROLE (app_user và app_migrator)
# ===========================================================================
PRV07 = ("TC-PRV-07", "P0", "app_user (và app_migrator) không CREATE/ALTER/DROP ROLE",
         "permission denied (chỉ postgres)")
PRV07_SQL = {
    "create_role": "CREATE ROLE prv_probe_role",
    "alter_self_superuser": "ALTER ROLE CURRENT_USER SUPERUSER",
    "alter_self_bypassrls": "ALTER ROLE CURRENT_USER BYPASSRLS",
    "alter_self_createrole": "ALTER ROLE CURRENT_USER CREATEROLE",
    "alter_owner_login": "ALTER ROLE {owner} LOGIN",
    "drop_owner_role": "DROP ROLE {owner}",
}


@tc(*PRV07)
@pytest.mark.parametrize("role", ["app_user", "app_migrator"])
@pytest.mark.parametrize("statement", denied(PRV07_SQL))
def test_prv_07_role_ddl_denied(request, schema, settings, role, statement):
    with session(role_conn(role, request), None, role) as s:
        s.expect_denied(statement.format(owner=settings.owner_role))


# ===========================================================================
# TC-PRV-08 – app_migrator chạy DDL qua app_owner
# ===========================================================================
PRV08 = ("TC-PRV-08", "P0", "app_migrator chạy được DDL (CREATE TABLE, ALTER, INDEX, POLICY...) qua app_owner",
         "Thành công; đối tượng mới có owner = app_owner")


@tc(*PRV08)
def test_prv_08_migrator_ddl_via_owner(migrator_conn, schema, settings):
    owner = settings.owner_role
    t = f"{schema}.prv_probe"
    with session(migrator_conn, None, "app_migrator") as s:
        s.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(owner)).as_string(s.conn))
        s.execute(f"CREATE TABLE {t} (id int PRIMARY KEY, tenant_id uuid NOT NULL, note text)")
        s.execute(f"ALTER TABLE {t} ADD COLUMN extra int")
        s.execute(f"CREATE INDEX prv_probe_note_idx ON {t} (note)")
        s.execute(f"ALTER TABLE {t} ENABLE ROW LEVEL SECURITY")
        s.execute(f"ALTER TABLE {t} FORCE ROW LEVEL SECURITY")
        s.execute(f"CREATE POLICY prv_probe_pol ON {t} USING (tenant_id = "
                  f"nullif(current_setting('app.tenant_id', true), '')::uuid)")
        s.execute(f"CREATE VIEW {schema}.prv_probe_v AS SELECT id FROM {t}")
        s.execute(f"CREATE FUNCTION {schema}.prv_probe_f() RETURNS int LANGUAGE sql AS 'SELECT 1'")
        objects = s.query("SELECT c.relname, pg_get_userbyid(c.relowner) FROM pg_class c "
                          "WHERE c.relnamespace = %s::regnamespace AND c.relname LIKE 'prv_probe%%' "
                          "ORDER BY 1", (schema,))
        objects += s.query("SELECT p.proname, pg_get_userbyid(p.proowner) FROM pg_proc p "
                           "WHERE p.pronamespace = %s::regnamespace AND p.proname LIKE 'prv_probe%%'", (schema,))
    assert len(objects) >= 5, f"thiếu đối tượng vừa tạo (bảng, 2 index, view, hàm): {objects}"
    wrong = [o for o in objects if o[1] != owner]
    assert not wrong, f"đối tượng không thuộc {owner}: {wrong}"


# ===========================================================================
# TC-PRV-09 – app_migrator không CREATE DATABASE / ROLE
# ===========================================================================
PRV09 = ("TC-PRV-09", "P1", "app_migrator không CREATE DATABASE / CREATE ROLE", "permission denied")


@tc(*PRV09)
@pytest.mark.parametrize("statement, cleanup", [
    pytest.param("CREATE DATABASE tbl_prv_probe_db", "DROP DATABASE IF EXISTS tbl_prv_probe_db", id="create_database"),
    pytest.param("CREATE ROLE prv_probe_role", "DROP ROLE IF EXISTS prv_probe_role", id="create_role"),
])
def test_prv_09_migrator_database_role_denied(settings, statement, cleanup):
    with contextlib.closing(open_role("app_migrator", settings)) as conn:
        expect_error(conn, "app_migrator", statement, pgerr.InsufficientPrivilege, cleanup=cleanup)


# ===========================================================================
# TC-PRV-10 – app_user CRUD trong phạm vi tenant
# ===========================================================================
PRV10 = ("TC-PRV-10", "P0", "app_user chạy được INSERT/UPDATE/DELETE/SELECT trong phạm vi tenant",
         "Thành công trên dữ liệu của tenant")


@tc(*PRV10)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_10_crud_within_tenant(app_conn, schema, tenant_id):
    with session(app_conn, tenant_id, "app_user") as s:
        new_id = s.query(f"INSERT INTO {schema}.orders (tenant_id, code) VALUES (%s::uuid, 'PRV-NEW') "
                         "RETURNING id::text", (tenant_id,))[0][0]
        assert s.query(f"SELECT code FROM {schema}.orders WHERE id = %s::uuid", (new_id,)) == [("PRV-NEW",)]
        assert s.execute(f"UPDATE {schema}.orders SET code = 'PRV-UPD' WHERE id = %s::uuid", (new_id,)) == 1
        assert s.query(f"SELECT code FROM {schema}.orders WHERE id = %s::uuid", (new_id,)) == [("PRV-UPD",)]
        assert s.execute(f"DELETE FROM {schema}.orders WHERE id = %s::uuid", (new_id,)) == 1
        assert s.query(f"SELECT code FROM {schema}.orders WHERE id = %s::uuid", (new_id,)) == []


@tc(*PRV10)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_10_crud_cannot_reach_other_tenant(app_conn, schema, tenant_id):
    foreign = OWN_ORDER[OTHER_TENANT[tenant_id]]
    with session(app_conn, tenant_id, "app_user") as s:
        assert s.execute(f"UPDATE {schema}.orders SET code = 'hacked' WHERE id = %s::uuid", (foreign,)) == 0
        assert s.execute(f"DELETE FROM {schema}.orders WHERE id = %s::uuid", (foreign,)) == 0
        assert s.query(f"SELECT id::text FROM {schema}.orders WHERE id = %s::uuid", (foreign,)) == []


# ===========================================================================
# TC-PRV-11 – MERGE chỉ tác động dòng của tenant hiện tại (cần PostgreSQL 15+)
# ===========================================================================
PRV11 = ("TC-PRV-11", "P0", "MERGE chỉ tác động dòng của tenant hiện tại",
         "Dòng tenant khác không bị đọc/sửa/xóa/chèn")


def _require_merge(conn):
    if conn.info.server_version < 150000:
        pytest.skip(f"MERGE cần PostgreSQL 15+ (server_version={conn.info.server_version})")


def _switch_tenant(s: TenantSession, tenant_id: str):
    """Đổi app.tenant_id NGAY TRONG transaction để đọc lại dữ liệu của tenant kia (chưa commit)."""
    s.query("SELECT set_config('app.tenant_id', %s, true)", (tenant_id,))
    s.label = f"app_user/{TENANT_LABEL[tenant_id]}"


@tc(*PRV11)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_11_merge_update_cannot_touch_other_tenant(app_conn, schema, tenant_id):
    _require_merge(app_conn)
    other, foreign = OTHER_TENANT[tenant_id], OWN_ORDER[OTHER_TENANT[tenant_id]]
    with session(app_conn, tenant_id, "app_user") as s:
        before = s.query(f"SELECT code FROM {schema}.orders WHERE id = %s::uuid", (foreign,))
        assert before == [], "dòng tenant khác lẽ ra phải vô hình"
        n = s.execute(f"""MERGE INTO {schema}.orders t USING (VALUES (%s::uuid, 'PRV-MERGE')) AS src(id, code)
                          ON t.id = src.id
                          WHEN MATCHED THEN UPDATE SET code = src.code
                          WHEN NOT MATCHED THEN INSERT (tenant_id, code)
                               VALUES (nullif(current_setting('app.tenant_id', true), '')::uuid, src.code)""",
                      (foreign,))
        assert n == 1, f"MERGE phải chỉ INSERT 1 dòng cho tenant hiện tại (không khớp dòng tenant khác), thực tế {n}"
        mine = s.query(f"SELECT tenant_id::text FROM {schema}.orders WHERE code = 'PRV-MERGE'")
        assert mine == [(tenant_id,)], f"dòng MERGE chèn phải thuộc tenant hiện tại: {mine}"
        _switch_tenant(s, other)
        assert s.query(f"SELECT code FROM {schema}.orders WHERE id = %s::uuid", (foreign,)) != [("PRV-MERGE",)], \
            "dòng của tenant khác đã bị MERGE sửa!"
        assert s.query(f"SELECT 1 FROM {schema}.orders WHERE code = 'PRV-MERGE'") == [], \
            "tenant khác thấy dòng do MERGE của tenant này tạo"


@tc(*PRV11)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_11_merge_delete_cannot_touch_other_tenant(app_conn, schema, tenant_id):
    _require_merge(app_conn)
    other, foreign = OTHER_TENANT[tenant_id], OWN_ORDER[OTHER_TENANT[tenant_id]]
    delete_sql = (f"MERGE INTO {schema}.orders t USING (VALUES (%s::uuid)) AS src(id) ON t.id = src.id "
                  "WHEN MATCHED THEN DELETE")
    with session(app_conn, tenant_id, "app_user") as s:
        own_id = s.query(f"INSERT INTO {schema}.orders (tenant_id, code) VALUES (%s::uuid, 'PRV-MERGE-DEL') "
                         "RETURNING id::text", (tenant_id,))[0][0]
        assert s.execute(delete_sql, (own_id,)) == 1, "đối chứng: MERGE DELETE dòng của chính tenant phải thành công"
        assert s.execute(delete_sql, (foreign,)) == 0, "MERGE DELETE dòng tenant khác phải không xóa được gì"
        _switch_tenant(s, other)
        assert s.query(f"SELECT 1 FROM {schema}.orders WHERE id = %s::uuid", (foreign,)) == [(1,)], \
            "dòng của tenant khác đã bị MERGE xóa!"


@tc(*PRV11)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_11_merge_insert_other_tenant_rejected(app_conn, schema, tenant_id):
    _require_merge(app_conn)
    other = OTHER_TENANT[tenant_id]
    with session(app_conn, tenant_id, "app_user") as s:
        s.expect_denied(f"""MERGE INTO {schema}.orders t USING (VALUES ('PRV-X')) AS src(code) ON false
                            WHEN NOT MATCHED THEN INSERT (tenant_id, code) VALUES (%s::uuid, src.code)""", (other,))


# ===========================================================================
# TC-PRV-12 – COPY bị RLS áp dụng
# ===========================================================================
PRV12 = ("TC-PRV-12", "P0", "COPY FROM STDIN / COPY (SELECT) TO STDOUT bị RLS áp dụng",
         "Chỉ xuất dữ liệu của tenant hiện tại; nhập sai tenant bị chặn")
COPY_OUT = {
    "copy_select_to_stdout": "COPY (SELECT id::text, tenant_id::text, code FROM {s}.orders ORDER BY code) TO STDOUT",
    "copy_table_to_stdout": "COPY {s}.orders (id, tenant_id, code) TO STDOUT",
}


@tc(*PRV12)
@pytest.mark.parametrize("statement", denied(COPY_OUT))
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_12_copy_out_only_own_tenant(app_conn, schema, tenant_id, statement):
    statement = statement.format(s=schema)
    with session(app_conn, tenant_id, "app_user") as s:
        log.debug("[%s] SQL: %s", s.label, statement)
        with s.conn.cursor() as cur, cur.copy(statement) as copy:
            rows = list(copy.rows())
        log.info("[%s] %s -> %d dòng %s", s.label, _flat(statement), len(rows), rows[:5])
    foreign = [r for r in rows if r[1] != tenant_id]
    assert not foreign, f"COPY xuất dòng của tenant khác: {foreign}"
    assert {r[0] for r in rows} == OWN_ORDERS[tenant_id], f"COPY xuất thiếu/thừa dòng: {rows}"


@tc(*PRV12)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_12_copy_in_other_tenant_rejected(app_conn, schema, tenant_id):
    """PostgreSQL không cho COPY FROM vào bảng bật RLS (FeatureNotSupported); nếu cho thì WITH CHECK
    phải chặn (InsufficientPrivilege). Cả hai đều đạt; dòng sai tenant không được xuất hiện."""
    other = OTHER_TENANT[tenant_id]
    statement = f"COPY {schema}.orders (tenant_id, code) FROM STDIN"
    with session(app_conn, tenant_id, "app_user") as s:
        try:
            with s.conn.transaction(), s.conn.cursor() as cur, cur.copy(statement) as copy:
                copy.write_row((other, "PRV-COPY"))
        except (pgerr.FeatureNotSupported, pgerr.InsufficientPrivilege) as exc:
            log.info("[%s] %s -> LỖI %s (SQLSTATE %s): %s", s.label, statement,
                     type(exc).__name__, exc.sqlstate, _first_line(exc))
        else:
            raise AssertionError(f"COPY FROM ghi được dòng của tenant khác ({other}) khi đang là {tenant_id}")
        _switch_tenant(s, other)
        assert s.query(f"SELECT 1 FROM {schema}.orders WHERE code = 'PRV-COPY'") == [], \
            "dòng PRV-COPY đã lọt vào tenant khác"


# ===========================================================================
# TC-PRV-13 – SELECT FOR UPDATE/SHARE và CTE
# ===========================================================================
PRV13 = ("TC-PRV-13", "P0", "SELECT ... FOR UPDATE / FOR SHARE và WITH (CTE) chỉ thấy dòng tenant",
         "Không khóa/đọc dòng tenant khác")


@tc(*PRV13)
@pytest.mark.parametrize("tenant_id", TENANTS)
@pytest.mark.parametrize("lock", ["FOR UPDATE", "FOR SHARE"])
def test_prv_13_row_locks_only_own_rows(app_conn, schema, tenant_id, lock):
    with session(app_conn, tenant_id, "app_user") as s:
        rows = s.query(f"SELECT id::text FROM {schema}.orders {lock}")
    assert {r[0] for r in rows} == OWN_ORDERS[tenant_id], f"{lock} khóa/đọc dòng ngoài tenant: {rows}"


@tc(*PRV13)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_13_for_update_does_not_block_other_tenant(app_conn, settings, schema, tenant_id):
    """Tenant này giữ FOR UPDATE trên toàn bảng; tenant kia vẫn FOR UPDATE NOWAIT dòng của mình được ngay."""
    other = OTHER_TENANT[tenant_id]
    with session(app_conn, tenant_id, "app_user") as s1:
        s1.query(f"SELECT id::text FROM {schema}.orders FOR UPDATE")
        second = psycopg.connect(settings.app_dsn, application_name="tbl-isolation-tests")
        try:
            with session(second, other, "app_user#2") as s2:
                rows = s2.query(f"SELECT id::text FROM {schema}.orders FOR UPDATE NOWAIT")
        except pgerr.LockNotAvailable as exc:
            raise AssertionError(f"tenant {TENANT_LABEL[tenant_id]} đã khóa dòng của tenant {TENANT_LABEL[other]}: "
                                 f"{_first_line(exc)}") from exc
        finally:
            second.close()
    assert {r[0] for r in rows} == OWN_ORDERS[other]


@tc(*PRV13)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_13_cte_only_own_rows(app_conn, schema, tenant_id):
    other = OTHER_TENANT[tenant_id]
    with session(app_conn, tenant_id, "app_user") as s:
        rows = s.query(f"WITH o AS (SELECT id::text, tenant_id::text FROM {schema}.orders) SELECT * FROM o")
        assert {r[0] for r in rows} == OWN_ORDERS[tenant_id], f"CTE đọc ngoài tenant: {rows}"
        deleted = s.query(f"WITH d AS (DELETE FROM {schema}.orders WHERE tenant_id = %s::uuid RETURNING id) "
                          "SELECT count(*) FROM d", (other,))
        assert deleted == [(0,)], f"CTE DELETE xóa được dòng tenant khác: {deleted}"


# ===========================================================================
# TC-PRV-14 – EXPLAIN theo môi trường
# ===========================================================================
PRV14 = ("TC-PRV-14", "P1", "EXPLAIN [ANALYZE] bị chặn với app_user ở môi trường production",
         "Prod: bị từ chối; dev: được phép")


@tc(*PRV14)
def test_prv_14_explain_by_environment(app_conn, schema):
    env = os.environ.get("APP_ENV", "").strip().lower()
    if env not in ("dev", "prod"):
        pytest.skip("Đặt APP_ENV=dev hoặc APP_ENV=prod để chạy PRV-14")
    statements = [f"EXPLAIN SELECT id FROM {schema}.orders", f"EXPLAIN (ANALYZE) SELECT id FROM {schema}.orders"]
    log.info("Môi trường: %s", env)
    with session(app_conn, TENANT_A, "app_user") as s:
        for statement in statements:
            if env == "dev":
                assert s.query(statement), "EXPLAIN ở dev phải chạy được"
                continue
            try:
                s.expect_error(statement, None, psycopg.Error)
            except AssertionError as exc:
                raise AssertionError(
                    f"{exc}\n  Gợi ý: PostgreSQL KHÔNG có quyền riêng cho EXPLAIN (ai SELECT được là EXPLAIN được); "
                    "muốn chặn ở prod phải làm ở tầng proxy/pooler/ứng dụng.") from exc


# ===========================================================================
# TC-PRV-15 – Prepared transaction không dùng được
# ===========================================================================
PRV15 = ("TC-PRV-15", "P1", "PREPARE TRANSACTION / COMMIT PREPARED / ROLLBACK PREPARED không dùng được",
         "Lỗi vì max_prepared_transactions = 0")
PREPARED_ERRORS = (pgerr.ObjectNotInPrerequisiteState, pgerr.UndefinedObject)


@tc(*PRV15)
@pytest.mark.parametrize("role", ["app_user", "app_migrator", "app_owner", "postgres"])
def test_prv_15_prepared_transactions_unusable(settings, role):
    with contextlib.closing(open_role(role, settings)) as conn:
        value = conn.execute("SHOW max_prepared_transactions").fetchone()[0]
        log.info("[%s] SHOW max_prepared_transactions -> %s", role, value)
        assert value == "0", f"max_prepared_transactions phải là 0, thực tế {value}"
        conn.execute("BEGIN")
        try:
            expect_error(conn, role, "PREPARE TRANSACTION 'prv_probe'", PREPARED_ERRORS,
                         cleanup="ROLLBACK PREPARED 'prv_probe'")
        finally:
            conn.execute("ROLLBACK")
        expect_error(conn, role, "COMMIT PREPARED 'prv_probe'", PREPARED_ERRORS)
        expect_error(conn, role, "ROLLBACK PREPARED 'prv_probe'", PREPARED_ERRORS)
        left = conn.execute("SELECT count(*) FROM pg_prepared_xacts").fetchone()[0]
        assert left == 0, f"còn {left} prepared transaction treo"


# ===========================================================================
# TC-PRV-16 – Lệnh điều khiển transaction hoạt động ở cả 4 vai trò
# ===========================================================================
PRV16 = ("TC-PRV-16", "P2", "BEGIN/COMMIT/ROLLBACK, SAVEPOINT, SET TRANSACTION hoạt động ở cả 4 vai trò",
         "Thành công, chỉ tác động transaction của chính phiên")
TX_SEQUENCE = ["BEGIN", "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "SAVEPOINT prv_sp",
               "ROLLBACK TO SAVEPOINT prv_sp", "RELEASE SAVEPOINT prv_sp", "COMMIT", "BEGIN", "ROLLBACK"]


@tc(*PRV16)
@pytest.mark.parametrize("role", ["app_user", "app_migrator", "app_owner", "postgres"])
def test_prv_16_transaction_control_allowed(settings, role):
    with contextlib.closing(open_role(role, settings)) as conn:
        for statement in TX_SEQUENCE:
            conn.execute(statement)
            log.info("[%s] %s -> OK", role, statement)
        status = conn.info.transaction_status
        assert status == psycopg.pq.TransactionStatus.IDLE, f"phiên không về trạng thái rảnh: {status.name}"


# ===========================================================================
# TC-PRV-17 – Tenant được đặt bằng SET LOCAL (phần kiểm tra được ở mức DB)
# ===========================================================================
PRV17 = ("TC-PRV-17", "P0", "SET LOCAL app.tenant_id chỉ do app_user (service) thực hiện",
         "Đặt đúng tenant ở đầu mỗi transaction (mức DB: giá trị chỉ sống trong transaction, không sót)")


@tc(*PRV17)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_prv_17_tenant_context_does_not_survive_commit(app_conn, schema, tenant_id):
    """Chỉ kiểm tra cơ chế ở DB: set_config(..., true) mất hiệu lực sau COMMIT và khi thiếu thì trả 0 dòng.
    Phần 'middleware có đặt tenant ở đầu mỗi transaction không' phải kiểm tra ở mức mã ứng dụng."""
    with session(app_conn, tenant_id, "app_user") as s:
        assert s.query(f"SELECT count(*) FROM {schema}.orders")[0][0] > 0
        s.conn.commit()
        log.info("[%s] COMMIT", s.label)
        leftover = s.query("SELECT current_setting('app.tenant_id', true)")[0][0]
        rows = s.query(f"SELECT count(*) FROM {schema}.orders")
    assert leftover in (None, ""), f"app.tenant_id còn sót sau COMMIT: {leftover!r}"
    assert rows == [(0,)], f"transaction kế tiếp không đặt tenant mà vẫn thấy dữ liệu: {rows}"


# ===========================================================================
# TC-PRV-18 – COMMENT
# ===========================================================================
PRV18 = ("TC-PRV-18", "P3", "COMMENT chỉ do app_migrator/postgres", "COMMENT ON bằng app_user bị permission denied")


@tc(*PRV18)
def test_prv_18_comment_denied_for_app_user(app_conn, schema):
    with session(app_conn, TENANT_A, "app_user") as s:
        s.expect_denied(f"COMMENT ON TABLE {schema}.orders IS 'prv probe'")


@tc(*PRV18)
def test_prv_18_comment_allowed_for_migrator_via_owner(migrator_conn, schema, settings):
    with session(migrator_conn, None, "app_migrator") as s:
        s.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(settings.owner_role)).as_string(s.conn))
        s.execute(f"COMMENT ON TABLE {schema}.orders IS 'prv probe'")
        got = s.query("SELECT obj_description(to_regclass(%s), 'pg_class')", (f"{schema}.orders",))
    assert got == [("prv probe",)], f"COMMENT không được ghi: {got}"