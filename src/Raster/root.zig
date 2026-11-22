//! Public module "Raster" (see build.zig): 2D drawing on the CPU into a
//! caller-owned RGBA8 buffer, for targets without a GPU path (a browser:
//! wasm32-freestanding, the buffer copied to a canvas with putImageData).
//! Only std: no OS, no Vulkan, no allocator.
//!
//!     var r = Raster.init(pixels, width, height, width * 4);
//!     r.clear(.{ 16, 16, 20, 255 });
//!     r.fillRect(10.5, 20, 100, 30.25, .{ 255, 0, 0, 128 }, null);
//!     const g = cache.get(&fonts, 'A', .{}, m, 1).?;       // Font.glyphcache
//!     r.mask(g.coverage, g.w, g.h, x, y, .{ 230, 230, 230, 255 }, clip);
//!     r.image(rgba, src_w, src_h, .{ .x = 0, .y = 0, .w = 300, .h = 200 }, clip);
//!
//! Pixel format. Bytes R, G, B, A in memory order (the order of a canvas
//! ImageData), `stride` bytes from one row to the next. Colours are
//! straight (not premultiplied) alpha and sRGB-encoded; they are blended
//! as stored, without converting to linear light. This is exactly what
//! Instanced2D does (UNORM swapchain, colours passed through unchanged;
//! blend colour = src * src_alpha + dst * (1 - src_alpha), alpha = src_alpha
//! + dst_alpha * (1 - src_alpha)), so a frame drawn here looks the same as
//! the Vulkan one. Clear to an opaque colour first: then every pixel stays
//! opaque and straight and premultiplied mean the same bytes (what
//! putImageData expects). Each blend rounds to the nearest 8-bit value; the
//! GPU blends in float, so a channel can differ by one step.
//!
//! Geometry. Coordinates are pixels, origin top left; pixel (i, j) covers
//! [i, i+1) x [j, j+1). `fillRect` anti-aliases fractional edges by exact
//! area coverage (on whole-pixel rectangles it matches the GPU exactly).
//! `mask` and `image` draw the pixels whose centres lie inside their
//! destination, as the GPU rasterises a quad. The optional `clip` is a hard
//! edge by the same pixel-centre rule: a pixel is drawn only when its
//! centre lies inside the clip rectangle.
//!
//! Speed: the inner loops work on `vec_bytes` bytes at a time
//! (std.simd.suggestVectorLength: SIMD128 on wasm when the build enables
//! the simd128 feature, NEON, SSE/AVX); there are no per-pixel calls
//! through pointers. Not thread-safe per buffer.

const std = @import("std");

const Raster = @This();

pixels: []u8,
width: u32,
height: u32,
/// Bytes from the start of one row to the next (>= width * 4).
stride: usize,

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Bytes per vector step in the inner loops (a whole number of pixels).
pub const vec_bytes: comptime_int = @max(16, std.simd.suggestVectorLength(u8) orelse 16);
const vec_px = vec_bytes / 4;

const V8 = @Vector(vec_bytes, u8);
const V16 = @Vector(vec_bytes, u16);
const P16 = @Vector(vec_px, u16);

/// `pixels` must hold `height` rows of `stride` bytes (the last row needs
/// only `width * 4`).
pub fn init(pixels: []u8, width: u32, height: u32, stride: usize) Raster {
    std.debug.assert(stride >= @as(usize, width) * 4);
    std.debug.assert(height == 0 or pixels.len >= stride * (height - 1) + @as(usize, width) * 4);
    return .{ .pixels = pixels, .width = width, .height = height, .stride = stride };
}

/// Sets every pixel to `rgba` (no blending).
pub fn clear(r: *Raster, rgba: [4]u8) void {
    if (r.width == 0) return;
    const w = @as(usize, r.width) * 4;
    for (0..r.height) |y| fill(r.pixels[y * r.stride ..][0..w], rgba);
}

