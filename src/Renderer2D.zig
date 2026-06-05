// moltenvk = wrapapround metal
// install shader toolchain debug symbols - needed for compiling shaders at runtime
// needed to link debugger to shader
// currently the application lives on the stack - i believe it is fine as it is so few bytes

// TODO:
// 1. make window closeable on WM_QUIT -
// 2. make window resizeable -
// 3. update square based on texture
// 4. load vertices + indices rather than passing them in hard coded
// 5. update pixels on texture map and save those updates
// 6. control ability to save to different files
// 7. add in ui - like IMGUI or something
// 8. perform simulations

// std
const std = @import("std");
const log = std.log.scoped(.r2d);
const Dir = std.Io.Dir;
// libraries
const vk = @import("Vulkan");
const Window = @import("os/Windows.zig");
const Image = @import("Image");
// imports
const QFI = @import("QueueFamilyIndices.zig");
const SSD = @import("SwapchainSupportDetails.zig");
const ExtensionProperties = @import("ExtensionProperties.zig");
const MAX_IMAGES: u32 = 3;
const Images: type = [MAX_IMAGES]vk.Image;
const ImageViews: type = [MAX_IMAGES]vk.ImageView;
const Framebuffers: type = [MAX_IMAGES]vk.Framebuffer;
const MAX_FRAMES_IN_FLIGHT: u32 = 2;
const CommandBuffers: type = [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer;
const Semaphores: type = [MAX_FRAMES_IN_FLIGHT]vk.Semaphore;
const Fences: type = [MAX_FRAMES_IN_FLIGHT]vk.Fence;
const Vertex = @import("Vertex.zig");
const FPS = @import("FPS.zig");
// Options
const dirs = @import("dirs");
// Total: 4kB
// base
window: Window = undefined, // 8 bytes
instance: vk.Instance = .null, // 16 bytes
physical_device: vk.PhysicalDevice = .null, // 24 bytes
surface: vk.SurfaceKHR = .null, // 32 bytes
device: vk.Device = .null, // 40 bytes
graphics_queue: vk.Queue = .null, // 48 bytes
present_queue: vk.Queue = .null, // 54 bytes
// swapchain
swapchain: vk.SwapchainKHR = .null, // 60 bytes
n_swapchain_images: u32 = 0, // 64 bytes, max value is 3
swapchain_images: Images = .{.null} ** MAX_IMAGES, // [_]vk.Image{.null} ** MAX_IMAGES, // 88 bytes
swapchain_format: vk.Format = .b8g8r8a8_srgb, // 96 bytes
swapchain_extent: vk.Extent2D = .{ .width = 640, .height = 480 }, // 104 bytes
swapchain_image_views: ImageViews = .{.null} ** MAX_IMAGES, // 128 bytes
swapchain_render_pass: vk.RenderPass = .null, // 136 bytes
// pipeline
pipeline_layout: vk.PipelineLayout = .null, // 144 bytes
pipeline: vk.Pipeline = .null, // 152 bytes
swapchain_framebuffers: Framebuffers = .{.null} ** MAX_IMAGES, // 176 bytes
// buffers
command_pool: vk.CommandPool = .null, // 184 bytes
texture_image: vk.Image = .null,
texture_buffer: vk.Buffer = .null,
texture_buffer_memory: vk.DeviceMemory = .null,
texxture_image_view: vk.ImageView = .null, // 192 bytes
vertex_buffer: vk.Buffer = .null, // 200 bytes
vertex_buffer_memory: vk.DeviceMemory = .null, // 208 bytes
index_buffer: vk.Buffer = .null, // 216 bytes
index_buffer_memory: vk.DeviceMemory = .null, // 224 bytes
command_buffers: CommandBuffers = .{.null} ** MAX_FRAMES_IN_FLIGHT, // 232 bytes
// sync objects
n_sync_objects: u32 = 0, // 240 bytes
image_available_semaphores: Semaphores = .{.null} ** MAX_FRAMES_IN_FLIGHT, // 264 bytes
render_finished_semaphores: Semaphores = .{.null} ** MAX_FRAMES_IN_FLIGHT, // 288 bytes
in_flight_fences: Fences = .{.null} ** MAX_FRAMES_IN_FLIGHT, // 312 bytes
// misc
current_frame: u32 = 0, // 320 bytes
resize: bool = false, // 328 bytes

pub fn run(io: std.Io, gpa: std.mem.Allocator) !void {
    // hardcoded now - need to load vertices on the fly
    const vertices = [_]Vertex{
        .{ .pos = .{ -0.5, -0.5 } },
        .{ .pos = .{ 0.5, -0.5 } },
        .{ .pos = .{ 0.5, 0.5 } },
        .{ .pos = .{ -0.5, 0.5 } },
    };
    const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
    var self: @This() = .{};
    const app_name: [*:0]const u8 = "Glint";
    self.window = try self.initWindow(
        std.mem.span(app_name),
        std.mem.span(app_name),
    );
    try self.initVulkan(io, gpa, app_name, &vertices, &indices);
    self.window.show();
    try self.coreLoop(io, &vertices, &indices);
    self.deinit();
}

fn initWindow(
    self: *const @This(),
    comptime app_name: []const u8,
    comptime window_title: []const u8,
) !Window {
    return Window.init(
        app_name,
        window_title,
        self.swapchain_extent.width,
        self.swapchain_extent.height,
    ) catch unreachable;
}

// TODO: need to remove vertices + indices - should be a file that is loaded in and used
fn initVulkan(
    self: *@This(),
    io: std.Io,
    gpa: std.mem.Allocator,
    app_name: [*:0]const u8,
    vertices: []const Vertex,
    indices: []const u16,
) !void {
    // base
    const ries = [_][*:0]const u8{
        vk.ExtensionName.win32_surface,
        vk.ExtensionName.surface,
    };
    self.instance = try createInstance(app_name, &ries);
    errdefer vk.destroyInstance(self.instance, null);
    self.surface = try self.createSurface();
    errdefer vk.destroySurfaceKHR(self.instance, self.surface, null);
    const rdes = [_][*:0]const u8{
        vk.ExtensionName.swapchain,
    };
    self.physical_device = try self.pickPhysicalDevice(&rdes);
    self.device = try self.createLogicalDevice(&rdes);
    errdefer vk.destroyDevice(self.device, null);
    const qfi: QFI = try .init(self.physical_device, self.surface);
    self.graphics_queue = self.createQueue(qfi.graphics_family.?);
    self.present_queue = self.createQueue(qfi.present_family.?);
    // swapchain
    self.swapchain = try self.createSwapchain();
    errdefer vk.destroySwapchainKHR(self.device, self.swapchain, null);
    self.n_swapchain_images = try self.getNumSwapchainImages();
    self.swapchain_images = try self.createSwapchainImages();
    const ssd: SSD = try .init(self.physical_device, self.surface);
    self.swapchain_format = ssd.chooseSwapSurfaceFormat().format;
    self.swapchain_extent = ssd.chooseSwapExtent(&self.window);
    self.swapchain_image_views = try self.createSwapchainImageViews();
    self.swapchain_render_pass = try self.createSwapchainRenderPass();
    self.swapchain_framebuffers = try self.createSwapchainFramebuffers();
    // pipeline
    self.pipeline_layout = try self.createPipelineLayout();
    self.pipeline = try self.createGraphicsPipeline(io);
    // commands + buffers
    self.command_pool = try self.createCommandPool();
    self.texture_image = try self.createTextureImage(io, gpa, "/BasicArt.bmp");
    // self.texture_image_memory = try self.createTextureImageMemory();
    // const texture_buffer = try self.createBuffer();
    // self.texture_buffer = texture_buffer.buffer;
    // self.texture_buffer_memory = texture_buffer.memory;
    const vertex_buffer = try self.createBuffer(Vertex, vertices);
    self.vertex_buffer = vertex_buffer.buffer;
    self.vertex_buffer_memory = vertex_buffer.memory;
    const index_buffer = try self.createBuffer(u16, indices);
    self.index_buffer = index_buffer.buffer;
    self.index_buffer_memory = index_buffer.memory;
    self.command_buffers = try self.createCommandBuffers(MAX_FRAMES_IN_FLIGHT);
    // sync objects - not needed if image is static
    self.in_flight_fences = try self.createFences(MAX_FRAMES_IN_FLIGHT);
    self.image_available_semaphores = try self.createSemaphores(MAX_FRAMES_IN_FLIGHT);
    self.render_finished_semaphores = try self.createSemaphores(MAX_FRAMES_IN_FLIGHT);
}

fn coreLoop(
    self: *@This(),
    io: std.Io,
    vertices: []const Vertex,
    indices: []const u16,
) !void {
    // var fps: FPS = .init(.{
    //     .interval_ms = 17,
    //     .io = io,
    // });
    // _ = fps;

    var i: usize = 0;
    while (i < 1_000_000_000) : (i += 1) {
        if (!Window.pollPeek()) break;
        try self.drawFrame(vertices, indices);
        // std.debug.print("FPS: {}\n", .{fps.update(io)});
        try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);
    }
    try vk.deviceWaitIdle(self.device)
        .handle(.FailedToIdleDevice);
}

