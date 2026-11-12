//! Instanced2D: a small reusable 2D renderer on top of the Vulkan package.
//!
//! Draws a list of textured, tinted quads ("instances") in one instanced
//! draw call per frame, sampling a single RGBA8 texture (an atlas). The
//! window/surface is supplied by the caller as a native handle, so this file
//! has no windowing code of its own and works for Win32, Wayland and
//! Metal (MoltenVK) surfaces (module "Window" provides such a window).
//!
//!     var r = try Instanced2D.init(gpa, .{ .win32 = .{ .hinstance = hi, .hwnd = hwnd } }, w, h, .{});
//!     defer r.deinit();
//!     try r.updateTexture(0, 0, 1, 1, &.{ 255, 255, 255, 255 });   // a white texel
//!     r.resize(new_w, new_h);                                     // on window resize
//!     try r.drawFrame(.{ 0, 0, 0, 1 }, instances);                // rects in pixels
//!
//! Colours are passed through unchanged (UNORM swapchain preferred), so
//! sRGB-encoded colours appear as given; alpha blending is "over".
//! Shaders are Zig code in src/Shaders/instanced2d_*.zig, compiled to SPIR-V
//! by build.zig.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("Vulkan");

const Instanced2D = @This();

pub const max_frames_in_flight = 2;
const max_swapchain_images = 8;

pub const SurfaceSource = union(enum) {
    win32: struct { hinstance: ?*anyopaque, hwnd: ?*anyopaque },
    /// wl_display and wl_surface (VK_KHR_wayland_surface).
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    metal: struct { layer: *anyopaque },
};

/// One quad. `rect` is x, y, width, height in framebuffer pixels (origin top
/// left); `uv` is u0, v0, u1, v1 in normalised texture coordinates; `color`
/// multiplies the texel (RGBA, 0..255).
pub const Instance = extern struct {
    rect: [4]f32,
    uv: [4]f32,
    color: [4]u8,
};

pub const Options = struct {
    app_name: [*:0]const u8 = "Instanced2D",
    texture_width: u32 = 1024,
    texture_height: u32 = 1024,
};

pub const Error = error{
    VulkanLibraryNotFound,
    MissingGetInstanceProcAddr,
    MissingInstanceExtension,
    NoSuitableDevice,
    NoSuitableMemoryType,
    SurfaceUnsupported,
    TextureRegionOutOfBounds,
    VulkanCallFailed,
    OutOfMemory,
};

const vert_spv align(4) = @embedFile("instanced2d_vert.spv").*;
const frag_spv align(4) = @embedFile("instanced2d_frag.spv").*;

const Frame = struct {
    cmd: vk.CommandBuffer = .null,
    image_available: vk.Semaphore = .null,
    in_flight: vk.Fence = .null,
    buffer: vk.Buffer = .null,
    memory: vk.DeviceMemory = .null,
    mapped: ?[*]Instance = null,
    capacity: usize = 0,
};

gpa: std.mem.Allocator,
instance: vk.Instance = .null,
surface: vk.SurfaceKHR = .null,
physical_device: vk.PhysicalDevice = .null,
device: vk.Device = .null,
queue_family: u32 = 0,
queue: vk.Queue = .null,
memory_props: vk.PhysicalDeviceMemoryProperties = .{},

swapchain: vk.SwapchainKHR = .null,
swapchain_format: vk.Format = .b8g8r8a8_unorm,
color_space: vk.ColorSpaceKHR = .srgb_nonlinear,
extent: vk.Extent2D = .{ .width = 0, .height = 0 },
image_count: u32 = 0,
images: [max_swapchain_images]vk.Image = @splat(.null),
views: [max_swapchain_images]vk.ImageView = @splat(.null),
framebuffers: [max_swapchain_images]vk.Framebuffer = @splat(.null),
render_finished: [max_swapchain_images]vk.Semaphore = @splat(.null),

render_pass: vk.RenderPass = .null,
set_layout: vk.DescriptorSetLayout = .null,
pipeline_layout: vk.PipelineLayout = .null,
pipeline: vk.Pipeline = .null,
descriptor_pool: vk.DescriptorPool = .null,
descriptor_set: vk.DescriptorSet = .null,
command_pool: vk.CommandPool = .null,

texture_width: u32 = 0,
texture_height: u32 = 0,
texture: vk.Image = .null,
texture_memory: vk.DeviceMemory = .null,
texture_view: vk.ImageView = .null,
sampler: vk.Sampler = .null,
staging: vk.Buffer = .null,
staging_memory: vk.DeviceMemory = .null,
staging_mapped: ?[*]u8 = null,

frames: [max_frames_in_flight]Frame = @splat(.{}),
frame_index: usize = 0,
wanted_width: u32 = 0,
wanted_height: u32 = 0,
needs_recreate: bool = false,

fn ok(r: anytype) Error!void {
    _ = r catch return error.VulkanCallFailed;
}

