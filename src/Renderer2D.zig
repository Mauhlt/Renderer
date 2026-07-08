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
const UniformBuffers: type = [MAX_FRAMES_IN_FLIGHT]vk.Buffer;
const UniformBufferMemories: type = [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory;
const UniformBufferMaps: type = [MAX_FRAMES_IN_FLIGHT]?*anyopaque;
const DescriptorSets: type = [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet;
const Vertex = @import("Vertex.zig");
const UBO = @import("UniformBufferObject.zig");
const FPS = @import("FPS.zig");
const VulkanImage = struct {
    image: vk.Image,
    buffer: vk.Buffer,
};
const VulkanBuffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
};

// Total: 4kB - Used 328 bytes
shader: Dir = undefined,
texture: Dir = undefined,
// base
window: Window = undefined, // 8
instance: vk.Instance = .null, // 16
physical_device: vk.PhysicalDevice = .null, // 24
surface: vk.SurfaceKHR = .null, // 32
device: vk.Device = .null, // 40
graphics_queue: vk.Queue = .null, // 48
present_queue: vk.Queue = .null, // 56
// swapchain
swapchain: vk.SwapchainKHR = .null, // 64
n_swapchain_images: usize = 0, // 72
swapchain_images: Images = .{.null} ** MAX_IMAGES, // 88
swapchain_format: vk.Format = .b8g8r8a8_srgb, // 96
swapchain_extent: vk.Extent2D = .{ .width = 640, .height = 480 }, // 104
swapchain_image_views: ImageViews = .{.null} ** MAX_IMAGES, // 120
swapchain_framebuffers: Framebuffers = .{.null} ** MAX_IMAGES, // 136
// pipeline
swapchain_render_pass: vk.RenderPass = .null, // 144
descriptor_set_layout: vk.DescriptorSetLayout = .null, // 152
pipeline_layout: vk.PipelineLayout = .null, // 160
// pipeline_config: vk.GraphicsPipelineCreateInfo = .{},
pipeline: vk.Pipeline = .null, // 168

command_pool: vk.CommandPool = .null, // 176
// textures
texture_image: vk.Image = .null, // 184
texture_memory: vk.DeviceMemory = .null, // 192
texture_image_view: vk.ImageView = .null, // 200
texture_sampler: vk.Sampler = .null, // 208
// vertex
vertex_buffer: vk.Buffer = .null, // 216
vertex_buffer_memory: vk.DeviceMemory = .null, // 224
// index
index_buffer: vk.Buffer = .null, // 232
index_buffer_memory: vk.DeviceMemory = .null, // 240
// uniform buffers
uniform_buffers: UniformBuffers = [_]vk.Buffer{.null} ** MAX_FRAMES_IN_FLIGHT, // 256
uniform_buffer_memories: UniformBufferMemories = [_]vk.DeviceMemory{.null} ** MAX_FRAMES_IN_FLIGHT, // 272
uniform_buffer_maps: UniformBufferMaps = [_]?*anyopaque{null} ** MAX_FRAMES_IN_FLIGHT, // 288
// descriptors
descriptor_pool: vk.DescriptorPool = .null, // 296
descriptor_sets: DescriptorSets = [_]vk.DescriptorSet{.null} ** MAX_FRAMES_IN_FLIGHT, // 312
// command
command_buffers: CommandBuffers = .{.null} ** MAX_FRAMES_IN_FLIGHT, // 328
// sync
image_available_semaphores: Semaphores = .{.null} ** MAX_FRAMES_IN_FLIGHT, // 344
render_finished_semaphores: Semaphores = .{.null} ** MAX_FRAMES_IN_FLIGHT, // 360
in_flight_fences: Fences = .{.null} ** MAX_FRAMES_IN_FLIGHT, // 376
// misc
current_frame: usize = 0, // 384
framebuffer_resize: bool = false, // 392

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
) !void {
    // TODO: Remove this and generate data based on player position
    const vertices = [_]Vertex{
        .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1, 0, 0 }, .tex_coord = .{ 1, 0 } },
        .{ .pos = .{ 0.5, -0.5 }, .color = .{ 0, 1, 0 }, .tex_coord = .{ 0, 0 } },
        .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 0, 1 }, .tex_coord = .{ 0, 1 } },
        .{ .pos = .{ -0.5, 0.5 }, .color = .{ 1, 1, 1 }, .tex_coord = .{ 1, 1 } },
    };
    const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
    var self: @This() = .{};
    // path to executable
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executableDirPath(io, &buf);
    const exe_dir = buf[0..n];
    // path to shader
    const shader_filename = try std.fs.path.join(gpa, &.{ exe_dir, "Shaders" });
    defer gpa.free(shader_filename);
    self.shader = try Dir.openDirAbsolute(io, shader_filename, .{});
    errdefer self.shader.close(io);
    // path to texture
    const texture_filename = try std.fs.path.join(gpa, &.{ exe_dir, "Textures" });
    defer gpa.free(texture_filename);
    self.texture = try Dir.openDirAbsolute(io, texture_filename, .{});
    errdefer self.texture.close(io);

    const app_name: [*:0]const u8 = "Glint";
    self.window = try self.initWindow(
        std.mem.span(app_name),
        std.mem.span(app_name),
    );
    try self.initVulkan(io, gpa, app_name, &vertices, &indices);
    // self.window.show();
    // try self.coreLoop(io, &vertices, &indices);
    self.deinit(io);
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

