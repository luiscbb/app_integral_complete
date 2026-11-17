-- Preparation only. Requires staff_purchase_recording_partial.sql and
-- staff_provider_operations_partial.sql. Execution remains revoked.
-- Serializes with the original operation through its request row, never
-- interprets a missing row as proof that a delayed request cannot arrive.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

create or replace function public.resolve_staff_purchase_request(
    p_request_id uuid,
    p_billar_id text,
    p_kind text,
    p_request_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
set lock_timeout = '3s'
as $$
declare
    actor uuid := auth.uid();
    metadata jsonb := auth.jwt() -> 'app_metadata';
    request_row record;
    receipt jsonb;
begin
    if actor is null or metadata ->> 'account_type' is distinct from 'staff'
       or metadata ->> 'billar_id' is distinct from p_billar_id then
        raise exception 'Se requiere una cuenta de personal de este billar.' using errcode = '42501';
    end if;
    if p_request_id is null or p_billar_id is null or btrim(p_billar_id) = ''
       or p_kind is null or p_kind not in ('purchase', 'provider')
       or jsonb_typeof(p_request_payload) is distinct from 'object' then
        raise exception 'La solicitud de resolución no es válida.' using errcode = '22023';
    end if;
    if p_kind = 'purchase' then
        if not (p_request_payload ?& array['provider_id', 'reference', 'cash_source', 'items'])
           or (select count(*) from jsonb_object_keys(p_request_payload))
              <> (case when p_request_payload ? 'payment' then 5 else 4 end) then
            raise exception 'El contenido de la compra no es válido.' using errcode = '22023';
        end if;
    else
        if not (p_request_payload ?& array['provider_id', 'operation', 'provider', 'product_ids'])
           or (select count(*) from jsonb_object_keys(p_request_payload)) <> 4 then
            raise exception 'El contenido del proveedor no es válido.' using errcode = '22023';
        end if;
    end if;
    perform 1 from public.business_memberships membership
    where membership.user_id = actor and membership.billar_id = p_billar_id
      and membership.role = 'manager' and membership.is_active
      and not membership.must_change_password
      and membership.username is not null and btrim(membership.username) <> ''
      and 'purchases' = any(membership.allowed_modules)
    for share;
    if not found then
        raise exception 'No tienes permiso para resolver compras y proveedores.' using errcode = '42501';
    end if;

    if p_kind = 'purchase' then
        insert into public.staff_purchase_requests(request_id, billar_id, actor_id, request_payload)
        values (p_request_id, p_billar_id, actor, p_request_payload)
        on conflict (request_id) do nothing;
        select * into strict request_row from public.staff_purchase_requests
        where request_id = p_request_id for update;
    else
        insert into public.staff_provider_requests(request_id, billar_id, actor_id, request_payload)
        values (p_request_id, p_billar_id, actor, p_request_payload)
        on conflict (request_id) do nothing;
        select * into strict request_row from public.staff_provider_requests
        where request_id = p_request_id for update;
    end if;
    if request_row.billar_id <> p_billar_id or request_row.actor_id <> actor
       or request_row.request_payload <> p_request_payload then
        raise exception 'El identificador de solicitud ya fue utilizado.' using errcode = '23505';
    end if;
    if request_row.result is not null then return request_row.result; end if;

    receipt := jsonb_build_object(
        'status', 'rejected', 'reason_code', 'not_applied_closed',
        'kind', p_kind, 'request_id', p_request_id,
        'billar_id', p_billar_id, 'actor_id', actor,
        'request_payload', p_request_payload
    );
    if p_kind = 'purchase' then
        update public.staff_purchase_requests set result = receipt
        where request_id = p_request_id;
    else
        update public.staff_provider_requests set result = receipt
        where request_id = p_request_id;
    end if;
    return receipt;
end;
$$;
revoke all on function public.resolve_staff_purchase_request(uuid, text, text, jsonb)
from public, anon, authenticated;
commit;
