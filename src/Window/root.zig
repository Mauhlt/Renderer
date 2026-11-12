//! Module "Window": a native window to draw into with Instanced2D, with one
//! interface on every platform. Event driven: `waitEvents` blocks in the OS
//! until input, a `wake()` from another thread, or the caller's deadline;
//! nothing here ticks at a fixed rate (the one exception is Win32's 16 ms
//! timer while the user drags the window border, because Windows then runs
//! its own modal loop and only a timer lets the app redraw during it).
//!
//!     const win = try Window.init(gpa, "Title", 800, 600);   // logical size
//!     defer win.deinit();
//!     const r = try Instanced2D.init(gpa, win.surfaceSource(), fb[0], fb[1], .{});
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
//!                                   all zero on desktops
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
//! `.insets`, `.background` / `.foreground`, `.text_input`.
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

pub const Mods = packed struct(u8) {
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
    expose,
    key: struct { key: Key, mods: Mods },
    /// Typed text. Control characters are never delivered here; Ctrl+letter
    /// arrives as the lowercase letter with `mods.ctrl`, Alt+character with
    /// `mods.alt`.
    char: struct { cp: u21, mods: Mods = .{} },
    mouse_down: struct { x: f32, y: f32, button: MouseButton = .left, mods: Mods = .{} },
    /// Pointer moved with the left button held (plain hovering is not
    /// reported).
    mouse_move: struct { x: f32, y: f32, left_held: bool = false },
    /// Left button released.
    mouse_up: struct { x: f32, y: f32, button: MouseButton = .left },
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
    /// Cover colour.
    cover_rgb: [3]u8 = .{ 0x20, 0x23, 0x29 },
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

comptime {
    _ = &runApp;
}

test {
    if (builtin.os.tag == .windows) _ = @import("win32.zig");
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
