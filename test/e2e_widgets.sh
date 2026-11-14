#!/usr/bin/env bash
# Batch-2 widgets: combobox, date/time/color pickers, rating, search field,
# radio group, chips, breadcrumb, tree, context menu, menu bar + keyboard
# shortcuts, toast auto-dismiss, accordion. Quits via the Ctrl+Q menu
# shortcut, then checks the final state and the message log.
set -u
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
LOG=/tmp/e2e_widgets.log
xh_launch $LOG examples.widgets
xh_wait_window Widgets || { cat $LOG; exit 1; }
esc() { xdotool key Escape; sleep 0.3; }
xh_click 208 109; xh_click 54 226                     # combobox -> Cherry
xh_click 208 149; xh_click 187 339                    # date -> 20 Nov
xh_click 208 188; xh_click 141 316; esc               # time -> hour 14
xh_click 208 230; xh_press 143 323; esc               # color: press in the SV square (tracked while held, like slider)
xh_click 108 268                                      # rating -> 4
xh_click 174 356; xh_type "skald"; xdotool key Return; sleep 0.3   # search + submit
xh_click 565 100                                      # radio group -> Large
xh_click 481 130                                      # close the "odin" chip
xh_click 406 158                                      # breadcrumb -> Home
xh_click 428 237                                      # next step
xh_click 469 435                                      # tree: select README.md
xh_click 405 327                                      # tree: collapse src
xdotool mousemove $((XH_X+876)) $((XH_Y+449)) click 3; sleep 0.4
xh_click 907 510                                      # context menu -> Paste
xh_click 21 17; xh_click 29 56                        # File > New (toast)
sleep 2.5                                             # toast auto-dismisses
xh_chord ctrl n; sleep 2.5                            # shortcut: New again
xh_click 803 276                                      # accordion -> Avatars
sleep 0.5; xh_shot "${SHOT:-/tmp/e2e_widgets.png}"
xh_chord ctrl q                                       # shortcut: Quit
if xh_wait_exit 15; then echo "exited via Ctrl+Q"; else echo "FAIL: Ctrl+Q did not quit"; kill $XH_PID; exit 1; fi
final=$(grep ':final-state' $LOG)
fails=0
expect() { if grep -qF -- "$2" <<<"$final"; then echo "ok   $1"; else echo "FAIL $1: missing $2"; fails=$((fails+1)); fi; }
expect "combobox string"         ':fruit "Cherry"'
expect "date picker -> map"      ':date {:year 2026, :month 11, :day 20}'
expect "time picker -> map"      ':time {:hour 14, :minute 30, :second 0}, :color'
expect "color picker -> hex"     '[:color "#'
expect "rating int"              ':stars 4'
expect "search on-change"        '[:query "skald"]'
expect "search on-submit"        ':searched "skald"'
expect "radio group index"       ':size 2'
expect "chip on-close label"     ':tags ["jolt" "skald"]'
expect "breadcrumb index"        ':crumb 0'
expect "button"                  ':step 2'
expect "tree select"             ':tree-sel 3'
expect "tree toggle"             ':tree-open #{}'
expect "context menu index"      '[:ctx 1]'
expect "accordion index"         ':section 1'
n_new=$(grep -o ':new' <<<"$final" | wc -l); n_closed=$(grep -o ':toast-closed' <<<"$final" | wc -l)
[ "$n_new" = 2 ] && echo "ok   File>New by click and by Ctrl+N" || { echo "FAIL :new x$n_new"; fails=$((fails+1)); }
[ "$n_closed" = 2 ] && echo "ok   toast auto-dismissed twice" || { echo "FAIL :toast-closed x$n_closed"; fails=$((fails+1)); }
expect "menu shortcut quit"      ':quit]'
grep -q "exception" $LOG && { echo "FAIL exceptions in log"; grep exception $LOG; fails=$((fails+1)); }
[ $fails = 0 ] && echo PASS || { echo "FAIL ($fails)"; echo "$final"; exit 1; }
