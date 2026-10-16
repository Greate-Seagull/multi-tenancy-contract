-- Schema fixture mô phỏng một ứng dụng đa tenant thực tế (đơn hàng, sản phẩm, thành viên).
-- Chạy bằng ADMIN_DSN (superuser). Các placeholder dạng ngoặc nhọn do conftest.py điền vào
-- (lưu ý: không viết dấu ngoặc nhọn trong file này ngoài các placeholder, vì file được xử lý bằng str.format).
-- Tên schema/role đã được quote an toàn trước khi format.

DROP SCHEMA IF EXISTS {schema} CASCADE;
CREATE SCHEMA {schema} AUTHORIZATION {owner};
COMMENT ON SCHEMA {schema} IS '{marker}';
REVOKE ALL ON SCHEMA {schema} FROM PUBLIC;
GRANT USAGE ON SCHEMA {schema} TO {app_role};

-- Từ đây mọi đối tượng thuộc sở hữu app_owner (đúng thiết kế: app_user KHÔNG là owner)
SET ROLE {owner};

-- ===== Nhóm 1: bảng KHÔNG có tenant_id =====

-- (TBL-01) Bảng tham chiếu dùng chung: mọi tenant đọc, không ai ghi
CREATE TABLE {schema}.countries (
    code char(2) PRIMARY KEY,
    name text NOT NULL
);

-- (TBL-02) Bảng cấu hình nền tảng: tenant không được sửa
CREATE TABLE {schema}.plans (
    code text PRIMARY KEY,
    name text NOT NULL,
    monthly_price_usd numeric(10,2) NOT NULL
);
CREATE TABLE {schema}.feature_flags (
    key text PRIMARY KEY,
    enabled boolean NOT NULL DEFAULT false
);

-- (TBL-06) Bảng kỹ thuật: app_user không được đụng tới
CREATE TABLE {schema}.schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE {schema}.job_queue (
    id bigserial PRIMARY KEY,
    kind text NOT NULL,
    payload text NOT NULL
);

-- (TBL-03) Bảng tenants: khóa là id, không có cột tenant_id
CREATE TABLE {schema}.tenants (
    id uuid PRIMARY KEY,
    name text NOT NULL,
    plan_code text NOT NULL REFERENCES {schema}.plans (code)
);

-- Người dùng toàn cục (đăng nhập), app_user không đọc trực tiếp
CREATE TABLE {schema}.users (
    id uuid PRIMARY KEY,
    email text NOT NULL UNIQUE
);

-- ===== Nhóm 2: bảng nghiệp vụ CÓ tenant_id =====

-- (TBL-07) Một user có thể thuộc nhiều tenant
CREATE TABLE {schema}.memberships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES {schema}.tenants (id),
    user_id uuid NOT NULL REFERENCES {schema}.users (id),
    role text NOT NULL,
    UNIQUE (tenant_id, user_id)
);

CREATE TABLE {schema}.orders (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES {schema}.tenants (id),
    code text NOT NULL,
    UNIQUE (tenant_id, id),      -- cần cho FK kép từ bảng con
    UNIQUE (tenant_id, code)
);

-- (TBL-04) Bảng con: có tenant_id riêng + FK kép
CREATE TABLE {schema}.order_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    order_id uuid NOT NULL,
    sku text NOT NULL,
    qty integer NOT NULL CHECK (qty > 0),
    FOREIGN KEY (tenant_id, order_id) REFERENCES {schema}.orders (tenant_id, id)
);

CREATE TABLE {schema}.products (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES {schema}.tenants (id),
    name text NOT NULL,
    UNIQUE (tenant_id, id)
);
CREATE TABLE {schema}.tags (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES {schema}.tenants (id),
    name text NOT NULL,
    UNIQUE (tenant_id, id)
);

-- (TBL-05) Bảng nối many-to-many: tenant_id + FK kép về cả hai phía
CREATE TABLE {schema}.product_tags (
    tenant_id uuid NOT NULL,
    product_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    PRIMARY KEY (tenant_id, product_id, tag_id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES {schema}.products (tenant_id, id),
    FOREIGN KEY (tenant_id, tag_id) REFERENCES {schema}.tags (tenant_id, id)
);

-- ===== Row Level Security =====
-- Điều kiện lọc: tenant lấy từ app.tenant_id; nếu chưa đặt (NULL hoặc '') thì không khớp dòng nào.

ALTER TABLE {schema}.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE {schema}.tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON {schema}.tenants
    USING (id = nullif(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (id = nullif(current_setting('app.tenant_id', true), '')::uuid);

ALTER TABLE {schema}.memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE {schema}.memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON {schema}.memberships
    USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);

ALTER TABLE {schema}.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE {schema}.orders FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON {schema}.orders
    USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);

ALTER TABLE {schema}.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE {schema}.order_items FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON {schema}.order_items
    USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);

