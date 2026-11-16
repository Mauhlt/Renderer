//! Wayland window backend (Linux), on the owner's Wayland bindings
//! (../Wayland: libwayland-client and libxkbcommon via dlopen). No X11.
//!
//!   window      xdg-shell toplevel; server-side decorations through
//!               xdg-decoration when the compositor offers it. Where it
//!               does not (GNOME, Weston and so WSLg) or answers
//!               client_side, the backend draws its own title bar
//!               (wl_csd.zig, wl_bar.zig): title, close button, move,
//!               double-click maximise, resize at the edges. It covers the
//!               content's top strip (insets().top). WSLg's RAIL windows
//!               show only the main surface (no sub-surfaces): there the
//!               app draws the bar from titleBar() and the backend still
//!               handles the strip's input
//!   cursor      cursor-shape-v1 when offered, else the Xcursor theme
//!               through libwayland-cursor (dlopen; $XCURSOR_THEME,
//!               $XCURSOR_SIZE); without either the compositor's cursor
//!               stays (no image is set)
//!   scale       wl_surface.preferred_buffer_scale (v6) or the largest
//!               wl_output scale among the outputs the surface is on;
//!               integer scales only (no wp_fractional_scale yet)
//!   keyboard    wl_keyboard + xkbcommon; key repeat from repeat_info on a
//!               timerfd (a deadline in the same poll, not a tick)
//!   pointer     wl_pointer: buttons, drags, wheel (value120 / discrete /
//!               continuous axis)
//!   clipboard   wl_data_device (local shim in wl_data.zig), made once
//!               both the seat and the manager are bound, whenever
//!   wake        an eventfd in the same poll as the display socket
//!
//! Event driven: waitEvents polls the display fd, the wake eventfd and
//! the repeat timerfd, using libwayland's prepare_read / read_events
//! protocol, with the caller's timeout (or none). It returns only for
//! the app: an event queued, a wake, or the timeout. Traffic on the
//! socket that is not ours (Vulkan's WSI keeps frame callbacks and
//! buffer releases on its own event queue; pointer motion with no button
//! held) is read and the wait goes on: returning for it would make an
//! app that draws after every wait present again, ask for another frame
//! callback, and draw at the compositor's refresh rate forever.
//!
//! STATUS: run under WSLg (Weston); not yet on GNOME or KDE.

const std = @import("std");
const linux = std.os.linux;
const Wl = @import("Wayland");
const WL = Wl.WL;
const XDG = Wl.XDG;
const DECOR = Wl.DECOR;
const XKB = Wl.XKB;
const CURSOR = Wl.CURSOR;
const SHAPE = Wl.CURSOR_SHAPE;
const data = @import("wl_data.zig");
const csd = @import("wl_csd.zig");
const Bar = @import("wl_bar.zig").Bar;
const root = @import("root.zig");

const Event = root.Event;
const Key = root.Key;
const Mods = root.Mods;

const max_outputs = 16;
const max_offers = 8;
/// Pastes of our own selection served at once (more are refused: the
/// reader sees an empty paste).
const max_sends = 4;
/// Time limit for reading another client's selection (clipboardText, on
/// the caller's thread) and for each paste of ours (served from the poll
/// loop, never blocking it).
const paste_timeout_ms = 2000;
/// Two presses on our title bar this close (wl_pointer time) are a
/// double-click: maximise or restore.
const double_click_ms = 400;

