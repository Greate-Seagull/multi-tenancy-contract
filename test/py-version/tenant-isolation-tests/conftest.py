"""Fixture dùng chung: dựng/xóa schema mẫu, kết nối app_user, banner và bảng tổng hợp."""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import make_conninfo

from helpers import FIXTURE_MARKER, SCHEMA_RE, SEED_IDS

log = logging.getLogger("tbl")
ROOT = Path(__file__).parent
SQL_FILE = ROOT / "sql" / "fixture_schema.sql"


@dataclass(frozen=True)
class Settings:
    app_dsn: str
    admin_dsn: str
    migrator_dsn: str | None
    schema: str
    owner_role: str
    keep_fixture: bool


# --------------------------------------------------------------------------
# Cấu hình
# --------------------------------------------------------------------------
def _dsn(dsn_env: str, user_env: str, password_env: str) -> str | None:
    """Ưu tiên chuỗi DSN nếu có; nếu không thì ghép từ user/password riêng (tự escape ký tự đặc biệt).
    host/port/dbname do libpq tự lấy từ PGHOST/PGPORT/PGDATABASE."""
    if os.environ.get(dsn_env):
        return os.environ[dsn_env]
    user, password = os.environ.get(user_env), os.environ.get(password_env)
    return make_conninfo(user=user, password=password) if user and password else None


@pytest.fixture(scope="session")
def settings() -> Settings:
    app_dsn = _dsn("APP_USER_DSN", "APP_USER", "APP_PASSWORD")
    admin_dsn = _dsn("ADMIN_DSN", "ADMIN_USER", "ADMIN_PASSWORD")
    missing = [n for n, v in (("APP_USER_DSN (hoặc APP_USER + APP_PASSWORD)", app_dsn),
                              ("ADMIN_DSN (hoặc ADMIN_USER + ADMIN_PASSWORD)", admin_dsn)) if not v]
    if missing:
        pytest.exit(f"Thiếu biến môi trường: {', '.join(missing)} (xem .env.example)", returncode=2)
    schema = os.environ.get("FIXTURE_SCHEMA", "tbl_fixture")
    if not SCHEMA_RE.match(schema):
        pytest.exit(f"FIXTURE_SCHEMA='{schema}' không hợp lệ: phải bắt đầu bằng 'tbl_' "
                    "và chỉ gồm chữ thường/số/gạch dưới (để không bao giờ chạm schema thật)", returncode=2)
    return Settings(
        app_dsn=app_dsn,
        admin_dsn=admin_dsn,
        migrator_dsn=_dsn("APP_MIGRATOR_DSN", "MIG_USER", "MIG_PASSWORD"),
        schema=schema,
        owner_role=os.environ.get("OWNER_ROLE", "app_owner"),
        keep_fixture=os.environ.get("KEEP_FIXTURE") == "1",
    )


def _describe(conn: psycopg.Connection) -> str:
    """Mô tả kết nối mà KHÔNG lộ mật khẩu."""
    i = conn.info
    return f"host={i.host} port={i.port} db={i.dbname} user={i.user} server_version={i.server_version}"


# --------------------------------------------------------------------------
# Dựng / xóa schema fixture
# --------------------------------------------------------------------------
@pytest.fixture(scope="session")
def schema(settings: Settings):
    """Tạo schema mẫu bằng ADMIN_DSN, trả về tên schema, xóa khi xong (trừ KEEP_FIXTURE=1)."""
    try:
        with psycopg.connect(settings.app_dsn) as c:
            app_role = c.execute("SELECT current_user").fetchone()[0]
        with psycopg.connect(settings.admin_dsn, autocommit=True) as admin:
            log.info("ADMIN kết nối: %s", _describe(admin))
            priv = admin.execute(
                "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user").fetchone()[0]
            if not priv:
                pytest.exit("ADMIN_DSN phải là superuser (hoặc BYPASSRLS) để seed dữ liệu qua RLS", returncode=2)

            # Chốt an toàn: chỉ được xóa schema do chính bộ test này tạo
            row = admin.execute(
                "SELECT obj_description(oid, 'pg_namespace') FROM pg_namespace WHERE nspname = %s",
                (settings.schema,)).fetchone()
            if row is not None and row[0] != FIXTURE_MARKER:
                pytest.exit(f"Schema '{settings.schema}' đã tồn tại và KHÔNG phải do bộ test tạo – "
                            "từ chối ghi đè. Đổi FIXTURE_SCHEMA.", returncode=2)

            quote = lambda name: sql.Identifier(name).as_string(admin)  # noqa: E731
            script = SQL_FILE.read_text(encoding="utf-8").format(
                schema=quote(settings.schema), owner=quote(settings.owner_role),
                app_role=quote(app_role), marker=FIXTURE_MARKER, **SEED_IDS)
            admin.execute(script)
            log.info("Đã dựng schema fixture '%s' (owner=%s, app_role=%s)",
                     settings.schema, settings.owner_role, app_role)
    except psycopg.Error as exc:
        pytest.exit(f"Dựng fixture thất bại: {type(exc).__name__}: {exc}", returncode=2)

    yield settings.schema

    if settings.keep_fixture:
        log.info("KEEP_FIXTURE=1: giữ lại schema '%s' để debug", settings.schema)
        return
    with psycopg.connect(settings.admin_dsn, autocommit=True) as admin:
        admin.execute(sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(sql.Identifier(settings.schema)))
    log.info("Đã xóa schema fixture '%s'", settings.schema)


