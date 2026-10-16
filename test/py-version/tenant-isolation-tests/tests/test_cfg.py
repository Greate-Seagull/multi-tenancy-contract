"""Nhóm CFG – Quyền và cấu hình bắt buộc của role (tài liệu mục 3.6.3).

FILE MỚI: không sửa file nhóm khác. Chạy riêng: pytest tests/test_cfg.py   hoặc   pytest -m cfg

KHÔNG thực hiện TC-CFG-13 (pg_hba giới hạn IP/phương thức): cần thử kết nối từ MẠNG ỨNG DỤNG, Python chạy ở
một điểm nên không làm được; bộ test cũng bắt buộc chạy từ mạng quản trị/CI (ADMIN/migrator phải kết nối được).

Phần lớn test chỉ ĐỌC catalog hoặc thử câu lệnh trong transaction rồi ROLLBACK, nên chạy được trên DB thật.

Schema ứng dụng cần kiểm tra (CFG-04, 05, 08, 09, 10, 12):
  APP_SCHEMAS   danh sách schema, ngăn cách bằng dấu phẩy. Không đặt -> tự dò mọi schema người dùng
                (trừ pg_*, information_schema và schema mẫu của bộ test). Không có gì để kiểm tra -> SKIP.
  TENANT_COLUMN tên cột tenant (mặc định tenant_id), dùng cho CFG-05 và CFG-10.
Role: app_owner = OWNER_ROLE; app_user = user của APP_USER_DSN; app_migrator = MIG_USER / user của
APP_MIGRATOR_DSN / "app_migrator". Cần APP_MIGRATOR_DSN (hoặc MIG_USER + MIG_PASSWORD) cho CFG-02 (phần COPY) và CFG-12.
"""
from __future__ import annotations

import contextlib
import logging
import os

import psycopg
import pytest
from psycopg import errors as pgerr
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

from helpers import TENANT_A, TenantSession, tc

pytestmark = pytest.mark.cfg
log = logging.getLogger("cfg")

EXT_REL = ("NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass "
           "AND d.objid = c.oid AND d.deptype = 'e')")
EXT_PROC = ("NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass "
            "AND d.objid = p.oid AND d.deptype = 'e')")
TENANT_COLUMN = os.environ.get("TENANT_COLUMN", "tenant_id")


# ---------------------------------------------------------------------------
# Fixture & công cụ riêng của nhóm CFG
# ---------------------------------------------------------------------------
def _migrator_dsn(settings) -> str | None:
    return getattr(settings, "migrator_dsn", None) or os.environ.get("APP_MIGRATOR_DSN")


@pytest.fixture(scope="module")
def cfg_conn(settings):
    """Kết nối app_user (autocommit). Câu lệnh thử luôn đi qua txn() để ROLLBACK."""
    conn = psycopg.connect(settings.app_dsn, autocommit=True, application_name="tbl-isolation-tests")
    log.info("CFG kết nối app_user: host=%s db=%s user=%s server_version=%s",
             conn.info.host, conn.info.dbname, conn.info.user, conn.info.server_version)
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def cfg_migrator_conn(settings):
    dsn = _migrator_dsn(settings)
    if not dsn:
        pytest.skip("Thiếu APP_MIGRATOR_DSN (hoặc MIG_USER + MIG_PASSWORD) – bỏ qua test cần app_migrator")
    conn = psycopg.connect(dsn, autocommit=True, application_name="tbl-isolation-tests")
    log.info("CFG kết nối app_migrator: user=%s", conn.info.user)
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def admin_pid(settings):
    """PID của một phiên ADMIN đang rảnh – làm đích cho thử pg_cancel_backend."""
    conn = psycopg.connect(settings.admin_dsn, autocommit=True, application_name="tbl-isolation-tests")
    yield conn.execute("SELECT pg_backend_pid()").fetchone()[0]
    conn.close()


@pytest.fixture(scope="module")
def role_names(settings, cfg_conn) -> dict:
    dsn = _migrator_dsn(settings)
    migrator = (os.environ.get("MIG_USER")
                or (conninfo_to_dict(dsn).get("user") if dsn else None) or "app_migrator")
    names = {"app_owner": settings.owner_role, "app_migrator": migrator,
             "app_user": cfg_conn.execute("SELECT current_user").fetchone()[0]}
    log.info("Tên role được kiểm tra: %s", names)
    return names