fn deinit(self: *@This()) void {
    self.destroySwapchain();
    // texture
    // vk.destroyImageView(self.device, self.texture_image_view, null);
    // vk.destroyImage(self.device, self.texture_image, null);
    // vk.freeMemory(self.device, self.texture_image_memory, null);
    // buffers
    vk.destroyBuffer(self.device, self.vertex_buffer, null);
    vk.freeMemory(self.device, self.vertex_buffer_memory, null);
    vk.destroyBuffer(self.device, self.index_buffer, null);
    vk.freeMemory(self.device, self.index_buffer_memory, null);
    // sync objects
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        vk.destroySemaphore(self.device, self.render_finished_semaphores[i], null);
        vk.destroySemaphore(self.device, self.image_available_semaphores[i], null);
        vk.destroyFence(self.device, self.in_flight_fences[i], null);
    }
    // buffers
    vk.destroyCommandPool(self.device, self.command_pool, null);
    // pipeline
    vk.destroyPipeline(self.device, self.pipeline, null);
    vk.destroyPipelineLayout(self.device, self.pipeline_layout, null);
    // swapchain
    vk.destroyRenderPass(self.device, self.swapchain_render_pass, null);
    // base
    vk.destroyDevice(self.device, null);
    vk.destroySurfaceKHR(self.instance, self.surface, null);
    vk.destroyInstance(self.instance, null);
    self.window.deinit();
}

fn createInstance(
    app_name: [*:0]const u8,
    ries: []const [*:0]const u8,
) !vk.Instance {
    const app_info: vk.ApplicationInfo = .{
        .p_application_name = app_name,
        .application_version = vk.makeApiVersion(0, 1, 0, 0),
        .p_engine_name = "Mauhlt",
        .engine_version = vk.makeApiVersion(0, 1, 0, 0),
        .api_version = vk.makeApiVersion(0, 1, 0, 0),
    };
    const exts = ExtensionProperties.initInstance() catch
        return vk.Errors.FailedToEnumerateInstanceExtensions;
    // exts.printExtensions();
    if (!exts.ensureExtensions(ries))
        return vk.Errors.MissingRequiredInstanceExtension;
    const create_info: vk.InstanceCreateInfo = .{
        .flags = .empty,
        .p_application_info = &app_info,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
        .enabled_extension_count = @truncate(ries.len),
        .pp_enabled_extension_names = @ptrCast(ries),
    };
    var instance: vk.Instance = .null;
    try vk.createInstance(&create_info, null, &instance)
        .handle(.FailedToCreateInstance);
    return instance;
}

