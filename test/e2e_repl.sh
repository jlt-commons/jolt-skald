#!/usr/bin/env bash
# REPL-driven development against a live window, over nREPL (the protocol
# CIDER / Calva / Cursive use): start the app from the REPL, redefine view
# and update, poke state, break and fix a view, close, start again.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../examples"
source "$here/xharness.sh"
xh_start_x
PORT=${NREPL_PORT:-7893}
LOG=/tmp/e2e_repl_server.log
setsid nohup jolt nrepl-server "$PORT" --no-port-file >"$LOG" 2>&1 </dev/null &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for _ in $(seq 1 120); do grep -q "started" "$LOG" && break; sleep 0.5; done

fails=0
ev()  { python3 "$here/nrepl.py" "$PORT" "$1" "${2:-user}"; }
check() { # check NAME EXPECTED CODE [NS]
  local got; got=$(ev "$3" "${4:-user}" 2>&1 | tail -1)
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $got"; fails=$((fails+1)); fi
}
frames() { ev '(:frames (sk/stats))' | tail -1; }

ev "(require '[skald.core :as sk] '[examples.counter :as c])" >/dev/null
ev "(def app (sk/start! {:title \"Hello\" :size [640 400] :init {:count 0}
                         :update #'c/update-state :view #'c/view}))" >/dev/null
xh_wait_window Hello || { cat "$LOG"; exit 1; }
check "start! returned, app running" "true" "(sk/running?)"
xh_shot /tmp/repl_0.png

# 1. redefine view from the REPL: must repaint with no input at all
f0=$(frames)
ev '(defn view [s]
      [:col {:padding :xl :spacing :md :main-align :center :cross-align :center}
       [:text {:size :display :color :primary} (str "Live: " (:count s))]
       [:row {:spacing :md}
        [:button {:on-click :dec :width 64} "−"]
        [:button {:on-click :inc :width 64} "+"]]])' examples.counter >/dev/null
sleep 1.0
f1=$(frames)
if [ "$f1" -gt "$f0" ]; then echo "ok   redefining view repainted without input ($f0 -> $f1 frames)"
else echo "FAIL redefining view did not repaint ($f0 -> $f1)"; fails=$((fails+1)); fi
xh_shot /tmp/repl_1.png

# 2. poke state from the REPL
ev '(sk/swap-state! assoc :count 41)' >/dev/null; sleep 0.6
check "swap-state! from the REPL" "{:count 41}" "@sk/state"

# 3. redefine update: + now adds 10; click it in the window
ev '(defn update-state [s msg] (case msg :inc (update s :count + 10) :dec (update s :count dec) s))' examples.counter >/dev/null
xh_click 358 210
check "redefined update handles the click" "{:count 51}" "@sk/state"
xh_shot /tmp/repl_2.png

# 4. a view that throws shows the error screen; fixing it recovers
ev '(defn view [s] (throw (ex-info "oops from the REPL" {})))' examples.counter >/dev/null
sleep 1.0; xh_shot /tmp/repl_3.png
grep -q "skald: exception in view: oops from the REPL" "$LOG" && echo "ok   view exception printed in the nrepl-server terminal" \
  || { echo "FAIL view exception not printed to the server's stderr"; fails=$((fails+1)); }
check "(sk/last-error) holds it" '"oops from the REPL"' "(ex-message (sk/last-error))"
check "app survived the broken view" "true" "(sk/running?)"
ev '(defn view [s] [:col {:padding :xl} [:text {:size :display} (str "Fixed: " (:count s))]])' examples.counter >/dev/null
sleep 1.0; xh_shot /tmp/repl_4.png

# 5. close the window: the promise from start! yields the final state
xh_close; sleep 1.5
check "closing the window ends the app" "false" "(sk/running?)"
check "start! promise yields the final state" "{:count 51}" "(deref app 5000 :timeout)"
# after exit, redefining view must not try to repaint a closed app
ev '(defn view [s] [:text "after exit"])' examples.counter >/dev/null
check "no repaint attempted after exit" "false" "(sk/running?)"

# 6. a second app in the same REPL process
ev "(def app2 (sk/start! {:title \"Again\" :size [400 200] :init {:n 1}
                          :update (fn [s _] s) :view (fn [s] [:text (str \"again \" (:n s))])}))" >/dev/null
xh_wait_window Again && echo "ok   second start! in the same process" || { echo "FAIL second start!"; fails=$((fails+1)); }
xh_close; sleep 1.5
check "second app closed" "{:n 1}" "(deref app2 5000 :timeout)"

[ $fails = 0 ] && echo PASS || { echo "FAIL ($fails)"; cat "$LOG"; exit 1; }
