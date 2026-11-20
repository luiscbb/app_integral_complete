-- Incremental: plantillas por negocio, sin modificar membresías existentes.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

create table if not exists public.staff_role_templates (
    id uuid primary key default gen_random_uuid(),
    billar_id text not null,
    name text not null,
    modules text[] not null,
    revision bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create unique index if not exists staff_role_templates_billar_name
    on public.staff_role_templates (billar_id, lower(name));
alter table public.staff_role_templates enable row level security;
revoke all on public.staff_role_templates from public, anon, authenticated;

create or replace function public.staff_role_templates_list(requested_billar_id text)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
    perform 1 from public.business_memberships m
    where m.user_id = auth.uid() and m.billar_id = requested_billar_id
      and m.role = 'admin' and m.is_active and not m.must_change_password
    for share;
    if not found then
        raise exception 'Solo un administrador activo puede gestionar roles.' using errcode = '42501';
    end if;
    return coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'billar_id', t.billar_id, 'name', t.name,
        'modules', t.modules, 'revision', t.revision
    ) order by lower(t.name), t.id)
    from public.staff_role_templates t where t.billar_id = requested_billar_id), '[]'::jsonb);
end;
$$;

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

create or replace function public.staff_role_template_delete(
    requested_billar_id text, template_id uuid, expected_revision bigint
)
returns void language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
    perform 1 from public.business_memberships m
    where m.user_id = auth.uid() and m.billar_id = requested_billar_id
      and m.role = 'admin' and m.is_active and not m.must_change_password
    for share;
    if not found then
        raise exception 'Solo un administrador activo puede gestionar roles.' using errcode = '42501';
    end if;
    delete from public.staff_role_templates t
    where t.id = template_id and t.billar_id = requested_billar_id
      and t.revision = expected_revision;
    if not found then
        raise exception 'La plantilla cambió o ya no existe. Vuelve a cargarla.' using errcode = '40001';
    end if;
end;
$$;

revoke all on function public.staff_role_templates_list(text) from public, anon, authenticated;
revoke all on function public.staff_role_template_save(text,uuid,bigint,text,text[]) from public, anon, authenticated;
revoke all on function public.staff_role_template_delete(text,uuid,bigint) from public, anon, authenticated;
grant execute on function public.staff_role_templates_list(text) to authenticated;
grant execute on function public.staff_role_template_save(text,uuid,bigint,text,text[]) to authenticated;
grant execute on function public.staff_role_template_delete(text,uuid,bigint) to authenticated;
notify pgrst, 'reload schema';
commit;