// TODO:
// 1. resize window + blur on resize
// 2. remove vertices + indices - load it on use
// 3. pass dir to image
fn initVulkan(
    self: *@This(),
    io: std.Io,
    gpa: std.mem.Allocator,
    app_name: [*:0]const u8,
    vertices: []const Vertex,
    indices: []const u16,
) !void {
    const ries = [_][*:0]const u8{
        vk.ExtensionName.win32_surface,
        vk.ExtensionName.surface,
    };

    self.instance = try createInstance(app_name, &ries);
    errdefer vk.destroyInstance(self.instance, null);

    self.surface = try self.createSurface();
    errdefer vk.destroySurfaceKHR(self.instance, self.surface, null);

    const rdes = [_][*:0]const u8{vk.ExtensionName.swapchain};
    self.physical_device = try self.pickPhysicalDevice(&rdes);

    self.device = try self.createLogicalDevice(&rdes);
    errdefer vk.destroyDevice(self.device, null);

    const qfi: QFI = try .init(self.physical_device, self.surface);
    self.graphics_queue = self.createQueue(qfi.graphics_family.?);
    self.present_queue = self.createQueue(qfi.present_family.?);

    self.swapchain = try self.createSwapchain();
    errdefer vk.destroySwapchainKHR(self.device, self.swapchain, null);

    self.n_swapchain_images = try self.getNumSwapchainImages();
    self.swapchain_images = try self.createSwapchainImages();

    const ssd: SSD = try .init(self.physical_device, self.surface);
    self.swapchain_format = ssd.chooseSwapSurfaceFormat().format;
    self.swapchain_extent = ssd.chooseSwapExtent(&self.window);

    self.swapchain_image_views = try self.createSwapchainImageViews();
    errdefer for (0..MAX_IMAGES) |i| vk.destroyImageView(self.device, self.swapchain_image_views[i], null);

    self.swapchain_framebuffers = try self.createSwapchainFramebuffers();
    errdefer for (0..MAX_IMAGES) |i| vk.destroyFramebuffer(self.device, self.swapchain_framebuffers[i], null);

    self.swapchain_render_pass = try self.createRenderPass();
    errdefer vk.destroyRenderPass(self.device, self.swapchain_render_pass, null);

    self.descriptor_set_layout = try self.createDescriptorSetLayout();
    errdefer vk.destroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);

    self.pipeline_layout = try self.createPipelineLayout();
    errdefer vk.destroyPipelineLayout(self.device, self.pipeline_layout, null);

    const shader_filenames = [_][]const u8{ "square.vert.spv", "square.frag.spv" };
    self.pipeline = try self.createGraphicsPipeline(gpa, io, &shader_filenames);
    errdefer vk.destroyPipeline(self.device, self.pipeline, null);

    self.command_pool = try self.createCommandPool();
    errdefer vk.destroyCommandPool(self.device, self.command_pool, null);

    self.texture_image = try self.createTextureImage(io, gpa, "BasicArt.bmp");
    self.texture_image_view = try self.createTextureImageView();
    self.texture_sampler = try self.createTextureSampler();

    const vertex_buffer = try self.createBuffer(Vertex, vertices);
    self.vertex_buffer = vertex_buffer.buffer;
    self.vertex_buffer_memory = vertex_buffer.memory;

    const index_buffer = try self.createBuffer(u16, indices);
    self.index_buffer = index_buffer.buffer;
    self.index_buffer_memory = index_buffer.memory;

    self.uniform_buffers = self.createUniformBuffers();
    self.uniform_buffer_memories = self.createUniformBufferMemories();
    self.uniform_buffer_maps = self.createUniformBufferMaps();

    self.descriptor_pool = try self.createDescriptorPool();
    self.descriptor_sets = try self.createDescriptorSets();

    self.command_buffers = try self.createCommandBuffers(MAX_FRAMES_IN_FLIGHT);

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

