//! Win32 window backend, on the owner's Windows bindings (../Windows).
//!
//! Event driven: waitEvents is MsgWaitForMultipleObjectsEx on the thread's
//! message queue; wake() posts WM_APP. The only timer is a 16 ms SetTimer
//! while the user drags the border (WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE):
//! Windows then runs its own modal loop, and the live callback is the only
//! way to redraw during it.

const std = @import("std");
const W = @import("Windows");
const root = @import("root.zig");

const USER = W.USER;
const KERNEL = W.KERNEL;
const T = W.TYPES;
const S = W.STRUCTS;
const E = W.ENUMS;
const M = E.Messages;

const Event = root.Event;
const Key = root.Key;
const Mods = root.Mods;
const Media = root.Media;
const MouseButton = root.MouseButton;

const HWND = T.HWND;
const WPARAM = T.WPARAM;
const LPARAM = T.LPARAM;
const LRESULT = T.LRESULT;

// --- Not in ../Windows yet (kernel32 global memory, for the clipboard).
// Remove these once the Windows package's KERNEL binds them.
extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) T.HANDLE;
extern "kernel32" fn GlobalLock(mem: T.HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(mem: T.HANDLE) callconv(.winapi) T.BOOL;
extern "kernel32" fn GlobalFree(mem: T.HANDLE) callconv(.winapi) T.HANDLE;
extern "kernel32" fn GlobalSize(mem: T.HANDLE) callconv(.winapi) usize;
const GMEM_MOVEABLE: u32 = 0x0002;
/// MsgWaitForMultipleObjectsEx flag (the binding documents the value).
const MWMO_INPUTAVAILABLE: u32 = 0x0004;

const MK_LBUTTON: usize = 0x0001;
const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const live_timer_id: usize = 1;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("RendererWindow");
var class_registered = false;

const style: E.WindowStyle = .overlapped_window;

fn msgId(m: M) u32 {
    return @backingInt(m);
}

fn wbits(wp: WPARAM) usize {
    return @backingInt(wp);
}

pub const Window = struct {
    gpa: std.mem.Allocator,
    hwnd: HWND = .null,
    hinstance: T.HINSTANCE = .null,
    queue: root.Queue = .{},
    dpi: u32 = 96,
    pending_high: ?u16 = null,
    live_ctx: ?*anyopaque = null,
    live_fn: ?root.LiveFn = null,
    in_size_move: bool = false,
    closed: bool = false,

    pub fn init(gpa: std.mem.Allocator, title: []const u8, width: u32, height: u32) !*Window {
        enableDpiAwareness();
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };
        self.hinstance = KERNEL.GetModuleHandleW(null);
        if (self.hinstance == .null) return error.NoModuleHandle;
        if (!class_registered) {
            const wc: S.WNDCLASSEXW = .{
                .style = .redraw,
                .wnd_proc = wndProc,
                .instance = self.hinstance,
                .cursor = USER.LoadCursorW(.null, E.SystemCursor.arrow.nameW()),
                .class_name = class_name,
                // The program's own icon (resource 1, if the exe has one):
                // title bar, Alt+Tab and taskbar. Without it Windows shows its
                // default icon.
                .icon = appIcon(self.hinstance, 0, 0, .{ .default_size = true, .shared = true }),
                .small_icon = appIcon(self.hinstance, USER.GetSystemMetrics(.cx_small_icon), USER.GetSystemMetrics(.cy_small_icon), .{ .shared = true }),
            };
            if (USER.RegisterClassExW(&wc) == .null) return error.RegisterClassFailed;
            class_registered = true;
        }
        var wtitle: [256:0]u16 = undefined;
        utf16Title(title, &wtitle);
        const hwnd = USER.CreateWindowExW(.{}, class_name, &wtitle, style, USER.CW_USEDEFAULT, USER.CW_USEDEFAULT, @intCast(width), @intCast(height), .null, .null, self.hinstance, self);
        if (hwnd == .null) return error.CreateWindowFailed;
        self.hwnd = hwnd;
        self.dpi = windowDpi(hwnd);
        // Resize to the requested logical client size at this monitor's DPI.
        var rect: S.RECT = .{ .left = 0, .top = 0, .right = @intCast(width * self.dpi / 96), .bottom = @intCast(height * self.dpi / 96) };
        _ = USER.AdjustWindowRectEx(&rect, style, .false, .{});
        _ = USER.SetWindowPos(hwnd, .null, 0, 0, rect.width(), rect.height(), .{ .no_move = true, .no_z_order = true, .no_activate = true });
        _ = USER.ShowWindow(hwnd, .normal);
        return self;
    }

    pub fn deinit(self: *Window) void {
        if (!self.closed) _ = USER.DestroyWindow(self.hwnd);
        self.gpa.destroy(self);
    }

    pub fn setLiveCallback(self: *Window, ctx: *anyopaque, f: root.LiveFn) void {
        self.live_ctx = ctx;
        self.live_fn = f;
    }

    pub fn pollEvent(self: *Window) ?Event {
        if (self.queue.pop()) |e| return e;
        var msg: S.MSG = undefined;
        while (USER.PeekMessageW(&msg, .null, 0, 0, .remove).toBool()) {
            _ = USER.TranslateMessage(&msg);
            _ = USER.DispatchMessageW(&msg);
            if (self.queue.pending()) break;
        }
        return self.queue.pop();
    }

    /// Events already queued, without pumping the OS (safe inside callbacks).
    pub fn pollQueued(self: *Window) ?Event {
        return self.queue.pop();
    }

    /// `root.forever` (= INFINITE) waits with no timeout; wake()'s posted
    /// WM_APP (QS_POSTMESSAGE) still ends it, and MWMO_INPUTAVAILABLE makes
    /// a message posted before the call count too, so a wake cannot be lost
    /// between pollEvent and here.
    pub fn waitEvents(self: *Window, timeout_ms: u32) void {
        if (self.queue.pending()) return;
        _ = USER.MsgWaitForMultipleObjectsEx(0, null, timeout_ms, .all_input, MWMO_INPUTAVAILABLE);
    }

    /// Safe to call from any thread. Coalesced by the wait: any number of
    /// posted WM_APPs end one wait and are drained by the next pollEvent.
    pub fn wake(self: *Window) void {
        _ = USER.PostMessageW(self.hwnd, msgId(.app), .null, .null);
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        var r: S.RECT = undefined;
        if (!USER.GetClientRect(self.hwnd, &r).toBool()) return .{ 0, 0 };
        return .{ @intCast(@max(0, r.width())), @intCast(@max(0, r.height())) };
    }

    pub fn scale(self: *const Window) f32 {
        return @as(f32, @floatFromInt(self.dpi)) / 96.0;
    }

    pub fn surfaceSource(self: *const Window) root.SurfaceSource {
        return .{ .win32 = .{
            .hinstance = @ptrFromInt(@as(usize, @bitCast(@backingInt(self.hinstance)))),
            .hwnd = @ptrFromInt(@as(usize, @bitCast(@backingInt(self.hwnd)))),
        } };
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        var wtitle: [256:0]u16 = undefined;
        utf16Title(title, &wtitle);
        _ = USER.SetWindowTextW(self.hwnd, &wtitle);
    }

    pub fn hide(self: *Window) void {
        if (!self.closed) _ = USER.ShowWindow(self.hwnd, .hide);
    }

    fn handle(self: *Window, hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) ?LRESULT {
        const lpi: isize = @backingInt(lp);
        // WM_APPCOMMAND (not in the Messages enum): media buttons. TRUE when
        // taken; others go on to DefWindowProc (which passes them up).
        if (msg == WM_APPCOMMAND) {
            const m = mediaCommand(USER.hiWord(lp)) orelse return null;
            self.queue.push(.{ .media = m });
            return @enumFromInt(1);
        }
        switch (@as(M, @enumFromInt(msg))) {
            .close => {
                self.queue.push(.close);
                return .null;
            },
            .destroy => {
                self.closed = true;
                return .null;
            },
            .erase_bkgnd => return @enumFromInt(1),
            .size => {
                const w: u32 = USER.loWord(lp);
                const h: u32 = USER.hiWord(lp);
                self.queue.push(.{ .resize = .{ .width = w, .height = h } });
                if (self.in_size_move) self.runLive();
                return .null;
            },
            .paint => {
                // Validate so Windows stops sending WM_PAINT; we redraw ourselves.
                _ = USER.ValidateRect(hwnd, null);
                self.queue.push(.expose);
                return .null;
            },
            .enter_size_move => {
                self.in_size_move = true;
                _ = USER.SetTimer(hwnd, live_timer_id, 16, null);
                return .null;
            },
            .exit_size_move => {
                self.in_size_move = false;
                _ = USER.KillTimer(hwnd, live_timer_id);
                return .null;
            },
            .timer => {
                if (self.in_size_move) self.runLive();
                return .null;
            },
            .dpi_changed => {
                self.dpi = USER.loWord(wp);
                if (lpi != 0) {
                    const r = lp.toPtr(S.RECT);
                    _ = USER.SetWindowPos(hwnd, .null, r.left, r.top, r.width(), r.height(), .{ .no_z_order = true, .no_activate = true });
                }
                self.queue.push(.{ .scale = self.scale() });
                return .null;
            },
            .l_button_down, .r_button_down, .m_button_down => |m| {
                const p = mousePos(lp);
                const button: MouseButton = switch (m) {
                    .l_button_down => .left,
                    .r_button_down => .right,
                    else => .middle,
                };
                // Keep receiving moves (and the up) while dragging outside.
                if (button == .left) _ = USER.SetCapture(hwnd);
                self.queue.push(.{ .mouse_down = .{ .x = p[0], .y = p[1], .button = button, .mods = currentMods() } });
                return .null;
            },
            .l_button_up => {
                const p = mousePos(lp);
                _ = USER.ReleaseCapture();
                self.queue.push(.{ .mouse_up = .{ .x = p[0], .y = p[1] } });
                return .null;
            },
            .mouse_move => {
                // Only drags matter to hosts; plain hovering is not queued.
                if (wbits(wp) & MK_LBUTTON == 0) return .null;
                const p = mousePos(lp);
                self.queue.push(.{ .mouse_move = .{ .x = p[0], .y = p[1], .left_held = true } });
                return .null;
            },
            .mouse_wheel, .mouse_h_wheel => |m| {
                // Wheel positions are in screen coordinates.
                var pt: S.POINT = .{ .x = USER.getXLParam(lp), .y = USER.getYLParam(lp) };
                _ = USER.ScreenToClient(hwnd, &pt);
                const notches = @as(f32, @floatFromInt(USER.getWheelDeltaWParam(wp))) / @as(f32, @floatFromInt(USER.WHEEL_DELTA));
                const vertical = m == .mouse_wheel;
                self.queue.push(.{ .scroll = .{
                    .x = @floatFromInt(pt.x),
                    .y = @floatFromInt(pt.y),
                    .dx = if (vertical) 0 else notches,
                    .dy = if (vertical) notches else 0,
                    .mods = currentMods(),
                } });
                return .null;
            },
            .sys_char => {
                // Alt+character: deliver it (hosts send ESC + char) instead
                // of letting DefWindowProc beep. Alt+Space still opens the
                // system menu.
                const unit: u16 = @truncate(wbits(wp));
                if (unit < 0x20 or unit == ' ' or unit == 0x7f or (unit >= 0xD800 and unit <= 0xDFFF)) return null;
                self.queue.push(.{ .char = .{ .cp = unit, .mods = .{ .alt = true } } });
                return .null;
            },
            .key_down, .sys_key_down => {
                if (self.keyDown(@truncate(wbits(wp)), currentMods())) return .null;
                return null; // let DefWindowProc handle Alt+F4 etc.
            },
            .char => {
                const unit: u16 = @truncate(wbits(wp));
                if (unit >= 0xD800 and unit <= 0xDBFF) {
                    self.pending_high = unit;
                    return .null;
                }
                var cp: u21 = unit;
                if (unit >= 0xDC00 and unit <= 0xDFFF) {
                    const hi = self.pending_high orelse return .null;
                    cp = 0x10000 + ((@as(u21, hi) - 0xD800) << 10) + (unit - 0xDC00);
                }
                self.pending_high = null;
                if (cp >= 0x20 and cp != 0x7f) self.queue.push(.{ .char = .{ .cp = cp } });
                return .null;
            },
            .app => return .null,
            else => return null,
        }
    }

    fn runLive(self: *Window) void {
        if (self.live_fn) |f| f(self.live_ctx.?);
    }

    /// Returns true if the key was consumed.
    fn keyDown(self: *Window, vk: u8, mods: Mods) bool {
        const key: ?Key = switch (vk) {
            0x0D => .enter,
            0x1B => .escape,
            0x08 => .backspace,
            0x09 => .tab,
            0x26 => .up,
            0x28 => .down,
            0x25 => .left,
            0x27 => .right,
            0x24 => .home,
            0x23 => .end,
            0x21 => .page_up,
            0x22 => .page_down,
            0x2E => .delete,
            0x2D => .insert,
            0x70 => .f1,
            0x71 => .f2,
            0x72 => .f3,
            0x73 => .f4,
            0x74 => .f5,
            0x75 => .f6,
            0x76 => .f7,
            0x77 => .f8,
            0x78 => .f9,
            0x79 => .f10,
            0x7A => .f11,
            0x7B => .f12,
            else => null,
        };
        if (key) |k| {
            // Alt+F4 stays with DefWindowProc (closes the window).
            if (k == .f4 and mods.alt) return false;
            self.queue.push(.{ .key = .{ .key = k, .mods = mods } });
            // F-keys are consumed (F10 would otherwise enter menu mode);
            // the others are still translated (their WM_CHAR is filtered).
            return @backingInt(k) >= @backingInt(Key.f1);
        }
        if (mods.ctrl and !mods.alt) {
            switch (vk) {
                0xBB, 0x6B => self.queue.push(.{ .zoom = .in }), // '=' / numpad +
                0xBD, 0x6D => self.queue.push(.{ .zoom = .out }),
                0x30, 0x60 => self.queue.push(.{ .zoom = .reset }),
                'A'...'Z' => self.queue.push(.{ .char = .{ .cp = vk + 32, .mods = mods } }),
                // Ctrl+[ \ ] Space / (US layout positions): ESC, FS, GS, NUL, US.
                0xDB => self.queue.push(.{ .char = .{ .cp = '[', .mods = mods } }),
                0xDC => self.queue.push(.{ .char = .{ .cp = '\\', .mods = mods } }),
                0xDD => self.queue.push(.{ .char = .{ .cp = ']', .mods = mods } }),
                0x20 => self.queue.push(.{ .char = .{ .cp = ' ', .mods = mods } }),
                0xBF => self.queue.push(.{ .char = .{ .cp = '/', .mods = mods } }),
                else => return false,
            }
            return true;
        }
        return false;
    }

    // ------------------------------------------------------------ clipboard

    /// Puts UTF-8 text on the clipboard as CF_UNICODETEXT. False on failure
    /// (invalid UTF-8, clipboard busy, out of memory).
    pub fn setClipboardText(self: *Window, utf8: []const u8) bool {
        const units = std.unicode.calcUtf16LeLen(utf8) catch return false;
        const mem = GlobalAlloc(GMEM_MOVEABLE, (units + 1) * 2);
        if (mem == .null) return false;
        var handed_over = false;
        defer if (!handed_over) {
            _ = GlobalFree(mem);
        };
        {
            const p = GlobalLock(mem) orelse return false;
            defer _ = GlobalUnlock(mem);
            const dst: [*]align(1) u16 = @ptrCast(p);
            var i: usize = 0;
            var it = (std.unicode.Utf8View.init(utf8) catch return false).iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp >= 0x10000) {
                    if (i + 2 > units) break;
                    const v = cp - 0x10000;
                    dst[i] = @intCast(0xD800 + (v >> 10));
                    dst[i + 1] = @intCast(0xDC00 + (v & 0x3FF));
                    i += 2;
                } else {
                    if (i + 1 > units) break;
                    dst[i] = @intCast(cp);
                    i += 1;
                }
            }
            dst[i] = 0;
        }
        if (!USER.OpenClipboard(self.hwnd).toBool()) return false;
        defer _ = USER.CloseClipboard();
        if (!USER.EmptyClipboard().toBool()) return false;
        if (USER.SetClipboardData(USER.CF_UNICODETEXT, mem) == .null) return false;
        handed_over = true; // the clipboard owns it now
        return true;
    }

    // ------------------------------------------- touch-device extras (none)

    pub fn insets(self: *const Window) root.Insets {
        _ = self;
        return .{};
    }

    /// No native text field here: keys and text arrive as events.
    pub fn showTextInput(self: *Window, field: root.TextField) bool {
        _ = self;
        _ = field;
        return false;
    }

    pub fn hideTextInput(self: *Window) void {
        _ = self;
    }

    pub fn textInputText(self: *Window, buf: []u8) []const u8 {
        _ = self;
        return buf[0..0];
    }

    pub fn setTextInputText(self: *Window, utf8: []const u8) void {
        _ = self;
        _ = utf8;
    }

    /// Clipboard text as UTF-8 (unpaired surrogates become U+FFFD), at most
    /// `max_units` UTF-16 units. Caller frees. Null if there is none.
    pub fn clipboardText(self: *Window, gpa: std.mem.Allocator, max_units: usize) ?[]u8 {
        if (!USER.OpenClipboard(self.hwnd).toBool()) return null;
        defer _ = USER.CloseClipboard();
        const h = USER.GetClipboardData(USER.CF_UNICODETEXT);
        if (h == .null) return null;
        const p = GlobalLock(h) orelse return null;
        defer _ = GlobalUnlock(h);
        const src: [*]align(1) const u16 = @ptrCast(p);
        const cap = @min(GlobalSize(h) / 2, max_units);
        var n: usize = 0;
        while (n < cap and src[n] != 0) n += 1;
        return utf16ToUtf8Lossy(gpa, src[0..n]);
    }
};

