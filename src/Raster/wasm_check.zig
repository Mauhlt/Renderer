//! Compile check (`zig build wasm-check`, part of `zig build test`): the
//! browser's drawing path, Raster with the Font module's font set from
//! memory and glyph cache, built for wasm32-freestanding, so an accidental
//! OS or Vulkan dependency fails here rather than in an app's build.

const std = @import("std");
const Raster = @import("Raster");
const Font = @import("Font");

export fn rasterCheckFrame(px: [*]u8, w: u32, h: u32, font: [*]const u8, font_len: usize, img: [*]const u8, iw: u32, ih: u32) bool {
    const gpa = std.heap.wasm_allocator;
    var r = Raster.init(px[0 .. @as(usize, w) * h * 4], w, h, @as(usize, w) * 4);
    const clip: Raster.Rect = .{ .x = 1, .y = 1, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    r.clear(.{ 0, 0, 0, 255 });
    r.fillRect(0.5, 0.5, 10.25, 3, .{ 255, 0, 0, 128 }, clip);
    r.image(img[0 .. @as(usize, iw) * ih * 4], iw, ih, .{ .x = 0, .y = 0, .w = 33.5, .h = 20 }, clip);
    var fonts = Font.fontset.FontSet.fromMemory(gpa, std.Io.failing, font[0..font_len], null) catch return false;
    defer fonts.deinit();
    var cache = Font.glyphcache.GlyphCache.init(gpa, 1 << 20);
    defer cache.deinit();
    const g = cache.get(&fonts, 'A', .{ .bold = true }, fonts.metrics(16), 1) orelse return false;
    r.mask(g.coverage, g.w, g.h, 2, 2, .{ 255, 255, 255, 255 }, clip);
    return true;
}