@pytest.fixture(scope="module")
def app_schemas(cfg_conn, settings) -> list[str]:
    configured = [s.strip() for s in os.environ.get("APP_SCHEMAS", "").split(",") if s.strip()]
    if configured:
        names, source = configured, "APP_SCHEMAS"
    else:
        rows = cfg_conn.execute("SELECT nspname FROM pg_namespace WHERE nspname !~ '^pg_' "
                                "AND nspname <> 'information_schema' ORDER BY 1").fetchall()
        names = [r[0] for r in rows if r[0] != settings.schema]
        source = "tự dò (mọi schema người dùng, trừ schema mẫu của bộ test)"
    log.info("Schema ứng dụng được kiểm tra [%s]: %s", source, names)
    return names


def need(rows, what: str):
    if not rows:
        pytest.skip(f"Không có {what} trong schema ứng dụng – đặt APP_SCHEMAS=... nếu tự dò chưa đúng")


@contextlib.contextmanager
def txn(conn):
    """BEGIN ... ROLLBACK trên kết nối autocommit: mọi câu lệnh thử đều bị hoàn tác."""
    conn.execute("BEGIN")
    try:
        yield
    finally:
        conn.execute("ROLLBACK")


def attempt_denied(conn, label: str, statement: str):
    """Chạy trong transaction rồi ROLLBACK; PHẢI bị từ chối quyền (SQLSTATE 42501)."""
    log.debug("[%s] SQL: %s", label, statement)
    with txn(conn):
        try:
            conn.execute(statement)
        except psycopg.Error as exc:
            first = str(exc).strip().splitlines()[0]
            log.info("[%s] %s -> LỖI %s (SQLSTATE %s): %s", label, " ".join(statement.split())[:160],
                     type(exc).__name__, exc.sqlstate, first)
            if not isinstance(exc, pgerr.InsufficientPrivilege):
                raise AssertionError(f"[{label}] mong đợi permission denied nhưng nhận {type(exc).__name__} "
                                     f"(SQLSTATE {exc.sqlstate}): {first}\n  SQL: {statement}") from exc
            return
        log.info("[%s] %s -> CHẠY THÀNH CÔNG", label, " ".join(statement.split())[:160])
        raise AssertionError(f"[{label}] mong đợi permission denied nhưng câu lệnh CHẠY THÀNH CÔNG (đã ROLLBACK)\n"
                             f"  SQL: {statement}")


def not_member_of(conn, label: str, user: str, groups: list[str]):
    offenders = []
    for group in groups:
        if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (group,)).fetchone():
            log.info("[%s] role %s không có ở phiên bản PostgreSQL này – bỏ qua", label, group)
            continue
        member = conn.execute("SELECT pg_has_role(%s::name, %s::name, 'member')", (user, group)).fetchone()[0]
        log.info("[%s] pg_has_role(%s, %s, 'member') -> %s", label, user, group, member)
        if member:
            offenders.append(group)
    assert not offenders, f"{user} là thành viên (trực tiếp hoặc gián tiếp) của: {offenders}"


ROLE_PARAMS = [pytest.param("app_user", id="app_user"), pytest.param("app_migrator", id="app_migrator")]


# ===========================================================================
# TC-CFG-01 – pg_read_all_data / pg_write_all_data
# ===========================================================================
CFG01 = ("TC-CFG-01", "P0", "app_user không có pg_read_all_data / pg_write_all_data", "Không có")


@tc(*CFG01)
def test_cfg_01_no_read_write_all_data(cfg_conn, role_names):
    not_member_of(cfg_conn, "app_user", role_names["app_user"], ["pg_read_all_data", "pg_write_all_data"])


# ===========================================================================
# TC-CFG-02 – pg_*_server_files / pg_execute_server_program / COPY TO PROGRAM
# ===========================================================================
CFG02 = ("TC-CFG-02", "P0", "app_user và app_migrator không có pg_read/write_server_files, pg_execute_server_program",
         "Không có; COPY ... TO PROGRAM bị từ chối")


@tc(*CFG02)
@pytest.mark.parametrize("role", ROLE_PARAMS)
def test_cfg_02_no_server_file_roles(cfg_conn, role_names, role):
    not_member_of(cfg_conn, role, role_names[role],
                  ["pg_read_server_files", "pg_write_server_files", "pg_execute_server_program"])


