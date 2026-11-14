#!/usr/bin/env bash
# File dialogs: Open (pick a file, then cancel), Save as (writes the file),
# Pick folder (cancel). Under Xvfb SDL3 has no desktop portal and falls back
# to zenity, so this test needs zenity installed; it skips without it.
set -u
command -v zenity >/dev/null || { echo "SKIP: zenity not installed (apt install zenity)"; exit 0; }
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
IN=/tmp/e2e_files_in.txt; OUT=/tmp/e2e_files_out.txt
echo hello > $IN; rm -f $OUT
LOG=/tmp/e2e_files.log
xh_launch $LOG examples.files
xh_wait_window Files || { cat $LOG; exit 1; }

app()    { xdotool windowfocus --sync "$XH_WIN"; sleep 0.3; }
# wait for zenity's window, focus it (there may be no window manager)
dialog() {
  local w=""
  for _ in $(seq 1 40); do
    w=$(xdotool search --onlyvisible --pid "$(pgrep -n zenity)" 2>/dev/null | head -1); [ -n "$w" ] && break; sleep 0.25
  done
  [ -z "$w" ] && { echo "zenity window never appeared"; return 1; }
  sleep 1; xdotool windowfocus --sync "$w"; sleep 0.3
}
gone()   { for _ in $(seq 1 40); do pgrep zenity >/dev/null || { sleep 0.4; return 0; }; sleep 0.25; done; return 1; }

app; xdotool key Tab Return                      # focus Open…, press it
dialog && { xdotool type --delay 40 "$IN"; sleep 0.5; xdotool key Return; }; gone
app; xdotool key Return                          # Open… again (still focused)
dialog && xdotool key Escape; gone               # cancel -> nil
app; xdotool key Tab Return                      # Save as…
dialog && { xdotool key ctrl+a; xdotool type --delay 40 "$OUT"; sleep 0.5; xdotool key Return; }; gone
app; xdotool key Tab Return                      # Pick folder…
dialog && xdotool key Escape; gone
xh_shot "${SHOT:-/tmp/e2e_files.png}"
xh_close
if xh_wait_exit 15; then echo "exited cleanly"; else echo "HUNG"; kill $XH_PID; exit 1; fi
final=$(grep ':final-state' $LOG); log=$(grep '^:log' $LOG)
fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails+1)); }
grep -qF "[:opened \"$IN\"]" <<<"$log"  && ok "open delivers the chosen path"  || bad "open path"
grep -qF '[:opened nil]' <<<"$log"      && ok "cancel delivers nil"            || bad "open cancel"
grep -qF "[:saved \"$OUT\"]" <<<"$log"  && ok "save delivers the chosen path"  || bad "save path"
grep -qF 'saved by examples.files' $OUT 2>/dev/null && ok "file written to the saved path" || bad "saved file"
grep -qF '[:folder nil]' <<<"$log"      && ok "folder dialog result routed to its own message" || bad "folder cancel"
grep -q "exception" $LOG && { bad "exceptions in log"; grep exception $LOG; }
[ $fails = 0 ] && echo PASS || { echo "FAIL ($fails)"; echo "$final"; echo "$log"; cat $LOG; exit 1; }
