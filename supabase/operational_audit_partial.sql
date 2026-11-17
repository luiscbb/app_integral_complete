-- Partial preparation only. Do not deploy until the clients, business RLS,
-- offline provenance and staff workflows are validated together.
-- actor_id identifies the authenticated uploader, not necessarily the person
-- who originally performed an old offline operation.
-- Requires add_player_registration.sql and add_staff_account_fields.sql.
begin;

create table if not exists public.operational_audit (
    id bigint generated always as identity primary key,
    billar_id text not null,
    actor_id uuid,
    entity_type text not null,
    entity_id text not null,
    operation text not null check (operation in ('INSERT', 'UPDATE', 'DELETE')),
    changed_fields text[] not null,
    old_values jsonb,
    new_values jsonb,
    recorded_at timestamptz not null default clock_timestamp()
);

alter table public.operational_audit enable row level security;
revoke all on public.operational_audit from public, anon, authenticated;
grant select on public.operational_audit to authenticated;

create or replace function public.can_read_operational_audit(requested_billar_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1 from public.business_memberships membership
        where membership.user_id = auth.uid()
          and membership.billar_id = requested_billar_id
          and membership.role = 'admin'
          and membership.is_active
          and not membership.must_change_password
    );
$$;
revoke all on function public.can_read_operational_audit(text) from public, anon, authenticated;
grant execute on function public.can_read_operational_audit(text) to authenticated;

drop policy if exists operational_audit_admin_select on public.operational_audit;
create policy operational_audit_admin_select on public.operational_audit
for select to authenticated using (public.can_read_operational_audit(billar_id));

create or replace function public.record_operational_audit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    previous jsonb;
    current_row jsonb;
    previous_values jsonb;
    current_values jsonb;
    fields text[];
    visible_fields text[];
    old_business text;
    new_business text;
    record_id text;
begin
    if tg_op <> 'INSERT' then previous := to_jsonb(old); end if;
    if tg_op <> 'DELETE' then current_row := to_jsonb(new); end if;
    old_business := previous ->> 'billar_id';
    new_business := current_row ->> 'billar_id';
    record_id := coalesce(current_row ->> 'id', previous ->> 'id');
    if record_id is null
       or (previous is not null and (old_business is null or btrim(old_business) = ''))
       or (current_row is not null and (new_business is null or btrim(new_business) = '')) then
        raise exception 'No se puede identificar el registro de auditoría.' using errcode = '23514';
    end if;

    visible_fields := case tg_table_name
        when 'sales_history' then array['type', 'source_module', 'total', 'paid', 'payment_method', 'cancelled']
        when 'purchases' then array['provider_id', 'total', 'cash_source', 'cancelled']
        when 'products' then array['name', 'stock', 'price', 'cost', 'is_active']
        when 'inventory_movements' then array['product_id', 'movement_type', 'quantity', 'unit_cost', 'unit_price', 'reference_id', 'reference_type']
        when 'cash_outflows' then array['outflow_type', 'amount', 'payment_method']
        when 'billar_settings' then array['business_name', 'table_count', 'hourly_rate', 'allow_negative_stock_sales']
        else null
    end;
    if visible_fields is null then
        raise exception 'Tabla de auditoría no admitida.' using errcode = '22023';
    end if;

    select coalesce(array_agg(key order by key), array[]::text[]) into fields
    from (
        select key from jsonb_object_keys(coalesce(previous, '{}'::jsonb)) as keys(key)
        union
        select key from jsonb_object_keys(coalesce(current_row, '{}'::jsonb)) as keys(key)
    ) keys
    where key not in ('updated_at', 'synced', 'cloud_id')
      and (previous -> key) is distinct from (current_row -> key);
    if tg_op = 'UPDATE' and cardinality(fields) = 0 then return new; end if;

    if previous is not null then
        select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into previous_values
        from jsonb_each(previous) where key = any (visible_fields);
    end if;
    if current_row is not null then
        select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into current_values
        from jsonb_each(current_row) where key = any (visible_fields);
    end if;

    if old_business is not null and new_business is not null and old_business <> new_business then
        insert into public.operational_audit (
            billar_id, actor_id, entity_type, entity_id, operation, changed_fields, old_values
        ) values (old_business, auth.uid(), tg_table_name, record_id, 'DELETE', fields, previous_values);
        insert into public.operational_audit (
            billar_id, actor_id, entity_type, entity_id, operation, changed_fields, new_values
        ) values (new_business, auth.uid(), tg_table_name, record_id, 'INSERT', fields, current_values);
    else
        insert into public.operational_audit (
            billar_id, actor_id, entity_type, entity_id, operation, changed_fields, old_values, new_values
        ) values (
            coalesce(new_business, old_business), auth.uid(), tg_table_name, record_id,
            tg_op, fields, previous_values, current_values
        );
    end if;
    if tg_op = 'DELETE' then return old; end if;
    return new;
end;
$$;
revoke all on function public.record_operational_audit() from public, anon, authenticated;

do $$
declare target text;
begin
    foreach target in array array[
        'sales_history', 'purchases', 'products', 'inventory_movements',
        'cash_outflows', 'billar_settings'
    ] loop
        execute format('drop trigger if exists operational_audit_changes on public.%I', target);
        execute format(
            'create trigger operational_audit_changes after insert or update or delete on public.%I '
            'for each row execute function public.record_operational_audit()', target
        );
    end loop;
end;
$$;
commit;
