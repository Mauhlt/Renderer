//! Client-side window decorations for the Wayland backend: the title bar
//! wayland.zig shows where the compositor draws none (no xdg-decoration:
//! GNOME, Weston / WSLg; or it answered client_side).
//!
//! This file is only layout, hit testing and drawing into an XRGB8888
//! pixel buffer; it makes no Wayland calls, so its tests run on every OS.
//!
//!   bar        a wl_subsurface over the content's top `bar_h` logical
//!              pixels (the app keeps them clear: insets().top): the
//!              title, left-aligned, and a close button (x)
//!   move       press on the title: xdg_toplevel.move; double-click
//!              maximises or restores
//!   resize     the bar's top `grip` pixels, and `grip` pixels inside the
//!              content's left, right and bottom edges (those presses are
//!              not passed to the app); corners take `corner` pixels along
//!              each edge. None while maximised.
//!
//! All sizes below are logical pixels (surface units); the buffer is
//! drawn at the window's integer buffer scale.

const std = @import("std");
const root = @import("root.zig");

pub const Edge = root.ResizeEdge;
pub const Colors = root.DecorationColors;

/// Height of the bar.
pub const bar_h: i32 = 32;
/// Depth of the resize grips.
pub const grip: i32 = 6;
/// Length of a corner's grip along each edge.
pub const corner: i32 = 16;
/// Width of the close button (the bar's right end).
pub const close_w: i32 = 46;
/// Space before the title.
pub const title_pad: i32 = 12;
/// The title's font size.
pub const title_em: f32 = 14;
/// The cross's half-size, and its stroke width.
const cross_half: f32 = 5;
const cross_stroke: f32 = 1.25;

/// What a point of the bar (or of the content's edge) does.
pub const Part = union(enum) {
    none,
    title,
    close,
    edge: Edge,

    pub fn eql(a: Part, b: Part) bool {
        return switch (a) {
            .edge => |e| b == .edge and b.edge == e,
            else => @as(std.meta.Tag(Part), a) == @as(std.meta.Tag(Part), b),
        };
    }
};

/// The bar's part under (x, y), bar-surface coordinates; `w` the bar's
/// (= the content's) width.
pub fn hitBar(x: f64, y: f64, w: i32, maximized: bool) Part {
    const fw: f64 = @floatFromInt(w);
    if (x < 0 or y < 0 or x >= fw or y >= bar_h) return .none;
    if (!maximized and y < grip) {
        if (x < corner) return .{ .edge = .top_left };
        if (x >= fw - corner) return .{ .edge = .top_right };
        return .{ .edge = .top };
    }
    if (x >= fw - close_w) return .close;
    return .title;
}

/// The resize edge under (x, y) in the content (w x h), if any: the left,
/// right and bottom grips (the top one is the bar's).
pub fn hitContent(x: f64, y: f64, w: i32, h: i32, maximized: bool) ?Edge {
    if (maximized) return null;
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    if (x < 0 or y < 0 or x >= fw or y >= fh) return null;
    const left = x < grip;
    const right = x >= fw - grip;
    const bottom = y >= fh - grip;
    if (bottom or (y >= fh - corner and (left or right))) {
        if (x < corner) return .bottom_left;
        if (x >= fw - corner) return .bottom_right;
        return .bottom;
    }
    if (left) return .left;
    if (right) return .right;
    return null;
}

/// The cursor a part shows.
pub const Cursor = enum { default, n, s, e, w, ne, nw, se, sw };

pub fn cursorFor(p: Part) Cursor {
    return switch (p) {
        .none, .title, .close => .default,
        .edge => |e| switch (e) {
            .top => .n,
            .bottom => .s,
            .left => .w,
            .right => .e,
            .top_left => .nw,
            .top_right => .ne,
            .bottom_left => .sw,
            .bottom_right => .se,
        },
    };
}

/// The bar's pixel layout at a buffer scale.
pub const Layout = struct {
    scale: i32,
    /// Buffer size, pixels.
    w: u32,
    h: u32,
    /// The close button's left edge, pixels.
    close_x: u32,
    /// Where the title starts, and the last pixel it may use (exclusive).
    title_x: u32,
    title_end: u32,
    /// The title's font size, pixels.
    em: f32,

    pub fn init(width: i32, scale: i32) Layout {
        const s = @max(1, scale);
        const w: u32 = @intCast(@max(1, width) * s);
        const close_px: u32 = @intCast(close_w * s);
        const close_x = w -| close_px;
        const pad: u32 = @intCast(title_pad * s);
        return .{
            .scale = s,
            .w = w,
            .h = @intCast(bar_h * s),
            .close_x = close_x,
            .title_x = @min(pad, close_x),
            .title_end = @max(@min(pad, close_x), close_x -| pad),
            .em = title_em * @as(f32, @floatFromInt(s)),
        };
    }
};

/// The title's glyphs, from the app's font (wayland.zig: the Renderer's
/// FontSet). Each glyph is `cells` cells of cell_w x cell_h coverage.
pub const Glyphs = struct {
    ctx: *anyopaque,
    cell_w: u32,
    cell_h: u32,
    /// Cells a code point takes (0, 1 or 2).
    width: *const fn (cp: u21) u2,
    /// Coverage of `cp` into `cov` (cells * cell_w * cell_h bytes).
    render: *const fn (ctx: *anyopaque, cp: u21, cells: u32, cov: []u8) void,
};

pub const State = struct {
    active: bool = true,
    close_hover: bool = false,
};

const ellipsis: u21 = 0x2026;

/// Draws the bar into `px` (l.w x l.h, 0xXXRRGGBB). `scratch` holds one
/// glyph's coverage (at least 2 * cell_w * cell_h bytes); without glyphs
/// or scratch the title is left out.
pub fn draw(px: []u32, l: Layout, colors: Colors, st: State, title: []const u8, glyphs: ?Glyphs, scratch: []u8) void {
    std.debug.assert(px.len >= @as(usize, l.w) * l.h);
    const bg = if (st.active) colors.bar else colors.bar_inactive;
    const fg = if (st.active) colors.title else colors.title_inactive;
    @memset(px[0 .. @as(usize, l.w) * l.h], rgb(bg));

    // The close button.
    const cross_fg = if (st.close_hover) colors.close_hover_fg else fg;
    if (st.close_hover) fillRect(px, l.w, l.close_x, 0, l.w, l.h, colors.close_hover);
    drawCross(px, l, if (st.close_hover) colors.close_hover else bg, cross_fg);

    if (glyphs) |g| drawTitle(px, l, bg, fg, title, g, scratch);
}

fn rgb(c: [3]u8) u32 {
    return 0xFF000000 | (@as(u32, c[0]) << 16) | (@as(u32, c[1]) << 8) | c[2];
}

fn blend(bg: [3]u8, fg: [3]u8, a: f32) u32 {
    var out: [3]u8 = undefined;
    for (0..3) |i| {
        const b: f32 = @floatFromInt(bg[i]);
        const f: f32 = @floatFromInt(fg[i]);
        out[i] = @intFromFloat(@round(b + (f - b) * std.math.clamp(a, 0, 1)));
    }
    return rgb(out);
}

fn fillRect(px: []u32, stride: u32, x0: u32, y0: u32, x1: u32, y1: u32, c: [3]u8) void {
    var y = y0;
    while (y < y1) : (y += 1) @memset(px[@as(usize, y) * stride + x0 .. @as(usize, y) * stride + x1], rgb(c));
}

/// Two anti-aliased diagonals, centred in the close button.
fn drawCross(px: []u32, l: Layout, bg: [3]u8, fg: [3]u8) void {
    const s: f32 = @floatFromInt(l.scale);
    const cx = (@as(f32, @floatFromInt(l.close_x)) + @as(f32, @floatFromInt(l.w))) / 2;
    const cy = @as(f32, @floatFromInt(l.h)) / 2;
    const half = cross_half * s;
    const hw = cross_stroke * s / 2;
    const x0: u32 = @intFromFloat(@max(0, @floor(cx - half - hw - 1)));
    const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(l.w)), @ceil(cx + half + hw + 1)));
    const y0: u32 = @intFromFloat(@max(0, @floor(cy - half - hw - 1)));
    const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(l.h)), @ceil(cy + half + hw + 1)));
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const fy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @min(segDist(fx, fy, 1, half), segDist(fx, fy, -1, half));
            const a = hw + 0.5 - d;
            if (a > 0) px[@as(usize, y) * l.w + x] = blend(bg, fg, a);
        }
    }
}

/// Distance from (x, y) to the segment from (-half, -half * k) to
/// (half, half * k), k = 1 or -1 (one diagonal of the cross).
fn segDist(x: f32, y: f32, k: f32, half: f32) f32 {
    // The closest point's x: the projection onto (1, k), clamped to the ends.
    const t = std.math.clamp((x + y * k) / 2, -half, half);
    const dx = x - t;
    const dy = y - t * k;
    return @sqrt(dx * dx + dy * dy);
}

