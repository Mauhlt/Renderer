//! Wayland window backend (Linux), on the owner's Wayland bindings
//! (../Wayland: libwayland-client and libxkbcommon via dlopen). No X11.
//!
//!   window      xdg-shell toplevel; server-side decorations through
//!               xdg-decoration when the compositor offers it (GNOME does
//!               not: there the window has no title bar)
//!   scale       wl_surface.preferred_buffer_scale (v6) or the largest
//!               wl_output scale among the outputs the surface is on;
//!               integer scales only (no wp_fractional_scale yet)
//!   keyboard    wl_keyboard + xkbcommon; key repeat from repeat_info on a
//!               timerfd (a deadline in the same poll, not a tick)
//!   pointer     wl_pointer: buttons, drags, wheel (value120 / discrete /
//!               continuous axis)
//!   clipboard   wl_data_device (local shim in wl_data.zig)
//!   wake        an eventfd in the same poll as the display socket
//!
//! Event driven: waitEvents is one poll(2) on the display fd, the wake
//! eventfd and the repeat timerfd, using libwayland's prepare_read /
//! read_events protocol, with the caller's timeout (or none).
//!
//! STATUS: compile-checked by cross-compilation (x86_64-linux-gnu) only;
//! never run.

const std = @import("std");
const linux = std.os.linux;
const Wl = @import("Wayland");
const WL = Wl.WL;
const XDG = Wl.XDG;
const DECOR = Wl.DECOR;
const XKB = Wl.XKB;
const data = @import("wl_data.zig");
const root = @import("root.zig");

const Event = root.Event;
const Key = root.Key;
const Mods = root.Mods;

const max_outputs = 16;
const max_offers = 8;

const OutputSlot = struct {
    win: *Window = undefined,
    output: ?*WL.Output = null,
    name: u32 = 0,
    scale: i32 = 1,
    entered: bool = false,
};

const OfferSlot = struct {
    offer: ?*data.DataOffer = null,
    /// Best text type offered: 3 = text/plain;charset=utf-8, 2 = UTF8_STRING,
    /// 1 = text/plain, 0 = none.
    rank: u8 = 0,
};

const mime_by_rank = [_]?[*:0]const u8{ null, "text/plain", "UTF8_STRING", "text/plain;charset=utf-8" };

