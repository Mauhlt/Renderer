const std = @import("std");

pub fn build(b: *std.Build) !void {
    // set cwd
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module "Font" (src/Font/root.zig): TrueType parser, rasteriser, cell
    // width table, system font set and glyph atlas. Only std, no Vulkan or
    // OS bindings, so it also builds for wasm32-freestanding; packages that
    // only need text (a browser client, a terminal emulator's width table)
    // import it on its own and never compile the Vulkan bindings.
    const font_mod = b.addModule("Font", .{
        .root_source_file = b.path("src/Font/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const font_tests = b.addTest(.{ .root_module = font_mod });
    const font_step = b.step("test-font", "Test the Font module and compile it for wasm32-freestanding");
    font_step.dependOn(&b.addRunArtifact(font_tests).step);
    const font_wasm = b.addObject(.{
        .name = "font-wasm-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Font/wasm_check.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    font_step.dependOn(&font_wasm.step);

    // Reusable library module "Renderer" (src/root.zig): Instanced2D plus
    // re-exports of the Vulkan bindings and the Font module. Needs only the Vulkan package, works
    // for any target, and uses shaders written in Zig (src/Shaders/*.zig)
    // compiled to SPIR-V by the Zig compiler, so no glslc is required.
    const vulkan_lib = b.dependency("Vulkan", .{ .target = target, .optimize = optimize }).module("Vulkan");
    const lib_mod = b.addModule("Renderer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Vulkan", .module = vulkan_lib },
            .{ .name = "Font", .module = font_mod },
        },
    });
    addZigShader(b, lib_mod, "instanced2d_vert.spv", "src/Shaders/instanced2d_vert.zig");
    addZigShader(b, lib_mod, "instanced2d_frag.spv", "src/Shaders/instanced2d_frag.zig");
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const lib_step = b.step("test-lib", "Test the Renderer library module (and the Font module)");
    lib_step.dependOn(&b.addRunArtifact(lib_tests).step);
    lib_step.dependOn(font_step);

    // Module "Window" (src/Window/root.zig): a native window for Instanced2D
    // with one interface everywhere. Win32 on ../Windows, Wayland on
    // ../Wayland, macOS on ../MacOS; only the target OS's bindings are
    // imported (the Wayland and MacOS packages link libc for dlopen, which a
    // Windows program must not pick up).
    const window_mod = b.addModule("Window", .{
        .root_source_file = b.path("src/Window/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // "IosObjC": the iOS backend's runtime layer on its own (the Window
    // module imports this same instance, so an app may use both). Only
    // compiled when an iOS build imports it.
    const ios_objc_mod = b.addModule("IosObjC", .{
        .root_source_file = b.path("src/Window/ios_objc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .ios) ios_objc_mod.addImport("MacOS", b.dependency("MacOS", .{ .target = target, .optimize = optimize }).module("MacOS"));
    addWindowImports(b, window_mod, target, optimize, lib_mod, ios_objc_mod);
    const window_tests = b.addTest(.{ .root_module = window_mod });
    const window_step = b.step("test-window", "Test the Window module and compile it for Windows, Linux (Wayland) and macOS");
    window_step.dependOn(&b.addRunArtifact(window_tests).step);
    lib_step.dependOn(window_step);
    // Compile-only checks: the Window module (every backend method, see
    // checkInterface) for each supported OS, whatever the host is.
    const check_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };
    const cross_step = b.step("check-window", "Compile the Window module for x86_64-windows, x86_64-linux-gnu, aarch64-macos and aarch64-ios (and the Font module for aarch64-ios)");
    for (check_targets) |q| {
        const t = b.resolveTargetQuery(q);
        const check = b.addTest(.{
            .name = b.fmt("window-check-{t}", .{q.os_tag.?}),
            .root_module = windowCheckModule(b, t),
        });
        cross_step.dependOn(&check.step);
    }
    // iOS: an object only. Linking needs the iOS SDK (libSystem, libobjc,
    // UIKit), which only a Mac has; the externs in ios.zig / ios_objc.zig
    // resolve there (see CHANGES-ios.md). Compiling still analyses every
    // backend method (checkInterface) and the iOS extras.
    const ios_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .ios });
    const ios_check = b.addObject(.{
        .name = "window-check-ios",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Window/ios_check.zig"),
            .target = ios_target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{.{ .name = "Window", .module = windowCheckModule(b, ios_target) }},
        }),
    });
    cross_step.dependOn(&ios_check.step);
    // The Font module's iOS path (CoreText font lookup) as an object too.
    const font_ios_check = b.addObject(.{
        .name = "font-check-ios",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Font/ios_check.zig"),
            .target = ios_target,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    cross_step.dependOn(&font_ios_check.step);
    window_step.dependOn(cross_step);
    // Runtime check on this machine (opens a window for ~2 s): surface,
    // present, wake from a thread, timed wait, clipboard, title.
    const smoke = b.addExecutable(.{ .name = "window-smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("src/Window/smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Window", .module = window_mod },
            .{ .name = "Renderer", .module = lib_mod },
        },
    }) });
    b.step("window-smoke", "Open a Window here and check present, wake, timed wait and clipboard at runtime").dependOn(&b.addRunArtifact(smoke).step);

    // `zig build test`: every module's tests and the compile-only checks
    // (test-lib covers test-font and test-window). `zig build` compiles the
    // same without running anything, so a plain build still checks the code.
    b.step("test", "Run all tests (test-lib: the Renderer, Font and Window modules) and the compile checks").dependOn(lib_step);
    b.getInstallStep().dependOn(&lib_tests.step);
    b.getInstallStep().dependOn(&font_tests.step);
    b.getInstallStep().dependOn(&window_tests.step);
    b.getInstallStep().dependOn(cross_step);
    b.getInstallStep().dependOn(&font_wasm.step);
    b.getInstallStep().dependOn(&smoke.step);
}

/// Compiles a Zig shader to SPIR-V with the self-hosted backend and makes the
/// binary available to `mod` as `@embedFile(name)`.
fn addZigShader(b: *std.Build, mod: *std.Build.Module, name: []const u8, src: []const u8) void {
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .spirv32, .os_tag = .vulkan, .ofmt = .spirv }),
            .optimize = .ReleaseFast,
        }),
        .use_llvm = false,
    });
    mod.addAnonymousImport(name, .{ .root_source_file = obj.getEmittedBin() });
}

