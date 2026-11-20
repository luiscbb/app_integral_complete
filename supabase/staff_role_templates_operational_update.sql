-- Incremental update for role templates already installed.
-- Adds Mesas/Comandas action permissions; does not change membership rows.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

lock table public.business_memberships in share row exclusive mode;
alter table public.business_memberships
    drop constraint if exists business_memberships_allowed_modules_valid;
alter table public.business_memberships
    add constraint business_memberships_allowed_modules_valid
    check (
        allowed_modules <@ array[
            'quick_sale', 'billiard_tables', 'dine_in',
            'billiard_tables_open', 'billiard_tables_consume',
            'billiard_tables_charge', 'billiard_tables_view_all',
            'dine_in_open', 'dine_in_consume',
            'dine_in_charge', 'dine_in_view_all',
            'personal_account', 'inventory', 'purchases',
            'reports', 'reports_sales', 'reports_purchases',
            'reports_cash_flow', 'reports_kardex', 'reports_profit',
            'players', 'settings'
        ]::text[]
        and array_position(allowed_modules, null) is null
        and ('billiard_tables' = any(allowed_modules)) is not distinct from (
            allowed_modules && array[
                'billiard_tables_open', 'billiard_tables_consume',
                'billiard_tables_charge', 'billiard_tables_view_all'
            ]::text[]
        )
        and ('dine_in' = any(allowed_modules)) is not distinct from (
            allowed_modules && array[
                'dine_in_open', 'dine_in_consume',
                'dine_in_charge', 'dine_in_view_all'
            ]::text[]
        )
    );

create or replace function public.staff_role_template_save(
    requested_billar_id text, template_id uuid, expected_revision bigint,
    template_name text, template_modules text[]
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    result public.staff_role_templates%rowtype;
    normalized_modules text[];
begin
    perform 1 from public.business_memberships m
    where m.user_id = auth.uid() and m.billar_id = requested_billar_id
      and m.role = 'admin' and m.is_active and not m.must_change_password
    for share;
    if not found then
        raise exception 'Solo un administrador activo puede gestionar roles.' using errcode = '42501';
    end if;
    if template_name is null or length(btrim(template_name)) not between 1 and 80
       or template_modules is null or array_position(template_modules, null) is not null
       or not template_modules <@ array[
           'quick_sale',
           'billiard_tables', 'billiard_tables_open', 'billiard_tables_consume',
           'billiard_tables_charge', 'billiard_tables_view_all',
           'dine_in', 'dine_in_open', 'dine_in_consume',
           'dine_in_charge', 'dine_in_view_all',
           'inventory', 'purchases', 'reports_sales',
           'reports_purchases', 'reports_cash_flow', 'reports_kardex', 'reports_profit'
       ]::text[]
       or ('billiard_tables' = any(template_modules)) is distinct from (
           template_modules && array[
               'billiard_tables_open', 'billiard_tables_consume',
               'billiard_tables_charge', 'billiard_tables_view_all'
           ]::text[]
       )
       or ('dine_in' = any(template_modules)) is distinct from (
           template_modules && array[
               'dine_in_open', 'dine_in_consume',
               'dine_in_charge', 'dine_in_view_all'
           ]::text[]
       )
       or (template_id is null) <> (expected_revision is null)
       or expected_revision < 0 then
        raise exception 'Datos de plantilla inválidos.' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct item order by item), '{}'::text[])
      into normalized_modules from unnest(template_modules) item;
    if template_id is null then
        insert into public.staff_role_templates (billar_id, name, modules)
        values (requested_billar_id, btrim(template_name), normalized_modules)
        returning * into result;
    else
        update public.staff_role_templates t
        set name = btrim(template_name), modules = normalized_modules,
            revision = t.revision + 1, updated_at = now()
        where t.id = template_id and t.billar_id = requested_billar_id
          and t.revision = expected_revision
        returning * into result;
        if not found then
            raise exception 'La plantilla cambió o ya no existe. Vuelve a cargarla.' using errcode = '40001';
        end if;
    end if;
    return jsonb_build_object('id', result.id, 'billar_id', result.billar_id,
        'name', result.name, 'modules', result.modules, 'revision', result.revision);
end;
$$;

revoke all on function public.staff_role_template_save(text,uuid,bigint,text,text[])
    from public, anon, authenticated;
grant execute on function public.staff_role_template_save(text,uuid,bigint,text,text[])
    to authenticated;

notify pgrst, 'reload schema';
commit;
