//! Public module "Renderer" (see build.zig). The Vulkan bindings are the
//! "Vulkan" package's own module and the text code is module "Font"; an
//! app imports those directly when it needs them.
pub const Instanced2D = @import("Instanced2D.zig");

test {
    @import("std").testing.refAllDecls(Instanced2D);
}
