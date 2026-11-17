const fs = require('node:fs');
const path = require('node:path');

const sources = [
  'provider_credit_terms_partial.sql',
  'purchase_payment_terms_partial.sql',
  'owner_transaction_sync_partial.sql',
  'staff_account_creation_partial.sql',
  'staff_module_guards_partial.sql',
  'staff_sales_guards_partial.sql',
  'staff_inventory_guards_partial.sql',
  'staff_purchases_guards_partial.sql',
  'staff_sale_recording_partial.sql',
  'staff_provider_operations_partial.sql',
  'staff_purchase_recording_partial.sql',
  'staff_purchase_resolution_partial.sql',
  'staff_business_profile.sql',
];

const preflight = `
lock table public.business_memberships in share row exclusive mode;
do $preflight$
declare
    table_name text;
    column_info record;
begin
    if exists (select 1 from public.business_memberships where username is not null) then
        raise exception 'Este lote es solo para preparar un proyecto sin cuentas de personal. No continuar con personal existente.';
    end if;
    if to_regprocedure('public.has_billar_role(text,text[])') is null then
        raise exception 'Falta el control de identidad por billar.';
    end if;
    for column_info in select * from (values
        ('business_memberships', 'username'), ('business_memberships', 'full_name'),
        ('business_memberships', 'job_title'), ('business_memberships', 'allowed_modules'),
        ('business_memberships', 'must_change_password'), ('business_memberships', 'staff_revision'),
        ('products', 'stock_revision'), ('providers', 'is_active'),
        ('sales_history', 'source_module')
    ) as required(table_name, column_name) loop
        if not exists (select 1 from pg_attribute
            where attrelid = to_regclass('public.' || column_info.table_name)
              and attname = column_info.column_name and attnum > 0 and not attisdropped) then
            raise exception 'Falta el prerrequisito public.%.%.', column_info.table_name, column_info.column_name;
        end if;
    end loop;
    foreach table_name in array array[
        'billar_settings', 'business_memberships', 'billiard_tables',
        'cash_outflow_concepts', 'cash_outflows', 'cashier_sessions', 'categories',
        'inventory_movements', 'match_results', 'pending_sales', 'products',
        'providers', 'purchases', 'sales_history', 'billar_tournaments',
        'personal_clients', 'personal_customer_accounts', 'players',
        'sale_details', 'purchase_details', 'promo_items', 'provider_products'
    ] loop
        if not exists (select 1 from pg_class
            where oid = to_regclass('public.' || table_name) and relrowsecurity)
           or not exists (select 1 from pg_policy
            where polrelid = to_regclass('public.' || table_name)
              and polname = 'owner_no_anon' and not polpermissive
              and polcmd = '*' and 'anon'::regrole = any(polroles)
              and pg_get_expr(polqual, polrelid) = 'false'
              and pg_get_expr(polwithcheck, polrelid) = 'false') then
            raise exception 'Falta la proteccion base de public.%. No se instala personal.', table_name;
        end if;
    end loop;
    if (select count(*) from storage.buckets
        where id in ('player_avatars', 'product_images', 'promo_images') and not public) <> 3 then
        raise exception 'Los tres buckets deben seguir privados antes de preparar personal.';
    end if;
end;
$preflight$;
`;

const seal = `
do $seal$
declare
    function_name text;
    endpoint record;
begin
    foreach function_name in array array[
        'staff_sale_products', 'record_staff_sale', 'get_staff_sale_reconciliation',
        'reserve_staff_account', 'find_staff_creation_auth_user', 'finalize_staff_account',
        'stop_staff_password_recovery', 'complete_staff_password_change',
        'list_staff_accounts', 'update_staff_account', 'apply_staff_provider_operation',
        'record_staff_purchase', 'resolve_staff_purchase_request', 'staff_business_profile'
    ] loop
        if not exists (select 1 from pg_proc
            where pronamespace = 'public'::regnamespace and proname = function_name) then
            raise exception 'No se instalo la funcion %. Se revierte el lote.', function_name;
        end if;
        for endpoint in select oid, proname, pg_get_function_identity_arguments(oid) as arguments
            from pg_proc where pronamespace = 'public'::regnamespace and proname = function_name loop
            execute format('revoke all on function public.%I(%s) from public, anon, authenticated',
                endpoint.proname, endpoint.arguments);
            if has_function_privilege('authenticated', endpoint.oid, 'EXECUTE')
               or has_function_privilege('anon', endpoint.oid, 'EXECUTE') then
                raise exception 'No se pudo cerrar el acceso a %. Se revierte el lote.', function_name;
            end if;
        end loop;
    end loop;
end;
$seal$;
`;

function unwrap(sql, file) {
  const boundaries = sql.match(/^[ \t]*(?:begin|commit|rollback|savepoint|release|start transaction)\b[^\r\n]*;[ \t]*\r?$/gim);
  if (boundaries?.length !== 2 ||
      boundaries[0].trim().toLowerCase() !== 'begin;' ||
      boundaries[1].trim().toLowerCase() !== 'commit;' ||
      !/commit;\s*$/i.test(sql)) {
    throw new Error(`Unexpected transaction boundaries in ${file}; refusing to generate rollout.`);
  }
  return sql.replace(/^[ \t]*begin;[ \t]*\r?$/im, '')
    .replace(/^[ \t]*commit;[ \t]*\r?$/im, '').trim();
}

function buildStaffRollout() {
  const sections = sources.map(file =>
    `-- SOURCE: ${file}\n${unwrap(fs.readFileSync(path.join(__dirname, file), 'utf8'), file)}\n`);
  const diagnostic = fs.readFileSync(path.join(__dirname, 'staff_rollout_diagnostic.sql'), 'utf8');
  return `-- GENERATED by node supabase\\build_staff_rollout.cjs; do not edit this file.
-- Preparacion agrupada, NO activacion de roles. Ejecutar el archivo COMPLETO.
-- Cerrar primero la app en los dispositivos para evitar bloqueos de operaciones.
-- Los avisos de preparacion de cada fuente siguen vigentes para su activacion.
-- Una sola transaccion: cualquier error ANTES de COMMIT revierte la instalacion.
-- No crea cuentas ni borra datos. Conserva privados los buckets y sus politicas.
-- Agrega restricciones de escritura de avatares; no cambia flags de cliente/Edge.
-- Al terminar devuelve diagnostic. Ante un error: ROLLBACK; y revisar el error.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';
${preflight}
${sections.join('\n')}
${seal}
notify pgrst, 'reload schema';
commit;

${diagnostic}`;
}

if (require.main === module) {
  const output = path.join(__dirname, 'staff_rollout_install.sql');
  fs.writeFileSync(output, buildStaffRollout());
  console.log(`Generated ${output}`);
}

module.exports = { buildStaffRollout };
