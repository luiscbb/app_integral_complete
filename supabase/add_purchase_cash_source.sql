-- ------------------------------------------------------------
-- Origen del dinero en compras (Caja / Cajero / Transferencia / Tarjeta)
-- Solo las compras con cash_source = 'caja' afectan el corte de efectivo.
-- ------------------------------------------------------------
alter table public.purchases
add column if not exists cash_source text not null default 'caja';

alter table public.purchases
drop constraint if exists purchases_cash_source_check;

alter table public.purchases
add constraint purchases_cash_source_check
check (cash_source in ('caja', 'cajero', 'transferencia', 'tarjeta'));

-- ------------------------------------------------------------
-- Total de compras que SÍ salieron de caja (afectan el corte de efectivo)
-- Reemplaza a get_total_purchases para el cálculo de flujo de caja.
-- ------------------------------------------------------------
create or replace function public.get_total_purchases_cash(
    p_billar_id text,
    p_start timestamptz,
    p_end timestamptz
) returns double precision as $$
    select coalesce(sum(total), 0)
    from public.purchases
    where billar_id = p_billar_id
      and cash_source = 'caja'
      and date::timestamptz between p_start and p_end;
$$ language sql stable;

-- Flujo de caja: ahora resta solo las compras pagadas con dinero de caja.
create or replace function public.get_cash_flow(
    p_billar_id text,
    p_start timestamptz,
    p_end timestamptz
) returns table (
    sales double precision,
    purchases double precision,
    outflows double precision,
    net_cash double precision
) as $$
    select
        public.get_total_sales(p_billar_id, p_start, p_end) as sales,
        public.get_total_purchases_cash(p_billar_id, p_start, p_end) as purchases,
        public.get_total_outflows(p_billar_id, p_start, p_end) as outflows,
        public.get_total_sales(p_billar_id, p_start, p_end)
            - public.get_total_purchases_cash(p_billar_id, p_start, p_end)
            - public.get_total_outflows(p_billar_id, p_start, p_end) as net_cash;
$$ language sql stable;
