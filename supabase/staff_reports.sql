-- Subcategorias independientes; no concede SELECT directo ni operaciones.
-- Requiere shared_cash.sql para incluir aportes y gastos de caja compartida.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

create or replace function public.staff_read_report(
    requested_billar_id text, requested_report text,
    start_at timestamptz, end_at timestamptz, before_id bigint default null
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    metrics jsonb := '{}'::jsonb;
    items jsonb := '[]'::jsonb;
    report_count bigint := 0;
    has_more boolean := false;
    incomplete_expenses boolean := false;
    cash jsonb;
    total_sales numeric;
    total_cost numeric;
    expenses numeric;
    costs_available boolean;
begin
    if requested_report is null or requested_report not in
        ('reports_sales','reports_cash_flow','reports_kardex','reports_profit')
       or not public.has_staff_module_access(requested_billar_id, requested_report) then
        raise exception 'Sin permiso para consultar este informe.' using errcode = '42501';
    end if;
    if start_at is null or end_at is null or not isfinite(start_at) or not isfinite(end_at)
       or end_at <= start_at or end_at - start_at > interval '366 days'
       or (before_id is not null and before_id <= 0) then
        raise exception 'Rango o pagina del informe invalidos.' using errcode = '22023';
    end if;
    if requested_report = 'reports_sales' then
        with filtered as materialized (
            select id, billar_id, date::timestamptz as date,
                coalesce(payment_method, 'Sin forma de pago') as label,
                total as amount, ''::text as details,
                least(total, coalesce(paid, total)) as paid
            from public.sales_history where billar_id = requested_billar_id
              and not coalesce(cancelled, false)
              and date::timestamptz >= start_at and date::timestamptz < end_at
        ), page as (
            select id,billar_id,date,label,amount,details from filtered
            where before_id is null or id < before_id order by id desc limit 51
        )
        select count(*), jsonb_build_object('total', coalesce(sum(amount::numeric),0), 'paid', coalesce(sum(paid::numeric),0)),
            (select coalesce(jsonb_agg(to_jsonb(p) order by id desc), '[]'::jsonb)
                from (select * from page order by id desc limit 50) p),
            (select count(*) > 50 from page)
        into report_count,metrics,items,has_more from filtered;
    elsif requested_report = 'reports_kardex' then
        with filtered as materialized (
            select m.id, m.billar_id, m.created_at as date,
                coalesce(p.name, 'Producto no disponible') as label,
                m.quantity as amount, m.movement_type as details
            from public.inventory_movements m
            left join public.products p on p.id = m.product_id and p.billar_id = m.billar_id
            where m.billar_id = requested_billar_id and m.created_at >= start_at and m.created_at < end_at
        ), page as (
            select * from filtered where before_id is null or id < before_id
            order by id desc limit 51
        )
        select count(*),
            (select coalesce(jsonb_agg(to_jsonb(p) order by id desc), '[]'::jsonb)
                from (select * from page order by id desc limit 50) p),
            (select count(*) > 50 from page)
        into report_count,items,has_more from filtered;
    elsif requested_report = 'reports_cash_flow' then
        cash := public.cash_shared_summary(requested_billar_id, start_at, end_at);
        metrics := jsonb_build_object('sales',cash->'sales','purchases',cash->'purchases',
            'inflows',cash->'inflows','outflows',cash->'outflows',
            'netCash',cash->'netCash','netFlow',cash->'netFlow');
        select (select count(*) from public.sales_history where billar_id = requested_billar_id
                    and not coalesce(cancelled,false) and date::timestamptz >= start_at and date::timestamptz < end_at)
            + (select count(*) from public.purchases where billar_id = requested_billar_id
                    and not coalesce(cancelled,false) and date::timestamptz >= start_at and date::timestamptz < end_at)
            + (select count(*) from public.cash_outflows where billar_id = requested_billar_id
                    and created_at >= start_at and created_at < end_at)
            + (select count(*) from public.cash_shared_movements where billar_id = requested_billar_id
                    and created_at >= start_at and created_at < end_at)
        into report_count;
    else
        select count(*), coalesce(sum(s.total::numeric),0) into report_count,total_sales
        from public.sales_history s where s.billar_id = requested_billar_id
          and not coalesce(s.cancelled,false) and s.date::timestamptz >= start_at and s.date::timestamptz < end_at;
        select not exists (
            select 1 from public.sales_history s where s.billar_id = requested_billar_id
              and not coalesce(s.cancelled,false) and s.date::timestamptz >= start_at and s.date::timestamptz < end_at
              and (not exists (select 1 from public.sale_details d where d.sale_id = s.id and not coalesce(d.cancelled,false))
                or exists (select 1 from public.sale_details d where d.sale_id = s.id and not coalesce(d.cancelled,false)
                    and (d.cost_at_sale is null or d.cost_at_sale < 0 or d.quantity is null)))
        ) into costs_available;
        select coalesce(sum(d.quantity::numeric * d.cost_at_sale),0) into total_cost
        from public.sale_details d join public.sales_history s on s.id = d.sale_id
        where s.billar_id = requested_billar_id and not coalesce(s.cancelled,false) and not coalesce(d.cancelled,false)
          and s.date::timestamptz >= start_at and s.date::timestamptz < end_at;
        -- Los movimientos antiguos no distinguen gasto de retiro: no inventar utilidad.
        select exists (select 1 from public.cash_outflows where billar_id = requested_billar_id
            and created_at >= start_at and created_at < end_at) into incomplete_expenses;
        select coalesce(sum(amount),0) into expenses from public.cash_shared_movements
        where billar_id = requested_billar_id and kind = 'expense'
          and created_at >= start_at and created_at < end_at;
        metrics := jsonb_build_object('sales',total_sales,'expenses',expenses,
            'cost',case when costs_available then total_cost else null end,
            'profit',case when costs_available and not incomplete_expenses then total_sales-total_cost-expenses else null end);
    end if;
    return jsonb_build_object('billar_id',requested_billar_id,'report',requested_report,
        'count',report_count,'metrics',metrics,'items',items,'has_more',has_more,
        'incomplete_expenses',incomplete_expenses);
end;
$$;

revoke all on function public.staff_read_report(text,text,timestamptz,timestamptz,bigint)
    from public, anon, authenticated;
grant execute on function public.staff_read_report(text,text,timestamptz,timestamptz,bigint) to authenticated;
notify pgrst, 'reload schema';
commit;
