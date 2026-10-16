"""Nhóm TBL – Bảng không có tenant_id (tài liệu mục 4.1).

Quy ước:
  * Tên test dạng test_tbl_<số>_...  -> chạy riêng một case:  pytest -k tbl_03
  * Mọi câu lệnh chạy bằng app_user qua TenantSession (luôn ROLLBACK, không để lại dữ liệu).
  * Test "bị từ chối" luôn kèm đối chứng "được phép" để không pass vì lý do sai.
"""
import pytest
from psycopg import errors as pgerr

from helpers import (
    EXPECTED_COUNTRIES, EXPECTED_MEMBERS, EXPECTED_ORDER_ITEMS, OTHER_TENANT, OWN_ORDER,
    PRODUCT_A1, PRODUCT_B1, TAG_A1, TAG_A2, TAG_B1, TENANT_A, TENANT_B, TENANT_LABEL, USER_1,
    TenantSession, tc,
)

TENANTS = [pytest.param(TENANT_A, id="tenant_A"), pytest.param(TENANT_B, id="tenant_B")]


# ===========================================================================
# TC-TBL-01 – Bảng tham chiếu dùng chung
# ===========================================================================
TBL01 = ("TC-TBL-01", "P2", "Bảng tham chiếu dùng chung (quốc gia, tiền tệ...) đọc được bởi mọi tenant",
         "Mọi tenant đọc cùng dữ liệu; app_user không có quyền ghi")


@tc(*TBL01)
def test_tbl_01_shared_reference_same_data_for_all_tenants(app_conn, schema):
    seen = {}
    for tenant in (TENANT_A, TENANT_B):
        with TenantSession(app_conn, tenant) as s:
            seen[tenant] = s.query(f"SELECT code, name FROM {schema}.countries ORDER BY code")
    assert len(seen[TENANT_A]) == EXPECTED_COUNTRIES, \
        f"tenant A phải đọc đủ {EXPECTED_COUNTRIES} quốc gia, thực tế {len(seen[TENANT_A])}"
    assert seen[TENANT_A] == seen[TENANT_B], \
        f"hai tenant đọc dữ liệu tham chiếu khác nhau:\n  A={seen[TENANT_A]}\n  B={seen[TENANT_B]}"


@tc(*TBL01)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_01_shared_reference_is_read_only(app_conn, schema, tenant_id):
    with TenantSession(app_conn, tenant_id) as s:
        s.expect_denied(f"INSERT INTO {schema}.countries (code, name) VALUES ('ZZ', 'Zedland')")
        s.expect_denied(f"UPDATE {schema}.countries SET name = 'hacked'")
        s.expect_denied(f"DELETE FROM {schema}.countries")


# ===========================================================================
# TC-TBL-02 – Bảng cấu hình nền tảng
# ===========================================================================
TBL02 = ("TC-TBL-02", "P1", "Bảng cấu hình nền tảng (plans, feature flags) không cho tenant sửa",
         "UPDATE/INSERT bằng app_user bị từ chối (permission denied)")

PLATFORM_WRITES = {
    "plans": (
        "INSERT INTO {t} (code, name, monthly_price_usd) VALUES ('free_forever', 'Free forever', 0)",
        "UPDATE {t} SET monthly_price_usd = 0",
        "DELETE FROM {t}",
    ),
    "feature_flags": (
        "INSERT INTO {t} (key, enabled) VALUES ('tenant_backdoor', true)",
        "UPDATE {t} SET enabled = true",
        "DELETE FROM {t}",
    ),
}


@tc(*TBL02)
@pytest.mark.parametrize("table", list(PLATFORM_WRITES))
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_02_platform_config_not_writable(app_conn, schema, tenant_id, table):
    qualified = f"{schema}.{table}"
    with TenantSession(app_conn, tenant_id) as s:
        rows = s.query(f"SELECT count(*) FROM {qualified}")  # đối chứng: đọc được
        assert rows[0][0] > 0, f"{table} trống – test không có ý nghĩa"
        for statement in PLATFORM_WRITES[table]:
            s.expect_denied(statement.format(t=qualified))


