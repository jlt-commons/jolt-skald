#!/usr/bin/env bash
# The macOS-safe REPL workflow: the app's own -main starts nREPL and runs the
# UI on the main thread (examples.dev). Redefine from the REPL, then close:
# the process must exit on its own.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../examples"
source "$here/xharness.sh"
xh_start_x
export SKALD_NREPL_PORT=${NREPL_PORT:-7895}
LOG=/tmp/e2e_repl_main.log
xh_launch "$LOG" examples.dev
xh_wait_window Hello || { cat "$LOG"; exit 1; }
for _ in $(seq 1 40); do grep -q "nREPL on port" "$LOG" && break; sleep 0.25; done
fails=0
ev() { python3 "$here/nrepl.py" "$SKALD_NREPL_PORT" "$1" "${2:-user}"; }
check() { local got; got=$(ev "$3" "${4:-user}" 2>&1 | tail -1)
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $got"; fails=$((fails+1)); fi; }
check "connected to the app's own nREPL" "true" "(do (require '[skald.core :as sk]) (sk/running?))"
f0=$(ev '(:frames (sk/stats))' | tail -1)
ev '(defn view [s] [:col {:padding :xl} [:text {:size :display} (str "Main thread: " (:count s))]])' examples.counter >/dev/null
sleep 1
f1=$(ev '(:frames (sk/stats))' | tail -1)
[ "$f1" -gt "$f0" ] && echo "ok   redefinition repainted ($f0 -> $f1)" || { echo "FAIL no repaint ($f0 -> $f1)"; fails=$((fails+1)); }
ev '(sk/swap-state! assoc :count 7)' >/dev/null; sleep 0.5
xh_shot "${SHOT:-/tmp/e2e_repl_main.png}"
xh_close
if xh_wait_exit 15; then echo "ok   process exited after the window closed"
else echo "FAIL process still running"; kill "$XH_PID"; fails=$((fails+1)); fi
grep -q ':final-state {:count 7}' "$LOG" && echo "ok   final state {:count 7}" || { echo "FAIL final state"; fails=$((fails+1)); cat "$LOG"; }
[ $fails = 0 ] && echo PASS || { echo "FAIL ($fails)"; exit 1; }
