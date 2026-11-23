//! Module "Window": a native window to draw into with Instanced2D, with one
//! interface on every platform. Event driven: `waitEvents` blocks in the OS
//! until input, a `wake()` from another thread, or the caller's deadline;
//! nothing here ticks at a fixed rate (the one exception is Win32's 16 ms
//! timer while the user drags the window border, because Windows then runs
//! its own modal loop and only a timer lets the app redraw during it).
//!
//!     const win = try Window.init(gpa, "Title", 800, 600);   // logical size
//!     defer win.deinit();
//!     const r = try Instanced2D.init(gpa, win.surfaceSource(), fb[0], fb[1], .{ .vertex_spirv = &vert, .fragment_spirv = &frag });
//!     while (true) {
//!         while (win.pollEvent()) |e| switch (e) { .close => return, else => {} };
//!         // draw
//!         win.waitEvents(Window.forever);
//!     }
//!
//! Interface (checked at compile time for every backend by `checkInterface`):
//!
//!   init(gpa, title, width, height) !*Window   logical size, scaled by DPI
//!   deinit()
//!   setLiveCallback(ctx, fn)        redraw hook while the OS runs a modal
//!                                   resize loop (Win32 border drag, macOS
//!                                   live resize); may never fire elsewhere
//!   pollEvent() ?Event              non-blocking; pumps the OS queue
//!   pollQueued() ?Event             queued events only, no OS pumping (safe
//!                                   inside the live callback)
//!   waitEvents(timeout_ms)          sleep until input, wake() or timeout;
//!                                   `forever` = no timeout
//!   wake()                          any thread; coalesced; ends a waitEvents
//!   framebufferSize() [2]u32        pixels
//!   scale() f32                     1.0 = 96 dpi (Windows) / 1x (Wayland,
//!                                   macOS points)
//!   surfaceSource() Instanced2D.SurfaceSource
//!   setTitle(utf8)
//!   hide()                          unmap the window (shutdown in progress)
//!   clipboardText(gpa, max_units) ?[]u8   UTF-8, at most max_units UTF-16
//!                                   units, invalid sequences -> U+FFFD;
//!                                   caller frees
//!   setClipboardText(utf8) bool
//!   insets() Insets                 pixels at the edges the UI must keep
//!                                   clear: safe area (notch, home
//!                                   indicator) and the on-screen keyboard;
//!                                   on Wayland the strip under the
//!                                   backend's own title bar (top);
//!                                   otherwise zero on desktops
//!   showTextInput(TextField) bool   place the OS's own text field over the
//!                                   UI's input slot (iOS: a UITextView, so
//!                                   the keyboard, autocorrect and dictation
//!                                   work); false where keys and text arrive
//!                                   as .key / .char events instead
//!   hideTextInput()
//!   textInputText(buf) []const u8   the native field's current text (UTF-8)
//!   setTextInputText(utf8)          replace it (e.g. clear after a send)
//!
//! Module-level: `runApp(options, entry, ctx)` runs the app's main loop.
//! Desktop backends call `entry` on the calling thread. On iOS
//! UIApplicationMain takes over the main thread and never returns, so
//! `entry` runs on an app thread started once the scene's window exists;
//! the same `while (pollEvent) ... waitEvents` loop runs there unchanged
//! (see ios.zig, "Inverted control"). Events only some platforms produce:
//! `.insets`, `.background` / `.foreground`, `.text_input`, `.media` and
//! `.posture` (Win32 only so far), and `mouse_up.cancelled` (iOS, Win32
//! touch). On iOS and on a Windows touch screen one finger is the
//! pointer: mouse_down where it lands, mouse_move while it moves, mouse_up
//! where it lifts, each with `source` .touch (Win32 pens: .pen; a mouse or
//! trackpad: .mouse); the app decides what a drag means (scroll, swipe).
//!
//! Wayland extras (Linux only, outside the common interface): where the
//! compositor draws no title bar, the backend draws one itself (wl_csd.zig);
//! `setDecorationColors(DecorationColors)` recolours it, `startMove()` and
//! `startResize(ResizeEdge)` let an app's own top bar or grip move or
//! resize the window from a mouse_down, and `clientDecorations()` says
//! whether the backend's bar is shown. Where the compositor shows no
//! sub-surfaces (WSLg) `titleBar()` returns the bar the app must draw in
//! its inset strip (the backend still handles that strip's input).
//!
//! Backends: Win32 (../Windows bindings), Wayland (../Wayland; no X11),
//! macOS AppKit (../MacOS), iOS UIKit (ios.zig; Objective-C runtime types
//! from ../MacOS).

