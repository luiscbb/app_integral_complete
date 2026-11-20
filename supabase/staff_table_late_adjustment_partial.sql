-- PREPARACION LOCAL: NO DESPLEGAR NI HABILITAR.
-- Requiere product_stock_conflict_guard_partial.sql,
-- staff_table_service_partial.sql y staff_table_checkout_partial.sql.
begin;

create table if not exists public.staff_table_late_adjustment_requests (
    request_id uuid primary key,
    actor_id uuid not null,
    billar_id text not null,
    service_id uuid not null,
    payload jsonb not null,
    receipt jsonb,
    created_at timestamptz not null default clock_timestamp()
);
alter table public.staff_table_late_adjustment_requests enable row level security;
revoke all on public.staff_table_late_adjustment_requests from public, anon, authenticated;

alter table public.staff_table_service_consumptions
    add column if not exists late_adjustment_request_id uuid;
do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.staff_table_service_consumptions'::regclass
          and conname = 'staff_table_consumption_late_adjustment_fk'
    ) then
        alter table public.staff_table_service_consumptions
            add constraint staff_table_consumption_late_adjustment_fk
            foreign key (late_adjustment_request_id)
            references public.staff_table_late_adjustment_requests(request_id)
            on delete restrict;
    end if;
end;
$$;
create index if not exists staff_table_unadjusted_late_items
    on public.staff_table_service_consumptions (billar_id, service_id, ordinal)
    where late and late_adjustment_request_id is null;

