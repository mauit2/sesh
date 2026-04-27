-- Adds venue support: real-world bars/places where the user can be checked
-- in. Phase 1 stores venues + per-venue "specials" — drinks that only
-- appear in the picker when the user is checked into that venue. Phase 2
-- (later) wires in featured curation, geo proximity highlights, photos.
--
-- Coordinates are plain doubles (lat/lon in WGS-84). Distance is computed
-- client-side via CLLocation.distance(from:). If we ever need true
-- geospatial queries we can swap to PostGIS without changing the wire shape.

create table if not exists venues (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  address      text,
  city         text,
  lat          double precision not null,
  lon          double precision not null,
  is_featured  boolean not null default false,
  created_at   timestamptz not null default now()
);

create index if not exists venues_geo_idx       on venues (lat, lon);
create index if not exists venues_featured_idx  on venues (is_featured) where is_featured = true;

-- Per-venue special drinks. These show up at the top of the drink picker
-- as a pinned "Specials at <Venue>" section whenever the user is checked
-- into the venue. volume_ml + abv use the same units as DrinkOption (ml +
-- decimal ABV) so they plug into the existing BAC math without conversion.
create table if not exists venue_specials (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references venues(id) on delete cascade,
  name        text not null,
  detail      text,                                    -- short blurb shown under name
  volume_ml   double precision not null,               -- total served volume (the jug, the glass…)
  abv         double precision not null,               -- effective ABV of that volume
  category    text not null default 'cocktail',        -- maps to DrinkCategory rawValue
  emoji       text,                                    -- optional override icon
  created_at  timestamptz not null default now()
);

create index if not exists venue_specials_venue_idx on venue_specials (venue_id);

-- Lets a session record the venue the group is checked into, if any. Phase
-- 2 can use this to surface specials in the menu sheet without each phone
-- having to do its own location fix.
alter table sessions
  add column if not exists current_venue_id uuid references venues(id);

-- ---------------------------------------------------------------------------
-- Seed: Handelspuben (Vasagatan 1, 405 30 Göteborg) + two of their jug
-- drinks. Each jug is 50 cl total with 18 cl of 40% spirit. We model the
-- jug as a single 500 ml drink at 14.4% effective ABV so the BAC math
-- (volume_ml × abv × 0.789) yields the correct ~56.8 g of ethanol per jug.
-- ---------------------------------------------------------------------------

insert into venues (name, address, city, lat, lon, is_featured)
select 'Handelspuben', 'Vasagatan 1', 'Göteborg', 57.6991, 11.9712, true
where not exists (
  select 1 from venues where name = 'Handelspuben' and address = 'Vasagatan 1'
);

insert into venue_specials (venue_id, name, detail, volume_ml, abv, category, emoji)
select v.id, 'Fittkittlaren', '50 cl jug · 18 cl @ 40%', 500, 0.144, 'cocktail', '🍹'
from venues v
where v.name = 'Handelspuben' and v.address = 'Vasagatan 1'
  and not exists (
    select 1 from venue_specials s where s.venue_id = v.id and s.name = 'Fittkittlaren'
  );

insert into venue_specials (venue_id, name, detail, volume_ml, abv, category, emoji)
select v.id, 'Döda mig', '50 cl jug · 18 cl @ 40%', 500, 0.144, 'cocktail', '☠️'
from venues v
where v.name = 'Handelspuben' and v.address = 'Vasagatan 1'
  and not exists (
    select 1 from venue_specials s where s.venue_id = v.id and s.name = 'Döda mig'
  );
