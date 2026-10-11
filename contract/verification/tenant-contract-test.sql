SELECT n.nspname, c.relname
FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
         JOIN pg_attribute a ON a.attrelid = c.oid
    AND a.attname = 'tenant_id' AND NOT a.attisdropped
WHERE c.relkind IN ('r','p')
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity);