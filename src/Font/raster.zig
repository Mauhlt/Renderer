//! Scanline coverage rasterizer for glyph outlines (quadratic B-splines).
//!
//! Exact-area antialiasing: each line segment adds its signed area and
//! coverage to an accumulation buffer, and a running sum turns that into
//! per-pixel coverage (the approach used by font-rs / stb_truetype v2).
//! Non-zero winding is approximated by clamping |sum| to 1, which is exact
//! for well-formed fonts (no self-overlapping contours).

const std = @import("std");
const ttf = @import("ttf.zig");

pub const Transform = struct {
    /// pixel = (unit * scale) with y flipped around the baseline.
    scale: f32,
    /// Pixel position of the font-unit origin inside the bitmap.
    origin_x: f32,
    baseline_y: f32,
    /// Horizontal shear for synthetic italics (pixels per pixel of height).
    skew: f32 = 0,
};

pub const Canvas = struct {
    w: u32,
    h: u32,
    acc: []f32,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Canvas {
        const n = @as(usize, w) * h + 4;
        const acc = try gpa.alloc(f32, n);
        @memset(acc, 0);
        return .{ .w = w, .h = h, .acc = acc };
    }

    pub fn deinit(c: *Canvas, gpa: std.mem.Allocator) void {
        gpa.free(c.acc);
    }

    fn clampX(c: *const Canvas, x: f32) f32 {
        if (!(x >= 0)) return 0; // also catches NaN
        const wf: f32 = @floatFromInt(c.w);
        return @min(x, wf);
    }

    pub fn line(c: *Canvas, ax: f32, ay: f32, bx: f32, by: f32) void {
        if (!std.math.isFinite(ax) or !std.math.isFinite(ay) or !std.math.isFinite(bx) or !std.math.isFinite(by)) return;
        if (ay == by) return;
        const dir: f32 = if (ay < by) 1 else -1;
        var x0 = ax;
        var y0 = ay;
        var x1 = bx;
        var y1 = by;
        if (dir < 0) {
            std.mem.swap(f32, &x0, &x1);
            std.mem.swap(f32, &y0, &y1);
        }
        const hf: f32 = @floatFromInt(c.h);
        if (y1 <= 0 or y0 >= hf) return;
        const dxdy = (x1 - x0) / (y1 - y0);
        var x = x0;
        if (y0 < 0) {
            x -= y0 * dxdy;
            y0 = 0;
        }
        if (y1 > hf) y1 = hf;
        const ystart: u32 = @intFromFloat(@floor(y0));
        const yend: u32 = @intFromFloat(@ceil(y1));
        var y = ystart;
        while (y < yend) : (y += 1) {
            const yf: f32 = @floatFromInt(y);
            const dy = @min(yf + 1, y1) - @max(yf, y0);
            const xnext = x + dxdy * dy;
            const d = dy * dir;
            var xa = c.clampX(x);
            var xb = c.clampX(xnext);
            if (xa > xb) std.mem.swap(f32, &xa, &xb);
            const linestart = @as(usize, y) * c.w;
            const xa_floor = @floor(xa);
            const xai: usize = @intFromFloat(xa_floor);
            const xb_ceil = @ceil(xb);
            const xbi: usize = @intFromFloat(xb_ceil);
            if (xbi <= xai + 1) {
                const xmf = 0.5 * (xa + xb) - xa_floor;
                c.add(linestart + xai, d - d * xmf);
                c.add(linestart + xai + 1, d * xmf);
            } else {
                const s = 1.0 / (xb - xa);
                const x0f = xa - xa_floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = xb - xb_ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                c.add(linestart + xai, d * a0);
                if (xbi == xai + 2) {
                    c.add(linestart + xai + 1, d * (1 - a0 - am));
                } else {
                    const a1 = s * (1.5 - x0f);
                    c.add(linestart + xai + 1, d * (a1 - a0));
                    var xi = xai + 2;
                    while (xi < xbi - 1) : (xi += 1) c.add(linestart + xi, d * s);
                    const a2 = a1 + @as(f32, @floatFromInt(xbi - xai - 3)) * s;
                    c.add(linestart + xbi - 1, d * (1 - a2 - am));
                }
                c.add(linestart + xbi, d * am);
            }
            x = xnext;
        }
    }

    inline fn add(c: *Canvas, i: usize, v: f32) void {
        if (i < c.acc.len) c.acc[i] += v;
    }

    pub fn quad(c: *Canvas, x0: f32, y0: f32, cx: f32, cy: f32, x1: f32, y1: f32) void {
        const ddx = x0 - 2 * cx + x1;
        const ddy = y0 - 2 * cy + y1;
        const dev = @sqrt(ddx * ddx + ddy * ddy);
        if (!std.math.isFinite(dev)) return;
        const n: u32 = @intFromFloat(std.math.clamp(@ceil(@sqrt(dev * 1.5)), 1, 24));
        var px = x0;
        var py = y0;
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const mt = 1 - t;
            const nx = mt * mt * x0 + 2 * mt * t * cx + t * t * x1;
            const ny = mt * mt * y0 + 2 * mt * t * cy + t * t * y1;
            c.line(px, py, nx, ny);
            px = nx;
            py = ny;
        }
    }

    /// Converts accumulated area into 8-bit coverage, `out.len == w*h`.
    pub fn finish(c: *const Canvas, out: []u8) void {
        var sum: f32 = 0;
        const n = @min(out.len, @as(usize, c.w) * c.h);
        for (0..n) |i| {
            sum += c.acc[i];
            const a = @min(@abs(sum), 1.0);
            out[i] = @intFromFloat(a * 255.0 + 0.5);
        }
    }
};