const std = @import("std");
const builtin = @import("builtin");
const Renderer = @import("Renderer");

pub const SurfaceSource = Renderer.Instanced2D.SurfaceSource;

/// The platform's window type.
pub const Window = switch (builtin.os.tag) {
    .windows => @import("win32.zig").Window,
    .linux => @import("wayland.zig").Window,
    .macos => @import("cocoa.zig").Window,
    .ios => @import("ios.zig").Window,
    else => @compileError("Window: unsupported OS"),
};

/// The iOS backend's extras (lock cover, native view handle); void elsewhere.
pub const ios = if (builtin.os.tag == .ios) @import("ios.zig") else void;

comptime {
    checkInterface(Window);
}

pub const LiveFn = *const fn (ctx: *anyopaque) void;

/// waitEvents timeout meaning "no timeout": sleep until input or wake()
/// (equals Win32 INFINITE).
pub const forever: u32 = std.math.maxInt(u32);

// ------------------------------------------------------------------ events

pub const Key = enum {
    enter,
    escape,
    backspace,
    tab,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    insert,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const MouseButton = enum { left, right, middle };

/// What produced a pointer event: a mouse or trackpad, a finger on a touch
/// screen, or a pen. Apps that treat touch differently (presses that act
/// on release, drags that scroll, long presses) look at this per event, so
/// a convertible's trackpad stays a mouse while its screen is touched.
pub const PointerSource = enum { mouse, touch, pen };

pub const Mods = bitpack struct(u8) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    _: u4 = 0,
};

/// Positions are framebuffer pixels, origin top left.
pub const Event = union(enum) {
    close,
    resize: struct { width: u32, height: u32 },
    /// Device scale changed (moved to another monitor).
    scale: f32,
    /// Draw again (the picture on screen may be stale; iOS: the interface
    /// orientation changed, e.g. a 180 degree turn that keeps the size).
    expose,
    key: struct { key: Key, mods: Mods },
    /// Typed text. Control characters are never delivered here; Ctrl+letter
    /// arrives as the lowercase letter with `mods.ctrl`, Alt+character with
    /// `mods.alt`.
    char: struct { cp: u21, mods: Mods = .{} },
    /// A press. A finger is the left button (`source` .touch).
    mouse_down: struct { x: f32, y: f32, button: MouseButton = .left, mods: Mods = .{}, source: PointerSource = .mouse },
    /// Pointer moved with the left button held (plain hovering is not
    /// reported).
    mouse_move: struct { x: f32, y: f32, left_held: bool = false, source: PointerSource = .mouse },
    /// Left button released. `cancelled`: the OS took the press away (iOS:
    /// touchesCancelled, e.g. a system gesture or a call, or the interface
    /// orientation changed; Win32: the touch was cancelled or its capture
    /// lost): end the press without acting on it (no tap, no committed
    /// drag).
    mouse_up: struct { x: f32, y: f32, button: MouseButton = .left, cancelled: bool = false, source: PointerSource = .mouse },
    /// Wheel / trackpad scroll in notches (1.0 = one wheel detent).
    /// `dy` > 0: away from the user (scroll up); `dx` > 0: to the right.
    scroll: struct { x: f32, y: f32, dx: f32, dy: f32, mods: Mods = .{} },
    /// Ctrl(+Cmd on macOS) with = / - / 0.
    zoom: enum { in, out, reset },
    /// `insets()` changed (rotation, keyboard shown / hidden). Redraw.
    insets,
    /// The app left the screen (iOS: the scene entered the background).
    /// Stop drawing until `.foreground`: the backend waits (briefly) until
    /// this event has been taken, so no frame is in flight afterwards.
    background,
    /// Back on screen after `.background`. Redraw.
    foreground,
    /// The native text field (showTextInput) changed or was submitted
    /// (Return). Read it with textInputText.
    text_input: enum { changed, submit },
    /// A media / headset button while the window has the keyboard focus
    /// (Win32: WM_APPCOMMAND, e.g. a headset's play / pause button or the
    /// keyboard's media keys). Never on Wayland, macOS or iOS yet (their
    /// remote-command APIs are a later step).
    media: Media,
    /// The device's posture may have changed: a convertible went into or
    /// out of tablet (slate) mode, a keyboard was attached or taken off
    /// (Win32: WM_SETTINGCHANGE "ConvertibleSlateMode" or
    /// "UserInteractionMode"). Ask the OS again what input it offers.
    /// Never elsewhere yet.
    posture,
};

