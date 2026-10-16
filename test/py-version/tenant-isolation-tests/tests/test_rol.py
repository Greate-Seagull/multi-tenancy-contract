"""Nhóm ROL – Thuộc tính và vai trò (tài liệu mục 3.2 – 3.4, 3.6.1, 3.6.2).

FILE MỚI: không sửa file nhóm khác. Đã loại theo yêu cầu: ROL-01, ROL-06, ROL-07, ROL-09.
Chạy riêng nhóm:  pytest tests/test_rol.py   hoặc   pytest -m rol
(Không dùng `pytest -k rol`: từ khóa "rol" trùng cả tên test chứa chữ "control".)

Đặc điểm: phần lớn test CHỈ ĐỌC catalog (pg_roles, pg_auth_members...), không tạo gì trong DB,
nên có thể chạy trên DB thật của môi trường cần kiểm tra. Riêng ROL-12 tạo đối tượng thử
trong schema mẫu rồi ROLLBACK.

Tên role được lấy như sau (không cần cấu hình thêm):
  app_owner    = OWNER_ROLE (mặc định app_owner)
  app_user     = user đang dùng trong APP_USER_DSN
  app_migrator = MIG_USER, nếu không có thì user trong APP_MIGRATOR_DSN, nếu không có thì "app_migrator"
Cần quyền đọc đặc biệt (dùng ADMIN_DSN, thiếu quyền -> SKIP có ghi lý do):
  ROL-08 đọc pg_authid và pg_hba_file_rules.
ROL-12 cần APP_MIGRATOR_DSN (hoặc MIG_USER + MIG_PASSWORD), thiếu -> SKIP.
"""
from __future__ import annotations

import logging
import os

import psycopg
import pytest
from psycopg import errors as pgerr
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from psycopg.rows import dict_row

from helpers import tc

pytestmark = pytest.mark.rol
log = logging.getLogger("rol")

ROLES = [pytest.param(r, id=r) for r in ("app_owner", "app_migrator", "app_user")]
WEAK_HBA_METHODS = ("trust", "md5", "password")


# ---------------------------------------------------------------------------
# Fixture riêng của nhóm ROL
# ---------------------------------------------------------------------------
def _migrator_dsn(settings) -> str | None:
    """Tương thích cả bản conftest cũ (chỉ APP_MIGRATOR_DSN) lẫn bản đã thêm settings.migrator_dsn."""
    return getattr(settings, "migrator_dsn", None) or os.environ.get("APP_MIGRATOR_DSN")


@pytest.fixture(scope="module")
def rol_conn(settings):
    """Kết nối app_user (autocommit) chỉ để đọc catalog; KHÔNG dựng schema mẫu."""
    conn = psycopg.connect(settings.app_dsn, autocommit=True, application_name="tbl-isolation-tests")
    log.info("ROL kết nối app_user: host=%s db=%s user=%s server_version=%s",
             conn.info.host, conn.info.dbname, conn.info.user, conn.info.server_version)
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def admin_rol_conn(settings):
    """Kết nối ADMIN (autocommit) cho các kiểm tra cần đọc pg_authid / pg_hba_file_rules."""
    conn = psycopg.connect(settings.admin_dsn, autocommit=True, application_name="tbl-isolation-tests")
    log.info("ROL kết nối ADMIN: user=%s", conn.info.user)
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def role_names(settings, rol_conn) -> dict:
    dsn = _migrator_dsn(settings)
    migrator = (os.environ.get("MIG_USER")
                or (conninfo_to_dict(dsn).get("user") if dsn else None)
                or "app_migrator")
    names = {
        "app_owner": settings.owner_role,
        "app_migrator": migrator,
        "app_user": rol_conn.execute("SELECT current_user").fetchone()[0],
    }
    log.info("Tên role được kiểm tra: %s", names)
    return names


@pytest.fixture(scope="module")
def rol_migrator_conn(schema, settings):
    """Kết nối app_migrator (không autocommit) cho ROL-12; cần schema mẫu. Thiếu DSN -> skip."""
    dsn = _migrator_dsn(settings)
    if not dsn:
        pytest.skip("Thiếu APP_MIGRATOR_DSN (hoặc MIG_USER + MIG_PASSWORD) – bỏ qua test cần app_migrator")
    conn = psycopg.connect(dsn, application_name="tbl-isolation-tests")
    log.info("ROL kết nối app_migrator: user=%s", conn.info.user)
    yield conn
    conn.close()


def fetch_role(conn, label: str, name: str) -> dict:
    cur = conn.cursor(row_factory=dict_row)
    cur.execute("SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, "
                "rolreplication, rolbypassrls FROM pg_roles WHERE rolname = %s", (name,))
    row = cur.fetchone()
    log.info("[%s] pg_roles %r -> %s", label, name, row)
    assert row is not None, f"role {name!r} ({label}) không tồn tại trong cluster"
    return row


# ===========================================================================
# TC-ROL-02 – app_owner là NOLOGIN
# ===========================================================================
ROL02 = ("TC-ROL-02", "P0", "app_owner là NOLOGIN", "Không đăng nhập được; rolcanlogin = false")