pub const Window = struct {
    gpa: std.mem.Allocator,
    queue: root.Queue = .{},
    display: *WL.Display,
    registry: ?*WL.Registry = null,
    compositor: ?*WL.Compositor = null,
    wm_base: ?*XDG.WmBase = null,
    seat: ?*WL.Seat = null,
    deco_manager: ?*DECOR.Manager = null,
    ddm: ?*data.DataDeviceManager = null,
    outputs: [max_outputs]OutputSlot = @splat(.{}),

    surface: ?*WL.Surface = null,
    xdg_surface: ?*XDG.Surface = null,
    toplevel: ?*XDG.Toplevel = null,
    decoration: ?*DECOR.ToplevelDecoration = null,
    keyboard: ?*WL.Keyboard = null,
    pointer: ?*WL.Pointer = null,
    data_device: ?*data.DataDevice = null,

    xkb_ctx: ?*XKB.Context = null,
    keymap: ?*XKB.Keymap = null,
    xkb_state: ?*XKB.State = null,

    /// Surface size in logical units (the framebuffer is this times buffer_scale).
    width: i32,
    height: i32,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    configured: bool = false,
    buffer_scale: i32 = 1,
    preferred_scale: ?i32 = null,

    ptr_x: f64 = 0,
    ptr_y: f64 = 0,
    left_held: bool = false,
    scroll_value: [2]f64 = .{ 0, 0 },
    scroll_v120: [2]i32 = .{ 0, 0 },
    scroll_any: bool = false,

    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_key: ?u32 = null,
    timer_fd: i32 = -1,
    wake_fd: i32 = -1,
    /// Latest input serial (selection requests must carry one).
    serial: u32 = 0,
    /// The compositor connection failed; only the wake fd is polled.
    dead: bool = false,

    offers: [max_offers]OfferSlot = @splat(.{}),
    selection: ?*data.DataOffer = null,
    dnd_offer: ?*data.DataOffer = null,
    own_source: ?*data.DataSource = null,
    own_text: ?[]u8 = null,

    live_ctx: ?*anyopaque = null,
    live_fn: ?root.LiveFn = null,

    pub fn init(gpa: std.mem.Allocator, title: []const u8, width: u32, height: u32) !*Window {
        const display = WL.Display.connect(null) catch return error.WaylandUnavailable;
        errdefer display.disconnect();
        XKB.load() catch return error.XkbcommonUnavailable;
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .display = display,
            .width = @intCast(@max(1, width)),
            .height = @intCast(@max(1, height)),
        };
        for (&self.outputs) |*o| o.win = self;
        errdefer self.destroyObjects();

        self.xkb_ctx = XKB.Context.new() orelse return error.XkbcommonUnavailable;
        self.wake_fd = try sysFd(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        self.timer_fd = try sysFd(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }));

        const registry = try display.getRegistry();
        self.registry = registry;
        registry.setListener(*Window, onGlobal, self);
        _ = display.roundtrip() catch return error.WaylandDisconnected;
        // Seat capabilities and output scales arrive after binding.
        _ = display.roundtrip() catch return error.WaylandDisconnected;
        const compositor = self.compositor orelse return error.NoCompositor;
        const wm_base = self.wm_base orelse return error.NoXdgShell;

        const surface = try compositor.createSurface();
        self.surface = surface;
        surface.setListener(*Window, onSurface, self);
        const xs = try wm_base.getXdgSurface(surface);
        self.xdg_surface = xs;
        xs.setListener(*Window, onXdgSurface, self);
        const tl = try xs.getToplevel();
        self.toplevel = tl;
        tl.setListener(*Window, onToplevel, self);
        var buf: [512]u8 = undefined;
        tl.setTitle(root.titleZ(title, &buf).ptr);
        if (self.deco_manager) |dm| {
            const d = try dm.getToplevelDecoration(tl);
            self.decoration = d;
            d.setMode(.server_side);
        }
        if (self.seat) |seat| if (self.ddm) |m| {
            const dd = try m.getDataDevice(seat);
            self.data_device = dd;
            dd.setListener(*Window, onDataDevice, self);
        };
        surface.commit();
        // The first configure says the size; the window maps on the first
        // presented frame. dispatch() blocks on the socket.
        while (!self.configured) _ = display.dispatch() catch return error.WaylandDisconnected;
        return self;
    }

    pub fn deinit(self: *Window) void {
        self.destroyObjects();
        self.display.disconnect();
        self.gpa.destroy(self);
    }

    fn destroyObjects(self: *Window) void {
        self.stopRepeat();
        if (self.own_source) |s| s.destroy();
        self.own_source = null;
        if (self.own_text) |t| self.gpa.free(t);
        self.own_text = null;
        for (&self.offers) |*o| if (o.offer) |of| {
            of.destroy();
            o.* = .{};
        };
        self.selection = null;
        self.dnd_offer = null;
        if (self.data_device) |d| d.release();
        if (self.keyboard) |k| k.release();
        if (self.pointer) |p| p.release();
        if (self.xkb_state) |s| s.unref();
        if (self.keymap) |k| k.unref();
        if (self.xkb_ctx) |c| c.unref();
        if (self.decoration) |d| d.destroy();
        if (self.toplevel) |t| t.destroy();
        if (self.xdg_surface) |s| s.destroy();
        if (self.surface) |s| s.destroy();
        for (&self.outputs) |*o| if (o.output) |out| {
            out.release();
            o.output = null;
        };
        if (self.ddm) |m| m.destroy();
        if (self.deco_manager) |m| m.destroy();
        if (self.seat) |s| s.release();
        if (self.wm_base) |w| w.destroy();
        if (self.compositor) |c| c.destroy();
        if (self.registry) |r| r.destroy();
        self.data_device = null;
        self.keyboard = null;
        self.pointer = null;
        self.xkb_state = null;
        self.keymap = null;
        self.xkb_ctx = null;
        self.decoration = null;
        self.toplevel = null;
        self.xdg_surface = null;
        self.surface = null;
        self.ddm = null;
        self.deco_manager = null;
        self.seat = null;
        self.wm_base = null;
        self.compositor = null;
        self.registry = null;
        _ = self.display.flush() catch {};
        if (self.wake_fd >= 0) _ = linux.close(self.wake_fd);
        if (self.timer_fd >= 0) _ = linux.close(self.timer_fd);
        self.wake_fd = -1;
        self.timer_fd = -1;
    }

    pub fn setLiveCallback(self: *Window, ctx: *anyopaque, f: root.LiveFn) void {
        // Wayland has no modal resize loop: the app keeps running its own
        // loop during a resize, so the hook is stored but never needed.
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

    /// Any thread. The eventfd counter coalesces any number of wakes into
    /// one readable state.
    pub fn wake(self: *Window) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), 8);
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        return .{ @intCast(self.width * self.buffer_scale), @intCast(self.height * self.buffer_scale) };
    }

    pub fn scale(self: *const Window) f32 {
        return @floatFromInt(self.buffer_scale);
    }

    pub fn surfaceSource(self: *const Window) root.SurfaceSource {
        return .{ .wayland = .{ .display = @ptrCast(self.display), .surface = @ptrCast(self.surface.?) } };
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        var buf: [512]u8 = undefined;
        if (self.toplevel) |t| t.setTitle(root.titleZ(title, &buf).ptr);
        _ = self.display.flush() catch {};
    }

    /// Unmaps the toplevel (a null buffer). The next presented frame would
    /// map it again.
    pub fn hide(self: *Window) void {
        const s = self.surface orelse return;
        s.attach(null, 0, 0);
        s.commit();
        _ = self.display.flush() catch {};
    }

    // --------------------------------------------------------------- loop

    /// One round of the libwayland read protocol plus our fds, waiting at
    /// most `timeout_ms` (`root.forever`: no limit).
    fn pump(self: *Window, timeout_ms: u32) void {
        const d = self.display;
        const t: i32 = if (timeout_ms == root.forever) -1 else @intCast(@min(timeout_ms, std.math.maxInt(i32)));
        if (self.dead) {
            var fds = [_]linux.pollfd{
                .{ .fd = self.wake_fd, .events = linux.POLL.IN },
            };
            _ = linux.poll(&fds, fds.len, t);
            if (fds[0].revents & linux.POLL.IN != 0) drain(self.wake_fd);
            return;
        }
        // Events already read but not dispatched must be dispatched before
        // waiting, or the wait could sleep on work that is already here.
        while (!d.prepareRead()) {
            _ = d.dispatchPending() catch return self.fail();
        }
        const wait = if (self.queue.pending()) 0 else t;
        _ = d.flush() catch {};
        var fds = [_]linux.pollfd{
            .{ .fd = d.getFd(), .events = linux.POLL.IN },
            .{ .fd = self.wake_fd, .events = linux.POLL.IN },
            .{ .fd = self.timer_fd, .events = linux.POLL.IN },
        };
        const rc = linux.poll(&fds, fds.len, wait);
        const polled = linux.errno(rc) == .SUCCESS;
        if (polled and fds[0].revents & (linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP) != 0) {
            d.readEvents() catch return self.fail();
        } else d.cancelRead();
        _ = d.dispatchPending() catch return self.fail();
        if (!polled) return;
        if (fds[1].revents & linux.POLL.IN != 0) drain(self.wake_fd);
        if (fds[2].revents & linux.POLL.IN != 0) {
            var n: u64 = 0;
            if (linux.errno(linux.read(self.timer_fd, std.mem.asBytes(&n), 8)) == .SUCCESS) {
                if (self.repeat_key) |code| {
                    var i: u64 = 0;
                    while (i < @min(n, 32)) : (i += 1) self.emitKey(code);
                }
            }
        }
        _ = d.flush() catch {};
    }

    fn fail(self: *Window) void {
        // The compositor went away (or a protocol error): report a close
        // once; later waits only watch the wake fd.
        self.dead = true;
        self.stopRepeat();
        self.queue.push(.close);
    }

    // ------------------------------------------------------------ globals

    fn onGlobal(reg: *WL.Registry, ev: WL.Registry.Event, self: *Window) void {
        switch (ev) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (eql(name, "wl_compositor")) {
                    if (self.compositor == null) self.compositor = reg.bind(g.name, WL.Compositor, g.version) catch null;
                } else if (eql(name, "xdg_wm_base")) {
                    if (self.wm_base == null) {
                        self.wm_base = reg.bind(g.name, XDG.WmBase, g.version) catch null;
                        if (self.wm_base) |w| w.setListener(void, onPing, {});
                    }
                } else if (eql(name, "wl_seat")) {
                    if (self.seat == null) {
                        self.seat = reg.bind(g.name, WL.Seat, g.version) catch null;
                        if (self.seat) |s| s.setListener(*Window, onSeat, self);
                    }
                } else if (eql(name, "zxdg_decoration_manager_v1")) {
                    if (self.deco_manager == null) self.deco_manager = reg.bind(g.name, DECOR.Manager, g.version) catch null;
                } else if (eql(name, "wl_data_device_manager")) {
                    if (self.ddm == null) self.ddm = reg.bind(g.name, data.DataDeviceManager, g.version) catch null;
                } else if (eql(name, "wl_output")) {
                    for (&self.outputs) |*slot| if (slot.output == null) {
                        const out = reg.bind(g.name, WL.Output, g.version) catch return;
                        slot.* = .{ .win = self, .output = out, .name = g.name };
                        out.setListener(*OutputSlot, onOutput, slot);
                        break;
                    };
                }
            },
            .global_remove => |r| {
                for (&self.outputs) |*slot| if (slot.output != null and slot.name == r.name) {
                    slot.output.?.release();
                    slot.* = .{ .win = self };
                    self.updateScale();
                };
            },
        }
    }

    fn onPing(wm: *XDG.WmBase, ev: XDG.WmBase.Event, _: void) void {
        wm.pong(ev.ping.serial);
    }

    fn onOutput(_: *WL.Output, ev: WL.Output.Event, slot: *OutputSlot) void {
        switch (ev) {
            .scale => |s| slot.scale = @max(1, s.factor),
            .done => slot.win.updateScale(),
            else => {},
        }
    }

    fn onSurface(_: *WL.Surface, ev: WL.Surface.Event, self: *Window) void {
        switch (ev) {
            .enter => |e| self.outputEntered(e.output, true),
            .leave => |e| self.outputEntered(e.output, false),
            .preferred_buffer_scale => |p| {
                self.preferred_scale = @max(1, p.factor);
                self.updateScale();
            },
            .preferred_buffer_transform => {},
        }
    }

    fn outputEntered(self: *Window, output: ?*WL.Output, entered: bool) void {
        for (&self.outputs) |*slot| if (slot.output != null and slot.output == output) {
            slot.entered = entered;
        };
        self.updateScale();
    }

    fn updateScale(self: *Window) void {
        const surface = self.surface orelse return;
        var s: i32 = 0;
        if (self.preferred_scale) |p| s = p else for (self.outputs) |o| {
            if (o.output != null and o.entered) s = @max(s, o.scale);
        }
        if (s == 0 or s == self.buffer_scale) return;
        // wl_surface.set_buffer_scale is version 3.
        if (Wl.CLIENT.version(surface) < 3) return;
        self.buffer_scale = s;
        surface.setBufferScale(s);
        self.queue.push(.{ .scale = @floatFromInt(s) });
        const fb = self.framebufferSize();
        self.queue.push(.{ .resize = .{ .width = fb[0], .height = fb[1] } });
    }

    fn onXdgSurface(xs: *XDG.Surface, ev: XDG.Surface.Event, self: *Window) void {
        xs.ackConfigure(ev.configure.serial);
        var changed = false;
        if (self.pending_width > 0 and self.pending_height > 0 and
            (self.pending_width != self.width or self.pending_height != self.height))
        {
            self.width = self.pending_width;
            self.height = self.pending_height;
            changed = true;
        }
        if (changed or !self.configured) {
            const fb = self.framebufferSize();
            self.queue.push(.{ .resize = .{ .width = fb[0], .height = fb[1] } });
        }
        self.configured = true;
        // Draw now: the compositor waits for a commit after the ack.
        self.queue.push(.expose);
    }

    fn onToplevel(_: *XDG.Toplevel, ev: XDG.Toplevel.Event, self: *Window) void {
        switch (ev) {
            .configure => |c| {
                self.pending_width = c.width;
                self.pending_height = c.height;
            },
            .close => self.queue.push(.close),
            else => {},
        }
    }

    fn onSeat(seat: *WL.Seat, ev: WL.Seat.Event, self: *Window) void {
        switch (ev) {
            .capabilities => |caps| {
                if (caps.keyboard and self.keyboard == null) {
                    self.keyboard = seat.getKeyboard() catch null;
                    if (self.keyboard) |k| k.setListener(*Window, onKeyboard, self);
                } else if (!caps.keyboard) if (self.keyboard) |k| {
                    self.stopRepeat();
                    k.release();
                    self.keyboard = null;
                };
                if (caps.pointer and self.pointer == null) {
                    self.pointer = seat.getPointer() catch null;
                    if (self.pointer) |p| p.setListener(*Window, onPointer, self);
                } else if (!caps.pointer) if (self.pointer) |p| {
                    p.release();
                    self.pointer = null;
                };
            },
            .name => {},
        }
    }

    // ----------------------------------------------------------- keyboard

    fn onKeyboard(_: *WL.Keyboard, ev: WL.Keyboard.Event, self: *Window) void {
        switch (ev) {
            .keymap => |k| {
                defer _ = linux.close(k.fd);
                if (k.format != .xkb_v1) return;
                const ctx = self.xkb_ctx orelse return;
                const km = XKB.Keymap.fromFd(ctx, k.fd, k.size) catch return;
                const st = XKB.State.new(km) orelse {
                    km.unref();
                    return;
                };
                if (self.xkb_state) |s| s.unref();
                if (self.keymap) |old| old.unref();
                self.keymap = km;
                self.xkb_state = st;
            },
            .enter => |e| self.serial = e.serial,
            .leave => self.stopRepeat(),
            .key => |k| {
                self.serial = k.serial;
                switch (k.state) {
                    .pressed => {
                        self.emitKey(k.key);
                        const km = self.keymap orelse return;
                        if (self.repeat_rate > 0 and km.keyRepeats(k.key + XKB.evdev_offset)) {
                            self.startRepeat(k.key);
                        } else self.stopRepeat();
                    },
                    .released => if (self.repeat_key == k.key) self.stopRepeat(),
                    else => {},
                }
            },
            .modifiers => |m| {
                if (self.xkb_state) |s| _ = s.updateMask(m.depressed, m.latched, m.locked, 0, 0, m.group);
            },
            .repeat_info => |r| {
                self.repeat_rate = r.rate;
                self.repeat_delay = r.delay;
                if (r.rate <= 0) self.stopRepeat();
            },
        }
    }

    fn startRepeat(self: *Window, code: u32) void {
        self.repeat_key = code;
        const interval_ns: i64 = @divTrunc(1_000_000_000, @max(1, self.repeat_rate));
        const delay_ns: i64 = @as(i64, @max(1, self.repeat_delay)) * 1_000_000;
        const spec: linux.itimerspec = .{
            .it_value = nsToTimespec(delay_ns),
            .it_interval = nsToTimespec(interval_ns),
        };
        _ = linux.timerfd_settime(self.timer_fd, .{ .ABSTIME = false }, &spec, null);
    }

    fn stopRepeat(self: *Window) void {
        if (self.repeat_key == null) return;
        self.repeat_key = null;
        const zero: linux.itimerspec = .{ .it_value = nsToTimespec(0), .it_interval = nsToTimespec(0) };
        if (self.timer_fd >= 0) _ = linux.timerfd_settime(self.timer_fd, .{ .ABSTIME = false }, &zero, null);
    }

    fn mods(self: *Window) Mods {
        const s = self.xkb_state orelse return .{};
        const eff: XKB.StateComponent = .{ .mods_effective = true };
        return .{
            .ctrl = s.modNameIsActive(XKB.MOD_NAME_CTRL, eff),
            .shift = s.modNameIsActive(XKB.MOD_NAME_SHIFT, eff),
            .alt = s.modNameIsActive(XKB.MOD_NAME_ALT, eff),
            .super = s.modNameIsActive(XKB.MOD_NAME_LOGO, eff),
        };
    }

    /// Same semantics as the Win32 backend: named keys as `.key`, Ctrl+key
    /// as the lowercase character with `mods.ctrl` (or a zoom), text as
    /// `.char` (Alt-modified text with `mods.alt`).
    fn emitKey(self: *Window, code: u32) void {
        const st = self.xkb_state orelse return;
        const kc = code + XKB.evdev_offset;
        const sym: u32 = @backingInt(st.keyGetOneSym(kc));
        const m = self.mods();
        if (keyFromSym(sym)) |k| {
            self.queue.push(.{ .key = .{ .key = k, .mods = m } });
            return;
        }
        if (m.ctrl and !m.alt) {
            switch (sym) {
                '=', '+', 0xffab => self.queue.push(.{ .zoom = .in }), // KP_Add
                '-', 0xffad => self.queue.push(.{ .zoom = .out }), // KP_Subtract
                '0', 0xffb0 => self.queue.push(.{ .zoom = .reset }), // KP_0
                'a'...'z', '[', '\\', ']', ' ', '/' => self.queue.push(.{ .char = .{ .cp = @intCast(sym), .mods = m } }),
                'A'...'Z' => self.queue.push(.{ .char = .{ .cp = @intCast(sym + 32), .mods = m } }),
                else => {},
            }
            return;
        }
        var buf: [64]u8 = undefined;
        const text = st.keyGetUtf8(kc, &buf);
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp < 0x20 or cp == 0x7f) continue;
            self.queue.push(.{ .char = .{ .cp = cp, .mods = if (m.alt) .{ .alt = true } else .{} } });
        }
    }

    // ------------------------------------------------------------ pointer

    fn pos(self: *const Window) [2]f32 {
        const s: f64 = @floatFromInt(self.buffer_scale);
        return .{ @floatCast(self.ptr_x * s), @floatCast(self.ptr_y * s) };
    }

    fn onPointer(p: *WL.Pointer, ev: WL.Pointer.Event, self: *Window) void {
        switch (ev) {
            .enter => |e| {
                self.serial = e.serial;
                self.ptr_x = e.x.toFloat();
                self.ptr_y = e.y.toFloat();
            },
            .leave => {},
            .motion => |mo| {
                self.ptr_x = mo.x.toFloat();
                self.ptr_y = mo.y.toFloat();
                if (self.left_held) {
                    const xy = self.pos();
                    self.queue.push(.{ .mouse_move = .{ .x = xy[0], .y = xy[1], .left_held = true } });
                }
            },
            .button => |b| {
                self.serial = b.serial;
                const xy = self.pos();
                const button: root.MouseButton = switch (b.button) {
                    WL.BTN_LEFT => .left,
                    WL.BTN_RIGHT => .right,
                    WL.BTN_MIDDLE => .middle,
                    else => return,
                };
                switch (b.state) {
                    .pressed => {
                        if (button == .left) self.left_held = true;
                        self.queue.push(.{ .mouse_down = .{ .x = xy[0], .y = xy[1], .button = button, .mods = self.mods() } });
                    },
                    .released => if (button == .left) {
                        self.left_held = false;
                        self.queue.push(.{ .mouse_up = .{ .x = xy[0], .y = xy[1] } });
                    },
                    _ => {},
                }
            },
            .axis => |a| {
                const i = axisIndex(a.axis) orelse return;
                self.scroll_value[i] += a.value.toFloat();
                self.scroll_any = true;
                // Before v5 there is no frame event: report each axis event.
                if (Wl.CLIENT.version(p) < 5) self.flushScroll();
            },
            .axis_discrete => |a| {
                const i = axisIndex(a.axis) orelse return;
                self.scroll_v120[i] += a.discrete * 120;
                self.scroll_any = true;
            },
            .axis_value120 => |a| {
                const i = axisIndex(a.axis) orelse return;
                // value120 replaces axis_discrete from v8; never both.
                self.scroll_v120[i] += a.value120;
                self.scroll_any = true;
            },
            .frame => self.flushScroll(),
            .axis_source, .axis_stop, .axis_relative_direction => {},
        }
    }

    fn flushScroll(self: *Window) void {
        if (!self.scroll_any) return;
        var notches: [2]f32 = undefined;
        for (0..2) |i| {
            // Wayland axis values grow downwards / rightwards; continuous
            // values are ~10 surface units per wheel detent.
            notches[i] = if (self.scroll_v120[i] != 0)
                @as(f32, @floatFromInt(self.scroll_v120[i])) / 120.0
            else
                @floatCast(self.scroll_value[i] / 10.0);
        }
        const xy = self.pos();
        if (notches[0] != 0 or notches[1] != 0) self.queue.push(.{ .scroll = .{
            .x = xy[0],
            .y = xy[1],
            .dx = notches[1],
            .dy = -notches[0],
            .mods = self.mods(),
        } });
        self.scroll_value = .{ 0, 0 };
        self.scroll_v120 = .{ 0, 0 };
        self.scroll_any = false;
    }

    // ---------------------------------------------------------- clipboard

    fn offerSlot(self: *Window, offer: *data.DataOffer) ?*OfferSlot {
        for (&self.offers) |*o| if (o.offer == offer) return o;
        return null;
    }

    fn dropOffer(self: *Window, offer: *data.DataOffer) void {
        if (self.offerSlot(offer)) |o| o.* = .{};
        offer.destroy();
    }

    fn onDataDevice(_: *data.DataDevice, ev: data.DataDevice.Event, self: *Window) void {
        switch (ev) {
            .data_offer => |o| {
                const offer = o.id orelse return;
                offer.setListener(*Window, onDataOffer, self);
                for (&self.offers) |*slot| if (slot.offer == null) {
                    slot.* = .{ .offer = offer };
                    return;
                };
                // Table full: an untracked offer is destroyed when it is
                // replaced as the selection or its drag ends, as usual.
            },
            .enter => |e| {
                // Drag and drop is not supported: leave the offer unaccepted.
                self.serial = e.serial;
                self.dnd_offer = e.id;
            },
            .leave, .drop => {
                if (self.dnd_offer) |o| if (o != self.selection) self.dropOffer(o);
                self.dnd_offer = null;
            },
            .motion => {},
            .selection => |s| {
                if (self.selection) |old| if (old != s.id) self.dropOffer(old);
                self.selection = s.id;
            },
        }
    }

    fn onDataOffer(offer: *data.DataOffer, ev: data.DataOffer.Event, self: *Window) void {
        switch (ev) {
            .offer => |o| {
                const slot = self.offerSlot(offer) orelse return;
                const mime = std.mem.span(o.mime_type);
                const rank: u8 = if (eql(mime, "text/plain;charset=utf-8"))
                    3
                else if (eql(mime, "UTF8_STRING"))
                    2
                else if (eql(mime, "text/plain"))
                    1
                else
                    0;
                slot.rank = @max(slot.rank, rank);
            },
            else => {},
        }
    }

    /// The clipboard's text, read from its owner through a pipe (bounded
    /// by `max_units` and a 2 s deadline in case the owner never writes).
    pub fn clipboardText(self: *Window, gpa: std.mem.Allocator, max_units: usize) ?[]u8 {
        // Our own selection: reading it through the compositor would wait
        // on ourselves (we serve `send` on this same thread).
        if (self.own_source != null) if (self.own_text) |t| return root.sanitizeClipboard(gpa, t, max_units);
        const offer = self.selection orelse return null;
        const rank = if (self.offerSlot(offer)) |s| s.rank else 3;
        const mime = mime_by_rank[rank] orelse return null;
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
        defer _ = linux.close(fds[0]);
        offer.receive(mime, fds[1]);
        _ = self.display.flush() catch {};
        _ = linux.close(fds[1]);

        const cap = max_units * 3 + 4; // UTF-8 bytes for max_units UTF-16 units
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var waited: i32 = 0;
        while (buf.items.len < cap and waited < 2000) {
            var pfd = [_]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN }};
            const step: i32 = 100;
            const prc = linux.poll(&pfd, 1, step);
            if (linux.errno(prc) != .SUCCESS) break;
            if (prc == 0) {
                waited += step;
                continue;
            }
            var chunk: [4096]u8 = undefined;
            const want = @min(chunk.len, cap - buf.items.len);
            const n = linux.read(fds[0], &chunk, want);
            if (linux.errno(n) != .SUCCESS) break;
            if (n == 0) break; // EOF: the owner closed its end
            buf.appendSlice(gpa, chunk[0..n]) catch return null;
        }
        if (buf.items.len == 0) return null;
        return root.sanitizeClipboard(gpa, buf.items, max_units);
    }

    pub fn setClipboardText(self: *Window, utf8: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(utf8)) return false;
        const m = self.ddm orelse return false;
        const dd = self.data_device orelse return false;
        const text = self.gpa.dupe(u8, utf8) catch return false;
        const source = m.createDataSource() catch {
            self.gpa.free(text);
            return false;
        };
        source.offer("text/plain;charset=utf-8");
        source.offer("UTF8_STRING");
        source.offer("text/plain");
        source.setListener(*Window, onDataSource, self);
        dd.setSelection(source, self.serial);
        if (self.own_source) |old| old.destroy();
        if (self.own_text) |old| self.gpa.free(old);
        self.own_source = source;
        self.own_text = text;
        _ = self.display.flush() catch {};
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

    fn onDataSource(source: *data.DataSource, ev: data.DataSource.Event, self: *Window) void {
        switch (ev) {
            .send => |s| {
                defer _ = linux.close(s.fd);
                if (source != self.own_source) return;
                // A blocking write to the reader's pipe (SIGPIPE is ignored
                // by Zig's start code, so a vanished reader is just EPIPE).
                var rest = self.own_text orelse return;
                while (rest.len > 0) {
                    const n = linux.write(s.fd, rest.ptr, rest.len);
                    if (linux.errno(n) != .SUCCESS or n == 0) break;
                    rest = rest[n..];
                }
            },
            .cancelled => {
                if (source == self.own_source) {
                    self.own_source = null;
                    if (self.own_text) |t| self.gpa.free(t);
                    self.own_text = null;
                }
                source.destroy();
            },
            else => {},
        }
    }
};