fn pickPhysicalDevice(
    self: *const @This(),
    rdes: []const [*:0]const u8,
) vk.Errors!vk.PhysicalDevice {
    var n_devices: u32 = 0;
    try vk.enumeratePhysicalDevices(self.instance, &n_devices, null)
        .handle(.FailedToEnumeratePhysicalDevice);
    var physical_devices: [64]vk.PhysicalDevice = undefined;
    try vk.enumeratePhysicalDevices(self.instance, &n_devices, &physical_devices)
        .handle(.FailedToEnumeratePhysicalDevice);
    if (n_devices == 0) return vk.Errors.NoPhysicalDevicesSupportVulkan;
    for (physical_devices) |physical_device|
        if (isDeviceSuitable(physical_device, self.surface, rdes))
            return physical_device;
    return vk.Errors.NoPhysicalDevicesAreSuitableForApp;
}

fn isDeviceSuitable(
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    rdes: []const [*:0]const u8,
) bool {
    var props: vk.PhysicalDeviceProperties = undefined;
    vk.getPhysicalDeviceProperties(physical_device, &props);
    var feats: vk.PhysicalDeviceFeatures = undefined;
    vk.getPhysicalDeviceFeatures(physical_device, &feats);
    const qfi = QFI.init(physical_device, surface) catch return false;
    const ssd = SSD.init(physical_device, surface) catch return false;
    return qfi.isComplete() and
        checkDeviceExtensionSupport(physical_device, rdes) and
        ssd.isComplete();
}

fn checkDeviceExtensionSupport(
    physical_device: vk.PhysicalDevice,
    rdes: []const [*:0]const u8,
) bool {
    const exts = ExtensionProperties.initDevice(physical_device) catch return false;
    return exts.ensureExtensions(rdes);
}

fn createSurface(self: *const @This()) vk.Errors!vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = .null;
    switch (@import("builtin").os.tag) {
        .windows => {
            const create_info: vk.Win32SurfaceCreateInfoKHR = .{
                .hinstance = self.window.instance,
                .hwnd = self.window.hwnd,
            };
            try vk.createWin32SurfaceKHR(self.instance, &create_info, null, &surface)
                .handle(.FailedToCreateSurface);
        },
        // .linux => { // TODO: Implement
        //     const create_info: vk.XlibSurfaceCreateInfoKHR = .{
        //         .flags = 0,
        //         .dpy = dpy,
        //         .window = window,
        //     };
        //     try vk.createXlibSurfaceKHR(self.instance, &create_info, null, &surface)
        //         .handle(.FailedToCreateSurface);
        // },
        else => unreachable,
    }
    return surface;
}

fn createLogicalDevice(
    self: *const @This(),
    rdes: []const [*:0]const u8,
) vk.Errors!vk.Device {
    const qfi = QFI.init(self.physical_device, self.surface) catch
        return vk.Errors.FailedToGetQueueFamilyIndices;
    var queue_priority: [1]f32 = [_]f32{1};
    var qcis = [_]vk.DeviceQueueCreateInfo{
        .{
            .p_queue_priorities = &queue_priority,
            .queue_count = 1,
            .queue_family_index = qfi.graphics_family.?,
        },
        .{
            .p_queue_priorities = &queue_priority,
            .queue_count = 1,
            .queue_family_index = qfi.present_family.?,
        },
    };
    var feats: vk.PhysicalDeviceFeatures = .{};
    const exts = ExtensionProperties.initDevice(self.physical_device) catch
        return vk.Errors.FailedToEnumerateDeviceExtensions;
    _ = exts;
    // exts.printExtensions();
    const create_info: vk.DeviceCreateInfo = .{
        .flags = 0,
        .queue_create_info_count = if (qfi.isSameFamily()) 1 else 2,
        .p_queue_create_infos = &qcis,
        .p_enabled_features = &feats,
        .enabled_extension_count = @truncate(rdes.len),
        .pp_enabled_extension_names = @ptrCast(rdes),
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
    };
    var device: vk.Device = .null;
    try vk.createDevice(self.physical_device, &create_info, null, &device)
        .handle(.FailedToCreateDevice);
    return device;
}

fn createSwapchain(self: *const @This()) !vk.SwapchainKHR {
    const ssd = SSD.init(self.physical_device, self.surface) catch unreachable;
    const surface_format: vk.SurfaceFormatKHR = ssd.chooseSwapSurfaceFormat();
    const present_mode: vk.PresentModeKHR = ssd.chooseSwapPresentMode();
    const extent: vk.Extent2D = ssd.chooseSwapExtent(&self.window);
    var image_count: u32 = ssd.capabilities.min_image_count + 1;
    if (ssd.capabilities.max_image_count > 0 and
        image_count > ssd.capabilities.max_image_count)
    {
        image_count = ssd.capabilities.max_image_count;
    }
    const qfi = QFI.init(self.physical_device, self.surface) catch
        return vk.Errors.FailedToGetQueueFamilyIndices;
    const queue_family_indices: [2]u32 = [_]u32{
        qfi.graphics_family.?,
        qfi.present_family.?,
    };
    const create_info = vk.SwapchainCreateInfoKHR{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .init(.color_attachment_bit),
        .image_sharing_mode = if (qfi.isSameFamily()) .exclusive else .concurrent,
        .queue_family_index_count = if (qfi.isSameFamily()) 0 else 2,
        .p_queue_family_indices = if (qfi.isSameFamily()) null else &queue_family_indices,
        .pre_transform = ssd.capabilities.current_transform,
        .composite_alpha = .opaque_bit,
        .present_mode = present_mode,
        .clipped = .true,
        .old_swapchain = .null,
    };
    var swapchain: vk.SwapchainKHR = .null;
    try vk.createSwapchainKHR(self.device, &create_info, null, &swapchain)
        .handle(.FailedToCreateSwapchain);
    return swapchain;
}

