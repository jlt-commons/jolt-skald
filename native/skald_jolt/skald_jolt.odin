// skald_jolt — a C-ABI shim that lets Jolt (or any C-FFI host) drive Skald.
//
// Skald is generic over the app's State and Msg types, and its widget
// builders take Odin procs, default/named arguments and variadics — none of
// which cross a C boundary. This package instantiates Skald exactly once with
// two concrete, host-agnostic types and re-exports the framework as a flat
// set of `proc "c"` entry points:
//
//   State  — a generation counter. The real state lives in the host (a Jolt
//            atom); Skald only needs *something* to thread through update.
//   Msg    — {tag, kind, i, f, s}. `tag` is a host-side handle for whatever
//            value the host used as the message (a keyword, a vector, a fn);
//            the rest carries the widget's payload (new text, slider value…).
//
// The view is built with a small stack machine:
//
//   * Properties (`sk_pf`, `sk_pc`, `sk_ps`, `sk_pi`, …) are written into a
//     single property register `P` before a builder call.
//   * Leaf builders (`sk_text`, `sk_button`, …) read `P`, push one View onto
//     the node stack, and clear `P`.
//   * Containers bracket their children: `sk_begin()` records the stack
//     depth, the children are emitted, then `sk_col()` (etc.) pops everything
//     above that mark and pushes the container.
//
// Widget builders run their interaction logic at call time (exactly as they
// do in native Odin, where children are evaluated as arguments before the
// parent), so emission order is the same as a hand-written Skald view and
// auto-generated widget IDs stay stable frame to frame.
//
// Threading: everything except `sk_post` must be called on the thread that
// called `sk_run`, from inside the update/view callbacks. `sk_post` may be
// called from any thread; it wakes the UI through Skald's own cmd_thread
// machinery (see "Mailbox" below).
package skald_jolt

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:reflect"
import "core:unicode"
import "core:mem"
import "core:strings"
import "core:sync"
import sk "gui:skald"
import "core:os"
import sdl3 "vendor:sdl3"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

Msg_Kind :: enum i32 {
	None  = 0,
	Bool  = 1,
	Int   = 2,
	Float = 3,
	Str   = 4,
	Date  = 5, // v = {year, month, day, 0}
	Time  = 6, // v = {hour, minute, second, 0}
	Color = 7, // v = sRGB {r, g, b, a}
	Sort  = 8,  // v = {column, ascending (0/1)}
	Size  = 9,  // v = {column, width}
	Point = 10, // v = {x, y} canvas-local
	Drop  = 11, // i = payload id, s = payload kind
	Files = 12, // s = newline-separated paths
	Row   = 13, // i = row, v = {modifier bits (1 << sk.Modifier), 0, 0, 0}
	Key   = 14, // i = sk.Key, v = {modifier bits, pressed (0/1), 0, 0}
	Path  = 15, // s = chosen path (heap; freed after update), i = 1 if cancelled
}

Msg :: struct {
	tag:  i64,
	kind: Msg_Kind,
	i:    i64,
	f:    f64,
	s:    string,
	v:    [4]f64,
}

State :: struct {
	gen: u64,
}

// Reserved tags. Host tags are >= 0 (per-frame view table) or <= -16
// (persistent table: commands, mailbox, close handler).
NO_TAG    :: i64(-1) // widget had no handler; update ignores it
PUMP_TAG  :: i64(-2) // mailbox worker woke up; drain the mailbox
CLOSE_TAG :: i64(-3) // native window close was requested
THEME_TAG :: i64(-4) // OS light/dark preference changed

Update_Fn :: #type proc "c" (tag: i64, kind: i32, i: i64, f: f64, s: cstring,
                             v0, v1, v2, v3: f64)
View_Fn   :: #type proc "c" (window: i64, reset: i32)
// Virtual lists and tables build rows during layout, after the view has
// returned: the shim calls back into the host per visible row.
//   op 0: emit row `index` of list `list` onto the node stack (returns 0)
//   op 1: return the row's stable key
//   op 2: return 1 if the row is selected
List_Fn   :: #type proc "c" (list: i64, index: i64, op: i32) -> i64

// ---------------------------------------------------------------------------
// Property register
// ---------------------------------------------------------------------------
//
// The host discovers names and numeric ids at load time through
// `sk_enum_count` / `sk_enum_name`, so this enum is the single source of
// truth: add a field here and it is immediately settable from Jolt as the
// kebab-cased keyword (`Font_Size` -> `:font-size`).

Prop :: enum i32 {
	// numbers (P.f). Value / Min / Max also take a 4-vector (P.v) for
	// dates and times.
	Spacing, Line_Spacing, Padding, Width, Height, Radius, Size, Font_Size,
	Max_Width, Weight, Min_Main, Value, Min, Max, Step, Thickness, Shadow,
	Shadow_Y, Track_W, Track_H, Thumb_R, Box_Size, Factor, Wheel_Step, Period,
	Dismiss_After, Margin, Fill, Gap, X_Secs, Indent, Row_Height, Disc_Size,
	Border_Width, Header_Height, First_Size, Min_First, Min_Second,
	Divider_Thickness, Spacing_X, Spacing_Y, Estimated_Height, Fallback_Height,
	// colors (P.c)
	Color, Bg, Fg, Border, Shadow_Color, Color_Fill, Color_Bg, Color_On,
	Color_Off, Color_Knob, Color_Box, Color_Dot, Color_Hover, Scrim,
	Track_Color, Thumb_Color, Tint,
	// strings (P.s) — `Value` doubles as the string value for text widgets.
	// Anchor..Week_Start are enum names ("bottom-center"), resolved per
	// widget with reflect, so the host needs no table for them.
	Text, Label, Placeholder, Error, Title, Description, Path, Shortcut,
	Separator, Icon, Y_Unit, Anchor, Kind, Fit, Direction, Week_Start, Link,
	Accepts, Cursor, Keys,
	// integers / enums / booleans (P.i)
	Id, Main_Align, Cross_Align, Align, Overflow, Tone, Selected, Active,
	Decimals, Max_Chars, Min_Lines, Max_Lines, Disabled, Multiline, Wrap,
	Password, Clear_Button, Escape_Clears, Invalid, Checked, Open, Vertical,
	Indeterminate, Underline, Focusable, Filter, Free_Form, Max_Rows,
	Minute_Step, Second_Step, Depth, Expandable, Expanded, Grid, Y_Right,
	Visible, Sortable, Resizable, Count, Sort_Column, Ascending, Reveal_Row,
	Handle, Has_Key, Focus_Row, Bold, Italic, Strike, Selectable,
	// message tags (P.i)
	On_Click, On_Change, On_Select, On_Dismiss, On_Toggle, On_Submit, On_Close,
	On_Activate, On_Sort, On_Resize, On_Context, On_Link, On_Drop, On_Press,
	On_Drag, On_Release, On_Row_Select,
}

// Theme color roles, settable as color props by keyword (`:bg :primary`).
Color_Role :: enum i32 {
	Bg, Surface, Elevated, Border, Fg, Fg_Muted, Primary, On_Primary,
	Selection, Success, Warning, Danger, Transparent,
}

// Theme scale tokens. The host picks the scale (spacing / radius / font)
// from the property it is setting.
Token :: enum i32 { Xs, Sm, Md, Lg, Xl, Pill, Display }
Token_Scale :: enum i32 { Spacing, Radius, Font }

// The register is reset after every widget, so a reset must be cheap:
// `set` flags guard every read, and only the props actually set are
// un-flagged (via `touched`), instead of zeroing the whole struct.
// (A bit_set would cap Prop at 128 members.)
Props :: struct {
	set:      [Prop]bool,
	vset:     [Prop]bool,
	f:        [Prop]f64,
	c:        [Prop]sk.Color,
	s:        [Prop]string,
	i:        [Prop]i64,
	v:        [Prop][4]f64,
	touched:  [96]Prop,
	n:        int,
	overflow: bool,
}

@(private) mark :: #force_inline proc "contextless" (p: Prop) {
	if P.set[p] { return }
	P.set[p] = true
	if P.n < len(P.touched) { P.touched[P.n] = p; P.n += 1 } else { P.overflow = true }
}

@(private) clear_props :: proc "contextless" () {
	if P.overflow { P = {}; return }
	for k in 0 ..< P.n {
		p := P.touched[k]
		P.set[p] = false
		P.vset[p] = false
	}
	P.n = 0
}

// ---------------------------------------------------------------------------
// Globals (UI thread only, except the mailbox)
// ---------------------------------------------------------------------------

g_update:       Update_Fn
g_view:         View_Fn
g_list_fn:      List_Fn
g_ctx:          runtime.Context // Odin context of the Skald frame we're inside
g_vctx:         ^sk.Ctx(Msg)    // non-nil only while the host builds a view
g_in_update:    bool

P:              Props
g_stack:        [dynamic]sk.View
g_marks:        [dynamic]int
g_opts:         [dynamic]string
g_scopes:       [dynamic]sk.Widget_Scope_Saved
g_cmds:         [dynamic]sk.Command(Msg)
g_cur_tag:      i64 // tag for Skald callbacks that carry no payload slot

g_rendered:     [dynamic]i64 // windows rendered since the host table reset
g_updated:      bool         // an update ran since the last view

g_close_tag:    i64 = NO_TAG
g_follow_theme: bool

// Mailbox: host threads post persistent tags; a Skald cmd_thread worker
// blocks on the semaphore and, when woken, returns PUMP_TAG so the UI
// thread drains the queue inside update.
g_mbox_lock:    sync.Mutex
g_mbox:         [dynamic]i64
g_mbox_sema:    sync.Sema
g_closing:      bool // atomic access
g_pump_armed:   bool

// ---------------------------------------------------------------------------
// Property helpers
// ---------------------------------------------------------------------------

@(private) has :: #force_inline proc(p: Prop) -> bool { return P.set[p] }

@(private) pf :: proc(p: Prop, def: f32) -> f32 { return has(p) ? f32(P.f[p]) : def }
@(private) pd :: proc(p: Prop, def: f64) -> f64 { return has(p) ? P.f[p] : def }
@(private) pc :: proc(p: Prop) -> sk.Color { return has(p) ? P.c[p] : {} }
@(private) ps :: proc(p: Prop, def := "") -> string { return has(p) ? P.s[p] : def }
@(private) pi :: proc(p: Prop, def: i64 = 0) -> i64 { return has(p) ? P.i[p] : def }
@(private) pb :: proc(p: Prop, def := false) -> bool { return has(p) ? P.i[p] != 0 : def }
@(private) ptag :: proc(p: Prop) -> i64 { return has(p) ? P.i[p] : NO_TAG }
@(private) pid :: proc() -> sk.Widget_ID { return sk.Widget_ID(transmute(u64)pi(.Id)) }