@tc(*CFG02)
@pytest.mark.parametrize("role", ROLE_PARAMS)
def test_cfg_02_copy_to_program_denied(request, role):
    conn = request.getfixturevalue({"app_user": "cfg_conn", "app_migrator": "cfg_migrator_conn"}[role])
    # Lệnh 'true' vô hại: nếu quyền cấu hình sai và lệnh chạy được thì test FAIL (đã ROLLBACK)
    attempt_denied(conn, role, "COPY (SELECT 1) TO PROGRAM 'true'")


# ===========================================================================
# TC-CFG-03 – pg_monitor, pg_read_all_stats, pg_signal_backend, pg_checkpoint, pg_maintain
# ===========================================================================
CFG03 = ("TC-CFG-03", "P0", "app_user không có pg_monitor, pg_read_all_stats, pg_signal_backend, pg_checkpoint, pg_maintain",
         "Không có; bị từ chối khi thử hủy phiên của role khác")


@tc(*CFG03)
def test_cfg_03_no_monitoring_or_signal_roles(cfg_conn, role_names):
    not_member_of(cfg_conn, "app_user", role_names["app_user"],
                  ["pg_monitor", "pg_read_all_stats", "pg_signal_backend", "pg_checkpoint", "pg_maintain"])


@tc(*CFG03)
def test_cfg_03_cancel_other_session_denied(cfg_conn, admin_pid):
    # Dùng pg_cancel_backend (nhẹ hơn terminate): nếu cấu hình sai và chạy được thì phiên ADMIN rảnh không bị hại
    attempt_denied(cfg_conn, "app_user", f"SELECT pg_cancel_backend({int(admin_pid)})")


@tc(*CFG03)
def test_cfg_03_checkpoint_denied(cfg_conn):
    attempt_denied(cfg_conn, "app_user", "CHECKPOINT")


# ===========================================================================
# TC-CFG-04 – app_owner sở hữu mọi bảng, view, function, sequence
# ===========================================================================
CFG04 = ("TC-CFG-04", "P0", "app_owner sở hữu mọi bảng, view, function, sequence",
         "Mọi đối tượng schema ứng dụng có owner = app_owner")


@tc(*CFG04)
def test_cfg_04_all_objects_owned_by_owner(cfg_conn, role_names, app_schemas):
    owner = role_names["app_owner"]
    rows = cfg_conn.execute(
        f"SELECT 'relkind=' || c.relkind::text, n.nspname::text, c.relname::text, pg_get_userbyid(c.relowner) "
        f"FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        f"WHERE n.nspname::text = ANY(%s::text[]) AND c.relkind IN ('r','p','v','m','S','f') AND {EXT_REL} "
        f"UNION ALL "
        f"SELECT 'function', n.nspname::text, p.proname::text, pg_get_userbyid(p.proowner) "
        f"FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        f"WHERE n.nspname::text = ANY(%s::text[]) AND {EXT_PROC} ORDER BY 2, 3",
        (app_schemas, app_schemas)).fetchall()
    need(rows, "đối tượng nào (bảng/view/sequence/hàm)")
    wrong = [r for r in rows if r[3] != owner]
    for kind, schema, name, obj_owner in rows:
        log.info("%s.%s (%s) owner=%s %s", schema, name, kind, obj_owner, "" if obj_owner == owner else "<-- SAI")
    assert not wrong, f"{len(wrong)}/{len(rows)} đối tượng không thuộc {owner}: {wrong}"


# ===========================================================================
# TC-CFG-05 – ENABLE + FORCE ROW LEVEL SECURITY
# ===========================================================================
CFG05 = ("TC-CFG-05", "P0", "Mọi bảng nghiệp vụ bật ENABLE + FORCE ROW LEVEL SECURITY", "relrowsecurity và relforcerowsecurity đều = true")


