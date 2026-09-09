#!/bin/zsh
# Upload the demo shoot images to Supabase Storage.
#   1. Put the files in ~/Desktop/sejdel-shots/ with the exact names below.
#   2. In your own terminal:  SUPABASE_SERVICE_ROLE_KEY=… ./upload-demo.sh
# The key never leaves your shell. Buckets are public, so the seed's URLs
# resolve the moment this finishes.
set -e
: "${SUPABASE_SERVICE_ROLE_KEY:?set SUPABASE_SERVICE_ROLE_KEY in your shell first}"
src=~/Desktop/sejdel-shots
base=https://lltuozmbxacxiepardys.supabase.co/storage/v1/object
put() { # bucket path file
  curl -sS -o /dev/null -w "%{http_code}  $1/$2\n" -X POST "$base/$1/$2" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" -H "x-upsert: true" \
    -H "Content-Type: image/jpeg" --data-binary "@$src/$3"
}
for n in me emma oskar linnea hugo alva elias; do put avatars "demo/$n.jpg" "$n.jpg"; done
for i in 01 02 03 04 05 06 07;                 do put recap-photos "demo/post-$i.jpg" "post-$i.jpg"; done
for i in 01 02 03 04;                          do put stories "demo/story-$i.jpg" "story-$i.jpg"; done