@(private) pmain :: proc() -> sk.Main_Align { return sk.Main_Align(clamp(pi(.Main_Align), 0, i64(max(sk.Main_Align)))) }
@(private) pcross :: proc(p: Prop = .Cross_Align) -> sk.Cross_Align { return sk.Cross_Align(clamp(pi(p), 0, i64(max(sk.Cross_Align)))) }
@(private) povf :: proc() -> sk.Text_Overflow { return sk.Text_Overflow(clamp(pi(.Overflow), 0, i64(max(sk.Text_Overflow)))) }
@(private) ptone :: proc(def: sk.Badge_Tone) -> sk.Badge_Tone {
	return has(.Tone) ? sk.Badge_Tone(clamp(pi(.Tone), 0, i64(max(sk.Badge_Tone)))) : def
}

@(private) push :: proc(v: sk.View) {
	append(&g_stack, v)
	clear_props()
}

// take_children pops everything above the innermost sk_begin mark into a
// temp-allocated slice (the same allocator Skald's own col/row use).
@(private) take_children :: proc() -> []sk.View {
	mark := len(g_stack)
	if len(g_marks) > 0 { mark = pop(&g_marks) }
	mark = clamp(mark, 0, len(g_stack))
	out := make([]sk.View, len(g_stack) - mark, context.temp_allocator)
	copy(out, g_stack[mark:])
	resize(&g_stack, mark)
	return out
}

// one_child collapses a child list to a single View for wrappers that take
// exactly one (flex, scroll, tooltip…). Several children become a column.
@(private) one_child :: proc(kids: []sk.View) -> sk.View {
	switch len(kids) {
	case 0: return sk.spacer(0)
	case 1: return kids[0]
	}
	return sk.col(..kids)
}

@(private) take_opts :: proc() -> []string {
	out := make([]string, len(g_opts), context.temp_allocator)
	copy(out, g_opts[:])
	clear(&g_opts)
	return out
}

@(private) tmp_str :: proc(s: cstring) -> string {
	if s == nil { return "" }
	return strings.clone_from_cstring(s, context.temp_allocator)
}

@(private) in_view :: proc() -> bool { return g_vctx != nil }

// Message constructors handed to Skald's *_payload builders. The payload is
// the host tag, so one proc serves every widget instance.
@(private) m_unit  :: proc(tag: i64) -> Msg { return {tag = tag} }
@(private) m_bool  :: proc(tag: i64, v: bool) -> Msg { return {tag = tag, kind = .Bool, i = v ? 1 : 0} }
@(private) m_int   :: proc(tag: i64, v: int) -> Msg { return {tag = tag, kind = .Int, i = i64(v)} }
@(private) m_f32   :: proc(tag: i64, v: f32) -> Msg { return {tag = tag, kind = .Float, f = f64(v)} }
@(private) m_f64   :: proc(tag: i64, v: f64) -> Msg { return {tag = tag, kind = .Float, f = v} }
@(private) m_str   :: proc(tag: i64, v: string) -> Msg {
	return {tag = tag, kind = .Str, s = strings.clone(v, context.temp_allocator)}
}
// …and for builders whose callbacks have no payload slot. Skald invokes
// these synchronously inside the builder, so g_cur_tag is always current.
@(private) c_unit :: proc() -> Msg { return {tag = g_cur_tag} }
@(private) c_bool :: proc(v: bool) -> Msg { return m_bool(g_cur_tag, v) }
@(private) c_int  :: proc(v: int) -> Msg { return m_int(g_cur_tag, v) }

// ---------------------------------------------------------------------------
// Introspection — lets the host build its keyword tables from this file
// ---------------------------------------------------------------------------

// kind: 0 = Prop, 1 = Color_Role, 2 = Token, 3 = Main_Align, 4 = Cross_Align,
//       5 = Text_Overflow, 6 = Badge_Tone, 7 = Msg_Kind, 8 = Modifier, 9 = Key
@(export) sk_enum_count :: proc "c" (kind: i32) -> i32 {
	switch kind {
	case 0: return i32(len(Prop))
	case 1: return i32(len(Color_Role))
	case 2: return i32(len(Token))
	case 3: return i32(len(sk.Main_Align))
	case 4: return i32(len(sk.Cross_Align))
	case 5: return i32(len(sk.Text_Overflow))
	case 6: return i32(len(sk.Badge_Tone))
	case 7: return i32(len(Msg_Kind))
	case 8: return i32(len(sk.Modifier))
	case 9: return i32(len(sk.Key))
	}
	return 0
}

// Returns a pointer to a static, NUL-terminated name. Names are produced
// once and cached; the host copies them.
@(export) sk_enum_name :: proc "c" (kind: i32, idx: i32) -> cstring {
	context = runtime.default_context()
	@(static) cache: map[[2]i32]cstring
	key := [2]i32{kind, idx}
	if s, ok := cache[key]; ok { return s }
	name: string
	switch kind {
	case 0: name = fmt.tprint(Prop(idx))
	case 1: name = fmt.tprint(Color_Role(idx))
	case 2: name = fmt.tprint(Token(idx))
	case 3: name = fmt.tprint(sk.Main_Align(idx))
	case 4: name = fmt.tprint(sk.Cross_Align(idx))
	case 5: name = fmt.tprint(sk.Text_Overflow(idx))
	case 6: name = fmt.tprint(sk.Badge_Tone(idx))
	case 7: name = fmt.tprint(Msg_Kind(idx))
	case 8: name = fmt.tprint(sk.Modifier(idx))
	case 9: name = fmt.tprint(sk.Key(idx))
	case:   return nil
	}
	c := strings.clone_to_cstring(name)
	cache[key] = c
	return c
}

@(export) sk_abi_version :: proc "c" () -> i32 { return 3 }

// Odin's runtime start-up: global initialisers and @(init) procedures in
// core:os, core:fmt and the rest. A shared-library build runs it from a
// loader hook; a static archive (-no-entry-point) has no such hook, so the
// static support archive calls this from a C constructor (static_init.c).
// Idempotent, and a no-op in shared builds.
g_runtime_started: bool

// macOS: Homebrew's Vulkan loader lives outside dlopen's default search path,
// so SDL fails with "Failed to load Vulkan Portability library". Point SDL at
// it. A user-set SDL_VULKAN_LIBRARY env var still wins (env beats hints).
when ODIN_OS == .Darwin {
	@(init) set_vulkan_library_hint :: proc "contextless" () {
		context = runtime.default_context()
		for p in ([]cstring{"/opt/homebrew/lib/libvulkan.1.dylib", "/usr/local/lib/libvulkan.1.dylib"}) {
			if os.exists(string(p)) { sdl3.SetHint("SDL_VULKAN_LIBRARY", p); return }
		}
	}
}

@(export) sk_startup_runtime :: proc "c" () {
	if g_runtime_started { return }
	g_runtime_started = true
	when ODIN_BUILD_MODE != .Dynamic {
		context = runtime.default_context()
		#force_no_inline runtime._startup_runtime()
	}
}

// How the host should marshal a property:
//   0 = number, 1 = color, 2 = string, 3 = integer/enum/bool, 4 = msg tag
@(export) sk_prop_kind :: proc "c" (key: i32) -> i32 {
	if !valid_prop(key) { return -1 }
	switch {
	case key >= i32(Prop.On_Click): return 4
	case key >= i32(Prop.Id):       return 3
	case key >= i32(Prop.Text):     return 2
	case key >= i32(Prop.Color):    return 1
	}
	return 0
}

// Discard a half-built view (the host's view fn threw). Open scopes are
// unwound so auto-IDs stay consistent.
@(export) sk_reset :: proc "c" () {
	context = g_ctx
	if g_vctx != nil {
		for len(g_scopes) > 0 { sk.widget_scope_pop(g_vctx, pop(&g_scopes)) }
	}
	clear(&g_stack); clear(&g_marks); clear(&g_opts)
	reset_batch2()
	clear_props()
}

// ---------------------------------------------------------------------------
// Property setters
// ---------------------------------------------------------------------------

@(private) valid_prop :: proc "contextless" (key: i32) -> bool {
	return key >= 0 && key < i32(len(Prop))
}

@(export) sk_pf :: proc "c" (key: i32, v: f64) {
	if !valid_prop(key) { return }
	p := Prop(key); P.f[p] = v; mark(p)
}

@(export) sk_pi :: proc "c" (key: i32, v: i64) {
	if !valid_prop(key) { return }
	p := Prop(key); P.i[p] = v; mark(p)
}

// Color from sRGB components in 0..1 (what hex codes and color pickers
// mean). Skald renders in linear space, so the RGB channels are converted
// with its own sRGB transfer function; alpha is linear already.
@(export) sk_pc :: proc "c" (key: i32, r, g, b, a: f64) {
	if !valid_prop(key) { return }
	context = runtime.default_context()
	p := Prop(key)
	P.c[p] = {sk.srgb_to_linear(f32(r)), sk.srgb_to_linear(f32(g)), sk.srgb_to_linear(f32(b)), f32(a)}
	mark(p)
}

// Color already in Skald's linear space, passed through untouched.
@(export) sk_pc_linear :: proc "c" (key: i32, r, g, b, a: f64) {
	if !valid_prop(key) { return }
	p := Prop(key); P.c[p] = {f32(r), f32(g), f32(b), f32(a)}; mark(p)
}

@(export) sk_ps :: proc "c" (key: i32, s: cstring) {
	if !valid_prop(key) { return }
	context = g_ctx
	p := Prop(key); P.s[p] = tmp_str(s); mark(p)
}

// Color from the active theme by role.
@(export) sk_pc_role :: proc "c" (key: i32, role: i32) {
	if !valid_prop(key) || g_vctx == nil { return }
	c := theme_color(g_vctx.theme, Color_Role(role))
	p := Prop(key); P.c[p] = c; mark(p)
}

// Number from the active theme's spacing / radius / font scale.
@(export) sk_pf_token :: proc "c" (key: i32, scale: i32, tok: i32) {
	if !valid_prop(key) || g_vctx == nil { return }
	p := Prop(key); P.f[p] = f64(theme_token(g_vctx.theme, Token_Scale(scale), Token(tok))); mark(p)
}

// Widget id from a stable string key (Skald's FNV-1a hash_id).
@(export) sk_pid_str :: proc "c" (s: cstring) {
	context = g_ctx
	P.i[.Id] = i64(transmute(u64)sk.hash_id(tmp_str(s)))
	mark(.Id)
}

// Append one entry to the option list consumed by select / segmented / tabs.
@(export) sk_opt :: proc "c" (s: cstring) {
	context = g_ctx
	append(&g_opts, tmp_str(s))
}

