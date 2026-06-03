const vk = @import("Vulkan");
pos: [2]f32,

pub fn getBindingDescription() vk.VertexInputBindingDescription {
    return .{
        .binding = 0,
        .stride = @sizeOf(@This()),
        .input_rate = .vertex,
    };
}

pub fn getAttributeDescription() vk.VertexInputAttributeDescription {
    return .{
        .binding = 0,
        .location = 0,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(@This(), "pos"),
    };
}
