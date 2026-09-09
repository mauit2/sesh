-- Remove every trace of the App Store demo seed (marketing/appstore/seed-demo.sql).
-- Demo accounts hang off fixed 0d000000-… ids; deleting the auth.users rows
-- cascades to profiles, friendships, posts, stories, presence and sessions.
-- Also restores Mauritz's real avatar, which is swapped for the shoot.
begin;
-- Things created during the shoot on Mauritz's own account
delete from event_members where event_id = '669dd040-2f8c-47f0-815f-fc84ce20b914';
delete from events        where id       = '669dd040-2f8c-47f0-815f-fc84ce20b914';   -- "Friday pre-game"
delete from session_drinks  where session_id = '865db79e-c402-430a-9236-d7292b21b120';
delete from session_members where session_id = '865db79e-c402-430a-9236-d7292b21b120';
delete from sessions        where id         = '865db79e-c402-430a-9236-d7292b21b120';   -- group 4Y5EEN
delete from live_presence   where user_id = 'b6511620-282f-4a85-b4af-442437a27d2f';      -- the two logged beers
delete from venue_offers    where id::text like '0d000000-0000-4000-8000-0000000000d%';  -- demo deals, if seeded
delete from session_drinks  where session_id = '0d000000-0000-4000-8000-0000000000aa';
delete from session_members where session_id = '0d000000-0000-4000-8000-0000000000aa';
delete from sessions        where id         = '0d000000-0000-4000-8000-0000000000aa';
delete from live_presence   where user_id::text like '0d000000-0000-4000-8000-00000000000%';
delete from live_stories    where profile_id::text like '0d000000-0000-4000-8000-00000000000%';
delete from posts           where author_id::text  like '0d000000-0000-4000-8000-00000000000%';
delete from friendships     where requester_id::text like '0d000000-0000-4000-8000-00000000000%'
                               or addressee_id::text like '0d000000-0000-4000-8000-00000000000%';
delete from auth.users      where email like 'demo+%@sejdel.com';
update profiles set avatar_url = 'https://lltuozmbxacxiepardys.supabase.co/storage/v1/object/public/avatars/b6511620-282f-4a85-b4af-442437a27d2f/avatar.jpg?v=1781708189'
 where id = 'b6511620-282f-4a85-b4af-442437a27d2f';
commit;
-- Then, outside SQL:
--   git rm -r docs/demo && git commit -m "Remove App Store shoot images" && git push
--   xcrun simctl location <udid> clear        (simulator was pinned to Göteborg for the shoot)
--   In the app: Live → Group → the saved crew "Emma Lindqvist, Oskar B…" — untoggle if unwanted.
