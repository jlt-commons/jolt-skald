#!/usr/bin/env bash
# Renders every bound widget; switches theme (set-theme command) and tab.
set -u
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
LOG=/tmp/e2e_gallery.log
xh_launch $LOG examples.gallery
xh_wait_window Gallery || { cat $LOG; exit 1; }
xh_shot "${SHOT_DIR:-/tmp}/gallery_dark.png"
xh_click 213 31; sleep 0.8; xh_shot "${SHOT_DIR:-/tmp}/gallery_light.png"
xh_click 117 74; sleep 0.8
xh_close
if xh_wait_exit 15; then echo "exited cleanly"; else echo "HUNG"; kill $XH_PID; exit 1; fi
grep -v "^skald: gpu" $LOG
grep -q ':tab 1, .*:theme :light' $LOG && ! grep -q "exception" $LOG && echo PASS || { echo FAIL; exit 1; }
