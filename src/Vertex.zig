const vk = @import("Vulkan");
pos: [2]f32,
color: [3]f32,
tex_coord: [2]f32,

pub fn getBindingDescription() vk.VertexInputBindingDescription {
    return .{
        .binding = 0,
        .stride = @sizeOf(@This()),
        .input_rate = .vertex,
    };
}

pub fn getAttributeDescription() [3]vk.VertexInputAttributeDescription {
    return .{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(@This(), "pos"),
        },
        .{
            .binding = 0,
            .location = 0,
            .format = .r8g8b8_sfloat,
            .offset = @offsetOf(@This(), "color"),
        },
        .{
            .binding = 0,
            .location = 0,
            .format = .r8g8b8a8_sfloat,
            .offset = @offsetOf(@This(), "tex_coord"),
        },
    };
}