create or replace function public.staff_table_late_adjustment_snapshot(
    requested_billar_id text, requested_table_type text, requested_service_id uuid,
    before_ordinal bigint default null
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    service public.staff_table_service_requests%rowtype;
    revision bigint;
    item_count bigint;
    amount numeric;
    items jsonb;
    has_more boolean;
    permission text;
begin
    if requested_billar_id is null or btrim(requested_billar_id) = ''
       or requested_table_type is null or requested_table_type not in ('Billar', 'Comanda')
       or requested_service_id is null
       or (before_ordinal is not null and before_ordinal <= 0) then
        raise exception 'La consulta de ajuste no es válida.' using errcode = '22023';
    end if;
    permission := case requested_table_type
        when 'Billar' then 'billiard_tables_view_all' else 'dine_in_view_all' end;
    perform public.staff_table_require_permission(requested_billar_id, permission);
    permission := case requested_table_type
        when 'Billar' then 'billiard_tables_charge' else 'dine_in_charge' end;
    perform public.staff_table_require_permission(requested_billar_id, permission);

    select * into service
    from public.staff_table_service_requests s
    where s.service_id = requested_service_id
      and s.billar_id = requested_billar_id
      and s.table_type = requested_table_type
      and s.state = 'closed';
    if not found then
        raise exception 'El servicio cerrado no está disponible.' using errcode = '42501';
    end if;
    select coalesce(max(c.ordinal), 0), count(*),
           coalesce(sum(c.quantity::numeric * c.price::numeric), 0)
    into revision, item_count, amount
    from public.staff_table_service_consumptions c
    where c.service_id = requested_service_id and c.billar_id = requested_billar_id
      and c.late and c.late_adjustment_request_id is null;
    if item_count = 0 then
        raise exception 'El servicio no tiene consumos tardíos pendientes.' using errcode = '55000';
    end if;
    with page as materialized (
        select c.* from public.staff_table_service_consumptions c
        where c.service_id = requested_service_id and c.billar_id = requested_billar_id
          and c.late and c.late_adjustment_request_id is null
          and (before_ordinal is null or c.ordinal < before_ordinal)
        order by c.ordinal desc limit 51
    )
    select coalesce((select jsonb_agg(jsonb_build_object(
        'ordinal', p.ordinal, 'request_id', p.request_id, 'product_id', p.product_id,
        'product_name', p.product_name, 'quantity', p.quantity, 'price', p.price,
        'recorded_at', p.recorded_at
    ) order by p.ordinal desc)
      from (select * from page order by ordinal desc limit 50) p), '[]'::jsonb),
      (select count(*) > 50 from page)
    into items, has_more;
    return jsonb_build_object(
        'billar_id', requested_billar_id,
        'table_type', requested_table_type,
        'service_id', requested_service_id,
        'table_id', service.table_id,
        'actor_id', service.actor_id,
        'revision', revision,
        'item_count', item_count,
        'total', amount,
        'items', items,
        'has_more', has_more
    );
end;
$$;
revoke all on function public.staff_table_late_adjustment_snapshot(text,text,uuid,bigint)
    from public, anon, authenticated;
grant execute on function public.staff_table_late_adjustment_snapshot(text,text,uuid,bigint)
    to authenticated;

create or replace function public.staff_table_adjust_late_consumptions(
    requested_request_id uuid, requested_billar_id text, requested_table_type text,
    requested_service_id uuid, expected_revision bigint, expected_total double precision,
    payment_method text, paid double precision
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    actor uuid := auth.uid();
    permission text;
    payload jsonb;
    request_row public.staff_table_late_adjustment_requests%rowtype;
    service public.staff_table_service_requests%rowtype;
    item record;
    component record;
    product public.products%rowtype;
    revision bigint;
    item_count bigint;
    amount numeric := 0;
    computed_total numeric := 0;
    allow_negative boolean;
    required_stock double precision;
    component_count integer;
    sale_id bigint;
    sale_date timestamptz;
    sale_type text;
    result_receipt jsonb;
    sold_items jsonb := '[]'::jsonb;
    sold_movements jsonb := '[]'::jsonb;
    stock_before jsonb := '{}'::jsonb;
    movement_id bigint;
    previous_revision bigint;
    affected_product_id bigint;
    changed_count bigint;
begin
    if actor is null or requested_request_id is null or requested_service_id is null
       or requested_billar_id is null or btrim(requested_billar_id) = ''
       or requested_table_type is null or requested_table_type not in ('Billar', 'Comanda')
       or expected_revision is null or expected_revision <= 0
       or (expected_total > 0 and expected_total < 'Infinity'::double precision) is not true
       or payment_method is null
       or payment_method not in ('Efectivo', 'Tarjeta', 'Transferencia')
       or (paid >= 0 and paid < 'Infinity'::double precision) is not true then
        raise exception 'Datos del ajuste tardío inválidos.' using errcode = '22023';
    end if;
    permission := case requested_table_type
        when 'Billar' then 'billiard_tables_view_all' else 'dine_in_view_all' end;
    perform public.staff_table_require_permission(requested_billar_id, permission);
    permission := case requested_table_type
        when 'Billar' then 'billiard_tables_charge' else 'dine_in_charge' end;
    perform public.staff_table_require_permission(requested_billar_id, permission);

    payload := jsonb_build_object(
        'billar_id', requested_billar_id, 'table_type', requested_table_type,
        'service_id', requested_service_id, 'revision', expected_revision,
        'total', expected_total, 'payment_method', payment_method, 'paid', paid
    );
    insert into public.staff_table_late_adjustment_requests
        (request_id, actor_id, billar_id, service_id, payload)
    values
        (requested_request_id, actor, requested_billar_id, requested_service_id, payload)
    on conflict (request_id) do nothing;
    select * into strict request_row
    from public.staff_table_late_adjustment_requests r
    where r.request_id = requested_request_id
    for update;
    if request_row.actor_id is distinct from actor
       or request_row.billar_id is distinct from requested_billar_id
       or request_row.service_id is distinct from requested_service_id
       or request_row.payload is distinct from payload then
        raise exception 'El identificador del ajuste ya fue utilizado.' using errcode = '23505';
    end if;
    if request_row.receipt is not null then
        if not exists (
            select 1 from public.sales_history s
            where s.id = (request_row.receipt ->> 'sale_id')::bigint
              and s.billar_id = requested_billar_id and not s.cancelled
        ) then
            raise exception 'La venta del ajuste no está disponible o fue anulada.' using errcode = '55000';
        end if;
        return request_row.receipt;
    end if;

    select * into service
    from public.staff_table_service_requests s
    where s.service_id = requested_service_id
      and s.billar_id = requested_billar_id
      and s.table_type = requested_table_type
      and s.state = 'closed'
    for update;
    if not found then
        raise exception 'El servicio cerrado no está disponible.' using errcode = '42501';
    end if;
    select coalesce(max(c.ordinal), 0), count(*),
           coalesce(sum(c.quantity::numeric * c.price::numeric), 0)
    into revision, item_count, amount
    from public.staff_table_service_consumptions c
    where c.service_id = requested_service_id and c.billar_id = requested_billar_id
      and c.late and c.late_adjustment_request_id is null;
    if revision <> expected_revision then
        raise exception 'Los consumos tardíos cambiaron; vuelve a consultar.' using errcode = 'PST02';
    end if;
    if item_count = 0 or abs(amount - expected_total::numeric) >
       greatest(0.000001::numeric, abs(amount) * 0.0000000001::numeric) then
        raise exception 'El total del ajuste no coincide con los consumos pendientes.' using errcode = '22023';
    end if;
    if paid::numeric < amount then
        raise exception 'El importe recibido debe cubrir el total.' using errcode = '22023';
    end if;
    if (select count(*) from public.billar_settings s
        where s.billar_id = requested_billar_id) <> 1 then
        raise exception 'No hay una configuración única para este billar.' using errcode = '55000';
    end if;
    select s.allow_negative_stock_sales into strict allow_negative
    from public.billar_settings s
    where s.billar_id = requested_billar_id
    for share;

    perform p.id from public.products p
    where p.billar_id = requested_billar_id and p.id in (
        select c.product_id from public.staff_table_service_consumptions c
        where c.service_id = requested_service_id and c.billar_id = requested_billar_id
          and c.late and c.late_adjustment_request_id is null
    )
    order by p.id for update;

    sale_date := clock_timestamp();
    sale_type := 'Ajuste consumo tardio - Mesa ' || service.table_id;
    insert into public.sales_history (
        billar_id, type, source_module, date, payment_method, total, paid, customer_key, cancelled
    ) values (
        requested_billar_id, sale_type,
        case when requested_table_type = 'Comanda' then 'dine_in' else 'billiard_tables' end,
        sale_date::text, payment_method, expected_total, paid, null, false
    ) returning id into sale_id;

    for item in
        select c.* from public.staff_table_service_consumptions c
        where c.service_id = requested_service_id and c.billar_id = requested_billar_id
          and c.late and c.late_adjustment_request_id is null
        order by c.product_id, c.ordinal
        for update
    loop
        select * into product from public.products p
        where p.id = item.product_id and p.billar_id = requested_billar_id and p.is_active;
        if not found then
            raise exception 'El producto no pertenece a este billar o no está activo.' using errcode = '42501';
        end if;
        if (item.quantity > 0 and item.quantity < 'Infinity'::double precision) is not true
           or (item.price >= 0 and item.price < 'Infinity'::double precision) is not true
           or (product.price >= 0 and product.price < 'Infinity'::double precision) is not true
           or (coalesce(product.cost, 0) >= 0 and coalesce(product.cost, 0) < 'Infinity'::double precision) is not true
           or abs(item.price::numeric - product.price::numeric) > 0.000001 then
            raise exception 'El precio o consumo cambió; revisa el ajuste.' using errcode = '22023';
        end if;
        computed_total := computed_total + item.quantity::numeric * item.price::numeric;

        if product.parent_id is not null then
            if product.is_promo <> 0 or product.pieces_per_unit <= 0 then
                raise exception 'La presentación del producto es inválida.' using errcode = '22023';
            end if;
            required_stock := item.quantity * product.pieces_per_unit;
            affected_product_id := product.parent_id;
            select p.stock_revision into strict previous_revision
            from public.products p
            where p.id = affected_product_id and p.billar_id = requested_billar_id
            for update;
            if not (stock_before ? affected_product_id::text) then
                stock_before := stock_before || jsonb_build_object(
                    affected_product_id::text, previous_revision);
            end if;
            update public.products p set stock = p.stock - required_stock,
                stock_revision = p.stock_revision + 1
            where p.id = affected_product_id and p.billar_id = requested_billar_id
              and p.parent_id is null and p.is_promo = 0 and p.is_active
              and p.stock > '-Infinity'::double precision
              and p.stock < 'Infinity'::double precision
              and (allow_negative or p.stock >= required_stock);
            if not found then
                raise exception 'No hay existencias suficientes o el producto padre es inválido.' using errcode = '22023';
            end if;
        elsif product.is_promo = 1 then
            component_count := 0;
            for component in
                select pi.child_id, pi.quantity from public.promo_items pi
                where pi.parent_id = product.id order by pi.child_id for share
            loop
                component_count := component_count + 1;
                if component.quantity is null or component.quantity <= 0 then
                    raise exception 'La promoción contiene cantidades inválidas.' using errcode = '22023';
                end if;
                required_stock := item.quantity * component.quantity;
                affected_product_id := component.child_id;
                select p.stock_revision into strict previous_revision
                from public.products p
                where p.id = affected_product_id and p.billar_id = requested_billar_id
                for update;
                if not (stock_before ? affected_product_id::text) then
                    stock_before := stock_before || jsonb_build_object(
                        affected_product_id::text, previous_revision);
                end if;
                update public.products p set stock = p.stock - required_stock,
                    stock_revision = p.stock_revision + 1
                where p.id = affected_product_id and p.billar_id = requested_billar_id
                  and p.parent_id is null and p.is_promo = 0 and p.is_active
                  and p.stock > '-Infinity'::double precision
                  and p.stock < 'Infinity'::double precision
                  and (allow_negative or p.stock >= required_stock);
                if not found then
                    raise exception 'No hay existencias suficientes para la promoción.' using errcode = '22023';
                end if;
            end loop;
            if component_count = 0 then
                raise exception 'La promoción no tiene componentes.' using errcode = '22023';
            end if;
        elsif product.is_promo = 0 then
            affected_product_id := product.id;
            select p.stock_revision into strict previous_revision
            from public.products p
            where p.id = affected_product_id and p.billar_id = requested_billar_id
            for update;
            if not (stock_before ? affected_product_id::text) then
                stock_before := stock_before || jsonb_build_object(
                    affected_product_id::text, previous_revision);
            end if;
            update public.products p set stock = p.stock - item.quantity,
                stock_revision = p.stock_revision + 1
            where p.id = affected_product_id and p.billar_id = requested_billar_id
              and p.stock > '-Infinity'::double precision
              and p.stock < 'Infinity'::double precision
              and (allow_negative or p.stock >= item.quantity);
            if not found then
                raise exception 'No hay existencias suficientes.' using errcode = '22023';
            end if;
        else
            raise exception 'El producto no es válido.' using errcode = '22023';
        end if;

        insert into public.sale_details
            (sale_id, product_id, product_name, quantity, price_at_sale, cost_at_sale, cancelled)
        values (sale_id, product.id, item.product_name, item.quantity, item.price, coalesce(product.cost, 0), false);
        insert into public.inventory_movements
            (billar_id, product_id, movement_type, quantity, unit_cost, unit_price,
             reference_id, reference_type, notes)
        values (requested_billar_id, product.id, 'sale', -item.quantity,
            coalesce(product.cost, 0), item.price, sale_id, 'sales_history',
            'Ajuste tardio servicio ' || requested_service_id)
        returning id into movement_id;
        sold_movements := sold_movements || jsonb_build_array(jsonb_build_object(
            'cloud_id', movement_id, 'product_id', product.id,
            'quantity', -item.quantity, 'unit_cost', coalesce(product.cost, 0),
            'unit_price', item.price, 'notes', 'Ajuste tardio servicio ' || requested_service_id));
        sold_items := sold_items || jsonb_build_array(jsonb_build_object(
            'product_id', product.id, 'product_name', item.product_name,
            'quantity', item.quantity, 'price_at_sale', item.price,
            'cost_at_sale', coalesce(product.cost, 0)));
    end loop;
    if abs(computed_total - expected_total::numeric) >
       greatest(0.000001::numeric, abs(computed_total) * 0.0000000001::numeric) then
        raise exception 'El total del ajuste no coincide.' using errcode = '22023';
    end if;
    if paid::numeric + 0.000000001 < computed_total then
        raise exception 'El importe recibido debe cubrir el total.' using errcode = '22023';
    end if;
    update public.sales_history set total = computed_total::double precision
    where id = sale_id;
    update public.staff_table_service_consumptions c
    set late_adjustment_request_id = requested_request_id
    where c.service_id = requested_service_id and c.billar_id = requested_billar_id
      and c.late and c.late_adjustment_request_id is null;
    get diagnostics changed_count = row_count;
    if changed_count <> item_count then
        raise exception 'Los consumos tardíos cambiaron durante el ajuste.' using errcode = 'PST02';
    end if;

    result_receipt := jsonb_build_object(
        'request_id', requested_request_id,
        'billar_id', requested_billar_id,
        'service_id', requested_service_id,
        'table_id', service.table_id,
        'table_type', requested_table_type,
        'sale_id', sale_id,
        'date', sale_date,
        'payment_method', payment_method,
        'total', computed_total::double precision,
        'paid', paid,
        'sale_type', sale_type,
        'items', sold_items,
        'movements', sold_movements,
        'stock', coalesce((
            select jsonb_agg(jsonb_build_object(
                'product_id', p.id, 'stock', p.stock,
                'stock_revision', p.stock_revision,
                'previous_revision', (stock_before ->> p.id::text)::bigint
            ) order by p.id)
            from public.products p
            where p.billar_id = requested_billar_id
              and p.id::text in (select jsonb_object_keys(stock_before))
        ), '[]'::jsonb)
    );
    update public.staff_table_late_adjustment_requests
    set receipt = result_receipt
    where request_id = requested_request_id;
    return result_receipt;
end;
$$;
revoke all on function public.staff_table_adjust_late_consumptions(
    uuid,text,text,uuid,bigint,double precision,text,double precision
) from public, anon, authenticated;

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
                    and c.late and c.late_adjustment_request_id is null
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
    ) order by p.ordinal desc)
      from (select * from page order by ordinal desc limit 50) p), '[]'::jsonb),
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