/// Imports for module "Window": "Renderer" (for Instanced2D.SurfaceSource)
/// and the target OS's bindings package.
fn addWindowImports(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    renderer: *std.Build.Module,
    ios_objc: ?*std.Build.Module,
) void {
    mod.addImport("Renderer", renderer);
    switch (target.result.os.tag) {
        .windows => mod.addImport("Windows", b.dependency("Windows", .{ .target = target, .optimize = optimize }).module("Windows")),
        // iOS reuses the Objective-C runtime types from ../MacOS (ios_objc.zig).
        .macos => mod.addImport("MacOS", b.dependency("MacOS", .{ .target = target, .optimize = optimize }).module("MacOS")),
        .ios => mod.addImport("IosObjC", ios_objc orelse iosObjcModule(b, target, optimize)),
        else => mod.addImport("Wayland", b.dependency("Wayland", .{ .target = target, .optimize = optimize }).module("Wayland")),
    }
    // dlopen (Wayland, Vulkan loader, Objective-C runtime) needs libc off Windows.
    if (target.result.os.tag != .windows) mod.link_libc = true;
}

/// Module "IosObjC" (src/Window/ios_objc.zig): the iOS backend's
/// Objective-C runtime layer (libobjc externs, msgSend, runtime classes,
/// global blocks, main-queue dispatch) on ../MacOS's types. Exposed on its
/// own for iOS code that needs no window (an app extension).
fn iosObjcModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/Window/ios_objc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "MacOS", .module = b.dependency("MacOS", .{ .target = target, .optimize = optimize }).module("MacOS") }},
    });
}

/// A Renderer + Window module pair for `t`, for compile-only checks.
fn windowCheckModule(b: *std.Build, t: std.Build.ResolvedTarget) *std.Build.Module {
    const vulkan = b.dependency("Vulkan", .{ .target = t, .optimize = .Debug }).module("Vulkan");
    const font = b.createModule(.{ .root_source_file = b.path("src/Font/root.zig"), .target = t, .optimize = .Debug });
    const renderer = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = t,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "Vulkan", .module = vulkan },
            .{ .name = "Font", .module = font },
        },
    });
    addZigShader(b, renderer, "instanced2d_vert.spv", "src/Shaders/instanced2d_vert.zig");
    addZigShader(b, renderer, "instanced2d_frag.spv", "src/Shaders/instanced2d_frag.zig");
    const window = b.createModule(.{ .root_source_file = b.path("src/Window/root.zig"), .target = t, .optimize = .Debug });
    addWindowImports(b, window, t, .Debug, renderer, null);
    return window;
}