/// One paste of our selection in progress: the rest of the text goes to
/// the reader's fd (non-blocking) whenever poll says it is writable, until
/// done, an error, or the deadline.
const Send = struct {
    fd: i32 = -1,
    /// Own copy: the selection may be replaced or cancelled meanwhile.
    text: []u8 = &.{},
    off: usize = 0,
    deadline_ns: u64 = 0,
};

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
    shm: ?*WL.Shm = null,
    subcompositor: ?*WL.Subcompositor = null,
    shape_manager: ?*SHAPE.Manager = null,
    outputs: [max_outputs]OutputSlot = @splat(.{}),

    /// Our own title bar as a sub-surface (null: the compositor decorates,
    /// the app draws it, or it could not be made).
    bar: ?*Bar = null,
    /// The app draws the bar (titleBar()): the compositor shows no
    /// sub-surfaces (WSLg). Its input is still ours.
    app_bar: bool = false,
    /// WSLg's RDP RAIL shell is present: its windows show the main
    /// surface only, never sub-surfaces.
    rail: bool = false,
    /// The bar's input: the part under the pointer, a press on the close
    /// button (it closes on release over it), the last press on the title
    /// (wl_pointer time, ms) for double-clicks.
    bar_hover: csd.Part = .none,
    close_armed: bool = false,
    last_click_ms: ?u32 = null,
    colors: root.DecorationColors = .{},
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    maximized: bool = false,
    activated: bool = true,
    pending_maximized: bool = false,
    pending_activated: bool = true,

    /// Which surface the pointer is on.
    ptr_on: enum { none, content, bar } = .none,
    /// The latest wl_pointer.enter serial (cursor requests) and button
    /// press serial (move / resize requests).
    enter_serial: u32 = 0,
    press_serial: u32 = 0,
    /// The cursor shown (null: set it at the next chance).
    cursor_now: ?csd.Cursor = null,
    shape_device: ?*SHAPE.Device = null,
    cursor_theme: ?*CURSOR.Theme = null,
    cursor_theme_scale: i32 = 0,
    cursor_surface: ?*WL.Surface = null,
    /// libwayland-cursor could not be loaded or has no theme: no cursor
    /// images are set.
    cursor_unavailable: bool = false,

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
    sends: [max_sends]Send = @splat(.{}),

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
        self.storeTitle(title);
        tl.setTitle(self.titleZ().ptr);
        self.requestDecoration();
        // No xdg-decoration: our own bar (an answer of client_side from
        // the decoration object enables it too, onDecoration).
        if (self.decoration == null) self.enableBar();
        self.ensureDataDevice();
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
        if (self.bar) |b| b.destroy();
        self.bar = null;
        if (self.shape_device) |d| d.destroy();
        self.shape_device = null;
        if (self.cursor_surface) |s| s.destroy();
        self.cursor_surface = null;
        if (self.cursor_theme) |t| t.destroy();
        self.cursor_theme = null;
        if (self.shape_manager) |m| m.destroy();
        self.shape_manager = null;
        if (self.subcompositor) |s| s.destroy();
        self.subcompositor = null;
        for (&self.sends) |*s| self.endSend(s);
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
        if (self.shm) |s| s.release();
        self.shm = null;
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
        _ = self.pump(0);
        return self.queue.pop();
    }

    pub fn pollQueued(self: *Window) ?Event {
        return self.queue.pop();
    }

    /// Sleeps until an event is queued, wake() or `timeout_ms`
    /// (`root.forever`: no limit). Socket traffic that queues nothing
    /// (another event queue's, or ignored events) does not end it: the
    /// wait resumes with what is left of the timeout.
    pub fn waitEvents(self: *Window, timeout_ms: u32) void {
        if (self.queue.pending()) return;
        const deadline: ?u64 = if (timeout_ms == root.forever) null else monotonicNs() +| @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (true) {
            const t: i32 = if (deadline) |d| root.msUntil(monotonicNs(), d) else -1;
            if (self.pump(t) or self.queue.pending()) return;
            if (deadline) |d| if (monotonicNs() >= d) return;
        }
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
        self.storeTitle(title);
        if (self.toplevel) |t| t.setTitle(self.titleZ().ptr);
        if (self.bar) |b| {
            b.invalidate();
            self.redrawBar();
        }
        _ = self.display.flush() catch {};
    }

    fn storeTitle(self: *Window, title: []const u8) void {
        self.title_len = root.titleZ(title, &self.title_buf).len;
    }

    fn titleZ(self: *const Window) [:0]const u8 {
        return self.title_buf[0..self.title_len :0];
    }

    // ----------------------------------------------- Wayland-only extras

    /// Recolours the title bar the backend draws (where it draws one).
    pub fn setDecorationColors(self: *Window, colors: root.DecorationColors) void {
        self.colors = colors;
        if (self.bar) |b| {
            b.invalidate();
            self.redrawBar();
            _ = self.display.flush() catch {};
        }
        if (self.app_bar) self.queue.push(.expose);
    }

    /// True while there is a client-side title bar (the compositor draws
    /// none): ours, or the app's (titleBar()).
    pub fn clientDecorations(self: *const Window) bool {
        return self.bar != null or self.app_bar;
    }

    /// The title bar the app must draw in its inset strip, where the
    /// compositor shows no sub-surfaces (WSLg); null elsewhere. A change
    /// (focus, the close button's hover, title, colours, scale) comes with
    /// an .expose or .insets event.
    pub fn titleBar(self: *const Window) ?root.TitleBar {
        if (!self.app_bar) return null;
        const s: f32 = @floatFromInt(self.buffer_scale);
        return .{
            .height = @as(f32, @floatFromInt(csd.bar_h)) * s,
            .close_w = @as(f32, @floatFromInt(csd.close_w)) * s,
            .title_pad = @as(f32, @floatFromInt(csd.title_pad)) * s,
            .title_em = csd.title_em * s,
            .title = self.title_buf[0..self.title_len],
            .active = self.activated,
            .close_hover = self.bar_hover == .close,
            .colors = self.colors,
        };
    }

    /// Starts an interactive move, from the latest mouse_down (call it
    /// while handling that event, e.g. for an app's own top bar). The
    /// compositor then has the pointer until the button is released: no
    /// mouse_move or mouse_up follows. False if there is no seat.
    pub fn startMove(self: *Window) bool {
        const seat = self.seat orelse return false;
        const tl = self.toplevel orelse return false;
        tl.move(seat, self.press_serial);
        self.left_held = false;
        _ = self.display.flush() catch {};
        return true;
    }

    /// Starts an interactive resize from `edge`, like `startMove`.
    pub fn startResize(self: *Window, edge: root.ResizeEdge) bool {
        const seat = self.seat orelse return false;
        const tl = self.toplevel orelse return false;
        tl.resize(seat, self.press_serial, xdgEdge(edge));
        self.left_held = false;
        _ = self.display.flush() catch {};
        return true;
    }

    // ---------------------------------------------------------- title bar

    /// Shows our own title bar: a sub-surface (needs wl_shm and
    /// wl_subcompositor; without them the window stays undecorated), or
    /// under WSLg, whose RAIL windows show no sub-surfaces, one the app
    /// draws (titleBar()).
    fn enableBar(self: *Window) void {
        if (self.clientDecorations()) return;
        if (self.rail) {
            self.app_bar = true;
        } else {
            const compositor = self.compositor orelse return;
            const sc = self.subcompositor orelse return;
            const shm = self.shm orelse return;
            const surface = self.surface orelse return;
            self.bar = Bar.create(self.gpa, compositor, sc, shm, surface) catch return;
        }
        // The app keeps the bar's strip clear (insets().top).
        self.queue.push(.insets);
        if (self.configured) self.redrawBar();
    }

    fn disableBar(self: *Window) void {
        if (!self.clientDecorations()) return;
        if (self.bar) |b| b.destroy();
        self.bar = null;
        self.app_bar = false;
        if (self.ptr_on == .bar) self.ptr_on = .none;
        self.bar_hover = .none;
        self.queue.push(.insets);
    }

    /// Our bar shows the current state (the sub-surface is painted when it
    /// changed; the app's is drawn on the .expose that follows).
    fn redrawBar(self: *Window) void {
        if (self.app_bar) return self.queue.push(.expose);
        const b = self.bar orelse return;
        const state: csd.State = .{ .active = self.activated, .close_hover = self.bar_hover == .close };
        b.redraw(self.width, self.buffer_scale, state, self.title_buf[0..self.title_len], self.colors);
    }

    fn onDecoration(_: *DECOR.ToplevelDecoration, ev: DECOR.ToplevelDecoration.Event, self: *Window) void {
        switch (ev.configure.mode) {
            .client_side => self.enableBar(),
            else => self.disableBar(),
        }
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
    /// most `t` ms (poll(2)'s timeout: negative, no limit). True when the
    /// wait should end whatever was queued: wake(), the connection lost,
    /// or poll failing (not EINTR). False otherwise: the socket, the
    /// repeat timer, a paste or a timeout (waitEvents keeps its own
    /// deadline; a paste's may have cut the poll short); any events are
    /// in the queue.
    fn pump(self: *Window, t: i32) bool {
        const d = self.display;
        if (self.dead) {
            var fds = [_]linux.pollfd{
                .{ .fd = self.wake_fd, .events = linux.POLL.IN },
            };
            const rc = linux.poll(&fds, fds.len, t);
            if (fds[0].revents & linux.POLL.IN != 0) drain(self.wake_fd);
            return linux.errno(rc) != .INTR;
        }
        // Events already read but not dispatched must be dispatched before
        // waiting, or the wait could sleep on work that is already here.
        while (!d.prepareRead()) {
            _ = d.dispatchPending() catch {
                self.fail();
                return true;
            };
        }
        var wait = if (self.queue.pending()) 0 else t;
        _ = d.flush() catch {};
        var fds: [3 + max_sends]linux.pollfd = undefined;
        fds[0] = .{ .fd = d.getFd(), .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 };
        fds[2] = .{ .fd = self.timer_fd, .events = linux.POLL.IN, .revents = 0 };
        // Pastes in progress: writable fds, and their deadlines bound the
        // wait. A free slot's fd is -1, which poll ignores.
        const now = monotonicNs();
        for (self.sends, fds[3..]) |s, *p| {
            p.* = .{ .fd = s.fd, .events = linux.POLL.OUT, .revents = 0 };
            if (s.fd >= 0) wait = root.minTimeout(wait, root.msUntil(now, s.deadline_ns));
        }
        const rc = linux.poll(&fds, fds.len, wait);
        const polled = linux.errno(rc) == .SUCCESS;
        if (polled and fds[0].revents & (linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP) != 0) {
            d.readEvents() catch {
                self.fail();
                return true;
            };
        } else d.cancelRead();
        _ = d.dispatchPending() catch {
            self.fail();
            return true;
        };
        if (!polled) return linux.errno(rc) != .INTR;
        // Dispatching may have started a new paste in a free slot (polled as
        // fd -1): only a slot whose own fd was polled acts on revents.
        const after = monotonicNs();
        for (&self.sends, fds[3..]) |*s, p| {
            if (s.fd < 0) continue;
            if (p.fd == s.fd and p.revents != 0) self.continueSend(s);
            if (s.fd >= 0 and after >= s.deadline_ns) self.endSend(s);
        }
        const woken = fds[1].revents & linux.POLL.IN != 0;
        if (woken) drain(self.wake_fd);
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
        return woken;
    }

    fn fail(self: *Window) void {
        // The compositor went away (or a protocol error): report a close
        // once; later waits only watch the wake fd.
        self.dead = true;
        self.stopRepeat();
        for (&self.sends) |*s| self.endSend(s);
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
                        self.ensureDataDevice();
                    }
                } else if (eql(name, "zxdg_decoration_manager_v1")) {
                    if (self.deco_manager == null) {
                        self.deco_manager = reg.bind(g.name, DECOR.Manager, g.version) catch null;
                        self.requestDecoration();
                    }
                } else if (eql(name, "wl_data_device_manager")) {
                    if (self.ddm == null) {
                        self.ddm = reg.bind(g.name, data.DataDeviceManager, g.version) catch null;
                        self.ensureDataDevice();
                    }
                } else if (eql(name, "weston_rdprail_shell")) {
                    self.rail = true;
                } else if (eql(name, "wl_shm")) {
                    if (self.shm == null) self.shm = reg.bind(g.name, WL.Shm, g.version) catch null;
                } else if (eql(name, "wl_subcompositor")) {
                    if (self.subcompositor == null) self.subcompositor = reg.bind(g.name, WL.Subcompositor, g.version) catch null;
                } else if (eql(name, "wp_cursor_shape_manager_v1")) {
                    if (self.shape_manager == null) {
                        self.shape_manager = reg.bind(g.name, SHAPE.Manager, g.version) catch null;
                        self.ensureShapeDevice();
                    }
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

    /// The clipboard needs a data device, made from the seat and the data
    /// device manager once both are bound, whichever comes last: a seat
    /// can be announced after the window exists (WSLg starting cold adds
    /// wl_seat seconds later, when its RDP client connects).
    fn ensureDataDevice(self: *Window) void {
        if (self.data_device != null) return;
        const seat = self.seat orelse return;
        const m = self.ddm orelse return;
        const dd = m.getDataDevice(seat) catch return;
        self.data_device = dd;
        dd.setListener(*Window, onDataDevice, self);
    }

    /// Server-side decorations (title bar, frame, close) when the
    /// compositor offers xdg-decoration (KDE, Sway, wlroots). GNOME and
    /// Weston (WSLg) do not: there our own bar is shown (enableBar), as
    /// when the compositor answers client_side.
    fn requestDecoration(self: *Window) void {
        if (self.decoration != null) return;
        const tl = self.toplevel orelse return;
        const dm = self.deco_manager orelse return;
        const d = dm.getToplevelDecoration(tl) catch return;
        self.decoration = d;
        d.setListener(*Window, onDecoration, self);
        d.setMode(.server_side);
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
        // The bar (and so the inset, in pixels) and the cursor follow the
        // new scale.
        if (self.clientDecorations()) self.queue.push(.insets);
        self.redrawBar();
        self.cursor_now = null;
        self.updatePointer();
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
        self.maximized = self.pending_maximized;
        self.activated = self.pending_activated;
        self.configured = true;
        self.redrawBar();
        // Draw now: the compositor waits for a commit after the ack.
        self.queue.push(.expose);
    }

    fn onToplevel(_: *XDG.Toplevel, ev: XDG.Toplevel.Event, self: *Window) void {
        switch (ev) {
            .configure => |c| {
                self.pending_width = c.width;
                self.pending_height = c.height;
                self.pending_maximized = c.states.maximized or c.states.fullscreen;
                self.pending_activated = c.states.activated;
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
                    self.ensureShapeDevice();
                } else if (!caps.pointer) if (self.pointer) |p| {
                    if (self.shape_device) |d| d.destroy();
                    self.shape_device = null;
                    p.release();
                    self.pointer = null;
                    self.ptr_on = .none;
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

    /// The pointer is on the title bar: our sub-surface, or the strip the
    /// app draws it in (the content's top `csd.bar_h`).
    fn onBar(self: *const Window) bool {
        return switch (self.ptr_on) {
            .none => false,
            .bar => true,
            .content => self.app_bar and self.ptr_y < csd.bar_h,
        };
    }

    /// The resize grip under the pointer in the content (only with a
    /// client-side bar: a compositor that decorates has its own border).
    fn contentEdge(self: *const Window) ?root.ResizeEdge {
        if (!self.clientDecorations() or self.ptr_on != .content or self.onBar()) return null;
        return csd.hitContent(self.ptr_x, self.ptr_y, self.width, self.height, self.maximized);
    }

    /// What the pointer is over: the bar's hover (the close button lights
    /// up) and the cursor.
    fn updatePointer(self: *Window) void {
        if (self.ptr_on == .none) return;
        const on_bar = self.onBar();
        const part: csd.Part = if (on_bar)
            csd.hitBar(self.ptr_x, self.ptr_y, self.width, self.maximized)
        else if (self.contentEdge()) |e| .{ .edge = e } else .none;
        self.setBarHover(if (on_bar) part else .none);
        self.setCursor(csd.cursorFor(part));
    }

    fn setBarHover(self: *Window, part: csd.Part) void {
        if (self.bar_hover.eql(part)) return;
        const was_close = self.bar_hover == .close;
        self.bar_hover = part;
        // Only the close button's look depends on the hover.
        if (was_close != (part == .close)) self.redrawBar();
    }

    /// A button on the bar: close (on release over the button), move,
    /// double-click maximise, resize from the top edge, the window menu.
    fn barButton(self: *Window, b: anytype) void {
        const part = csd.hitBar(self.ptr_x, self.ptr_y, self.width, self.maximized);
        switch (b.state) {
            .pressed => switch (b.button) {
                WL.BTN_LEFT => switch (part) {
                    .none => {},
                    .close => self.close_armed = true,
                    .edge => |e| _ = self.startResize(e),
                    .title => {
                        const double = if (self.last_click_ms) |t| b.time -% t <= double_click_ms else false;
                        if (double) {
                            self.last_click_ms = null;
                            if (self.toplevel) |tl| if (self.maximized) tl.unsetMaximized() else tl.setMaximized();
                        } else {
                            self.last_click_ms = b.time;
                            _ = self.startMove();
                        }
                    },
                },
                WL.BTN_RIGHT => if (part == .title) if (self.seat) |seat| if (self.toplevel) |tl| {
                    // The bar sits at the window's origin: its coordinates
                    // are the window's.
                    tl.showWindowMenu(seat, b.serial, @intFromFloat(self.ptr_x), @intFromFloat(self.ptr_y));
                },
                else => {},
            },
            .released => if (b.button == WL.BTN_LEFT) {
                if (self.close_armed and part == .close) self.queue.push(.close);
                self.close_armed = false;
            },
            _ => {},
        }
        _ = self.display.flush() catch {};
    }

    // ------------------------------------------------------------- cursor

    fn ensureShapeDevice(self: *Window) void {
        if (self.shape_device != null) return;
        const m = self.shape_manager orelse return;
        const p = self.pointer orelse return;
        self.shape_device = m.getPointer(p) catch null;
    }

    /// Shows `kind` (once per change; an enter resets it): through
    /// cursor-shape-v1, else an image of the cursor theme.
    fn setCursor(self: *Window, kind: csd.Cursor) void {
        if (self.cursor_now == kind) return;
        const p = self.pointer orelse return;
        if (self.shape_device) |d| {
            d.setShape(self.enter_serial, shapeOf(kind));
            self.cursor_now = kind;
            return;
        }
        const theme = self.cursorTheme() orelse return;
        const cur = theme.getCursor(xcursorName(kind)) orelse theme.getCursor("left_ptr") orelse return;
        if (cur.image_count == 0) return;
        const img = cur.images[0];
        const buf = img.buffer() orelse return;
        const cs = self.cursor_surface orelse blk: {
            const compositor = self.compositor orelse return;
            const s = compositor.createSurface() catch return;
            self.cursor_surface = s;
            break :blk s;
        };
        const s = self.cursor_theme_scale;
        if (Wl.CLIENT.version(cs) >= 3) cs.setBufferScale(s);
        cs.attach(buf, 0, 0);
        cs.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        cs.commit();
        p.setCursor(self.enter_serial, cs, @divTrunc(@as(i32, @intCast(img.hotspot_x)), s), @divTrunc(@as(i32, @intCast(img.hotspot_y)), s));
        self.cursor_now = kind;
    }

    /// The Xcursor theme at the window's scale, loaded on first use and
    /// again when the scale changes; null without libwayland-cursor.
    fn cursorTheme(self: *Window) ?*CURSOR.Theme {
        if (self.cursor_unavailable) return null;
        const s = @max(1, self.buffer_scale);
        if (self.cursor_theme) |t| {
            if (self.cursor_theme_scale == s) return t;
            t.destroy();
            self.cursor_theme = null;
        }
        const shm = self.shm orelse return null;
        CURSOR.load() catch {
            self.cursor_unavailable = true;
            return null;
        };
        const name: ?[*:0]const u8 = std.c.getenv("XCURSOR_THEME");
        const size: i32 = if (std.c.getenv("XCURSOR_SIZE")) |z| std.fmt.parseInt(i32, std.mem.span(z), 10) catch 24 else 24;
        const t = CURSOR.Theme.load(name, std.math.clamp(size, 8, 256) * s, shm) orelse {
            self.cursor_unavailable = true;
            return null;
        };
        self.cursor_theme = t;
        self.cursor_theme_scale = s;
        return t;
    }

    fn onPointer(p: *WL.Pointer, ev: WL.Pointer.Event, self: *Window) void {
        switch (ev) {
            .enter => |e| {
                self.serial = e.serial;
                self.enter_serial = e.serial;
                self.ptr_x = e.x.toFloat();
                self.ptr_y = e.y.toFloat();
                const bar_surface: ?*WL.Surface = if (self.bar) |b| b.surface else null;
                self.ptr_on = if (e.surface != null and e.surface == bar_surface)
                    .bar
                else if (e.surface != null and e.surface == self.surface) .content else .none;
                // Each enter needs its cursor set again.
                self.cursor_now = null;
                self.updatePointer();
            },
            .leave => {
                self.close_armed = false;
                self.setBarHover(.none);
                self.ptr_on = .none;
            },
            .motion => |mo| {
                self.ptr_x = mo.x.toFloat();
                self.ptr_y = mo.y.toFloat();
                self.updatePointer();
                if (self.ptr_on == .content and self.left_held) {
                    const xy = self.pos();
                    self.queue.push(.{ .mouse_move = .{ .x = xy[0], .y = xy[1], .left_held = true } });
                }
            },
            .button => |b| {
                self.serial = b.serial;
                if (b.state == .pressed) self.press_serial = b.serial;
                // The bar's (a release ends a press made in the content
                // there, wherever it is).
                if (self.onBar() and !(self.left_held and b.state == .released)) return self.barButton(b);
                const xy = self.pos();
                const button: root.MouseButton = switch (b.button) {
                    WL.BTN_LEFT => .left,
                    WL.BTN_RIGHT => .right,
                    WL.BTN_MIDDLE => .middle,
                    else => return,
                };
                switch (b.state) {
                    .pressed => {
                        // Our bar's resize grips inside the content's edges.
                        if (button == .left and !self.left_held) if (self.contentEdge()) |edge| {
                            _ = self.startResize(edge);
                            return;
                        };
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
        if (self.ptr_on != .content or self.onBar()) {
            // The wheel over the bar does nothing.
            self.scroll_value = .{ 0, 0 };
            self.scroll_v120 = .{ 0, 0 };
            self.scroll_any = false;
            return;
        }
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
    /// by `max_units` and one 2 s deadline for the whole read, in case the
    /// owner never writes or writes slowly).
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

        const cap = (std.math.mul(usize, max_units, 3) catch std.math.maxInt(usize)) +| 4; // UTF-8 bytes for max_units UTF-16 units
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        // One absolute deadline for the whole read: an owner that trickles
        // bytes cannot keep the UI thread here past it.
        const deadline = monotonicNs() +| paste_timeout_ms * std.time.ns_per_ms;
        while (buf.items.len < cap) {
            const left = root.msUntil(monotonicNs(), deadline);
            if (left == 0) break;
            var pfd = [_]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN }};
            const prc = linux.poll(&pfd, 1, left);
            switch (linux.errno(prc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => break,
            }
            if (prc == 0) break; // the deadline passed
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

    /// Our title bar covers the content's top strip (none where the
    /// compositor decorates).
    pub fn insets(self: *const Window) root.Insets {
        if (!self.clientDecorations()) return .{};
        return .{ .top = @floatFromInt(csd.bar_h * self.buffer_scale) };
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
            .send => |s| self.startSend(source, s.fd),
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

    /// A reader asked for our selection: write it to `fd` without blocking,
    /// the rest from the poll loop (pump) until done or the deadline. The
    /// fd is always closed in the end; a refused or failed paste is just
    /// an empty or short one for the reader.
    fn startSend(self: *Window, source: *data.DataSource, fd: i32) void {
        const text = if (source == self.own_source) self.own_text else null;
        const slot = for (&self.sends) |*s| {
            if (s.fd < 0) break s;
        } else null;
        if (text == null or slot == null or !setNonBlocking(fd)) {
            _ = linux.close(fd);
            return;
        }
        const copy = self.gpa.dupe(u8, text.?) catch {
            _ = linux.close(fd);
            return;
        };
        const s = slot.?;
        s.* = .{ .fd = fd, .text = copy, .deadline_ns = monotonicNs() +| paste_timeout_ms * std.time.ns_per_ms };
        self.continueSend(s);
    }

    /// Writes what the fd takes now (SIGPIPE is ignored by Zig's start
    /// code, so a vanished reader is just EPIPE); ends the paste when all
    /// is written or on any error but EAGAIN.
    fn continueSend(self: *Window, s: *Send) void {
        while (s.off < s.text.len) {
            const rest = s.text[s.off..];
            const n = linux.write(s.fd, rest.ptr, rest.len);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return self.endSend(s);
                    s.off += n;
                },
                .INTR => continue,
                .AGAIN => return, // full: poll says when it drains
                else => return self.endSend(s),
            }
        }
        self.endSend(s);
    }

    fn endSend(self: *Window, s: *Send) void {
        if (s.fd < 0) return;
        _ = linux.close(s.fd);
        self.gpa.free(s.text);
        s.* = .{};
    }
};

/// CLOCK_MONOTONIC in nanoseconds (deadlines that wall-clock changes do
/// not move). If the clock fails, "the end of time", so every deadline
/// counts as passed and nothing waits on a clock that never moves.
fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return std.math.maxInt(u64);
    return @as(u64, @intCast(ts.sec)) *| std.time.ns_per_s +| @as(u64, @intCast(ts.nsec));
}

/// O_NONBLOCK on `fd` (the reader's end of a paste), so a reader that
/// stops reading can never block the UI thread.
fn setNonBlocking(fd: i32) bool {
    const got = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(got) != .SUCCESS) return false;
    var flags: linux.O = @bitCast(@as(u32, @truncate(got)));
    flags.NONBLOCK = true;
    return linux.errno(linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(flags)))) == .SUCCESS;
}

fn xdgEdge(e: root.ResizeEdge) XDG.Toplevel.ResizeEdge {
    return switch (e) {
        .top => .top,
        .bottom => .bottom,
        .left => .left,
        .right => .right,
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
    };
}

fn shapeOf(c: csd.Cursor) SHAPE.Device.Shape {
    return switch (c) {
        .default => .default,
        .n => .n_resize,
        .s => .s_resize,
        .e => .e_resize,
        .w => .w_resize,
        .ne => .ne_resize,
        .nw => .nw_resize,
        .se => .se_resize,
        .sw => .sw_resize,
    };
}

/// Xcursor names (also in libwayland-cursor's built-in set).
fn xcursorName(c: csd.Cursor) [*:0]const u8 {
    return switch (c) {
        .default => "left_ptr",
        .n => "top_side",
        .s => "bottom_side",
        .e => "right_side",
        .w => "left_side",
        .ne => "top_right_corner",
        .nw => "top_left_corner",
        .se => "bottom_right_corner",
        .sw => "bottom_left_corner",
    };
}

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
