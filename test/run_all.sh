#!/usr/bin/env bash
# Runs the windowless unit tests, then every end-to-end test.
#   run_all.sh unit   unit tests only (a second, no window or GPU)
# Linux e2e needs: Xvfb, xdotool, xwd, ImageMagick, python3-xlib, a Vulkan
# driver (lavapipe works), SDL3, and the shim built (`jolt native`). Uses
# DISPLAY=:99 unless DISPLAY is set.
# macOS e2e runs on the real desktop (don't touch mouse or keyboard while it
# runs) and needs Accessibility + Screen Recording for the terminal; see
# test/mac/xdotool.swift. e2e_files is skipped there (it drives zenity).
cd "$(dirname "$0")"
fail=0
for t in select_rows_test core_test; do
  echo "== $t"
  res=$(cd ../examples && jolt run ../test/$t.clj 2>&1) || { echo "$res"; fail=1; }
  echo "$res" | tail -1
done
[ "${1:-}" = unit ] && { [ $fail = 0 ] && echo "UNIT PASSED" || { echo "UNIT FAILED"; exit 1; }; exit 0; }
for t in e2e_counter e2e_todo e2e_gallery e2e_stress e2e_widgets e2e_data e2e_keys e2e_files e2e_studio e2e_repl e2e_repl_main; do
  echo "== $t"
  [ "$(uname)" = Darwin ] && [ $t = e2e_files ] && { echo "skipped on macOS"; continue; }
  res=$(timeout 180 bash "$t.sh" 2>&1); rc=$?
  if [ $rc = 0 ]; then echo "$res" | tail -2; else echo "$res" | tail -25; fail=1; fi
done
[ $fail = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
