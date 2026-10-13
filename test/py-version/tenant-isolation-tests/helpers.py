"""Hằng số dữ liệu seed và công cụ dùng chung cho các test cách ly tenant.

Mọi test đi qua TenantSession để:
  * đặt app.tenant_id đúng cách (set_config(..., true) == SET LOCAL),
  * luôn ROLLBACK khi kết thúc (test không để lại dữ liệu, không rò trạng thái sang test sau),
  * ghi log rõ ràng: ai (tenant nào) chạy câu SQL gì, thấy gì, lỗi gì.
"""
from __future__ import annotations

import logging
import re

import psycopg
import pytest

log = logging.getLogger("tbl")

# --------------------------------------------------------------------------
# Dữ liệu seed – ID cố định để log dễ đọc và test tham chiếu được
# --------------------------------------------------------------------------
TENANT_A = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
TENANT_B = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
TENANT_LABEL = {TENANT_A: "A", TENANT_B: "B"}
OTHER_TENANT = {TENANT_A: TENANT_B, TENANT_B: TENANT_A}


def _id(kind: int, n: int) -> str:
    return f"{kind:08x}-0000-0000-0000-{n:012x}"


USER_1 = _id(4, 1)  # thuộc CẢ HAI tenant A và B (người dùng nhiều tenant)
USER_2 = _id(4, 2)  # chỉ thuộc A
USER_3 = _id(4, 3)  # chỉ thuộc B

ORDER_A1, ORDER_A2, ORDER_B1 = _id(1, 0xA1), _id(1, 0xA2), _id(1, 0xB1)
PRODUCT_A1, PRODUCT_B1 = _id(2, 0xA1), _id(2, 0xB1)
TAG_A1, TAG_A2, TAG_B1 = _id(3, 0xA1), _id(3, 0xA2), _id(3, 0xB1)

OWN_ORDER = {TENANT_A: ORDER_A1, TENANT_B: ORDER_B1}

# Số dòng kỳ vọng theo seed (xem sql/fixture_schema.sql)
EXPECTED_COUNTRIES = 3
EXPECTED_ORDER_ITEMS = {TENANT_A: 3, TENANT_B: 2}
EXPECTED_MEMBERS = {TENANT_A: {USER_1, USER_2}, TENANT_B: {USER_1, USER_3}}

# Các giá trị được format vào file SQL fixture
SEED_IDS = {
    "tenant_a": TENANT_A, "tenant_b": TENANT_B,
    "user_1": USER_1, "user_2": USER_2, "user_3": USER_3,
    "order_a1": ORDER_A1, "order_a2": ORDER_A2, "order_b1": ORDER_B1,
    "product_a1": PRODUCT_A1, "product_b1": PRODUCT_B1,
    "tag_a1": TAG_A1, "tag_a2": TAG_A2, "tag_b1": TAG_B1,
}

SCHEMA_RE = re.compile(r"^tbl_[a-z0-9_]{0,50}$")
FIXTURE_MARKER = "tbl-isolation-tests fixture (an toàn để xóa)"


def tc(tc_id: str, priority: str, title: str, expected: str):
    """Gắn thông tin test case vào hàm test (dùng để in banner và bảng tổng hợp)."""

    def decorator(fn):
        fn = pytest.mark.tc(tc_id, priority, title, expected)(fn)
        fn = getattr(pytest.mark, priority.lower())(fn)
        return fn

    return decorator


def _one_line(text: str, limit: int = 220) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 3] + "..."


def _preview(rows: list, limit: int = 5) -> str:
    shown = ", ".join(repr(r) for r in rows[:limit])
    more = f" ... (+{len(rows) - limit})" if len(rows) > limit else ""
    return _one_line(f"[{shown}]{more}", 300)


class TenantSession:
    """Một transaction của app_user dưới danh nghĩa một tenant.

    tenant_id=None  -> KHÔNG đặt app.tenant_id (mô phỏng request thiếu tenant).
    Kết thúc khối `with` luôn ROLLBACK.
    """

    def __init__(self, conn: psycopg.Connection, tenant_id: str | None):
        self.conn = conn
        self.tenant_id = tenant_id
        self.label = TENANT_LABEL.get(tenant_id, "không-tenant") if tenant_id else "không-tenant"

    def __enter__(self) -> "TenantSession":
        self.conn.rollback()
        if self.tenant_id is not None:
            self.conn.execute("SELECT set_config('app.tenant_id', %s, true)", (self.tenant_id,))
            log.info("[%s] BEGIN; set_config('app.tenant_id', %s, true)", self.label, self.tenant_id)
        else:
            leftover = self.conn.execute("SELECT current_setting('app.tenant_id', true)").fetchone()[0]
            log.info("[%s] BEGIN; không đặt app.tenant_id (giá trị hiện có: %r)", self.label, leftover)
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.conn.rollback()
        log.debug("[%s] ROLLBACK", self.label)
        return False

    # -- đọc ---------------------------------------------------------------
    def query(self, sql: str, params: tuple | None = None) -> list[tuple]:
        log.debug("[%s] SQL: %s | params=%s", self.label, _one_line(sql, 1000), params)
        rows = self.conn.execute(sql, params).fetchall()
        log.info("[%s] %s -> %d dòng %s", self.label, _one_line(sql), len(rows), _preview(rows))
        return rows

    # -- ghi (trả về số dòng bị tác động) ----------------------------------
    def execute(self, sql: str, params: tuple | None = None) -> int:
        log.debug("[%s] SQL: %s | params=%s", self.label, _one_line(sql, 1000), params)
        rowcount = self.conn.execute(sql, params).rowcount
        log.info("[%s] %s -> %d dòng bị tác động", self.label, _one_line(sql), rowcount)
        return rowcount

    # -- kỳ vọng lỗi -------------------------------------------------------
    def expect_error(self, sql: str, params: tuple | None, expected: type[psycopg.Error]) -> psycopg.Error:
        """Chạy câu lệnh trong savepoint; PHẢI lỗi đúng loại `expected`, nếu không test fail."""
        log.debug("[%s] SQL: %s | params=%s", self.label, _one_line(sql, 1000), params)
        try:
            with self.conn.transaction():  # savepoint -> transaction vẫn dùng tiếp được sau lỗi
                self.conn.execute(sql, params)
        except psycopg.Error as exc:
            first_line = str(exc).strip().splitlines()[0]
            log.info("[%s] %s -> LỖI %s (SQLSTATE %s): %s",
                     self.label, _one_line(sql), type(exc).__name__, exc.sqlstate, first_line)
            if not isinstance(exc, expected):
                raise AssertionError(
                    f"[{self.label}] mong đợi {expected.__name__} nhưng nhận {type(exc).__name__} "
                    f"(SQLSTATE {exc.sqlstate}): {first_line}\n  SQL: {_one_line(sql)}"
                ) from exc
            return exc
        raise AssertionError(
            f"[{self.label}] mong đợi lỗi {expected.__name__} nhưng câu lệnh CHẠY THÀNH CÔNG "
            f"(có thể bị rò/ghi trái phép)\n  SQL: {_one_line(sql)}"
        )

    def expect_denied(self, sql: str, params: tuple | None = None) -> psycopg.Error:
        """Mong đợi 'permission denied' (SQLSTATE 42501)."""
        return self.expect_error(sql, params, psycopg.errors.InsufficientPrivilege)
