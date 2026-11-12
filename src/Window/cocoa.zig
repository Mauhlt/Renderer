//! macOS window backend (AppKit), on the owner's MacOS bindings (../MacOS:
//! libobjc, AppKit, QuartzCore loaded with dlopen, so no SDK is needed to
//! build). Surface: a CAMetalLayer on the content view, for
//! VK_EXT_metal_surface (MoltenVK).
//!
//! Event driven: waitEvents blocks in nextEventMatchingMask (untilDate =
//! distantFuture for `forever`, else the caller's deadline). wake() posts an
//! application-defined NSEvent from any thread (postEvent:atStart: is
//! thread safe), coalesced with an atomic flag. Close, resize and backing
//! scale changes come from a real NSWindowDelegate subclass registered with
//! objc_allocateClassPair; during a live resize AppKit runs its own tracking
//! loop inside sendEvent, and windowDidResize: then runs the live callback
//! (as WM_SIZE does on Win32), so no timer is needed here.
//!
//! All AppKit calls (everything but wake) must happen on the main thread.
//!
//! STATUS: compile-checked by cross-compilation (aarch64-macos) only;
//! never run.

const std = @import("std");
const Mac = @import("MacOS");
const OBJC = Mac.OBJC;
const APPKIT = Mac.APPKIT;
const TY = Mac.TYPES;
const root = @import("root.zig");

const Object = OBJC.Object;
const msgSend = OBJC.msgSend;
const sel = OBJC.sel;
const Event = root.Event;
const Key = root.Key;
const Mods = root.Mods;

const delegate_class_name = "RendererWindowDelegate";
const self_ivar = "renderer_window";
/// NSEvent subtype marking our wake event.
const wake_subtype: i16 = 0x5257; // "RW"
const NSUTF8StringEncoding: TY.NSUInteger = 4;

var launched = false;

