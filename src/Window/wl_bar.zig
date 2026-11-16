//! The Wayland side of the title bar wayland.zig shows where the
//! compositor draws no decorations: a wl_subsurface over the top
//! `csd.bar_h` pixels of the content (desynchronised, so a hover or focus
//! change shows without the app drawing), painted by wl_csd.zig into a
//! wl_shm buffer. The app keeps that strip clear through `insets().top`.
//!
//! Over the content rather than above it: a bar at a negative offset,
//! with the window geometry grown to include it, is the usual layout, but
//! WSLg's RDP RAIL windows are the main surface's size and cut it off.
//!
//! Event driven: `redraw` paints only when something it shows changed
//! (width, scale, focus, the close button's hover, the title, the
//! colours). Each paint is a new memfd and buffer; the buffer is
//! destroyed when the compositor releases it.
//!
//! The title uses the Renderer's FontSet (the system monospace font),
//! loaded on the first paint; without a font the bar has no title.

const std = @import("std");
const linux = std.os.linux;
const Wl = @import("Wayland");
const WL = Wl.WL;
const Font = @import("Font");
const csd = @import("wl_csd.zig");

pub const Bar = struct {
    gpa: std.mem.Allocator,
    surface: *WL.Surface,
    sub: *WL.Subsurface,
    shm: *WL.Shm,

    fonts: ?Font.fontset.FontSet = null,
    fonts_tried: bool = false,
    metrics: ?Font.fontset.Metrics = null,

    /// The buffer on screen until the compositor releases it.
    live: ?*WL.Buffer = null,
    /// What the last paint showed; null forces the next one.
    drawn: ?Shown = null,

    const Shown = struct {
        width: i32,
        scale: i32,
        state: csd.State,
    };

    /// The bar for `parent` (its toplevel's surface), over its top edge.
    pub fn create(gpa: std.mem.Allocator, compositor: *WL.Compositor, subcompositor: *WL.Subcompositor, shm: *WL.Shm, parent: *WL.Surface) !*Bar {
        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const sub = try subcompositor.getSubsurface(surface, parent);
        sub.setPosition(0, 0);
        sub.setDesync();
        const self = try gpa.create(Bar);
        self.* = .{ .gpa = gpa, .surface = surface, .sub = sub, .shm = shm };
        return self;
    }

    pub fn destroy(self: *Bar) void {
        if (self.live) |b| b.destroy();
        self.sub.destroy();
        self.surface.destroy();
        if (self.fonts) |*f| f.deinit();
        self.gpa.destroy(self);
    }

    /// Paint again on the next `redraw` (title or colours changed).
    pub fn invalidate(self: *Bar) void {
        self.drawn = null;
    }

    /// Paints the bar if what it shows changed. `width`: logical pixels
    /// (the content's width); `scale`: the integer buffer scale.
    pub fn redraw(self: *Bar, width: i32, scale: i32, state: csd.State, title: []const u8, colors: csd.Colors) void {
        const shown: Shown = .{
            .width = @max(1, width),
            .scale = @max(1, scale),
            .state = state,
        };
        if (self.drawn) |d| if (std.meta.eql(d, shown)) return;
        const l = csd.Layout.init(shown.width, shown.scale);
        const stride = l.w * 4;
        const size = @as(usize, stride) * l.h;
        if (size > std.math.maxInt(i32)) return;

        const fd = memfd() orelse return;
        defer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return;
        const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(addr) != .SUCCESS) return;
        const mem: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(addr);
        defer _ = linux.munmap(mem, size);
        const px: []u32 = @as([*]u32, @ptrCast(mem))[0 .. size / 4];

        const glyphs = self.glyphSource(l.em);
        var scratch: []u8 = &.{};
        if (glyphs) |g| scratch = self.gpa.alloc(u8, 2 * @as(usize, g.cell_w) * g.cell_h) catch &.{};
        defer if (scratch.len > 0) self.gpa.free(scratch);
        csd.draw(px, l, colors, shown.state, title, glyphs, scratch);

        const pool = self.shm.createPool(fd, @intCast(size)) catch return;
        defer pool.destroy();
        const buf = pool.createBuffer(0, @intCast(l.w), @intCast(l.h), @intCast(stride), .xrgb8888) catch return;
        buf.setListener(*Bar, onBuffer, self);
        if (Wl.CLIENT.version(self.surface) >= 3) self.surface.setBufferScale(shown.scale);
        self.surface.attach(buf, 0, 0);
        if (Wl.CLIENT.version(self.surface) >= 4)
            self.surface.damageBuffer(0, 0, @intCast(l.w), @intCast(l.h))
        else
            self.surface.damage(0, 0, shown.width, csd.bar_h);
        self.surface.commit();
        // The buffer shown before stays until its own release.
        self.live = buf;
        self.drawn = shown;
    }

    fn onBuffer(buf: *WL.Buffer, _: WL.Buffer.Event, self: *Bar) void {
        if (self.live == buf) self.live = null;
        buf.destroy();
    }

    /// The title font at `em` pixels, loaded once; null without a font.
    fn glyphSource(self: *Bar, em: f32) ?csd.Glyphs {
        if (!self.fonts_tried) {
            self.fonts_tried = true;
            self.fonts = Font.fontset.FontSet.load(self.gpa, std.Io.Threaded.global_single_threaded.io()) catch null;
        }
        const fs = &(self.fonts orelse return null);
        if (self.metrics == null or self.metrics.?.em != em) self.metrics = fs.metrics(em);
        const m = self.metrics.?;
        return .{ .ctx = self, .cell_w = m.cell_w, .cell_h = m.cell_h, .width = cellWidth, .render = renderGlyph };
    }

    fn cellWidth(cp: u21) u2 {
        return Font.wcwidth.of(cp);
    }

    fn renderGlyph(ctx: *anyopaque, cp: u21, cells: u32, cov: []u8) void {
        const self: *Bar = @ptrCast(@alignCast(ctx));
        const fs = &(self.fonts orelse return @memset(cov, 0));
        fs.render(cp, .{}, self.metrics.?, cells, cov);
    }
};

fn memfd() ?i32 {
    const rc = linux.memfd_create("window-bar", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}
