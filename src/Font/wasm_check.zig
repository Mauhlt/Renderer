//! Compile check (`zig build test-font`): the Font pieces a browser client
//! uses, built for wasm32-freestanding, so an accidental OS or Vulkan
//! dependency fails here rather than in a user's build.
const Font = @import("root.zig");

export fn fontCheckWidth(cp: u32) u32 {
    return Font.wcwidth.of(@intCast(cp & 0x1FFFFF));
}

export fn fontCheckGlyph(ptr: [*]const u8, len: usize, cp: u32) u32 {
    const f = Font.ttf.Font.init(ptr[0..len], 0) catch return 0;
    return f.glyphIndex(@intCast(cp & 0x1FFFFF));
}

export fn fontCheckRaster(w: u32, h: u32, out: [*]u8) void {
    var c = Font.raster.Canvas.init(@import("std").heap.wasm_allocator, w, h) catch return;
    defer c.deinit(@import("std").heap.wasm_allocator);
    c.line(0, 0, @floatFromInt(w), @floatFromInt(h));
    c.finish(out[0 .. @as(usize, w) * h]);
}

/// The browser's text path: a font set from the app's bytes and the glyph
/// coverage cache over `FontSet.render`.
export fn fontCheckCache(ptr: [*]const u8, len: usize, cp: u32, em: f32) u32 {
    const gpa = @import("std").heap.wasm_allocator;
    var fs = Font.fontset.FontSet.fromMemory(gpa, @import("std").Io.failing, ptr[0..len], null) catch return 0;
    defer fs.deinit();
    var cache = Font.glyphcache.GlyphCache.init(gpa, 1 << 20);
    defer cache.deinit();
    const g = cache.get(&fs, @intCast(cp & 0x1FFFFF), .{ .italic = true }, fs.metrics(em), 2) orelse return 0;
    return g.w * g.h;
}
