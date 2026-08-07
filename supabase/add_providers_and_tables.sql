-- ============================================================
-- SUPABASE: Proveedores, relación proveedores-productos y mesas
-- Ejecutar este script en Supabase SQL Editor
-- ============================================================

-- ============================================================
-- 1. TABLA providers
-- ============================================================
create table if not exists public.providers (
    id bigint primary key,
    name text not null,
    phone text default '',
    email text default '',
    address text default '',
    contact_name text default '',
    notes text default '',
    category text default 'General',
    visit_days text default '',
    billar_id text not null default 'BILLAR_001',
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

alter table public.providers enable row level security;

drop policy if exists "providers_select" on public.providers;
drop policy if exists "providers_insert" on public.providers;
drop policy if exists "providers_update" on public.providers;
drop policy if exists "providers_delete" on public.providers;

create policy "providers_select" on public.providers for
select to authenticated using (billar_id = auth.uid()::text or true);

create policy "providers_insert" on public.providers for
insert to authenticated with check (true);

create policy "providers_update" on public.providers for
update to authenticated using (true) with check (true);

create policy "providers_delete" on public.providers for
delete to authenticated using (true);

create index if not exists idx_providers_billar on public.providers (billar_id);

-- Trigger updated_at
drop trigger if exists providers_updated_at on public.providers;
create trigger providers_updated_at before update on public.providers
    for each row execute function public.set_updated_at();

-- Secuencia para providers.id (la app envía id local; esto es fallback)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_sequences
        WHERE schemaname = 'public' AND sequencename = 'providers_id_seq'
    ) THEN
        CREATE SEQUENCE public.providers_id_seq AS bigint START WITH 1;
        ALTER TABLE public.providers ALTER COLUMN id SET DEFAULT nextval('public.providers_id_seq');
        ALTER SEQUENCE public.providers_id_seq OWNED BY public.providers.id;
    END IF;
END $$;

-- ============================================================
-- 2. TABLA provider_products
-- ============================================================
create table if not exists public.provider_products (
    id bigint generated always as identity primary key,
    provider_id bigint not null references public.providers (id) on delete cascade,
    product_id bigint not null references public.products (id) on delete cascade,
    created_at timestamptz default now(),
    unique (provider_id, product_id)
);

alter table public.provider_products enable row level security;

drop policy if exists "provider_products_select" on public.provider_products;
drop policy if exists "provider_products_insert" on public.provider_products;
drop policy if exists "provider_products_delete" on public.provider_products;

create policy "provider_products_select" on public.provider_products for
select to authenticated using (true);

create policy "provider_products_insert" on public.provider_products for
insert to authenticated with check (true);

create policy "provider_products_delete" on public.provider_products for
delete to authenticated using (true);

create index if not exists idx_provider_products_provider on public.provider_products (provider_id);
create index if not exists idx_provider_products_product on public.provider_products (product_id);

-- ============================================================
-- 3. TABLA billiard_tables
-- ============================================================
create table if not exists public.billiard_tables (
    id bigint not null,
    billar_id text not null default 'BILLAR_001',
    name text not null default 'Mesa',
    table_type text not null default 'Pool',
    is_occupied int not null default 0,
    start_time timestamptz,
    orders text default '[]',
    created_at timestamptz default now(),
    updated_at timestamptz default now(),
    primary key (billar_id, id)
);

alter table public.billiard_tables enable row level security;

drop policy if exists "billiard_tables_select" on public.billiard_tables;
drop policy if exists "billiard_tables_insert" on public.billiard_tables;
drop policy if exists "billiard_tables_update" on public.billiard_tables;
drop policy if exists "billiard_tables_delete" on public.billiard_tables;

create policy "billiard_tables_select" on public.billiard_tables for
select to authenticated using (true);

create policy "billiard_tables_insert" on public.billiard_tables for
insert to authenticated with check (true);

create policy "billiard_tables_update" on public.billiard_tables for
update to authenticated using (true) with check (true);

create policy "billiard_tables_delete" on public.billiard_tables for
delete to authenticated using (true);

create index if not exists idx_billiard_tables_billar on public.billiard_tables (billar_id);

-- Trigger updated_at
drop trigger if exists billiard_tables_updated_at on public.billiard_tables;
create trigger billiard_tables_updated_at before update on public.billiard_tables
    for each row execute function public.set_updated_at();

-- ============================================================
-- 4. (OPCIONAL) Borrar proveedores antiguos sin estructura completa
-- Solo usar si la tabla providers anterior tenía solo name/phone/address/category
-- y quieres empezar desde cero:
-- truncate table public.providers cascade;
-- truncate table public.provider_products cascade;
-- truncate table public.billiard_tables cascade;
-- ============================================================
