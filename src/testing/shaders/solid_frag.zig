//! Test fragment shader (see solid_vert.zig): the instance colour.
const in_color = @extern(*addrspace(.input) @Vector(4, f32), .{ .name = "in_color", .decoration = .{ .location = 0 } });
const out_frag = @extern(*addrspace(.output) @Vector(4, f32), .{ .name = "out_frag", .decoration = .{ .location = 0 } });

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    out_frag.* = in_color.*;
}