@pytest.fixture(scope="session")
def app_conn(settings: Settings, schema: str):
    """Một kết nối app_user dùng chung (giống connection pool: tái sử dụng giữa các test)."""
    conn = psycopg.connect(settings.app_dsn, application_name="tbl-isolation-tests")
    log.info("APP_USER kết nối: %s", _describe(conn))

    superuser, bypass = conn.execute(
        "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user").fetchone()
    if superuser or bypass:
        conn.close()
        pytest.exit("Role của APP_USER_DSN có SUPERUSER/BYPASSRLS – mọi test RLS đều vô nghĩa. "
                    "Hãy dùng đúng role app_user.", returncode=2)
    try:
        conn.execute(sql.SQL("SELECT 1 FROM {}.countries LIMIT 1").format(sql.Identifier(schema)))
    except psycopg.Error as exc:
        conn.close()
        pytest.exit(f"app_user không đọc được schema fixture (thiếu USAGE/SELECT?): {exc}", returncode=2)
    conn.rollback()

    yield conn
    conn.close()


# --------------------------------------------------------------------------
# Banner mỗi test case + kết quả + bảng tổng hợp
# --------------------------------------------------------------------------
@pytest.fixture(autouse=True)
def _tc_banner(request):
    marker = request.node.get_closest_marker("tc")
    if marker:
        tc_id, priority, title, expected = marker.args
        request.node.user_properties.append(("tc", tc_id))
        request.node.user_properties.append(("priority", priority))
        log.info("")
        log.info("━━ %s [%s] %s", tc_id, priority, title)
        log.info("   Mong đợi : %s", expected)
        log.info("   Test     : %s", request.node.name)
    yield


def pytest_runtest_logreport(report):
    if report.when == "call" or (report.when == "setup" and not report.passed):
        verdict = {"passed": "PASS ✔", "failed": "FAIL ✘", "skipped": "SKIP"}[report.outcome]
        log.info("   Kết quả  : %s  (%s)", verdict, report.nodeid.split("::", 1)[-1])


_RANK = {"failed": 3, "error": 3, "skipped": 2, "passed": 1}


def pytest_terminal_summary(terminalreporter, exitstatus, config):
    per_test: dict[str, tuple[str, str, str]] = {}  # nodeid -> (tc, priority, worst outcome)
    for outcome in ("passed", "failed", "error", "skipped"):
        for rep in terminalreporter.stats.get(outcome, []):
            props = dict(getattr(rep, "user_properties", []))
            if "tc" not in props:
                continue
            if outcome == "passed" and rep.when != "call":
                continue
            prev = per_test.get(rep.nodeid)
            if prev is None or _RANK[outcome] > _RANK[prev[2]]:
                per_test[rep.nodeid] = (props["tc"], props["priority"], outcome)
    if not per_test:
        return

    by_tc: dict[str, dict] = {}
    for tc_id, priority, outcome in per_test.values():
        entry = by_tc.setdefault(tc_id, {"priority": priority, "outcomes": []})
        entry["outcomes"].append(outcome)

    lines = [f"{'Mã TC':<12} {'Ưu tiên':<8} {'Kết quả':<8} Số test (đạt/tổng)"]
    for tc_id in sorted(by_tc):
        outcomes = by_tc[tc_id]["outcomes"]
        worst = max(outcomes, key=lambda o: _RANK[o])
        verdict = {"passed": "PASS", "failed": "FAIL", "error": "ERROR", "skipped": "SKIP"}[worst]
        lines.append(f"{tc_id:<12} {by_tc[tc_id]['priority']:<8} {verdict:<8} "
                     f"{outcomes.count('passed')}/{len(outcomes)}")

    terminalreporter.write_sep("=", "TỔNG HỢP THEO TEST CASE")
    for line in lines:
        terminalreporter.write_line(line)
    summary_file = ROOT / "reports" / "summary.txt"
    summary_file.parent.mkdir(exist_ok=True)
    summary_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