/// UTF-16 (host order) to a new UTF-8 buffer of exactly the encoded length;
/// unpaired surrogates become U+FFFD. Null on OOM, with nothing leaked: the
/// caller frees the result with its own length, so a failed shrink must
/// not hand back a slice shorter than the allocation.
fn utf16ToUtf8Lossy(gpa: std.mem.Allocator, src: []align(1) const u16) ?[]u8 {
    const n = src.len;
    const out = gpa.alloc(u8, std.math.mul(usize, n, 3) catch return null) catch return null;
    var o: usize = 0;
    var i: usize = 0;
    while (i < n) {
        var cp: u21 = 0xFFFD;
        const u = src[i];
        if (u >= 0xD800 and u <= 0xDBFF and i + 1 < n and src[i + 1] >= 0xDC00 and src[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (src[i + 1] - 0xDC00);
            i += 2;
        } else {
            if (u < 0xD800 or u > 0xDFFF) cp = u;
            i += 1;
        }
        // A 4-byte sequence always comes from 2 units (6 bytes reserved).
        o += std.unicode.utf8Encode(cp, out[o..]) catch 0;
    }
    return gpa.realloc(out, o) catch {
        gpa.free(out);
        return null;
    };
}

test "utf16ToUtf8Lossy: pairs, lone surrogates, and a failed shrink frees" {
    const gpa = std.testing.allocator;
    const text = [_]u16{ 'a', 0xD83D, 0xDE00, 0xDC00, 0xE9 };
    const s = utf16ToUtf8Lossy(gpa, &text).?;
    defer gpa.free(s);
    try std.testing.expectEqualStrings("a\u{1F600}\u{FFFD}\u{E9}", s);
    // The shrink (remap, then the fresh allocation it falls back to) fails:
    // null, and std.testing.allocator reports the buffer if it leaked or
    // was freed with the wrong length.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1, .resize_fail_index = 0 });
    try std.testing.expect(utf16ToUtf8Lossy(failing.allocator(), &text) == null);
    try std.testing.expect(failing.has_induced_failure);
    // The first allocation fails: null too.
    var first = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expect(utf16ToUtf8Lossy(first.allocator(), &text) == null);
}

fn mousePos(lp: LPARAM) [2]f32 {
    return .{ @floatFromInt(USER.getXLParam(lp)), @floatFromInt(USER.getYLParam(lp)) };
}

const WM_APPCOMMAND: u32 = 0x0319;

/// The media button an APPCOMMAND names (the high word of WM_APPCOMMAND's
/// lParam: the command in its low 12 bits, the device in the top 4).
pub fn mediaCommand(hi: u16) ?Media {
    return switch (hi & 0x0FFF) {
        14 => .play_pause, // APPCOMMAND_MEDIA_PLAY_PAUSE
        46 => .play, // APPCOMMAND_MEDIA_PLAY
        47 => .pause, // APPCOMMAND_MEDIA_PAUSE
        13 => .stop, // APPCOMMAND_MEDIA_STOP
        else => null,
    };
}

test "mediaCommand: the four media commands from any device, nothing else" {
    try std.testing.expectEqual(Media.play_pause, mediaCommand(14).?);
    try std.testing.expectEqual(Media.play_pause, mediaCommand(0x8000 | 14).?); // FAPPCOMMAND_KEY
    try std.testing.expectEqual(Media.play, mediaCommand(46).?);
    try std.testing.expectEqual(Media.pause, mediaCommand(0x1000 | 47).?); // FAPPCOMMAND_OEM
    try std.testing.expectEqual(Media.stop, mediaCommand(13).?);
    try std.testing.expect(mediaCommand(8) == null); // APPCOMMAND_VOLUME_MUTE
    try std.testing.expect(mediaCommand(11) == null); // NEXTTRACK
}

fn currentMods() Mods {
    return .{
        .ctrl = USER.GetKeyState(VK_CONTROL) < 0,
        .shift = USER.GetKeyState(VK_SHIFT) < 0,
        .alt = USER.GetKeyState(VK_MENU) < 0,
    };
}

/// Icon resource 1 of the module (the app icon a program links in), or
/// null. LR_SHARED: the system owns it, so nothing to destroy.
fn appIcon(inst: T.HINSTANCE, cx: i32, cy: i32, flags: E.LoadImageFlags) T.HICON {
    const h = USER.LoadImageW(inst, T.makeIntResourceW(1), .icon, cx, cy, flags);
    return @enumFromInt(@intFromEnum(h));
}

fn wndProc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    if (msg == msgId(.nc_create)) {
        const cs = lp.toPtr(S.CREATESTRUCTW);
        USER.setUserData(hwnd, cs.create_params);
        return USER.DefWindowProcW(hwnd, msg, wp, lp);
    }
    if (USER.getUserData(Window, hwnd)) |self| {
        if (self.handle(hwnd, msg, wp, lp)) |r| return r;
    }
    return USER.DefWindowProcW(hwnd, msg, wp, lp);
}

