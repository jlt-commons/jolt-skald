#!/usr/bin/env bash
# Canvas drawing (press/drag/release), drag-and-drop of a value payload,
# rich-text links, a variable-height list, a second window opened and
# closed from the app, a custom theme switch, and split-pane resizing.
set -u
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
LOG=/tmp/e2e_studio.log
xh_launch $LOG examples.studio
xh_wait_window Studio || { cat $LOG; exit 1; }
# drag with real intermediate motion: press, move in steps, release
drag() { # x1 y1 x2 y2 steps
  xdotool mousemove $((XH_X+$1)) $((XH_Y+$2)) mousedown 1; sleep 0.15
  for i in $(seq 1 $5); do
    xdotool mousemove $((XH_X+$1+($3-$1)*i/$5)) $((XH_Y+$2+($4-$2)*i/$5)); sleep 0.04
  done
  sleep 0.15; xdotool mouseup 1; sleep 0.4
}
drag 420 200 620 300 12                      # stroke 1, rose brush
drag 128 116 560 180 15                      # green swatch -> canvas (drop target)
drag 420 330 700 250 12                      # stroke 2, now green
xh_click 80 216                              # rich-text link "Skald"
xh_click 79 404                              # Pick on Note 1 (below the tall Note 0)
xh_click 62 23; sleep 1.5                    # open the inspector window
W2=$(xdotool search --name '^Inspector$' | head -1)
[ -n "$W2" ] && echo "ok   second window opened" || echo "FAIL no Inspector window"
eval "$(xdotool getwindowgeometry --shell "$W2")"
xdotool mousemove $((X+70)) $((Y+88)) click 1; sleep 1.0   # its own Close button
[ -z "$(xdotool search --name '^Inspector$' 2>/dev/null)" ] && echo "ok   second window closed by command" || echo "FAIL Inspector still open"
xh_click 172 23; sleep 0.6                   # custom theme: rose -> mint
xh_shot "${SHOT:-/tmp/e2e_studio.png}"
drag 303 300 360 300 8                       # split divider 57px right
xh_close
if xh_wait_exit 15; then echo "exited cleanly"; else echo "HUNG"; kill $XH_PID; exit 1; fi
final=$(grep ':final-state' $LOG); log=$(grep '^:log' $LOG)
fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
grep -qF '[:down {:x ' <<<"$log" && grep -qF '[:up {:x ' <<<"$log" && ok "canvas press/release with local {:x :y}" || bad "canvas pointer"
n=$(grep -oE ':points [0-9]+' <<<"$final" | head -1 | grep -oE '[0-9]+')
[ -n "$n" ] && [ "$n" -ge 5 ] && ok "stroke 1 has $n points (drag events)" || bad "stroke points ($n)"
grep -qE ':strokes \[\{:color "#e11d48", :points [0-9]+\} \{:color "#10b981", :points [0-9]+\}\]' <<<"$final" \
  && ok "dropped swatch value changed the brush (rose stroke, then green)" || bad "strokes/colors"
grep -qF '[:brush {:color "#10b981"}]' <<<"$log" && ok "drop delivered the payload value {:color ...}" || bad "drop payload"
grep -qF ':link "https://github.com/BuLEEto/Skald"' <<<"$final" && ok "rich-text link target" || bad "link"
grep -qF ':picked 1' <<<"$final" && ok "variable-height list: Pick on Note 1 under a tall row" || bad "variable list pick"
grep -qE '\[:opened [0-9]+\]' <<<"$log" && grep -qE '\[:closed [0-9]+\]' <<<"$log" && ok "window :on-open / :on-close with its id" || bad "window messages"
grep -qF ':inspector nil' <<<"$final" && ok "inspector state cleared" || bad "inspector state"
grep -qF ':theme :mint' <<<"$final" && ok "custom theme switched by command" || bad "theme"
grep -qE ':split 3[3-7][0-9]' <<<"$final" && ok "split resized by dragging" || bad "split ($(grep -oE ':split [0-9.]+' <<<"$final"))"
grep -q "exception" $LOG && { bad "exceptions in log"; grep exception $LOG | head -3; }
[ $fails = 0 ] && echo PASS || { echo "FAIL ($fails)"; echo "$final"; echo "$log" | cut -c1-600; exit 1; }