@tc(*CFG05)
def test_cfg_05_rls_enabled_and_forced(cfg_conn, app_schemas):
    """'Bảng nghiệp vụ' = bảng có cột tenant (TENANT_COLUMN). Ngoài ra bảng nào đã ENABLE RLS thì cũng phải FORCE.
    Bảng không có cột tenant và không RLS (bảng chung/kỹ thuật) chỉ được ghi log để rà soát thủ công."""
    rows = cfg_conn.execute(
        "SELECT n.nspname::text, c.relname::text, c.relrowsecurity, c.relforcerowsecurity, "
        "EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = %s "
        "AND a.attnum > 0 AND NOT a.attisdropped) "
        f"FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        f"WHERE n.nspname::text = ANY(%s::text[]) AND c.relkind IN ('r','p') AND {EXT_REL} ORDER BY 1, 2",
        (TENANT_COLUMN, app_schemas)).fetchall()
    need(rows, "bảng nào")
    problems = []
    for schema, table, enabled, forced, has_tenant in rows:
        if has_tenant and not (enabled and forced):
            problems.append((schema, table, f"có cột {TENANT_COLUMN} nhưng enable={enabled} force={forced}"))
        elif enabled and not forced:
            problems.append((schema, table, "đã ENABLE nhưng chưa FORCE RLS"))
        elif not has_tenant and not enabled:
            log.info("%s.%s: không có cột %s, không RLS -> bảng chung/kỹ thuật, cần rà soát thủ công",
                     schema, table, TENANT_COLUMN)
        else:
            log.info("%s.%s: enable=%s force=%s tenant_col=%s -> OK", schema, table, enabled, forced, has_tenant)
    assert not problems, f"{len(problems)} bảng sai cấu hình RLS (schema, bảng, lý do): {problems}"


# ===========================================================================
# TC-CFG-06 / 07 – Quyền PUBLIC trên database và TEMP
# ===========================================================================
CFG06 = ("TC-CFG-06", "P0", "PUBLIC bị thu quyền trên database; chỉ GRANT CONNECT cho role cần",
         "PUBLIC không có CONNECT/TEMP/CREATE")
CFG07 = ("TC-CFG-07", "P1", "Thu TEMP trên database từ PUBLIC", "CREATE TEMP TABLE bằng app_user bị permission denied")


@tc(*CFG06)
def test_cfg_06_public_has_no_database_privileges(cfg_conn, role_names):
    rows = cfg_conn.execute(
        "SELECT a.privilege_type FROM pg_database d CROSS JOIN LATERAL "
        "aclexplode(COALESCE(d.datacl, acldefault('d', d.datdba))) a "
        "WHERE d.datname = current_database() AND a.grantee = 0 ORDER BY 1").fetchall()
    public = [r[0] for r in rows]
    log.info("Quyền của PUBLIC trên database hiện tại: %s", public or "không có")
    assert not public, f"PUBLIC còn quyền trên database: {public} (cần REVOKE ALL ON DATABASE ... FROM PUBLIC)"
    for role in ("app_user", "app_migrator"):
        can = cfg_conn.execute("SELECT has_database_privilege(%s::name, current_database(), 'CONNECT')",
                               (role_names[role],)).fetchone()[0]
        log.info("[%s] CONNECT trên database -> %s", role, can)
        assert can, f"{role_names[role]} không có CONNECT (đã thu quá tay hoặc chưa GRANT)"


@tc(*CFG07)
def test_cfg_07_app_user_has_no_temp_privilege(cfg_conn, role_names):
    can = cfg_conn.execute("SELECT has_database_privilege(%s::name, current_database(), 'TEMPORARY')",
                           (role_names["app_user"],)).fetchone()[0]
    log.info("[app_user] TEMPORARY trên database -> %s", can)
    assert can is False, f"{role_names['app_user']} vẫn có quyền TEMP trên database"


@tc(*CFG07)
def test_cfg_07_create_temp_table_denied(cfg_conn):
    attempt_denied(cfg_conn, "app_user", "CREATE TEMP TABLE cfg_probe (id int)")


# ===========================================================================
# TC-CFG-08 – Không có CREATE trên schema
# ===========================================================================
CFG08 = ("TC-CFG-08", "P0", "Thu CREATE trên schema public; app_user chỉ có USAGE trên schema service",
         "CREATE TABLE/FUNCTION trong schema bằng app_user bị permission denied")


