-- Consulta de solo lectura: no modifica datos ni políticas.
-- Revisa únicamente la estructura necesaria para la sincronización de ventas
-- y compras; no devuelve filas de negocio ni identificadores de usuarios.
with target_tables(name) as (
  values
    ('billar_settings'), ('business_memberships'), ('providers'),
    ('products'), ('sales_history'), ('sale_details'), ('purchases'),
    ('purchase_details')
),
columns_info as (
  select c.table_name, c.column_name, c.ordinal_position, c.data_type,
         c.udt_name, c.is_nullable, c.column_default, c.is_identity,
         c.identity_generation
  from information_schema.columns c
  join target_tables t on t.name = c.table_name
  where c.table_schema = 'public'
),
constraints_info as (
  select r.relname as table_name, con.conname as name,
         pg_get_constraintdef(con.oid) as definition
  from pg_constraint con
  join pg_class r on r.oid = con.conrelid
  join pg_namespace n on n.oid = r.relnamespace
  join target_tables t on t.name = r.relname
  where n.nspname = 'public'
),
policies_info as (
  select tablename as table_name, policyname as name, permissive,
         roles, cmd, qual, with_check
  from pg_policies
  where schemaname = 'public'
    and tablename in (select name from target_tables)
),
triggers_info as (
  select r.relname as table_name, tg.tgname as name,
         pg_get_triggerdef(tg.oid) as definition
  from pg_trigger tg
  join pg_class r on r.oid = tg.tgrelid
  join pg_namespace n on n.oid = r.relnamespace
  join target_tables t on t.name = r.relname
  where n.nspname = 'public' and not tg.tgisinternal
),
functions_info as (
  select name,
         to_regprocedure('public.' || name || '(uuid,text,bigint,jsonb,jsonb)') is not null as installed
  from (values ('sync_owner_sale'), ('sync_owner_purchase'),
               ('sync_owner_purchase_with_payment')) targets(name)
),
tables_info as (
  select t.name, r.relrowsecurity as rls_enabled,
         r.relforcerowsecurity as rls_forced
  from target_tables t
  left join pg_class r on r.relname = t.name
    and r.relnamespace = 'public'::regnamespace
    and r.relkind in ('r', 'p')
)
select jsonb_build_object(
  'functions', (select jsonb_agg(to_jsonb(f) order by name) from functions_info f),
  'tables', (select jsonb_agg(to_jsonb(t) order by name) from tables_info t),
  'columns', (select jsonb_agg(to_jsonb(c) order by table_name, ordinal_position) from columns_info c),
  'constraints', (select jsonb_agg(to_jsonb(c) order by table_name, name) from constraints_info c),
  'policies', (select jsonb_agg(to_jsonb(p) order by table_name, name) from policies_info p),
  'triggers', (select jsonb_agg(to_jsonb(t) order by table_name, name) from triggers_info t)
) as diagnostic;