/// Blends `rgba` over the rectangle (x, y, w, h). Fractional edges are
/// anti-aliased by the share of each pixel the rectangle covers.
pub fn fillRect(r: *Raster, x: f32, y: f32, w: f32, h: f32, rgba: [4]u8, clip: ?Rect) void {
    if (rgba[3] == 0 or !(w > 0) or !(h > 0) or std.math.isNan(x + y + w + h)) return;
    const b = r.bounds(clip);
    // Keep the edges finite and near the buffer: coverage there is unchanged.
    const x0 = std.math.clamp(x, -1, @as(f32, @floatFromInt(r.width)) + 1);
    const x1 = std.math.clamp(x + w, -1, @as(f32, @floatFromInt(r.width)) + 1);
    const y0 = std.math.clamp(y, -1, @as(f32, @floatFromInt(r.height)) + 1);
    const y1 = std.math.clamp(y + h, -1, @as(f32, @floatFromInt(r.height)) + 1);
    const cx0 = @max(b.x0, floorPx(x0));
    const cx1 = @min(b.x1, ceilPx(x1));
    const cy0 = @max(b.y0, floorPx(y0));
    const cy1 = @min(b.y1, ceilPx(y1));
    if (cx0 >= cx1 or cy0 >= cy1) return;
    const src = opaqueOf(rgba);
    // Only the first and last column can be partly covered.
    const first = cx0;
    const last = cx1 - 1;
    const cov_first = overlap(first, x0, x1);
    const cov_last = overlap(last, x0, x1);
    var py = cy0;
    while (py < cy1) : (py += 1) {
        const cy = overlap(py, y0, y1);
        const row = r.rowBytes(py);
        blendPx(row[@as(usize, first) * 4 ..][0..4], src, alphaOf(rgba[3], cov8(cov_first * cy)));
        if (last > first) blendPx(row[@as(usize, last) * 4 ..][0..4], src, alphaOf(rgba[3], cov8(cov_last * cy)));
        if (last > first + 1) {
            const span = row[(@as(usize, first) + 1) * 4 .. @as(usize, last) * 4];
            const a = alphaOf(rgba[3], cov8(cy));
            if (a == 255) fill(span, src) else if (a != 0) blendSpan(span, src, a);
        }
    }
}

/// Blends `rgba` through an 8-bit coverage mask (`mw * mh` bytes, row-major;
/// a glyph from Font.glyphcache) whose top left pixel goes to (x, y). Each
/// pixel's alpha is rgba[3] * coverage / 255, as the GPU path's white glyph
/// texel with alpha = coverage, tinted by the colour, gives.
pub fn mask(r: *Raster, coverage: []const u8, mw: u32, mh: u32, x: i32, y: i32, rgba: [4]u8, clip: ?Rect) void {
    if (rgba[3] == 0 or coverage.len < @as(usize, mw) * mh) return;
    const b = r.bounds(clip);
    const bx0 = @max(@as(i64, b.x0), x);
    const bx1 = @min(@as(i64, b.x1), @as(i64, x) + mw);
    const by0 = @max(@as(i64, b.y0), y);
    const by1 = @min(@as(i64, b.y1), @as(i64, y) + mh);
    if (bx0 >= bx1 or by0 >= by1) return;
    const src = opaqueOf(rgba);
    const n: usize = @intCast(bx1 - bx0);
    const mx: usize = @intCast(bx0 - x);
    var py = by0;
    while (py < by1) : (py += 1) {
        const my: usize = @intCast(py - y);
        const cov = coverage[my * mw + mx ..][0..n];
        const row = r.rowBytes(@intCast(py))[@as(usize, @intCast(bx0)) * 4 ..][0 .. n * 4];
        maskRow(row, cov, src, rgba[3]);
    }
}

