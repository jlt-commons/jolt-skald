// A macOS stand-in for the subset of xdotool the e2e tests use, so the same
// scripts drive real windows on macOS. Built by test/xharness.sh on first use.
// Needs Accessibility (input, close) and Screen Recording (window titles,
// screenshots) for the terminal running the tests: System Settings > Privacy.
//
// Commands chain like xdotool's: xdotool mousemove 10 20 click 1 key Return
//   search [--name|--onlyvisible|--pid P]... PATTERN   print matching window ids
//   getwindowgeometry --shell WIN   X Y WIDTH HEIGHT of the content area
//   windowfocus|windowactivate [--sync] WIN
//   mousemove X Y | mousedown B | mouseup B | click [--repeat N] [--delay MS] B
//   key K... | keydown K | keyup K | type [--delay MS] TEXT
//   close WIN                       press the window's close button (not xdotool)
import AppKit
import ApplicationServices

// ponytail: fixed title-bar height, override with XH_TITLEBAR if the OS changes it
let titlebar = Double(ProcessInfo.processInfo.environment["XH_TITLEBAR"] ?? "") ?? 28

var args = Array(CommandLine.arguments.dropFirst())
var pos = CGEvent(source: nil)!.location
var mods: CGEventFlags = []
let src = CGEventSource(stateID: .hidSystemState)

// Without Accessibility, macOS can't raise the app, so synthetic input
// would land in whatever window is in front. Refuse instead.
let input: Set = ["windowfocus", "windowactivate", "close", "mousemove", "mousedown", "mouseup", "click", "key", "keydown", "keyup", "type"]
if args.contains(where: input.contains) && !AXIsProcessTrusted() {
  die("xdotool (macOS): grant Accessibility to your terminal app in System Settings > Privacy & Security, then rerun")
}

func next() -> String { args.isEmpty ? "" : args.removeFirst() }
func ms(_ n: Double) { usleep(useconds_t(n * 1000)) }
func die(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

func windows() -> [[String: Any]] {
  CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
func window(_ id: String) -> [String: Any] {
  guard let w = windows().first(where: { "\($0[kCGWindowNumber as String] ?? "")" == id }) else { die("no window \(id)") }
  return w
}

// X11 keysym names -> macOS virtual key codes
let keys: [String: CGKeyCode] = [
  "Return": 36, "Tab": 48, "space": 49, "BackSpace": 51, "Escape": 53, "Delete": 117,
  "Left": 123, "Right": 124, "Down": 125, "Up": 126, "Home": 115, "End": 119,
  "Page_Up": 116, "Page_Down": 121,
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
  "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
  "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
  "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
]
let modKeys: [String: (CGKeyCode, CGEventFlags)] = [
  "ctrl": (59, .maskControl), "shift": (56, .maskShift),
  "alt": (58, .maskAlternate), "super": (55, .maskCommand), "cmd": (55, .maskCommand),
]

func keyEvent(_ name: String, _ down: Bool) {
  if let (code, flag) = modKeys[name] {
    if down { mods.insert(flag) } else { mods.remove(flag) }
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    e.flags = mods; e.post(tap: .cghidEventTap); return
  }
  guard let code = keys[name] ?? keys[name.lowercased()] else { die("unknown key \(name)") }
  let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
  e.flags = mods; e.post(tap: .cghidEventTap)
}

// "ctrl+shift+a": hold the modifiers, tap the key, release in reverse
func chord(_ spec: String) {
  let parts = spec.split(separator: "+").map(String.init)
  for m in parts.dropLast() { keyEvent(m, true); ms(30) }
  keyEvent(parts.last!, true); ms(30); keyEvent(parts.last!, false)
  for m in parts.dropLast().reversed() { ms(30); keyEvent(m, false) }
}

func mouse(_ type: CGEventType, _ button: CGMouseButton, clicks: Int64 = 1) {
  let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: button)!
  e.setIntegerValueField(.mouseEventClickState, value: clicks)
  e.flags = mods; e.post(tap: .cghidEventTap)
}

func button(_ b: String, _ down: Bool, clicks: Int64 = 1) {
  switch b {
  case "1": mouse(down ? .leftMouseDown : .leftMouseUp, .left, clicks: clicks)
  case "3": mouse(down ? .rightMouseDown : .rightMouseUp, .right, clicks: clicks)
  case "4", "5":   // wheel up / down, one notch per click like X11
    if down { CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                      wheel1: b == "4" ? 3 : -3, wheel2: 0, wheel3: 0)!.post(tap: .cghidEventTap) }
  default: die("unknown button \(b)")
  }
}

while !args.isEmpty {
  switch next() {
  case "search":
    var pid: Int32? = nil, pattern = ""
    while let a = args.first {
      if a == "--pid" { _ = next(); pid = Int32(next()) }
      else if a.hasPrefix("--") { _ = next() }
      else { pattern = next(); break }
    }
    let re = try! NSRegularExpression(pattern: pattern)
    for w in windows() where (w[kCGWindowLayer as String] as? Int) == 0 {
      let name = w[kCGWindowName as String] as? String ?? ""
      if let p = pid, (w[kCGWindowOwnerPID as String] as? Int32) != p { continue }
      if re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
        print(w[kCGWindowNumber as String]!)
      }
    }
  case "getwindowgeometry":
    if args.first == "--shell" { _ = next() }
    let b = window(next())[kCGWindowBounds as String] as! [String: Double]
    print("X=\(Int(b["X"]!))\nY=\(Int(b["Y"]! + titlebar))\nWIDTH=\(Int(b["Width"]!))\nHEIGHT=\(Int(b["Height"]! - titlebar))")
  case "windowfocus", "windowactivate":
    if args.first == "--sync" { _ = next() }
    let pid = window(next())[kCGWindowOwnerPID as String] as! Int32
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var ws: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ws)
    if let w = (ws as? [AXUIElement])?.first { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
    ms(300)
  case "close":
    let pid = window(next())[kCGWindowOwnerPID as String] as! Int32
    let app = AXUIElementCreateApplication(pid)
    var ws: CFTypeRef?, btn: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ws)
    guard let w = (ws as? [AXUIElement])?.first else { die("no AX window (grant Accessibility?)") }
    AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &btn)
    AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
  case "mousemove":
    pos = CGPoint(x: Double(next())!, y: Double(next())!)
    let dragging = CGEventSource.buttonState(.hidSystemState, button: .left)
    mouse(dragging ? .leftMouseDragged : .mouseMoved, .left)
  case "mousedown": button(next(), true)
  case "mouseup": button(next(), false)
  case "click":
    var n = 1, delay = 12.0
    while let a = args.first, a.hasPrefix("--") {
      _ = next(); if a == "--repeat" { n = Int(next())! } else { delay = Double(next())! }
    }
    let b = next()
    for i in 1...n { button(b, true, clicks: Int64(i)); ms(10); button(b, false, clicks: Int64(i)); if i < n { ms(delay) } }
  case "key":
    while let a = args.first, !["mousemove", "click", "key", "keydown", "keyup", "type", "mousedown", "mouseup"].contains(a) {
      chord(next()); ms(30)
    }
  case "keydown": keyEvent(next(), true)
  case "keyup": keyEvent(next(), false)
  case "type":
    var delay = 12.0
    if args.first == "--delay" { _ = next(); delay = Double(next())! }
    for ch in next().utf16 {
      for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
        e.keyboardSetUnicodeString(stringLength: 1, unicodeString: [ch])
        e.post(tap: .cghidEventTap)
      }
      ms(delay)
    }
  case let c: die("unsupported command: \(c)")
  }
}
