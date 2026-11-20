-- PREPARACION LOCAL: NO DESPLEGAR NI HABILITAR.
-- Requiere staff_table_service_partial.sql.
begin;

alter table public.staff_table_service_requests
    add column if not exists reviewed_at timestamptz;
alter table public.staff_table_service_requests
    add column if not exists reviewed_by uuid;

create or replace function public.staff_table_review_opening_conflict(
    requested_billar_id text, requested_table_type text, requested_service_id uuid
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    actor uuid := auth.uid();
    permission text;
    service public.staff_table_service_requests%rowtype;
begin
    if actor is null or requested_billar_id is null or btrim(requested_billar_id) = ''
       or requested_table_type is null or requested_table_type not in ('Billar', 'Comanda')
       or requested_service_id is null then
        raise exception 'La revisión del conflicto no es válida.' using errcode = '22023';
    end if;
    permission := case requested_table_type
        when 'Billar' then 'billiard_tables_view_all' else 'dine_in_view_all' end;
    perform public.staff_table_require_permission(requested_billar_id, permission);

    select * into service
    from public.staff_table_service_requests s
    where s.service_id = requested_service_id
      and s.billar_id = requested_billar_id
      and s.table_type = requested_table_type
      and s.state = 'conflict'
    for update;
    if not found then
        raise exception 'La apertura rechazada no está disponible.' using errcode = '42501';
    end if;
    if service.reviewed_at is null then
        update public.staff_table_service_requests
        set reviewed_at = clock_timestamp(), reviewed_by = actor
        where service_id = requested_service_id and billar_id = requested_billar_id
        returning * into service;
    end if;
    return jsonb_build_object(
        'service_id', service.service_id,
        'billar_id', service.billar_id,
        'table_type', service.table_type,
        'state', service.state,
        'reviewed_at', service.reviewed_at,
        'reviewed_by', service.reviewed_by
    );
end;
$$;
revoke all on function public.staff_table_review_opening_conflict(text,text,uuid)
    from public, anon, authenticated;
grant execute on function public.staff_table_review_opening_conflict(text,text,uuid)
    to authenticated;

create or replace function public.staff_table_conflicts(
    requested_billar_id text, requested_table_type text, before_ordinal bigint default null
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    permission text;
    items jsonb;
    has_more boolean;
begin
    if requested_billar_id is null or btrim(requested_billar_id) = ''
       or requested_table_type is null or requested_table_type not in ('Billar', 'Comanda')
       or (before_ordinal is not null and before_ordinal <= 0) then
        raise exception 'Consulta de conflictos inválida.' using errcode = '22023';
    end if;
    permission := case requested_table_type
        when 'Billar' then 'billiard_tables_view_all' else 'dine_in_view_all' end;
    perform public.staff_table_require_permission(requested_billar_id, permission);
    with page as materialized (
        select * from public.staff_table_service_requests s
        where s.billar_id = requested_billar_id and s.table_type = requested_table_type
          and (
              (s.state = 'conflict' and s.reviewed_at is null)
              or (s.state = 'closed' and exists (
                  select 1 from public.staff_table_service_consumptions c
                  where c.billar_id = s.billar_id and c.service_id = s.service_id
                    and c.late
              ))
          )
          and (before_ordinal is null or s.ordinal < before_ordinal)
        order by s.ordinal desc limit 51
    )
    select coalesce((select jsonb_agg(jsonb_build_object(
        'ordinal', p.ordinal, 'service_id', p.service_id, 'billar_id', p.billar_id,
        'actor_id', p.actor_id, 'table_id', p.table_id, 'table_type', p.table_type,
        'opened_at', p.opened_at,
        'reason', case when p.state = 'closed' then 'late_consumption' else 'opening' end
    ) order by p.ordinal desc) from (select * from page order by ordinal desc limit 50) p), '[]'::jsonb),
    (select count(*) > 50 from page)
    into items, has_more;
    return jsonb_build_object(
        'billar_id', requested_billar_id,
        'table_type', requested_table_type,
        'items', items,
        'has_more', has_more
    );
end;
$$;

revoke all on function public.staff_table_conflicts(text,text,bigint)
    from public, anon, authenticated;
grant execute on function public.staff_table_conflicts(text,text,bigint)
    to authenticated;

commit;