/// Draws an RGBA8 image (`sw * sh` pixels, tightly packed, straight alpha)
/// scaled into `dst` with bilinear filtering (texel centres at half
/// pixels, edges clamped, as a GPU's linear sampler), blended over the
/// buffer by its own alpha.
pub fn image(r: *Raster, src: []const u8, sw: u32, sh: u32, dst: Rect, clip: ?Rect) void {
    if (sw == 0 or sh == 0 or src.len < @as(usize, sw) * sh * 4) return;
    if (!(dst.w > 0) or !(dst.h > 0) or std.math.isNan(dst.x + dst.y + dst.w + dst.h)) return;
    const b = r.bounds(clip);
    const x0 = @max(b.x0, centrePx(dst.x, r.width));
    const x1 = @min(b.x1, centrePx(dst.x + dst.w, r.width));
    const y0 = @max(b.y0, centrePx(dst.y, r.height));
    const y1 = @min(b.y1, centrePx(dst.y + dst.h, r.height));
    if (x0 >= x1 or y0 >= y1) return;
    // Source position of a destination pixel centre, in 16.16 fixed point:
    // u = (px + 0.5 - dst.x) * sw / dst.w - 0.5.
    const sx: f64 = @as(f64, @floatFromInt(sw)) / dst.w;
    const sy: f64 = @as(f64, @floatFromInt(sh)) / dst.h;
    const du: i64 = @intFromFloat(@round(sx * 65536));
    const dv: i64 = @intFromFloat(@round(sy * 65536));
    const u_start: i64 = @intFromFloat(@round(((@as(f64, @floatFromInt(x0)) + 0.5 - dst.x) * sx - 0.5) * 65536));
    const v_start: i64 = @intFromFloat(@round(((@as(f64, @floatFromInt(y0)) + 0.5 - dst.y) * sy - 0.5) * 65536));
    const max_x: i64 = sw - 1;
    const max_y: i64 = sh - 1;
    const src_stride = @as(usize, sw) * 4;
    const W = @Vector(4, u32);
    // Columns in chunks: their source columns and weights worked out once
    // for all rows.
    const chunk = 256;
    var ia: [chunk]u32 = undefined;
    var ib: [chunk]u32 = undefined;
    var wx: [chunk]u32 = undefined;
    var cx = x0;
    while (cx < x1) : (cx += chunk) {
        const n = @min(chunk, x1 - cx);
        var u = u_start + @as(i64, cx - x0) * du;
        for (0..n) |i| {
            const ux = u >> 16;
            ia[i] = @intCast(std.math.clamp(ux, 0, max_x) * 4);
            ib[i] = @intCast(std.math.clamp(ux + 1, 0, max_x) * 4);
            wx[i] = @intCast((u >> 8) & 0xFF);
            u += du;
        }
        var v = v_start;
        var py = y0;
        while (py < y1) : ({
            py += 1;
            v += dv;
        }) {
            const vy = v >> 16;
            const fy: W = @splat(@intCast((v >> 8) & 0xFF));
            const gy = @as(W, @splat(256)) - fy;
            const ra = src[@as(usize, @intCast(std.math.clamp(vy, 0, max_y))) * src_stride ..][0..src_stride];
            const rb = src[@as(usize, @intCast(std.math.clamp(vy + 1, 0, max_y))) * src_stride ..][0..src_stride];
            const row = r.rowBytes(py)[@as(usize, cx) * 4 ..][0 .. n * 4];
            for (0..n) |i| {
                const fx: W = @splat(wx[i]);
                const gx = @as(W, @splat(256)) - fx;
                const p00: W = @as(@Vector(4, u8), ra[ia[i]..][0..4].*);
                const p10: W = @as(@Vector(4, u8), ra[ib[i]..][0..4].*);
                const p01: W = @as(@Vector(4, u8), rb[ia[i]..][0..4].*);
                const p11: W = @as(@Vector(4, u8), rb[ib[i]..][0..4].*);
                const top = p00 * gx + p10 * fx;
                const bot = p01 * gx + p11 * fx;
                const s: @Vector(4, u8) = @truncate((top * gy + bot * fy + @as(W, @splat(32768))) >> @splat(16));
                blendPx(row[i * 4 ..][0..4], .{ s[0], s[1], s[2], 255 }, s[3]);
            }
        }
    }
}

// ------------------------------------------------------------ internals

/// The drawable pixel box: the buffer, cut by `clip` (pixel centres inside).
const Box = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

fn bounds(r: *const Raster, clip: ?Rect) Box {
    const c = clip orelse return .{ .x0 = 0, .y0 = 0, .x1 = r.width, .y1 = r.height };
    const x0 = centrePx(c.x, r.width);
    const y0 = centrePx(c.y, r.height);
    return .{ .x0 = x0, .y0 = y0, .x1 = @max(x0, centrePx(c.x + c.w, r.width)), .y1 = @max(y0, centrePx(c.y + c.h, r.height)) };
}