pub fn init(
    gpa: std.mem.Allocator,
    source: SurfaceSource,
    width: u32,
    height: u32,
    options: Options,
) Error!*Instanced2D {
    const self = try gpa.create(Instanced2D);
    self.* = .{ .gpa = gpa, .wanted_width = width, .wanted_height = height };
    errdefer {
        self.destroyAll();
        gpa.destroy(self);
    }
    vk.loadLibrary() catch |err| return err;
    try self.createInstance(source, options.app_name);
    try self.createSurface(source);
    try self.pickDevice();
    try self.createDevice();
    try self.createRenderPassAndPipeline();
    try self.createCommandObjects();
    try self.createTexture(options.texture_width, options.texture_height);
    try self.createSwapchain();
    return self;
}

pub fn deinit(self: *Instanced2D) void {
    const gpa = self.gpa;
    self.destroyAll();
    gpa.destroy(self);
}

/// Call when the window's framebuffer size changes (0 x 0 = minimised).
pub fn resize(self: *Instanced2D, width: u32, height: u32) void {
    if (width != self.wanted_width or height != self.wanted_height) {
        self.wanted_width = width;
        self.wanted_height = height;
        self.needs_recreate = true;
    }
}

/// Current framebuffer size in pixels.
pub fn framebufferSize(self: *const Instanced2D) [2]u32 {
    return .{ self.extent.width, self.extent.height };
}

/// Replaces a rectangle of the texture with tightly packed RGBA8 `pixels`.
/// Synchronous: waits for the GPU to be idle, so batch updates per frame.
pub fn updateTexture(self: *Instanced2D, x: u32, y: u32, w: u32, h: u32, pixels: []const u8) Error!void {
    if (w == 0 or h == 0) return;
    if (@as(u64, x) + w > self.texture_width or @as(u64, y) + h > self.texture_height) return error.TextureRegionOutOfBounds;
    const size = @as(usize, w) * h * 4;
    if (pixels.len < size) return error.TextureRegionOutOfBounds;
    try ok(vk.queueWaitIdle(self.queue));
    @memcpy(self.staging_mapped.?[0..size], pixels[0..size]);

    const cmd = try self.beginOneShot();
    self.barrier(cmd, .shader_read_only_optimal, .transfer_dst_optimal);
    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = w,
        .buffer_image_height = h,
        .image_subresource = .{ .aspect_mask = .init(.color_bit), .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
        .image_extent = .{ .width = w, .height = h, .depth = 1 },
    };
    vk.cmdCopyBufferToImage(cmd, self.staging, self.texture, .transfer_dst_optimal, 1, (&region)[0..1]);
    self.barrier(cmd, .transfer_dst_optimal, .shader_read_only_optimal);
    try self.endOneShot(cmd);
}

/// Records and presents one frame. Rects are in framebuffer pixels.
/// Returns without drawing while the window is minimised.
pub fn drawFrame(self: *Instanced2D, clear: [4]f32, instances: []const Instance) Error!void {
    if (self.needs_recreate or self.swapchain == .null) {
        if (self.wanted_width == 0 or self.wanted_height == 0) return;
        try self.recreateSwapchain();
        if (self.swapchain == .null) return;
    }
    const f = &self.frames[self.frame_index];
    try ok(vk.waitForFences(self.device, 1, (&f.in_flight)[0..1], .true, std.math.maxInt(u64)));

    var image_index: u32 = 0;
    const acq = vk.acquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), f.image_available, .null, &image_index);
    if (acq) |res| {
        if (res == .suboptimal_khr) self.needs_recreate = true;
    } else |err| switch (err) {
        error.OutOfDateKHR => {
            self.needs_recreate = true;
            return;
        },
        else => return error.VulkanCallFailed,
    }
    if (image_index >= self.image_count) return error.VulkanCallFailed;

    try self.ensureCapacity(f, instances.len);
    // Pixels -> normalised device coordinates.
    const sx = 2.0 / @as(f32, @floatFromInt(self.extent.width));
    const sy = 2.0 / @as(f32, @floatFromInt(self.extent.height));
    if (f.mapped) |dst| {
        for (instances, 0..) |inst, i| {
            dst[i] = .{
                .rect = .{ inst.rect[0] * sx - 1, inst.rect[1] * sy - 1, inst.rect[2] * sx, inst.rect[3] * sy },
                .uv = inst.uv,
                .color = inst.color,
            };
        }
    }

    try ok(vk.resetFences(self.device, 1, (&f.in_flight)[0..1]));
    try ok(vk.resetCommandBuffer(f.cmd, .empty));
    try self.record(f, image_index, clear, instances.len);

    const wait_stage: vk.PipelineStageFlags = .init(.color_attachment_output_bit);
    const submit: vk.SubmitInfo = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = (&f.image_available)[0..1],
        .p_wait_dst_stage_mask = (&wait_stage)[0..1],
        .command_buffer_count = 1,
        .p_command_buffers = (&f.cmd)[0..1],
        .signal_semaphore_count = 1,
        .p_signal_semaphores = self.render_finished[image_index..][0..1],
    };
    try ok(vk.queueSubmit(self.queue, 1, (&submit)[0..1], f.in_flight));

    const present: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = self.render_finished[image_index..][0..1],
        .swapchain_count = 1,
        .p_swapchains = (&self.swapchain)[0..1],
        .p_image_indices = (&image_index)[0..1],
    };
    if (vk.queuePresentKHR(self.queue, &present)) |res| {
        if (res == .suboptimal_khr) self.needs_recreate = true;
    } else |err| switch (err) {
        error.OutOfDateKHR => self.needs_recreate = true,
        else => return error.VulkanCallFailed,
    }
    self.frame_index = (self.frame_index + 1) % max_frames_in_flight;
}

