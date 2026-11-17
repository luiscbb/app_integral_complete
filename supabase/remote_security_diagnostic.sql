-- Solo lectura: metadatos de seguridad, sin filas de negocio ni credenciales.
-- Los nombres de tablas, políticas y funciones forman parte del resultado.
with app_relations as (
  select c.oid, c.relname, c.relkind, c.relrowsecurity, c.relforcerowsecurity,
         c.reloptions
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
),
relations_info as (
  select r.relname as name, r.relkind as kind,
         r.relrowsecurity as rls_enabled, r.relforcerowsecurity as rls_forced,
         coalesce('security_invoker=true' = any(r.reloptions), false) as security_invoker,
         has_table_privilege('anon', r.oid, 'SELECT') as anon_select,
         has_table_privilege('anon', r.oid, 'INSERT') as anon_insert,
         has_table_privilege('anon', r.oid, 'UPDATE') as anon_update,
         has_table_privilege('anon', r.oid, 'DELETE') as anon_delete
  from app_relations r
),
policies_info as (
  select schemaname, tablename, policyname, permissive, roles, cmd,
         coalesce(qual = 'true', false) as unrestricted_using,
         coalesce(with_check = 'true', false) as unrestricted_check
  from pg_policies
  where schemaname = 'public'
     or (schemaname = 'storage' and tablename = 'objects')
),
definer_functions as (
  select p.proname as name, pg_get_function_identity_arguments(p.oid) as arguments,
         has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
         exists (
           select 1 from unnest(p.proconfig) as setting(value)
           where setting.value like 'search_path=%'
         ) as fixed_search_path
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and p.prokind = 'f'
),
triggers_info as (
  select r.relname as table_name, t.tgname as name,
         t.tgfoid::regprocedure::text as function
  from pg_trigger t
  join app_relations r on r.oid = t.tgrelid
  where not t.tgisinternal
),
storage_info as (
  select id, public from storage.buckets
  where id in ('product_images', 'promo_images', 'player_avatars')
)
select jsonb_build_object(
  'relations', coalesce((select jsonb_agg(to_jsonb(r) order by name) from relations_info r), '[]'::jsonb),
  'policies', coalesce((select jsonb_agg(to_jsonb(p) order by schemaname, tablename, policyname) from policies_info p), '[]'::jsonb),
  'definer_functions', coalesce((select jsonb_agg(to_jsonb(f) order by name, arguments) from definer_functions f), '[]'::jsonb),
  'triggers', coalesce((select jsonb_agg(to_jsonb(t) order by table_name, name) from triggers_info t), '[]'::jsonb),
  'image_buckets', coalesce((select jsonb_agg(to_jsonb(b) order by id) from storage_info b), '[]'::jsonb)
) as diagnostic;