fn rowBytes(r: *const Raster, y: u32) []u8 {
    return r.pixels[@as(usize, y) * r.stride ..][0 .. @as(usize, r.width) * 4];
}

/// The first pixel whose centre is at or right of `v`, within [0, limit].
fn centrePx(v: f32, limit: u32) u32 {
    const c = @ceil(v - 0.5);
    if (!(c > 0)) return 0; // also NaN
    if (c >= @as(f32, @floatFromInt(limit))) return limit;
    return @intFromFloat(c);
}

/// floor / ceil of an edge already clamped to [-1, limit + 1], as a pixel
/// index clamped at 0 (the caller clamps the top end by the clip box).
fn floorPx(v: f32) u32 {
    return @intFromFloat(@max(0, @floor(v)));
}

fn ceilPx(v: f32) u32 {
    return @intFromFloat(@max(0, @ceil(v)));
}

/// How much of pixel [i, i+1) lies inside [a, b), 0..1.
fn overlap(i: u32, a: f32, b: f32) f32 {
    const f: f32 = @floatFromInt(i);
    return std.math.clamp(@min(f + 1, b) - @max(f, a), 0, 1);
}

fn cov8(c: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255));
}

/// Colour alpha times coverage, both 0..255.
fn alphaOf(a: u8, cov: u8) u8 {
    return @intCast(div255(@as(u32, a) * cov));
}

/// The source as blended: alpha byte 255, so one formula serves all four
/// channels (out = s * A + d * (1 - A) gives out_a = A + d_a * (1 - A)).
fn opaqueOf(c: [4]u8) [4]u8 {
    return .{ c[0], c[1], c[2], 255 };
}

/// round(x / 255) for x in 0..65535 (exact), on a scalar or a vector.
inline fn div255(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    const vector = @typeInfo(T) == .vector;
    const k128: T = if (vector) @splat(128) else 128;
    const k8 = if (vector) @as(@Vector(@typeInfo(T).vector.len, u4), @splat(8)) else 8;
    const t = x + k128;
    return (t + (t >> k8)) >> k8;
}

fn blendPx(p: *[4]u8, s: [4]u8, a: u8) void {
    if (a == 0) return;
    if (a == 255) {
        p.* = s;
        return;
    }
    const inv: u32 = 255 - a;
    inline for (0..4) |k| p[k] = @intCast(div255(@as(u32, s[k]) * a + @as(u32, p[k]) * inv));
}

/// `px` repeated across one vector.
fn pattern(px: [4]u8) V8 {
    const m = comptime blk: {
        var idx: [vec_bytes]i32 = undefined;
        for (&idx, 0..) |*v, i| v.* = @intCast(i % 4);
        break :blk idx;
    };
    return @shuffle(u8, @as(@Vector(4, u8), px), undefined, m);
}

/// Each of `vec_px` values repeated for the four bytes of its pixel.
fn perPixel(v: P16) V16 {
    const m = comptime blk: {
        var idx: [vec_bytes]i32 = undefined;
        for (&idx, 0..) |*e, i| e.* = @intCast(i / 4);
        break :blk idx;
    };
    return @shuffle(u16, v, undefined, m);
}

/// Sets every pixel of `dst` (a whole number of pixels) to `px`.
fn fill(dst: []u8, px: [4]u8) void {
    const p = pattern(px);
    var i: usize = 0;
    while (i + vec_bytes <= dst.len) : (i += vec_bytes) dst[i..][0..vec_bytes].* = p;
    while (i < dst.len) : (i += 4) dst[i..][0..4].* = px;
}

/// Blends `s` (alpha byte 255) over every pixel of `dst` with alpha `a`.
fn blendSpan(dst: []u8, s: [4]u8, a: u8) void {
    const sa: V16 = @as(V16, pattern(s)) * @as(V16, @splat(a));
    const inv: V16 = @splat(255 - @as(u16, a));
    var i: usize = 0;
    while (i + vec_bytes <= dst.len) : (i += vec_bytes) {
        const d: V16 = @as(V8, dst[i..][0..vec_bytes].*);
        const o: V8 = @truncate(div255(sa + d * inv));
        dst[i..][0..vec_bytes].* = o;
    }
    while (i < dst.len) : (i += 4) blendPx(dst[i..][0..4], s, a);
}