@(private) theme_color :: proc "contextless" (th: ^sk.Theme, r: Color_Role) -> sk.Color {
	c := th.color
	switch r {
	case .Bg:          return c.bg
	case .Surface:     return c.surface
	case .Elevated:    return c.elevated
	case .Border:      return c.border
	case .Fg:          return c.fg
	case .Fg_Muted:    return c.fg_muted
	case .Primary:     return c.primary
	case .On_Primary:  return c.on_primary
	case .Selection:   return c.selection
	case .Success:     return c.success
	case .Warning:     return c.warning
	case .Danger:      return c.danger
	case .Transparent: return {0, 0, 0, 0}
	}
	return c.fg
}

@(private) theme_token :: proc "contextless" (th: ^sk.Theme, scale: Token_Scale, t: Token) -> f32 {
	switch scale {
	case .Spacing:
		s := th.spacing
		switch t {
		case .Xs: return s.xs
		case .Sm: return s.sm
		case .Md: return s.md
		case .Lg: return s.lg
		case .Xl, .Pill, .Display: return s.xl
		}
	case .Radius:
		r := th.radius
		switch t {
		case .Xs, .Sm: return r.sm
		case .Md: return r.md
		case .Lg: return r.lg
		case .Xl, .Display: return r.xl
		case .Pill: return r.pill
		}
	case .Font:
		f := th.font
		switch t {
		case .Xs: return f.size_xs
		case .Sm: return f.size_sm
		case .Md, .Pill: return f.size_md
		case .Lg: return f.size_lg
		case .Xl: return f.size_xl
		case .Display: return f.size_display
		}
	}
	return 0
}

// Read a theme color into out[0..3] as sRGB (the inverse of sk_pc, so a
// value read here can be passed straight back as a color).
@(export) sk_theme_color :: proc "c" (role: i32, out: [^]f32) {
	if g_vctx == nil || out == nil { return }
	c := theme_color(g_vctx.theme, Color_Role(role))
	out[0], out[1], out[2], out[3] = linear_to_srgb(c[0]), linear_to_srgb(c[1]), linear_to_srgb(c[2]), c[3]
}

@(private) linear_to_srgb :: proc "contextless" (x: f32) -> f32 {
	if x <= 0.0031308 { return x * 12.92 }
	return 1.055 * math.pow(x, 1.0 / 2.4) - 0.055
}

@(export) sk_breakpoint :: proc "c" () -> i32 {
	return g_vctx == nil ? 0 : i32(g_vctx.breakpoint)
}

// ---------------------------------------------------------------------------
// Structure: marks, scopes
// ---------------------------------------------------------------------------

@(export) sk_begin :: proc "c" () {
	context = g_ctx
	append(&g_marks, len(g_stack))
}

// Keyed widget scope: auto-IDs of widgets emitted between push and pop are
// salted with `key`, so list rows keep their state when reordered.
@(export) sk_scope_push :: proc "c" (key: i64) {
	context = g_ctx
	if !in_view() { return }
	append(&g_scopes, sk.widget_scope_push(g_vctx, transmute(u64)key))
}

@(export) sk_scope_push_str :: proc "c" (key: cstring) {
	context = g_ctx
	if !in_view() { return }
	h := transmute(u64)sk.hash_id(tmp_str(key))
	append(&g_scopes, sk.widget_scope_push(g_vctx, h))
}

@(export) sk_scope_pop :: proc "c" () {
	context = g_ctx
	if !in_view() || len(g_scopes) == 0 { return }
	sk.widget_scope_pop(g_vctx, pop(&g_scopes))
}

// ---------------------------------------------------------------------------
// Layout & primitives
// ---------------------------------------------------------------------------

@(export) sk_col :: proc "c" () {
	context = g_ctx
	kids := take_children()
	push(sk.col(..kids,
		spacing = pf(.Spacing, 0), padding = pf(.Padding, 0),
		width = pf(.Width, 0), height = pf(.Height, 0),
		main_align = pmain(), cross_align = pcross(),
		bg = pc(.Bg), radius = pf(.Radius, 0),
		shadow = pf(.Shadow, 0), shadow_color = pc(.Shadow_Color), shadow_y = pf(.Shadow_Y, 0)))
}

@(export) sk_row :: proc "c" () {
	context = g_ctx
	kids := take_children()
	push(sk.row(..kids,
		spacing = pf(.Spacing, 0), padding = pf(.Padding, 0),
		width = pf(.Width, 0), height = pf(.Height, 0),
		main_align = pmain(), cross_align = pcross(),
		bg = pc(.Bg), radius = pf(.Radius, 0),
		shadow = pf(.Shadow, 0), shadow_color = pc(.Shadow_Color), shadow_y = pf(.Shadow_Y, 0)))
}

@(export) sk_wrap_row :: proc "c" () {
	context = g_ctx
	kids := take_children()
	push(sk.wrap_row(..kids,
		spacing = pf(.Spacing, 0), line_spacing = pf(.Line_Spacing, 0),
		padding = pf(.Padding, 0), width = pf(.Width, 0),
		bg = pc(.Bg), radius = pf(.Radius, 0)))
}

@(export) sk_flex :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	push(sk.flex(pf(.Weight, 1), kid, min_main = pf(.Min_Main, 0)))
}

@(export) sk_clip :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	push(sk.clip({pf(.Width, 0), pf(.Height, 0)}, kid))
}

@(export) sk_opacity :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	push(sk.opacity(pf(.Factor, 1), kid))
}

@(export) sk_spacer :: proc "c" () {
	context = g_ctx
	push(sk.spacer(pf(.Size, 0)))
}

@(export) sk_rect :: proc "c" () {
	context = g_ctx
	col := has(.Color) ? pc(.Color) : (in_view() ? g_vctx.theme.color.surface : sk.Color{})
	push(sk.rect({pf(.Width, 0), pf(.Height, 0)}, col, pf(.Radius, 0)))
}

@(export) sk_text :: proc "c" () {
	context = g_ctx
	col := has(.Color) ? pc(.Color) : (in_view() ? g_vctx.theme.color.fg : sk.Color{1, 1, 1, 1})
	size := pf(.Size, in_view() ? g_vctx.theme.font.size_md : 14)
	if pb(.Selectable) && in_view() {
		push(sk.text_selectable(g_vctx, ps(.Text), col, size, max_width = pf(.Max_Width, 0), id = pid()))
		return
	}
	push(sk.text(ps(.Text), col, size,
		max_width = pf(.Max_Width, 0), overflow = povf(), align = pcross(.Align)))
}

// ---------------------------------------------------------------------------
// Widgets (require an active view)
// ---------------------------------------------------------------------------

@(export) sk_divider :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.divider(g_vctx, vertical = pb(.Vertical), color = pc(.Color), thickness = pf(.Thickness, 1)))
}

@(export) sk_button :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.button(g_vctx, ps(.Label), m_unit(ptag(.On_Click)),
		id = pid(), bg = pc(.Bg), fg = pc(.Fg), radius = pf(.Radius, 0),
		padding = {pf(.Padding, 0), pf(.Padding, 0)}, font_size = pf(.Font_Size, 0),
		width = pf(.Width, 0), text_align = pcross(.Align) if has(.Align) else .Center,
		overflow = povf(), disabled = pb(.Disabled)))
}

@(export) sk_link :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.link(g_vctx, ps(.Label), m_unit(ptag(.On_Click)),
		id = pid(), color = pc(.Color), color_hover = pc(.Color_Hover),
		font_size = pf(.Font_Size, 0), underline = pb(.Underline, true), disabled = pb(.Disabled)))
}

@(export) sk_text_input :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.text_input(g_vctx, ps(.Value), ptag(.On_Change), m_str,
		id = pid(), placeholder = ps(.Placeholder),
		width = pf(.Width, 0), height = pf(.Height, 0), font_size = pf(.Font_Size, 0),
		padding = {pf(.Padding, 0), pf(.Padding, 0)},
		bg = pc(.Bg), fg = pc(.Fg), border = pc(.Border),
		disabled = pb(.Disabled), multiline = pb(.Multiline), wrap = pb(.Wrap),
		password = pb(.Password), clear_button = pb(.Clear_Button),
		escape_clears = pb(.Escape_Clears), invalid = pb(.Invalid), error = ps(.Error),
		max_chars = int(pi(.Max_Chars)), line_spacing = pf(.Line_Spacing, 0),
		min_lines = int(pi(.Min_Lines)), max_lines = int(pi(.Max_Lines))))
}

@(export) sk_checkbox :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.checkbox(g_vctx, pb(.Checked), ps(.Label), ptag(.On_Change), m_bool,
		id = pid(), font_size = pf(.Font_Size, 0), box_size = pf(.Box_Size, 0),
		color_box = pc(.Color_Box), color_fill = pc(.Color_Fill), disabled = pb(.Disabled)))
}

@(export) sk_toggle :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.toggle(g_vctx, pb(.Checked), ps(.Label), ptag(.On_Change), m_bool,
		id = pid(), font_size = pf(.Font_Size, 0),
		track_w = pf(.Track_W, 0), track_h = pf(.Track_H, 0),
		color_off = pc(.Color_Off), color_on = pc(.Color_On), color_knob = pc(.Color_Knob),
		disabled = pb(.Disabled)))
}

@(export) sk_radio :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.radio(g_vctx, pb(.Selected), ps(.Label), ptag(.On_Select), m_unit,
		id = pid(), font_size = pf(.Font_Size, 0), box_size = pf(.Box_Size, 0),
		color_bg = pc(.Color_Bg), color_dot = pc(.Color_Dot), disabled = pb(.Disabled)))
}

@(export) sk_slider :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.slider(g_vctx, pf(.Value, 0), ptag(.On_Change), m_f32,
		id = pid(), min_value = pf(.Min, 0), max_value = pf(.Max, 1), step = pf(.Step, 0),
		width = pf(.Width, 0), track_h = pf(.Track_H, 4), thumb_r = pf(.Thumb_R, 8),
		disabled = pb(.Disabled)))
}

@(export) sk_number_input :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.number_input(g_vctx, pd(.Value, 0), ptag(.On_Change), m_f64,
		id = pid(), step = pd(.Step, 1), min_value = pd(.Min, min(f64)), max_value = pd(.Max, max(f64)),
		decimals = int(pi(.Decimals)), width = pf(.Width, 140), disabled = pb(.Disabled),
		max_chars = int(pi(.Max_Chars))))
}

@(export) sk_select :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	push(sk.select(g_vctx, ps(.Value), opts, ptag(.On_Change), m_str,
		id = pid(), width = pf(.Width, 0), placeholder = ps(.Placeholder), disabled = pb(.Disabled)))
}

@(export) sk_segmented :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	push(sk.segmented(g_vctx, opts, int(pi(.Selected)), ptag(.On_Change), m_int,
		id = pid(), disabled = pb(.Disabled)))
}

@(export) sk_tabs :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	g_cur_tag = ptag(.On_Change)
	push(sk.tabs(g_vctx, opts, int(pi(.Active)), c_int, id = pid()))
}

