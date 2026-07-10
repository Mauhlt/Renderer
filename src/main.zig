const std = @import("std");
const r2d = @import("Renderer2D.zig");
const Io = std.Io;
const log = std.log.scoped(.main);
const vk = @import("Vulkan");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(.ok == debug_allocator.deinit());
    const allo = debug_allocator.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    try r2d.run(io, allo);
}
