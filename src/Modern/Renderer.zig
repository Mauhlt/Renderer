const vk = @import("vulkan");
const Window = @import("../os/Windows.zig");
// https://www.youtube.com/watch?v=DC9FBRQKNck&t=372s - use this link as a resource

window: Window = undefined, // 8 bytes
instance: vk.Instance = .null, // 16 bytes
physical_device: vk.PhysicalDevice = .null, // 24 bytes
surface: vk.SurfaceKHR = .null, // 32 bytes
device: vk.Device = .null, // 40 bytes
graphics_queue: vk.Queue = .null, // 48 bytes
present_queue: vk.Queue = .null, // 54 bytes

pub fn init() !@This() {
    var self: @This() = .{};
    const surface = try self.createSurface();
    return self;
}

pub fn createSurface(self: *@This()) !bool {}
