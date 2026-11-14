#!/usr/bin/env bash
# End-to-end: render, click +,+,+,-, screenshot, close via WM, expect {:count 2}.
set -u
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
xh_launch /tmp/e2e_counter.log examples.counter
xh_wait_window Hello || { cat /tmp/e2e_counter.log; exit 1; }
for _ in 1 2 3; do xh_click 358 218; done
xh_click 282 218
sleep 0.5; xh_shot "${SHOT:-/tmp/e2e_counter.png}"
xh_close
if xh_wait_exit 15; then echo "exited cleanly"; else echo "HUNG on close"; kill "$XH_PID"; fi
grep -v "^skald: gpu" /tmp/e2e_counter.log
grep -q ':final-state {:count 2}' /tmp/e2e_counter.log && echo "PASS" || { echo "FAIL"; exit 1; }
