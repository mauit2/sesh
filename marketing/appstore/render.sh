#!/bin/zsh
# Render every storyboard frame to a 1320×2868 PNG with headless Chrome.
# Usage: ./render.sh [frame-index ...]   (no args = all)
set -e
here=${0:a:h}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
count=$(grep -c '^  { eyebrow' "$here/frames.html")
idx=("$@"); [[ ${#idx} -eq 0 ]] && idx=($(seq 0 $((count-1))))
for i in $idx; do
  out="$here/out/sejdel-$(printf %02d $((i+1))).png"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --window-size=1320,2868 --virtual-time-budget=8000 \
    --screenshot="$out" "file://$here/frames.html#$i" >/dev/null 2>&1
  printf "%s  " "$out"; sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/{printf "%s ",$2}'; echo
done
