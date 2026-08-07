-- ------------------------------------------------------------
-- 1. COMPRAS: asegurar columnas de sincronizacion
-- ------------------------------------------------------------
alter table public.purchases
add column if not exists provider_id int references public.providers(id) on delete set null;

alter table public.purchases
add column if not exists reference text default '';

-- ------------------------------------------------------------
-- 2. KARDEX / MOVIMIENTOS DE INVENTARIO
-- ------------------------------------------------------------
create table if not exists public.inventory_movements (
    id bigserial primary key,
    billar_id text not null default 'BILLAR_001',
    product_id int not null references public.products(id) on delete restrict,
    movement_type text not null check (movement_type in ('sale','purchase','adjustment','return','initial')),
    quantity double precision not null,
    unit_cost double precision not null default 0,
    unit_price double precision not null default 0,
    reference_id int,                 -- id de venta, compra o ajuste relacionado
    reference_type text,              -- 'sales_history', 'purchases', 'adjustment'
    notes text default '',
    created_at timestamptz default now()
);

alter table public.inventory_movements enable row level security;

drop policy if exists "inventory_movements_select" on public.inventory_movements;
drop policy if exists "inventory_movements_insert" on public.inventory_movements;
drop policy if exists "inventory_movements_update" on public.inventory_movements;
drop policy if exists "inventory_movements_delete" on public.inventory_movements;

create policy "inventory_movements_select" on public.inventory_movements
    for select to authenticated using (true);

create policy "inventory_movements_insert" on public.inventory_movements
    for insert to authenticated with check (true);

create policy "inventory_movements_update" on public.inventory_movements
    for update to authenticated using (true) with check (true);

create policy "inventory_movements_delete" on public.inventory_movements
    for delete to authenticated using (true);

create index if not exists idx_inventory_movements_product on public.inventory_movements (product_id, created_at desc);
create index if not exists idx_inventory_movements_billar on public.inventory_movements (billar_id, created_at desc);

-- ------------------------------------------------------------
-- 3. RETIROS / GASTOS / MOVIMIENTOS DE CAJA
-- ------------------------------------------------------------
create table if not exists public.cash_outflows (
    id bigserial primary key,
    billar_id text not null default 'BILLAR_001',
    outflow_type text not null check (outflow_type in ('withdrawal','expense','refund','other')),
    amount double precision not null check (amount > 0),
    description text not null default '',
    payment_method text default 'Efectivo',
    created_by text default '',
    created_at timestamptz default now()
);

alter table public.cash_outflows enable row level security;

drop policy if exists "cash_outflows_select" on public.cash_outflows;
drop policy if exists "cash_outflows_insert" on public.cash_outflows;
drop policy if exists "cash_outflows_update" on public.cash_outflows;
drop policy if exists "cash_outflows_delete" on public.cash_outflows;

create policy "cash_outflows_select" on public.cash_outflows
    for select to authenticated using (true);

create policy "cash_outflows_insert" on public.cash_outflows
    for insert to authenticated with check (true);

create policy "cash_outflows_update" on public.cash_outflows
    for update to authenticated using (true) with check (true);

create policy "cash_outflows_delete" on public.cash_outflows
    for delete to authenticated using (true);

create index if not exists idx_cash_outflows_billar on public.cash_outflows (billar_id, created_at desc);

-- ------------------------------------------------------------
-- 4. TURNOS / CORTES DE CAJA
-- ------------------------------------------------------------
create table if not exists public.cashier_sessions (
    id bigserial primary key,
    billar_id text not null default 'BILLAR_001',
    opened_at timestamptz not null default now(),
    closed_at timestamptz,
    opening_amount double precision not null default 0,
    closing_amount double precision,
    expected_amount double precision,
    difference double precision,
    is_closed boolean not null default false,
    partial_closures jsonb default '[]',  -- historial de cortes parciales
    notes text default '',
    created_by text default '',
    closed_by text default ''
);

alter table public.cashier_sessions enable row level security;

drop policy if exists "cashier_sessions_select" on public.cashier_sessions;
drop policy if exists "cashier_sessions_insert" on public.cashier_sessions;
drop policy if exists "cashier_sessions_update" on public.cashier_sessions;

create policy "cashier_sessions_select" on public.cashier_sessions
    for select to authenticated using (true);

create policy "cashier_sessions_insert" on public.cashier_sessions
    for insert to authenticated with check (true);

create policy "cashier_sessions_update" on public.cashier_sessions
    for update to authenticated using (true) with check (true);

create index if not exists idx_cashier_sessions_billar on public.cashier_sessions (billar_id, opened_at desc);

-- ------------------------------------------------------------
-- 5. FUNCIONES AUXILIARES PARA REPORTES
-- ------------------------------------------------------------

-- Total de ventas en un rango de fechas
-- Nota: `date` en sales_history es TEXT (ISO8601 guardado desde Flutter),
-- por eso se castea explícitamente a timestamptz antes de comparar.
create or replace function public.get_total_sales(
    p_billar_id text,
    p_start timestamptz,
    p_end timestamptz
) returns double precision as $$
    select coalesce(sum(total), 0)
    from public.sales_history
    where billar_id = p_billar_id
      and date::timestamptz between p_start and p_end;
$$ language sql stable;

-- Total de compras en un rango de fechas
-- Nota: `date` en purchases también es TEXT (ISO8601), mismo cast.
create or replace function public.get_total_purchases(
    p_billar_id text,
    p_start timestamptz,
    p_end timestamptz
) returns double precision as $$
    select coalesce(sum(total), 0)
    from public.purchases
    where billar_id = p_billar_id
      and date::timestamptz between p_start and p_end;
$$ language sql stable;

-- Total de retiros/gastos en un rango de fechas
create or replace function public.get_total_outflows(
    p_billar_id text,
    p_start timestamptz,
    p_end timestamptz
) returns double precision as $$
    select coalesce(sum(amount), 0)
    from public.cash_outflows
    where billar_id = p_billar_id
      and created_at between p_start and p_end;
$$ language sql stable;

-- Flujo de caja simple: ingresos - egresos
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
        public.get_total_purchases(p_billar_id, p_start, p_end) as purchases,
        public.get_total_outflows(p_billar_id, p_start, p_end) as outflows,
        public.get_total_sales(p_billar_id, p_start, p_end)
            - public.get_total_purchases(p_billar_id, p_start, p_end)
            - public.get_total_outflows(p_billar_id, p_start, p_end) as net_cash;
$$ language sql stable;

-- ------------------------------------------------------------
-- 6. INDICES ADICIONALES
-- ------------------------------------------------------------
create index if not exists idx_sales_history_billar_date on public.sales_history (billar_id, date desc);
create index if not exists idx_purchases_billar_date on public.purchases (billar_id, date desc);
