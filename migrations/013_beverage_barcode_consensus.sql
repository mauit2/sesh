-- 013_beverage_barcode_consensus.sql
--
-- Crowd-sourced barcode specs now require 5 independent users to agree
-- before an entry is trusted in the shared `beverage_barcodes` catalog.
-- Each scan-confirm is a "vote" recorded in beverage_barcode_submissions;
-- submit_beverage_barcode() tallies distinct submitters per normalized
-- content signature and promotes to the verified table on the 5th match.
-- Until then the user's own value lives only on their device (app-side
-- local cache) + the current session.

create table if not exists beverage_barcode_submissions (
  id            uuid primary key default gen_random_uuid(),
  barcode       text not null,
  submitted_by  uuid not null references profiles(id) on delete cascade,
  name          text not null,
  category      text not null,
  volume_ml     double precision not null,
  abv           double precision not null,
  content_sig   text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (barcode, submitted_by)
);

create index if not exists beverage_barcode_submissions_sig_idx
  on beverage_barcode_submissions (barcode, content_sig);

alter table beverage_barcode_submissions enable row level security;

create policy beverage_barcode_submissions_select_own
  on beverage_barcode_submissions for select
  to authenticated
  using ( submitted_by = auth.uid() );

drop function if exists upsert_beverage_barcode(text, text, text, double precision, double precision);

create or replace function submit_beverage_barcode(
  p_barcode   text,
  p_name      text,
  p_category  text,
  p_volume_ml double precision,
  p_abv       double precision
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sig        text;
  v_count      int;
  v_threshold  constant int := 5;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  v_sig := lower(trim(p_name)) || '|'
        || lower(trim(p_category)) || '|'
        || round(p_volume_ml)::text || '|'
        || round(p_abv::numeric, 3)::text;

  insert into beverage_barcode_submissions
        (barcode, submitted_by, name, category, volume_ml, abv, content_sig, updated_at)
  values (p_barcode, auth.uid(), p_name, p_category, p_volume_ml, p_abv, v_sig, now())
  on conflict (barcode, submitted_by) do update
    set name        = excluded.name,
        category    = excluded.category,
        volume_ml   = excluded.volume_ml,
        abv         = excluded.abv,
        content_sig = excluded.content_sig,
        updated_at  = now();

  select count(distinct submitted_by) into v_count
  from beverage_barcode_submissions
  where barcode = p_barcode and content_sig = v_sig;

  if v_count >= v_threshold then
    insert into beverage_barcodes (barcode, name, category, volume_ml, abv, created_by, updated_at)
    values (p_barcode, p_name, p_category, p_volume_ml, p_abv, auth.uid(), now())
    on conflict (barcode) do update
      set name       = excluded.name,
          category   = excluded.category,
          volume_ml  = excluded.volume_ml,
          abv        = excluded.abv,
          updated_at = now();
    return jsonb_build_object('verified', true, 'count', v_count, 'threshold', v_threshold);
  end if;

  return jsonb_build_object('verified', false, 'count', v_count, 'threshold', v_threshold);
end;
$$;

revoke execute on function submit_beverage_barcode(text, text, text, double precision, double precision) from public;
revoke execute on function submit_beverage_barcode(text, text, text, double precision, double precision) from anon;
grant  execute on function submit_beverage_barcode(text, text, text, double precision, double precision) to authenticated;