fn keyFromSym(sym: u32) ?Key {
    return switch (sym) {
        0xff0d, 0xff8d => .enter, // Return, KP_Enter
        0xff1b => .escape,
        0xff08 => .backspace,
        0xff09, 0xfe20 => .tab, // Tab, ISO_Left_Tab (Shift+Tab)
        0xff52, 0xff97 => .up,
        0xff54, 0xff99 => .down,
        0xff51, 0xff96 => .left,
        0xff53, 0xff98 => .right,
        0xff50, 0xff95 => .home,
        0xff57, 0xff9c => .end,
        0xff55, 0xff9a => .page_up,
        0xff56, 0xff9b => .page_down,
        0xffff, 0xff9f => .delete,
        0xff63, 0xff9e => .insert,
        0xffbe => .f1,
        0xffbf => .f2,
        0xffc0 => .f3,
        0xffc1 => .f4,
        0xffc2 => .f5,
        0xffc3 => .f6,
        0xffc4 => .f7,
        0xffc5 => .f8,
        0xffc6 => .f9,
        0xffc7 => .f10,
        0xffc8 => .f11,
        0xffc9 => .f12,
        else => null,
    };
}

fn axisIndex(a: WL.Pointer.Axis) ?usize {
    return switch (a) {
        .vertical_scroll => 0,
        .horizontal_scroll => 1,
        _ => null,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nsToTimespec(ns: i64) linux.timespec {
    return .{ .sec = @intCast(@divTrunc(ns, 1_000_000_000)), .nsec = @intCast(@mod(ns, 1_000_000_000)) };
}

fn sysFd(rc: usize) !i32 {
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    return @intCast(rc);
}

fn drain(fd: i32) void {
    var n: u64 = 0;
    _ = linux.read(fd, std.mem.asBytes(&n), 8);
}
