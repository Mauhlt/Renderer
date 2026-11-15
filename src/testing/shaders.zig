//! The test shaders (src/testing/shaders, compiled by build.zig's
//! addShader) for Renderer's own tests and the window-smoke step. Not part
//! of any library module: apps pass their own SPIR-V to Instanced2D.init.
const std = @import("std");
const Renderer = @import("Renderer");

pub const vert align(4) = @embedFile("solid_vert.spv").*;
pub const frag align(4) = @embedFile("solid_frag.spv").*;

test "addShader output is SPIR-V that Instanced2D accepts" {
    try Renderer.Instanced2D.checkSpirv(&vert);
    try Renderer.Instanced2D.checkSpirv(&frag);
}