/// Encodes `title` into `out`, NUL-terminated, truncating at the buffer
/// limit on a code point boundary (a BMP code point takes one unit, an
/// astral one two; a pair never splits). Invalid UTF-8 yields an empty
/// title. A terminal's program controls the title (OSC 0/2), so this must
/// never write past `out` whatever its length (std's utf8ToUtf16Le does not
/// bounds-check the destination).
pub fn utf16Title(title: []const u8, out: *[256:0]u16) void {
    const cap: usize = out.len; // 256 units; out[256] is the sentinel slot
    var n: usize = 0;
    defer out[n] = 0;
    const v = std.unicode.Utf8View.init(title) catch return;
    var it = v.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            if (n + 1 > cap) return;
            out[n] = std.mem.nativeToLittle(u16, @intCast(cp));
            n += 1;
        } else {
            if (n + 2 > cap) return;
            const u = cp - 0x10000;
            out[n] = std.mem.nativeToLittle(u16, @intCast(0xD800 + (u >> 10)));
            out[n + 1] = std.mem.nativeToLittle(u16, @intCast(0xDC00 + (u & 0x3FF)));
            n += 2;
        }
    }
}

fn enableDpiAwareness() void {
    if (USER.load("SetProcessDpiAwarenessContext")) |f| {
        if (f(.per_monitor_aware_v2).toBool()) return;
    }
    if (USER.load("SetProcessDPIAware")) |f| _ = f();
}