/// What a media button asked for.
pub const Media = enum { play_pause, play, pause, stop };

/// An edge or corner of the window, for an interactive resize
/// (Wayland: `Window.startResize`).
pub const ResizeEdge = enum { top, bottom, left, right, top_left, top_right, bottom_left, bottom_right };

/// Colours of the title bar the Wayland backend draws itself where the
/// compositor draws none (GNOME, Weston / WSLg); `Window.setDecorationColors`
/// replaces them. Neutral by default.
pub const DecorationColors = struct {
    /// The bar while the window has the focus, and while it has not.
    bar: [3]u8 = .{ 0x2B, 0x2D, 0x31 },
    bar_inactive: [3]u8 = .{ 0x3A, 0x3C, 0x41 },
    /// The title text, focused and not.
    title: [3]u8 = .{ 0xE4, 0xE6, 0xEA },
    title_inactive: [3]u8 = .{ 0x9A, 0x9D, 0xA3 },
    /// The close button under the pointer: its background and its cross.
    close_hover: [3]u8 = .{ 0xC4, 0x2B, 0x1C },
    close_hover_fg: [3]u8 = .{ 0xFF, 0xFF, 0xFF },
};

/// The title bar an app must draw itself (Wayland `Window.titleBar()`):
/// where the compositor shows no sub-surfaces (WSLg) the backend cannot
/// show its own, but still handles the strip's input (move, close,
/// double-click maximise, resize at the top edge). Draw it over the top
/// `height` pixels (= `insets().top`): the bar colour, the title from
/// the left, and a cross centred in the last `close_w` pixels (on
/// `colors.close_hover` while `close_hover`). Framebuffer pixels.
pub const TitleBar = struct {
    height: f32,
    close_w: f32,
    /// Space before the title, and the title's font size.
    title_pad: f32,
    title_em: f32,
    title: []const u8,
    active: bool,
    close_hover: bool,
    colors: DecorationColors,
};

/// Pixels (framebuffer) at each edge that the UI should keep clear.
/// `keyboard` is the height covered by the on-screen keyboard, measured
/// from the bottom edge (0 when hidden); it includes the bottom safe area
/// while shown.
pub const Insets = struct {
    top: f32 = 0,
    left: f32 = 0,
    bottom: f32 = 0,
    right: f32 = 0,
    keyboard: f32 = 0,

    /// The bottom inset to lay out against: keyboard or safe area.
    pub fn bottomClear(i: Insets) f32 {
        return @max(i.bottom, i.keyboard);
    }
};

/// Where and how to show the native text field (framebuffer pixels).
pub const TextField = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// Font size in pixels; 0 = the platform's default.
    font_px: f32 = 0,
    fg: [3]u8 = .{ 0xE6, 0xE9, 0xED },
    bg: [3]u8 = .{ 0x31, 0x36, 0x3F },
    /// Raise the keyboard now (the UI moved its focus here). Otherwise the
    /// keyboard comes up when the user taps the field.
    focus: bool = false,
    /// How the system keyboard treats the text (iOS today; others ignore
    /// it). The defaults are the platform's own.
    traits: TextTraits = .{},
};

/// Input traits of the native text field. Each enum's values are UIKit's
/// raw values; `.default` leaves the platform's choice.
pub const TextTraits = struct {
    pub const Toggle = enum(i64) { default = 0, off = 1, on = 2 };
    pub const Capitalization = enum(i64) { none = 0, words = 1, sentences = 2, all = 3 };
    pub const Appearance = enum(i64) { default = 0, dark = 1, light = 2 };
    pub const ReturnKey = enum(i64) { default = 0, go = 1, next = 4, search = 6, send = 7, done = 9, @"continue" = 11 };

    /// Curly quotes for straight ones (UITextSmartQuotesType).
    smart_quotes: Toggle = .default,
    /// An em dash for "--" (UITextSmartDashesType).
    smart_dashes: Toggle = .default,
    /// Spaces added or removed around pasted and deleted words
    /// (UITextSmartInsertDeleteType).
    smart_insert_delete: Toggle = .default,
    /// Automatic capitals (UITextAutocapitalizationType; UIKit's default
    /// is sentences).
    capitalization: Capitalization = .sentences,
    keyboard_appearance: Appearance = .default,
    /// The label of the keyboard's Return key (UIReturnKeyType).
    return_key: ReturnKey = .default,
};