fn deinit(self: *@This(), io: std.Io) void {
    self.deinitDirs(io);
    self.deinitVulkan();
}

fn deinitDirs(self: *@This(), io: std.Io) void {
    self.shader.close(io);
    self.texture.close(io);
}

fn deinitVulkan(self: *@This()) void {
    self.destroySwapchain();

    vk.destroyPipeline(self.device, self.pipeline, null);
    vk.destroyPipelineLayout(self.device, self.pipeline_layout, null);
    vk.destroyRenderPass(self.device, self.swapchain_render_pass, null);

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        vk.destroyBuffer(self.device, self.uniform_buffers[i], null);
        vk.freeMemory(self.device, self.uniform_buffers_memories[i], null);
    }

    vk.destroyDescriptorPool(self.device, self.descriptor_pool, null);

    vk.destroySampler(self.device, self.texture_sampler, null);
    vk.destroyImageView(self.device, self.texture_image_view, null);
    vk.destroyImage(self.device, self.texture_image, null);
    vk.freeMemory(self.device, self.texture_image_memory, null);

    vk.destroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);

    vk.destroyBuffer(self.device, self.index_buffer, null);
    vk.freeMemory(self.device, self.index_buffer_memory, null);

    vk.destroyBuffer(self.device, self.vertex_buffer, null);
    vk.freeMemory(self.device, self.vertex_buffer_memory, null);

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        vk.destroySemaphore(self.device, self.render_finished_semaphores[i], null);
        vk.destroySemaphore(self.device, self.image_available_semaphores[i], null);
        vk.destroyFence(self.device, self.in_flight_fences[i], null);
    }

    vk.destroyCommandPool(self.device, self.command_pool, null);

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
    // TODO: add VK_EXT_DEBUG_UTILS_EXTENSION_NAME - better debug + allows callbacks
    // defaults: khr_surface, khr_win32_surface, ext_debug_utils,
    // layers: layer_khronos_validation
    // add debugutilsmessengercreateinfoext struct - pass in debug callback fn
    // pnext = convert structs into linked lists
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
    const extensions_supported = checkDeviceExtensionSupport(physical_device, rdes);
    const ssd = SSD.init(physical_device, surface) catch return false;
    return qfi.isComplete() and
        extensions_supported and
        ssd.isComplete() and
        feats.sampler_anisotropy == .true;
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
        // .macos => {},
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
    var feats: vk.PhysicalDeviceFeatures = .{
        .sampler_anisotropy = .true,
    };
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
    var n_images: u32 = @truncate(self.n_swapchain_images);
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

fn createRenderPass(self: *const @This()) vk.Errors!vk.RenderPass {
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

fn createDescriptorSetLayout(self: *const @This()) vk.Errors!vk.DescriptorSetLayout {
    const ubo_layout_binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_count = 1,
        .descriptor_type = .uniform_buffer,
        .p_immutable_samplers = null,
        .stage_flags = .init(.vertex_bit),
    };

    const sampler_layout_binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 1,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_immutable_samplers = null,
        .stage_flags = .init(.fragment_bit),
    };

    const bindings: [2]vk.DescriptorSetLayoutBinding = //
        .{ ubo_layout_binding, sampler_layout_binding };

    const create_info: vk.DescriptorSetLayoutCreateInfo = .{
        .binding_count = @truncate(bindings.len),
        .p_bindings = &bindings,
    };

    var layout: vk.DescriptorSetLayout = .null;
    try vk.createDescriptorSetLayout(self.device, &create_info, null, &layout)
        .handle(.FailedToCreateDescriptorSetLayout);
    return layout;
}