@tc(*ROL02)
def test_rol_02_owner_rolcanlogin_false(rol_conn, role_names):
    row = fetch_role(rol_conn, "app_owner", role_names["app_owner"])
    assert row["rolcanlogin"] is False, f"{row['rolname']} đang có LOGIN (rolcanlogin = true)"


@tc(*ROL02)
def test_rol_02_owner_cannot_login(settings, role_names):
    """Thử đăng nhập bằng app_owner với mật khẩu giả: phải thất bại (không được vào bằng bất kỳ cách nào)."""
    owner = role_names["app_owner"]
    dsn = make_conninfo(settings.admin_dsn, user=owner, password="mat-khau-gia-de-thu")
    try:
        conn = psycopg.connect(dsn, connect_timeout=5)
    except psycopg.OperationalError as exc:
        first = str(exc).strip().splitlines()[0]
        log.info("[app_owner] đăng nhập -> bị từ chối: %s", first)
        return
    conn.close()
    raise AssertionError(f"đăng nhập được bằng {owner} (NOLOGIN role phải không đăng nhập được)")


# ===========================================================================
# TC-ROL-03 / 04 / 05 – Thuộc tính NOSUPERUSER, NOBYPASSRLS, NOCREATEDB/ROLE/REPLICATION
# ===========================================================================
ROL03 = ("TC-ROL-03", "P0", "app_owner / app_migrator / app_user là NOSUPERUSER", "rolsuper = false cho cả 3")
ROL04 = ("TC-ROL-04", "P0", "app_owner / app_migrator / app_user là NOBYPASSRLS", "rolbypassrls = false cho cả 3")
ROL05 = ("TC-ROL-05", "P0", "NOCREATEDB, NOCREATEROLE, NOREPLICATION cho 3 role ứng dụng", "false cho cả 3")


@tc(*ROL03)
@pytest.mark.parametrize("role", ROLES)
def test_rol_03_nosuperuser(rol_conn, role_names, role):
    row = fetch_role(rol_conn, role, role_names[role])
    assert row["rolsuper"] is False, f"{row['rolname']} là SUPERUSER"


@tc(*ROL04)
@pytest.mark.parametrize("role", ROLES)
def test_rol_04_nobypassrls(rol_conn, role_names, role):
    row = fetch_role(rol_conn, role, role_names[role])
    assert row["rolbypassrls"] is False, f"{row['rolname']} có BYPASSRLS – bỏ qua toàn bộ RLS"


@tc(*ROL05)
@pytest.mark.parametrize("role", ROLES)
def test_rol_05_no_createdb_createrole_replication(rol_conn, role_names, role):
    row = fetch_role(rol_conn, role, role_names[role])
    enabled = [a for a in ("rolcreatedb", "rolcreaterole", "rolreplication") if row[a]]
    assert not enabled, f"{row['rolname']} đang bật thuộc tính không được phép: {enabled}"


# ===========================================================================
# TC-ROL-08 – Xác thực scram-sha-256 hoặc chứng chỉ; không md5/trust/password
# ===========================================================================
ROL08 = ("TC-ROL-08", "P0", "Xác thực scram-sha-256 hoặc chứng chỉ; không dùng md5/trust/password",
         "Chỉ scram-sha-256 hoặc cert")


def _password_kind(value: str | None) -> str:
    if value is None:
        return "chưa đặt mật khẩu (NULL)"
    if value.startswith("SCRAM-SHA-256$"):
        return "scram-sha-256"
    if value.startswith("md5") and len(value) == 35:
        return "md5"
    return "văn bản thường/không xác định"


@tc(*ROL08)
@pytest.mark.parametrize("role", ROLES)
def test_rol_08_password_hash_is_scram(admin_rol_conn, role_names, role):
    name = role_names[role]
    try:
        row = admin_rol_conn.execute("SELECT rolpassword FROM pg_authid WHERE rolname = %s", (name,)).fetchone()
    except pgerr.InsufficientPrivilege:
        pytest.skip("ADMIN_DSN không đọc được pg_authid (cần superuser) – bỏ qua")
    assert row is not None, f"role {name!r} không tồn tại"
    kind = _password_kind(row[0])  # KHÔNG ghi chính giá trị hash vào log
    log.info("[%s] %s: kiểu mật khẩu = %s", role, name, kind)
    assert row[0] is None or kind == "scram-sha-256", \
        f"{name} lưu mật khẩu kiểu '{kind}' – phải là scram-sha-256 (hoặc không có mật khẩu nếu dùng cert)"


