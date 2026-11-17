-- Preparation only. Do not deploy or enable staff purchases yet.
-- Requires staff account fields, purchase/provider columns, staff purchase and
-- inventory guards, product_stock_conflict_guard_partial.sql and
-- purchase_payment_terms_partial.sql.
-- Items preserve the presentation the user confirmed; names, date and totals
-- are authoritative server values. Execution remains revoked.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

create table if not exists public.staff_purchase_requests (
    request_id uuid primary key,
    billar_id text not null,
    actor_id uuid not null,
    request_payload jsonb not null,
    result jsonb
);
alter table public.staff_purchase_requests enable row level security;
revoke all on public.staff_purchase_requests from public, anon, authenticated;

create table if not exists public.staff_purchase_audit (
    request_id uuid primary key references public.staff_purchase_requests(request_id),
    billar_id text not null,
    actor_id uuid not null,
    purchase_id bigint not null references public.purchases(id),
    receipt jsonb not null,
    recorded_at timestamptz not null default clock_timestamp()
);
alter table public.staff_purchase_audit enable row level security;
revoke all on public.staff_purchase_audit from public, anon, authenticated;
grant select on public.staff_purchase_audit to authenticated;
drop policy if exists staff_purchase_audit_admin_select on public.staff_purchase_audit;
create policy staff_purchase_audit_admin_select on public.staff_purchase_audit
for select to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]));