/// Blends `s` (alpha byte 255) over `dst` with alpha `a * cov[i] / 255`
/// per pixel.
fn maskRow(dst: []u8, cov: []const u8, s: [4]u8, a: u8) void {
    const sv: V16 = pattern(s);
    const sp = pattern(s);
    const av: P16 = @splat(a);
    const full: @Vector(vec_px, u8) = @splat(255);
    const empty: @Vector(vec_px, u8) = @splat(0);
    var i: usize = 0;
    while (i + vec_px <= cov.len) : (i += vec_px) {
        const c8: @Vector(vec_px, u8) = cov[i..][0..vec_px].*;
        if (@reduce(.And, c8 == empty)) continue;
        const o = dst[i * 4 ..][0..vec_bytes];
        if (a == 255 and @reduce(.And, c8 == full)) {
            o.* = sp;
            continue;
        }
        const alpha = perPixel(div255(@as(P16, c8) * av));
        const d: V16 = @as(V8, o.*);
        const out: V8 = @truncate(div255(sv * alpha + d * (@as(V16, @splat(255)) - alpha)));
        o.* = out;
    }
    while (i < cov.len) : (i += 1) blendPx(dst[i * 4 ..][0..4], s, alphaOf(a, cov[i]));
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn testRaster(buf: []u8, w: u32, h: u32) Raster {
    var r = Raster.init(buf, w, h, @as(usize, w) * 4);
    r.clear(.{ 0, 0, 0, 255 });
    return r;
}

fn at(r: *const Raster, x: u32, y: u32) [4]u8 {
    return r.pixels[@as(usize, y) * r.stride + @as(usize, x) * 4 ..][0..4].*;
}

/// The exact blend of `s` with alpha `a` over `d`, for checks.
fn expectBlend(s: [4]u8, a: u8, d: [4]u8) [4]u8 {
    var o: [4]u8 = undefined;
    for (0..4) |k| {
        const sk: u32 = if (k == 3) 255 else s[k];
        o[k] = @intFromFloat(@round((@as(f64, @floatFromInt(sk)) * @as(f64, @floatFromInt(a)) + @as(f64, @floatFromInt(d[k])) * @as(f64, @floatFromInt(255 - a))) / 255));
    }
    return o;
}

test "clear sets every pixel, stride padding untouched" {
    var buf: [3 * 20]u8 = @splat(7);
    var r = Raster.init(&buf, 3, 3, 20);
    r.clear(.{ 1, 2, 3, 4 });
    for (0..3) |y| for (0..3) |x| try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, at(&r, @intCast(x), @intCast(y)));
    try testing.expectEqual(@as(u8, 7), buf[12]); // first padding byte of row 0
    try testing.expectEqual(@as(u8, 7), buf[19]);
}

test "fillRect: whole-pixel rectangle, exact edges" {
    var buf: [40 * 10 * 4]u8 = undefined;
    var r = testRaster(&buf, 40, 10);
    r.fillRect(2, 3, 33, 4, .{ 200, 100, 50, 255 }, null);
    for (0..10) |y| for (0..40) |x| {
        const inside = x >= 2 and x < 35 and y >= 3 and y < 7;
        const want: [4]u8 = if (inside) .{ 200, 100, 50, 255 } else .{ 0, 0, 0, 255 };
        try testing.expectEqual(want, at(&r, @intCast(x), @intCast(y)));
    };
}