fn destroySwapchain(self: *@This()) void {
    for (0..self.n_swapchain_images) |i| {
        vk.destroyImageView(self.device, self.swapchain_image_views[i], null);
        vk.destroyFramebuffer(self.device, self.swapchain_framebuffers[i], null);
    }
    vk.destroySwapchainKHR(self.device, self.swapchain, null);
}

fn recreateSwapchain(
    self: *@This(),
) vk.Errors!void {
    vk.deviceWaitIdle(self.device);

    self.swapchain = try self.createSwapchain();
    self.swapchain_image_views = try self.createSwapchainImageViews();
    self.swapchain_framebuffers = try self.createSwapchainFramebuffers();
}

fn createQueue(self: *const @This(), family: u32) vk.Queue {
    var queue: vk.Queue = .null;
    vk.getDeviceQueue(self.device, family, 0, &queue);
    return queue;
}

fn getNumSwapchainImages(self: *const @This()) vk.Errors!u32 {
    var n_images: u32 = 0;
    try vk.getSwapchainImagesKHR(
        self.device,
        self.swapchain,
        &n_images,
        null,
    )
        .handle(.FailedToGetNumSwapchainImages);
    if (n_images == 0)
        return vk.Errors.FailedToGetNumSwapchainImages;
    return n_images;
}

fn createSwapchainImages(
    self: *const @This(),
) vk.Errors!Images {
    var n_images: u32 = self.n_swapchain_images;
    var images: Images = .{.null} ** MAX_IMAGES;
    try vk.getSwapchainImagesKHR(
        self.device,
        self.swapchain,
        &n_images,
        &images,
    )
        .handle(.FailedToGetSwapchainImages);
    std.debug.assert(n_images == self.n_swapchain_images);
    return images;
}

fn createSwapchainImageViews(self: *const @This()) vk.Errors!ImageViews {
    var views: ImageViews = .{.null} ** MAX_IMAGES;
    for (0..self.n_swapchain_images) |i| {
        views[i] = try self.createImageView(
            self.swapchain_images[i],
            self.swapchain_format,
        );
    }
    return views;
}

fn createSwapchainRenderPass(self: *const @This()) vk.Errors!vk.RenderPass {
    const color_attachments = [_]vk.AttachmentDescription{
        .{
            .format = self.swapchain_format,
            .samples = .@"1_bit",
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        },
    };
    const color_attachment_references = [1]vk.AttachmentReference{
        .{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        },
    };
    const subpasses = [1]vk.SubpassDescription{
        .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = @truncate(color_attachment_references.len),
            .p_color_attachments = &color_attachment_references,
        },
    };
    const dependencies = [1]vk.SubpassDependency{
        .{
            .src_subpass = vk.SubpassExternal,
            .dst_subpass = 0,
            .src_stage_mask = .init(.color_attachment_output_bit),
            .src_access_mask = .empty,
            .dst_stage_mask = .init(.color_attachment_output_bit),
            .dst_access_mask = .init(.color_attachment_write_bit),
        },
    };
    const create_info: vk.RenderPassCreateInfo = .{
        .attachment_count = @truncate(color_attachments.len),
        .p_attachments = &color_attachments,
        .subpass_count = @truncate(subpasses.len),
        .p_subpasses = &subpasses,
        .dependency_count = @truncate(dependencies.len),
        .p_dependencies = &dependencies,
    };
    var render_pass: vk.RenderPass = .null;
    try vk.createRenderPass(self.device, &create_info, null, &render_pass)
        .handle(.FailedToCreateRenderPass);
    return render_pass;
}

fn createPipelineLayout(self: *const @This()) vk.Errors!vk.PipelineLayout {
    const create_info: vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = 0,
        .p_set_layouts = null,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    };
    var layout: vk.PipelineLayout = .null;
    try vk.createPipelineLayout(self.device, &create_info, null, &layout)
        .handle(.FailedToCreatePipelineLayout);
    return layout;
}

