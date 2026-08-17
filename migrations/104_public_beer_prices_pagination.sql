-- 104: public_beer_prices grows p_limit/p_offset so callers can page past
-- PostgREST's 1000-row response cap (the blog generators were silently
-- reading only the first 1000 rows — Sweden truncated, the rest of the
-- world invisible). Adds a deterministic ORDER BY so pages can't overlap.
drop function if exists public.public_beer_prices();

create or replace function public.public_beer_prices(
  p_limit integer default 1000000,
  p_offset integer default 0
)
returns table(venue_id uuid, venue_name text, lat double precision, lon double precision,
              serving text, currency text, price numeric, report_count bigint, outdoor boolean)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not rate_limit_hit('web_read_ip', request_ip(), 600, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select v.id, v.name, v.lat, v.lon, b.serving, b.currency, b.price, b.report_count,
           v.outdoor_seating
    from venue_beer_prices() b
    join venues v on v.id = b.venue_id
    left join venue_canonical c on c.venue_id = v.id
    where coalesce(c.reason, 'unique') <> 'duplicate'
    order by v.id, b.serving
    limit greatest(0, p_limit)
    offset greatest(0, p_offset);
end $$;

grant execute on function public.public_beer_prices(integer, integer) to anon, authenticated;
