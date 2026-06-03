const std = @import("std");
const log = std.log.scoped(.r3d);
const Dir = std.Io.Dir;

const vk = @import("Vulkan");
const win = @import("os/Windows");
const Image = @import("Image");

const QFI = @import("QueueFamilyIndices.zig");
const SSD = @import("SwapchainSupportDetails.zig");

pub fn run() void {}
pub fn cleanup() void {}
pub fn deinit() void {}
