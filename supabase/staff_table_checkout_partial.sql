-- PREPARACION LOCAL: NO DESPLEGAR NI HABILITAR.
-- Requiere staff_table_service_partial.sql y product_stock_conflict_guard_partial.sql.
-- Requiere bloquear las escrituras legacy de promociones y usar su RPC atomica.
-- Las escrituras legacy, la recuperacion local y la UI aun no estan integradas.
begin;

create table if not exists public.staff_table_checkout_requests (
    request_id uuid primary key,
    actor_id uuid not null,
    billar_id text not null,
    payload jsonb not null,
    receipt jsonb
);
alter table public.staff_table_checkout_requests enable row level security;
revoke all on public.staff_table_checkout_requests from public, anon, authenticated;

create or replace function public.staff_table_checkout(
    requested_request_id uuid, requested_billar_id text, requested_table_type text,
    requested_service_id uuid, expected_revision bigint,
    expected_time_cost double precision, expected_total double precision,
    payment_method text, paid double precision
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    actor uuid := auth.uid();
    permission text;
    payload jsonb;
    request_row public.staff_table_checkout_requests%rowtype;
    service public.staff_table_service_requests%rowtype;
    target public.billiard_tables%rowtype;
    settings public.billar_settings%rowtype;
    item record;
    component record;
    product public.products%rowtype;
    revision bigint;
    elapsed_seconds numeric;
    time_cost numeric := 0;
    computed_total numeric := 0;
    required_stock double precision;
    components integer;
    sale_id bigint;
    result_receipt jsonb;
    sold_items jsonb := '[]'::jsonb;
    sold_movements jsonb := '[]'::jsonb;
    stock_before jsonb := '{}'::jsonb;
    sale_date timestamptz;
    elapsed_label text;
    movement_id bigint;
    previous_revision bigint;
    affected_product_id bigint;
begin
    if actor is null or requested_request_id is null or requested_service_id is null
       or requested_billar_id is null or btrim(requested_billar_id) = ''
       or requested_table_type is null or requested_table_type not in ('Billar', 'Comanda')
       or expected_revision is null or expected_revision < 0
       or (expected_time_cost >= 0 and expected_time_cost < 'Infinity'::double precision) is not true
       or (expected_total >= 0 and expected_total < 'Infinity'::double precision) is not true
       or payment_method is null or payment_method not in ('Efectivo', 'Tarjeta', 'Transferencia')
       or (paid >= 0 and paid < 'Infinity'::double precision) is not true then
        raise exception 'Datos de cobro inválidos.' using errcode = '22023';
    end if;
    permission := case requested_table_type
        when 'Billar' then 'billiard_tables_charge' else 'dine_in_charge' end;
    perform public.staff_table_require_permission(requested_billar_id, permission);

    payload := jsonb_build_object(
        'billar_id', requested_billar_id, 'table_type', requested_table_type,
        'service_id', requested_service_id, 'revision', expected_revision,
        'time_cost', expected_time_cost, 'total', expected_total,
        'payment_method', payment_method, 'paid', paid
    );
    insert into public.staff_table_checkout_requests (request_id, actor_id, billar_id, payload)
    values (requested_request_id, actor, requested_billar_id, payload)
    on conflict (request_id) do nothing;
    select * into strict request_row from public.staff_table_checkout_requests r
    where r.request_id = requested_request_id for update;
    if request_row.actor_id is distinct from actor
       or request_row.billar_id is distinct from requested_billar_id
       or request_row.payload is distinct from payload then
        raise exception 'El identificador de cobro ya fue utilizado.' using errcode = '23505';
    end if;
    if request_row.receipt is not null then
        if not exists (
            select 1 from public.sales_history s
            where s.id = (request_row.receipt ->> 'sale_id')::bigint
              and s.billar_id = requested_billar_id and not s.cancelled
        ) then
            raise exception 'La venta registrada ya no está disponible o fue anulada.' using errcode = '55000';
        end if;
        return request_row.receipt;
    end if;

    select * into service from public.staff_table_service_requests s
    where s.service_id = requested_service_id and s.billar_id = requested_billar_id
      and s.table_type = requested_table_type and s.state = 'active'
    for update;
    if not found then
        raise exception 'El servicio activo no está disponible.' using errcode = '42501';
    end if;
    select * into target from public.billiard_tables t
    where t.billar_id = service.billar_id and t.id = service.table_id
      and (
          (service.table_type = 'Billar'
              and t.table_type in ('Billar', 'Pool', 'Carambola', 'Snooker'))
          or (service.table_type = 'Comanda' and t.table_type = 'Comanda')
      )
      and t.is_deleted = 0
      and t.is_occupied = 1 and t.start_time = service.opened_at
      and (t.orders is null or btrim(t.orders) = '[]')
    for update;
    if not found then
        raise exception 'El estado de la mesa requiere revisión.' using errcode = '55000';
    end if;
    if (select count(*) from public.billar_settings s where s.billar_id = requested_billar_id) <> 1 then
        raise exception 'No hay una configuración única para este billar.' using errcode = '55000';
    end if;
    select * into strict settings from public.billar_settings s
    where s.billar_id = requested_billar_id for share;
    if (settings.hourly_rate >= 0 and settings.hourly_rate < 'Infinity'::double precision) is not true
       or settings.allow_negative_stock_sales is null then
        raise exception 'La configuración del billar no es válida.' using errcode = '55000';
    end if;
    select coalesce(max(c.ordinal), 0) into revision
    from public.staff_table_service_consumptions c
    where c.billar_id = requested_billar_id and c.service_id = requested_service_id;
    if revision <> expected_revision then
        raise exception 'Los consumos cambiaron; vuelve a consultar el servicio.' using errcode = 'PST02';
    end if;
    sale_date := clock_timestamp();
    time_cost := public.staff_table_time_cost(
        requested_table_type, service.opened_at, sale_date, settings.hourly_rate);
    elapsed_seconds := floor(extract(epoch from sale_date - service.opened_at));
    if time_cost <> expected_time_cost::numeric then
        raise exception 'El costo de tiempo cambió; vuelve a consultar el servicio.' using errcode = 'PST03';
    end if;
    computed_total := time_cost;

    -- Lock sold products before reading promo composition; its RPC locks the
    -- promo product before replacing components.
    perform p.id from public.products p
    where p.billar_id = requested_billar_id and p.id in (
        select c.product_id from public.staff_table_service_consumptions c
        where c.billar_id = requested_billar_id and c.service_id = requested_service_id
    )
    order by p.id for update;

    insert into public.sales_history (
        billar_id, type, source_module, date, payment_method, total, paid, customer_key, cancelled
    ) values (
        requested_billar_id,
        case when requested_table_type = 'Comanda' then 'Comanda: ' || target.name else target.name end,
        case when requested_table_type = 'Comanda' then 'dine_in' else 'billiard_tables' end,
        sale_date::text, payment_method, expected_total, paid, null, false
    ) returning id into sale_id;

    for item in
        select c.* from public.staff_table_service_consumptions c
        where c.billar_id = requested_billar_id and c.service_id = requested_service_id
        order by c.product_id, c.ordinal
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
            raise exception 'El precio o consumo cambió; revisa el servicio.' using errcode = '22023';
        end if;
        computed_total := computed_total + item.quantity::numeric * item.price::numeric;
        if product.parent_id is not null then
            if product.is_promo <> 0 or product.pieces_per_unit <= 0 then
                raise exception 'La presentación del producto es inválida.' using errcode = '22023';
            end if;
            required_stock := item.quantity * product.pieces_per_unit;
            affected_product_id := product.parent_id;
            select p.stock_revision into strict previous_revision from public.products p
            where p.id = affected_product_id and p.billar_id = requested_billar_id for update;
            if not (stock_before ? affected_product_id::text) then
                stock_before := stock_before || jsonb_build_object(
                    affected_product_id::text, previous_revision);
            end if;
            update public.products p set stock = p.stock - required_stock,
                stock_revision = p.stock_revision + 1
            where p.id = affected_product_id and p.billar_id = requested_billar_id
              and p.parent_id is null and p.is_promo = 0 and p.is_active
              and p.stock > '-Infinity'::double precision and p.stock < 'Infinity'::double precision
              and (settings.allow_negative_stock_sales or p.stock >= required_stock);
            if not found then
                raise exception 'No hay existencias suficientes o el producto padre es inválido.' using errcode = '22023';
            end if;
        elsif product.is_promo = 1 then
            components := 0;
            for component in select pi.child_id, pi.quantity from public.promo_items pi
                where pi.parent_id = product.id order by pi.child_id for share
            loop
                components := components + 1;
                if component.quantity is null or component.quantity <= 0 then
                    raise exception 'La promoción contiene cantidades inválidas.' using errcode = '22023';
                end if;
                required_stock := item.quantity * component.quantity;
                affected_product_id := component.child_id;
                select p.stock_revision into strict previous_revision from public.products p
                where p.id = affected_product_id and p.billar_id = requested_billar_id for update;
                if not (stock_before ? affected_product_id::text) then
                    stock_before := stock_before || jsonb_build_object(
                        affected_product_id::text, previous_revision);
                end if;
                update public.products p set stock = p.stock - required_stock,
                    stock_revision = p.stock_revision + 1
                where p.id = affected_product_id and p.billar_id = requested_billar_id
                  and p.parent_id is null and p.is_promo = 0 and p.is_active
                  and p.stock > '-Infinity'::double precision and p.stock < 'Infinity'::double precision
                  and (settings.allow_negative_stock_sales or p.stock >= required_stock);
                if not found then
                    raise exception 'No hay existencias suficientes para la promoción.' using errcode = '22023';
                end if;
            end loop;
            if components = 0 then
                raise exception 'La promoción no tiene componentes.' using errcode = '22023';
            end if;
        elsif product.is_promo = 0 then
            affected_product_id := product.id;
            select p.stock_revision into strict previous_revision from public.products p
            where p.id = affected_product_id and p.billar_id = requested_billar_id for update;
            if not (stock_before ? affected_product_id::text) then
                stock_before := stock_before || jsonb_build_object(
                    affected_product_id::text, previous_revision);
            end if;
            update public.products p set stock = p.stock - item.quantity,
                stock_revision = p.stock_revision + 1
            where p.id = affected_product_id and
              p.stock > '-Infinity'::double precision and p.stock < 'Infinity'::double precision and
              (settings.allow_negative_stock_sales or p.stock >= item.quantity);
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
            (billar_id, product_id, movement_type, quantity, unit_cost, unit_price, reference_id, reference_type, notes)
        values (requested_billar_id, product.id, 'sale', -item.quantity, coalesce(product.cost, 0),
            item.price, sale_id, 'sales_history', 'Servicio de mesa')
        returning id into movement_id;
        sold_movements := sold_movements || jsonb_build_array(jsonb_build_object(
            'cloud_id', movement_id, 'product_id', product.id,
            'quantity', -item.quantity, 'unit_cost', coalesce(product.cost, 0),
            'unit_price', item.price, 'notes', 'Servicio de mesa'));
        sold_items := sold_items || jsonb_build_array(jsonb_build_object(
            'product_id', product.id, 'product_name', item.product_name,
            'quantity', item.quantity, 'price_at_sale', item.price,
            'cost_at_sale', coalesce(product.cost, 0)
        ));
    end loop;
    if abs(computed_total - expected_total::numeric) >
       greatest(0.000001::numeric, abs(computed_total) * 0.0000000001::numeric) then
        raise exception 'El total no coincide con los detalles.' using errcode = '22023';
    end if;
    if computed_total <= 0 or paid::numeric + 0.000000001 < computed_total then
        raise exception 'El importe recibido debe cubrir el total.' using errcode = '22023';
    end if;
    update public.sales_history set total = computed_total::double precision where id = sale_id;
    if time_cost > 0 then
        elapsed_label := case when elapsed_seconds >= 3600
            then trunc(elapsed_seconds / 3600)::text || ':'
            else '' end
            || lpad(trunc(mod(elapsed_seconds, 3600) / 60)::text, 2, '0')
            || ':' || lpad(mod(elapsed_seconds, 60)::text, 2, '0');
        insert into public.sale_details
            (sale_id, product_id, product_name, quantity, price_at_sale, cost_at_sale, cancelled)
        values (sale_id, null, 'Tiempo de juego (' || elapsed_label || ')', 1, time_cost, 0, false);
        sold_items := sold_items || jsonb_build_array(jsonb_build_object(
            'product_id', null, 'product_name', 'Tiempo de juego (' || elapsed_label || ')',
            'quantity', 1, 'price_at_sale', time_cost, 'cost_at_sale', 0
        ));
    end if;
    update public.staff_table_service_requests set state = 'closed'
    where service_id = service.service_id;
    update public.billiard_tables set is_occupied = 0, start_time = null, orders = '[]'
    where billar_id = service.billar_id and id = service.table_id;
    result_receipt := jsonb_build_object(
        'request_id', requested_request_id, 'billar_id', requested_billar_id,
        'service_id', requested_service_id, 'table_id', service.table_id,
        'table_type', requested_table_type, 'sale_id', sale_id, 'date', sale_date,
        'payment_method', payment_method, 'total', computed_total::double precision,
        'paid', paid, 'sale_type', case when requested_table_type = 'Comanda'
            then 'Comanda: ' || target.name else target.name end,
        'items', sold_items, 'movements', sold_movements,
        'stock', coalesce((
            select jsonb_agg(jsonb_build_object(
                'product_id', p.id, 'stock', p.stock,
                'stock_revision', p.stock_revision,
                'previous_revision', (stock_before ->> p.id::text)::bigint
            ) order by p.id)
            from public.products p where p.billar_id = requested_billar_id
              and p.id::text in (select jsonb_object_keys(stock_before))
        ), '[]'::jsonb)
    );
    update public.staff_table_checkout_requests set receipt = result_receipt
    where request_id = requested_request_id;
    return result_receipt;
end;
$$;
revoke all on function public.staff_table_checkout(uuid,text,text,uuid,bigint,double precision,double precision,text,double precision)
    from public, anon, authenticated;
commit;
