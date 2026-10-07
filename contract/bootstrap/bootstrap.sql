-- Biến :db, :mig, :migpw, :app, :apppw do bootstrap.sh truyền qua psql -v
-- role: không superuser, không BYPASSRLS
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOBYPASSRLS', :'mig')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'mig') \gexec
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOBYPASSRLS', :'app')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app') \gexec
-- đồng bộ password theo secret (xoay password chỉ cần chạy lại Job)
SELECT format('ALTER ROLE %I PASSWORD %L', :'mig', :'migpw') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'app', :'apppw') \gexec
-- database: owner là migrator
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'mig')
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I, %I', :'db', :'app', :'mig') \gexec