/// Platform behaviour for `runApp`. Only iOS acts on these today; every
/// field defaults to off so a desktop program is unaffected.
pub const AppOptions = struct {
    /// iOS: refuse third-party (custom) keyboards for the whole app
    /// (application:shouldAllowExtensionPointIdentifier: says NO for
    /// UIApplicationKeyboardExtensionPointIdentifier).
    block_keyboard_extensions: bool = false,
    /// iOS: cover the UI with an opaque view while the app is not active
    /// (app switcher snapshot, Control Center, calls).
    cover_when_inactive: bool = false,
    /// iOS: cover the UI while the screen is recorded or mirrored
    /// (UIScreen.isCaptured, UIScreenCapturedDidChangeNotification).
    cover_when_captured: bool = false,
    /// iOS: after a trip to the background keep the cover up ("locked")
    /// until the app calls `ios.unlock()` (e.g. after Face ID).
    lock_after_background: bool = false,
    /// iOS: start locked: the cover is up from the scene's first frame and
    /// the first activation asks the unlock handler. Applied synchronously
    /// in runApp (an `ios.lock()` before runApp is dispatched to the main
    /// queue and may land after that first activation).
    start_locked: bool = false,
    /// iOS: text shown on the cover while locked (e.g. "Tap to unlock");
    /// `ios.setLockMessage` replaces it (e.g. why unlocking failed).
    lock_message: []const u8 = "",
    /// Cover colour.
    cover_rgb: [3]u8 = .{ 0x20, 0x23, 0x29 },
    /// The lock message's text colour.
    lock_text_rgb: [3]u8 = .{ 0xE6, 0xE8, 0xEC },
};

pub const EntryFn = *const fn (ctx: ?*anyopaque) void;

/// Runs `entry(ctx)` as the program's main loop and exits the process
/// when it returns (status 0). Desktop: on this thread, now. iOS: call it
/// from `main` on the main thread; it starts UIKit (UIApplicationMain,
/// never returns) and runs `entry` on an app thread once the window
/// exists. Window.init must be called from inside `entry`.
pub fn runApp(options: AppOptions, entry: EntryFn, ctx: ?*anyopaque) noreturn {
    if (builtin.os.tag == .ios) @import("ios.zig").runApp(options, entry, ctx);
    entry(ctx);
    std.process.exit(0);
}

/// Fixed-size event queue shared by the backends. Other events are dropped
/// on overflow, but `.close` never is: it is kept as a sticky flag and
/// delivered once the queue has drained (so a flood of input cannot make
/// the window unclosable).
pub const Queue = struct {
    items: [256]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    close_pending: bool = false,

    pub fn push(q: *Queue, e: Event) void {
        if (e == .close) {
            q.close_pending = true;
            return;
        }
        if (q.len == q.items.len) return; // drop on overflow
        q.items[(q.head + q.len) % q.items.len] = e;
        q.len += 1;
    }
    pub fn pop(q: *Queue) ?Event {
        if (q.len == 0) {
            if (!q.close_pending) return null;
            q.close_pending = false;
            return .close;
        }
        const e = q.items[q.head];
        q.head = (q.head + 1) % q.items.len;
        q.len -= 1;
        return e;
    }
    /// True if pop() would return an event.
    pub fn pending(q: *const Queue) bool {
        return q.len > 0 or q.close_pending;
    }
};

// --------------------------------------------------------------- interface

