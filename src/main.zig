const std = @import("std");
// const r2d = @import("Renderer2D.zig");
const Io = std.Io;
const log = std.log.scoped(.main);
const vk = @import("Vulkan");

pub fn main() !void {
    const base = vk.GraphicsPipelineCreateInfo{};
    std.debug.print("{}\n", .{@sizeOf(@TypeOf(base))});

    // allocator
    // var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    // defer std.debug.assert(.ok == debug_allocator.deinit());
    // const gpa = debug_allocator.allocator();
    // // io
    // var threaded = std.Io.Threaded.init_single_threaded;
    // const io = threaded.io();
    //
    // try r2d.run(io, gpa);
    // try r3d.run(io, gpa);
}