// ----------------------------------------------------------- setup

fn hasExtension(props: []const vk.ExtensionProperties, name: []const u8) bool {
    for (props) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.extension_name, 0), name)) return true;
    }
    return false;
}

fn createInstance(self: *Instanced2D, source: SurfaceSource, app_name: [*:0]const u8) Error!void {
    var count: u32 = 0;
    try ok(vk.enumerateInstanceExtensionProperties(null, &count, null));
    const props = try self.gpa.alloc(vk.ExtensionProperties, count);
    defer self.gpa.free(props);
    try ok(vk.enumerateInstanceExtensionProperties(null, &count, props.ptr));
    const available = props[0..@min(count, props.len)];

    var exts: [6][*:0]const u8 = undefined;
    var n: u32 = 0;
    exts[n] = vk.khr_surface_extension_name;
    n += 1;
    exts[n] = switch (source) {
        .win32 => vk.khr_win32_surface_extension_name,
        .wayland => vk.khr_wayland_surface_extension_name,
        .metal => vk.ext_metal_surface_extension_name,
    };
    n += 1;
    for (exts[0..n]) |e| {
        if (!hasExtension(available, std.mem.span(e))) return error.MissingInstanceExtension;
    }
    var flags: vk.InstanceCreateFlags = .empty;
    // MoltenVK through the loader is a "portability" driver: it is only
    // enumerated when the application opts in.
    if (hasExtension(available, vk.khr_portability_enumeration_extension_name)) {
        exts[n] = vk.khr_portability_enumeration_extension_name;
        n += 1;
        flags.set(.enumerate_portability_bit_khr);
    }
    if (hasExtension(available, vk.khr_get_physical_device_properties_2_extension_name)) {
        exts[n] = vk.khr_get_physical_device_properties_2_extension_name;
        n += 1;
    }
    const app: vk.ApplicationInfo = .{
        .p_application_name = app_name,
        .application_version = vk.makeApiVersion(0, 1, 0, 0),
        .p_engine_name = "Mauhlt Renderer",
        .engine_version = vk.makeApiVersion(0, 1, 0, 0),
        .api_version = vk.api_version_1_0,
    };
    const info: vk.InstanceCreateInfo = .{
        .flags = flags,
        .p_application_info = &app,
        .enabled_extension_count = n,
        .pp_enabled_extension_names = &exts,
    };
    try ok(vk.createInstance(&info, null, &self.instance));
    vk.loadInstance(self.instance);
}

fn createSurface(self: *Instanced2D, source: SurfaceSource) Error!void {
    switch (source) {
        .win32 => |s| {
            const info: vk.Win32SurfaceCreateInfoKHR = .{ .hinstance = s.hinstance, .hwnd = s.hwnd };
            try ok(vk.createWin32SurfaceKHR(self.instance, &info, null, &self.surface));
        },
        .wayland => |s| {
            const info: vk.WaylandSurfaceCreateInfoKHR = .{ .display = @ptrCast(s.display), .surface = @ptrCast(s.surface) };
            try ok(vk.createWaylandSurfaceKHR(self.instance, &info, null, &self.surface));
        },
        .metal => |s| {
            const info: vk.MetalSurfaceCreateInfoEXT = .{ .p_layer = @ptrCast(s.layer) };
            try ok(vk.createMetalSurfaceEXT(self.instance, &info, null, &self.surface));
        },
    }
}

fn pickDevice(self: *Instanced2D) Error!void {
    var count: u32 = 0;
    try ok(vk.enumeratePhysicalDevices(self.instance, &count, null));
    var devices: [16]vk.PhysicalDevice = @splat(.null);
    count = @min(count, devices.len);
    try ok(vk.enumeratePhysicalDevices(self.instance, &count, &devices));
    var best: ?vk.PhysicalDevice = null;
    var best_family: u32 = 0;
    var best_score: u32 = 0;
    for (devices[0..count]) |pd| {
        const family = self.graphicsPresentFamily(pd) orelse continue;
        if (!self.deviceHasSwapchain(pd)) continue;
        var props: vk.PhysicalDeviceProperties = undefined;
        vk.getPhysicalDeviceProperties(pd, &props);
        const score: u32 = switch (props.device_type) {
            .discrete_gpu => 3,
            .integrated_gpu => 2,
            else => 1,
        };
        if (score > best_score) {
            best = pd;
            best_family = family;
            best_score = score;
        }
    }
    self.physical_device = best orelse return error.NoSuitableDevice;
    self.queue_family = best_family;
    vk.getPhysicalDeviceMemoryProperties(self.physical_device, &self.memory_props);
}

