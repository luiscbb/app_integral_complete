-- Migración: agregar columnas de puntaje y precisión a match_results
-- para soportar el nuevo módulo de partidas (Bola 8, 9, 10).
-- Copiar y ejecutar en Supabase SQL Editor.

alter table public.match_results
    add column if not exists player_score integer not null default 0,
    add column if not exists opponent_score integer not null default 0,
    add column if not exists accuracy double precision not null default 0,
    add column if not exists efficiency double precision not null default 0;

-- Permitir partidas de training sin jugadores registrados
alter table public.match_results
    alter column player1_id drop not null,
    alter column player2_id drop not null;