test "fillRect: alpha blending matches the GPU's over" {
    var buf: [37 * 3 * 4]u8 = undefined;
    var r = testRaster(&buf, 37, 3);
    r.clear(.{ 10, 200, 30, 255 });
    r.fillRect(0, 0, 37, 3, .{ 250, 0, 128, 77 }, null);
    const want = expectBlend(.{ 250, 0, 128, 77 }, 77, .{ 10, 200, 30, 255 });
    for (0..3) |y| for (0..37) |x| try testing.expectEqual(want, at(&r, @intCast(x), @intCast(y)));
    // Every alpha, through both the vector span and the edge pixels.
    for (0..256) |a| {
        r.clear(.{ 90, 160, 220, 255 });
        r.fillRect(0, 0, 37, 1, .{ 20, 240, 100, @intCast(a) }, null);
        const w = expectBlend(.{ 20, 240, 100, 0 }, @intCast(a), .{ 90, 160, 220, 255 });
        for (0..37) |x| try testing.expectEqual(w, at(&r, @intCast(x), 0));
    }
}

test "fillRect: fractional edges are covered by area" {
    var buf: [8 * 8 * 4]u8 = undefined;
    var r = testRaster(&buf, 8, 8);
    // x 1.5 .. 5.25, y 2 .. 3.5
    r.fillRect(1.5, 2, 3.75, 1.5, .{ 255, 255, 255, 255 }, null);
    try testing.expectEqual(@as(u8, 0), at(&r, 0, 2)[0]);
    try testing.expectEqual(@as(u8, 128), at(&r, 1, 2)[0]); // half
    try testing.expectEqual(@as(u8, 255), at(&r, 2, 2)[0]);
    try testing.expectEqual(@as(u8, 255), at(&r, 4, 2)[0]);
    try testing.expectEqual(@as(u8, 64), at(&r, 5, 2)[0]); // a quarter
    try testing.expectEqual(@as(u8, 0), at(&r, 6, 2)[0]);
    try testing.expectEqual(@as(u8, 128), at(&r, 3, 3)[0]); // bottom row half
    try testing.expectEqual(@as(u8, 64), at(&r, 1, 3)[0]); // half x half
    try testing.expectEqual(@as(u8, 32), at(&r, 5, 3)[0]); // quarter x half
    try testing.expectEqual(@as(u8, 0), at(&r, 3, 4)[0]);
    try testing.expectEqual(@as(u8, 255), at(&r, 1, 2)[3]); // opaque stays opaque
    // A rectangle inside one pixel.
    r.clear(.{ 0, 0, 0, 255 });
    r.fillRect(3.25, 3.25, 0.5, 0.5, .{ 255, 255, 255, 255 }, null);
    try testing.expectEqual(@as(u8, 64), at(&r, 3, 3)[0]);
    try testing.expectEqual(@as(u8, 0), at(&r, 4, 3)[0]);
}

test "fillRect: off-buffer, empty and NaN rectangles are safe" {
    var buf: [4 * 4 * 4]u8 = undefined;
    var r = testRaster(&buf, 4, 4);
    const white: [4]u8 = .{ 255, 255, 255, 255 };
    r.fillRect(-100, -100, 50, 50, white, null);
    r.fillRect(10, 1, 5, 5, white, null);
    r.fillRect(1, 1, 0, 3, white, null);
    r.fillRect(1, 1, -2, 3, white, null);
    r.fillRect(std.math.nan(f32), 0, 2, 2, white, null);
    r.fillRect(0, 0, std.math.inf(f32), 1, white, .{ .x = std.math.nan(f32), .y = 0, .w = 4, .h = 4 });
    for (0..4) |y| for (0..4) |x| try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(&r, @intCast(x), @intCast(y)));
    r.fillRect(-1e30, -1e30, std.math.inf(f32), std.math.inf(f32), white, null);
    for (0..4) |y| for (0..4) |x| try testing.expectEqual(white, at(&r, @intCast(x), @intCast(y)));
}