# ===========================================================================
# TC-TBL-03 – Bảng tenants
# ===========================================================================
TBL03 = ("TC-TBL-03", "P0", "Bảng tenants: tenant chỉ thấy bản ghi của chính mình",
         "SELECT * FROM tenants với app.tenant_id = A chỉ trả dòng id = A")


@tc(*TBL03)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_03_tenants_only_own_row(app_conn, schema, tenant_id):
    with TenantSession(app_conn, tenant_id) as s:
        rows = s.query(f"SELECT id::text, name FROM {schema}.tenants ORDER BY id")
    assert [r[0] for r in rows] == [tenant_id], \
        f"tenant {TENANT_LABEL[tenant_id]} phải chỉ thấy đúng dòng của mình, thực tế thấy: {rows}"


@tc(*TBL03)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_03_tenants_other_row_unreachable_by_id(app_conn, schema, tenant_id):
    other = OTHER_TENANT[tenant_id]
    with TenantSession(app_conn, tenant_id) as s:
        rows = s.query(f"SELECT id::text FROM {schema}.tenants WHERE id = %s::uuid", (other,))
    assert rows == [], f"truy vấn đích danh id của tenant khác vẫn trả dòng: {rows}"


@tc(*TBL03)
def test_tbl_03_tenants_empty_without_tenant_context(app_conn, schema):
    with TenantSession(app_conn, None) as s:
        rows = s.query(f"SELECT id::text FROM {schema}.tenants")
    assert rows == [], f"request thiếu app.tenant_id vẫn thấy dữ liệu tenants: {rows}"


# ===========================================================================
# TC-TBL-04 – Bảng con có tenant_id và policy lọc trực tiếp
# ===========================================================================
TBL04 = ("TC-TBL-04", "P1", "Bảng con (order_items) có tenant_id và policy lọc trực tiếp",
         "Có tenant_id, RLS lọc đúng, không cần join")


@tc(*TBL04)
def test_tbl_04_order_items_structure(app_conn, schema):
    table = f"{schema}.order_items"
    with TenantSession(app_conn, None) as s:
        col = s.query("SELECT attnotnull FROM pg_attribute WHERE attrelid = to_regclass(%s) "
                      "AND attname = 'tenant_id' AND NOT attisdropped", (table,))
        assert col, "order_items không có cột tenant_id"
        assert col[0][0] is True, "cột tenant_id của order_items phải NOT NULL"

        flags = s.query("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = to_regclass(%s)",
                        (table,))
        assert flags == [(True, True)], f"order_items phải ENABLE + FORCE RLS, thực tế {flags}"

        policies = s.query("SELECT policyname, cmd, qual, with_check FROM pg_policies "
                           "WHERE schemaname = %s AND tablename = 'order_items'", (schema,))
    assert policies, "order_items chưa có policy RLS nào"
    for name, cmd, qual, with_check in policies:
        for part_name, part in (("USING", qual), ("WITH CHECK", with_check)):
            if part is None:
                continue
            assert "tenant_id" in part, f"policy {name} ({part_name}) không lọc theo tenant_id: {part}"
            assert "select" not in part.lower(), \
                f"policy {name} ({part_name}) dùng subquery/join sang bảng khác: {part}"
    assert any(wc and "tenant_id" in wc for _, _, _, wc in policies), \
        "không có policy nào có WITH CHECK theo tenant_id (ghi sai tenant sẽ không bị chặn)"


@tc(*TBL04)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_04_order_items_filtered_directly(app_conn, schema, tenant_id):
    # Cố ý KHÔNG join và KHÔNG có WHERE theo tenant: chỉ RLS được phép lọc.
    with TenantSession(app_conn, tenant_id) as s:
        rows = s.query(f"SELECT tenant_id::text, sku FROM {schema}.order_items")
    expected = EXPECTED_ORDER_ITEMS[tenant_id]
    assert len(rows) == expected, f"phải thấy đúng {expected} dòng của mình, thực tế {len(rows)}: {rows}"
    foreign = [r for r in rows if r[0] != tenant_id]
    assert not foreign, f"lọt dòng của tenant khác: {foreign}"


