-- Caja unica por negocio. No importa ni modifica turnos locales anteriores.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

create table if not exists public.cash_shared_sessions (
    id bigserial primary key,
    billar_id text not null,
    opened_at timestamptz not null default clock_timestamp(),
    closed_at timestamptz,
    opening_amount numeric(14,2) not null check (opening_amount >= 0),
    closing_amount numeric(14,2),
    expected_amount numeric(14,2),
    difference numeric(14,2),
    opened_by uuid not null,
    closed_by uuid,
    closing_summary jsonb,
    check ((closed_at is null and closing_amount is null and closed_by is null)
        or (closed_at is not null and closing_amount >= 0 and closed_by is not null))
);
create unique index if not exists cash_shared_one_open
    on public.cash_shared_sessions (billar_id) where closed_at is null;
create index if not exists cash_shared_sessions_history
    on public.cash_shared_sessions (billar_id, id desc);

create table if not exists public.cash_shared_movements (
    id bigserial primary key,
    billar_id text not null,
    session_id bigint not null references public.cash_shared_sessions(id),
    kind text not null check (kind in ('contribution', 'expense', 'withdrawal', 'partial')),
    amount numeric(14,2) not null check (amount > 0),
    description text not null,
    payment_method text not null check (payment_method in ('Efectivo', 'Tarjeta', 'Transferencia')),
    created_by uuid not null,
    created_at timestamptz not null default clock_timestamp(),
    check (kind = 'expense' or payment_method = 'Efectivo')
);
create index if not exists cash_shared_movements_scope
    on public.cash_shared_movements (billar_id, created_at, id);

create table if not exists public.cash_shared_requests (
    actor_id uuid not null,
    request_id uuid not null,
    billar_id text not null,
    operation text not null,
    payload jsonb not null,
    result jsonb not null,
    created_at timestamptz not null default clock_timestamp(),
    primary key (actor_id, request_id)
);

alter table public.cash_shared_sessions enable row level security;
alter table public.cash_shared_movements enable row level security;
alter table public.cash_shared_requests enable row level security;
revoke all on public.cash_shared_sessions, public.cash_shared_movements,
    public.cash_shared_requests from public, anon, authenticated;
revoke all on sequence public.cash_shared_sessions_id_seq, public.cash_shared_movements_id_seq
    from public, anon, authenticated;