test "clip: pixel centres inside the clip rectangle are drawn" {
    var buf: [10 * 10 * 4]u8 = undefined;
    var r = testRaster(&buf, 10, 10);
    // Centres 2.5..5.5 lie in [2.4, 6.0) on x, 7.5 in [7, 8) on y.
    r.fillRect(0, 0, 10, 10, .{ 255, 0, 0, 255 }, .{ .x = 2.4, .y = 7, .w = 3.6, .h = 1 });
    for (0..10) |y| for (0..10) |x| {
        const inside = x >= 2 and x < 6 and y == 7;
        try testing.expectEqual(@as(u8, if (inside) 255 else 0), at(&r, @intCast(x), @intCast(y))[0]);
    };
    // Clip and anti-aliased edge together: the edge keeps its coverage.
    r.clear(.{ 0, 0, 0, 255 });
    r.fillRect(1.5, 0, 5, 1, .{ 255, 0, 0, 255 }, .{ .x = 0, .y = 0, .w = 3, .h = 10 });
    try testing.expectEqual(@as(u8, 128), at(&r, 1, 0)[0]);
    try testing.expectEqual(@as(u8, 255), at(&r, 2, 0)[0]);
    try testing.expectEqual(@as(u8, 0), at(&r, 3, 0)[0]);
    // A clip outside the buffer, or empty, draws nothing.
    r.clear(.{ 0, 0, 0, 255 });
    r.fillRect(0, 0, 10, 10, .{ 255, 0, 0, 255 }, .{ .x = 20, .y = 0, .w = 5, .h = 5 });
    r.fillRect(0, 0, 10, 10, .{ 255, 0, 0, 255 }, .{ .x = 3, .y = 3, .w = -1, .h = 5 });
    for (0..10) |y| for (0..10) |x| try testing.expectEqual(@as(u8, 0), at(&r, @intCast(x), @intCast(y))[0]);
}

test "mask: coverage blit tints and blends per pixel, clipped" {
    // A mask wider than one vector step, so both paths run.
    const mw = vec_px * 2 + 3;
    var cov: [mw * 2]u8 = undefined;
    for (&cov, 0..) |*c, i| c.* = @intCast((i * 37) % 256);
    cov[0] = 255;
    cov[1] = 0;
    var buf: [(mw + 4) * 4 * 4]u8 = undefined;
    var r = testRaster(&buf, mw + 4, 4);
    const bg: [4]u8 = .{ 40, 50, 60, 255 };
    r.clear(bg);
    const c: [4]u8 = .{ 250, 200, 10, 180 };
    r.mask(&cov, mw, 2, 2, 1, c, null);
    for (0..4) |y| for (0..mw + 4) |x| {
        const in = x >= 2 and x < mw + 2 and y >= 1 and y < 3;
        const want = if (in) expectBlend(c, alphaOf(c[3], cov[(y - 1) * mw + x - 2]), bg) else bg;
        try testing.expectEqual(want, at(&r, @intCast(x), @intCast(y)));
    };
    // Full coverage with an opaque colour is the colour exactly.
    try testing.expectEqual(expectBlend(c, alphaOf(180, 255), bg), at(&r, 2, 1));
    r.clear(bg);
    var solid: [mw]u8 = @splat(255);
    r.mask(&solid, mw, 1, 0, 0, .{ 9, 8, 7, 255 }, null);
    try testing.expectEqual([4]u8{ 9, 8, 7, 255 }, at(&r, 0, 0));
    try testing.expectEqual([4]u8{ 9, 8, 7, 255 }, at(&r, mw - 1, 0));
    // Clipped, partly off the buffer on the left and top.
    r.clear(bg);
    r.mask(&solid, mw, 1, -3, 0, .{ 9, 8, 7, 255 }, .{ .x = 0, .y = 0, .w = 2, .h = 1 });
    try testing.expectEqual([4]u8{ 9, 8, 7, 255 }, at(&r, 0, 0));
    try testing.expectEqual([4]u8{ 9, 8, 7, 255 }, at(&r, 1, 0));
    try testing.expectEqual(bg, at(&r, 2, 0));
    r.mask(&solid, mw, 1, 0, -1, .{ 1, 1, 1, 255 }, null);
    r.mask(&solid, mw, 1, 1000, 1000, .{ 1, 1, 1, 255 }, null);
    try testing.expectEqual(bg, at(&r, 3, 0));
}

