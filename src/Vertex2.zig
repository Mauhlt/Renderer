const vk = @import("Vulkan");
const BindingDescriptions = [2]vk.VertexInputBindingDescription;
const AttributeDescriptions = [3]vk.VertexInputAttributeDescription;
// need to check for r8g8b8_unorm - many desktop gpus dont expose it:
// another choice is r8g8b8_uint
// check via: vk.FormatProperties props; vk.GetPhysicalDeviceProperties(self.physical_device, .r8g8b8_unorm, &props);

pos: [2]f32,
color: [3]u8,
tex_coords: [3]f32,

fn getBindingDescriptions() BindingDescriptions {
    return .{
        .{ // position
            .binding = 0,
            .stride = @sizeOf(f32) * 2,
            .input_rate = .vertex,
        },
        .{ // colors
            .binding = 0,
            .stride = @sizeOf(f32) * 3,
            .input_rate = .vertex,
        },
    };
}

fn getAttributeDescriptions() AttributeDescriptions {
    return .{
        .{
            .location = 0,
            .binding = 0,
            .format = .r32g32_sfloat,
            .offset = 0,
        },
        .{
            .location = 1,
            .binding = 1,
            .format = .r8g8b8_unorm,
            .offset = 0,
        },
        .{
            .location = 2,
            .binding = 2,
            .format = .r32g32b32_sfloat,
            .offset = 0,
        },
    };
}
