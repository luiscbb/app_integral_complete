-- ============================================================
-- MIGRACION SUPABASE - Baumar POS
-- Ejecutar este script en Supabase SQL Editor
-- ============================================================

-- ============================================================
-- 1. BILLAR_SETTINGS (nueva - config del negocio por usuario)
-- ============================================================
create table if not exists public.billar_settings (
    id uuid default uuid_generate_v4 () primary key,
    user_id uuid not null references auth.users (id) on delete cascade,
    billar_id text not null default 'BILLAR_001',
    business_name text not null default 'Baumar Billar',
    table_count int not null default 8,
    hourly_rate double precision not null default 0.0,
    primary_color int default 0xFFE53935,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

alter table public.billar_settings enable row level security;

create policy "b_settings_select" on public.billar_settings for
select to authenticated using (user_id = auth.uid ());

create policy "b_settings_insert" on public.billar_settings for
insert
    to authenticated
with
    check (user_id = auth.uid ());

create policy "b_settings_update" on public.billar_settings for
update to authenticated using (user_id = auth.uid ())
with
    check (user_id = auth.uid ());

create unique index if not exists idx_billar_settings_user on public.billar_settings (user_id);

-- trigger updated_at
create or replace function public.set_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end;
$$ language plpgsql;

drop trigger if exists billar_settings_updated_at on public.billar_settings;

create trigger billar_settings_updated_at before update on public.billar_settings
    for each row execute function public.set_updated_at();

-- ============================================================
-- 2. SALES_HISTORY: agregar columna PAUSADA y secuencia para ID
-- ============================================================
alter table public.sales_history
add column if not exists paid double precision not null default 0;

-- Asegurar que sales_history.id tenga secuencia (el codigo Flutter
-- hace insert() sin enviar id y espera que Supabase lo genere)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_sequences
        WHERE schemaname = 'public' AND sequencename = 'sales_history_id_seq'
    ) THEN
        CREATE SEQUENCE public.sales_history_id_seq AS bigint START WITH 1;
        ALTER TABLE public.sales_history ALTER COLUMN id SET DEFAULT nextval('public.sales_history_id_seq');
        ALTER SEQUENCE public.sales_history_id_seq OWNED BY public.sales_history.id;
    END IF;
END $$;

-- ============================================================
-- 3. PURCHASES: agregar billar_id, synced y cloud_id
-- ============================================================
alter table public.purchases
add column if not exists billar_id text not null default 'BILLAR_001';

alter table public.purchases
add column if not exists synced integer not null default 0;

alter table public.purchases add column if not exists cloud_id text;

-- ============================================================
-- 4. PENDING_SALES (tabla nueva para quick_sale)
-- ============================================================
create table if not exists public.pending_sales (
    id uuid default uuid_generate_v4 () primary key,
    billar_id text not null default 'BILLAR_001',
    product text not null,
    quantity int not null,
    price double precision not null,
    created_at timestamptz default now()
);

alter table public.pending_sales enable row level security;

drop policy if exists "pending_sales_select" on public.pending_sales;
drop policy if exists "pending_sales_insert" on public.pending_sales;

create policy "pending_sales_select" on public.pending_sales for
select to authenticated using (true);

create policy "pending_sales_insert" on public.pending_sales for
insert
    to authenticated
with
    check (true);

-- ============================================================
-- 5. CORREGIR POLICIES players (asegurar que RLS estan activas)
-- ============================================================
-- Solo aseguramos que RLS esta on (ya lo esta segun tu schema)
-- Si no las tienes, descomenta:
-- alter table public.players enable row level security;
-- alter table public.match_results enable row level security;

-- ============================================================
-- 6. TRIGGER updated_at para players (si no existe)
-- ============================================================
drop trigger if exists players_updated_at on public.players;

create trigger players_updated_at before update on public.players
    for each row execute function public.set_updated_at();

-- ============================================================
-- 7. INDICES recomendados adicionales
-- ============================================================
create index if not exists idx_sales_history_date on public.sales_history (date desc);

create index if not exists idx_purchases_date on public.purchases (date desc);

create index if not exists idx_pending_sales_billar on public.pending_sales (billar_id);

-- ============================================================
-- 8. (OPCIONAL) TABLA sales VIEJA - considerar eliminar
-- Esta tabla parece estar en desuso. Tu app usa
-- sales_history + pending_sales. Si sales esta vacia,
-- puedes ejecutar:
--   DROP TABLE public.sales CASCADE;
-- ============================================================

-- ============================================================
-- VERIFICACION: lista las tablas publicas
-- ============================================================
-- select table_name from information_schema.tables where table_schema = 'public' order by table_name;