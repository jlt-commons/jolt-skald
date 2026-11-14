#!/usr/bin/env bash
# Keyboard: :on-key delivers presses and releases (arrows move the square,
# Escape resets it), [:shortcut] fires once per Ctrl+K, and :on-key stays
# quiet while a text field has focus.
set -u
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
LOG=/tmp/e2e_keys.log
xh_launch $LOG examples.keys
xh_wait_window Keys || { cat $LOG; exit 1; }
xdotool windowactivate --sync "$XH_WIN" 2>/dev/null; xdotool windowfocus --sync "$XH_WIN"; sleep 0.3
for k in Right Right Down; do xdotool key $k; sleep 0.25; done   # -> [190 170]
xdotool key Escape; sleep 0.3                                    # -> [150 150]
xdotool key Right; sleep 0.3                                     # -> [170 150]
for _ in 1 2 3; do xdotool key ctrl+k; sleep 0.3; done           # panel on/off/on
xdotool key Tab; sleep 0.4                                       # focus the text field
xh_type wasd
xdotool key Left; sleep 0.3                                      # caret move, not the square
xh_shot "${SHOT:-/tmp/e2e_keys.png}"
xh_close
if xh_wait_exit 15; then echo "exited cleanly"; else echo "HUNG"; kill $XH_PID; exit 1; fi
final=$(grep ':final-state' $LOG); log=$(grep '^:log' $LOG)
fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails+1)); }
grep -qF '[:key {:key :right, :mods #{}, :pressed? true}]' <<<"$log"  && ok "arrow press delivered"   || bad "arrow press"
grep -qF '[:key {:key :right, :mods #{}, :pressed? false}]' <<<"$log" && ok "arrow release delivered" || bad "arrow release"
grep -qF '[:key {:key :escape, :mods #{}, :pressed? true}]' <<<"$log" && ok "escape delivered"        || bad "escape"
grep -qF '[:key {:key :k, :mods #{:ctrl}, :pressed? true}]' <<<"$log" && ok "ctrl+k carries :ctrl"    || bad "ctrl+k key event"
grep -qF ':pos [170 150]' <<<"$final"   && ok "square moved, reset, moved; Left in the field ignored" || bad "position"
n=$(grep -oF ':panel' <<<"$log" | wc -l | tr -d ' ')
[ "$n" = 3 ] && ok "shortcut fired once per press" || bad "shortcut count ($n)"
grep -qF ':panel? true' <<<"$final"     && ok "panel toggled on/off/on" || bad "panel state"
grep -qF ':note "wasd"' <<<"$final"     && ok "typing reached the field" || bad "note"
grep -qE ':key :(w|a|s|d),' <<<"$log"   && bad "keys leaked to :on-key while typing" || ok "no :on-key while the field has focus"
grep -q "exception" $LOG && { bad "exceptions in log"; grep exception $LOG; }
[ $fails = 0 ] && echo PASS || { echo "FAIL ($fails)"; echo "$final"; echo "$log"; exit 1; }
