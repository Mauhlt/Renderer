const std = @import("std");
// const r2d = @import("Renderer2D.zig");
// const r3d = @import("Renderer3D.zig");
const Io = std.Io;
const log = std.log.scoped(.main);

pub fn main() !void {
    // allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(.ok == debug_allocator.deinit());
    const gpa = debug_allocator.allocator();
    _ = gpa;
    // io
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    // relative paths
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executableDirPath(io, &buf);
    const exe_dir = buf[0..n];
    std.debug.print("Exe: {s}\n", .{exe_dir});

    // switch at runtime which mode to use
    // try r2d.run(io, gpa, &exe_dir);
    // try r3d.run(io, gpa);
}