pub const Window = struct {
    gpa: std.mem.Allocator,
    queue: root.Queue = .{},
    app: *APPKIT.Application,
    window: *APPKIT.Window,
    view: *APPKIT.View,
    layer: *APPKIT.MetalLayer,
    delegate: *Object,
    width: u32 = 0,
    height: u32 = 0,
    backing: f64 = 1,
    live_ctx: ?*anyopaque = null,
    live_fn: ?root.LiveFn = null,
    wake_pending: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, title: []const u8, width: u32, height: u32) !*Window {
        OBJC.load() catch return error.AppKitUnavailable;
        const pool = OBJC.AutoreleasePool.push();
        defer pool.pop();
        const app = APPKIT.Application.shared();
        if (!launched) {
            _ = app.setActivationPolicy(.regular);
            app.finishLaunching();
            launched = true;
        }
        const window = APPKIT.Window.create(.init(0, 0, @floatFromInt(width), @floatFromInt(height)), .standard) orelse
            return error.CreateWindowFailed;
        errdefer OBJC.release(window);
        var buf: [512]u8 = undefined;
        window.setTitle(root.titleZ(title, &buf).ptr);
        window.center();
        const view = window.contentView() orelse return error.CreateWindowFailed;
        const layer = view.useMetalLayer() orelse return error.NoMetal;

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const delegate = msgSend(?*Object, delegateClass(), sel("new"), .{}) orelse return error.OutOfMemory;
        OBJC.ivarPtr(?*Window, delegate, self_ivar).* = self;
        self.* = .{
            .gpa = gpa,
            .app = app,
            .window = window,
            .view = view,
            .layer = layer,
            .delegate = delegate,
            .backing = window.backingScaleFactor(),
        };
        window.setDelegate(delegate);
        window.makeKeyAndOrderFront();
        app.activate();
        self.updateSize(false);
        return self;
    }

    pub fn deinit(self: *Window) void {
        const pool = OBJC.AutoreleasePool.push();
        defer pool.pop();
        self.window.setDelegate(null);
        OBJC.ivarPtr(?*Window, self.delegate, self_ivar).* = null;
        OBJC.release(self.delegate);
        self.window.close();
        OBJC.release(self.window);
        self.gpa.destroy(self);
    }

    pub fn setLiveCallback(self: *Window, ctx: *anyopaque, f: root.LiveFn) void {
        self.live_ctx = ctx;
        self.live_fn = f;
    }

    pub fn pollEvent(self: *Window) ?Event {
        if (self.queue.pop()) |e| return e;
        self.pump(0);
        return self.queue.pop();
    }

    pub fn pollQueued(self: *Window) ?Event {
        return self.queue.pop();
    }

    pub fn waitEvents(self: *Window, timeout_ms: u32) void {
        if (self.queue.pending()) return;
        self.pump(timeout_ms);
    }

    /// Any thread. Posts one application-defined event; further wakes are
    /// dropped until the main thread dequeues it (the flag is cleared then,
    /// before the host looks at its state again, so no wake is lost).
    pub fn wake(self: *Window) void {
        if (self.wake_pending.swap(true, .acq_rel)) return;
        const pool = OBJC.AutoreleasePool.push();
        defer pool.pop();
        // +[NSEvent otherEventWithType:location:modifierFlags:timestamp:
        //   windowNumber:context:subtype:data1:data2:] takes 9 arguments,
        // more than OBJC.msgSend supports, so objc_msgSend is cast here.
        const F = fn (?*Object, *OBJC.Selector, TY.NSUInteger, TY.NSPoint, TY.NSUInteger, f64, TY.NSInteger, ?*Object, i16, TY.NSInteger, TY.NSInteger) callconv(.c) ?*Object;
        const f: *const F = @ptrCast(OBJC.api().objc_msgSend.?);
        const ev = f(
            @ptrCast(OBJC.getClass("NSEvent")),
            sel("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"),
            @backingInt(TY.EventType.application_defined),
            .{},
            0,
            0,
            0,
            null,
            wake_subtype,
            0,
            0,
        ) orelse {
            self.wake_pending.store(false, .release);
            return;
        };
        msgSend(void, self.app, sel("postEvent:atStart:"), .{ ev, OBJC.NO });
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        return .{ self.width, self.height };
    }

    pub fn scale(self: *const Window) f32 {
        return @floatCast(self.backing);
    }

    pub fn surfaceSource(self: *const Window) root.SurfaceSource {
        return .{ .metal = .{ .layer = @ptrCast(self.layer) } };
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const pool = OBJC.AutoreleasePool.push();
        defer pool.pop();
        var buf: [512]u8 = undefined;
        self.window.setTitle(root.titleZ(title, &buf).ptr);
    }

    pub fn hide(self: *Window) void {
        self.window.orderOut();
    }

    // --------------------------------------------------------------- loop

    fn pump(self: *Window, timeout_ms: u32) void {
        const pool = OBJC.AutoreleasePool.push();
        defer pool.pop();
        const date_cls = OBJC.getClass("NSDate");
        // Only the first dequeue waits; the rest drain what is queued.
        var until: *Object = if (timeout_ms == root.forever)
            @ptrCast(APPKIT.Date.distantFuture())
        else if (timeout_ms == 0)
            @ptrCast(APPKIT.Date.distantPast())
        else
            msgSend(*Object, date_cls, sel("dateWithTimeIntervalSinceNow:"), .{@as(f64, @floatFromInt(timeout_ms)) / 1000.0});
        const mode = APPKIT.defaultRunLoopMode();
        while (true) {
            const ev = msgSend(?*APPKIT.Event, self.app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), .{
                TY.event_mask_any, until, mode, OBJC.YES,
            }) orelse break;
            until = @ptrCast(APPKIT.Date.distantPast());
            if (!self.translate(ev)) self.app.sendEvent(ev);
        }
        self.app.updateWindows();
    }

    fn updateSize(self: *Window, emit: bool) void {
        const backing = self.window.backingScaleFactor();
        if (backing != self.backing) {
            self.backing = backing;
            self.layer.setContentsScale(backing);
            if (emit) self.queue.push(.{ .scale = @floatCast(backing) });
        }
        const px = self.view.convertRectToBacking(self.view.bounds());
        const w: u32 = @intFromFloat(@max(0, px.size.width));
        const h: u32 = @intFromFloat(@max(0, px.size.height));
        if (w != self.width or h != self.height) {
            self.width = w;
            self.height = h;
            if (emit) self.queue.push(.{ .resize = .{ .width = w, .height = h } });
        }
    }

    fn runLive(self: *Window) void {
        if (self.live_fn) |f| f(self.live_ctx.?);
    }

    /// Mouse position in framebuffer pixels (top-left origin), or null when
    /// outside the content view (title bar).
    fn mousePos(self: *Window, ev: *APPKIT.Event) ?[2]f32 {
        const p = ev.locationInWindow();
        const b = self.view.bounds();
        const y = b.size.height - p.y;
        if (p.x < 0 or y < 0 or p.x > b.size.width or y > b.size.height) return null;
        return .{ @floatCast(p.x * self.backing), @floatCast(y * self.backing) };
    }

    /// Returns true if the event was consumed (not forwarded to AppKit).
    fn translate(self: *Window, ev: *APPKIT.Event) bool {
        const kind = ev.kind();
        if (kind == .application_defined) {
            const subtype = msgSend(i16, ev, sel("subtype"), .{});
            if (subtype == wake_subtype) {
                self.wake_pending.store(false, .release);
                return true;
            }
            return false;
        }
        const ours = ev.window() == self.window;
        switch (kind) {
            .key_down => {
                if (!ours) return false;
                self.keyDown(ev);
                return true;
            },
            .left_mouse_down, .right_mouse_down, .other_mouse_down => {
                if (!ours) return false;
                const p = self.mousePos(ev) orelse return false;
                const button: root.MouseButton = switch (kind) {
                    .left_mouse_down => .left,
                    .right_mouse_down => .right,
                    else => if (ev.buttonNumber() == 2) .middle else return false,
                };
                self.queue.push(.{ .mouse_down = .{ .x = p[0], .y = p[1], .button = button, .mods = modsOf(ev) } });
                return false;
            },
            .left_mouse_dragged => {
                if (!ours) return false;
                const p = ev.locationInWindow();
                const b = self.view.bounds();
                self.queue.push(.{ .mouse_move = .{
                    .x = @floatCast(p.x * self.backing),
                    .y = @floatCast((b.size.height - p.y) * self.backing),
                    .left_held = true,
                } });
                return false;
            },
            .left_mouse_up => {
                if (!ours) return false;
                const p = ev.locationInWindow();
                const b = self.view.bounds();
                self.queue.push(.{ .mouse_up = .{
                    .x = @floatCast(p.x * self.backing),
                    .y = @floatCast((b.size.height - p.y) * self.backing),
                } });
                return false;
            },
            .scroll_wheel => {
                if (!ours) return false;
                const p = self.mousePos(ev) orelse return false;
                // Trackpads report pixels; ~10 per wheel notch.
                const div: f64 = if (ev.hasPreciseScrollingDeltas()) 10 else 1;
                self.queue.push(.{ .scroll = .{
                    .x = p[0],
                    .y = p[1],
                    .dx = @floatCast(-ev.scrollingDeltaX() / div),
                    .dy = @floatCast(ev.scrollingDeltaY() / div),
                    .mods = modsOf(ev),
                } });
                return true;
            },
            else => return false,
        }
    }

    fn keyDown(self: *Window, ev: *APPKIT.Event) void {
        const mods = modsOf(ev);
        const code: u16 = @backingInt(ev.keyCode());
        const key: ?Key = switch (code) {
            36, 76 => .enter, // return, keypad enter
            53 => .escape,
            51 => .backspace,
            48 => .tab,
            117 => .delete, // forward delete
            114 => .insert, // help
            123 => .left,
            124 => .right,
            125 => .down,
            126 => .up,
            115 => .home,
            119 => .end,
            116 => .page_up,
            121 => .page_down,
            122 => .f1,
            120 => .f2,
            99 => .f3,
            118 => .f4,
            96 => .f5,
            97 => .f6,
            98 => .f7,
            100 => .f8,
            101 => .f9,
            109 => .f10,
            103 => .f11,
            111 => .f12,
            else => null,
        };
        if (key) |k| return self.queue.push(.{ .key = .{ .key = k, .mods = mods } });

        const plain: []const u8 = if (ev.charactersIgnoringModifiers()) |s| std.mem.span(s.utf8() orelse "") else "";
        if (mods.super or mods.ctrl) {
            if (plain.len == 1) switch (plain[0]) {
                '=', '+' => return self.queue.push(.{ .zoom = .in }),
                '-' => return self.queue.push(.{ .zoom = .out }),
                '0' => return self.queue.push(.{ .zoom = .reset }),
                // Cmd+Q / Cmd+W close the window (there is no app menu).
                'q', 'w' => if (mods.super) return self.queue.push(.close) else if (mods.ctrl) return self.queue.push(.{ .char = .{ .cp = plain[0], .mods = mods } }),
                'a'...'p', 'r'...'v', 'x'...'z', '[', '\\', ']', ' ', '/' => if (mods.ctrl) return self.queue.push(.{ .char = .{ .cp = plain[0], .mods = mods } }),
                else => {},
            };
            return;
        }
        const str = ev.characters() orelse return;
        const text = std.mem.span(str.utf8() orelse return);
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp < 0x20 or cp == 0x7f or (cp >= 0xF700 and cp <= 0xF8FF)) continue; // function-key PUA
            self.queue.push(.{ .char = .{ .cp = cp } });
        }
    }

    // ---------------------------------------------------------- clipboard

    fn pasteboard() ?*Object {
        return msgSend(?*Object, OBJC.getClass("NSPasteboard"), sel("generalPasteboard"), .{});
    }

    fn stringType() ?*APPKIT.String {
        if (OBJC.frameworkSymbol(*APPKIT.String, "NSPasteboardTypeString")) |p| return p.*;
        return APPKIT.String.fromUtf8("public.utf8-plain-text");
    }

    pub fn clipboardText(self: *Window, gpa: std.mem.Allocator, max_units: usize) ?[]u8 {
        _ = self;
        const pool = OBJC.AutoreleasePool.push();
        defer pool.pop();
        const pb = pasteboard() orelse return null;
        const s = msgSend(?*APPKIT.String, pb, sel("stringForType:"), .{stringType() orelse return null}) orelse return null;
        const bytes = std.mem.span(s.utf8() orelse return null);
        return root.sanitizeClipboard(gpa, bytes, max_units);
    }

    pub fn setClipboardText(self: *Window, utf8: []const u8) bool {
        _ = self;
        const pool = OBJC.AutoreleasePool.push();
        defer pool.pop();
        const pb = pasteboard() orelse return false;
        const t = stringType() orelse return false;
        const alloc = msgSend(?*Object, OBJC.getClass("NSString"), sel("alloc"), .{}) orelse return false;
        // Nil for invalid UTF-8.
        const ns = msgSend(?*Object, alloc, sel("initWithBytes:length:encoding:"), .{
            @as([*]const u8, utf8.ptr), @as(TY.NSUInteger, utf8.len), NSUTF8StringEncoding,
        }) orelse return false;
        defer OBJC.release(ns);
        _ = msgSend(TY.NSInteger, pb, sel("clearContents"), .{});
        return msgSend(OBJC.BOOL, pb, sel("setString:forType:"), .{ ns, t }) != 0;
    }
};

