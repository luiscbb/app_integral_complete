-- Partial preparation only. Do not apply until every client sends and handles
-- stock_revision and stock conflicts have an administrator resolution flow.
begin;

alter table public.products
    add column if not exists stock_revision bigint not null default 0;

create or replace function public.guard_product_stock_revision()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if new.stock_revision is distinct from old.stock_revision + 1 then
        raise exception 'El inventario cambió en otro dispositivo; revisa el conflicto.'
            using errcode = '40001';
    end if;
    return new;
end;
$$;

create or replace function public.guard_product_revision_integrity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if new.stock_revision is distinct from old.stock_revision
       and new.stock_revision is distinct from old.stock_revision + 1 then
        raise exception 'El inventario cambió en otro dispositivo; revisa el conflicto.'
            using errcode = '40001';
    end if;
    return new;
end;
$$;

drop trigger if exists product_stock_revision_guard on public.products;
create trigger product_stock_revision_guard
before update of stock on public.products
for each row execute function public.guard_product_stock_revision();

drop trigger if exists product_revision_integrity_guard on public.products;
create trigger product_revision_integrity_guard
before update on public.products
for each row execute function public.guard_product_revision_integrity();

commit;