@tc(*CFG08)
def test_cfg_08_app_user_no_create_on_schemas(cfg_conn, role_names, app_schemas):
    schemas = list(dict.fromkeys(["public", *app_schemas]))
    rows = cfg_conn.execute(
        "SELECT n.nspname::text, has_schema_privilege(%s::name, n.oid, 'USAGE'), "
        "has_schema_privilege(%s::name, n.oid, 'CREATE') FROM pg_namespace n "
        "WHERE n.nspname::text = ANY(%s::text[]) ORDER BY 1",
        (role_names["app_user"], role_names["app_user"], schemas)).fetchall()
    need(rows, "schema nào")
    for name, usage, create in rows:
        log.info("[app_user] schema %s: USAGE=%s CREATE=%s", name, usage, create)
    with_create = [r[0] for r in rows if r[2]]
    assert not with_create, f"app_user có quyền CREATE trên schema: {with_create}"


@tc(*CFG08)
@pytest.mark.parametrize("statement", [
    pytest.param("CREATE TABLE public.cfg_probe (id int)", id="create_table_public"),
    pytest.param("CREATE FUNCTION public.cfg_probe_f() RETURNS int LANGUAGE sql AS 'SELECT 1'", id="create_function_public"),
])
def test_cfg_08_create_in_public_denied(cfg_conn, statement):
    if not cfg_conn.execute("SELECT 1 FROM pg_namespace WHERE nspname = 'public'").fetchone():
        pytest.skip("Không có schema public")
    attempt_denied(cfg_conn, "app_user", statement)


# ===========================================================================
# TC-CFG-09 – app_user chỉ có SELECT/INSERT/UPDATE/DELETE (và USAGE sequence)
# ===========================================================================
CFG09 = ("TC-CFG-09", "P0", "app_user chỉ có SELECT, INSERT, UPDATE, DELETE (và USAGE sequence)",
         "Không có TRUNCATE, REFERENCES, TRIGGER, WITH GRANT OPTION")


@tc(*CFG09)
def test_cfg_09_only_dml_privileges(cfg_conn, role_names, app_schemas):
    rows = cfg_conn.execute(
        "SELECT n.nspname::text, c.relname::text, c.relkind::text, a.privilege_type, a.is_grantable "
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, "
        "acldefault(CASE WHEN c.relkind = 'S' THEN 's'::\"char\" ELSE 'r'::\"char\" END, c.relowner))) a "
        "WHERE n.nspname::text = ANY(%s::text[]) AND c.relkind IN ('r','p','v','m','f','S') "
        "AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = %s) ORDER BY 1, 2, 4",
        (app_schemas, role_names["app_user"])).fetchall()
    need(rows, "quyền nào cấp cho app_user")
    bad = []
    for schema, name, kind, privilege, grantable in rows:
        allowed = {"USAGE", "SELECT"} if kind == "S" else {"SELECT", "INSERT", "UPDATE", "DELETE"}
        ok = privilege in allowed and not grantable
        log.info("%s.%s (relkind=%s): %s%s -> %s", schema, name, kind, privilege,
                 " WITH GRANT OPTION" if grantable else "", "OK" if ok else "SAI")
        if not ok:
            bad.append((schema, name, privilege + (" WITH GRANT OPTION" if grantable else "")))
    assert not bad, f"{len(bad)} quyền vượt phạm vi cho phép (schema, đối tượng, quyền): {bad}"


# ===========================================================================
# TC-CFG-10 – UPDATE theo cột không gồm tenant_id
# ===========================================================================
CFG10 = ("TC-CFG-10", "P0", "Column-level UPDATE không gồm tenant_id", "app_user không có quyền UPDATE cột tenant_id")


@tc(*CFG10)
def test_cfg_10_no_update_on_tenant_column(cfg_conn, role_names, app_schemas):
    """Kiểm tra bằng catalog (has_column_privilege), KHÔNG chạy UPDATE thật để không đụng dữ liệu."""
    rows = cfg_conn.execute(
        "SELECT n.nspname::text, c.relname::text, has_column_privilege(%s::name, c.oid, %s::text, 'UPDATE') "
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = %s AND a.attnum > 0 AND NOT a.attisdropped "
        f"WHERE n.nspname::text = ANY(%s::text[]) AND c.relkind IN ('r','p') AND {EXT_REL} ORDER BY 1, 2",
        (role_names["app_user"], TENANT_COLUMN, TENANT_COLUMN, app_schemas)).fetchall()
    need(rows, f"bảng nào có cột {TENANT_COLUMN}")
    for schema, table, can in rows:
        log.info("[app_user] UPDATE(%s) trên %s.%s -> %s", TENANT_COLUMN, schema, table, can)
    bad = [(s, t) for s, t, can in rows if can]
    assert not bad, f"app_user có quyền UPDATE cột {TENANT_COLUMN} trên: {bad}"