-- Solo la RPC autorizada puede usar este calculo. Los fondos no son ventas.
create or replace function public.cash_shared_summary(
    requested_billar_id text, start_at timestamptz, end_at timestamptz
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    cash_sales numeric; all_sales numeric; card_sales numeric; transfer_sales numeric;
    cash_purchases numeric; all_purchases numeric; credit_purchases numeric;
    cash_outflows numeric; all_outflows numeric; contributions numeric;
begin
    if exists (
        select 1 from public.sales_history s
        where s.billar_id = requested_billar_id and not coalesce(s.cancelled, false)
          and s.date::timestamptz >= start_at and s.date::timestamptz < end_at
          and (s.total is null or s.total < 0 or coalesce(s.paid, s.total) < 0
            or lower(trim(coalesce(s.payment_method, ''))) not in ('efectivo', 'tarjeta', 'transferencia'))
    ) or exists (
        select 1 from public.purchases p
        where p.billar_id = requested_billar_id and not coalesce(p.cancelled, false)
          and p.date::timestamptz >= start_at and p.date::timestamptz < end_at
          and (p.total is null or p.total < 0 or p.paid_amount < 0
            or (coalesce(p.payment_condition, 'contado') <> 'credito'
                and lower(trim(coalesce(p.payment_method,
                    case when p.cash_source in ('caja', 'cajero') then 'efectivo' else p.cash_source end, '')))
                    not in ('efectivo', 'tarjeta', 'transferencia')))
    ) or exists (
        select 1 from public.cash_outflows o
        where o.billar_id = requested_billar_id and o.created_at >= start_at and o.created_at < end_at
          and (o.amount is null or o.amount <= 0
            or lower(trim(coalesce(o.payment_method, 'Efectivo'))) not in ('efectivo', 'tarjeta', 'transferencia'))
    ) then
        raise exception 'Hay movimientos sincronizados con importes o formas de pago invalidos. Revisar antes del corte.'
            using errcode = '22023';
    end if;
    select coalesce(sum(least(total, coalesce(paid, total))::numeric), 0),
        coalesce(sum(least(total, coalesce(paid, total))::numeric) filter (where lower(trim(payment_method)) = 'efectivo'), 0),
        coalesce(sum(least(total, coalesce(paid, total))::numeric) filter (where lower(trim(payment_method)) = 'tarjeta'), 0),
        coalesce(sum(least(total, coalesce(paid, total))::numeric) filter (where lower(trim(payment_method)) = 'transferencia'), 0)
    into all_sales, cash_sales, card_sales, transfer_sales
    from public.sales_history
    where billar_id = requested_billar_id and not coalesce(cancelled, false)
      and date::timestamptz >= start_at and date::timestamptz < end_at;

    select coalesce(sum(least(total, coalesce(paid_amount, total))::numeric)
            filter (where coalesce(payment_condition, 'contado') <> 'credito'), 0),
        coalesce(sum(least(total, coalesce(paid_amount, total))::numeric)
            filter (where coalesce(payment_condition, 'contado') <> 'credito'
                and cash_source = 'caja'
                and lower(trim(coalesce(payment_method, 'efectivo'))) = 'efectivo'), 0),
        coalesce(sum(total::numeric) filter (where payment_condition = 'credito'), 0)
    into all_purchases, cash_purchases, credit_purchases
    from public.purchases where billar_id = requested_billar_id
      and not coalesce(cancelled, false)
      and date::timestamptz >= start_at and date::timestamptz < end_at;

    with outflows as (
        select amount::numeric as amount, payment_method from public.cash_outflows
        where billar_id = requested_billar_id and created_at >= start_at and created_at < end_at
        union all
        select amount, payment_method from public.cash_shared_movements
        where billar_id = requested_billar_id and created_at >= start_at and created_at < end_at
          and kind <> 'contribution'
    )
    select coalesce(sum(amount), 0),
        coalesce(sum(amount) filter (where lower(trim(coalesce(payment_method, 'Efectivo'))) = 'efectivo'), 0)
    into all_outflows, cash_outflows from outflows;
    select coalesce(sum(amount), 0) into contributions from public.cash_shared_movements
    where billar_id = requested_billar_id and created_at >= start_at and created_at < end_at
      and kind = 'contribution';
    return jsonb_build_object(
        'sales', cash_sales, 'purchases', cash_purchases, 'inflows', contributions,
        'outflows', cash_outflows, 'netCash', cash_sales + contributions - cash_purchases - cash_outflows,
        'totalSales', all_sales, 'totalPurchases', all_purchases, 'totalOutflows', all_outflows,
        'netFlow', all_sales + contributions - all_purchases - all_outflows,
        'cardSales', card_sales, 'transferSales', transfer_sales, 'creditPurchases', credit_purchases);
end;
$$;
revoke all on function public.cash_shared_summary(text,timestamptz,timestamptz)
    from public, anon, authenticated;

create or replace function public.cash_shared_state(
    requested_billar_id text, start_at timestamptz, end_at timestamptz,
    before_session_id bigint default null, before_movement_id bigint default null
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    current_session public.cash_shared_sessions%rowtype;
    result jsonb;
begin
    if not public.has_billar_role(requested_billar_id, array['admin']::text[]) then
        raise exception 'Caja compartida solo esta habilitada para administradores.' using errcode = '42501';
    end if;
    if start_at is null or end_at is null or not isfinite(start_at) or not isfinite(end_at)
       or end_at <= start_at or end_at - start_at > interval '366 days'
       or before_session_id <= 0 or before_movement_id <= 0 then
        raise exception 'Rango o pagina de caja invalidos.' using errcode = '22023';
    end if;
    select * into current_session from public.cash_shared_sessions
    where billar_id = requested_billar_id and closed_at is null;
    with sessions as (
        select * from public.cash_shared_sessions
        where billar_id = requested_billar_id and (before_session_id is null or id < before_session_id)
        order by id desc limit 51
    ), movements as (
        select * from public.cash_shared_movements
        where billar_id = requested_billar_id and created_at >= start_at and created_at < end_at
          and (before_movement_id is null or id < before_movement_id)
        order by id desc limit 51
    )
    select jsonb_build_object(
        'billar_id', requested_billar_id,
        'session', case when current_session.id is null then null else to_jsonb(current_session) end,
        'summary', case when current_session.id is null then '{}'::jsonb
            else public.cash_shared_summary(requested_billar_id, current_session.opened_at, statement_timestamp()) end,
        'sessions', (select coalesce(jsonb_agg(to_jsonb(s) order by id desc), '[]'::jsonb)
            from (select s.*, case when s.closed_at is null then false else
                public.cash_shared_summary(requested_billar_id, s.opened_at, s.closed_at)
                    is distinct from s.closing_summary end as needs_reconciliation
                from sessions s order by id desc limit 50) s),
        'more_sessions', (select count(*) > 50 from sessions),
        'movements', (select coalesce(jsonb_agg(to_jsonb(m) order by id desc), '[]'::jsonb)
            from (select * from movements order by id desc limit 50) m),
        'more_movements', (select count(*) > 50 from movements)
    ) into result;
    return result;
end;
$$;

create or replace function public.cash_shared_request_status(requested_billar_id text, requested_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
    if not public.has_billar_role(requested_billar_id, array['admin']::text[]) then
        raise exception 'Sin permiso para consultar solicitudes de caja.' using errcode = '42501';
    end if;
    return (select result from public.cash_shared_requests
        where actor_id = auth.uid() and request_id = requested_id and billar_id = requested_billar_id);
end;
$$;

create or replace function public.cash_shared_apply(
    requested_billar_id text, requested_id uuid, operation text, payload jsonb
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    previous public.cash_shared_requests%rowtype;
    current_session public.cash_shared_sessions%rowtype;
    amount numeric;
    next_opening numeric;
    result jsonb;
    summary jsonb;
    cutoff timestamptz;
    new_id bigint;
    expected numeric;
begin
    if not public.has_billar_role(requested_billar_id, array['admin']::text[]) then
        raise exception 'Caja compartida solo esta habilitada para administradores.' using errcode = '42501';
    end if;
    if requested_id is null or operation is null or operation not in ('open', 'move', 'close', 'cancel')
       or payload is null or jsonb_typeof(payload) <> 'object' then
        raise exception 'Solicitud de caja invalida.' using errcode = '22023';
    end if;
    -- Tambien serializa cancelar/reintentar una respuesta perdida entre telefonos.
    perform pg_advisory_xact_lock(hashtextextended('shared-cash:' || requested_billar_id, 0));
    select * into previous from public.cash_shared_requests
    where actor_id = auth.uid() and request_id = requested_id;
    if found then
        if previous.billar_id <> requested_billar_id then
            raise exception 'La solicitud pertenece a otro negocio.' using errcode = '42501';
        end if;
        if operation = 'cancel' then return previous.result; end if;
        if previous.operation <> operation or previous.payload <> payload then
            raise exception 'La solicitud ya fue utilizada o cancelada.' using errcode = '22023';
        end if;
        return previous.result;
    end if;
    if operation = 'cancel' then
        result := jsonb_build_object('billar_id', requested_billar_id, 'cancelled', true);
    else
        if jsonb_typeof(payload->'amount') is distinct from 'number' then
            raise exception 'Importe de caja invalido.' using errcode = '22023';
        end if;
        amount := (payload->>'amount')::numeric;
        if amount < 0 or amount >= 1000000000000 or amount <> round(amount, 2)
           or (operation = 'move' and amount = 0) then
            raise exception 'Usa un importe valido con hasta dos decimales.' using errcode = '22023';
        end if;
        select * into current_session from public.cash_shared_sessions
        where billar_id = requested_billar_id and closed_at is null for update;
        if operation = 'open' then
            if current_session.id is not null then
                raise exception 'Ya hay un turno abierto en este negocio.' using errcode = '22023';
            end if;
            if payload - 'amount' <> '{}'::jsonb then
                raise exception 'Apertura invalida.' using errcode = '22023';
            end if;
            insert into public.cash_shared_sessions(billar_id, opening_amount, opened_by)
            values (requested_billar_id, amount, auth.uid()) returning id into new_id;
            result := jsonb_build_object('billar_id', requested_billar_id, 'id', new_id);
        else
            if current_session.id is null
                or jsonb_typeof(payload->'session_id') is distinct from 'number'
                or payload->>'session_id' <> current_session.id::text then
                raise exception 'El turno cambio. Actualiza caja antes de operar.' using errcode = '22023';
            end if;
            if operation = 'move' then
                if payload - array['amount','session_id','kind','description','payment_method'] <> '{}'::jsonb
                   or coalesce(payload->>'kind','') not in ('contribution','expense','withdrawal','partial')
                   or jsonb_typeof(payload->'description') is distinct from 'string'
                   or length(trim(payload->>'description')) not between 1 and 500
                   or coalesce(payload->>'payment_method','') not in ('Efectivo','Tarjeta','Transferencia')
                   or (payload->>'kind' <> 'expense' and payload->>'payment_method' <> 'Efectivo') then
                    raise exception 'Movimiento de caja invalido.' using errcode = '22023';
                end if;
                insert into public.cash_shared_movements
                    (billar_id, session_id, kind, amount, description, payment_method, created_by)
                values (requested_billar_id, current_session.id, payload->>'kind', amount,
                    trim(payload->>'description'), payload->>'payment_method', auth.uid())
                returning id into new_id;
                result := jsonb_build_object('billar_id', requested_billar_id, 'id', new_id);
            else
                if payload - array['amount','session_id','next_opening'] <> '{}'::jsonb then
                    raise exception 'Cierre invalido.' using errcode = '22023';
                end if;
                if payload ? 'next_opening' then
                    if jsonb_typeof(payload->'next_opening') is distinct from 'number' then
                        raise exception 'Fondo del siguiente turno invalido.' using errcode = '22023';
                    end if;
                    next_opening := (payload->>'next_opening')::numeric;
                    if next_opening < 0 or next_opening >= 1000000000000
                       or next_opening <> round(next_opening, 2) then
                        raise exception 'Fondo del siguiente turno invalido.' using errcode = '22023';
                    end if;
                end if;
                cutoff := clock_timestamp();
                summary := public.cash_shared_summary(requested_billar_id, current_session.opened_at, cutoff);
                expected := round(current_session.opening_amount + (summary->>'netCash')::numeric, 2);
                update public.cash_shared_sessions set closed_at = cutoff, closing_amount = amount,
                    expected_amount = expected, difference = amount - expected,
                    closed_by = auth.uid(), closing_summary = summary
                where id = current_session.id;
                if next_opening is not null then
                    insert into public.cash_shared_sessions (billar_id, opened_at, opening_amount, opened_by)
                    values (requested_billar_id, cutoff, next_opening, auth.uid());
                end if;
                result := jsonb_build_object('billar_id', requested_billar_id, 'id', current_session.id,
                    'summary', summary || jsonb_build_object('openingAmount', current_session.opening_amount,
                        'expected', expected, 'difference', amount - expected));
            end if;
        end if;
    end if;
    insert into public.cash_shared_requests(actor_id,request_id,billar_id,operation,payload,result)
    values (auth.uid(),requested_id,requested_billar_id,operation,payload,result);
    return result;
end;
$$;

revoke all on function public.cash_shared_state(text,timestamptz,timestamptz,bigint,bigint)
    from public, anon, authenticated;
revoke all on function public.cash_shared_request_status(text,uuid) from public, anon, authenticated;
revoke all on function public.cash_shared_apply(text,uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.cash_shared_state(text,timestamptz,timestamptz,bigint,bigint) to authenticated;
grant execute on function public.cash_shared_request_status(text,uuid) to authenticated;
grant execute on function public.cash_shared_apply(text,uuid,text,jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;
