//! Tests of modules Raster and Font together (`zig build test-raster`):
//! text drawn on the CPU from the glyph coverage cache, with the Font
//! module's test font (no system fonts needed).

const std = @import("std");
const Raster = @import("Raster");
const Font = @import("Font");

const testing = std.testing;

test "a short string drawn from the glyph cache inks only its cells" {
    const gpa = testing.allocator;
    var fonts = try Font.fontset.FontSet.fromMemory(gpa, std.Io.failing, Font.ttf.test_font, null);
    defer fonts.deinit();
    var cache = Font.glyphcache.GlyphCache.init(gpa, 256 << 10);
    defer cache.deinit();
    const m = fonts.metrics(24);

    const w: u32 = 200;
    const h: u32 = 60;
    const buf = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(buf);
    var r = Raster.init(buf, w, h, w * 4);
    const bg: [4]u8 = .{ 0, 0, 0, 255 };
    r.clear(bg);

    const s = "Hi, gyp!";
    const x0: i32 = 10;
    const y0: i32 = 12;
    var x = x0;
    for (s) |ch| {
        const g = cache.get(&fonts, ch, .{}, m, 1).?;
        r.mask(g.coverage, g.w, g.h, x, y0, .{ 255, 255, 255, 255 }, null);
        x += @intCast(m.cell_w);
    }
    const box_x1: usize = @intCast(x);
    const box_y1: usize = @intCast(y0 + @as(i32, @intCast(m.cell_h)));

    var ink: usize = 0;
    var per_cell: [s.len]usize = @splat(0);
    for (0..h) |py| for (0..w) |px| {
        const p = buf[(py * w + px) * 4 ..][0..4];
        if (p[0] == 0) continue;
        // Inside the string's box, grey (white on black), opaque.
        try testing.expect(px >= x0 and px < box_x1 and py >= y0 and py < box_y1);
        try testing.expect(p[0] == p[1] and p[1] == p[2] and p[3] == 255);
        ink += 1;
        per_cell[(px - @as(usize, @intCast(x0))) / m.cell_w] += 1;
    };
    try testing.expect(ink > 100);
    // Every character but the space has ink in its own cell.
    for (s, per_cell) |ch, n| try testing.expect((n > 0) == (ch != ' '));
    // 'g', 'y' and 'p' reach below the baseline, 'H' does not.
    const base: usize = @as(usize, @intCast(y0)) + @as(usize, @intFromFloat(m.baseline));
    try testing.expect(inkBelow(buf, w, base + 2, cellX(x0, m, 4), m.cell_w));
    try testing.expect(!inkBelow(buf, w, base + 2, cellX(x0, m, 0), m.cell_w));
    // The cache was used: a second pass over the same string is all hits.
    const misses = cache.misses;
    for (s) |ch| _ = cache.get(&fonts, ch, .{}, m, 1).?;
    try testing.expectEqual(misses, cache.misses);
}

fn cellX(x0: i32, m: Font.fontset.Metrics, i: usize) usize {
    return @as(usize, @intCast(x0)) + i * m.cell_w;
}

fn inkBelow(buf: []const u8, w: u32, y: usize, x: usize, cw: u32) bool {
    for (x..x + cw) |px| if (buf[(y * w + px) * 4] != 0) return true;
    return false;
}