# ===========================================================================
# TC-CFG-11 – row_security = on cho app_user
# ===========================================================================
CFG11 = ("TC-CFG-11", "P1", "ALTER ROLE app_user SET row_security = on",
         "on; nếu RLS không áp dụng được thì lỗi thay vì lộ dữ liệu")


@tc(*CFG11)
def test_cfg_11_row_security_is_on(cfg_conn):
    value = cfg_conn.execute("SHOW row_security").fetchone()[0]
    log.info("[app_user] SHOW row_security -> %s", value)
    assert value == "on", f"row_security = {value} (phải là on)"


@tc(*CFG11)
def test_cfg_11_role_setting_present(cfg_conn, role_names):
    rows = cfg_conn.execute(
        "SELECT s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole "
        "WHERE r.rolname = %s AND s.setdatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()))",
        (role_names["app_user"],)).fetchall()
    settings_list = [item for r in rows for item in r[0]]
    log.info("[app_user] ALTER ROLE ... SET đang có: %s", settings_list or "không có")
    assert "row_security=off" not in settings_list, "role đang bị đặt row_security=off"
    assert "row_security=on" in settings_list, "chưa có ALTER ROLE ... SET row_security = on cho app_user"


@tc(*CFG11)
def test_cfg_11_row_security_off_errors_instead_of_leaking(app_conn, schema):
    with TenantSession(app_conn, TENANT_A) as s:
        s.execute("SET LOCAL row_security = off")
        s.expect_denied(f"SELECT count(*) FROM {schema}.orders")


# ===========================================================================
# TC-CFG-12 – ALTER DEFAULT PRIVILEGES FOR ROLE app_owner cấp đúng quyền hẹp
# ===========================================================================
CFG12 = ("TC-CFG-12", "P0", "ALTER DEFAULT PRIVILEGES FOR ROLE app_owner cấp đúng quyền hẹp",
         "app_user chỉ có SELECT/INSERT/UPDATE/DELETE; PUBLIC không có")


@tc(*CFG12)
def test_cfg_12_new_table_gets_narrow_default_privileges(cfg_migrator_conn, role_names, app_schemas):
    owner, app_user, conn = role_names["app_owner"], role_names["app_user"], cfg_migrator_conn
    candidates = conn.execute("SELECT nspname::text FROM pg_namespace WHERE nspname::text = ANY(%s::text[]) "
                              "AND has_schema_privilege(%s::name, oid, 'CREATE') ORDER BY 1",
                              (app_schemas, owner)).fetchall()
    need(candidates, f"schema nào mà {owner} có quyền CREATE")
    schema = candidates[0][0]
    qualified = f"{sql.Identifier(schema).as_string(conn)}.cfg_probe"
    log.info("[app_migrator] tạo bảng thử %s qua SET ROLE %s (sẽ ROLLBACK)", qualified, owner)
    with txn(conn):
        conn.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(owner)))
        conn.execute(f"CREATE TABLE {qualified} (id int)")
        acl = conn.execute(
            "SELECT CASE a.grantee WHEN 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, "
            "a.privilege_type, a.is_grantable FROM pg_class c CROSS JOIN LATERAL "
            "aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a WHERE c.oid = to_regclass(%s)",
            (qualified,)).fetchall()
    for grantee, privilege, grantable in acl:
        log.info("ACL bảng mới: %s có %s%s", grantee, privilege, " WITH GRANT OPTION" if grantable else "")
    public = [p for g, p, _ in acl if g == "PUBLIC"]
    mine = {p for g, p, _ in acl if g == app_user}
    grantable = [(g, p) for g, p, gr in acl if gr and g != owner]
    assert not public, f"PUBLIC có quyền trên bảng mới: {public}"
    assert mine, f"{app_user} không có quyền nào trên bảng mới (thiếu ALTER DEFAULT PRIVILEGES FOR ROLE {owner})"
    assert mine <= {"SELECT", "INSERT", "UPDATE", "DELETE"}, \
        f"{app_user} có quyền vượt phạm vi trên bảng mới: {sorted(mine - {'SELECT', 'INSERT', 'UPDATE', 'DELETE'})}"
    assert not grantable, f"có quyền kèm WITH GRANT OPTION trên bảng mới: {grantable}"
