-- Lectura limitada de identidad para el inicio de personal.
-- No concede SELECT ni escritura sobre billar_settings.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

create or replace function public.staff_business_profile(requested_billar_id text)
returns table (billar_id text, business_name text, logo_url text, primary_color integer)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
    if not exists (
        select 1 from public.business_memberships m
        where m.user_id = auth.uid()
          and m.billar_id = requested_billar_id
          and m.role = 'manager' and m.username is not null
          and m.is_active and not m.must_change_password
    ) then
        raise exception 'La cuenta de personal no tiene acceso activo a este billar.'
            using errcode = '42501';
    end if;
    return query
        select s.billar_id::text, s.business_name::text, s.logo_url::text, s.primary_color
        from public.billar_settings s
        where s.billar_id = requested_billar_id;
    if not found then
        raise exception 'No se encontró la identidad del negocio.'
            using errcode = '55000';
    end if;
end;
$$;

revoke all on function public.staff_business_profile(text) from public, anon, authenticated;
grant execute on function public.staff_business_profile(text) to authenticated;
notify pgrst, 'reload schema';
commit;