/// Fails compilation unless `W` implements the whole interface with the
/// exact signatures. Taking each method's address also makes the compiler
/// analyse its body, so a cross-compile of this module type-checks the
/// complete backend, not just what one program happens to call.
pub fn checkInterface(comptime W: type) void {
    const A = std.mem.Allocator;
    const Sigs = struct {
        init: *const fn (A, []const u8, u32, u32) anyerror!*W,
        deinit: *const fn (*W) void,
        setLiveCallback: *const fn (*W, *anyopaque, LiveFn) void,
        pollEvent: *const fn (*W) ?Event,
        pollQueued: *const fn (*W) ?Event,
        waitEvents: *const fn (*W, u32) void,
        wake: *const fn (*W) void,
        framebufferSize: *const fn (*const W) [2]u32,
        scale: *const fn (*const W) f32,
        surfaceSource: *const fn (*const W) SurfaceSource,
        setTitle: *const fn (*W, []const u8) void,
        hide: *const fn (*W) void,
        clipboardText: *const fn (*W, A, usize) ?[]u8,
        setClipboardText: *const fn (*W, []const u8) bool,
        insets: *const fn (*const W) Insets,
        showTextInput: *const fn (*W, TextField) bool,
        hideTextInput: *const fn (*W) void,
        textInputText: *const fn (*W, []u8) []const u8,
        setTextInputText: *const fn (*W, []const u8) void,
    };
    inline for (@typeInfo(Sigs).@"struct".field_names, @typeInfo(Sigs).@"struct".field_types) |name, F| {
        if (!@hasDecl(W, name)) @compileError(@typeName(W) ++ " lacks Window." ++ name);
        const f = &@field(W, name);
        const Fn = @typeInfo(F).pointer.child;
        const Have = @TypeOf(@field(W, name));
        const want = @typeInfo(Fn).@"fn";
        const have = @typeInfo(Have).@"fn";
        if (want.param_types.len != have.param_types.len)
            @compileError(@typeName(W) ++ "." ++ name ++ ": wrong parameter count");
        inline for (want.param_types, have.param_types) |a, b| {
            if (a != b) @compileError(@typeName(W) ++ "." ++ name ++ ": parameter " ++ @typeName(b) ++ ", want " ++ @typeName(a));
        }
        const want_ret = want.return_type.?;
        const have_ret = have.return_type.?;
        if (want_ret != have_ret) {
            // init may name its own error set.
            const ok = @typeInfo(want_ret) == .error_union and @typeInfo(have_ret) == .error_union and
                @typeInfo(want_ret).error_union.payload == @typeInfo(have_ret).error_union.payload;
            if (!ok) @compileError(@typeName(W) ++ "." ++ name ++ ": returns " ++ @typeName(have_ret) ++ ", want " ++ @typeName(want_ret));
        }
        _ = f;
    }
}

// ----------------------------------------------------------- shared helpers

