-- Mitigación acotada: bloquea inserciones anónimas en player_avatars.
-- No cambia la visibilidad de los buckets ni los permisos de usuarios autenticados.
-- Aplicar solo con aprobación explícita después de revisar el entorno.
begin;

drop policy if exists deny_anonymous_avatar_insert on storage.objects;
create policy deny_anonymous_avatar_insert on storage.objects
as restrictive for insert to anon
with check (bucket_id is distinct from 'player_avatars');

commit;