fn graphicsPresentFamily(self: *Instanced2D, pd: vk.PhysicalDevice) ?u32 {
    var count: u32 = 0;
    vk.getPhysicalDeviceQueueFamilyProperties(pd, &count, null);
    var families: [32]vk.QueueFamilyProperties = undefined;
    count = @min(count, families.len);
    vk.getPhysicalDeviceQueueFamilyProperties(pd, &count, &families);
    for (families[0..count], 0..) |fam, i| {
        if (!fam.queue_flags.contains(.graphics_bit)) continue;
        var present: vk.Bool32 = .false;
        vk.getPhysicalDeviceSurfaceSupportKHR(pd, @intCast(i), self.surface, &present) catch continue;
        if (present.toBool()) return @intCast(i);
    }
    return null;
}

fn deviceExtensions(self: *Instanced2D, pd: vk.PhysicalDevice) ?[]vk.ExtensionProperties {
    var count: u32 = 0;
    _ = vk.enumerateDeviceExtensionProperties(pd, null, &count, null) catch return null;
    const props = self.gpa.alloc(vk.ExtensionProperties, count) catch return null;
    _ = vk.enumerateDeviceExtensionProperties(pd, null, &count, props.ptr) catch {
        self.gpa.free(props);
        return null;
    };
    return props[0..@min(count, props.len)];
}

fn deviceHasSwapchain(self: *Instanced2D, pd: vk.PhysicalDevice) bool {
    const props = self.deviceExtensions(pd) orelse return false;
    defer self.gpa.free(props.ptr[0..props.len]);
    return hasExtension(props, vk.khr_swapchain_extension_name);
}

fn createDevice(self: *Instanced2D) Error!void {
    const props = self.deviceExtensions(self.physical_device) orelse return error.NoSuitableDevice;
    defer self.gpa.free(props.ptr[0..props.len]);
    var exts: [2][*:0]const u8 = .{ vk.khr_swapchain_extension_name, undefined };
    var n: u32 = 1;
    // Required when the driver advertises it (MoltenVK).
    if (hasExtension(props, vk.khr_portability_subset_extension_name)) {
        exts[1] = vk.khr_portability_subset_extension_name;
        n = 2;
    }
    const priority: f32 = 1;
    const queue_info: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = self.queue_family,
        .queue_count = 1,
        .p_queue_priorities = (&priority)[0..1],
    };
    const features: vk.PhysicalDeviceFeatures = .{};
    const info: vk.DeviceCreateInfo = .{
        .queue_create_info_count = 1,
        .p_queue_create_infos = (&queue_info)[0..1],
        .enabled_extension_count = n,
        .pp_enabled_extension_names = &exts,
        .p_enabled_features = &features,
    };
    try ok(vk.createDevice(self.physical_device, &info, null, &self.device));
    vk.loadDevice(self.device);
    vk.getDeviceQueue(self.device, self.queue_family, 0, &self.queue);
}

fn chooseFormat(self: *Instanced2D) Error!void {
    var count: u32 = 0;
    try ok(vk.getPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &count, null));
    var formats: [64]vk.SurfaceFormatKHR = undefined;
    count = @min(count, formats.len);
    try ok(vk.getPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &count, &formats));
    if (count == 0) return error.SurfaceUnsupported;
    self.swapchain_format = formats[0].format;
    self.color_space = formats[0].color_space;
    // UNORM keeps caller colours (already sRGB-encoded) unchanged.
    for (formats[0..count]) |f| {
        if ((f.format == .b8g8r8a8_unorm or f.format == .r8g8b8a8_unorm) and f.color_space == .srgb_nonlinear) {
            self.swapchain_format = f.format;
            self.color_space = f.color_space;
            return;
        }
    }
}

