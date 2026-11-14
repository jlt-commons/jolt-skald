#!/usr/bin/env bash
# Helpers for driving a Skald app under Xvfb + lavapipe. Source this file.
if [ "$(uname)" != Darwin ]; then
export DISPLAY=${DISPLAY:-:99}
export VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}
fi

xh_start_x() {
  pgrep -x Xvfb >/dev/null && return 0
  local n=${DISPLAY#:}
  rm -f "/tmp/.X${n}-lock" "/tmp/.X11-unix/X${n}"   # stale after a crash
  setsid nohup Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 </dev/null &
  for _ in $(seq 1 20); do xdpyinfo >/dev/null 2>&1 && return 0; sleep 0.25; done
  echo "Xvfb failed to start on $DISPLAY"; return 1
}

# xh_launch LOG NS — `jolt run -m NS` (the examples print :final-state on
# exit); sets XH_PID. With XH_BIN_DIR set, runs the `jolt build` binary
# $XH_BIN_DIR/<last ns segment> from that directory instead.
xh_launch() {
  if [ -n "${XH_BIN_DIR:-}" ]; then
    xh_launch_bin "$1" "$XH_BIN_DIR/${2##*.}" "$XH_BIN_DIR"
  else
    setsid nohup timeout 180 jolt run -m "$2" >"$1" 2>&1 </dev/null &
    XH_PID=$!
  fi
}

# xh_wait_window TITLE — sets XH_WIN, XH_X, XH_Y
xh_wait_window() {
  for _ in $(seq 1 120); do
    XH_WIN=$(xdotool search --name "^$1\$" 2>/dev/null | head -1); [ -n "$XH_WIN" ] && break; sleep 0.5
  done
  [ -z "$XH_WIN" ] && { echo "window '$1' never appeared"; return 1; }
  eval "$(xdotool getwindowgeometry --shell "$XH_WIN")"; XH_X=$X; XH_Y=$Y; XH_W=$WIDTH; XH_H=$HEIGHT
  sleep 1.5
}

xh_click() { xdotool mousemove $((XH_X + $1)) $((XH_Y + $2)) click 1; sleep 0.35; }
xh_type()  { xdotool type --delay 40 "$1"; sleep 0.3; }
xh_shot()  { xwd -root -silent | convert xwd:- -crop "${XH_W}x${XH_H}+${XH_X}+${XH_Y}" +repage "$1"; }

# Ask the window manager protocol to close the window (the title-bar ✕).
xh_close() {
  python3 - "$XH_WIN" <<'PY'
import sys
from Xlib import display, protocol, X
d = display.Display(); w = d.create_resource_object('window', int(sys.argv[1]))
ev = protocol.event.ClientMessage(window=w, client_type=d.intern_atom('WM_PROTOCOLS'),
     data=(32, [d.intern_atom('WM_DELETE_WINDOW'), X.CurrentTime, 0, 0, 0]))
w.send_event(ev, event_mask=X.NoEventMask); d.flush()
PY
}

# xh_wait_exit SECONDS — 0 if the app process exited in time
xh_wait_exit() { for _ in $(seq 1 $(( $1 * 4 ))); do kill -0 "$XH_PID" 2>/dev/null || return 0; sleep 0.25; done; return 1; }

# Press, hold across a few frames, release — widgets like slider only
# track the pointer while the button is down.
xh_press() { xdotool mousemove $((XH_X + $1)) $((XH_Y + $2)) mousedown 1; sleep 0.25; xdotool mousemove $((XH_X + $1 + 1)) $((XH_Y + $2)); sleep 0.25; xdotool mouseup 1; sleep 0.35; }

# xh_launch_bin LOG BINARY [DIR] — run a `jolt build` binary (from DIR,
# default the binary's directory); sets XH_PID
xh_launch_bin() {
  ( cd "${3:-$(dirname "$2")}" && setsid nohup timeout 180 "$2" >"$1" 2>&1 </dev/null & echo $! > /tmp/.xh_pid )
  sleep 0.2; XH_PID=$(cat /tmp/.xh_pid)
}

# xh_chord MOD KEY — hold the modifier across frames, as a person does.
# (`xdotool key ctrl+n` can release Ctrl within the same frame as the N.)
xh_chord() { xdotool keydown "$1"; sleep 0.15; xdotool key "$2"; sleep 0.15; xdotool keyup "$1"; sleep 0.35; }

# macOS: same helpers on the real desktop. test/mac/xdotool.swift stands in
# for xdotool; the terminal needs Accessibility and Screen Recording.
if [ "$(uname)" = Darwin ]; then
  _mac="$(cd "$(dirname "${BASH_SOURCE[0]}")/mac" && pwd)"
  [ "$_mac/bin/xdotool" -nt "$_mac/xdotool.swift" ] ||
    { mkdir -p "$_mac/bin" && swiftc -O "$_mac/xdotool.swift" -o "$_mac/bin/xdotool"; } || return 1
  export PATH="$_mac/bin:$PATH"
  setsid() { "$@"; }
  xh_start_x() { :; }
  xh_shot()  { screencapture -x -R "$XH_X,$XH_Y,$XH_W,$XH_H" "$1"; }
  xh_close() { xdotool close "$XH_WIN"; }
  # new windows open behind the terminal: bring each one forward before input
  eval "_xh_wait_window_x11() $(declare -f xh_wait_window | tail -n +2)"
  xh_wait_window() { _xh_wait_window_x11 "$1" && xdotool windowactivate "$XH_WIN"; }
fi
