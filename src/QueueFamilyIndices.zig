const std = @import("std");
const vk = @import("Vulkan");
const log = std.log.scoped(.qfi);

graphics_family: ?u32 = null,
present_family: ?u32 = null,

pub fn init(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) vk.Errors!@This() {
    var self: @This() = .{};
    var n_families: u32 = 0;
    vk.getPhysicalDeviceQueueFamilyProperties(physical_device, &n_families, null);
    var families: [64]vk.QueueFamilyProperties = undefined;
    vk.getPhysicalDeviceQueueFamilyProperties(physical_device, &n_families, &families);
    for (families, 0..) |family, i| {
        if (family.queue_flags.contains(.graphics_bit))
            self.graphics_family = @truncate(i);
        var present_support: vk.Bool32 = .false;
        try vk.getPhysicalDeviceSurfaceSupportKHR(
            physical_device,
            @truncate(i),
            surface,
            &present_support,
        ).handle(.FailedToGetPhysicalDeviceSurfaceSupport);
        switch (present_support) {
            .true => self.present_family = @truncate(i),
            else => {},
        }
        if (self.isComplete()) break;
    }
    return self;
}

pub fn isComplete(self: @This()) bool {
    return self.graphics_family != null and self.present_family != null;
}

pub fn isSameFamily(self: @This()) bool {
    return self.graphics_family.? == self.present_family.?;
}