@tc(*TBL04)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_04_order_items_write_checked(app_conn, schema, tenant_id):
    other = OTHER_TENANT[tenant_id]
    insert = f"INSERT INTO {schema}.order_items (tenant_id, order_id, sku, qty) VALUES (%s::uuid, %s::uuid, 'NEW', 1)"
    with TenantSession(app_conn, tenant_id) as s:
        assert s.execute(insert, (tenant_id, OWN_ORDER[tenant_id])) == 1  # đối chứng: ghi vào tenant mình được
        s.expect_denied(insert, (other, OWN_ORDER[other]))  # ghi vào tenant khác bị WITH CHECK chặn


# ===========================================================================
# TC-TBL-05 – Bảng nối many-to-many
# ===========================================================================
TBL05 = ("TC-TBL-05", "P1", "Bảng nối many-to-many có tenant_id và FK kép",
         "Chèn dòng nối giữa 2 bản ghi thuộc 2 tenant khác nhau bị FK kép từ chối")

INSERT_LINK = ("INSERT INTO {schema}.product_tags (tenant_id, product_id, tag_id) "
               "VALUES (%s::uuid, %s::uuid, %s::uuid)")


@tc(*TBL05)
def test_tbl_05_junction_structure(app_conn, schema):
    table = f"{schema}.product_tags"
    with TenantSession(app_conn, None) as s:
        col = s.query("SELECT attnotnull FROM pg_attribute WHERE attrelid = to_regclass(%s) "
                      "AND attname = 'tenant_id' AND NOT attisdropped", (table,))
        assert col and col[0][0] is True, "product_tags phải có cột tenant_id NOT NULL"

        flags = s.query("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = to_regclass(%s)",
                        (table,))
        assert flags == [(True, True)], f"product_tags phải ENABLE + FORCE RLS, thực tế {flags}"

        fks = s.query("SELECT c.conname, array_agg(a.attname::text) FROM pg_constraint c "
                      "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey) "
                      "WHERE c.conrelid = to_regclass(%s) AND c.contype = 'f' GROUP BY c.oid, c.conname",
                      (table,))
    assert len(fks) == 2, f"phải có 2 FK (product, tag), thực tế {len(fks)}: {fks}"
    for name, columns in fks:
        assert "tenant_id" in columns, f"FK {name} không phải FK kép (thiếu tenant_id): cột = {columns}"


@tc(*TBL05)
def test_tbl_05_junction_same_tenant_allowed(app_conn, schema):
    """Đối chứng: nối hai bản ghi CÙNG tenant (A) phải thành công, để các test từ chối bên dưới có ý nghĩa."""
    with TenantSession(app_conn, TENANT_A) as s:
        assert s.execute(INSERT_LINK.format(schema=schema), (TENANT_A, PRODUCT_A1, TAG_A2)) == 1


CROSS_TENANT_LINKS = [
    # (tenant đang đăng nhập, tenant_id ghi vào dòng, product, tag, lỗi mong đợi)
    pytest.param(TENANT_A, TENANT_A, PRODUCT_A1, TAG_B1, pgerr.ForeignKeyViolation, id="A_noi_product_A_voi_tag_B"),
    pytest.param(TENANT_A, TENANT_A, PRODUCT_B1, TAG_A1, pgerr.ForeignKeyViolation, id="A_noi_product_B_voi_tag_A"),
    pytest.param(TENANT_B, TENANT_B, PRODUCT_B1, TAG_A1, pgerr.ForeignKeyViolation, id="B_noi_product_B_voi_tag_A"),
    pytest.param(TENANT_B, TENANT_B, PRODUCT_A1, TAG_B1, pgerr.ForeignKeyViolation, id="B_noi_product_A_voi_tag_B"),
    # Ghi hẳn sang tenant khác (cả hai bản ghi đều của B) -> bị RLS WITH CHECK chặn trước
    pytest.param(TENANT_A, TENANT_B, PRODUCT_B1, TAG_B1, pgerr.InsufficientPrivilege, id="A_ghi_hang_vao_B"),
    pytest.param(TENANT_B, TENANT_A, PRODUCT_A1, TAG_A2, pgerr.InsufficientPrivilege, id="B_ghi_hang_vao_A"),
]