/// Draws `outline` into `canvas` with transform `t`.
pub fn fillOutline(canvas: *Canvas, outline: *const ttf.Outline, t: Transform) void {
    const pts = outline.points.items;
    var start: usize = 0;
    for (outline.contour_ends.items) |end_u| {
        const end: usize = end_u;
        if (end > pts.len or end <= start) {
            start = @max(start, @min(end, pts.len));
            continue;
        }
        contour(canvas, pts[start..end], t);
        start = end;
    }
}

fn toPx(t: Transform, p: ttf.Point) [2]f32 {
    const y = t.baseline_y - p.y * t.scale;
    const x = t.origin_x + p.x * t.scale + (t.baseline_y - y) * t.skew;
    return .{ x, y };
}

fn mid(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

fn contour(c: *Canvas, pts: []const ttf.Point, t: Transform) void {
    const n = pts.len;
    if (n < 2) return;
    // Find a starting on-curve point (or synthesise one between two off points).
    var first: usize = 0;
    var start_pt: [2]f32 = undefined;
    while (first < n and !pts[first].on) : (first += 1) {}
    if (first == n) {
        start_pt = mid(toPx(t, pts[0]), toPx(t, pts[1]));
        first = 0;
    } else {
        start_pt = toPx(t, pts[first]);
    }
    var cur = start_pt;
    var ctrl: ?[2]f32 = null;
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        const p = pts[(first + k) % n];
        const pp = toPx(t, p);
        if (p.on) {
            if (ctrl) |cc| {
                c.quad(cur[0], cur[1], cc[0], cc[1], pp[0], pp[1]);
                ctrl = null;
            } else {
                c.line(cur[0], cur[1], pp[0], pp[1]);
            }
            cur = pp;
        } else {
            if (ctrl) |cc| {
                const m = mid(cc, pp);
                c.quad(cur[0], cur[1], cc[0], cc[1], m[0], m[1]);
                cur = m;
            }
            ctrl = pp;
        }
    }
    // Close back to the start.
    if (ctrl) |cc| {
        c.quad(cur[0], cur[1], cc[0], cc[1], start_pt[0], start_pt[1]);
    } else {
        c.line(cur[0], cur[1], start_pt[0], start_pt[1]);
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "filled square has full interior coverage and AA edges" {
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit(gpa);
    // Square from (1.5,1.5) to (6.5,6.5), clockwise in pixel space.
    c.line(1.5, 1.5, 6.5, 1.5);
    c.line(6.5, 1.5, 6.5, 6.5);
    c.line(6.5, 6.5, 1.5, 6.5);
    c.line(1.5, 6.5, 1.5, 1.5);
    var out: [64]u8 = undefined;
    c.finish(&out);
    try testing.expectEqual(@as(u8, 255), out[3 * 8 + 3]);
    try testing.expectEqual(@as(u8, 0), out[0]);
    try testing.expectEqual(@as(u8, 0), out[7 * 8 + 7]);
    // Edge pixel is half covered.
    const e = out[3 * 8 + 1];
    try testing.expect(e > 100 and e < 155);
}

test "lines outside the canvas and NaN never write out of bounds" {
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit(gpa);
    c.line(-100, -100, 1e9, 1e9);
    c.line(std.math.nan(f32), 0, 1, 1);
    c.line(0, -5, 3, 50);
    c.quad(-1e30, 0, 1e30, 2, 3, 1e30);
    var out: [16]u8 = undefined;
    c.finish(&out);
}

test "rasterize a real glyph" {
    const gpa = testing.allocator;
    const data = ttf.test_font;
    const f = try ttf.Font.init(data, 0);
    var o: ttf.Outline = .{};
    defer o.deinit(gpa);
    try f.glyphOutline(gpa, f.glyphIndex('O'), &o);
    const size: f32 = 32;
    const scale = size / @as(f32, @floatFromInt(f.units_per_em));
    var c = try Canvas.init(gpa, 20, 40);
    defer c.deinit(gpa);
    fillOutline(&c, &o, .{ .scale = scale, .origin_x = 0, .baseline_y = 30 });
    var out: [20 * 40]u8 = undefined;
    c.finish(&out);
    // 'O' has a hole: the centre is empty, the left stroke is inked.
    const row = 20 * 20;
    try testing.expect(out[row + 9] < 40);
    var inked: usize = 0;
    for (out) |v| inked += @intFromBool(v > 128);
    try testing.expect(inked > 40);
}