ALTER TABLE {schema}.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE {schema}.products FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON {schema}.products
    USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);

ALTER TABLE {schema}.tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE {schema}.tags FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON {schema}.tags
    USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);

ALTER TABLE {schema}.product_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE {schema}.product_tags FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON {schema}.product_tags
    USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);

-- ===== Phân quyền cho app_user (hẹp, theo nguyên tắc tối thiểu) =====
GRANT SELECT ON {schema}.countries, {schema}.plans, {schema}.feature_flags, {schema}.tenants
    TO {app_role};
GRANT SELECT, INSERT, UPDATE, DELETE
    ON {schema}.memberships, {schema}.orders, {schema}.order_items,
       {schema}.products, {schema}.tags, {schema}.product_tags
    TO {app_role};
-- users, schema_migrations, job_queue: KHÔNG cấp gì cho app_user

RESET ROLE;

-- ===== Dữ liệu seed (chạy bằng superuser nên bỏ qua RLS) =====
INSERT INTO {schema}.countries (code, name) VALUES ('VN', 'Vietnam'), ('LA', 'Laos'), ('US', 'United States');
INSERT INTO {schema}.plans (code, name, monthly_price_usd) VALUES ('free', 'Free', 0), ('pro', 'Pro', 49);
INSERT INTO {schema}.feature_flags (key, enabled) VALUES ('new_checkout', false), ('beta_reports', true);
INSERT INTO {schema}.schema_migrations (version) VALUES ('20260101000000'), ('20260301000000');
INSERT INTO {schema}.job_queue (kind, payload) VALUES ('send_email', 'tenant=A user=1'), ('rebuild_index', 'tenant=B');

INSERT INTO {schema}.tenants (id, name, plan_code) VALUES
    ('{tenant_a}', 'Acme Logistics', 'pro'),
    ('{tenant_b}', 'Borealis Retail', 'free');

INSERT INTO {schema}.users (id, email) VALUES
    ('{user_1}', 'consultant@example.com'),
    ('{user_2}', 'alice@acme.example'),
    ('{user_3}', 'bob@borealis.example');

INSERT INTO {schema}.memberships (tenant_id, user_id, role) VALUES
    ('{tenant_a}', '{user_1}', 'admin'),
    ('{tenant_a}', '{user_2}', 'owner'),
    ('{tenant_b}', '{user_1}', 'viewer'),
    ('{tenant_b}', '{user_3}', 'owner');

INSERT INTO {schema}.orders (id, tenant_id, code) VALUES
    ('{order_a1}', '{tenant_a}', 'A-0001'),
    ('{order_a2}', '{tenant_a}', 'A-0002'),
    ('{order_b1}', '{tenant_b}', 'B-0001');

INSERT INTO {schema}.order_items (tenant_id, order_id, sku, qty) VALUES
    ('{tenant_a}', '{order_a1}', 'PALLET-01', 4),
    ('{tenant_a}', '{order_a1}', 'PALLET-02', 1),
    ('{tenant_a}', '{order_a2}', 'CRATE-09', 7),
    ('{tenant_b}', '{order_b1}', 'SHIRT-M', 20),
    ('{tenant_b}', '{order_b1}', 'SHIRT-L', 15);

INSERT INTO {schema}.products (id, tenant_id, name) VALUES
    ('{product_a1}', '{tenant_a}', 'Forklift'),
    ('{product_b1}', '{tenant_b}', 'T-shirt');

INSERT INTO {schema}.tags (id, tenant_id, name) VALUES
    ('{tag_a1}', '{tenant_a}', 'heavy'),
    ('{tag_a2}', '{tenant_a}', 'fragile'),
    ('{tag_b1}', '{tenant_b}', 'apparel');

INSERT INTO {schema}.product_tags (tenant_id, product_id, tag_id) VALUES
    ('{tenant_a}', '{product_a1}', '{tag_a1}'),
    ('{tenant_b}', '{product_b1}', '{tag_b1}');