/// Copies UTF-8 clipboard bytes into a new buffer, replacing invalid
/// sequences with U+FFFD and stopping before `max_units` UTF-16 units
/// would be exceeded (a code point never splits). Null on OOM.
pub fn sanitizeClipboard(gpa: std.mem.Allocator, bytes: []const u8, max_units: usize) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var units: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        var cp: u21 = 0xFFFD;
        var adv: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(bytes[i])) |n| {
            if (i + n <= bytes.len) {
                if (std.unicode.utf8Decode(bytes[i..][0..n])) |c| {
                    cp = c;
                    adv = n;
                } else |_| {}
            }
        } else |_| {}
        if (cp == 0) break; // C strings end here
        const u: usize = if (cp >= 0x10000) 2 else 1;
        if (units + u > max_units) break;
        units += u;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        out.appendSlice(gpa, buf[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
        i += adv;
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

/// Copies `text` into `buf` NUL-terminated, truncated on a code point
/// boundary; invalid UTF-8 gives "". For titles (the terminal's program
/// sets them, so length and content are untrusted).
pub fn titleZ(text: []const u8, buf: []u8) [:0]const u8 {
    std.debug.assert(buf.len > 0);
    if (!std.unicode.utf8ValidateSlice(text)) {
        buf[0] = 0;
        return buf[0..0 :0];
    }
    var n = @min(text.len, buf.len - 1);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

/// Length of the longest prefix of `s` that does not split a UTF-8 code
/// point (for fixed-size text buffers).
pub fn utf8Prefix(s: []const u8) usize {
    var n = s.len;
    while (n > 0 and (s[n - 1] & 0xC0) == 0x80) n -= 1;
    if (n == 0) return 0;
    const need = std.unicode.utf8ByteSequenceLength(s[n - 1]) catch return n - 1;
    return if (n - 1 + need <= s.len) n - 1 + need else n - 1;
}

/// The poll(2) timeout (ms) that ends at the absolute monotonic `deadline_ns`
/// when it is `now_ns`: 0 once it has passed, rounded up so a wake-up never
/// lands just before the deadline, and capped at maxInt(i32).
pub fn msUntil(now_ns: u64, deadline_ns: u64) i32 {
    if (deadline_ns <= now_ns) return 0;
    const left = deadline_ns - now_ns;
    const ms = left / std.time.ns_per_ms + @intFromBool(left % std.time.ns_per_ms != 0);
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

/// The shorter of two poll(2) timeouts, where a negative one means "none".
pub fn minTimeout(a: i32, b: i32) i32 {
    if (a < 0) return b;
    if (b < 0) return a;
    return @min(a, b);
}

comptime {
    _ = &runApp;
}

test "msUntil: an absolute deadline, rounded up, never negative" {
    const ms = std.time.ns_per_ms;
    try std.testing.expectEqual(@as(i32, 2000), msUntil(0, 2000 * ms));
    try std.testing.expectEqual(@as(i32, 1), msUntil(5 * ms, 5 * ms + 1));
    try std.testing.expectEqual(@as(i32, 0), msUntil(5 * ms, 5 * ms));
    try std.testing.expectEqual(@as(i32, 0), msUntil(9 * ms, 5 * ms));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), msUntil(0, std.math.maxInt(u64)));
    // A reader that trickles one byte every 99 ms still ends at the
    // deadline: the budget shrinks with every wake-up, not only idle ones.
    const deadline: u64 = 2000 * ms;
    var now: u64 = 0;
    var wakes: u32 = 0;
    while (msUntil(now, deadline) > 0) : (wakes += 1) now += 99 * ms;
    try std.testing.expectEqual(@as(u32, 21), wakes);
}

test "minTimeout: negative is no timeout" {
    try std.testing.expectEqual(@as(i32, -1), minTimeout(-1, -1));
    try std.testing.expectEqual(@as(i32, 5), minTimeout(-1, 5));
    try std.testing.expectEqual(@as(i32, 5), minTimeout(5, -1));
    try std.testing.expectEqual(@as(i32, 0), minTimeout(0, 5));
}

test {
    if (builtin.os.tag == .windows) _ = @import("win32.zig");
    // The Wayland title bar's layout and hit testing (no Wayland calls).
    _ = @import("wl_csd.zig");
    // The macOS key mapping is pure: tested on every host.
    _ = @import("cocoa_keys.zig");
}

test "utf8Prefix never splits a code point" {
    try std.testing.expectEqual(@as(usize, 3), utf8Prefix("abc"));
    try std.testing.expectEqual(@as(usize, 1), utf8Prefix("a\xc3"));
    try std.testing.expectEqual(@as(usize, 3), utf8Prefix("a\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 1), utf8Prefix("a\xe2\x82"));
    try std.testing.expectEqual(@as(usize, 0), utf8Prefix("\xa9"));
}

test "Queue never drops close" {
    var q: Queue = .{};
    var i: usize = 0;
    while (i < 300) : (i += 1) q.push(.expose);
    q.push(.close);
    q.push(.expose);
    try std.testing.expect(q.pending());
    var n: usize = 0;
    var saw_close = false;
    while (q.pop()) |e| {
        if (e == .close) {
            saw_close = true;
        } else n += 1;
    }
    try std.testing.expect(saw_close);
    try std.testing.expectEqual(@as(usize, 256), n);
    try std.testing.expect(!q.pending());
}

test "sanitizeClipboard: replacement, NUL and unit limit" {
    const gpa = std.testing.allocator;
    const a = sanitizeClipboard(gpa, "a\xffb", 10).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("a\u{FFFD}b", a);
    const b = sanitizeClipboard(gpa, "xy\x00z", 10).?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("xy", b);
    // U+1F600 takes two units: with 2 units left after "a" only one fits.
    const c = sanitizeClipboard(gpa, "a\u{1F600}\u{1F600}", 4).?;
    defer gpa.free(c);
    try std.testing.expectEqualStrings("a\u{1F600}", c);
}

test "titleZ truncates on a code point boundary" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("ab", titleZ("ab\u{e9}\u{e9}", buf[0..4]));
    try std.testing.expectEqualStrings("", titleZ("ok\xff", &buf));
    try std.testing.expectEqualStrings("hi", titleZ("hi", &buf));
}