fn createGraphicsPipeline(
    self: *const @This(),
    io: std.Io,
) vk.Errors!vk.Pipeline {
    var sms = [_]vk.ShaderModule{.null} ** 2;
    var filepath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const filenames = [_][]const u8{ "/square.vert.spv", "/square.frag.spv" };
    for (filenames, 0..) |ext, i| {
        const path = appendPaths(&filepath_buf, &.{ dirs.shader_dir, ext });
        var data: [4096]u8 = undefined;
        const sc = readShaderSPV(io, path, &data) catch unreachable;
        sms[i] = try self.createShaderModule(sc);
    }
    defer {
        for (0..sms.len) |i| {
            vk.destroyShaderModule(self.device, sms[i], null);
        }
    }
    const vert_shader_stage_create_info: vk.PipelineShaderStageCreateInfo = .{
        .stage = .vertex_bit,
        .module = sms[0],
        .p_name = "main",
    };
    const frag_shader_stage_create_info: vk.PipelineShaderStageCreateInfo = .{
        .stage = .fragment_bit,
        .module = sms[1],
        .p_name = "main",
    };
    const shader_stages_create_info = [_]vk.PipelineShaderStageCreateInfo{
        vert_shader_stage_create_info,
        frag_shader_stage_create_info,
    };
    const binding_description = Vertex.getBindingDescription();
    const attribute_description = Vertex.getAttributeDescription();
    const vertex_input_state_create_info: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = &binding_description,
        .vertex_attribute_description_count = 1,
        .p_vertex_attribute_descriptions = &attribute_description,
    };
    const input_assembly_state_create_info: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };
    const viewport_state_create_info: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .scissor_count = 1,
    };
    const rasterization_state_create_info: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .line_width = 1,
        .cull_mode = .init(.back_bit),
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        // .depth_bias_constant_factor = 0,
        // .depth_bias_clamp = 0,
        // .depth_bias_slope_factor = 0,
    };
    const multisample_state_create_info: vk.PipelineMultisampleStateCreateInfo = .{
        .sample_shading_enable = .false,
        .rasterization_samples = .@"1_bit",
        // .min_sample_shading = 1,
        // .p_sample_mask = null,
        // .alpha_to_coverage_enable = .false,
        // .alpha_to_one_enable = .false,
    };
    const color_blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .color_write_mask = .initMany(&.{ .r_bit, .g_bit, .b_bit, .a_bit }),
        .blend_enable = .false,
        // .src_color_blend_factor = .one,
        // .dst_color_blend_factor = .zero,
        // .color_blend_op = .add,
        // .src_alpha_blend_factor = .one,
        // .dst_alpha_blend_factor = .zero,
        // .alpha_blend_op = .add,
    };
    const color_blend_state_create_info: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = &color_blend_attachment,
        .blend_constants = [4]f32{ 0, 0, 0, 0 },
    };
    const dynamic_states = [_]vk.DynamicState{
        .viewport,
        .scissor,
    };
    const dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = @truncate(dynamic_states.len),
        .p_dynamic_states = &dynamic_states,
    };
    const create_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = @truncate(shader_stages_create_info.len),
        .p_stages = &shader_stages_create_info,
        .p_vertex_input_state = &vertex_input_state_create_info,
        .p_input_assembly_state = &input_assembly_state_create_info,
        .p_viewport_state = &viewport_state_create_info,
        .p_rasterization_state = &rasterization_state_create_info,
        .p_multisample_state = &multisample_state_create_info,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &color_blend_state_create_info,
        .p_tessellation_state = null,
        .p_dynamic_state = &dynamic_state_create_info,
        .render_pass = self.swapchain_render_pass,
        .layout = self.pipeline_layout,
        .subpass = 0,
        .base_pipeline_handle = .null,
        // .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = .null;
    try vk.createGraphicsPipelines(self.device, .null, 1, &create_info, null, &pipeline)
        .handle(.FailedToCreatePipeline);
    return pipeline;
}

fn trimExePath(exe_path: []const u8) []const u8 {
    const zig_out_index = std.mem.indexOf(u8, exe_path, "zig-out").?;
    return exe_path[0..zig_out_index];
}

fn appendPaths(
    buf: *[std.fs.max_path_bytes]u8,
    paths: []const []const u8,
) []const u8 {
    var len: usize = 0;
    for (paths) |path| len += path.len;
    std.debug.assert(len < std.fs.max_path_bytes);
    var start: usize = 0;
    for (paths) |path| {
        @memcpy(buf[start .. start + path.len], path);
        start += path.len;
    }
    return buf[0..start];
}

fn readShaderSPV(
    io: std.Io,
    abs_filepath: []const u8,
    data: *[4096]u8,
) ![]const u8 {
    const file = try Dir.openFileAbsolute(io, abs_filepath, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    var reader = file.reader(io, @ptrCast(data));
    return try reader.interface.peek(stat.size);
}

fn createShaderModule(
    self: *const @This(),
    code: []const u8,
) vk.Errors!vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = @truncate(code.len),
        .p_code = @ptrCast(@alignCast(code)),
    };
    var shader_module: vk.ShaderModule = .null;
    try vk.createShaderModule(self.device, &create_info, null, &shader_module)
        .handle(.FailedToCreateShaderModule);
    return shader_module;
}

fn createSwapchainFramebuffers(self: *const @This()) vk.Errors!Framebuffers {
    var framebuffers: Framebuffers = .{.null} ** MAX_IMAGES;
    for (
        self.swapchain_images,
        self.swapchain_image_views,
        0..,
    ) |image, image_view, i| {
        switch (image) {
            .null => break,
            else => {
                const attachments = [_]vk.ImageView{image_view};
                const create_info: vk.FramebufferCreateInfo = .{
                    .render_pass = self.swapchain_render_pass,
                    .attachment_count = @truncate(attachments.len),
                    .p_attachments = &attachments,
                    .width = self.swapchain_extent.width,
                    .height = self.swapchain_extent.height,
                    .layers = 1,
                };
                try vk.createFramebuffer(self.device, &create_info, null, &framebuffers[i])
                    .handle(.FailedToCreateFramebuffer);
            },
        }
    }
    return framebuffers;
}

fn createCommandPool(self: *const @This()) vk.Errors!vk.CommandPool {
    const qfi = QFI.init(self.physical_device, self.surface) catch
        return vk.Errors.FailedToGetQueueFamilyIndices;
    const create_info = vk.CommandPoolCreateInfo{
        .flags = .init(.reset_command_buffer_bit),
        .queue_family_index = qfi.graphics_family.?,
    };
    var pool: vk.CommandPool = .null;
    try vk.createCommandPool(self.device, &create_info, null, &pool)
        .handle(.FailedToCreateCommandPool);
    return pool;
}

