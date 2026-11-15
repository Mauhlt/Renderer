//! Test vertex shader (Renderer's own tests and window-smoke only; apps
//! supply their own, see Instanced2D's "Shader contract"). The smallest
//! shader pair that meets the contract: each instance is its rect filled
//! with its colour, the texture unused.
const std = @import("std");
const spirv = std.spirv;

const in_rect = @extern(*addrspace(.input) @Vector(4, f32), .{ .name = "in_rect", .decoration = .{ .location = 0 } });
const in_color = @extern(*addrspace(.input) @Vector(4, f32), .{ .name = "in_color", .decoration = .{ .location = 2 } });
const out_color = @extern(*addrspace(.output) @Vector(4, f32), .{ .name = "out_color", .decoration = .{ .location = 0 } });

export fn main() callconv(.spirv_vertex) void {
    const vi = spirv.vertex_index;
    const fx: f32 = @floatFromInt(vi & 1);
    const fy: f32 = @floatFromInt((vi >> 1) & 1);
    const r = in_rect.*;
    spirv.position_out.* = .{ r[0] + r[2] * fx, r[1] + r[3] * fy, 0.0, 1.0 };
    out_color.* = in_color.*;
}
