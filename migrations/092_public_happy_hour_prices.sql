-- 092 — expose happy-hour prices to the public (website blog generator).
--
-- WHAT WE ACTUALLY HAVE, and what we deliberately do not claim:
--
-- Happy-hour rows are identified only by a note that begins "Happy hour · ",
-- followed by the beer brand. NONE of them carry a start/end time — verified:
--
--   select count(*) filter (where note ~ '\d{1,2}[:.]\d{2}')
--     from beer_prices where note ~* 'happy';   -->  0
--
-- venue_offers, which does have start_minute/end_minute, holds exactly one row
-- and it is a quiz night. So the site can honestly publish WHAT a happy-hour
-- beer costs, and must not publish WHEN happy hour is — there is no such data,
-- and printing plausible-looking hours for a real named bar would be inventing
-- facts about a business. The blog pages say so in as many words, and the app's
-- report flow is where the hours should come from.
--
-- Additive by design: a new function rather than extra columns on
-- public_beer_prices(), so no existing caller changes shape.

create or replace function public.public_happy_hour_prices()
returns table (
  venue_id   uuid,
  venue_name text,
  city       text,
  lat        double precision,
  lon        double precision,
  serving    text,
  currency   text,
  price      numeric,
  beer       text
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not rate_limit_hit('web_read_ip', request_ip(), 600, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select
      v.id, v.name, v.city, v.lat, v.lon,
      b.serving, b.currency, b.price_sek,
      -- The brand sits in field 2 of a "·"-separated note. Everything after it
      -- is import bookkeeping (source ids, city slugs, timestamps) that must
      -- never reach a public page, so anything that smells like bookkeeping is
      -- dropped rather than shown.
      nullif(
        case
          when split_part(b.note, ' · ', 2) ~* '(source_id|city=|updated=)' then ''
          else btrim(split_part(b.note, ' · ', 2))
        end, '') as beer
    from beer_prices b
    join venues v on v.id = b.venue_id
    left join venue_canonical c on c.venue_id = v.id
    where b.note ~* '^\s*happy ?hour'
      and coalesce(c.reason, 'unique') <> 'duplicate'
      and v.city is not null
      and b.price_sek is not null
    order by v.city, b.price_sek;
end $$;

revoke all on function public.public_happy_hour_prices() from public;
grant execute on function public.public_happy_hour_prices() to anon, authenticated;