fn createVulkanBuffer(
    self: *const @This(),
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
) vk.Errors!vk.Buffer {
    const create_info = vk.BufferCreateInfo{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    };
    var buffer: vk.Buffer = .null;
    try vk.createBuffer(self.device, &create_info, null, &buffer)
        .handle(.FailedToCreateBuffer);
    return buffer;
}

fn createVulkanBufferMemory(
    self: *const @This(),
    buffer: vk.Buffer,
    props: vk.MemoryPropertyFlags,
) vk.Errors!vk.DeviceMemory {
    var mem_reqs: vk.MemoryRequirements = .{};
    vk.getBufferMemoryRequirements(self.device, buffer, &mem_reqs);
    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try self.findMemoryType(mem_reqs.memory_type_bits, props),
    };
    var memory: vk.DeviceMemory = .null;
    try vk.allocateMemory(self.device, &alloc_info, null, &memory)
        .handle(.FailedToAllocateBufferMemory);
    try vk.bindBufferMemory(self.device, buffer, memory, 0)
        .handle(.FailedToBindBufferMemory);
    return memory;
}

fn mapVulkanMemory(
    self: *const @This(),
    comptime T: type,
    data: []const T,
    size: vk.DeviceSize,
    memory: vk.DeviceMemory,
) vk.Errors!void {
    var gpu_ptr: ?*anyopaque = null;
    try vk.mapMemory(self.device, memory, 0, size, .empty, &gpu_ptr)
        .handle(.FailedToMapMemory);
    defer vk.unmapMemory(self.device, memory);
    var gpu_data: [*]T = @ptrCast(@alignCast(gpu_ptr));
    @memcpy(gpu_data[0..data.len], data);
}

const Buffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
};

fn createBuffer(
    self: *const @This(),
    comptime T: type,
    data: []const T,
) vk.Errors!Buffer {
    const size: vk.DeviceSize = @sizeOf(T) * data.len;
    const staging_buffer = try self.createVulkanBuffer(size, .init(.transfer_src_bit));
    defer vk.destroyBuffer(self.device, staging_buffer, null);

    const staging_buffer_memory = try self.createVulkanBufferMemory(
        staging_buffer,
        .initMany(&.{ .host_visible_bit, .host_coherent_bit }),
    );
    defer vk.freeMemory(self.device, staging_buffer_memory, null);

    try self.mapVulkanMemory(T, data, size, staging_buffer_memory);

    const buffer = try self.createVulkanBuffer(
        size,
        .initMany(&.{ .transfer_dst_bit, .index_buffer_bit }),
    );
    const buffer_memory = try self.createVulkanBufferMemory(
        buffer,
        .init(.device_local_bit),
    );
    try self.copyVulkanBuffer(staging_buffer, buffer, size);

    return .{
        .buffer = buffer,
        .memory = buffer_memory,
    };
}

fn copyVulkanBuffer(
    self: *const @This(),
    src: vk.Buffer,
    dst: vk.Buffer,
    size: vk.DeviceSize,
) vk.Errors!void {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .level = .primary,
        .command_pool = self.command_pool,
        .command_buffer_count = 1,
    };
    var command_buffer: vk.CommandBuffer = .null;
    try vk.allocateCommandBuffers(self.device, &alloc_info, &command_buffer)
        .handle(.FailedToAllocateCommandBuffer);

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .init(.one_time_submit_bit),
    };
    try vk.beginCommandBuffer(command_buffer, &begin_info)
        .handle(.FailedToBeginCommandBuffer);

    const copy_region = vk.BufferCopy{
        .size = size,
    };
    vk.cmdCopyBuffer(command_buffer, src, dst, 1, &copy_region);

    try vk.endCommandBuffer(command_buffer)
        .handle(.FailedToEndCommandBuffer);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = &command_buffer,
    };
    try vk.queueSubmit(self.graphics_queue, 1, &submit_info, .null)
        .handle(.FailedToSubmitQueue);
    try vk.queueWaitIdle(self.graphics_queue)
        .handle(.FailedToIdleQueue);

    vk.freeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);
}

fn beginSingleTimeCommands(self: *const @This()) vk.Errors!vk.CommandBuffer {
    const alloc_info: vk.CommandBufferAllocateInfo = .{
        .level = .primary,
        .command_pool = self.command_pool,
        .command_buffer_count = 1,
    };

    var command_buffer: vk.CommandBuffer = .null;
    try vk.allocateCommandBuffers(self.device, &alloc_info, &command_buffer)
        .handle(.FailedToAllocateCommandBuffers);
}

fn endSingleTimeCommands(
    self: *const @This(),
    command_buffer: vk.CommandBuffer,
) vk.Errors!void {
    vk.endCommandBuffer(command_buffer);
    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = &command_buffer,
    };
    vk.queueSubmit(self.graphics_queue, 1, &submit_info, .null);
    vk.queueWaitIdle(self.graphics_queue);
    vk.freeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);
}