fn createRenderPassAndPipeline(self: *Instanced2D) Error!void {
    try self.chooseFormat();
    const attachment: vk.AttachmentDescription = .{
        .format = self.swapchain_format,
        .samples = .@"1_bit",
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };
    const color_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = (&color_ref)[0..1],
    };
    const dependency: vk.SubpassDependency = .{
        .src_subpass = vk.subpass_external,
        .dst_subpass = 0,
        .src_stage_mask = .init(.color_attachment_output_bit),
        .src_access_mask = .empty,
        .dst_stage_mask = .init(.color_attachment_output_bit),
        .dst_access_mask = .init(.color_attachment_write_bit),
    };
    const rp_info: vk.RenderPassCreateInfo = .{
        .attachment_count = 1,
        .p_attachments = (&attachment)[0..1],
        .subpass_count = 1,
        .p_subpasses = (&subpass)[0..1],
        .dependency_count = 1,
        .p_dependencies = (&dependency)[0..1],
    };
    try ok(vk.createRenderPass(self.device, &rp_info, null, &self.render_pass));

    const binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .init(.fragment_bit),
    };
    const set_info: vk.DescriptorSetLayoutCreateInfo = .{ .binding_count = 1, .p_bindings = (&binding)[0..1] };
    try ok(vk.createDescriptorSetLayout(self.device, &set_info, null, &self.set_layout));
    const layout_info: vk.PipelineLayoutCreateInfo = .{ .set_layout_count = 1, .p_set_layouts = (&self.set_layout)[0..1] };
    try ok(vk.createPipelineLayout(self.device, &layout_info, null, &self.pipeline_layout));

    var vert: vk.ShaderModule = .null;
    var frag: vk.ShaderModule = .null;
    const vinfo: vk.ShaderModuleCreateInfo = .{ .code_size = vert_spv.len, .p_code = @ptrCast(&vert_spv) };
    try ok(vk.createShaderModule(self.device, &vinfo, null, &vert));
    defer vk.destroyShaderModule(self.device, vert, null);
    const finfo: vk.ShaderModuleCreateInfo = .{ .code_size = frag_spv.len, .p_code = @ptrCast(&frag_spv) };
    try ok(vk.createShaderModule(self.device, &finfo, null, &frag));
    defer vk.destroyShaderModule(self.device, frag, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .vertex_bit, .module = vert, .p_name = "main" },
        .{ .stage = .fragment_bit, .module = frag, .p_name = "main" },
    };
    const vbinding: vk.VertexInputBindingDescription = .{ .binding = 0, .stride = @sizeOf(Instance), .input_rate = .instance };
    const vattrs = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "rect") },
        .{ .location = 1, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "uv") },
        .{ .location = 2, .binding = 0, .format = .r8g8b8a8_unorm, .offset = @offsetOf(Instance, "color") },
    };
    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = (&vbinding)[0..1],
        .vertex_attribute_description_count = vattrs.len,
        .p_vertex_attribute_descriptions = &vattrs,
    };
    const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_strip, .primitive_restart_enable = .false };
    const viewport_state: vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .scissor_count = 1 };
    const raster: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .empty,
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .line_width = 1,
    };
    const multisample: vk.PipelineMultisampleStateCreateInfo = .{ .rasterization_samples = .@"1_bit", .sample_shading_enable = .false };
    const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = .true,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .initMany(&.{ .r_bit, .g_bit, .b_bit, .a_bit }),
    };
    const blend: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = (&blend_attachment)[0..1],
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic: vk.PipelineDynamicStateCreateInfo = .{ .dynamic_state_count = dynamic_states.len, .p_dynamic_states = &dynamic_states };
    const info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &raster,
        .p_multisample_state = &multisample,
        .p_color_blend_state = &blend,
        .p_dynamic_state = &dynamic,
        .layout = self.pipeline_layout,
        .render_pass = self.render_pass,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    try ok(vk.createGraphicsPipelines(self.device, .null, 1, (&info)[0..1], null, (&self.pipeline)[0..1]));
}

fn createCommandObjects(self: *Instanced2D) Error!void {
    const pool_info: vk.CommandPoolCreateInfo = .{ .flags = .init(.reset_command_buffer_bit), .queue_family_index = self.queue_family };
    try ok(vk.createCommandPool(self.device, &pool_info, null, &self.command_pool));
    for (&self.frames) |*f| {
        const alloc_info: vk.CommandBufferAllocateInfo = .{ .command_pool = self.command_pool, .level = .primary, .command_buffer_count = 1 };
        try ok(vk.allocateCommandBuffers(self.device, &alloc_info, (&f.cmd)[0..1]));
        const sem_info: vk.SemaphoreCreateInfo = .{};
        try ok(vk.createSemaphore(self.device, &sem_info, null, &f.image_available));
        const fence_info: vk.FenceCreateInfo = .{ .flags = .init(.signaled_bit) };
        try ok(vk.createFence(self.device, &fence_info, null, &f.in_flight));
    }
}

fn findMemoryType(self: *Instanced2D, bits: u32, props: vk.MemoryPropertyFlags) Error!u32 {
    for (0..self.memory_props.memory_type_count) |i| {
        if (bits & (@as(u32, 1) << @intCast(i)) != 0 and self.memory_props.memory_types[i].property_flags.isSupersetOf(props))
            return @intCast(i);
    }
    return error.NoSuitableMemoryType;
}

