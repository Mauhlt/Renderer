const vk = @import("Vulkan");
const BindingDescriptions = [1]vk.VertexInputBindingDescription;
const AttributeDescriptions = [3]vk.VertexInputAttributeDescription;

pos: [2]f32,
color: [3]f32,
tex_coord: [2]f32,

pub fn getBindingDescription() BindingDescriptions {
    return .{
        .binding = 0,
        .stride = @sizeOf(@This()),
        .input_rate = .vertex,
    };
}

pub fn getAttributeDescription() AttributeDescriptions {
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
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(@This(), "color"),
        },
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(@This(), "tex_coord"),
        },
    };
}
