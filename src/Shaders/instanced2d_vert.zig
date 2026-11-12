//! Vertex shader for Instanced2D, written in Zig and compiled to SPIR-V by
//! the Zig compiler (target spirv32-vulkan, self-hosted backend).
//!
//! One instance = one quad. Inputs (binding 0, per instance):
//!   location 0: rect  (x, y, w, h) in normalised device coordinates
//!   location 1: uv    (u0, v0, u1, v1)
//!   location 2: color (r, g, b, a), from r8g8b8a8_unorm
//! The four corners come from gl_VertexIndex (triangle strip, 4 vertices).
const std = @import("std");
const spirv = std.spirv;

const in_rect = @extern(*addrspace(.input) @Vector(4, f32), .{ .name = "in_rect", .decoration = .{ .location = 0 } });
const in_uv = @extern(*addrspace(.input) @Vector(4, f32), .{ .name = "in_uv", .decoration = .{ .location = 1 } });
const in_color = @extern(*addrspace(.input) @Vector(4, f32), .{ .name = "in_color", .decoration = .{ .location = 2 } });
const out_uv = @extern(*addrspace(.output) @Vector(2, f32), .{ .name = "out_uv", .decoration = .{ .location = 0 } });
const out_color = @extern(*addrspace(.output) @Vector(4, f32), .{ .name = "out_color", .decoration = .{ .location = 1 } });

export fn main() callconv(.spirv_vertex) void {
    const vi = spirv.vertex_index;
    const fx: f32 = @floatFromInt(vi & 1);
    const fy: f32 = @floatFromInt((vi >> 1) & 1);
    const r = in_rect.*;
    const uv = in_uv.*;
    spirv.position_out.* = .{ r[0] + r[2] * fx, r[1] + r[3] * fy, 0.0, 1.0 };
    out_uv.* = .{ uv[0] + (uv[2] - uv[0]) * fx, uv[1] + (uv[3] - uv[1]) * fy };
    out_color.* = in_color.*;
}
