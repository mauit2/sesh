-- Four demo deals at Gothenburg venues for the "Deals near you tonight" frame.
-- Paste into Supabase → SQL editor → Run. Fixed 0d…d1–d4 ids; cleanup-demo.sql removes them.
-- All four carry posters (placement 'poster' + image).
insert into venue_offers (id, venue_id, kind, title, description, fine_print, redeem, starts_at, ends_at,
                          active_days, start_minute, end_minute, is_active, approved, placement, image_url, created_at)
select d.id::uuid, ven.id, d.kind, d.title, d.descr, 'Demo for App Store screenshots.', 'show',
       now() - interval '1 day', now() + interval '30 days', array[0,1,2,3,4,5,6], 0, 1439, true, true, d.placement, d.image, now()
from (values
  ('0d000000-0000-4000-8000-0000000000d1','John Scott''s Pub',   'happy_hour','2 for 1 on large beer',     'Until 21:00, every night this week.',            'poster','https://sejdel.com/demo/deal-01.jpg'),
  ('0d000000-0000-4000-8000-0000000000d2','Brewers Beer Bar',    'deal',      'Tasting flight 99 kr',      'Four 15 cl pours of whatever is fresh on tap.', 'poster','https://sejdel.com/demo/deal-02.jpg'),
  ('0d000000-0000-4000-8000-0000000000d3','Bar Himmel',          'happy_hour','Wine by the glass 65 kr',   'Red, white or bubbles, until 20:00.',            'poster','https://sejdel.com/demo/deal-03.jpg'),
  ('0d000000-0000-4000-8000-0000000000d4','John Scott''s Stable','deal',      'Free nachos with a pitcher','Show the app at the bar.',                       'poster','https://sejdel.com/demo/deal-04.jpg')
) d(id, vname, kind, title, descr, placement, image)
join lateral (select id from venues where name = d.vname and city = 'Göteborg' order by created_at limit 1) ven on true
on conflict (id) do nothing;
