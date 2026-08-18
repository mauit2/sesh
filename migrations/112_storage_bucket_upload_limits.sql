-- 112: server-side upload validation on all storage buckets.
-- allowed_mime_types and file_size_limit were both NULL, so any authenticated
-- user could upload arbitrary content (e.g. an HTML/SVG page that executes JS
-- on the public storage origin — a phishing/XSS primitive) or huge files to
-- burn egress. Restrict to non-executable image types (no text/html, no
-- image/svg+xml) and cap at 15 MB. The app only ever uploads image/jpeg, so
-- this is transparent to every legitimate client.
update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic','image/heif'],
    file_size_limit = 15728640
where id in ('avatars','campaign-art','event-covers','recap-photos','session-snaps','stories');
