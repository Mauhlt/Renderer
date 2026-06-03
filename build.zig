const std = @import("std");
const Dir = std.Io.Dir;

pub fn build(b: *std.Build) !void {
    // set cwd
    const target = b.standardTargetOptions(.{});
    switch (target.result.os.tag) {
        .windows => {},
        inline else => |tag| std.log.err("Unsupported OS: {t}", .{tag}),
    }
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "Renderer", // "GameEngine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
            .link_libc = true,
        }),
    });
    // vulkan
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
    // libraries
    const windows_mod = addLibrary(b, "Windows");
    const vulkan_mod = addLibraryWithCommonModules(b, "Vulkan", &.{windows_mod});
    const image_mod = addLibraryWithCommonModules(b, "Image", &.{ windows_mod, vulkan_mod });
    exe.root_module.addImport(windows_mod.name, windows_mod.mod);
    exe.root_module.addImport(vulkan_mod.name, vulkan_mod.mod);
    exe.root_module.addImport(image_mod.name, image_mod.mod);

    // install
    b.installArtifact(exe);
    // options
    const basepath = b.build_root.path.?;
    const shader_dir = b.pathJoin(&.{ basepath, "src\\Shaders" });
    const texture_dir = b.pathJoin(&.{ basepath, "src\\Textures" });
    const dir_options = b.addOptions();
    dir_options.addOption([]const u8, "shader_dir", shader_dir);
    dir_options.addOption([]const u8, "texture_dir", texture_dir);
    exe.root_module.addOptions("dirs", dir_options);
    // Compile Shaders
    const io = b.graph.io;
    var dir = try Dir.openDirAbsolute(io, shader_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(b.allocator);
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {},
            else => continue,
        }
        if (!isShader(entry.basename)) continue;
        try compileShader(b, io, shader_dir, entry.basename);
    }
    // Create Run Command
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    // Process Args
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    // Build Tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn isShader(name: []const u8) bool {
    for ([_][]const u8{ "vert", "frag" }) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    } else return false;
}

fn compileShader(
    b: *std.Build,
    io: std.Io,
    shader_dir: []const u8,
    filename: []const u8,
) !void {
    const glslc = b.pathFromRoot("Vulkan/Bin/glslc.exe");
    const in_file = b.pathFromRoot(b.pathJoin(&.{ shader_dir, filename }));
    // get out file
    var new_filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(new_filename_buf[0..in_file.len], in_file);
    const ext = ".spv";
    @memcpy(new_filename_buf[in_file.len .. in_file.len + ext.len], ext);
    const out_file = new_filename_buf[0 .. in_file.len + ext.len];
    // start child process
    var child = try std.process.spawn(io, .{
        .argv = &.{ glslc, in_file, "-o", out_file },
        .create_no_window = true,
    });
    const term = try child.wait(io);
    outer: while (true) {
        switch (term) {
            .exited => break :outer,
            else => {},
        }
    }
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