@(export) sk_progress :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.progress(g_vctx, pf(.Value, 0), width = pf(.Width, 0), height = pf(.Height, 6),
		color_bg = pc(.Color_Bg), color_fill = pc(.Color_Fill),
		indeterminate = pb(.Indeterminate), period = pf(.Period, 1.2)))
}

@(export) sk_spinner :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.spinner(g_vctx, size = pf(.Size, 24), color = pc(.Color),
		period_ms = int(pd(.Period, 0.9) * 1000)))
}

@(export) sk_badge :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.badge(g_vctx, ps(.Label), tone = ptone(.Primary),
		bg = pc(.Bg), fg = pc(.Fg), font_size = pf(.Font_Size, 0)))
}

@(export) sk_alert :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.alert(g_vctx, ps(.Title), ps(.Description), tone = ptone(.Primary)))
}

@(export) sk_kbd :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.kbd(g_vctx, ps(.Label), font_size = pf(.Font_Size, 0)))
}

@(export) sk_section_header :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.section_header(g_vctx, ps(.Title), color = pc(.Color), font_size = pf(.Font_Size, 0)))
}

// Children (optional): the action view shown under the description.
@(export) sk_empty_state :: proc "c" () {
	context = g_ctx
	kids := take_children()
	if !in_view() { clear_props(); return }
	action := len(kids) > 0 ? one_child(kids) : sk.View(sk.View_Spacer{size = 0})
	push(sk.empty_state(g_vctx, ps(.Title), ps(.Description), action))
}

// Children: the scrolled content.
@(export) sk_scroll :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	if !in_view() { clear_props(); return }
	push(sk.scroll(g_vctx, {pf(.Width, 0), pf(.Height, 0)}, kid,
		id = pid(), wheel_step = pf(.Wheel_Step, 40),
		track_color = pc(.Track_Color), thumb_color = pc(.Thumb_Color),
		focusable = pb(.Focusable)))
}

// Children: the anchor the tooltip attaches to.
@(export) sk_tooltip :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	if !in_view() { clear_props(); return }
	push(sk.tooltip(g_vctx, kid, ps(.Text), id = pid(), shadow = pf(.Shadow, -1)))
}

// Children: the collapsible body.
@(export) sk_collapsible :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	if !in_view() { clear_props(); return }
	g_cur_tag = ptag(.On_Toggle)
	push(sk.collapsible(g_vctx, ps(.Title), pb(.Open), c_bool, kid,
		id = pid(), padding = pf(.Padding, -1), font_size = pf(.Font_Size, 0)))
}

// Children: [content] or [content footer].
@(export) sk_dialog :: proc "c" () {
	context = g_ctx
	kids := take_children()
	if !in_view() { clear_props(); return }
	content := len(kids) > 0 ? kids[0] : sk.spacer(0)
	footer: sk.View
	if len(kids) > 1 { footer = kids[1] }
	g_cur_tag = ptag(.On_Dismiss)
	push(sk.dialog(g_vctx, pb(.Open), content, c_unit, footer = footer,
		id = pid(), width = pf(.Width, 0), max_width = pf(.Max_Width, 480),
		padding = pf(.Padding, 0), bg = pc(.Bg), border = pc(.Border), scrim = pc(.Scrim)))
}

// ---------------------------------------------------------------------------
// Widgets, batch 2: helpers
// ---------------------------------------------------------------------------

g_cur_tag2:     i64 // second payload-less callback (menu: select + dismiss…)
g_vals:         [dynamic]f32
g_menu_entries: [dynamic]sk.Menu_Entry(Msg)
g_menu_items:   [dynamic]sk.Menu_Item(Msg)
g_menu_label:   string
g_menu_open:    bool
g_tree_rows:    [dynamic]sk.Tree_Row

// "bottom-center" / "bottom_center" -> "Bottom_Center"
@(private) enum_ident :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	up := true
	for r in s {
		switch {
		case r == '-' || r == '_' || r == ' ':
			strings.write_byte(&b, '_'); up = true
		case up:
			strings.write_rune(&b, unicode.to_upper(r)); up = false
		case:
			strings.write_rune(&b, unicode.to_lower(r))
		}
	}
	return strings.to_string(b)
}

// An enum-valued prop sent by name. Unknown names fall back to `def`.
@(private) penum :: proc(p: Prop, def: $T) -> T {
	if !has(p) || P.s[p] == "" { return def }
	want := enum_ident(P.s[p])
	if v, ok := reflect.enum_from_name(T, want); ok { return v }
	// case-insensitive fallback: "ns-resize" -> NS_Resize
	names := reflect.enum_field_names(T)
	values := reflect.enum_field_values(T)
	for n, i in names { if strings.equal_fold(n, want) { return T(i64(values[i])) } }
	return def
}

// "Ctrl+Shift+S", "cmd+o", "F5", "ctrl+page-down", "ctrl+1"
@(private) parse_shortcut :: proc(s: string) -> sk.Shortcut {
	sc: sk.Shortcut
	if s == "" { return sc }
	for part in strings.split(s, "+", context.temp_allocator) {
		t := strings.to_lower(strings.trim_space(part), context.temp_allocator)
		switch t {
		case "ctrl", "control":                   sc.mods += {.Ctrl}; continue
		case "shift":                             sc.mods += {.Shift}; continue
		case "alt", "option", "opt":              sc.mods += {.Alt}; continue
		case "super", "cmd", "command", "meta", "win": sc.mods += {.Super}; continue
		}
		name := enum_ident(t)
		if len(t) == 1 && t[0] >= '0' && t[0] <= '9' { name = fmt.tprintf("N%s", t) }
		if k, ok := reflect.enum_from_name(sk.Key, name); ok { sc.key = k }
	}
	return sc
}

@(private) pdate :: proc(p: Prop) -> sk.Date {
	if !P.vset[p] { return {} }
	v := P.v[p]
	return {int(v[0]), int(v[1]), int(v[2])}
}

@(private) ptime :: proc(p: Prop) -> sk.Time {
	if !P.vset[p] { return {} }
	v := P.v[p]
	return {int(v[0]), int(v[1]), int(v[2])}
}

@(private) take_vals :: proc() -> []f32 {
	out := make([]f32, len(g_vals), context.temp_allocator)
	copy(out, g_vals[:])
	clear(&g_vals)
	return out
}

@(private) m_date :: proc(tag: i64, d: sk.Date) -> Msg {
	return {tag = tag, kind = .Date, v = {f64(d.year), f64(d.month), f64(d.day), 0}}
}
@(private) m_time :: proc(tag: i64, t: sk.Time) -> Msg {
	return {tag = tag, kind = .Time, v = {f64(t.hour), f64(t.minute), f64(t.second), 0}}
}
// Colors leave the shim as sRGB, the inverse of sk_pc, so a picked color
// round-trips through the host unchanged.
@(private) m_color :: proc(tag: i64, c: sk.Color) -> Msg {
	return {tag = tag, kind = .Color,
	        v = {f64(linear_to_srgb(c[0])), f64(linear_to_srgb(c[1])), f64(linear_to_srgb(c[2])), f64(c[3])}}
}
@(private) c_str   :: proc(v: string) -> Msg { return m_str(g_cur_tag, v) }
@(private) c_unit2 :: proc() -> Msg { return {tag = g_cur_tag2} }
@(private) c_int2  :: proc(v: int) -> Msg { return m_int(g_cur_tag2, v) }

@(private) reset_batch2 :: proc() {
	clear(&g_vals); clear(&g_menu_entries); clear(&g_menu_items); clear(&g_tree_rows)
	clear(&g_table_cols); clear(&g_spans); clear(&g_cv_cmds); clear(&g_cv_pts)
	g_menu_open = false
}

// A 4-vector prop: dates {y m d}, times {h m s}.
@(export) sk_pv :: proc "c" (key: i32, a, b, c, d: f64) {
	if !valid_prop(key) { return }
	p := Prop(key); P.v[p] = {a, b, c, d}; P.vset[p] = true; mark(p)
}

// Append one number to the series consumed by sparkline / bar_chart.
@(export) sk_val :: proc "c" (v: f64) {
	context = g_ctx
	append(&g_vals, f32(v))
}

// ---------------------------------------------------------------------------
// Widgets, batch 2: value widgets
// ---------------------------------------------------------------------------

@(export) sk_combobox :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	push(sk.combobox(g_vctx, ps(.Value), opts, ptag(.On_Change), m_str,
		id = pid(), width = pf(.Width, 0), placeholder = ps(.Placeholder),
		filter = pb(.Filter, true), free_form = pb(.Free_Form), disabled = pb(.Disabled),
		max_chars = int(pi(.Max_Chars)), max_rows = int(pi(.Max_Rows, 8))))
}

@(export) sk_date_picker :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.date_picker(g_vctx, pdate(.Value), ptag(.On_Change), m_date,
		id = pid(), width = pf(.Width, 0), placeholder = ps(.Placeholder),
		disabled = pb(.Disabled), min_date = pdate(.Min), max_date = pdate(.Max),
		week_start = penum(.Week_Start, sk.Week_Start.Locale)))
}

@(export) sk_time_picker :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.time_picker(g_vctx, ptime(.Value), ptag(.On_Change), m_time,
		id = pid(), width = pf(.Width, 0), placeholder = ps(.Placeholder),
		disabled = pb(.Disabled), minute_step = int(pi(.Minute_Step, 15)),
		second_step = int(pi(.Second_Step, 0))))
}

// The current color comes in as the `Color` prop (sRGB, converted by sk_pc).
@(export) sk_color_picker :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	val := has(.Color) ? pc(.Color) : sk.Color{1, 1, 1, 1}
	push(sk.color_picker(g_vctx, val, ptag(.On_Change), m_color,
		id = pid(), width = pf(.Width, 0), disabled = pb(.Disabled)))
}

@(export) sk_rating :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.rating(g_vctx, int(pf(.Value, 0)), ptag(.On_Change), m_int,
		id = pid(), max_value = int(pf(.Max, 5)), size = pf(.Size, 20),
		color_on = pc(.Color_On), color_off = pc(.Color_Off), disabled = pb(.Disabled)))
}

@(export) sk_radio_group :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	push(sk.radio_group(g_vctx, opts, int(pi(.Selected, -1)), ptag(.On_Change), m_int,
		id = pid(), direction = penum(.Direction, sk.Stack_Direction.Column),
		spacing = pf(.Spacing, -1), disabled = pb(.Disabled)))
}

@(export) sk_search_field :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	g_cur_tag = ptag(.On_Change)
	g_cur_tag2 = ptag(.On_Submit)
	push(sk.search_field(g_vctx, ps(.Value), c_str, c_unit2,
		id = pid(), placeholder = ps(.Placeholder), width = pf(.Width, 0),
		height = pf(.Height, 0), font_size = pf(.Font_Size, 0),
		padding = {pf(.Padding, 0), pf(.Padding, 0)},
		bg = pc(.Bg), fg = pc(.Fg), border = pc(.Border),
		invalid = pb(.Invalid), error = ps(.Error), disabled = pb(.Disabled)))
}

