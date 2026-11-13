-- Comandas reutiliza billiard_tables: table_type identifica la pantalla y
-- orders conserva el pedido abierto que aparta existencias hasta cobrar.
-- Ejecutar una sola vez (o repetir de forma segura) en Supabase SQL Editor.

alter table public.billiard_tables
  add column if not exists table_type text not null default 'Billar';

alter table public.billiard_tables
  add column if not exists is_occupied integer not null default 0;

alter table public.billiard_tables
  add column if not exists start_time timestamptz;

alter table public.billiard_tables
  add column if not exists orders text not null default '[]';

alter table public.billiard_tables
  add column if not exists is_deleted integer not null default 0;

create index if not exists idx_billiard_tables_type_occupied
  on public.billiard_tables (billar_id, table_type, is_occupied);

alter table public.billiard_tables enable row level security;

drop policy if exists "billiard_tables_select" on public.billiard_tables;
drop policy if exists "billiard_tables_insert" on public.billiard_tables;
drop policy if exists "billiard_tables_update" on public.billiard_tables;
drop policy if exists "billiard_tables_delete" on public.billiard_tables;

create policy "billiard_tables_select" on public.billiard_tables
  for select to authenticated using (true);
create policy "billiard_tables_insert" on public.billiard_tables
  for insert to authenticated with check (true);
create policy "billiard_tables_update" on public.billiard_tables
  for update to authenticated using (true) with check (true);
create policy "billiard_tables_delete" on public.billiard_tables
  for delete to authenticated using (true);

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'billiard_tables'
  ) then
    alter publication supabase_realtime add table public.billiard_tables;
  end if;
end $$;
