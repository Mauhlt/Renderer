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
