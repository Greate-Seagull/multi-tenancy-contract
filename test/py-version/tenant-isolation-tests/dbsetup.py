#!/usr/bin/env python3
"""Chuẩn bị DB cho tenant-isolation tests. Chạy TRƯỚC pytest, bằng superuser DSN.

Các bước:
  1. Chạy bootstrap.sql (contract, không chứa password) nếu các role chưa tồn tại.
  2. Đặt password cho app_migrator và app_user.
  3. Kiểm tra đăng nhập bằng từng role.

Idempotent: role đã có thì bỏ qua bootstrap, chỉ đặt lại password.
Muốn reset sạch: `docker compose down -v` rồi dựng lại.

Mật khẩu nhận qua flag hoặc env (ưu tiên env trên CI để không lộ trong `ps`/log):
  Admin: biến libpq chuẩn PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE (hoặc --admin-dsn)
  --migrator-password / APP_MIGRATOR_PASSWORD
  --user-password     / APP_USER_PASSWORD
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo

HERE = Path(__file__).resolve().parent
# Giả định: test/py-version/tenant-isolation-tests/dbsetup.py, bootstrap ở test/deploy/bootstrap.sql
DEFAULT_BOOTSTRAP = HERE.parents[2] / "contract" / "bootstrap" / "bootstrap.sql"

OWNER = "app_owner"  # NOLOGIN, không đặt password
MIGRATOR = "app_migrator"
USER = "app_user"
ALL_ROLES = {OWNER, MIGRATOR, USER}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    # Rỗng = psycopg tự đọc PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE từ env
    p.add_argument("--admin-dsn", default="")
    p.add_argument("--migrator-password", default=os.environ.get("APP_MIGRATOR_PASSWORD"))
    p.add_argument("--user-password", default=os.environ.get("APP_USER_PASSWORD"))
    p.add_argument(
        "--bootstrap-sql",
        type=Path,
        default=Path(os.environ.get("BOOTSTRAP_SQL", DEFAULT_BOOTSTRAP)),
    )
    p.add_argument("--wait", type=int, default=30, help="giây chờ DB sẵn sàng (mặc định 30)")
    args = p.parse_args(argv)

    missing = [
        flag
        for flag, val in (
            ("--migrator-password / APP_MIGRATOR_PASSWORD", args.migrator_password),
            ("--user-password / APP_USER_PASSWORD", args.user_password),
        )
        if not val
    ]
    if missing:
        p.error("thiếu: " + ", ".join(missing))
    return args


def connect_admin(dsn: str, wait: int) -> psycopg.Connection:
    deadline = time.monotonic() + wait
    while True:
        try:
            return psycopg.connect(dsn, autocommit=True, connect_timeout=3)
        except psycopg.OperationalError as e:
            if time.monotonic() >= deadline:
                sys.exit(f"Không kết nối được admin DSN sau {wait}s: {e}")
            time.sleep(1)


def run_bootstrap(conn: psycopg.Connection, path: Path) -> None:
    existing = {
        r[0]
        for r in conn.execute(
            "SELECT rolname FROM pg_roles WHERE rolname = ANY(%s)", (sorted(ALL_ROLES),)
        )
    }
    if existing == ALL_ROLES:
        print("bootstrap: role đã tồn tại, bỏ qua")
        return
    if existing:
        sys.exit(
            f"Trạng thái dở dang: chỉ có role {sorted(existing)}. "
            "Reset DB (docker compose down -v) rồi chạy lại."
        )
    if not path.is_file():
        sys.exit(f"Không thấy bootstrap.sql: {path}")
    print(f"bootstrap: chạy {path}")
    # Không truyền params -> psycopg cho phép nhiều statement trong một lần execute
    conn.execute(path.read_text(encoding="utf-8"))


def set_password(conn: psycopg.Connection, role: str, password: str) -> None:
    # Băm SCRAM phía client: plaintext không đi vào câu lệnh SQL nên không lọt vào log server
    hashed = conn.pgconn.encrypt_password(
        password.encode(), role.encode(), b"scram-sha-256"
    ).decode()
    conn.execute(
        sql.SQL("ALTER ROLE {} PASSWORD {}").format(sql.Identifier(role), sql.Literal(hashed))
    )
    print(f"password: đã đặt cho {role}")


def check_login(admin_dsn: str, role: str, password: str) -> None:
    dsn = make_conninfo(admin_dsn, user=role, password=password)
    try:
        with psycopg.connect(dsn, connect_timeout=5) as c:
            c.execute("SELECT 1")
    except psycopg.Error as e:
        sys.exit(f"Đăng nhập thất bại với {role}: {e}")
    print(f"login: {role} OK")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    with connect_admin(args.admin_dsn, args.wait) as conn:
        run_bootstrap(conn, args.bootstrap_sql)
        set_password(conn, MIGRATOR, args.migrator_password)
        set_password(conn, USER, args.user_password)
    check_login(args.admin_dsn, MIGRATOR, args.migrator_password)
    check_login(args.admin_dsn, USER, args.user_password)
    return 0


if __name__ == "__main__":
    sys.exit(main())