fn modsOf(ev: *APPKIT.Event) Mods {
    const f = ev.modifierFlags();
    return .{ .ctrl = f.control, .shift = f.shift, .alt = f.option, .super = f.command };
}

// ------------------------------------------------------------- delegate

fn windowOf(obj: *Object) ?*Window {
    return OBJC.ivarPtr(?*Window, obj, self_ivar).*;
}

const DelegateImpl = struct {
    fn shouldClose(obj: *Object, _: *OBJC.Selector, _: ?*Object) callconv(.c) OBJC.BOOL {
        // The host decides: report a close and keep the window.
        if (windowOf(obj)) |w| w.queue.push(.close);
        return OBJC.NO;
    }
    fn didResize(obj: *Object, _: *OBJC.Selector, _: ?*Object) callconv(.c) void {
        const w = windowOf(obj) orelse return;
        w.updateSize(true);
        // Inside AppKit's live-resize tracking loop our own loop is not
        // running: redraw from here, as Win32 does from WM_SIZE.
        if (msgSend(OBJC.BOOL, w.window, sel("inLiveResize"), .{}) != 0) w.runLive();
    }
    fn didChangeBacking(obj: *Object, _: *OBJC.Selector, _: ?*Object) callconv(.c) void {
        const w = windowOf(obj) orelse return;
        w.updateSize(true);
    }
};

fn delegateClass() *OBJC.Class {
    if (OBJC.lookUpClassUncached(delegate_class_name)) |cls| return cls;
    const b = OBJC.ClassBuilder.begin(OBJC.getClass("NSObject"), delegate_class_name) orelse
        return OBJC.lookUpClassUncached(delegate_class_name).?;
    _ = b.addIvar(self_ivar, ?*Window, "^v");
    _ = b.addMethod("windowShouldClose:", &DelegateImpl.shouldClose, "c@:@");
    _ = b.addMethod("windowDidResize:", &DelegateImpl.didResize, "v@:@");
    _ = b.addMethod("windowDidChangeBackingProperties:", &DelegateImpl.didChangeBacking, "v@:@");
    return b.register();
}
