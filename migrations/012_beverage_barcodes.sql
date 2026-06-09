-- 012_beverage_barcodes.sql
--
-- Crowd-sourced barcode → beverage spec catalog. First time anyone scans
-- a can/bottle and confirms its specs, we upsert here; the next person who
-- scans the same barcode gets it instantly and accurately, with no
-- dependency on third-party (Open Food Facts) coverage. `abv` is stored as
-- a fraction (0..1) to match the app's DrinkOption.abv.
create table if not exists beverage_barcodes (
  barcode     text primary key,
  name        text not null,
  category    text not null default 'beer',
  volume_ml   double precision not null,
  abv         double precision not null,
  created_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table beverage_barcodes enable row level security;

-- Shared catalog: any signed-in user can read any barcode.
create policy beverage_barcodes_read
  on beverage_barcodes for select
  to authenticated
  using ( true );

-- Writes go through a SECURITY DEFINER upsert (same pattern as
-- register_device_token) so contributions + corrections don't need a
-- broad UPDATE policy. The function stamps created_by = auth.uid().
create or replace function upsert_beverage_barcode(
  p_barcode   text,
  p_name      text,
  p_category  text,
  p_volume_ml double precision,
  p_abv       double precision
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  insert into beverage_barcodes (barcode, name, category, volume_ml, abv, created_by, updated_at)
  values (p_barcode, p_name, p_category, p_volume_ml, p_abv, auth.uid(), now())
  on conflict (barcode) do update
    set name       = excluded.name,
        category   = excluded.category,
        volume_ml  = excluded.volume_ml,
        abv        = excluded.abv,
        updated_at = now();
end;
$$;

revoke execute on function upsert_beverage_barcode(text, text, text, double precision, double precision) from public;
revoke execute on function upsert_beverage_barcode(text, text, text, double precision, double precision) from anon;
grant  execute on function upsert_beverage_barcode(text, text, text, double precision, double precision) to authenticated;
