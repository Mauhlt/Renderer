//! Public module "Renderer" (see build.zig).
pub const Instanced2D = @import("Instanced2D.zig");
/// The Vulkan bindings this module was built against.
pub const vk = @import("Vulkan");
/// Fonts and cell widths (also published on its own as module "Font").
pub const Font = @import("Font");

test {
    @import("std").testing.refAllDecls(Instanced2D);
}