fn createBuffer(self: *Instanced2D, size: u64, usage: vk.BufferUsageFlags, buffer: *vk.Buffer, memory: *vk.DeviceMemory, mapped: *?*anyopaque) Error!void {
    const info: vk.BufferCreateInfo = .{ .size = size, .usage = usage, .sharing_mode = .exclusive };
    try ok(vk.createBuffer(self.device, &info, null, buffer));
    var reqs: vk.MemoryRequirements = .{};
    vk.getBufferMemoryRequirements(self.device, buffer.*, &reqs);
    const alloc: vk.MemoryAllocateInfo = .{
        .allocation_size = reqs.size,
        .memory_type_index = try self.findMemoryType(reqs.memory_type_bits, .initMany(&.{ .host_visible_bit, .host_coherent_bit })),
    };
    try ok(vk.allocateMemory(self.device, &alloc, null, memory));
    try ok(vk.bindBufferMemory(self.device, buffer.*, memory.*, 0));
    try ok(vk.mapMemory(self.device, memory.*, 0, size, .empty, mapped));
}

fn createTexture(self: *Instanced2D, width: u32, height: u32) Error!void {
    self.texture_width = width;
    self.texture_height = height;
    const info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .@"1_bit",
        .tiling = .optimal,
        .usage = .initMany(&.{ .transfer_dst_bit, .sampled_bit }),
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    try ok(vk.createImage(self.device, &info, null, &self.texture));
    var reqs: vk.MemoryRequirements = .{};
    vk.getImageMemoryRequirements(self.device, self.texture, &reqs);
    const alloc: vk.MemoryAllocateInfo = .{
        .allocation_size = reqs.size,
        .memory_type_index = try self.findMemoryType(reqs.memory_type_bits, .init(.device_local_bit)),
    };
    try ok(vk.allocateMemory(self.device, &alloc, null, &self.texture_memory));
    try ok(vk.bindImageMemory(self.device, self.texture, self.texture_memory, 0));
    self.texture_view = try self.createView(self.texture, .r8g8b8a8_unorm);

    const sampler_info: vk.SamplerCreateInfo = .{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = .false,
    };
    try ok(vk.createSampler(self.device, &sampler_info, null, &self.sampler));

    var mapped: ?*anyopaque = null;
    try self.createBuffer(@as(u64, width) * height * 4, .init(.transfer_src_bit), &self.staging, &self.staging_memory, &mapped);
    self.staging_mapped = @ptrCast(mapped);

    // Start fully transparent, in shader-read layout.
    @memset(self.staging_mapped.?[0 .. @as(usize, width) * height * 4], 0);
    const cmd = try self.beginOneShot();
    self.barrier(cmd, .undefined, .transfer_dst_optimal);
    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .init(.color_bit), .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    vk.cmdCopyBufferToImage(cmd, self.staging, self.texture, .transfer_dst_optimal, 1, (&region)[0..1]);
    self.barrier(cmd, .transfer_dst_optimal, .shader_read_only_optimal);
    try self.endOneShot(cmd);

    const pool_size: vk.DescriptorPoolSize = .{ .type = .combined_image_sampler, .descriptor_count = 1 };
    const pool_info: vk.DescriptorPoolCreateInfo = .{ .max_sets = 1, .pool_size_count = 1, .p_pool_sizes = (&pool_size)[0..1] };
    try ok(vk.createDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool));
    const set_alloc: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = (&self.set_layout)[0..1],
    };
    try ok(vk.allocateDescriptorSets(self.device, &set_alloc, (&self.descriptor_set)[0..1]));
    const image_info: vk.DescriptorImageInfo = .{
        .sampler = self.sampler,
        .image_view = self.texture_view,
        .image_layout = .shader_read_only_optimal,
    };
    const write: vk.WriteDescriptorSet = .{
        .dst_set = self.descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = (&image_info)[0..1],
    };
    vk.updateDescriptorSets(self.device, 1, (&write)[0..1], 0, null);
}

