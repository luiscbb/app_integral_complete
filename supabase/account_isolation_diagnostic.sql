-- Solo lectura. No incluye filas de negocio, identificadores ni credenciales.
with app_tables as (
  select c.oid, c.relname, c.relrowsecurity, c.relforcerowsecurity
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p')
),
table_summary as (
  select t.relname as name, t.relrowsecurity as rls_enabled,
         t.relforcerowsecurity as rls_forced,
         exists (
           select 1 from pg_attribute a
           where a.attrelid = t.oid and a.attname = 'billar_id'
             and a.attnum > 0 and not a.attisdropped
         ) as has_billar_id
  from app_tables t
),
broad_policies as (
  select tablename, policyname, permissive, roles, cmd, qual, with_check
  from pg_policies
  where schemaname = 'public'
    and (qual = 'true' or with_check = 'true')
),
sync_ids as (
  select table_name, is_identity, identity_generation, column_default
  from information_schema.columns
  where table_schema = 'public' and column_name = 'id'
    and table_name in ('sales_history', 'sale_details', 'purchases', 'purchase_details')
)
select jsonb_build_object(
  'tables', (select jsonb_agg(to_jsonb(t) order by name) from table_summary t),
  'unrestricted_policies', (select jsonb_agg(to_jsonb(p) order by tablename, policyname) from broad_policies p),
  'transaction_ids', (select jsonb_agg(to_jsonb(i) order by table_name) from sync_ids i)
) as diagnostic;