fn drawTitle(px: []u32, l: Layout, bg: [3]u8, fg: [3]u8, title: []const u8, g: Glyphs, scratch: []u8) void {
    if (g.cell_w == 0 or g.cell_h == 0 or g.cell_h > l.h) return;
    if (scratch.len < 2 * @as(usize, g.cell_w) * g.cell_h) return;
    const view = std.unicode.Utf8View.init(title) catch return;
    const room = l.title_end -| l.title_x;
    // Total width; when it does not fit, cut and end with an ellipsis.
    var total: u32 = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| total += @as(u32, g.width(cp)) * g.cell_w;
    const cut = total > room;
    const limit = if (cut) room -| g.cell_w else room;
    const y0 = (l.h - g.cell_h) / 2;
    var x = l.title_x;
    it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const cells: u32 = g.width(cp);
        if (cells == 0) continue;
        if (x - l.title_x + cells * g.cell_w > limit) break;
        blit(px, l, x, y0, cp, cells, bg, fg, g, scratch);
        x += cells * g.cell_w;
    }
    if (cut and x + g.cell_w <= l.title_end) blit(px, l, x, y0, ellipsis, 1, bg, fg, g, scratch);
}

fn blit(px: []u32, l: Layout, x0: u32, y0: u32, cp: u21, cells: u32, bg: [3]u8, fg: [3]u8, g: Glyphs, scratch: []u8) void {
    const w = cells * g.cell_w;
    const cov = scratch[0 .. @as(usize, w) * g.cell_h];
    g.render(g.ctx, cp, cells, cov);
    for (0..g.cell_h) |yy| {
        const y = y0 + yy;
        if (y >= l.h) break;
        for (0..w) |xx| {
            const x = x0 + xx;
            if (x >= l.w) break;
            const a = cov[yy * w + xx];
            if (a != 0) px[y * l.w + x] = blend(bg, fg, @as(f32, @floatFromInt(a)) / 255);
        }
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "hitBar: title, close, top edge and corners" {
    const w = 800;
    try testing.expect(hitBar(400, 16, w, false) == .title);
    try testing.expect(hitBar(799, 16, w, false) == .close);
    try testing.expect(hitBar(800 - close_w, 31, w, false) == .close);
    try testing.expect(hitBar(800 - close_w - 1, 31, w, false) == .title);
    try testing.expect(hitBar(400, 0, w, false).eql(.{ .edge = .top }));
    try testing.expect(hitBar(400, @as(f64, grip) - 0.5, w, false).eql(.{ .edge = .top }));
    try testing.expect(hitBar(400, grip, w, false) == .title);
    try testing.expect(hitBar(3, 2, w, false).eql(.{ .edge = .top_left }));
    try testing.expect(hitBar(corner - 1, 2, w, false).eql(.{ .edge = .top_left }));
    try testing.expect(hitBar(797, 2, w, false).eql(.{ .edge = .top_right }));
    // Maximised: no resize grips, the top row moves or closes.
    try testing.expect(hitBar(400, 0, w, true) == .title);
    try testing.expect(hitBar(799, 0, w, true) == .close);
    // Outside.
    try testing.expect(hitBar(-1, 10, w, false) == .none);
    try testing.expect(hitBar(10, bar_h, w, false) == .none);
    try testing.expect(hitBar(800, 10, w, false) == .none);
}

test "hitContent: left, right and bottom grips; corners; nothing inside" {
    const w = 800;
    const h = 600;
    try testing.expectEqual(@as(?Edge, null), hitContent(400, 300, w, h, false));
    try testing.expectEqual(@as(?Edge, .left), hitContent(0, 300, w, h, false));
    try testing.expectEqual(@as(?Edge, .left), hitContent(@as(f64, grip) - 0.5, 300, w, h, false));
    try testing.expectEqual(@as(?Edge, null), hitContent(grip, 300, w, h, false));
    try testing.expectEqual(@as(?Edge, .right), hitContent(799, 300, w, h, false));
    try testing.expectEqual(@as(?Edge, .bottom), hitContent(400, 599, w, h, false));
    try testing.expectEqual(@as(?Edge, .bottom_left), hitContent(2, 598, w, h, false));
    try testing.expectEqual(@as(?Edge, .bottom_left), hitContent(corner - 1, 599, w, h, false));
    try testing.expectEqual(@as(?Edge, .bottom_left), hitContent(1, h - corner + 1, w, h, false));
    try testing.expectEqual(@as(?Edge, .bottom_right), hitContent(798, 599, w, h, false));
    try testing.expectEqual(@as(?Edge, .bottom_right), hitContent(799, h - corner, w, h, false));
    // The top of the side edges is a plain side (the bar has the corner).
    try testing.expectEqual(@as(?Edge, .left), hitContent(1, 1, w, h, false));
    try testing.expectEqual(@as(?Edge, null), hitContent(0, 300, w, h, true));
    try testing.expectEqual(@as(?Edge, null), hitContent(-1, 300, w, h, false));
    try testing.expectEqual(@as(?Edge, null), hitContent(10, 600, w, h, false));
}

test "cursors follow the edge" {
    try testing.expectEqual(Cursor.default, cursorFor(.title));
    try testing.expectEqual(Cursor.default, cursorFor(.close));
    try testing.expectEqual(Cursor.n, cursorFor(.{ .edge = .top }));
    try testing.expectEqual(Cursor.se, cursorFor(.{ .edge = .bottom_right }));
    try testing.expectEqual(Cursor.nw, cursorFor(.{ .edge = .top_left }));
}

test "Layout: scaled sizes, the close button at the right end, title room" {
    const l1 = Layout.init(800, 1);
    try testing.expectEqual(@as(u32, 800), l1.w);
    try testing.expectEqual(@as(u32, bar_h), l1.h);
    try testing.expectEqual(@as(u32, 800 - close_w), l1.close_x);
    try testing.expectEqual(@as(u32, title_pad), l1.title_x);
    try testing.expectEqual(@as(u32, 800 - close_w - title_pad), l1.title_end);
    const l2 = Layout.init(800, 2);
    try testing.expectEqual(@as(u32, 1600), l2.w);
    try testing.expectEqual(@as(u32, 2 * bar_h), l2.h);
    try testing.expectEqual(@as(u32, 1600 - 2 * close_w), l2.close_x);
    try testing.expectEqual(@as(f32, 2 * title_em), l2.em);
    // Narrower than the close button: nothing underflows.
    const l3 = Layout.init(20, 1);
    try testing.expectEqual(@as(u32, 0), l3.close_x);
    try testing.expect(l3.title_end >= l3.title_x);
}

const TestGlyphs = struct {
    calls: u32 = 0,
    fn width(cp: u21) u2 {
        return if (cp >= 0x1100) 2 else 1;
    }
    fn render(ctx: *anyopaque, _: u21, _: u32, cov: []u8) void {
        const self: *TestGlyphs = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        @memset(cov, 255);
    }
};

test "draw: background, hovered close button, cross, title cut with an ellipsis" {
    const gpa = testing.allocator;
    const l = Layout.init(200, 1);
    const px = try gpa.alloc(u32, @as(usize, l.w) * l.h);
    defer gpa.free(px);
    var scratch: [2 * 8 * 16]u8 = undefined;
    var tg: TestGlyphs = .{};
    const g: Glyphs = .{ .ctx = &tg, .cell_w = 8, .cell_h = 16, .width = TestGlyphs.width, .render = TestGlyphs.render };
    const colors: Colors = .{};
    draw(px, l, colors, .{ .active = true, .close_hover = true }, "a long window title here", g, &scratch);
    // Corner of the bar: the background.
    try testing.expectEqual(rgb(colors.bar), px[0]);
    // The close button's corner: its hover colour; its centre: the cross.
    try testing.expectEqual(rgb(colors.close_hover), px[l.close_x + 1]);
    const centre = (l.h / 2) * l.w + (l.close_x + l.w) / 2;
    try testing.expect(px[centre] != rgb(colors.close_hover));
    // Room for (title_end - title_x) / 8 cells: the last one is the ellipsis.
    const room_cells = (l.title_end - l.title_x) / 8;
    try testing.expectEqual(room_cells, tg.calls);
    // A title glyph's pixel is the title colour.
    try testing.expectEqual(rgb(colors.title), px[((l.h - 16) / 2) * l.w + l.title_x]);
    // Inactive, not hovered: the inactive bar colour everywhere but the text.
    draw(px, l, colors, .{ .active = false }, "", null, &.{});
    try testing.expectEqual(rgb(colors.bar_inactive), px[l.close_x + 1]);
}
