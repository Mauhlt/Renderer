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
    var len: u32 = 0;
    switch (vk.enumerateInstanceExtensionProperties(null, &len, null)) {
        .success => {},
        else => |tag| {
            log.debug("{t}\n", .{tag});
            return error.FailedToEnumerateInstanceExtensionProperties;
        }
    }
    var props: [512]vk.ExtensionProperties = undefined;
    switch (vk.enumerateInstanceExtensionProperties(null, &len, &props)) {
        .success => {},
        else => |tag| {
            log.debug("{t}\n", .{tag});
            return error.FailedToEnumerateInstanceExtensionProperties;
        }
    }
    const version = .Instance;
    return .{
        .len = len,
        .props = props,
        .version = version,
    };
}

pub fn initDevice(physical_device: vk.PhysicalDevice) !@This() {
    var len: u32 = 0;
    switch (vk.enumerateDeviceExtensionProperties(physical_device, null, &len, null)) {
        .success => {},
        else => |tag| {
            log.debug("{t}\n", .{tag});
            return error.FailedToEnumerateInstanceExtensionProperties;
        }
    }
    var props: [512]vk.ExtensionProperties = undefined;
    switch (vk.enumerateDeviceExtensionProperties(physical_device, null, &len, &props)) {
        .success => {},
        else => |tag| {
            log.debug("{t}\n", .{tag});
            return error.FailedToEnumerateInstanceExtensionProperties;
        }
    }
    const version: ExtensionVersion = .Device;
    return .{
        .len = len,
        .props = props,
        .version = version,
    };
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
        for (self.props) |prop| {
            const name2 = std.mem.sliceTo(&prop.extension_name, 0);
            if (std.mem.eql(u8, name1, name2)) continue :outer;
        } else {
            all_matches = false;
            log.debug("Missing Required Extension: {s}", .{name1});
        }
    }
    return all_matches;
}
