const std = @import("std");
const r2d = @import("Renderer2D.zig");
// const r3d = @import("Renderer3D.zig");
const Io = std.Io;
const log = std.log.scoped(.main);

pub fn main() !void {
    // allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(.ok == debug_allocator.deinit());
    const gpa = debug_allocator.allocator();

    // create single threaded io
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    // switch at runtime which mode to use
    try r2d.run(io, gpa);
    // try r3d.run(io, gpa);
}
