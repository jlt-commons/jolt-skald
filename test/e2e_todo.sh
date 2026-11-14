#!/usr/bin/env bash
# End-to-end: text input, keyed checkboxes, slider (float), segmented (int),
# fx + after timer, background dispatch!, on-close-request dialog with
# cancel then quit. Asserts the exact final state returned by run.
set -u
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
LOG=/tmp/e2e_todo.log
xh_launch $LOG examples.todo
xh_wait_window Todo || { cat $LOG; exit 1; }
xh_click 230 70; xh_type "Buy milk"; xh_click 480 70
xh_press 222 110                          # slider -> 8 (needs a held press)
xh_click 230 70; xh_type "Walk dog"; xh_click 480 70
xh_click 25 206                           # tick "Buy milk"
xh_click 165 149                          # filter: Done
xh_close; sleep 0.8; xh_click 232 306     # dialog -> Cancel
kill -0 $XH_PID 2>/dev/null || { echo "FAIL: Cancel quit the app"; cat $LOG; exit 1; }
xh_close; sleep 1.5
xh_shot "${SHOT:-/tmp/e2e_todo.png}"
xh_click 295 306                          # dialog -> Quit
if xh_wait_exit 15; then echo "exited cleanly"; else echo "HUNG"; kill $XH_PID; exit 1; fi
grep -v "^skald: gpu" $LOG
expected=':final-state {:draft "", :next-id 3, :items [{:id 1, :text "Buy milk", :done true, :priority 3} {:id 2, :text "Walk dog", :done false, :priority 8}], :filter 2, :priority 8.0, :status "Saved", :confirm? false}'
grep -qF "$expected" $LOG && echo PASS || { echo "FAIL: expected"; echo "$expected"; exit 1; }