create or replace function public.record_staff_purchase(
    p_request_id uuid,
    p_billar_id text,
    p_provider_id bigint,
    p_reference text,
    p_cash_source text,
    p_items jsonb,
    p_payment jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    actor uuid := auth.uid();
    metadata jsonb := auth.jwt() -> 'app_metadata';
    uploader text;
    payload jsonb;
    request_row public.staff_purchase_requests%rowtype;
    item jsonb;
    product_row public.products%rowtype;
    base public.products%rowtype;
    requested_ids bigint[] := '{}';
    target_ids bigint[] := '{}';
    locked_ids bigint[];
    product_id bigint;
    parent bigint;
    pieces integer;
    quantity numeric;
    unit_cost numeric;
    stock_quantity double precision;
    cost_per_piece double precision;
    total numeric := 0;
    purchase_id bigint;
    purchase_date text;
    original_stock jsonb;
    details jsonb := '[]'::jsonb;
    receipt jsonb;
    payment_option text;
    payment_days integer;
    maturity date;
begin
    if actor is null or metadata ->> 'account_type' is distinct from 'staff'
       or metadata ->> 'billar_id' is distinct from p_billar_id then
        raise exception 'Se requiere una cuenta de personal de este billar.' using errcode = '42501';
    end if;
    if p_request_id is null or p_billar_id is null or btrim(p_billar_id) = ''
       or (p_provider_id is not null and p_provider_id <= 0)
       or p_reference is null
       or (p_payment is null and (p_cash_source is null
           or p_cash_source not in ('caja', 'cajero', 'transferencia', 'tarjeta')))
       or jsonb_typeof(p_items) is distinct from 'array' then
        raise exception 'Los datos de compra no son válidos.' using errcode = '22023';
    end if;
    if jsonb_array_length(p_items) = 0 then
        raise exception 'La compra debe tener al menos un detalle.' using errcode = '22023';
    end if;
    if p_payment is not null then
        if jsonb_typeof(p_payment) is distinct from 'object' then
            raise exception 'Las condiciones de la compra no son válidas.' using errcode = '22023';
        end if;
        if (select count(*) from jsonb_object_keys(p_payment)) <> 3
           or not (p_payment ?& array['option', 'cash_source', 'credit_days'])
           or jsonb_typeof(p_payment -> 'option') is distinct from 'string' then
            raise exception 'Las condiciones de la compra no son válidas.' using errcode = '22023';
        end if;
        payment_option := p_payment ->> 'option';
        if payment_option not in ('efectivo', 'tarjeta', 'transferencia', 'credito') then
            raise exception 'La forma de pago no es válida.' using errcode = '22023';
        end if;
        if payment_option = 'efectivo' then
            if jsonb_typeof(p_payment -> 'cash_source') is distinct from 'string'
               or p_payment ->> 'cash_source' not in ('caja', 'cajero')
               or p_cash_source is distinct from p_payment ->> 'cash_source' then
                raise exception 'El origen del efectivo no es válido.' using errcode = '22023';
            end if;
        elsif jsonb_typeof(p_payment -> 'cash_source') is distinct from 'null'
              or p_cash_source is distinct from (case when payment_option = 'credito' then null else payment_option end) then
            raise exception 'Un pago no efectivo no puede afectar el cajón.' using errcode = '22023';
        end if;
        if payment_option = 'credito' then
            if p_provider_id is null or jsonb_typeof(p_payment -> 'credit_days') is distinct from 'number' then
                raise exception 'El crédito requiere proveedor y días de crédito.' using errcode = '22023';
            end if;
            if (p_payment ->> 'credit_days')::numeric < 0
               or (p_payment ->> 'credit_days')::numeric > 2147483647
               or (p_payment ->> 'credit_days')::numeric <> trunc((p_payment ->> 'credit_days')::numeric) then
                raise exception 'Los días de crédito no son válidos.' using errcode = '22023';
            end if;
            payment_days := (p_payment ->> 'credit_days')::integer;
        elsif jsonb_typeof(p_payment -> 'credit_days') is distinct from 'null' then
            raise exception 'El contado no admite días de crédito.' using errcode = '22023';
        end if;
    end if;
    select membership.username into uploader from public.business_memberships membership
    where membership.user_id = actor and membership.billar_id = p_billar_id
      and membership.role = 'manager' and membership.is_active
      and not membership.must_change_password
      and membership.username is not null and btrim(membership.username) <> ''
      and 'purchases' = any(membership.allowed_modules)
    for share;
    if not found then
        raise exception 'No tienes permiso para registrar compras.' using errcode = '42501';
    end if;
    payload := jsonb_build_object(
        'provider_id', p_provider_id, 'reference', p_reference,
        'cash_source', p_cash_source, 'items', p_items
    );
    if p_payment is not null then
        payload := payload || jsonb_build_object('payment', p_payment);
    end if;
    insert into public.staff_purchase_requests(request_id, billar_id, actor_id, request_payload)
    values (p_request_id, p_billar_id, actor, payload) on conflict (request_id) do nothing;
    select * into strict request_row from public.staff_purchase_requests
    where request_id = p_request_id for update;
    if request_row.billar_id <> p_billar_id or request_row.actor_id <> actor
       or request_row.request_payload <> payload then
        raise exception 'El identificador de compra ya fue utilizado.' using errcode = '23505';
    end if;
    if request_row.result is not null then return request_row.result; end if;
    if p_provider_id is not null then
        perform 1 from public.providers
        where id = p_provider_id and billar_id = p_billar_id and is_active for share;
        if not found then
            raise exception 'El proveedor no está activo en este billar.' using errcode = '42501';
        end if;
    end if;

    for item in select value from jsonb_array_elements(p_items) loop
        if jsonb_typeof(item) is distinct from 'object' then
            raise exception 'El detalle de compra no es válido.' using errcode = '22023';
        end if;
        if (select count(*) from jsonb_object_keys(item)) <> 5
           or jsonb_typeof(item -> 'product_id') is distinct from 'number'
           or jsonb_typeof(item -> 'quantity') is distinct from 'number'
           or jsonb_typeof(item -> 'cost_per_unit') is distinct from 'number'
           or jsonb_typeof(item -> 'pieces_per_unit') is distinct from 'number'
           or jsonb_typeof(item -> 'parent_id') is null
           or jsonb_typeof(item -> 'parent_id') not in ('null', 'number') then
            raise exception 'El detalle de compra no es válido.' using errcode = '22023';
        end if;
        if (item ->> 'product_id')::numeric <> trunc((item ->> 'product_id')::numeric)
           or (item ->> 'pieces_per_unit')::numeric <> trunc((item ->> 'pieces_per_unit')::numeric)
           or (item ->> 'parent_id')::numeric <> trunc((item ->> 'parent_id')::numeric) then
            raise exception 'La presentación de compra no es válida.' using errcode = '22023';
        end if;
        product_id := (item ->> 'product_id')::bigint;
        parent := (item ->> 'parent_id')::bigint;
        pieces := (item ->> 'pieces_per_unit')::integer;
        quantity := (item ->> 'quantity')::numeric;
        unit_cost := (item ->> 'cost_per_unit')::numeric;
        if product_id <= 0 or pieces <= 0 or quantity <= 0 or unit_cost < 0
           or (parent is not null and (parent <= 0 or parent = product_id))
           or product_id = any(requested_ids) then
            raise exception 'La cantidad, el costo o el producto no son válidos.' using errcode = '22023';
        end if;
        requested_ids := array_append(requested_ids, product_id);
        target_ids := array_append(target_ids, coalesce(parent, product_id));
        total := total + quantity * unit_cost;
    end loop;

    select array_agg(locked.id) into locked_ids from (
        select product.id from public.products product
        where product.billar_id = p_billar_id and (
            product.id = any(requested_ids) or product.id = any(target_ids)
            or product.parent_id = any(target_ids)
        )
        order by product.id for update
    ) locked;
    if exists (
        select 1 from public.products product where product.id = any(locked_ids)
          and (
              (product.stock > '-Infinity'::double precision and product.stock < 'Infinity'::double precision) is not true
              or product.stock_revision is null or product.stock_revision < 0
              or (product.cost is not null and
                  (product.cost > '-Infinity'::double precision and product.cost < 'Infinity'::double precision) is not true)
          )
    ) then
        raise exception 'Las existencias registradas no son válidas.' using errcode = '22023';
    end if;
    select jsonb_agg(jsonb_build_object(
        'product_id', product.id, 'stock', product.stock, 'cost', product.cost,
        'stock_revision', product.stock_revision
    ) order by product.id) into original_stock
    from public.products product where product.id = any(locked_ids);

    purchase_date := to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
    if payment_option = 'credito' then
        maturity := (purchase_date::timestamptz at time zone 'UTC')::date + payment_days;
        if maturity > date '9999-12-31' then
            raise exception 'El vencimiento excede el rango de fechas admitido.' using errcode = '22023';
        end if;
    end if;
    insert into public.purchases (
        billar_id, provider_id, total, date, reference, created_by, cash_source, cancelled,
        payment_condition, payment_method, credit_days, due_date, paid_amount, balance_due
    ) values (
        p_billar_id, p_provider_id, total::double precision, purchase_date,
        p_reference, uploader, p_cash_source, false,
        case when p_payment is null then null when payment_option = 'credito' then 'credito' else 'contado' end,
        case when payment_option = 'credito' then null else payment_option end,
        payment_days, maturity,
        case when p_payment is null then null when payment_option = 'credito' then 0 else total::double precision end,
        case when p_payment is null then null when payment_option = 'credito' then total::double precision else 0 end
    ) returning id into purchase_id;
    for item in select value from jsonb_array_elements(p_items) loop
        product_id := (item ->> 'product_id')::bigint;
        parent := (item ->> 'parent_id')::bigint;
        pieces := (item ->> 'pieces_per_unit')::integer;
        quantity := (item ->> 'quantity')::numeric;
        unit_cost := (item ->> 'cost_per_unit')::numeric;
        select * into product_row from public.products product
        where product.id = product_id and product.billar_id = p_billar_id
          and product.id = any(locked_ids) and product.is_active and product.is_promo = 0;
        if not found or btrim(product_row.name) = '' then
            raise exception 'El producto no está activo o no admite compras en este billar.'
                using errcode = '42501';
        end if;
        if product_row.parent_id is distinct from parent or product_row.pieces_per_unit is distinct from pieces then
            raise exception 'La presentación cambió; actualiza los productos.' using errcode = '40001';
        end if;
        select * into base from public.products product
        where product.id = coalesce(parent, product_id) and product.billar_id = p_billar_id
          and product.id = any(locked_ids) and product.parent_id is null
          and product.is_promo = 0 and product.is_active;
        if not found then
            raise exception 'El producto base no está activo en este billar.' using errcode = '42501';
        end if;
        if (base.price >= 0 and base.price < 'Infinity'::double precision) is not true
           or exists (
               select 1 from public.products child
               where child.billar_id = p_billar_id and child.parent_id = base.id
                 and child.id = any(locked_ids)
                 and (child.is_promo is distinct from 0 or child.pieces_per_unit is null or child.pieces_per_unit <= 0)
           ) then
            raise exception 'La información del producto base no es válida.' using errcode = '22023';
        end if;
        stock_quantity := (quantity * case when parent is null then 1 else pieces end)::double precision;
        cost_per_piece := (unit_cost / case when parent is null then 1 else pieces end)::double precision;
        if (stock_quantity > 0 and stock_quantity < 'Infinity'::double precision) is not true
           or base.stock + stock_quantity = base.stock
           or (cost_per_piece >= 0 and cost_per_piece < 'Infinity'::double precision) is not true then
            raise exception 'La cantidad o el costo convertido no son válidos.' using errcode = '22023';
        end if;
        update public.products set stock = stock + stock_quantity, cost = cost_per_piece,
            stock_revision = stock_revision + 1
        where id = base.id and billar_id = p_billar_id;
        update public.products child set cost = cost_per_piece * child.pieces_per_unit,
            stock_revision = child.stock_revision + 1
        where child.billar_id = p_billar_id and child.parent_id = base.id and child.id = any(locked_ids);
        insert into public.purchase_details (
            purchase_id, product_id, quantity, cost_per_unit, created_by, cancelled
        ) values (purchase_id, product_id, quantity::double precision, unit_cost::double precision, uploader, false);
        insert into public.inventory_movements (
            billar_id, product_id, movement_type, quantity, unit_cost,
            unit_price, reference_id, reference_type, notes
        ) values (
            p_billar_id, base.id, 'purchase', stock_quantity, cost_per_piece,
            base.price, purchase_id, 'purchases', 'Compra de personal'
        );
        details := details || jsonb_build_array(item || jsonb_build_object(
            'product_name', product_row.name, 'stock_product_id', base.id,
            'stock_quantity', stock_quantity, 'cost_per_piece', cost_per_piece
        ));
    end loop;
    select jsonb_build_object(
        'request_id', p_request_id, 'billar_id', p_billar_id, 'actor_id', actor,
        'purchase', to_jsonb(purchase), 'items', details, 'stock_before', original_stock,
        'stock_after', (select jsonb_agg(jsonb_build_object(
            'product_id', product.id, 'stock', product.stock, 'cost', product.cost,
            'stock_revision', product.stock_revision
        ) order by product.id) from public.products product where product.id = any(locked_ids))
    ) into receipt from public.purchases purchase where purchase.id = purchase_id;
    insert into public.staff_purchase_audit(request_id, billar_id, actor_id, purchase_id, receipt)
    values (p_request_id, p_billar_id, actor, purchase_id, receipt);
    update public.staff_purchase_requests set result = receipt where request_id = p_request_id;
    return receipt;
end;
$$;
revoke all on function public.record_staff_purchase(uuid, text, bigint, text, text, jsonb, jsonb)
from public, anon, authenticated;

-- Keep the original argument list and payload for already-persisted requests.
create or replace function public.record_staff_purchase(
    p_request_id uuid, p_billar_id text, p_provider_id bigint,
    p_reference text, p_cash_source text, p_items jsonb
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
    select public.record_staff_purchase(
        p_request_id, p_billar_id, p_provider_id, p_reference, p_cash_source, p_items, null::jsonb
    );
$$;
revoke all on function public.record_staff_purchase(uuid, text, bigint, text, text, jsonb)
from public, anon, authenticated;
commit;
