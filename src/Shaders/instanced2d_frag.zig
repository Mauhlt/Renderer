//! Fragment shader for Instanced2D (Zig, compiled to SPIR-V).
//! Output = instance colour * texel. The texture is RGBA8; a fully white
//! texel gives a solid fill, white with alpha = coverage gives tinted glyphs.
const std = @import("std");
const spirv = std.spirv;

const Image = @SpirvType(.{ .image = .{
    .usage = .{ .sampled = f32 },
    .format = .unknown,
    .dim = .@"2d",
    .depth = .not_depth,
    .access = .unknown,
    .arrayed = false,
    .multisampled = false,
} });
const SampledImage = @SpirvType(.{ .sampled_image = Image });

const tex = @extern(*addrspace(.constant) SampledImage, .{ .name = "tex", .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } } });
const in_uv = @extern(*addrspace(.input) @Vector(2, f32), .{ .name = "in_uv", .decoration = .{ .location = 0 } });
const in_color = @extern(*addrspace(.input) @Vector(4, f32), .{ .name = "in_color", .decoration = .{ .location = 1 } });
const out_frag = @extern(*addrspace(.output) @Vector(4, f32), .{ .name = "out_frag", .decoration = .{ .location = 0 } });

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    const t = spirv.imageSampleImplicitLod(tex, in_uv.*);
    out_frag.* = in_color.* * t;
}