fn createTextureImage(
    self: *const @This(),
    io: std.Io,
    gpa: std.mem.Allocator,
    filepath: []const u8,
) !vk.Image {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const fullpath = appendPaths(&buf, &.{ dirs.texture_dir, filepath });

    const img = try Image.read(io, gpa, fullpath);
    defer img.deinit(gpa);

    const image_size: vk.DeviceSize = img.width * img.height * 3;

    const staging_buffer = try self.createVulkanBuffer(image_size, .init(.transfer_src_bit));
    defer vk.destroyBuffer(self.device, staging_buffer, null);

    const staging_buffer_memory = try self.createVulkanBufferMemory(
        staging_buffer,
        .initMany(&.{ .host_visible_bit, .host_coherent_bit }),
    );
    defer vk.freeMemory(self.device, staging_buffer_memory, null);

    switch (img.pixels) {
        inline else => |data| {
            if (image_size != data.items.len) return error.InvalidDimensions;
            try self.mapVulkanMemory(@TypeOf(data.items[0]), data.items, image_size, staging_buffer_memory);
        },
    }

    self.texture_image = try createImage(
        .{ .width = img.width, .height = img.height },
        .r8g8b8a8_srgb,
        .init(.optimal),
        .initMany(&.{ .transfer_dst_bit, .sampled_bit }),
        .local_bit,
    );

    self.texture_image_memory = try createImageMemory();

    transitionImageLayout(self.texture_image, .r8g8b8a8_srgb, .undefined, .optimal);
    copyBufferToImage(
        staging_buffer,
        self.texture_image,
        .{ .width = img.width, .height = img.height, .depth = 0 },
    );
    transitionImageLayout(
        self.texture_image,
        .r8g8b8a8_srgb,
        .optimal,
        .shader_read_only_optimal,
    );
}

fn createImage(
    self: *const @This(),
    extent: vk.Extent3D,
    format: vk.Format,
    tiling: vk.ImageTilingFlags,
    usage: vk.ImageUsageFlags,
) vk.Errors!vk.Image {
    const create_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .extent = extent,
        .mip_levels = 1,
        .array_layers = 1,
        .format = format,
        .tiling = tiling,
        .initial_layout = .undefined,
        .usage = usage,
        .samples = .@"1_bit",
        .sharing_mode = .exclusive,
    };
    var image: vk.Image = .null;
    try vk.createImage(self.device, &create_info, null, &image)
        .handle(.FailedToCreateImage);
    return image;
}

fn createImageMemory(
    self: *const @This(),
    image: vk.Image,
    props: vk.MemoryPropertyFlags,
) vk.Errors!vk.DeviceMemory {
    var mem_reqs: vk.MemoryRequirements = .{};
    vk.getImageMemoryRequirements(self.device, image, &mem_reqs);

    const alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try self.findMemoryType(mem_reqs.memory_type_bits, props),
    };

    var memory: vk.DeviceMemory = .null;
    try vk.allocateMemory(self.device, &alloc_info, null, &memory)
        .handle(.FailedToAllocateImageMemory);
    vk.bindImageMemory(self.device, image, memory, 0);
    return memory;
}

fn transitionImageLayout(
    image: vk.Image,
    format: vk.Format,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) !void {
    _ = format;
    const command_buffer = try beginSingleTimeCommands();
    defer endSingleTimeCommands(command_buffer);

    var barrier: vk.ImageMemoryBarrier = .{
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QueueFamilyIgnored,
        .dst_queue_family_index = vk.QueueFamilyIgnored,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .color_bit,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    var src_stage: vk.PipelineStageFlags = undefined;
    var dst_stage: vk.PipelineStageFlags = undefined;
    if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
        barrier.src_access_mask = 0;
        barrier.dst_access_mask = .transfer_write_bit;

        src_stage = .top_of_pipe_bit;
        dst_stage = .transfer_bit;
    } else if (old_layout == .transfer_dst_optimal and
        new_layout == .shader_read_only_optimal)
    {
        barrier.src_access_mask = .transfer_write_bit;
        barrier.dst_access_mask = .shader_read_bit;

        src_stage = .transfer_bit;
        dst_stage = .fragment_shader_bit;
    } else {
        return vk.Errors.UnsupportedLayoutTransition;
    }

    vk.cmdPipelineBarrier(
        command_buffer,
        src_stage,
        dst_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

fn copyBufferToImage(
    buffer: vk.Buffer,
    image: vk.Image,
    image_extent: vk.Extent3D,
) !void {
    const command_buffer = try beginSingleTimeCommands();
    defer endSingleTimeCommands(command_buffer);

    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_iamge_height = 0,
        .image_subresource = .{
            .aspect_mask = .color_bit,
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = image_extent,
        },
    };
    vk.cmdCopyBufferToImage(
        command_buffer,
        buffer,
        image,
        .transfer_dst_optimal,
        1,
        &region,
    );
}

fn createImageView(
    self: *const @This(),
    image: vk.Image,
    format: vk.Format,
) vk.Errors!vk.ImageView {
    const create_info = vk.ImageViewCreateInfo{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .subresource_range = .{
            .aspect_mask = .init(.color_bit),
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    var view: vk.ImageView = .null;
    try vk.createImageView(self.device, &create_info, null, &view)
        .handle(.FailedToCreateTextureImageView);
    return view;
}

fn createTextureImageView(self: *const @This()) vk.Errors!vk.ImageView {
    _ = self;
    // const tex_img = load("tex img path");
    // return self.createImageView(tex_img, .r8g8b8a8_srgb);
}

fn createCommandBuffers(
    self: *const @This(),
    len: usize,
) vk.Errors!CommandBuffers {
    std.debug.assert(len <= MAX_FRAMES_IN_FLIGHT);
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = @truncate(len),
    };
    var command_buffers: CommandBuffers = .{.null} ** MAX_FRAMES_IN_FLIGHT;
    try vk.allocateCommandBuffers(self.device, &alloc_info, &command_buffers)
        .handle(.FailedToAllocateCommandBuffers);
    return command_buffers;
}

fn recordCommandBuffer(
    self: *@This(),
    command_buffer: vk.CommandBuffer,
    image_index: u32,
    vertices: []const Vertex,
    indices: []const u16,
) vk.Errors!void {
    const cb_begin_info: vk.CommandBufferBeginInfo = .{};
    try vk.beginCommandBuffer(command_buffer, &cb_begin_info)
        .handle(.FailedToBeginRecordingCommandBuffer);

    const clear_colors = [_]vk.ClearValue{
        vk.ClearValue{ .color = .{
            .float32 = [4]f32{ 0, 0, 0, 1 },
        } },
    };
    const rp_begin_info: vk.RenderPassBeginInfo = .{
        .render_pass = self.swapchain_render_pass,
        .framebuffer = self.swapchain_framebuffers[image_index],
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        },
        .clear_value_count = @truncate(clear_colors.len),
        .p_clear_values = &clear_colors,
    };
    vk.cmdBeginRenderPass(command_buffer, &rp_begin_info, .@"inline");

    vk.cmdBindPipeline(command_buffer, .graphics, self.pipeline);

    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.swapchain_extent.width),
        .height = @floatFromInt(self.swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    vk.cmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor: vk.Rect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapchain_extent,
    };
    vk.cmdSetScissor(command_buffer, 0, 1, &scissor);

    _ = vertices;
    const vertex_buffers = [_]vk.Buffer{self.vertex_buffer};
    const offsets = [_]vk.DeviceSize{0};
    vk.cmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);
    vk.cmdBindIndexBuffer(command_buffer, self.index_buffer, 0, .uint16);
    vk.cmdDrawIndexed(command_buffer, @truncate(indices.len), 1, 0, 0, 0);

    // vk.cmdDraw(command_buffer, @truncate(vertices.len), 1, 0, 0);

    vk.cmdEndRenderPass(command_buffer);

    try vk.endCommandBuffer(command_buffer)
        .handle(.FailedToRecordCommandBuffer);
}