fn windowDpi(hwnd: HWND) u32 {
    const f = USER.load("GetDpiForWindow") orelse return 96;
    const d = f(hwnd);
    return if (d == 0) 96 else d;
}

test "utf16Title truncates long titles inside the buffer" {
    var title: [600]u8 = undefined;
    @memset(&title, 'A');
    var out: [256:0]u16 = undefined;
    @memset(&out, 0xBEEF);
    utf16Title(&title, &out);
    const n = std.mem.len(@as([*:0]const u16, &out));
    try std.testing.expectEqual(@as(usize, 256), n);
    for (out[0..n]) |u| try std.testing.expectEqual(@as(u16, 'A'), u);
    try std.testing.expectEqual(@as(u16, 0), out[256]);
}

test "utf16Title keeps surrogate pairs whole" {
    // 300 x U+1F600 (4 bytes, 2 units each): 128 fit exactly.
    var title: [300 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < title.len) : (i += 4) _ = try std.unicode.utf8Encode(0x1F600, title[i..][0..4]);
    var out: [256:0]u16 = undefined;
    utf16Title(&title, &out);
    try std.testing.expectEqual(@as(usize, 256), std.mem.len(@as([*:0]const u16, &out)));
    try std.testing.expectEqual(@as(u16, 0xD83D), out[254]);
    try std.testing.expectEqual(@as(u16, 0xDE00), out[255]);

    // One ASCII unit first: the 128th emoji no longer fits and is dropped
    // whole rather than leaving a lone high surrogate.
    var mixed: [1 + 300 * 4]u8 = undefined;
    mixed[0] = 'x';
    @memcpy(mixed[1..], &title);
    utf16Title(&mixed, &out);
    const n = std.mem.len(@as([*:0]const u16, &out));
    try std.testing.expectEqual(@as(usize, 255), n);
    try std.testing.expectEqual(@as(u16, 0xDE00), out[254]);
    const back = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, out[0..n]);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqual(@as(usize, 1 + 127 * 4), back.len);
}

test "utf16Title: short, empty and invalid input" {
    var out: [256:0]u16 = undefined;
    utf16Title("h\u{e9}", &out);
    try std.testing.expectEqualSlices(u16, &.{ 'h', 0xE9, 0 }, out[0..3]);
    utf16Title("", &out);
    try std.testing.expectEqual(@as(u16, 0), out[0]);
    utf16Title("ok\xff", &out);
    try std.testing.expectEqual(@as(u16, 0), out[0]);
}