// on_close sends the chip's label.
@(export) sk_chip :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	g_cur_tag = ptag(.On_Close)
	push(sk.chip(g_vctx, ps(.Label), c_str,
		id = pid(), tone = ptone(.Neutral), font_size = pf(.Font_Size, 0)))
}

@(export) sk_breadcrumb :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	g_cur_tag = ptag(.On_Select)
	push(sk.breadcrumb(g_vctx, opts, c_int,
		separator = ps(.Separator, "›"), font_size = pf(.Font_Size, 0)))
}

// ---------------------------------------------------------------------------
// Widgets, batch 2: menus, tree, accordion, toast
// ---------------------------------------------------------------------------

@(private) flush_menu_entry :: proc() {
	if !g_menu_open { return }
	items := make([]sk.Menu_Item(Msg), len(g_menu_items), context.temp_allocator)
	copy(items, g_menu_items[:])
	clear(&g_menu_items)
	append(&g_menu_entries, sk.Menu_Entry(Msg){label = g_menu_label, items = items})
	g_menu_open = false
}

// Menu bar protocol: sk_menu_entry (Label) opens a top-level menu; its
// sk_menu_item / sk_menu_separator calls follow; sk_menu_bar closes the
// last menu and builds the bar.
@(export) sk_menu_entry :: proc "c" () {
	context = g_ctx
	flush_menu_entry()
	g_menu_label = ps(.Label)
	g_menu_open = true
	clear_props()
}

@(export) sk_menu_item :: proc "c" () {
	context = g_ctx
	append(&g_menu_items, sk.Menu_Item(Msg){
		label    = ps(.Label),
		shortcut = parse_shortcut(ps(.Shortcut)),
		msg      = m_unit(ptag(.On_Click)),
		disabled = pb(.Disabled),
		checked  = pb(.Checked),
	})
	clear_props()
}

@(export) sk_menu_separator :: proc "c" () {
	context = g_ctx
	append(&g_menu_items, sk.Menu_Item(Msg){separator = true, msg = m_unit(NO_TAG)})
	clear_props()
}

@(export) sk_menu_bar :: proc "c" () {
	context = g_ctx
	flush_menu_entry()
	entries := make([]sk.Menu_Entry(Msg), len(g_menu_entries), context.temp_allocator)
	copy(entries, g_menu_entries[:])
	clear(&g_menu_entries)
	if !in_view() { clear_props(); return }
	push(sk.menu_bar(g_vctx, entries, id = pid()))
}

// A popup menu: Items (sk_opt list), on_select(index), on_dismiss.
@(export) sk_menu :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	g_cur_tag = ptag(.On_Select)
	g_cur_tag2 = ptag(.On_Dismiss)
	push(sk.menu(g_vctx, opts, c_int, c_unit2, id = pid(), width = pf(.Width, 200)))
}

// Children: the view that opens the menu on right-click.
@(export) sk_context_menu :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	g_cur_tag = ptag(.On_Select)
	push(sk.context_menu(g_vctx, kid, opts, c_int,
		id = pid(), width = pf(.Width, 200),
		anchor = penum(.Anchor, sk.Context_Menu_Anchor.Cursor)))
}

@(export) sk_tree_row :: proc "c" () {
	context = g_ctx
	append(&g_tree_rows, sk.Tree_Row{
		depth = int(pi(.Depth)), label = ps(.Label), expandable = pb(.Expandable),
		expanded = pb(.Expanded), selected = pb(.Selected), icon = ps(.Icon),
	})
	clear_props()
}

// on_toggle(row) and on_select(row) index the rows given by sk_tree_row.
@(export) sk_tree :: proc "c" () {
	context = g_ctx
	rows := make([]sk.Tree_Row, len(g_tree_rows), context.temp_allocator)
	copy(rows, g_tree_rows[:])
	clear(&g_tree_rows)
	if !in_view() { clear_props(); return }
	g_cur_tag = ptag(.On_Toggle)
	g_cur_tag2 = ptag(.On_Select)
	push(sk.tree(g_vctx, rows, c_int, c_int2,
		id = pid(), row_height = pf(.Row_Height, 0), indent = pf(.Indent, 0),
		width = pf(.Width, 0)))
}

// Children: one content view per section; titles come from sk_opt.
// Active = the open section (-1 = all closed).
@(export) sk_accordion :: proc "c" () {
	context = g_ctx
	kids := take_children()
	if !in_view() { clear_props(); clear(&g_opts); return }
	titles := take_opts()
	n := min(len(kids), len(titles))
	secs := make([]sk.Accordion_Section, n, context.temp_allocator)
	for i in 0 ..< n { secs[i] = {title = titles[i], content = kids[i]} }
	g_cur_tag = ptag(.On_Toggle)
	push(sk.accordion(g_vctx, secs, int(pi(.Active, -1)), c_int,
		id = pid(), spacing = pf(.Spacing, 0), padding = pf(.Padding, -1),
		font_size = pf(.Font_Size, 0)))
}

@(export) sk_toast :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	g_cur_tag = ptag(.On_Close)
	push(sk.toast(g_vctx, pb(.Visible), ps(.Text), c_unit,
		kind = penum(.Kind, sk.Toast_Kind.Info),
		anchor = penum(.Anchor, sk.Toast_Anchor.Bottom_Center),
		id = pid(), max_width = pf(.Max_Width, 420), margin = pf(.Margin, 16),
		dismiss_after = pf(.Dismiss_After, 0)))
}

// ---------------------------------------------------------------------------
// Widgets, batch 2: display
// ---------------------------------------------------------------------------

@(export) sk_image :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.image(g_vctx, ps(.Path), width = pf(.Width, 0), height = pf(.Height, 0),
		fit = penum(.Fit, sk.Image_Fit.Cover),
		tint = has(.Tint) ? pc(.Tint) : sk.Color{1, 1, 1, 1},
		radius = pf(.Radius, 0), border = pf(.Border_Width, 0), border_color = pc(.Border)))
}

@(export) sk_avatar :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.avatar(g_vctx, ps(.Label), size = pf(.Size, 32), bg = pc(.Bg), fg = pc(.Fg)))
}

@(export) sk_stepper :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); clear(&g_opts); return }
	opts := take_opts()
	push(sk.stepper(g_vctx, opts, int(pi(.Active)), disc_size = pf(.Disc_Size, 24)))
}

@(export) sk_gauge :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	push(sk.gauge(g_vctx, pf(.Value, 0), size = pf(.Size, 64), thickness = pf(.Thickness, 0),
		color = pc(.Color), track = pc(.Track_Color), id = pid()))
}

@(export) sk_sparkline :: proc "c" () {
	context = g_ctx
	vals := take_vals()
	if !in_view() { clear_props(); return }
	push(sk.sparkline(g_vctx, vals, pf(.Width, 200), pf(.Height, 40),
		min = pf(.Min, 0), max = pf(.Max, 0), color = pc(.Color), fill = pf(.Fill, 0),
		grid = pb(.Grid), y_unit = ps(.Y_Unit), y_right = pb(.Y_Right),
		x_secs = pf(.X_Secs, 0), id = pid()))
}

@(export) sk_bar_chart :: proc "c" () {
	context = g_ctx
	vals := take_vals()
	if !in_view() { clear_props(); return }
	push(sk.bar_chart(g_vctx, vals, pf(.Width, 200), pf(.Height, 80),
		min = pf(.Min, 0), max = pf(.Max, 0), color = pc(.Color), gap = pf(.Gap, 1),
		grid = pb(.Grid), y_unit = ps(.Y_Unit), y_right = pb(.Y_Right),
		x_secs = pf(.X_Secs, 0), id = pid()))
}


// ---------------------------------------------------------------------------
// Virtual lists and tables: rows built by the host during layout
// ---------------------------------------------------------------------------

// The `state` Skald threads through a list's callbacks: the host's handle
// for the list plus the table's message tags. Row-level callbacks such as
// on_row_click get no state from Skald, so every callback that *does*
// receive it records it in g_cur_list first; Skald calls row_key /
// row_builder / is_selected for a row before that row's click handling.
Host_List :: struct {
	list:        i64,
	has_key:     bool,
	on_click:    i64,
	on_activate: i64,
	on_sort:     i64,
	on_resize:   i64,
	on_context:  i64,
	on_select:   i64,
}

g_cur_list:     Host_List
g_table_cols:   [dynamic]sk.Table_Column

// Re-enter the host to build one row. Runs during render: install the
// row's Skald context, give the host a fresh stack segment and property
// register, and restore everything afterwards.
@(private) host_row :: proc(ctx: ^sk.Ctx(Msg), st: Host_List, index: int) -> []sk.View {
	g_cur_list = st
	if g_list_fn == nil { return nil }
	saved_ctx, saved_vctx, saved_P := g_ctx, g_vctx, P
	g_ctx = context
	g_vctx = ctx
	clear_props()
	append(&g_marks, len(g_stack))
	g_list_fn(st.list, i64(index), 0)
	kids := take_children()
	g_ctx, g_vctx, P = saved_ctx, saved_vctx, saved_P
	return kids
}

@(private) vl_row :: proc(ctx: ^sk.Ctx(Msg), st: Host_List, index: int) -> sk.View {
	return one_child(host_row(ctx, st, index))
}

@(private) tbl_row :: proc(ctx: ^sk.Ctx(Msg), st: Host_List, index: int) -> []sk.View {
	return host_row(ctx, st, index)
}

@(private) list_key :: proc(st: Host_List, index: int) -> u64 {
	g_cur_list = st
	if !st.has_key || g_list_fn == nil { return u64(index) }
	return transmute(u64)g_list_fn(st.list, i64(index), 1)
}

@(private) list_selected :: proc(st: Host_List, index: int) -> bool {
	g_cur_list = st
	if g_list_fn == nil { return false }
	return g_list_fn(st.list, i64(index), 2) != 0
}

// on_select (if set) wins over on_click: it also carries the modifiers, so
// the host can do Shift-range / Ctrl-toggle multi-select.
@(private) t_click    :: proc(row: int, mods: sk.Modifiers) -> Msg {
	if g_cur_list.on_select == NO_TAG { return m_int(g_cur_list.on_click, row) }
	return {tag = g_cur_list.on_select, kind = .Row, i = i64(row), v = {f64(mod_bits(mods)), 0, 0, 0}}
}