@tc(*TBL05)
@pytest.mark.parametrize("login_tenant, row_tenant, product, tag, expected_error", CROSS_TENANT_LINKS)
def test_tbl_05_junction_cross_tenant_rejected(app_conn, schema, login_tenant, row_tenant, product, tag,
                                               expected_error):
    with TenantSession(app_conn, login_tenant) as s:
        s.expect_error(INSERT_LINK.format(schema=schema), (row_tenant, product, tag), expected_error)


# ===========================================================================
# TC-TBL-06 – Bảng kỹ thuật
# ===========================================================================
TBL06 = ("TC-TBL-06", "P1",
         "Bảng kỹ thuật (schema_migrations, khóa phân tán, job queue) không truy cập được bởi app_user",
         "SELECT/INSERT bằng app_user bị từ chối (biến thể 'bị từ chối' của kỳ vọng 'từ chối hoặc đã tách tenant')")

TECHNICAL_STATEMENTS = {
    "schema_migrations": (
        "SELECT * FROM {t}",
        "INSERT INTO {t} (version) VALUES ('99999999999999')",
        "DELETE FROM {t}",
    ),
    "job_queue": (
        "SELECT * FROM {t}",
        "INSERT INTO {t} (kind, payload) VALUES ('x', 'y')",
        "DELETE FROM {t}",
    ),
}


@tc(*TBL06)
@pytest.mark.parametrize("table", list(TECHNICAL_STATEMENTS))
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_06_technical_tables_denied(app_conn, schema, tenant_id, table):
    with TenantSession(app_conn, tenant_id) as s:
        for statement in TECHNICAL_STATEMENTS[table]:
            s.expect_denied(statement.format(t=f"{schema}.{table}"))


# ===========================================================================
# TC-TBL-07 – Bảng memberships
# ===========================================================================
TBL07 = ("TC-TBL-07", "P1", "Bảng memberships: người dùng nhiều tenant chỉ thấy membership hợp lệ",
         "SELECT memberships với từng tenant chỉ thấy dòng thuộc tenant hiện tại")


@tc(*TBL07)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_07_memberships_only_current_tenant(app_conn, schema, tenant_id):
    with TenantSession(app_conn, tenant_id) as s:
        rows = s.query(f"SELECT tenant_id::text, user_id::text, role FROM {schema}.memberships")
    foreign = [r for r in rows if r[0] != tenant_id]
    assert not foreign, f"thấy membership của tenant khác: {foreign}"
    assert {r[1] for r in rows} == EXPECTED_MEMBERS[tenant_id], \
        f"danh sách thành viên sai: thấy {sorted(r[1] for r in rows)}"


@tc(*TBL07)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_07_multi_tenant_user_sees_one_membership(app_conn, schema, tenant_id):
    """USER_1 thuộc cả A và B: mỗi tenant chỉ được thấy ĐÚNG MỘT membership của user đó."""
    with TenantSession(app_conn, tenant_id) as s:
        rows = s.query(f"SELECT tenant_id::text, role FROM {schema}.memberships WHERE user_id = %s::uuid",
                       (USER_1,))
    assert [r[0] for r in rows] == [tenant_id], \
        f"user nhiều tenant phải chỉ có 1 membership trong tenant {TENANT_LABEL[tenant_id]}, thực tế: {rows}"


@tc(*TBL07)
@pytest.mark.parametrize("tenant_id", TENANTS)
def test_tbl_07_memberships_of_other_tenant_unreachable(app_conn, schema, tenant_id):
    other = OTHER_TENANT[tenant_id]
    with TenantSession(app_conn, tenant_id) as s:
        rows = s.query(f"SELECT user_id::text FROM {schema}.memberships WHERE tenant_id = %s::uuid", (other,))
    assert rows == [], f"lọc đích danh tenant khác vẫn thấy membership: {rows}"


@tc(*TBL07)
def test_tbl_07_memberships_empty_without_tenant_context(app_conn, schema):
    with TenantSession(app_conn, None) as s:
        rows = s.query(f"SELECT user_id::text FROM {schema}.memberships")
    assert rows == [], f"thiếu app.tenant_id vẫn thấy memberships: {rows}"
