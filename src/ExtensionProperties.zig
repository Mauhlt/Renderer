const std = @import("std");
const vk = @import("Vulkan");
const log = std.log.scoped(.ext_props);

const ExtensionVersion = enum {
    Instance,
    Device,
};

version: ExtensionVersion,
len: u32,
props: [512]vk.ExtensionProperties,

pub fn initInstance() !@This() {
    var self: @This() = .{ .version = .Instance, .len = 0, .props = undefined };
    _ = vk.enumerateInstanceExtensionProperties(null, &self.len, null) catch |err| return fail(err);
    self.len = @min(self.len, self.props.len); // never let Vulkan write past props
    _ = vk.enumerateInstanceExtensionProperties(null, &self.len, &self.props) catch |err| return fail(err);
    return self;
}

pub fn initDevice(physical_device: vk.PhysicalDevice) !@This() {
    var self: @This() = .{ .version = .Device, .len = 0, .props = undefined };
    _ = vk.enumerateDeviceExtensionProperties(physical_device, null, &self.len, null) catch |err| return fail(err);
    self.len = @min(self.len, self.props.len);
    _ = vk.enumerateDeviceExtensionProperties(physical_device, null, &self.len, &self.props) catch |err| return fail(err);
    return self;
}

fn fail(err: vk.Error) error{FailedToEnumerateInstanceExtensionProperties} {
    log.debug("{s}", .{@errorName(err)});
    return error.FailedToEnumerateInstanceExtensionProperties;
}

pub fn printExtensions(self: *const @This()) void {
    log.debug("{t}:", .{self.version});
    for (self.props[0..self.len]) |prop|
        log.debug("\t{s}", .{std.mem.sliceTo(&prop.extension_name, 0)});
}

pub fn ensureExtensions(
    self: *const @This(),
    required_extensions: []const [*:0]const u8,
) bool {
    var all_matches: bool = true;
    outer: for (required_extensions) |req_ext| {
        const name1 = std.mem.span(req_ext);
        for (self.props[0..self.len]) |prop| {
            const name2 = std.mem.sliceTo(&prop.extension_name, 0);
            if (std.mem.eql(u8, name1, name2)) continue :outer;
        } else {
            all_matches = false;
            log.debug("Missing Required Extension: {s}", .{name1});
        }
    }
    return all_matches;
}