@(private) mod_bits :: proc(mods: sk.Modifiers) -> u32 {
	bits: u32
	for m in mods { bits |= 1 << u32(m) }
	return bits
}
@(private) t_activate :: proc(row: int) -> Msg { return m_int(g_cur_list.on_activate, row) }
@(private) t_context  :: proc(row: int) -> Msg { return m_int(g_cur_list.on_context, row) }
@(private) t_sort     :: proc(col: int, asc: bool) -> Msg {
	return {tag = g_cur_list.on_sort, kind = .Sort, v = {f64(col), asc ? 1 : 0, 0, 0}}
}
@(private) t_resize   :: proc(col: int, w: f32) -> Msg {
	return {tag = g_cur_list.on_resize, kind = .Size, v = {f64(col), f64(w), 0, 0}}
}

@(private) host_list_state :: proc() -> Host_List {
	return {
		list = pi(.Handle), has_key = pb(.Has_Key),
		on_click = ptag(.On_Click), on_activate = ptag(.On_Activate),
		on_sort = ptag(.On_Sort), on_resize = ptag(.On_Resize), on_context = ptag(.On_Context),
		on_select = ptag(.On_Row_Select),
	}
}

// Handle = the host's list id; Count rows of Row_Height in a Width×Height
// viewport.
@(export) sk_virtual_list :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	st := host_list_state()
	g_cur_list = st
	push(sk.virtual_list(g_vctx, st, int(pi(.Count)), pf(.Row_Height, 28),
		{pf(.Width, 300), pf(.Height, 300)}, vl_row, list_key,
		id = pid(), wheel_step = pf(.Wheel_Step, 40),
		track_color = pc(.Track_Color), thumb_color = pc(.Thumb_Color),
		focusable = pb(.Focusable), reveal_row = int(pi(.Reveal_Row, -1))))
}

// One column for the next sk_table: Label, Width (0 = flex by Weight),
// Align, Sortable, Resizable.
@(export) sk_table_column :: proc "c" () {
	context = g_ctx
	append(&g_table_cols, sk.Table_Column{
		label = ps(.Label), width = pf(.Width, 0), flex = pf(.Weight, 1),
		align = pcross(.Align), sortable = pb(.Sortable), resizable = pb(.Resizable),
	})
	clear_props()
}

@(export) sk_table :: proc "c" () {
	context = g_ctx
	cols := make([]sk.Table_Column, len(g_table_cols), context.temp_allocator)
	copy(cols, g_table_cols[:])
	clear(&g_table_cols); clear(&g_spans); clear(&g_cv_cmds); clear(&g_cv_pts)
	if !in_view() { clear_props(); return }
	st := host_list_state()
	g_cur_list = st // header sort/resize and keyboard nav fire during this call
	ctxf: proc(int) -> Msg = st.on_context != NO_TAG ? t_context : nil
	push(sk.table(g_vctx, st, cols, int(pi(.Count)), pf(.Row_Height, 28),
		{pf(.Width, 600), pf(.Height, 300)}, tbl_row, list_key,
		t_click, list_selected, t_sort, t_resize, t_activate,
		sort_column = int(pi(.Sort_Column, -1)), sort_ascending = pb(.Ascending, true),
		focus_row = int(pi(.Focus_Row, -1)), reveal_row = int(pi(.Reveal_Row, -1)), id = pid(),
		header_height = pf(.Header_Height, 32), on_row_context = ctxf))
}


// ---------------------------------------------------------------------------
// Rich text
// ---------------------------------------------------------------------------

g_spans: [dynamic]sk.Text_Span

// One span for the next sk_rich_text: Text, Color, Size, Bold, Italic,
// Underline, Strike, Bg, Link.
@(export) sk_span :: proc "c" () {
	context = g_ctx
	append(&g_spans, sk.Text_Span{
		str = ps(.Text), color = pc(.Color), size = pf(.Size, 0),
		weight = pb(.Bold) ? .Bold : .Regular, italic = pb(.Italic),
		bg = pc(.Bg), underline = pb(.Underline) || has(.Link), strike = pb(.Strike),
		link = ps(.Link),
	})
	clear_props()
}

// On_Link (if set) gets the clicked span's link target.
@(export) sk_rich_text :: proc "c" () {
	context = g_ctx
	spans := make([]sk.Text_Span, len(g_spans), context.temp_allocator)
	copy(spans, g_spans[:])
	clear(&g_spans)
	if !in_view() { clear_props(); return }
	base := has(.Color) ? pc(.Color) : g_vctx.theme.color.fg
	size := pf(.Size, g_vctx.theme.font.size_md)
	mw := pf(.Max_Width, 0)
	tag := ptag(.On_Link)
	g_cur_tag = tag
	switch {
	case pb(.Selectable) && tag != NO_TAG:
		push(sk.rich_text_selectable_links(g_vctx, spans, base, c_str, size = size, max_width = mw, id = pid()))
	case pb(.Selectable):
		push(sk.rich_text_selectable(g_vctx, spans, base, size = size, max_width = mw, id = pid()))
	case tag != NO_TAG:
		push(sk.rich_text_links(g_vctx, spans, base, c_str, size = size, max_width = mw, id = pid()))
	case:
		push(sk.rich_text(g_vctx, spans, base, size = size, max_width = mw, id = pid()))
	}
}

// ---------------------------------------------------------------------------
// Canvas: a display list recorded during the view, replayed at render
// ---------------------------------------------------------------------------

Canvas_Op :: enum i32 {
	Rect, Rect_Outline, Line, Circle, Ring, Arc, Bezier, Polyline, Polygon, Text,
}

Canvas_Cmd :: struct {
	op:    Canvas_Op,
	color: sk.Color,
	a:     [9]f32,
	pts:   [][2]f32,
	text:  string,
}

g_cv_cmds: [dynamic]Canvas_Cmd
g_cv_pts:  [dynamic][2]f32
g_cv_drag: map[sk.Widget_ID][2]f32 // canvases with a press in progress -> last pos

@(private) srgb_color :: proc(r, g, b, a: f64) -> sk.Color {
	return {sk.srgb_to_linear(f32(r)), sk.srgb_to_linear(f32(g)), sk.srgb_to_linear(f32(b)), f32(a)}
}

// A path point for the next Polyline / Polygon command.
@(export) sk_cv_point :: proc "c" (x, y: f64) {
	context = g_ctx
	append(&g_cv_pts, [2]f32{f32(x), f32(y)})
}

// One drawing command (canvas-local coordinates; color sRGB):
//   Rect x y w h radius · Rect_Outline x y w h width radius · Line x1 y1 x2 y2 width
//   Circle cx cy r · Ring cx cy r width · Arc cx cy r a0 a1 width (radians)
//   Bezier x0 y0 x1 y1 x2 y2 x3 y3 width · Polyline width · Polygon
@(export) sk_cv :: proc "c" (op: i32, a0, a1, a2, a3, a4, a5, a6, a7, a8: f64, r, g, b, a: f64) {
	context = g_ctx
	cmd := Canvas_Cmd{op = Canvas_Op(op), color = srgb_color(r, g, b, a),
	                  a = {f32(a0), f32(a1), f32(a2), f32(a3), f32(a4), f32(a5), f32(a6), f32(a7), f32(a8)}}
	if cmd.op == .Polyline || cmd.op == .Polygon {
		cmd.pts = make([][2]f32, len(g_cv_pts), context.temp_allocator)
		copy(cmd.pts, g_cv_pts[:])
		clear(&g_cv_pts)
	}
	append(&g_cv_cmds, cmd)
}

@(export) sk_cv_text :: proc "c" (x, y, size: f64, s: cstring, r, g, b, a: f64) {
	context = g_ctx
	append(&g_cv_cmds, Canvas_Cmd{op = .Text, color = srgb_color(r, g, b, a),
	                              a = {f32(x), f32(y), f32(size), 0, 0, 0, 0, 0, 0}, text = tmp_str(s)})
}

@(private) canvas_draw :: proc(cmds: ^[]Canvas_Cmd, painter: sk.Canvas_Painter) {
	r := painter.r
	o := [2]f32{painter.bounds.x, painter.bounds.y}
	for c in cmds^ {
		a := c.a
		switch c.op {
		case .Rect:         sk.draw_rect(r, {o.x + a[0], o.y + a[1], a[2], a[3]}, c.color, a[4])
		case .Rect_Outline: sk.draw_rect_outline(r, {o.x + a[0], o.y + a[1], a[2], a[3]}, a[4], c.color, a[5], true)
		case .Line:         sk.draw_line(r, o + {a[0], a[1]}, o + {a[2], a[3]}, a[4], c.color, true)
		case .Circle:       sk.draw_circle(r, o + {a[0], a[1]}, a[2], c.color, true)
		case .Ring:         sk.draw_ring(r, o + {a[0], a[1]}, a[2], a[3], c.color, true)
		case .Arc:          sk.draw_arc(r, o + {a[0], a[1]}, a[2], a[3], a[4], a[5], c.color, true)
		case .Bezier:
			sk.draw_bezier(r, o + {a[0], a[1]}, o + {a[2], a[3]}, o + {a[4], a[5]}, o + {a[6], a[7]},
			               a[8], c.color, true)
		case .Polyline, .Polygon:
			pts := make([][2]f32, len(c.pts), context.temp_allocator)
			for p, i in c.pts { pts[i] = o + p }
			if c.op == .Polyline { sk.draw_polyline(r, pts, a[0], c.color, true) }
			else                 { sk.draw_polygon(r, pts, c.color, true) }
		case .Text:         sk.draw_text(r, c.text, o.x + a[0], o.y + a[1], c.color, a[2])
		}
	}
}

// Width × Height canvas drawing the commands recorded since the last
// canvas. On_Press / On_Drag / On_Release get canvas-local {x, y}.
@(export) sk_canvas :: proc "c" () {
	context = g_ctx
	cmds := new([]Canvas_Cmd, context.temp_allocator)
	cmds^ = make([]Canvas_Cmd, len(g_cv_cmds), context.temp_allocator)
	copy(cmds^, g_cv_cmds[:])
	clear(&g_cv_cmds)
	clear(&g_cv_pts)
	if !in_view() { clear_props(); return }
	ctx := g_vctx
	// resolve the id up front (as canvas() would) so we can read the rect
	// Skald recorded for it last frame
	rid := pid()
	if rid == 0 { rid = sk.widget_auto_id(ctx) }

	// pointer: press inside starts a stroke; drag while held; release ends it
	st := sk.widget_get(ctx, rid, .Canvas)
	rect := st.last_rect
	mp := ctx.input.mouse_pos
	local := [2]f32{mp.x - rect.x, mp.y - rect.y}
	inside := rect.w > 0 && mp.x >= rect.x && mp.y >= rect.y && mp.x < rect.x + rect.w && mp.y < rect.y + rect.h
	if g_cv_drag == nil { g_cv_drag = make(map[sk.Widget_ID][2]f32, 8, runtime.heap_allocator()) }
	point :: proc(tag: i64, p: [2]f32) -> Msg { return {tag = tag, kind = .Point, v = {f64(p.x), f64(p.y), 0, 0}} }
	if last, held := g_cv_drag[rid]; held {
		if !ctx.input.mouse_buttons[.Left] {
			delete_key(&g_cv_drag, rid)
			if t := ptag(.On_Release); t != NO_TAG { sk.send(ctx, point(t, local)) }
		} else if local != last {
			g_cv_drag[rid] = local
			if t := ptag(.On_Drag); t != NO_TAG { sk.send(ctx, point(t, local)) }
		}
	} else if inside && ctx.input.mouse_pressed[.Left] {
		g_cv_drag[rid] = local
		if t := ptag(.On_Press); t != NO_TAG { sk.send(ctx, point(t, local)) }
	}

	push(sk.canvas(ctx, cmds, canvas_draw, id = rid,
		width = pf(.Width, 0), height = pf(.Height, 0),
		cursor = penum(.Cursor, sk.Cursor_Shape.Default)))
}

