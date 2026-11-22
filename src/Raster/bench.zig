//! `zig build bench-raster` (ReleaseFast, not part of the tests): times
//! frames of a phone-sized screen (1170 x 2532, an iPhone's pixels) full
//! of terminal text drawn with Raster from the glyph coverage cache, plus
//! the other primitives on their own. Uses the Font module's test font.

const std = @import("std");
const Raster = @import("Raster");
const Font = @import("Font");

const width = 1170;
const height = 2532;
/// 13 pt at 3x.
const em: f32 = 39;
const frames = 60;

const line = "The quick brown fox jumps over the lazy dog; 0123456789 {}[]()<>=+-*/ $ ls -la ~/src | grep zig";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const buf = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(buf);
    var r = Raster.init(buf, width, height, width * 4);
    var fonts = try Font.fontset.FontSet.fromMemory(gpa, std.Io.failing, Font.ttf.test_font, null);
    defer fonts.deinit();
    var cache = Font.glyphcache.GlyphCache.init(gpa, 4 << 20);
    defer cache.deinit();
    const m = fonts.metrics(em);
    const cols = width / m.cell_w;
    const rows = height / m.cell_h;
    std.debug.print("raster bench: {d}x{d} px, em {d} px, cell {d}x{d}, {d}x{d} cells, vector {d} bytes\n", .{ width, height, em, m.cell_w, m.cell_h, cols, rows, Raster.vec_bytes });

    const cold = try timeFrames(io, &r, &fonts, &cache, m, cols, rows, 1);
    std.debug.print("  text frame, cold cache (rasterising {d} glyphs): {d:.2} ms\n", .{ cache.count(), cold });
    const warm = try timeFrames(io, &r, &fonts, &cache, m, cols, rows, frames);
    std.debug.print("  text frame, warm cache: {d:.2} ms ({d} frames)\n", .{ warm, frames });

    var t = Timer.start(io);
    for (0..frames) |_| r.clear(.{ 20, 20, 24, 255 });
    std.debug.print("  clear: {d:.3} ms\n", .{t.ms(frames)});
    t = Timer.start(io);
    for (0..frames) |_| r.fillRect(0.5, 0.5, width - 1, height - 1, .{ 200, 100, 50, 100 }, null);
    std.debug.print("  fillRect, full screen, alpha 100, fractional edges: {d:.3} ms\n", .{t.ms(frames)});

    // A camera preview: 640 x 480 scaled to the screen's width.
    const iw = 640;
    const ih = 480;
    const img = try gpa.alloc(u8, iw * ih * 4);
    defer gpa.free(img);
    for (img, 0..) |*b, i| b.* = if (i % 4 == 3) 255 else @truncate((i *% 2654435761) >> 13);
    const dst: Raster.Rect = .{ .x = 0, .y = 200, .w = width, .h = width * ih / iw };
    t = Timer.start(io);
    for (0..frames) |_| r.image(img, iw, ih, dst, null);
    std.debug.print("  image 640x480 -> {d}x{d} bilinear: {d:.3} ms\n", .{ width, @as(u32, @intFromFloat(dst.h)), t.ms(frames) });

    var sum: u64 = 0;
    for (buf) |b| sum +%= b;
    std.debug.print("  (checksum {d})\n", .{sum});
}

const Timer = struct {
    io: std.Io,
    t0: std.Io.Timestamp,

    fn start(io: std.Io) Timer {
        return .{ .io = io, .t0 = std.Io.Timestamp.now(io, .awake) };
    }

    /// Milliseconds per iteration since start.
    fn ms(t: Timer, n: usize) f64 {
        const ns = t.t0.durationTo(std.Io.Timestamp.now(t.io, .awake)).toNanoseconds();
        return @as(f64, @floatFromInt(ns)) / 1e6 / @as(f64, @floatFromInt(n));
    }
};

/// One frame like a terminal's: background, a highlighted line every
/// eighth row, a glyph in every cell (spaces skipped), a cursor block.
fn timeFrames(io: std.Io, r: *Raster, fonts: *Font.fontset.FontSet, cache: *Font.glyphcache.GlyphCache, m: Font.fontset.Metrics, cols: u32, rows: u32, n: usize) !f64 {
    const t = Timer.start(io);
    for (0..n) |_| {
        r.clear(.{ 20, 20, 24, 255 });
        for (0..rows) |row| {
            const y: i32 = @intCast(row * m.cell_h);
            if (row % 8 == 0) r.fillRect(0, @floatFromInt(y), width, @floatFromInt(m.cell_h), .{ 60, 60, 90, 160 }, null);
            for (0..cols) |col| {
                const ch = line[(row * 7 + col) % line.len];
                if (ch == ' ') continue;
                const style: Font.fontset.Style = .{ .bold = row % 5 == 0, .italic = row % 7 == 0 };
                const g = cache.get(fonts, ch, style, m, 1) orelse return error.OutOfMemory;
                r.mask(g.coverage, g.w, g.h, @intCast(col * m.cell_w), y, .{ 220, 220, 210, 255 }, null);
            }
        }
        r.fillRect(@floatFromInt(3 * m.cell_w), 0, @floatFromInt(m.cell_w), @floatFromInt(m.cell_h), .{ 255, 255, 255, 200 }, null);
    }
    return t.ms(n);
}