fn createPipelineLayout(self: *const @This()) vk.Errors!vk.PipelineLayout {
    const create_info: vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = 1,
        .p_set_layouts = &self.descriptor_set_layout,
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
    gpa: std.mem.Allocator,
    io: std.Io,
    shader_filenames: []const []const u8,
) !vk.Pipeline {
    _ = gpa;
    var sms = [_]vk.ShaderModule{.null} ** 2;
    var data: [4096]u8 = undefined;
    for (shader_filenames, 0..) |shader_filename, i| {
        const sc = self.readShaderSPV(io, shader_filename, &data) catch unreachable;
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
    self: *const @This(),
    io: std.Io,
    shader_filename: []const u8,
    data: *[4096]u8,
) ![]const u8 {
    const file = try self.shader.openFile(io, shader_filename, .{ .mode = .read_only });
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

const Texture = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    sampler: vk.Sampler,

    pub fn deinit(self: *@This(), device: vk.Device) void {
        vk.destroyImage(device, self.image, null);
        vk.freeMemory(device, self.memory, null);
        vk.destroyImageView(device, self.image_view, null);
    }
};

fn createBuffer(
    self: *const @This(),
    comptime T: type,
    data: []const T,
) vk.Errors!VulkanBuffer {
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
    return command_buffer;
}

fn endSingleTimeCommands(
    self: *const @This(),
    command_buffer: vk.CommandBuffer,
) !void {
    try vk.endCommandBuffer(command_buffer)
        .handle(.FailedToEndCommandBuffer);
    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = &command_buffer,
    };
    try vk.queueSubmit(self.graphics_queue, 1, &submit_info, .null)
        .handle(.FailedToSubmitQueue);
    try vk.queueWaitIdle(self.graphics_queue)
        .handle(.FailedToIdleQueue);
    vk.freeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);
}

fn createTextureImage(
    self: *const @This(),
    io: std.Io,
    gpa: std.mem.Allocator,
    filename: []const u8,
) !VulkanImage {
    // TODO: fix image so that read can be written as:  var img: Image = try .read();
    var img = try Image.read(.{
        .io = io,
        .gpa = gpa,
        .dir = self.texture,
        .path = filename,
        .path_type = .dir,
    });
    defer img.deinit(gpa);

    // TODO: should be changed to match img dimensions
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
            if (image_size != data.len) return error.MismatchDimensions;
            try self.mapVulkanMemory(@TypeOf(data[0]), data, image_size, staging_buffer_memory);
        },
    }

    var texture: VulkanImage = undefined;
    texture.image = try self.createImage(
        .{ .width = img.width, .height = img.height },
        .r8g8b8a8_srgb,
        .init(.optimal),
        .initMany(&.{ .transfer_dst_bit, .sampled_bit }),
    );
    texture.memory = try self.createImageMemory(
        texture.image,
        .init(.device_local_bit),
    );

    try self.transitionImageLayout(
        texture.image,
        .r8g8b8a8_srgb,
        .undefined,
        .transfer_dst_optimal,
    );
    try self.copyBufferToImage(
        staging_buffer,
        texture.image,
        .{
            .width = img.width,
            .height = img.height,
            .depth = 0,
        },
    );
    try self.transitionImageLayout(
        texture.image,
        .r8g8b8a8_srgb,
        .transfer_dst_optimal,
        .shader_read_only_optimal,
    );
    return texture;
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
    try vk.bindImageMemory(self.device, image, memory, 0)
        .handle(.FailedToBindImageMemory);
    return memory;
}