// ---------------------------------------------------------------------------
// Drag and drop
// ---------------------------------------------------------------------------

// Children: [child] or [child, drag_visual]. Kind + Handle (payload id).
@(export) sk_drag_source :: proc "c" () {
	context = g_ctx
	kids := take_children()
	if !in_view() { clear_props(); return }
	child := len(kids) > 0 ? kids[0] : sk.spacer(0)
	visual := len(kids) > 1 ? kids[1] : child
	push(sk.drag_source(g_vctx, child, sk.Drag_Payload{kind = ps(.Kind), id = transmute(u64)pi(.Handle)},
		visual, id = pid()))
}

@(private) c_drop :: proc(p: sk.Drag_Payload) -> Msg {
	return {tag = g_cur_tag, kind = .Drop, i = transmute(i64)p.id,
	        s = strings.clone(p.kind, context.temp_allocator)}
}

@(export) sk_drop_target :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	if !in_view() { clear_props(); return }
	g_cur_tag = ptag(.On_Drop)
	push(sk.drop_target(g_vctx, kid, c_drop, id = pid(), accepts = ps(.Accepts)))
}

@(private) c_files :: proc(files: []string) -> Msg {
	return {tag = g_cur_tag, kind = .Files, s = strings.join(files, "\n", context.temp_allocator)}
}

// Files dropped from the OS onto the child.
@(export) sk_drop_zone :: proc "c" () {
	context = g_ctx
	kid := one_child(take_children())
	if !in_view() { clear_props(); return }
	g_cur_tag = ptag(.On_Drop)
	push(sk.drop_zone(g_vctx, kid, c_files, id = pid()))
}

// The payload id of the drag in progress, or -1. (`kind` not needed by the
// host: it looks the value up by id.)
@(export) sk_dragging :: proc "c" () -> i64 {
	if g_vctx == nil { return -1 }
	context = g_ctx
	_, id, active := sk.dragging_payload(g_vctx)
	return active ? transmute(i64)id : -1
}

// Is a drag (of kind `accepts`, if given) over the widget with string id?
@(export) sk_drag_over :: proc "c" (key: cstring, accepts: cstring) -> i32 {
	if g_vctx == nil { return 0 }
	context = g_ctx
	return sk.drag_target_hot(g_vctx, sk.hash_id(tmp_str(key)), tmp_str(accepts)) ? 1 : 0
}

// ---------------------------------------------------------------------------
// Split panes, grid, variable-height list
// ---------------------------------------------------------------------------

@(private) c_f32 :: proc(v: f32) -> Msg { return m_f32(g_cur_tag, v) }

// Children: [first, second]. First_Size in px; On_Resize gets the new size.
@(export) sk_split :: proc "c" () {
	context = g_ctx
	kids := take_children()
	if !in_view() { clear_props(); return }
	first  := len(kids) > 0 ? kids[0] : sk.spacer(0)
	second := len(kids) > 1 ? kids[1] : sk.spacer(0)
	g_cur_tag = ptag(.On_Resize)
	push(sk.split(g_vctx, first, second, pf(.First_Size, 200), c_f32,
		id = pid(), direction = penum(.Direction, sk.Stack_Direction.Row),
		divider_thickness = pf(.Divider_Thickness, 6),
		min_first = pf(.Min_First, 40), min_second = pf(.Min_Second, 40),
		color_divider = pc(.Color)))
}

// Column widths from sk_val (0 = flex); children fill row-major.
@(export) sk_grid :: proc "c" () {
	context = g_ctx
	kids := take_children()
	cols := take_vals()
	if !in_view() { clear_props(); return }
	if len(cols) == 0 { cols = []f32{0} }
	sx := pf(.Spacing_X, pf(.Spacing, 0))
	pad := pf(.Padding, 0)
	// Without a width, Skald's grid sizes itself from the width its parent
	// offers — zero inside a start-aligned column. When every column is
	// fixed, its natural width is known: use it.
	width := pf(.Width, 0)
	if width <= 0 {
		all_fixed := true
		sum: f32
		for c in cols { if c <= 0 { all_fixed = false }; sum += c }
		if all_fixed { width = sum + sx * f32(len(cols) - 1) + 2 * pad }
	}
	push(sk.grid(g_vctx, cols, ..kids,
		spacing_x = sx, spacing_y = pf(.Spacing_Y, pf(.Spacing, 0)),
		padding = pad, width = width, bg = pc(.Bg), radius = pf(.Radius, 0)))
}

@(export) sk_virtual_list_variable :: proc "c" () {
	context = g_ctx
	if !in_view() { clear_props(); return }
	st := host_list_state()
	g_cur_list = st
	// rows measure themselves; Estimated_Height sizes the scrollbar until
	// they have been seen
	push(sk.virtual_list(g_vctx, st, int(pi(.Count)), pf(.Estimated_Height, 32),
		{pf(.Width, 300), pf(.Height, 300)}, vl_row, list_key,
		id = pid(), wheel_step = pf(.Wheel_Step, 40),
		track_color = pc(.Track_Color), thumb_color = pc(.Thumb_Color),
		variable_height = true, estimated_height = pf(.Estimated_Height, 0),
		focusable = pb(.Focusable), reveal_row = int(pi(.Reveal_Row, -1))))
}

// ---------------------------------------------------------------------------
// Custom themes
// ---------------------------------------------------------------------------

g_theme: sk.Theme

// kebab-case -> snake_case field name
@(private) field_ident :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "-", "_", context.temp_allocator)
	return out
}

@(private) set_field :: proc(base: rawptr, T: typeid, name: string, val: rawptr, size: int) -> bool {
	f := reflect.struct_field_by_name(T, field_ident(name))
	if f.type == nil || f.type.size != size { return false }
	mem.copy(rawptr(uintptr(base) + f.offset), val, size)
	return true
}

// Start a custom theme from a base (0 dark, 1 light, 2 OS).
@(export) sk_theme_begin :: proc "c" (base: i32) {
	context = runtime.default_context()
	g_theme = theme_for(base)
}

// A theme color by field name ("primary", "fg-muted"…), sRGB. 0 = unknown.
@(export) sk_theme_set_color :: proc "c" (name: cstring, r, g, b, a: f64) -> i32 {
	context = runtime.default_context()
	c := srgb_color(r, g, b, a)
	return set_field(&g_theme.color, sk.Theme_Colors, string(name), &c, size_of(sk.Color)) ? 1 : 0
}

// A theme number: group "spacing" | "radius" | "font", field "md", "size-lg"…
@(export) sk_theme_set_num :: proc "c" (group, name: cstring, v: f64) -> i32 {
	context = runtime.default_context()
	x := f32(v)
	ok: bool
	switch string(group) {
	case "spacing": ok = set_field(&g_theme.spacing, sk.Theme_Spacing, string(name), &x, size_of(f32))
	case "radius":  ok = set_field(&g_theme.radius, sk.Theme_Radii, string(name), &x, size_of(f32))
	case "font":    ok = set_field(&g_theme.font, sk.Theme_Font, string(name), &x, size_of(f32))
	}
	return ok ? 1 : 0
}

// ---------------------------------------------------------------------------
// Multiple windows
// ---------------------------------------------------------------------------

Win_Pending :: struct { open_tag, close_tag: i64 }

g_win_pending: [dynamic]Win_Pending       // opens in flight, in order
g_win_close:   map[sk.Window_Id]i64        // window -> close tag

@(private) win_id :: proc(id: sk.Window_Id) -> i64 { return i64(uintptr(rawptr(id))) }

@(private) w_result :: proc(id: sk.Window_Id) -> Msg {
	if len(g_win_pending) == 0 { return {tag = NO_TAG} }
	p := pop_front(&g_win_pending)
	if g_win_close == nil { g_win_close = make(map[sk.Window_Id]i64, 8, runtime.heap_allocator()) }
	g_win_close[id] = p.close_tag
	return {tag = p.open_tag, kind = .Int, i = win_id(id)}
}

@(private) w_close :: proc(id: sk.Window_Id) -> Msg {
	tag, ok := g_win_close[id]
	if !ok { return {tag = NO_TAG} }
	delete_key(&g_win_close, id)
	return {tag = tag, kind = .Int, i = win_id(id)}
}

// Open a window. open_tag gets its id once it exists; close_tag fires when
// it closes. Its content is the view the host renders for that id.
@(export) sk_cmd_open_window :: proc "c" (title: cstring, w, h: i32, open_tag, close_tag: i64) {
	context = g_ctx
	if !g_in_update { return }
	if g_win_pending.allocator.procedure == nil { g_win_pending.allocator = runtime.heap_allocator() }
	append(&g_win_pending, Win_Pending{open_tag, close_tag})
	desc := sk.Window_Desc{title = strings.clone_from_cstring(title, context.temp_allocator), size = {w, h}}
	append(&g_cmds, sk.cmd_open_window(desc, w_result, w_close))
}

@(export) sk_cmd_close_window :: proc "c" (id: i64) {
	context = g_ctx
	if !g_in_update { return }
	append(&g_cmds, sk.cmd_close_window(Msg, sk.Window_Id(rawptr(uintptr(id)))))
}

// ---------------------------------------------------------------------------
// Commands (call from inside the update callback)
// ---------------------------------------------------------------------------

@(export) sk_cmd_now :: proc "c" (tag: i64) {
	context = g_ctx
	if !g_in_update { return }
	append(&g_cmds, sk.cmd_now(Msg{tag = tag}))
}

@(export) sk_cmd_delay :: proc "c" (seconds: f64, tag: i64) {
	context = g_ctx
	if !g_in_update { return }
	append(&g_cmds, sk.cmd_delay(f32(seconds), Msg{tag = tag}))
}

// File dialogs. Stage filters with sk_dialog_filter, then call
// sk_cmd_file_dialog. kind: 0 open file, 1 save file, 2 open folder.
// location "" = the user's home. The result arrives on `tag` as .Path.
g_dialog_filters: [dynamic]sk.File_Filter
// ponytail: Skald's result callback can't carry the tag, so tags queue in
// open order. Right while one dialog is open at a time (the OS pickers are
// modal); two dialogs closed out of order would swap results.
g_dialog_tags: [dynamic]i64