fn createView(self: *Instanced2D, image: vk.Image, format: vk.Format) Error!vk.ImageView {
    const info: vk.ImageViewCreateInfo = .{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .subresource_range = .{ .aspect_mask = .init(.color_bit), .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    };
    var view: vk.ImageView = .null;
    try ok(vk.createImageView(self.device, &info, null, &view));
    return view;
}

fn beginOneShot(self: *Instanced2D) Error!vk.CommandBuffer {
    const alloc_info: vk.CommandBufferAllocateInfo = .{ .command_pool = self.command_pool, .level = .primary, .command_buffer_count = 1 };
    var cmd: vk.CommandBuffer = .null;
    try ok(vk.allocateCommandBuffers(self.device, &alloc_info, (&cmd)[0..1]));
    const begin: vk.CommandBufferBeginInfo = .{ .flags = .init(.one_time_submit_bit) };
    vk.beginCommandBuffer(cmd, &begin) catch {
        vk.freeCommandBuffers(self.device, self.command_pool, 1, (&cmd)[0..1]);
        return error.VulkanCallFailed;
    };
    return cmd;
}

fn endOneShot(self: *Instanced2D, cmd: vk.CommandBuffer) Error!void {
    var c = cmd;
    defer vk.freeCommandBuffers(self.device, self.command_pool, 1, (&c)[0..1]);
    try ok(vk.endCommandBuffer(cmd));
    const submit: vk.SubmitInfo = .{ .command_buffer_count = 1, .p_command_buffers = (&c)[0..1] };
    try ok(vk.queueSubmit(self.queue, 1, (&submit)[0..1], .null));
    try ok(vk.queueWaitIdle(self.queue));
}

fn barrier(self: *Instanced2D, cmd: vk.CommandBuffer, old: vk.ImageLayout, new: vk.ImageLayout) void {
    var b: vk.ImageMemoryBarrier = .{
        .old_layout = old,
        .new_layout = new,
        .src_queue_family_index = vk.queue_family_ignored,
        .dst_queue_family_index = vk.queue_family_ignored,
        .image = self.texture,
        .subresource_range = .{ .aspect_mask = .init(.color_bit), .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    };
    var src: vk.PipelineStageFlags = .init(.top_of_pipe_bit);
    var dst: vk.PipelineStageFlags = .init(.transfer_bit);
    if (new == .transfer_dst_optimal) {
        b.src_access_mask = if (old == .undefined) .empty else .init(.shader_read_bit);
        b.dst_access_mask = .init(.transfer_write_bit);
        src = if (old == .undefined) .init(.top_of_pipe_bit) else .init(.fragment_shader_bit);
        dst = .init(.transfer_bit);
    } else {
        b.src_access_mask = .init(.transfer_write_bit);
        b.dst_access_mask = .init(.shader_read_bit);
        src = .init(.transfer_bit);
        dst = .init(.fragment_shader_bit);
    }
    vk.cmdPipelineBarrier(cmd, src, dst, .empty, 0, null, 0, null, 1, (&b)[0..1]);
}

fn ensureCapacity(self: *Instanced2D, f: *Frame, n: usize) Error!void {
    if (n <= f.capacity) return;
    // The frame's fence has been waited on, so its buffer is no longer in use.
    self.destroyFrameBuffer(f);
    var cap: usize = @max(1024, f.capacity);
    while (cap < n) cap *= 2;
    var mapped: ?*anyopaque = null;
    try self.createBuffer(cap * @sizeOf(Instance), .init(.vertex_buffer_bit), &f.buffer, &f.memory, &mapped);
    f.mapped = @ptrCast(@alignCast(mapped));
    f.capacity = cap;
}

fn destroyFrameBuffer(self: *Instanced2D, f: *Frame) void {
    if (f.memory != .null) {
        vk.unmapMemory(self.device, f.memory);
        vk.freeMemory(self.device, f.memory, null);
    }
    if (f.buffer != .null) vk.destroyBuffer(self.device, f.buffer, null);
    f.buffer = .null;
    f.memory = .null;
    f.mapped = null;
    f.capacity = 0;
}

fn record(self: *Instanced2D, f: *Frame, image_index: u32, clear: [4]f32, n: usize) Error!void {
    const begin: vk.CommandBufferBeginInfo = .{};
    try ok(vk.beginCommandBuffer(f.cmd, &begin));
    const clear_value: vk.ClearValue = .{ .color = .{ .float32 = clear } };
    const rp_begin: vk.RenderPassBeginInfo = .{
        .render_pass = self.render_pass,
        .framebuffer = self.framebuffers[image_index],
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
        .clear_value_count = 1,
        .p_clear_values = (&clear_value)[0..1],
    };
    vk.cmdBeginRenderPass(f.cmd, &rp_begin, .@"inline");
    if (n > 0) {
        vk.cmdBindPipeline(f.cmd, .graphics, self.pipeline);
        const viewport: vk.Viewport = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.extent.width),
            .height = @floatFromInt(self.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        vk.cmdSetViewport(f.cmd, 0, 1, (&viewport)[0..1]);
        const scissor: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        vk.cmdSetScissor(f.cmd, 0, 1, (&scissor)[0..1]);
        vk.cmdBindDescriptorSets(f.cmd, .graphics, self.pipeline_layout, 0, 1, (&self.descriptor_set)[0..1], 0, null);
        const offset: vk.DeviceSize = 0;
        vk.cmdBindVertexBuffers(f.cmd, 0, 1, (&f.buffer)[0..1], (&offset)[0..1]);
        vk.cmdDraw(f.cmd, 4, @intCast(n), 0, 0);
    }
    vk.cmdEndRenderPass(f.cmd);
    try ok(vk.endCommandBuffer(f.cmd));
}

// ----------------------------------------------------------- swapchain

fn createSwapchain(self: *Instanced2D) Error!void {
    var caps: vk.SurfaceCapabilitiesKHR = undefined;
    try ok(vk.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &caps));
    var extent = caps.current_extent;
    if (extent.width == std.math.maxInt(u32)) {
        extent = .{
            .width = std.math.clamp(self.wanted_width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(self.wanted_height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
    if (extent.width == 0 or extent.height == 0) {
        self.needs_recreate = true; // minimised; try again later
        return;
    }
    var count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) count = @min(count, caps.max_image_count);
    count = @min(count, max_swapchain_images);
    const composite: vk.CompositeAlphaFlagBitsKHR = if (caps.supported_composite_alpha.contains(.opaque_bit))
        .opaque_bit
    else if (caps.supported_composite_alpha.contains(.inherit_bit))
        .inherit_bit
    else
        .pre_multiplied_bit;
    const info: vk.SwapchainCreateInfoKHR = .{
        .surface = self.surface,
        .min_image_count = count,
        .image_format = self.swapchain_format,
        .image_color_space = self.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .init(.color_attachment_bit),
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = composite,
        .present_mode = .fifo, // always available; vsync
        .clipped = .true,
        .old_swapchain = .null,
    };
    try ok(vk.createSwapchainKHR(self.device, &info, null, &self.swapchain));
    self.extent = extent;
    var n: u32 = 0;
    try ok(vk.getSwapchainImagesKHR(self.device, self.swapchain, &n, null));
    n = @min(n, max_swapchain_images);
    try ok(vk.getSwapchainImagesKHR(self.device, self.swapchain, &n, &self.images));
    self.image_count = n;
    for (0..n) |i| {
        self.views[i] = try self.createView(self.images[i], self.swapchain_format);
        const fb_info: vk.FramebufferCreateInfo = .{
            .render_pass = self.render_pass,
            .attachment_count = 1,
            .p_attachments = self.views[i..][0..1],
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };
        try ok(vk.createFramebuffer(self.device, &fb_info, null, &self.framebuffers[i]));
        const sem_info: vk.SemaphoreCreateInfo = .{};
        try ok(vk.createSemaphore(self.device, &sem_info, null, &self.render_finished[i]));
    }
    self.needs_recreate = false;
}

fn destroySwapchain(self: *Instanced2D) void {
    for (0..max_swapchain_images) |i| {
        if (self.framebuffers[i] != .null) vk.destroyFramebuffer(self.device, self.framebuffers[i], null);
        if (self.views[i] != .null) vk.destroyImageView(self.device, self.views[i], null);
        if (self.render_finished[i] != .null) vk.destroySemaphore(self.device, self.render_finished[i], null);
        self.framebuffers[i] = .null;
        self.views[i] = .null;
        self.render_finished[i] = .null;
        self.images[i] = .null;
    }
    if (self.swapchain != .null) vk.destroySwapchainKHR(self.device, self.swapchain, null);
    self.swapchain = .null;
    self.image_count = 0;
}

fn recreateSwapchain(self: *Instanced2D) Error!void {
    try ok(vk.deviceWaitIdle(self.device));
    self.destroySwapchain();
    try self.createSwapchain();
}

fn destroyAll(self: *Instanced2D) void {
    if (self.device != .null) {
        vk.deviceWaitIdle(self.device) catch {};
        self.destroySwapchain();
        for (&self.frames) |*f| {
            self.destroyFrameBuffer(f);
            if (f.in_flight != .null) vk.destroyFence(self.device, f.in_flight, null);
            if (f.image_available != .null) vk.destroySemaphore(self.device, f.image_available, null);
        }
        if (self.command_pool != .null) vk.destroyCommandPool(self.device, self.command_pool, null);
        if (self.staging_memory != .null) {
            vk.unmapMemory(self.device, self.staging_memory);
            vk.freeMemory(self.device, self.staging_memory, null);
        }
        if (self.staging != .null) vk.destroyBuffer(self.device, self.staging, null);
        if (self.descriptor_pool != .null) vk.destroyDescriptorPool(self.device, self.descriptor_pool, null);
        if (self.sampler != .null) vk.destroySampler(self.device, self.sampler, null);
        if (self.texture_view != .null) vk.destroyImageView(self.device, self.texture_view, null);
        if (self.texture != .null) vk.destroyImage(self.device, self.texture, null);
        if (self.texture_memory != .null) vk.freeMemory(self.device, self.texture_memory, null);
        if (self.pipeline != .null) vk.destroyPipeline(self.device, self.pipeline, null);
        if (self.pipeline_layout != .null) vk.destroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (self.set_layout != .null) vk.destroyDescriptorSetLayout(self.device, self.set_layout, null);
        if (self.render_pass != .null) vk.destroyRenderPass(self.device, self.render_pass, null);
        vk.destroyDevice(self.device, null);
        self.device = .null;
    }
    if (self.instance != .null) {
        if (self.surface != .null) vk.destroySurfaceKHR(self.instance, self.surface, null);
        vk.destroyInstance(self.instance, null);
        self.instance = .null;
    }
}

test "instance layout matches the vertex attributes" {
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 0), vert_spv.len % 4);
    try std.testing.expectEqual(@as(u32, 0x07230203), std.mem.readInt(u32, vert_spv[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x07230203), std.mem.readInt(u32, frag_spv[0..4], .little));
}
