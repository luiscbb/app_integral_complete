-- Ejecutar COMPLETO solo despues de desplegar player-admin y configurar el
-- secreto HMAC de creacion. Preparar el cliente con STAFF_PILOT_ENABLED=true.
-- No crea cuentas. Habilita el piloto base; los RPC de Mesas/Comandas requieren
-- despliegue separado aunque sus permisos ya se acepten en las cuentas.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

lock table public.business_memberships in share row exclusive mode;
do $preflight$
declare
    table_name text;
begin
    if exists (select 1 from public.business_memberships
        where username is not null and (
            role <> 'manager' or cardinality(allowed_modules) = 0
            or not allowed_modules <@ array[
                'quick_sale',
                'billiard_tables', 'billiard_tables_open', 'billiard_tables_consume',
                'billiard_tables_charge', 'billiard_tables_view_all',
                'dine_in', 'dine_in_open', 'dine_in_consume',
                'dine_in_charge', 'dine_in_view_all',
                'inventory', 'purchases', 'reports_purchases','reports_sales',
                'reports_cash_flow','reports_kardex','reports_profit'
            ]::text[]
            or ('billiard_tables' = any(allowed_modules)) is distinct from (
                allowed_modules && array[
                    'billiard_tables_open', 'billiard_tables_consume',
                    'billiard_tables_charge', 'billiard_tables_view_all'
                ]::text[]
            )
            or ('dine_in' = any(allowed_modules)) is distinct from (
                allowed_modules && array[
                    'dine_in_open', 'dine_in_consume',
                    'dine_in_charge', 'dine_in_view_all'
                ]::text[]
            )
        )) then
        raise exception 'Hay cuentas con modulos fuera del piloto. Revisarlas antes de activar.';
    end if;
    foreach table_name in array array[
        'business_memberships', 'staff_account_requests', 'staff_account_audit',
        'staff_sale_requests', 'staff_sale_stock_products', 'staff_sale_audit',
        'staff_provider_requests', 'staff_provider_audit',
        'staff_purchase_requests', 'staff_purchase_audit'
    ] loop
        if not exists (select 1 from pg_class
            where oid = to_regclass('public.' || table_name) and relrowsecurity) then
            raise exception 'Falta preparar public.%. No se activa el piloto.', table_name;
        end if;
    end loop;
    if (select count(*) from storage.buckets
        where id in ('player_avatars', 'product_images', 'promo_images') and not public) <> 3 then
        raise exception 'Los buckets deben seguir privados.';
    end if;
end;
$preflight$;

-- Supabase puede conceder EXECUTE explicitamente mediante default privileges.
revoke all on function public.has_staff_module_access(text, text) from public, anon;
revoke all on function public.has_staff_pos_module_access(text, text) from public, anon;
revoke all on function public.can_access_inventory(text, boolean) from public, anon;
grant execute on function public.has_staff_module_access(text, text) to authenticated;
grant execute on function public.has_staff_pos_module_access(text, text) to authenticated;
grant execute on function public.can_access_inventory(text, boolean) to authenticated;

revoke all on function public.staff_sale_products(text) from public, anon;
revoke all on function public.record_staff_sale(uuid, text, text, text, text, text, double precision, double precision, text, jsonb) from public, anon;
revoke all on function public.get_staff_sale_reconciliation(uuid, text) from public, anon;
revoke all on function public.apply_staff_provider_operation(uuid, text, bigint, text, jsonb, bigint[]) from public, anon;
revoke all on function public.record_staff_purchase(uuid, text, bigint, text, text, jsonb) from public, anon;
revoke all on function public.record_staff_purchase(uuid, text, bigint, text, text, jsonb, jsonb) from public, anon;
revoke all on function public.resolve_staff_purchase_request(uuid, text, text, jsonb) from public, anon;
revoke all on function public.list_staff_accounts(text) from public, anon;
revoke all on function public.staff_business_profile(text) from public, anon;

grant execute on function public.staff_sale_products(text) to authenticated;
grant execute on function public.record_staff_sale(uuid, text, text, text, text, text, double precision, double precision, text, jsonb) to authenticated;
grant execute on function public.get_staff_sale_reconciliation(uuid, text) to authenticated;
grant execute on function public.apply_staff_provider_operation(uuid, text, bigint, text, jsonb, bigint[]) to authenticated;
grant execute on function public.record_staff_purchase(uuid, text, bigint, text, text, jsonb) to authenticated;
grant execute on function public.record_staff_purchase(uuid, text, bigint, text, text, jsonb, jsonb) to authenticated;
grant execute on function public.resolve_staff_purchase_request(uuid, text, text, jsonb) to authenticated;
grant execute on function public.list_staff_accounts(text) to authenticated;
grant execute on function public.staff_business_profile(text) to authenticated;
revoke all on function public.staff_purchase_report(text, timestamptz, timestamptz, bigint) from public, anon;
grant execute on function public.staff_purchase_report(text, timestamptz, timestamptz, bigint) to authenticated;
revoke all on function public.staff_read_report(text,text,timestamptz,timestamptz,bigint) from public, anon;
revoke all on function public.cash_shared_state(text,timestamptz,timestamptz,bigint,bigint) from public, anon;
revoke all on function public.cash_shared_apply(text,uuid,text,jsonb) from public, anon;
revoke all on function public.cash_shared_request_status(text,uuid) from public, anon;
grant execute on function public.staff_read_report(text,text,timestamptz,timestamptz,bigint) to authenticated;
grant execute on function public.cash_shared_state(text,timestamptz,timestamptz,bigint,bigint) to authenticated;
grant execute on function public.cash_shared_apply(text,uuid,text,jsonb) to authenticated;
grant execute on function public.cash_shared_request_status(text,uuid) to authenticated;

revoke all on function public.reserve_staff_account(uuid, uuid, text, text, text, text, text[], text, text) from public, anon, authenticated;
revoke all on function public.find_staff_creation_auth_user(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.finalize_staff_account(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.stop_staff_password_recovery(uuid) from public, anon, authenticated;
revoke all on function public.complete_staff_password_change(uuid, text, bigint) from public, anon, authenticated;
revoke all on function public.update_staff_account(uuid, text, uuid, text, text, text[], boolean, bigint) from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;

select jsonb_agg(jsonb_build_object(
    'name', proname,
    'arguments', pg_get_function_identity_arguments(oid),
    'anon_execute', has_function_privilege('anon', oid, 'EXECUTE'),
    'authenticated_execute', has_function_privilege('authenticated', oid, 'EXECUTE'),
    'service_role_execute', has_function_privilege('service_role', oid, 'EXECUTE')
) order by proname, pg_get_function_identity_arguments(oid)) as pilot_permissions
from pg_proc
where pronamespace = 'public'::regnamespace and proname in (
    'has_staff_module_access', 'has_staff_pos_module_access', 'can_access_inventory',
    'staff_sale_products', 'record_staff_sale', 'get_staff_sale_reconciliation',
    'apply_staff_provider_operation', 'record_staff_purchase', 'resolve_staff_purchase_request',
    'list_staff_accounts', 'reserve_staff_account', 'find_staff_creation_auth_user',
    'finalize_staff_account', 'stop_staff_password_recovery',
    'complete_staff_password_change', 'update_staff_account', 'staff_business_profile', 'staff_purchase_report',
    'staff_read_report','cash_shared_state','cash_shared_apply','cash_shared_request_status'
);
