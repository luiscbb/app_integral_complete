create table if not exists public.billar_tournaments (
    id uuid primary key default gen_random_uuid(),
    billar_id text not null,
    name text not null check (char_length(name) between 1 and 120),
    tournament_format text not null check (
        tournament_format in ('single', 'double', 'liga', 'groups', 'swiss')
    ),
    capacity integer check (capacity is null or capacity between 2 and 256),
    race_to integer not null default 3 check (race_to between 1 and 99),
    sets_to_play integer not null default 1 check (sets_to_play between 1 and 99 and sets_to_play % 2 = 1),
    guaranteed_pool numeric(12,2) not null default 0 check (guaranteed_pool >= 0),
    entry_fee numeric(12,2) not null default 0 check (entry_fee >= 0),
    time_fee numeric(12,2) not null default 0 check (time_fee >= 0),
    prizes jsonb not null default '[]'::jsonb
        check (jsonb_typeof(prizes) = 'array'),
    game_type text not null default 'Bola 9'
        check (game_type in ('Bola 8', 'Bola 9', 'Bola 10')),
    playoff_qualifiers integer not null default 0
        check (playoff_qualifiers in (0, 8, 16)),
    entries jsonb not null default '[]'::jsonb
        check (jsonb_typeof(entries) = 'array'),
    matches jsonb not null default '[]'::jsonb
        constraint billar_tournaments_matches_array_check
        check (jsonb_typeof(matches) = 'array'),
    is_active boolean not null default true,
    created_by uuid not null default auth.uid() references auth.users(id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.billar_tournaments
    add column if not exists race_to integer not null default 3;
alter table public.billar_tournaments
    add column if not exists sets_to_play integer not null default 1;
alter table public.billar_tournaments
    add column if not exists matches jsonb not null default '[]'::jsonb;
alter table public.billar_tournaments
    add column if not exists guaranteed_pool numeric(12,2) not null default 0;
alter table public.billar_tournaments
    add column if not exists entry_fee numeric(12,2) not null default 0;
alter table public.billar_tournaments
    add column if not exists time_fee numeric(12,2) not null default 0;
alter table public.billar_tournaments
    add column if not exists prizes jsonb not null default '[]'::jsonb;
alter table public.billar_tournaments
    add column if not exists game_type text not null default 'Bola 9';
alter table public.billar_tournaments
    add column if not exists playoff_qualifiers integer not null default 0;

-- Un torneo antiguo sin sorteo puede actualizarse al nuevo top 8 sin alterar resultados.
alter table public.billar_tournaments
    drop constraint if exists billar_tournaments_playoff_qualifiers_check;

update public.billar_tournaments
set playoff_qualifiers = 8
where playoff_qualifiers = 16
  and matches = '[]'::jsonb;

alter table public.billar_tournaments
    add constraint billar_tournaments_playoff_qualifiers_check
    check (
        playoff_qualifiers in (0, 8)
        or (playoff_qualifiers = 16 and matches <> '[]'::jsonb)
    );

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'billar_tournaments_race_to_check'
          and conrelid = 'public.billar_tournaments'::regclass
    ) then
        alter table public.billar_tournaments
            add constraint billar_tournaments_race_to_check check (race_to between 1 and 99);
    end if;
    if not exists (
        select 1 from pg_constraint
        where conname = 'billar_tournaments_sets_to_play_check'
          and conrelid = 'public.billar_tournaments'::regclass
    ) then
        alter table public.billar_tournaments
            add constraint billar_tournaments_sets_to_play_check
            check (sets_to_play between 1 and 99 and sets_to_play % 2 = 1);
    end if;
    if not exists (
        select 1 from pg_constraint
        where conname = 'billar_tournaments_matches_array_check'
          and conrelid = 'public.billar_tournaments'::regclass
    ) then
        alter table public.billar_tournaments
            add constraint billar_tournaments_matches_array_check
            check (jsonb_typeof(matches) = 'array');
    end if;
    if not exists (
        select 1 from pg_constraint
        where conname = 'billar_tournaments_prizes_array_check'
          and conrelid = 'public.billar_tournaments'::regclass
    ) then
        alter table public.billar_tournaments
            add constraint billar_tournaments_prizes_array_check
            check (jsonb_typeof(prizes) = 'array');
    end if;
    if not exists (
        select 1 from pg_constraint
        where conname = 'billar_tournaments_finance_nonnegative_check'
          and conrelid = 'public.billar_tournaments'::regclass
    ) then
        alter table public.billar_tournaments
            add constraint billar_tournaments_finance_nonnegative_check
            check (guaranteed_pool >= 0 and entry_fee >= 0 and time_fee >= 0);
    end if;
    if not exists (
        select 1 from pg_constraint
        where conname = 'billar_tournaments_game_type_check'
          and conrelid = 'public.billar_tournaments'::regclass
    ) then
        alter table public.billar_tournaments
            add constraint billar_tournaments_game_type_check
            check (game_type in ('Bola 8', 'Bola 9', 'Bola 10'));
    end if;
end;
$$;

create index if not exists idx_billar_tournaments_active
    on public.billar_tournaments (billar_id, is_active, created_at desc);

create or replace function public.validate_tournament_entries()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if tg_op = 'UPDATE' then
        if old.matches <> '[]'::jsonb then
            if new.entries is distinct from old.entries then
                raise exception 'No se pueden cambiar los inscritos después del sorteo del cuadro.';
            end if;
            if new.race_to is distinct from old.race_to then
                raise exception 'No se puede cambiar la cantidad después del sorteo del cuadro.';
            end if;
            if new.sets_to_play is distinct from old.sets_to_play then
                raise exception 'No se puede cambiar el número de sets después del sorteo del cuadro.';
            end if;
            if new.guaranteed_pool is distinct from old.guaranteed_pool
               or new.entry_fee is distinct from old.entry_fee
               or new.time_fee is distinct from old.time_fee
               or new.prizes is distinct from old.prizes then
                raise exception 'No se pueden cambiar los importes después del sorteo del cuadro.';
            end if;
            if new.game_type is distinct from old.game_type
               or new.playoff_qualifiers is distinct from old.playoff_qualifiers then
                raise exception 'No se puede cambiar el juego o la fase final después de iniciar el torneo.';
            end if;
        end if;
    end if;

    if new.capacity is not null
       and jsonb_array_length(new.entries) > new.capacity then
        raise exception 'El torneo no puede superar el cupo configurado.';
    end if;

    if new.guaranteed_pool < 0 or new.entry_fee < 0 or new.time_fee < 0 then
        raise exception 'Los importes no pueden ser negativos.';
    end if;

    if exists (
        select 1
        from jsonb_array_elements(new.prizes) prize
        group by (prize ->> 'place')::integer
        having count(*) > 1
    ) then
        raise exception 'No puedes asignar premios dos veces al mismo lugar.';
    end if;

    if (
        select coalesce(sum((prize ->> 'value')::numeric), 0)
        from jsonb_array_elements(new.prizes) prize
        where prize ->> 'type' = 'percentage'
    ) > 100 then
        raise exception 'Los porcentajes de premios no pueden superar el 100%%.';
    end if;

    if exists (
        select 1
        from jsonb_array_elements(new.entries) entry
        where coalesce(entry ->> 'player_code', '') <> ''
        group by entry ->> 'player_code'
        having count(*) > 1
    ) then
        raise exception 'Un jugador no puede inscribirse dos veces en el torneo.';
    end if;

    return new;
end;
$$;

drop trigger if exists billar_tournaments_validate_entries
    on public.billar_tournaments;
create trigger billar_tournaments_validate_entries
before insert or update of entries, capacity, race_to, sets_to_play,
    guaranteed_pool, entry_fee, time_fee, prizes, game_type,
    playoff_qualifiers on public.billar_tournaments
for each row execute function public.validate_tournament_entries();

alter table public.billar_tournaments enable row level security;

drop policy if exists "billar_tournaments_staff_select" on public.billar_tournaments;
create policy "billar_tournaments_staff_select"
on public.billar_tournaments for select to authenticated
using (public.has_billar_role(billar_id, array['admin', 'manager']::text[]));

drop policy if exists "billar_tournaments_staff_insert" on public.billar_tournaments;
create policy "billar_tournaments_staff_insert"
on public.billar_tournaments for insert to authenticated
with check (public.has_billar_role(billar_id, array['admin', 'manager']::text[]));

drop policy if exists "billar_tournaments_staff_update" on public.billar_tournaments;
create policy "billar_tournaments_staff_update"
on public.billar_tournaments for update to authenticated
using (public.has_billar_role(billar_id, array['admin', 'manager']::text[]))
with check (public.has_billar_role(billar_id, array['admin', 'manager']::text[]));

drop policy if exists "billar_tournaments_staff_delete" on public.billar_tournaments;
create policy "billar_tournaments_staff_delete"
on public.billar_tournaments for delete to authenticated
using (public.has_billar_role(billar_id, array['admin', 'manager']::text[]));

drop trigger if exists billar_tournaments_updated_at on public.billar_tournaments;
create trigger billar_tournaments_updated_at
before update on public.billar_tournaments
for each row execute function public.set_updated_at();

notify pgrst, 'reload schema';
