#!/usr/bin/env bash
# Virtualized table (10,000 rows) and virtual list (100,000 rows): sort by
# header clicks, select by click and by keyboard, open by double-click,
# multi-select with Shift-click / Ctrl-click / Shift+Down, resize a column by dragging, scroll the list and click a button inside a
# row built during layout.
set -u
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
LOG=/tmp/e2e_data.log
xh_launch $LOG examples.data
xh_wait_window Data || { cat $LOG; exit 1; }
xh_click 331 57                         # sort by Size (ascending)
xh_click 331 57                         # again: descending
xh_click 100 89                         # select the first row
xdotool key Down; sleep 0.4             # keyboard: next row
xdotool mousemove $((XH_X+100)) $((XH_Y+173)) click --repeat 2 --delay 80 1; sleep 0.5   # open row 3
xdotool mousemove $((XH_X+100)) $((XH_Y+229)) keydown shift click 1 keyup shift; sleep 0.4 # rows 3..5
xdotool key shift+Down; sleep 0.4                                                           # rows 3..6
xdotool mousemove $((XH_X+100)) $((XH_Y+89)) keydown ctrl click 1 keyup ctrl; sleep 0.4     # + row 0
# drag the Name|Size divider 50px right
xdotool mousemove $((XH_X+233)) $((XH_Y+57)) mousedown 1; sleep 0.2
for dx in 10 20 30 40 50; do xdotool mousemove $((XH_X+233+dx)) $((XH_Y+57)); sleep 0.05; done
xdotool mouseup 1; sleep 0.4
# scroll the virtual list, then click the Pick button in the top visible row
xdotool mousemove $((XH_X+700)) $((XH_Y+250)); for _ in $(seq 1 15); do xdotool click 5; sleep 0.03; done; sleep 0.5
xh_shot "${SHOT:-/tmp/e2e_data.png}"
xh_click 785 110                        # Pick in a row built during layout
sleep 0.3
xh_close
if xh_wait_exit 15; then echo "exited cleanly"; else echo "HUNG"; kill $XH_PID; exit 1; fi
final=$(grep ':final-state' $LOG); log=$(grep '^:log' $LOG)
fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails+1)); }
grep -qF '[:sort {:column 1, :ascending true}]' <<<"$log"  && ok "header click sorts ascending"  || bad "sort asc"
grep -qF '[:sort {:column 1, :ascending false}]' <<<"$log" && ok "second click sorts descending" || bad "sort desc"
grep -qF ':sort-col 1, :asc? false' <<<"$final"            && ok "sort state"                    || bad "sort state"
grep -qF '[:select {:row 0, :mods #{}}]' <<<"$log"         && ok "row click -> row 0"            || bad "row click"
grep -qF '[:select {:row 1, :mods #{}}]' <<<"$log"         && ok "Down key -> row 1"             || bad "keyboard nav"
grep -qF '[:select {:row 5, :mods #{:shift}}]' <<<"$log"   && ok "shift-click carries :shift"    || bad "shift-click"
grep -qF '[:select {:row 6, :mods #{:shift}}]' <<<"$log"   && ok "shift+Down extends"            || bad "shift+Down"
grep -qF '[:select {:row 0, :mods #{:ctrl}}]' <<<"$log"    && ok "ctrl-click carries :ctrl"      || bad "ctrl-click"
nsel=$(grep -oE ':selected #\{[^}]*\}' <<<"$final" | grep -oE '[0-9]+' | wc -l | tr -d ' ')
[ "$nsel" = 5 ] && ok "5 rows selected (3..6 + 0)" || bad "selection count ($nsel)"
grep -qF '[:open 3]' <<<"$log"                             && ok "double-click opens row 3"      || bad "activate"
grep -q  ':opened "file-[0-9]*.txt"' <<<"$final"           && ok "opened a real file"            || bad "opened"
grep -qE '\[:resize \{:column 0, :width 2[4-9][0-9]' <<<"$log" && ok "dragging the divider resizes column 0" || bad "resize"
picked=$(grep -oE ':picked [0-9]+' <<<"$final" | grep -oE '[0-9]+')
if [ -n "$picked" ] && [ "$picked" -ge 5 ]; then ok "button in a scrolled, layout-built row: picked item $picked"
else bad "pick after scroll (picked=$picked)"; fi
grep -q "exception" $LOG && { bad "exceptions in log"; grep exception $LOG; }
[ $fails = 0 ] && echo PASS || { echo "FAIL ($fails)"; echo "$final"; echo "$log"; exit 1; }