@tc(*ROL08)
def test_rol_08_pg_hba_no_weak_methods(admin_rol_conn, role_names):
    """Không có dòng pg_hba nào áp dụng cho 3 role ứng dụng mà dùng trust/md5/password."""
    try:
        rules = admin_rol_conn.execute(
            "SELECT line_number, type, database, user_name, address, auth_method "
            "FROM pg_hba_file_rules WHERE error IS NULL ORDER BY line_number").fetchall()
    except pgerr.InsufficientPrivilege:
        pytest.skip("ADMIN_DSN không đọc được pg_hba_file_rules (DB managed hoặc thiếu quyền) – bỏ qua")
    if not rules:
        pytest.skip("pg_hba_file_rules rỗng (có thể là dịch vụ managed) – không kiểm tra được")
    names = set(role_names.values())
    weak = []
    for line, typ, database, users, address, method in rules:
        users = users or []
        applies = "all" in users or bool(names & set(users))
        log.debug("pg_hba dòng %s: %s db=%s user=%s addr=%s method=%s -> %s",
                  line, typ, database, users, address, method, "ÁP DỤNG" if applies else "-")
        if applies and method in WEAK_HBA_METHODS:
            weak.append((line, typ, database, users, address, method))
            log.info("pg_hba dòng %s: %s db=%s user=%s addr=%s method=%s -> PHƯƠNG THỨC YẾU",
                     line, typ, database, users, address, method)
    assert not weak, ("pg_hba.conf có dòng dùng trust/md5/password áp dụng cho role ứng dụng "
                      f"(line, type, database, user, address, method): {weak}")


# ===========================================================================
# TC-ROL-10 – app_migrator là thành viên app_owner
# ===========================================================================
ROL10 = ("TC-ROL-10", "P0", "app_migrator là thành viên app_owner", "pg_has_role(...,'member') = true")


@tc(*ROL10)
def test_rol_10_migrator_is_member_of_owner(rol_conn, role_names):
    migrator, owner = role_names["app_migrator"], role_names["app_owner"]
    value = rol_conn.execute("SELECT pg_has_role(%s::name, %s::name, 'member')", (migrator, owner)).fetchone()[0]
    log.info("pg_has_role(%s, %s, 'member') -> %s", migrator, owner, value)
    assert value is True, f"{migrator} không phải thành viên của {owner} (migration sẽ không SET ROLE được)"


# ===========================================================================
# TC-ROL-11 – app_user không là thành viên của bất kỳ role nào
# ===========================================================================
ROL11 = ("TC-ROL-11", "P0", "app_user không là thành viên của bất kỳ role nào", "0 dòng trong pg_auth_members")


@tc(*ROL11)
def test_rol_11_app_user_has_no_memberships(rol_conn, role_names):
    app_user = role_names["app_user"]
    rows = rol_conn.execute(
        "SELECT g.rolname FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid "
        "JOIN pg_roles u ON u.oid = m.member WHERE u.rolname = %s ORDER BY 1", (app_user,)).fetchall()
    log.info("[app_user] %s là thành viên của: %s", app_user, [r[0] for r in rows])
    assert rows == [], f"{app_user} đang là thành viên của: {[r[0] for r in rows]}"


# ===========================================================================
# TC-ROL-12 – Đối tượng do migration tạo có owner = app_owner
# ===========================================================================
ROL12 = ("TC-ROL-12", "P0", "Đối tượng do app_migrator tạo có owner là app_owner",
         "Owner = app_owner, không phải app_migrator")


@tc(*ROL12)
def test_rol_12_migration_objects_owned_by_owner(rol_migrator_conn, schema, settings):
    owner, conn = settings.owner_role, rol_migrator_conn
    t = f"{schema}.rol_probe"
    statements = [
        sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(owner)).as_string(conn),
        f"CREATE TABLE {t} (id bigserial PRIMARY KEY, note text)",   # kéo theo sequence + index
        f"CREATE INDEX rol_probe_note_idx ON {t} (note)",
        f"CREATE VIEW {schema}.rol_probe_v AS SELECT id FROM {t}",
        f"CREATE FUNCTION {schema}.rol_probe_f() RETURNS int LANGUAGE sql AS 'SELECT 1'",
    ]
    conn.rollback()
    try:
        for statement in statements:
            log.info("[app_migrator] %s", statement)
            conn.execute(statement)
        objects = conn.execute(
            "SELECT c.relkind::text, c.relname, pg_get_userbyid(c.relowner) FROM pg_class c "
            "WHERE c.relnamespace = %s::regnamespace AND c.relname LIKE 'rol\\_probe%%' ORDER BY 2",
            (schema,)).fetchall()
        objects += [("f", r[0], r[1]) for r in conn.execute(
            "SELECT p.proname, pg_get_userbyid(p.proowner) FROM pg_proc p "
            "WHERE p.pronamespace = %s::regnamespace AND p.proname LIKE 'rol\\_probe%%'", (schema,)).fetchall()]
    finally:
        conn.rollback()
    for kind, name, obj_owner in objects:
        log.info("[app_migrator] đối tượng %s (%s) -> owner = %s", name, kind, obj_owner)
    kinds = {o[0] for o in objects}
    assert {"r", "S", "i", "v", "f"} <= kinds, f"thiếu loại đối tượng vừa tạo (bảng, sequence, index, view, hàm): {objects}"
    wrong = [o for o in objects if o[2] != owner]
    assert not wrong, f"đối tượng không thuộc {owner}: {wrong}"