test "image: 1:1 and integer offsets copy exactly" {
    var src: [5 * 3 * 4]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i * 53 + 11) % 256);
    for (0..15) |i| src[i * 4 + 3] = 255;
    var buf: [9 * 6 * 4]u8 = undefined;
    var r = testRaster(&buf, 9, 6);
    r.image(&src, 5, 3, .{ .x = 2, .y = 1, .w = 5, .h = 3 }, null);
    for (0..6) |y| for (0..9) |x| {
        const in = x >= 2 and x < 7 and y >= 1 and y < 4;
        const want: [4]u8 = if (in) src[((y - 1) * 5 + x - 2) * 4 ..][0..4].* else .{ 0, 0, 0, 255 };
        try testing.expectEqual(want, at(&r, @intCast(x), @intCast(y)));
    };
    // Half-transparent source pixels blend by their own alpha.
    var semi = [_]u8{ 200, 100, 0, 128 };
    r.clear(.{ 0, 0, 255, 255 });
    r.image(&semi, 1, 1, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, null);
    try testing.expectEqual(expectBlend(.{ 200, 100, 0, 0 }, 128, .{ 0, 0, 255, 255 }), at(&r, 1, 1));
}

test "image: nearest-exact scales (2x down averages pairs, constant 3x up)" {
    // 4x2 -> 2x1: each destination pixel centre falls between two source
    // columns and rows, so it is the mean of a 2x2 block.
    const src = [_]u8{
        0,   0,   0,   255, 100, 100, 100, 255, 10, 10, 10, 255, 30, 30, 30, 255,
        200, 200, 200, 255, 100, 100, 100, 255, 50, 50, 50, 255, 70, 70, 70, 255,
    };
    var buf: [2 * 1 * 4]u8 = undefined;
    var r = testRaster(&buf, 2, 1);
    r.image(&src, 4, 2, .{ .x = 0, .y = 0, .w = 2, .h = 1 }, null);
    try testing.expectEqual([4]u8{ 100, 100, 100, 255 }, at(&r, 0, 0));
    try testing.expectEqual([4]u8{ 40, 40, 40, 255 }, at(&r, 1, 0));
    // A constant image scaled up stays the constant, edges included.
    const one: [4][4]u8 = @splat(.{ 12, 34, 56, 255 });
    var big: [6 * 6 * 4]u8 = undefined;
    var r2 = testRaster(&big, 6, 6);
    r2.image(std.mem.asBytes(&one), 2, 2, .{ .x = 0, .y = 0, .w = 6, .h = 6 }, null);
    for (0..6) |y| for (0..6) |x| try testing.expectEqual([4]u8{ 12, 34, 56, 255 }, at(&r2, @intCast(x), @intCast(y)));
}

test "image: bilinear 2x up interpolates, clamps at the edges, clips" {
    // One row 0, 200 scaled to 4x1: centres map to u = -0.25, 0.25, 0.75, 1.25.
    const src = [_]u8{ 0, 0, 0, 255, 200, 200, 200, 255 };
    var buf: [4 * 1 * 4]u8 = undefined;
    var r = testRaster(&buf, 4, 1);
    r.image(&src, 2, 1, .{ .x = 0, .y = 0, .w = 4, .h = 1 }, null);
    try testing.expectEqual(@as(u8, 0), at(&r, 0, 0)[0]); // clamped to the first texel
    try testing.expectEqual(@as(u8, 50), at(&r, 1, 0)[0]); // 0.75 * 0 + 0.25 * 200
    try testing.expectEqual(@as(u8, 150), at(&r, 2, 0)[0]);
    try testing.expectEqual(@as(u8, 200), at(&r, 3, 0)[0]);
    r.clear(.{ 0, 0, 0, 255 });
    r.image(&src, 2, 1, .{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{ .x = 1, .y = 0, .w = 2, .h = 1 });
    try testing.expectEqual(@as(u8, 0), at(&r, 3, 0)[0]);
    try testing.expectEqual(@as(u8, 50), at(&r, 1, 0)[0]);
    // Too-short source data or an empty destination draws nothing.
    r.image(src[0..4], 2, 1, .{ .x = 0, .y = 0, .w = 4, .h = 1 }, null);
    r.image(&src, 2, 1, .{ .x = 0, .y = 0, .w = 0, .h = 1 }, null);
    try testing.expectEqual(@as(u8, 0), at(&r, 3, 0)[0]);
}