fn createFences(
    self: *const @This(),
    len: usize,
) vk.Errors!Fences {
    std.debug.assert(len <= MAX_FRAMES_IN_FLIGHT);
    const create_info: vk.FenceCreateInfo = .{
        .flags = .init(.signaled_bit),
    };
    var fences: Fences = .{.null} ** MAX_FRAMES_IN_FLIGHT;
    for (0..len) |i| {
        try vk.createFence(self.device, &create_info, null, &fences[i])
            .handle(.FailedToCreateFence);
    }
    return fences;
}

fn createSemaphores(
    self: *const @This(),
    len: usize,
) vk.Errors!Semaphores {
    std.debug.assert(len <= MAX_FRAMES_IN_FLIGHT);
    const create_info: vk.SemaphoreCreateInfo = .{};
    var semaphores: Semaphores = .{.null} ** MAX_FRAMES_IN_FLIGHT;
    for (0..len) |i| {
        try vk.createSemaphore(self.device, &create_info, null, &semaphores[i])
            .handle(.FailedToCreateSemaphore);
    }
    return semaphores;
}

fn drawFrame(
    self: *@This(),
    vertices: []const Vertex,
    indices: []const u16,
) vk.Errors!void {
    try vk.waitForFences(
        self.device,
        1,
        &self.in_flight_fences[self.current_frame],
        .true,
        std.math.maxInt(u64),
    )
        .handle(.FailedToWaitForFence);
    try vk.resetFences(self.device, 1, &self.in_flight_fences[self.current_frame])
        .handle(.FailedToResetFences);

    var image_index: u32 = undefined;
    try vk.acquireNextImageKHR(
        self.device,
        self.swapchain,
        std.math.maxInt(u64),
        self.image_available_semaphores[self.current_frame],
        .null,
        &image_index,
    )
        .handle(.FailedToAcquireNextImage);

    try vk.resetCommandBuffer(self.command_buffers[self.current_frame], .empty)
        .handle(.FailedToResetCommandBuffer);
    try self.recordCommandBuffer(
        self.command_buffers[self.current_frame],
        image_index,
        vertices,
        indices,
    );

    const wait_semaphores = [1]vk.Semaphore{
        self.image_available_semaphores[self.current_frame],
    };
    const wait_stages = [1]vk.PipelineStageFlags{.init(.color_attachment_output_bit)};
    const signal_semaphores = [1]vk.Semaphore{
        self.render_finished_semaphores[self.current_frame],
    };
    const submit_info: vk.SubmitInfo = .{
        .wait_semaphore_count = @truncate(wait_semaphores.len),
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = &wait_stages,
        .command_buffer_count = 1,
        .p_command_buffers = &self.command_buffers[self.current_frame],
        .signal_semaphore_count = @truncate(signal_semaphores.len),
        .p_signal_semaphores = &signal_semaphores,
    };
    try vk.queueSubmit(
        self.graphics_queue,
        1,
        &submit_info,
        self.in_flight_fences[self.current_frame],
    )
        .handle(.FailedToSubmitDrawCommandBuffer);
    const swapchains = [1]vk.SwapchainKHR{self.swapchain};
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = @truncate(signal_semaphores.len),
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = @truncate(swapchains.len),
        .p_swapchains = &swapchains,
        .p_image_indices = &image_index,
        // .p_results = null,
    };
    try vk.queuePresentKHR(self.present_queue, &present_info)
        .handle(.FailedToPresentQueue);
    self.current_frame = @mod(self.current_frame, MAX_FRAMES_IN_FLIGHT);
}

fn findMemoryType(self: *const @This(), type_filter: u32, props: vk.MemoryPropertyFlags) !u32 {
    var mem_props: vk.PhysicalDeviceMemoryProperties = .{};
    vk.getPhysicalDeviceMemoryProperties(self.physical_device, &mem_props);
    for (0..mem_props.memory_type_count) |i| {
        if ((type_filter & (@as(@TypeOf(type_filter), 1) << @truncate(i))) > 0 and
            mem_props.memory_types[i].property_flags.isSupersetOf(props))
            return @truncate(i);
    } else return vk.Errors.FailedToFindSuitableMemoryType;
}