@(export) sk_dialog_filter :: proc "c" (name, pattern: cstring) {
	context = g_ctx
	// temp memory is enough: Skald copies filters when it starts the dialog
	append(&g_dialog_filters, sk.File_Filter{
		name = strings.clone_from_cstring(name, context.temp_allocator),
		pattern = strings.clone_from_cstring(pattern, context.temp_allocator)})
}

@(private) dialog_result :: proc(r: sk.File_Dialog_Result) -> Msg {
	tag := NO_TAG
	if len(g_dialog_tags) > 0 { tag = pop_front(&g_dialog_tags) }
	if tag == NO_TAG { delete(r.path); return {tag = NO_TAG} }
	return {tag = tag, kind = .Path, s = r.path, i = r.cancelled ? 1 : 0}
}

@(export) sk_cmd_file_dialog :: proc "c" (kind: i32, location: cstring, tag: i64) {
	context = g_ctx
	filters := make([]sk.File_Filter, len(g_dialog_filters), context.temp_allocator)
	copy(filters, g_dialog_filters[:])
	clear(&g_dialog_filters)
	if !g_in_update { return }
	if g_dialog_tags.allocator.procedure == nil { g_dialog_tags.allocator = runtime.heap_allocator() }
	append(&g_dialog_tags, tag)
	loc := strings.clone_from_cstring(location, context.temp_allocator)
	switch kind {
	case 1:  append(&g_cmds, sk.cmd_save_file_dialog(filters, dialog_result, loc))
	case 2:  append(&g_cmds, sk.cmd_open_folder_dialog(dialog_result, loc))
	case:    append(&g_cmds, sk.cmd_open_file_dialog(filters, dialog_result, loc))
	}
}

@(export) sk_cmd_quit :: proc "c" () {
	context = g_ctx
	if !g_in_update { return }
	begin_closing()
	append(&g_cmds, sk.cmd_quit(Msg))
}

// 0 = dark, 1 = light, 2 = follow the OS from now on.
@(export) sk_cmd_set_theme :: proc "c" (which: i32) {
	context = g_ctx
	if !g_in_update { return }
	g_follow_theme = which == 2
	append(&g_cmds, sk.cmd_set_theme(Msg, theme_for(which)))
}

// 0 dark, 1 light, 2 OS, 3 the custom theme staged with sk_theme_begin/set_*
@(private) theme_for :: proc(which: i32) -> sk.Theme {
	switch which {
	case 1: return sk.theme_light()
	case 2: return sk.theme_system()
	case 3: return g_theme
	}
	return sk.theme_dark()
}

// ---------------------------------------------------------------------------
// Mailbox — any-thread message delivery
// ---------------------------------------------------------------------------

// Post a persistent host tag from any thread. Delivered to update on the UI
// thread at the next frame; wakes an idle UI. Safe before sk_run (queued).
@(export) sk_post :: proc "c" (tag: i64) {
	context = runtime.default_context()
	sync.mutex_lock(&g_mbox_lock)
	if g_mbox.allocator.procedure == nil { g_mbox.allocator = runtime.heap_allocator() }
	append(&g_mbox, tag)
	sync.mutex_unlock(&g_mbox_lock)
	sync.sema_post(&g_mbox_sema)
}

@(private) pump_work :: proc() -> Msg {
	sync.sema_wait(&g_mbox_sema)
	if sync.atomic_load(&g_closing) { return {tag = NO_TAG} }
	return {tag = PUMP_TAG}
}

@(private) begin_closing :: proc() {
	if sync.atomic_exchange(&g_closing, true) { return }
	// Release the worker so Skald's shutdown (which waits for in-flight
	// cmd_thread jobs) can finish.
	sync.sema_post(&g_mbox_sema)
}

@(private) drain_mailbox :: proc() -> []i64 {
	sync.mutex_lock(&g_mbox_lock)
	defer sync.mutex_unlock(&g_mbox_lock)
	out := make([]i64, len(g_mbox), context.temp_allocator)
	copy(out, g_mbox[:])
	clear(&g_mbox)
	return out
}

// ---------------------------------------------------------------------------
// App wiring
// ---------------------------------------------------------------------------

@(private) app_init :: proc() -> State { return {} }

@(private) call_host_update :: proc(m: Msg) {
	cs: cstring
	if m.kind == .Str || m.kind == .Path { cs = strings.clone_to_cstring(m.s, context.temp_allocator) }
	g_update(m.tag, i32(m.kind), m.i, m.f, cs, m.v[0], m.v[1], m.v[2], m.v[3])
}

@(private) app_update :: proc(s: State, m: Msg) -> (State, sk.Command(Msg)) {
	if m.tag == NO_TAG { return s, {} }

	g_ctx = context
	g_in_update = true
	g_updated = true
	clear(&g_cmds)

	rearm := false
	switch m.tag {
	case PUMP_TAG:
		for t in drain_mailbox() { call_host_update({tag = t}) }
		rearm = true
	case CLOSE_TAG:
		if g_close_tag != NO_TAG {
			call_host_update({tag = g_close_tag})
		} else {
			begin_closing()
			append(&g_cmds, sk.cmd_quit(Msg))
		}
	case THEME_TAG:
		if g_follow_theme { append(&g_cmds, sk.cmd_set_theme(Msg, sk.theme_system())) }
	case:
		call_host_update(m)
		if m.kind == .Path { delete(m.s) } // Skald hands dialog paths over to us
	}

	if rearm && !sync.atomic_load(&g_closing) {
		append(&g_cmds, sk.cmd_thread_simple(Msg, pump_work))
	}
	g_in_update = false

	cmd: sk.Command(Msg)
	switch len(g_cmds) {
	case 0:
	case 1: cmd = g_cmds[0]
	case:   cmd = sk.cmd_batch(g_cmds[0], ..g_cmds[1:])
	}
	return State{gen = s.gen + 1}, cmd
}

@(private) app_view :: proc(s: State, ctx: ^sk.Ctx(Msg)) -> sk.View {
	g_ctx = context
	g_vctx = ctx
	defer g_vctx = nil

	// Arm the mailbox worker on the first frame (it needs an update to
	// return its command, so we route through a msg).
	if !g_pump_armed {
		g_pump_armed = true
		sk.send(ctx, Msg{tag = PUMP_TAG})
	}

	// The host's per-frame tag table is valid until all msgs emitted by this
	// frame's views have been through update. A new frame is detected by an
	// intervening update or by seeing the same window twice.
	wid := i64(uintptr(rawptr(ctx.window)))
	reset := g_updated
	for w in g_rendered { if w == wid { reset = true } }
	if reset { clear(&g_rendered); g_updated = false }
	append(&g_rendered, wid)

	clear(&g_stack)
	clear(&g_marks)
	clear(&g_opts)
	clear(&g_scopes)
	reset_batch2()
	clear_props()

	g_view(wid, reset ? 1 : 0)

	// Unbalanced scope pushes would corrupt the next frame's auto-IDs.
	for len(g_scopes) > 0 { sk.widget_scope_pop(ctx, pop(&g_scopes)) }

	switch len(g_stack) {
	case 0: return sk.spacer(0)
	case 1: return g_stack[0]
	}
	kids := make([]sk.View, len(g_stack), context.temp_allocator)
	copy(kids, g_stack[:])
	return sk.col(..kids)
}

@(private) app_close_request :: proc() -> Msg { return {tag = CLOSE_TAG} }

// Every key press / release (OS auto-repeat included), except while a text
// field has focus: Skald keeps SDL text-input mode on for the focused window
// exactly then, so typing never doubles as app keys. Shortcuts still fire.
g_key_tag: i64 = NO_TAG

// Persistent host tag for key events, or -1 for none. Call before sk_run.
@(export) sk_on_key :: proc "c" (tag: i64) { g_key_tag = tag }

@(private) app_key :: proc(ev: sk.Key_Event) -> Msg {
	if w := sdl3.GetKeyboardFocus(); w != nil && sdl3.TextInputActive(w) { return {tag = NO_TAG} }
	return {tag = g_key_tag, kind = .Key, i = i64(ev.key),
	        v = {f64(mod_bits(ev.mods)), ev.pressed ? 1 : 0, 0, 0}}
}

// A global shortcut while it is in the view: Keys ("Ctrl+K") fires On_Press.
// Pushes no view. Modifiers match exactly, as with menu shortcuts.
@(export) sk_shortcut :: proc "c" () {
	context = g_ctx
	if in_view() && has(.On_Press) {
		sk.shortcut(g_vctx, parse_shortcut(ps(.Keys)), Msg{tag = ptag(.On_Press)})
	}
	clear_props()
}
@(private) app_theme_change :: proc(t: sk.System_Theme) -> Msg { return {tag = THEME_TAG, i = i64(t)} }

// Run the app. Blocks until the window closes. Returns 0.
//   theme:      0 = dark, 1 = light, 2 = follow the OS
//   close_tag:  persistent host tag delivered instead of closing when the
//               user clicks the window's close button, or -1 to just close.
//   flags bit0: always_redraw
@(export) sk_run :: proc "c" (title: cstring, w, h: i32, theme: i32,
                              update: Update_Fn, view: View_Fn, list_fn: List_Fn,
                              close_tag: i64, flags: i32) -> i32 {
	context = runtime.default_context()

	g_update = update
	g_view = view
	g_list_fn = list_fn
	g_close_tag = close_tag
	g_follow_theme = theme == 2
	sync.atomic_store(&g_closing, false)
	g_pump_armed = false
	g_rendered = make([dynamic]i64)
	g_stack = make([dynamic]sk.View, 0, 256)
	g_marks = make([dynamic]int, 0, 64)
	g_opts = make([dynamic]string, 0, 16)
	g_scopes = make([dynamic]sk.Widget_Scope_Saved, 0, 16)
	g_cmds = make([dynamic]sk.Command(Msg), 0, 8)

	t := strings.clone_from_cstring(title)
	defer delete(t)

	sk.run(sk.App(State, Msg){
		title                  = t,
		size                   = {w, h},
		theme                  = theme_for(theme),
		init                   = app_init,
		update                 = app_update,
		view                   = app_view,
		on_close_request       = app_close_request,
		on_system_theme_change = app_theme_change,
		on_key                 = g_key_tag != NO_TAG ? app_key : nil,
		always_redraw          = flags & 1 != 0,
	})

	delete(g_rendered); delete(g_stack); delete(g_marks)
	delete(g_opts); delete(g_scopes); delete(g_cmds)
	g_update = nil
	g_view = nil
	g_list_fn = nil
	g_key_tag = NO_TAG
	clear(&g_dialog_tags)
	return 0
}