fn transitionImageLayout(
    self: *const @This(),
    image: vk.Image,
    format: vk.Format,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) !void {
    _ = format;
    const command_buffer = try self.beginSingleTimeCommands();
    errdefer self.endSingleTimeCommands(command_buffer) catch unreachable;

    var barrier: vk.ImageMemoryBarrier = .{
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QueueFamilyIgnored,
        .dst_queue_family_index = vk.QueueFamilyIgnored,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .init(.color_bit),
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    var src_stage: vk.PipelineStageFlags = undefined;
    var dst_stage: vk.PipelineStageFlags = undefined;
    if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
        barrier.src_access_mask = .init(.none);
        barrier.dst_access_mask = .init(.transfer_write_bit);

        src_stage = .init(.top_of_pipe_bit);
        dst_stage = .init(.transfer_bit);
    } else if (old_layout == .transfer_dst_optimal and
        new_layout == .shader_read_only_optimal)
    {
        barrier.src_access_mask = .init(.transfer_write_bit);
        barrier.dst_access_mask = .init(.shader_read_bit);

        src_stage = .init(.transfer_bit);
        dst_stage = .init(.fragment_shader_bit);
    } else {
        return vk.Errors.UnsupportedLayoutTransition;
    }

    vk.cmdPipelineBarrier(
        command_buffer,
        src_stage,
        dst_stage,
        .init(.null),
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
    try self.endSingleTimeCommands(command_buffer);
}

fn copyBufferToImage(
    self: *const @This(),
    buffer: vk.Buffer,
    image: vk.Image,
    image_extent: vk.Extent3D,
) !void {
    const command_buffer = try self.beginSingleTimeCommands();
    errdefer self.endSingleTimeCommands(command_buffer) catch unreachable;

    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .init(.color_bit),
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = image_extent,
    };
    vk.cmdCopyBufferToImage(
        command_buffer,
        buffer,
        image,
        .transfer_dst_optimal,
        1,
        &region,
    );
    try self.endSingleTimeCommands(command_buffer);
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
    return self.createImageView(self.texture_image.image, .r8g8b8a8_srgb);
}

fn createTextureSampler(self: *const @This()) !vk.Sampler {
    var props: vk.PhysicalDeviceProperties = .{};
    vk.getPhysicalDeviceProperties(self.physical_device, &props);

    const create_info: vk.SamplerCreateInfo = .{
        .mag_filter = .linear,
        .min_filter = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .anisotropy_enable = .true,
        .max_anisotropy = props.limits.max_sampler_anisotropy,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = .false,
        .compare_enable = .false,
        .compare_op = .always,
        .mipmap_mode = .linear,
        .miplod_bias = 0,
        .min_lod = 0,
        .max_lod = 0,
    };
    var sampler: vk.Sampler = .null;
    try vk.createSampler(self.device, &create_info, null, &sampler)
        .handle(.FailedToCreateTextureSampler);
    return sampler;
}

fn createUniformBuffers(self: *const @This()) !void {
    const size: vk.DeviceSize = @sizeOf(UBO);
    var uniform_buffers = [_]vk.Buffer{.null} ** MAX_FRAMES_IN_FLIGHT;
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        uniform_buffers[i] = try self.createBuffer(size, .uniform_buffer_bit, .initMany(&.{ .host_visible_bit, .host_coherent_bit }));
    }
    return uniform_buffers;
}

fn createDescriptorPool(self: *const @This()) vk.Errors!vk.DescriptorPool {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = .uniform_buffer,
            .descriptor_count = @truncate(self.uniform_buffers.len),
        },
        .{
            .type = .combined_image_sampler,
            .descriptor_count = @truncate(self.descriptor_sets.len),
        },
    };
    const create_info: vk.DescriptorPoolCreateInfo = .{
        .pool_size_count = @truncate(pool_sizes.len),
        .p_pool_sizes = &pool_sizes,
        .max_sets = MAX_FRAMES_IN_FLIGHT,
    };
    var pool: vk.DescriptorPool = .null;
    try vk.createDescriptorPool(self.device, &create_info, null, &pool)
        .handle(.FailedToCreateDescriptorPool);
    return pool;
}

fn createDescriptorSets(self: *const @This()) vk.Errors!DescriptorSets {
    var layouts = [_]vk.DescriptorSetLayout{.null} ** MAX_FRAMES_IN_FLIGHT;

    const alloc_info: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = @truncate(layouts.len),
        .p_set_layouts = &layouts,
    };

    try vk.allocateDescriptorSets(self.device, &alloc_info, &layouts)
        .handle(.FailedToAllocateDescriptorSets);

    for (0..layouts.len) |i| {
        const buffer_info: vk.DescriptorBufferInfo = .{
            .buffer = self.uniform_buffers[i],
            .offset = 0,
            .range = @sizeOf(UBO),
        };

        const image_info: vk.DescriptorImageInfo = .{
            .image_layout = .shader_read_only_optimal,
            .image_view = self.texture_image_view,
            .sampler = self.texture_sampler,
        };

        const writes = [_]vk.DescriptorSetWrite{
            .{
                .dst_set = self.descriptor_sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .p_buffer_info = &buffer_info,
            },
            .{
                .dst_set = self.descriptor_sets[i],
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .p_image_info = &image_info,
            },
        };

        vk.updateDescriptorSets(self.device, @truncate(writes.len), &writes, 0, null);
    }
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
