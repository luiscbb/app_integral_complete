-- Preparation only: do not deploy until the client, policies and real schema
-- have been validated together. Existing clients are not idempotent.
-- Requires purchase_payment_terms_partial.sql for purchase snapshots.
begin;

alter table public.sales_history
  add column if not exists sync_client_id uuid;
alter table public.purchases
  add column if not exists sync_client_id uuid;

create unique index if not exists sales_history_sync_client_id_key
  on public.sales_history (sync_client_id);
create unique index if not exists purchases_sync_client_id_key
  on public.purchases (sync_client_id);

create table if not exists public.owner_transaction_sync_requests (
  request_id uuid primary key,
  actor_id uuid not null,
  billar_id text not null,
  kind text not null,
  request_payload jsonb not null,
  result_id bigint,
  completed boolean not null default false
);
alter table public.owner_transaction_sync_requests enable row level security;
revoke all on public.owner_transaction_sync_requests from public, anon, authenticated;

create or replace function public.sync_owner_sale(
  p_request_id uuid,
  p_billar_id text,
  p_cloud_id bigint,
  p_sale jsonb,
  p_details jsonb
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  v_result_id bigint;
  payload jsonb;
  request_row public.owner_transaction_sync_requests%rowtype;
begin
  if actor is null or p_request_id is null or p_billar_id is null
      or btrim(p_billar_id) = '' or jsonb_typeof(p_sale) is distinct from 'object'
      or jsonb_typeof(p_details) is distinct from 'array' then
    raise exception 'Datos de sincronización inválidos.' using errcode = '22023';
  end if;
  perform 1 from public.billar_settings s
  join public.business_memberships m
    on m.user_id = s.user_id and m.billar_id = s.billar_id
  where s.user_id = actor and s.billar_id = p_billar_id
    and m.role = 'admin' and m.is_active and not m.must_change_password
  for share of s, m;
  if not found then
    raise exception 'Se requiere un administrador activo del billar.' using errcode = '42501';
  end if;

  payload := jsonb_build_object('cloud_id', p_cloud_id, 'sale', p_sale, 'details', p_details);
  insert into public.owner_transaction_sync_requests (
    request_id, actor_id, billar_id, kind, request_payload
  ) values (p_request_id, actor, p_billar_id, 'sale', payload)
  on conflict (request_id) do nothing;
  select * into strict request_row
  from public.owner_transaction_sync_requests
  where request_id = p_request_id for update;
  if request_row.actor_id <> actor or request_row.billar_id <> p_billar_id
      or request_row.kind <> 'sale' or request_row.request_payload <> payload then
    raise exception 'El identificador de sincronización ya fue utilizado.' using errcode = '23505';
  end if;
  if request_row.completed then
    if not exists (
      select 1 from public.sales_history
      where id = request_row.result_id and billar_id = p_billar_id
    ) then
      raise exception 'La venta registrada ya no está disponible.' using errcode = '55000';
    end if;
    return request_row.result_id;
  end if;

  perform 1 from public.products product
  where product.billar_id = p_billar_id and product.id in (
    select (item->>'product_id')::bigint
    from jsonb_array_elements(p_details) as items(item)
    where item->>'product_id' is not null
  )
  order by product.id for share;
  if exists (
    select 1 from jsonb_array_elements(p_details) as items(item)
    where item->>'product_id' is not null
      and not exists (
        select 1 from public.products product
        where product.id = (item->>'product_id')::bigint
          and product.billar_id = p_billar_id
      )
  ) then
    raise exception 'Un producto no está disponible en este billar.' using errcode = '42501';
  end if;

  if p_cloud_id is null then
    insert into public.sales_history (
      billar_id, total, paid, date, type, source_module, payment_method,
      cancelled, customer_key, sync_client_id
    ) values (
      p_billar_id, (p_sale->>'total')::double precision,
      (p_sale->>'paid')::double precision, p_sale->>'date', p_sale->>'type',
      p_sale->>'source_module', p_sale->>'payment_method',
      coalesce((p_sale->>'cancelled')::boolean, false), p_sale->>'customer_key',
      p_request_id
    )
    returning id into v_result_id;
  else
    update public.sales_history set
      total = (p_sale->>'total')::double precision,
      paid = (p_sale->>'paid')::double precision,
      date = p_sale->>'date', type = p_sale->>'type',
      source_module = p_sale->>'source_module',
      payment_method = p_sale->>'payment_method',
      cancelled = coalesce((p_sale->>'cancelled')::boolean, false),
      customer_key = p_sale->>'customer_key'
    where id = p_cloud_id and billar_id = p_billar_id
    returning id into v_result_id;
  end if;

  if v_result_id is null then
    raise exception 'La venta no está disponible en este billar.' using errcode = '42501';
  end if;
  delete from public.sale_details where sale_id = v_result_id;
  insert into public.sale_details (
    sale_id, product_id, product_name, quantity, price_at_sale, cost_at_sale, cancelled
  )
  select v_result_id, (item->>'product_id')::bigint, item->>'product_name',
    (item->>'quantity')::double precision, (item->>'price_at_sale')::double precision,
    coalesce((item->>'cost_at_sale')::numeric, 0),
    coalesce((p_sale->>'cancelled')::boolean, false)
  from jsonb_array_elements(p_details) as items(item);
  update public.owner_transaction_sync_requests
  set result_id = v_result_id, completed = true
  where request_id = p_request_id;
  return v_result_id;
end;
$$;

create or replace function public.sync_owner_purchase(
  p_request_id uuid,
  p_billar_id text,
  p_cloud_id bigint,
  p_purchase jsonb,
  p_details jsonb
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  v_result_id bigint;
  provider bigint;
  payload jsonb;
  request_row public.owner_transaction_sync_requests%rowtype;
  purchase_row public.purchases%rowtype;
  has_payment boolean;
  payment_fields text[] := array[
    'payment_condition', 'payment_method', 'credit_days', 'due_date', 'paid_amount', 'balance_due'
  ];
  field text;
  total_amount double precision;
  detail jsonb;
  detail_total numeric := 0;
begin
  if actor is null or p_request_id is null or p_billar_id is null
      or btrim(p_billar_id) = '' or jsonb_typeof(p_purchase) is distinct from 'object'
      or jsonb_typeof(p_details) is distinct from 'array' then
    raise exception 'Datos de sincronización inválidos.' using errcode = '22023';
  end if;
  perform 1 from public.billar_settings s
  join public.business_memberships m
    on m.user_id = s.user_id and m.billar_id = s.billar_id
  where s.user_id = actor and s.billar_id = p_billar_id
    and m.role = 'admin' and m.is_active and not m.must_change_password
  for share of s, m;
  if not found then
    raise exception 'Se requiere un administrador activo del billar.' using errcode = '42501';
  end if;
  payload := jsonb_build_object('cloud_id', p_cloud_id, 'purchase', p_purchase, 'details', p_details);
  insert into public.owner_transaction_sync_requests (
    request_id, actor_id, billar_id, kind, request_payload
  ) values (p_request_id, actor, p_billar_id, 'purchase', payload)
  on conflict (request_id) do nothing;
  select * into strict request_row
  from public.owner_transaction_sync_requests
  where request_id = p_request_id for update;
  if request_row.actor_id <> actor or request_row.billar_id <> p_billar_id
      or request_row.kind <> 'purchase' or request_row.request_payload <> payload then
    raise exception 'El identificador de sincronización ya fue utilizado.' using errcode = '23505';
  end if;
  if request_row.completed then
    if not exists (
      select 1 from public.purchases
      where id = request_row.result_id and billar_id = p_billar_id
    ) then
      raise exception 'La compra registrada ya no está disponible.' using errcode = '55000';
    end if;
    return request_row.result_id;
  end if;
  provider := (p_purchase->>'provider_id')::bigint;
  has_payment := p_purchase ?| payment_fields;
  if has_payment then
    if not (p_purchase ?& payment_fields)
       or jsonb_typeof(p_purchase -> 'payment_condition') is distinct from 'string'
       or p_purchase ->> 'payment_condition' not in ('contado', 'credito')
       or jsonb_typeof(p_purchase -> 'date') is distinct from 'string'
       or jsonb_typeof(p_purchase -> 'total') is distinct from 'number'
       or jsonb_typeof(p_purchase -> 'paid_amount') is distinct from 'number'
       or jsonb_typeof(p_purchase -> 'balance_due') is distinct from 'number' then
      raise exception 'Las condiciones de pago no son válidas.' using errcode = '22023';
    end if;
    total_amount := (p_purchase ->> 'total')::double precision;
    if (total_amount >= 0 and total_amount < 'Infinity'::double precision) is not true
       or not isfinite((p_purchase ->> 'date')::timestamptz) then
      raise exception 'El total de compra no es válido.' using errcode = '22023';
    end if;
    if jsonb_array_length(p_details) = 0 then
      raise exception 'La compra debe tener detalles.' using errcode = '22023';
    end if;
    for detail in select value from jsonb_array_elements(p_details) loop
      if jsonb_typeof(detail -> 'quantity') is distinct from 'number'
         or jsonb_typeof(detail -> 'cost_per_unit') is distinct from 'number' then
        raise exception 'El detalle de compra no es válido.' using errcode = '22023';
      end if;
      if (detail ->> 'quantity')::numeric <= 0 or (detail ->> 'cost_per_unit')::numeric < 0 then
        raise exception 'La cantidad o el costo no son válidos.' using errcode = '22023';
      end if;
      detail_total := detail_total + (detail ->> 'quantity')::numeric * (detail ->> 'cost_per_unit')::numeric;
    end loop;
    if abs(detail_total - total_amount::numeric) > greatest(0.000001, abs(total_amount::numeric) * 1e-10) then
      raise exception 'El total no coincide con los detalles.' using errcode = '22023';
    end if;
    if p_purchase ->> 'payment_condition' = 'credito' then
      if provider is null
         or jsonb_typeof(p_purchase -> 'payment_method') is distinct from 'null'
         or jsonb_typeof(p_purchase -> 'cash_source') is distinct from 'null'
         or jsonb_typeof(p_purchase -> 'credit_days') is distinct from 'number'
         or jsonb_typeof(p_purchase -> 'due_date') is distinct from 'string' then
        raise exception 'El crédito requiere proveedor, días y vencimiento, sin pago efectivo.' using errcode = '22023';
      end if;
      if ((p_purchase ->> 'credit_days')::numeric >= 0
          and (p_purchase ->> 'credit_days')::numeric <= 2147483647
          and (p_purchase ->> 'credit_days')::numeric = trunc((p_purchase ->> 'credit_days')::numeric)
          and (p_purchase ->> 'paid_amount')::double precision = 0
          and (p_purchase ->> 'balance_due')::double precision = total_amount) is not true then
        raise exception 'El crédito inicial debe ser total, sin anticipos.' using errcode = '22023';
      end if;
      if (p_purchase ->> 'due_date')::date > date '9999-12-31'
         or (p_purchase ->> 'due_date')::date is distinct from
           ((p_purchase ->> 'date')::timestamptz at time zone 'UTC')::date
             + (p_purchase ->> 'credit_days')::integer then
        raise exception 'El vencimiento no coincide con los días de crédito.' using errcode = '22023';
      end if;
    else
      if (jsonb_typeof(p_purchase -> 'credit_days') = 'null'
          and jsonb_typeof(p_purchase -> 'due_date') = 'null'
          and (p_purchase ->> 'paid_amount')::double precision = total_amount
          and (p_purchase ->> 'balance_due')::double precision = 0
          and ((p_purchase ->> 'payment_method' = 'efectivo'
                  and p_purchase ->> 'cash_source' in ('caja', 'cajero'))
            or (p_purchase ->> 'payment_method' in ('tarjeta', 'transferencia')
                  and p_purchase ->> 'cash_source' = p_purchase ->> 'payment_method'))) is not true then
        raise exception 'El pago de contado no es válido.' using errcode = '22023';
      end if;
    end if;
  end if;
  if provider is not null and not exists (
    select 1 from public.providers
    where id = provider and billar_id = p_billar_id
  ) then
    raise exception 'El proveedor no pertenece al billar.' using errcode = '42501';
  end if;
  if p_cloud_id is not null then
    select * into purchase_row from public.purchases
    where id = p_cloud_id and billar_id = p_billar_id for update;
    if not found then
      raise exception 'La compra no está disponible en este billar.' using errcode = '42501';
    end if;
    if purchase_row.payment_condition is not null then
      if not has_payment then
        raise exception 'Actualiza el cliente para conservar las condiciones de la compra.' using errcode = '22023';
      end if;
      foreach field in array payment_fields || array['provider_id', 'total', 'cash_source'] loop
        if to_jsonb(purchase_row) -> field is distinct from p_purchase -> field then
          raise exception 'Las condiciones registradas de la compra no se pueden cambiar.' using errcode = '22023';
        end if;
      end loop;
      if purchase_row.date::timestamptz is distinct from (p_purchase ->> 'date')::timestamptz then
        raise exception 'La fecha registrada de la compra no se puede cambiar.' using errcode = '22023';
      end if;
    elsif has_payment then
      raise exception 'No se pueden inventar condiciones de pago para una compra histórica.' using errcode = '22023';
    end if;
  end if;

  perform 1 from public.products product
  where product.billar_id = p_billar_id and product.id in (
    select (item->>'product_id')::bigint
    from jsonb_array_elements(p_details) as items(item)
    where item->>'product_id' is not null
  )
  order by product.id for share;
  if exists (
    select 1 from jsonb_array_elements(p_details) as items(item)
    where item->>'product_id' is null
      or not exists (
        select 1 from public.products product
        where product.id = (item->>'product_id')::bigint
          and product.billar_id = p_billar_id
      )
  ) then
    raise exception 'Un producto no está disponible en este billar.' using errcode = '42501';
  end if;

  if p_cloud_id is null then
    insert into public.purchases (
      billar_id, provider_id, total, date, reference, created_by, cash_source,
      cancelled, sync_client_id, payment_condition, payment_method,
      credit_days, due_date, paid_amount, balance_due
    ) values (
      p_billar_id, provider, (p_purchase->>'total')::double precision,
      p_purchase->>'date', p_purchase->>'reference', p_purchase->>'created_by',
      p_purchase->>'cash_source', coalesce((p_purchase->>'cancelled')::boolean, false),
      p_request_id, p_purchase ->> 'payment_condition', p_purchase ->> 'payment_method',
      (p_purchase ->> 'credit_days')::integer, (p_purchase ->> 'due_date')::date,
      (p_purchase ->> 'paid_amount')::double precision, (p_purchase ->> 'balance_due')::double precision
    )
    returning id into v_result_id;
  else
    update public.purchases set
      provider_id = provider, total = (p_purchase->>'total')::double precision,
      date = p_purchase->>'date', reference = p_purchase->>'reference',
      created_by = p_purchase->>'created_by', cash_source = p_purchase->>'cash_source',
      cancelled = coalesce((p_purchase->>'cancelled')::boolean, false)
    where id = p_cloud_id and billar_id = p_billar_id
    returning id into v_result_id;
  end if;

  if v_result_id is null then
    raise exception 'La compra no está disponible en este billar.' using errcode = '42501';
  end if;
  delete from public.purchase_details where purchase_id = v_result_id;
  insert into public.purchase_details (
    purchase_id, product_id, quantity, cost_per_unit, created_by, cancelled
  )
  select v_result_id, (item->>'product_id')::bigint,
    (item->>'quantity')::double precision, (item->>'cost_per_unit')::double precision,
    coalesce(item->>'created_by', p_purchase->>'created_by'),
    coalesce((p_purchase->>'cancelled')::boolean, false)
  from jsonb_array_elements(p_details) as items(item);
  update public.owner_transaction_sync_requests
  set result_id = v_result_id, completed = true
  where request_id = p_request_id;
  return v_result_id;
end;
$$;

-- A separate entry point prevents old servers from acknowledging a payload
-- while silently ignoring its new financial snapshot.
create or replace function public.sync_owner_purchase_with_payment(
  p_request_id uuid, p_billar_id text, p_cloud_id bigint,
  p_purchase jsonb, p_details jsonb
)
returns bigint
language plpgsql
security invoker
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if jsonb_typeof(p_purchase) is distinct from 'object'
     or not (p_purchase ? 'payment_condition') then
    raise exception 'Se requieren condiciones de pago explícitas.' using errcode = '22023';
  end if;
  return public.sync_owner_purchase(p_request_id, p_billar_id, p_cloud_id, p_purchase, p_details);
end;
$$;

revoke all on function public.sync_owner_sale(uuid, text, bigint, jsonb, jsonb) from public, anon;
revoke all on function public.sync_owner_purchase(uuid, text, bigint, jsonb, jsonb) from public, anon;
revoke all on function public.sync_owner_purchase_with_payment(uuid, text, bigint, jsonb, jsonb) from public, anon;
grant execute on function public.sync_owner_sale(uuid, text, bigint, jsonb, jsonb) to authenticated;
grant execute on function public.sync_owner_purchase(uuid, text, bigint, jsonb, jsonb) to authenticated;
grant execute on function public.sync_owner_purchase_with_payment(uuid, text, bigint, jsonb, jsonb) to authenticated;

commit;
