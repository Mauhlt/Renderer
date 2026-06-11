const std = @import("std");
const Dir = std.Io.Dir;

<<<<<<< HEAD
=======
 //     _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  //
  //     // now register class, create window, etc.
  //     _ = RegisterClassExA(&wc);
  //     const hwnd = CreateWindowExA(...);
  // }
  //
  // ---
  // Is it in user32?
  //
  // Yes:
  // extern "user32" fn SetProcessDpiAwarenessContext(
  //     value: ?*anyopaque,
  // ) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
  //
  // ---
  // Toggle by architecture
  //
  // const builtin = @import("builtin");
  //
  // pub fn main() void {
  //     if (comptime builtin.cpu.arch == .aarch64) {
  //         _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  //     }
  //     // ...
  // }
  //
  // builtin.cpu.arch is comptime-known so this compiles to nothing on x86_64 — no runtime branch
  //
  //With PER_MONITOR_AWARE_V2 you handle two messages:

  // - WM_DPICHANGED — fires when the window moves to a different-DPI monitor or the user changes display scaling. Windows hands you a
  // pre-calculated suggested RECT — just use it directly with SetWindowPos.
  // - WM_SIZE — fires on any resize (user drag, maximize, DPI change follow-up). This is where you flag a Vulkan swapchain rebuild.
  //
  // fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(WINAPI) LRESULT {
  //     switch (msg) {
  //
  //         WM_DPICHANGED => {
  //             // lParam is Windows' suggested rect for the new DPI — use it as-is.
  //             const rect: *const RECT = @ptrFromInt(@as(usize, @intCast(lparam)));
  //             _ = SetWindowPos(
  //                 hwnd,
  //                 null,
  //                 rect.left,
  //                 rect.top,
  //                 rect.right  - rect.left,
  //                 rect.bottom - rect.top,
  //                 SWP_NOZORDER | SWP_NOACTIVATE,
  //             );
  //             return 0;
  //         },
  //
  //         WM_SIZE => {
  //             // low word = new client width, high word = new client height
  //             const w: u32 = @as(u16, @truncate(lparam));
  //             const h: u32 = @as(u16, @truncate(lparam >> 16));
  //             if (w > 0 and h > 0) {
  //                 needs_swapchain_rebuild = true;
  //                 framebuffer_width  = w;
  //                 framebuffer_height = h;
  //             }
  //             return 0;
  //         },
  //
  //         WM_DESTROY => {
  //             PostQuitMessage(0);
  //             return 0;
  //         },
  //
  //         else => return DefWindowProcA(hwnd, msg, wparam, lparam),
  //     }
  // }
  //
  // Getting the current scale factor (useful for sizing UI elements):
  //
  // extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(WINAPI) u32;
  //
  // const dpi = GetDpiForWindow(hwnd);
  // const scale = @as(f32, @floatFromInt(dpi)) / 96.0; // 96 = 100%, 144 = 150%
  //
  // In your render loop, check the flag before submitting a frame:
  //
  // if (needs_swapchain_rebuild) {
  //     needs_swapchain_rebuild = false;
  //     rebuildSwapchain(framebuffer_width, framebuffer_height);
  // }
  //
  // The reason you don't act on WM_SIZE directly is that multiple resize messages can fire rapidly (e.g. during a drag). Deferring to the
  // render loop means you rebuild the swapchain exactly once per stable frame rather than thrashing it mid-drag.

>>>>>>> 5a51e6a93440a4cfaf585dc5d48bf42657819599
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
    { // Compile Shaders
      const in_shader_dir_path = "src\\Shaders";
      const out_shader_dir_path = "Shaders";
        var dir = b.build_root.handle.openDir(b.graph.io, shader_dir_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            return;
        };
        defer dir.close(b.graph.io);
        var walker = try dir.walk(b.allocator);
        var shader_dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bin_path = "Vulkan\\Bin\\glslc.exe";
        while (try walker.next(b.graph.io)) |entry| {
            switch (entry.kind) {
                .file => {},
                else => continue,
            }
            const src = entry.basename;
            if (!isShader(src)) continue;
            std.debug.print("{s}\n", .{src});
            // get out file
            const dst = createOutputShaderPath(&shader_dst_buf, src);
            std.debug.print("{s}\n", .{dst});
const install = systemCommand(
    b,
    bin_path,
    shader_dir_path,


    out_dir: []const u8,
    out: []const u8,
)
            b.getInstallStep().dependOn(&install.step);
        }
    }
    { // Add Custom Dirs
        const sub_paths = [_][]const u8{ "src\\Shaders", "src\\Textures" };
        for (sub_paths) |sub_path| {
            b.installDirectory(.{
                .source_dir = b.path(sub_path),
                .install_dir = .bin,
                .install_subdir = "",
            });
        }
    }
    // Install
    b.installArtifact(exe);
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

fn createOutputShaderPath(buf: []u8, shader_src: []const u8) []u8 {
    @memcpy(buf[0..shader_src.len], shader_src);
    const ext = ".spv";
    @memcpy(buf[shader_src.len .. shader_src.len + ext.len], ext);
    const shader_dst = buf[0 .. shader_src.len + ext.len];
    return shader_dst;
}

fn systemCommand(
    b: *std.Build,
    bin_path: []const u8,
    src_dir: []const u8,
    src: []const u8,
    out_dir: []const u8,
    out: []const u8,
) *std.Build.Step.InstallFile {
    const compile = b.addSystemCommand(&.{bin_path});
    compile.addFileArg(b.pathJoin(&.{ src_dir, src }));
    compile.addArg("-o");
    const spv = compile.addOutputFileArg(out);
    return b.addInstallFileWithDir(spv, .bin, b.pathJoin(&.{ out_dir, out }));
}

// fn compileShader(
//     b: *std.Build,
//     io: std.Io,
//     shader_dir: []const u8,
//     filename: []const u8,
// ) !void {
// const glslc = b.pathFromRoot("Vulkan/Bin/glslc.exe");
// const in_file = b.pathFromRoot(b.pathJoin(&.{ shader_dir, filename }));
// // get out file
// var new_filename_buf: [std.fs.max_path_bytes]u8 = undefined;
// @memcpy(new_filename_buf[0..in_file.len], in_file);
// const ext = ".spv";
// @memcpy(new_filename_buf[in_file.len .. in_file.len + ext.len], ext);
// const out_file = new_filename_buf[0 .. in_file.len + ext.len];
// // start child process
// var child = try std.process.spawn(io, .{
//     .argv = &.{ glslc, in_file, "-o", out_file },
//     .create_no_window = true,
// });
// const term = try child.wait(io);
// outer: while (true) {
//     switch (term) {
//         .exited => break :outer,
//         else => {},
//     }
// }
// }

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
