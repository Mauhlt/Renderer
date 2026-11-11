const std = @import("std");

pub fn build(b: *std.Build) !void {
    // set cwd
    const target = b.standardTargetOptions(.{});
    switch (target.result.os.tag) {
        .windows => {},
        inline else => |tag| std.log.err("Unsupported OS: {t}", .{tag}),
    }
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "Renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
            .link_libc = true,
        }),
    });
    // Vulkan
    exe.root_module.addLibraryPath(b.path("Vulkan/Lib"));
    switch (target.result.os.tag) {
        .windows => exe.root_module.linkSystemLibrary("vulkan-1", .{}),
        .linux => {},
        .macos => {},
        else => @panic("OS not supported!"),
    }
    exe.root_module.addIncludePath(b.path("Vulkan/Include"));
    // System Libraries
    switch (target.result.os.tag) {
        .windows => {
            exe.root_module.linkSystemLibrary("kernel32", .{});
            exe.root_module.linkSystemLibrary("user32", .{}); // gdi32
        },
        else => unreachable,
    }
    // Libraries
    const windows_mod = addLibrary(b, "Windows");
    const vulkan_mod = addLibraryWithCommonModules(b, "Vulkan", &.{windows_mod});
    const image_mod = addLibraryWithCommonModules(b, "Image", &.{ windows_mod, vulkan_mod });
    exe.root_module.addImport(windows_mod.name, windows_mod.mod);
    exe.root_module.addImport(vulkan_mod.name, vulkan_mod.mod);
    exe.root_module.addImport(image_mod.name, image_mod.mod);
    // Compile Shaders
    const shader_dir_path = "src\\Shaders";
    var shader_dir = b.root.root_dir.handle.openDir(
        b.graph.io,
        shader_dir_path,
        .{ .iterate = true },
    ) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        return;
    };
    defer shader_dir.close(b.graph.io);
    var walker = try shader_dir.walk(b.allocator);
    while (try walker.next(b.graph.io)) |entry| {
        switch (entry.kind) {
            .file => {},
            else => continue,
        }
        const src = entry.basename;
        if (!isShaderFile(src)) continue;
        const spv = compileShader(b, b.fmt("{s}/{s}", .{ shader_dir_path, src }));
        const install = b.addInstallFileWithDir(spv, .bin, b.fmt("Shaders/{s}.spv", .{src}));
        b.getInstallStep().dependOn(&install.step);
    }
    // Add Custom Dirs (Textures, Materials, Animations)
    const src_dirs = [_][]const u8{"src/Textures"};
    const sub_paths = [_][]const u8{"Textures"};
    for (src_dirs, sub_paths) |src_dir, sub_path| {
        b.installDirectory(.{
            .source_dir = b.path(src_dir),
            .install_dir = .bin,
            .install_subdir = sub_path,
        });
    }
    // Install
    b.installArtifact(exe);
    // Create Run Command
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path(".")); // defaults cwd to root of project
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    // Process Args
    run_cmd.addPassthruArgs(); // zig build run -- arg1 arg2
    // Build Tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

// TODO: impl hot reloading shaders
// fn compileShader2(io: std.Io, allo: std.mem.Allocator, src_path: []const u8, out_path: []const u8) !void {
//  var child = try std.process.spawn(io, .{
//  .argv = &.{"glslc", src_path, "-o", out_path},
//  .allocator = allocator,
//  });
//  const term = try child.wait(io);
//  if (term.Exited != 0) return error.ShaderCompilationFailed;
// }

// TODO: Install Layout:
// zig-out/bin/
//   app.exe
//   shaders/
//     vert.spv
//     frag.spv
// fn loadShader(io: std.Io, allo: std.mem.Allocator, exe_dir: []const u8, name: []const u8) ![]u8 {
//   const path = try std.fs.path.join(allo, &.{exe_dir, "shaders", name});
//   defer allo.free(path);
//   return std.Io.File.readFileAlloc(io, allo, path, 16 * 1024 * 1024);
// }
// pub fn main(init: std.process.Init) !void {
//   var buf: [std.fs.max_path_bytes]u8 = undefined;
//   const n = try std.process.executableDirPath(init.io, &buf);
//   const exe_dir = buf[0..n];
//   const vert = try loadShader(init.io, init.gpa, exe_dir, "mesh.vert.spv");
//   const frag = try loadShader(init.io, init.gpa, exe_dir, "mesh.frag.spv");
// }

fn isShaderFile(name: []const u8) bool {
    for ([_][]const u8{ "vert", "frag" }) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    } else return false;
}

fn compileShader(
    b: *std.Build,
    src: []const u8,
) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{ "Vulkan/Bin/glslc.exe", src, "-o" });
    return compile.addOutputFileArg(b.fmt("{s}.spv", .{src}));
}

fn addLibrary(b: *std.Build, library: []const u8) Module {
    const package = b.dependency(library, .{});
    return .{
        .name = library,
        .mod = package.module(library),
    };
}

const Module = struct {
    name: []const u8,
    mod: *std.Build.Module,
};

fn addLibraryWithCommonModules(
    b: *std.Build,
    library: []const u8,
    common_modules: []const Module,
) Module {
    const package = b.dependency(library, .{});
    const module = package.module(library);
    for (common_modules) |common_module| {
        module.addImport(common_module.name, common_module.mod);
    }
    return .{
        .name = library,
        .mod = module,
    };
}

// extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(WINAPI) u32;
// const dpi = GetDpiForWindow(hwnd);
// const scale = @as(f32, @floatFromInt(dpi)) / 96.0; // 96 = 100%, 144 = 150%
// if (needs_swapchain_rebuild) {
//     needs_swapchain_rebuild = false;
//     rebuildSwapchain(framebuffer_width, framebuffer_height);
// }
