const std = @import("std");
const log = std.log.scoped(.ssd);
const vk = @import("Vulkan");
const Errors = @import("errors.zig").Errors;
const Window = @import("os/Windows.zig");

const LEN: comptime_int = 8;
capabilities: vk.SurfaceCapabilitiesKHR = undefined,
n_formats: u32 = 0,
formats: [LEN]vk.SurfaceFormatKHR = undefined,
n_present_modes: u32 = 0,
present_modes: [LEN]vk.PresentModeKHR = undefined,

pub fn init(
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) Errors!@This() {
    var capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    vk.getPhysicalDeviceSurfaceCapabilitiesKHR(
        physical_device,
        surface,
        &capabilities,
    ) catch return error.FailedToGetPhysicalDeviceSurfaceCapabilities;

    var n_formats: u32 = 0;
    _ = vk.getPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        surface,
        &n_formats,
        null,
    ) catch return error.FailedToGetPhysicalDeviceSurfaceFormatsKHR;

    var formats: [LEN]vk.SurfaceFormatKHR = undefined;
    _ = vk.getPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        surface,
        &n_formats,
        &formats,
    ) catch return error.FailedToGetPhysicalDeviceSurfaceFormatsKHR;

    var n_present_modes: u32 = 0;
    _ = vk.getPhysicalDeviceSurfacePresentModesKHR(
        physical_device,
        surface,
        &n_present_modes,
        null,
    ) catch return error.FailedToGetPhysicalDeviceSurfacePresentModesKHR;

    var present_modes: [LEN]vk.PresentModeKHR = undefined;
    _ = vk.getPhysicalDeviceSurfacePresentModesKHR(
        physical_device,
        surface,
        &n_present_modes,
        &present_modes,
    ) catch return error.FailedToGetPhysicalDeviceSurfacePresentModesKHR;

    return .{
        .capabilities = capabilities,
        .n_formats = n_formats,
        .formats = formats,
        .n_present_modes = n_present_modes,
        .present_modes = present_modes,
    };
}

pub fn chooseSwapSurfaceFormat(self: *const @This()) vk.SurfaceFormatKHR {
    for (self.formats) |format| {
        if (format.format == .b8g8r8a8_srgb and
            format.color_space == .srgb_nonlinear)
        {
            return format;
        }
    } else return self.formats[0];
}

pub fn chooseSwapPresentMode(self: *const @This()) vk.PresentModeKHR {
    for (self.present_modes) |present_mode| {
        if (present_mode == .mailbox)
            return present_mode;
    } else return .fifo;
}

pub fn chooseSwapExtent(self: *const @This(), window: *const Window) vk.Extent2D {
    if (self.capabilities.current_extent.width != std.math.maxInt(u32)) {
        return self.capabilities.current_extent;
    } else {
        const size = window.clientSize();
        var actual_extent: vk.Extent2D = .{
            .width = @intCast(size.w),
            .height = @intCast(size.h),
        };
        actual_extent.width = std.math.clamp(
            actual_extent.width,
            self.capabilities.min_image_extent.width,
            self.capabilities.max_image_extent.width,
        );
        actual_extent.width = std.math.clamp(
            actual_extent.height,
            self.capabilities.min_image_extent.height,
            self.capabilities.max_image_extent.height,
        );
        return actual_extent;
    }
}

pub fn isComplete(self: *const @This()) bool {
    return self.n_formats > 0 and self.n_present_modes > 0;
}
