-- Consulta acotada; no abre SELECT directo ni permisos de operación de compras.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

create or replace function public.staff_purchase_report(
    requested_billar_id text,
    start_at timestamptz,
    end_at timestamptz,
    before_id bigint default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    result jsonb;
begin
    if not public.has_staff_module_access(requested_billar_id, 'reports_purchases') then
        raise exception 'Sin permiso para consultar informes de compras.' using errcode = '42501';
    end if;
    if start_at is null or end_at is null or not isfinite(start_at) or not isfinite(end_at)
       or end_at <= start_at or end_at - start_at > interval '366 days'
       or (before_id is not null and before_id <= 0) then
        raise exception 'Rango o página del informe inválidos.' using errcode = '22023';
    end if;
    with filtered as materialized (
        select p.id, p.billar_id, p.date::timestamptz as date, p.reference, p.total,
               p.payment_condition, p.payment_method,
               coalesce(p.paid_amount,
                   case when p.payment_condition = 'credito' then 0 else p.total end) as paid_amount,
               coalesce(p.balance_due,
                   case when p.payment_condition = 'credito' then p.total else 0 end) as balance_due,
               v.name as provider_name
        from public.purchases p
        left join public.providers v on v.id = p.provider_id and v.billar_id = p.billar_id
        where p.billar_id = requested_billar_id
          and p.date::timestamptz >= start_at and p.date::timestamptz < end_at
          and not coalesce(p.cancelled, false)
    ), page as (
        select * from filtered where before_id is null or id < before_id
        order by id desc limit 51
    ), shown as (
        select * from page order by id desc limit 50
    )
    select jsonb_build_object(
        'billar_id', requested_billar_id,
        'count', (select count(*) from filtered),
        'total', (select coalesce(sum(total), 0) from filtered),
        'paid', (select coalesce(sum(paid_amount), 0) from filtered),
        'balance', (select coalesce(sum(balance_due), 0) from filtered),
        'items', (select coalesce(jsonb_agg(to_jsonb(shown) order by id desc), '[]'::jsonb) from shown),
        'has_more', (select count(*) > 50 from page)
    ) into result;
    return result;
end;
$$;

revoke all on function public.staff_purchase_report(text, timestamptz, timestamptz, bigint)
    from public, anon, authenticated;
grant execute on function public.staff_purchase_report(text, timestamptz, timestamptz, bigint)
    to authenticated;
notify pgrst, 'reload schema';
commit;