create or replace function public.staff_table_conflict_consumptions(
    requested_billar_id text, requested_table_type text,
    requested_service_id uuid, before_ordinal bigint default null
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
       or requested_service_id is null
       or (before_ordinal is not null and before_ordinal <= 0) then
        raise exception 'Consulta de consumos inválida.' using errcode = '22023';
    end if;
    permission := case requested_table_type
        when 'Billar' then 'billiard_tables_view_all' else 'dine_in_view_all' end;
    perform public.staff_table_require_permission(requested_billar_id, permission);
    perform 1 from public.staff_table_service_requests s
    where s.service_id = requested_service_id and s.billar_id = requested_billar_id
      and s.table_type = requested_table_type
      and (
          (s.state = 'conflict' and s.reviewed_at is null)
          or (s.state = 'closed' and exists (
              select 1 from public.staff_table_service_consumptions c
              where c.billar_id = s.billar_id and c.service_id = s.service_id
                and c.late and c.late_adjustment_request_id is null
          ))
      );
    if not found then
        raise exception 'El conflicto no está disponible.' using errcode = '42501';
    end if;
    with page as materialized (
        select c.* from public.staff_table_service_consumptions c
        where c.billar_id = requested_billar_id and c.service_id = requested_service_id
          and (
              (c.late and c.late_adjustment_request_id is null)
              or exists (
                  select 1 from public.staff_table_service_requests s
                  where s.billar_id = c.billar_id and s.service_id = c.service_id
                    and s.state = 'conflict' and s.reviewed_at is null
              )
          )
          and (before_ordinal is null or c.ordinal < before_ordinal)
        order by c.ordinal desc limit 51
    )
    select coalesce((select jsonb_agg(jsonb_build_object(
        'ordinal', p.ordinal, 'request_id', p.request_id, 'product_id', p.product_id,
        'product_name', p.product_name, 'quantity', p.quantity, 'price', p.price,
        'recorded_at', p.recorded_at
    ) order by p.ordinal desc)
      from (select * from page order by ordinal desc limit 50) p), '[]'::jsonb),
      (select count(*) > 50 from page)
    into items, has_more;
    return jsonb_build_object(
        'billar_id', requested_billar_id,
        'table_type', requested_table_type,
        'service_id', requested_service_id,
        'items', items,
        'has_more', has_more
    );
end;
$$;
revoke all on function public.staff_table_conflict_consumptions(text,text,uuid,bigint)
    from public, anon, authenticated;
grant execute on function public.staff_table_conflict_consumptions(text,text,uuid,bigint)
    to authenticated;

commit;
