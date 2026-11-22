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
    // A font an app may ship (DejaVu Sans Mono 2.37, unmodified), and its
    // licence, which must ship with it (THIRD_PARTY.md):
    // `dep.namedLazyPath("dejavu_sans_mono")` and `"dejavu_sans_mono_licence"`.
    b.addNamedLazyPath("dejavu_sans_mono", b.path("src/Font/fonts/dejavu/DejaVuSansMono.ttf"));
    b.addNamedLazyPath("dejavu_sans_mono_licence", b.path("src/Font/fonts/dejavu/LICENSE.txt"));
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

    // Module "Raster" (src/Raster/root.zig): 2D drawing on the CPU into a
    // caller-owned RGBA8 buffer (rectangles, glyph coverage masks, scaled
    // images), for targets with no GPU path such as a browser
    // (wasm32-freestanding). Only std; text comes from the Font module's
    // glyph cache (Font.glyphcache), which the app passes to Raster.mask.
    const raster_mod = b.addModule("Raster", .{
        .root_source_file = b.path("src/Raster/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const raster_step = b.step("test-raster", "Test the Raster module (also with Font: text from the glyph cache) and run wasm-check");
    raster_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = raster_mod })).step);
    const raster_text_tests = b.addTest(.{ .name = "raster-text", .root_module = b.createModule(.{
        .root_source_file = b.path("src/Raster/text_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "Raster", .module = raster_mod }, .{ .name = "Font", .module = font_mod } },
    }) });
    raster_step.dependOn(&b.addRunArtifact(raster_text_tests).step);
    // Compile-only: the browser's path (Raster + Font from memory + glyph
    // cache) for wasm32-freestanding, with and without SIMD128.
    const wasm_step = b.step("wasm-check", "Compile Raster and Font for wasm32-freestanding (baseline and +simd128)");
    const wasm_targets = [_]std.Target.Query{
        .{ .cpu_arch = .wasm32, .os_tag = .freestanding },
        .{ .cpu_arch = .wasm32, .os_tag = .freestanding, .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}) },
    };
    for (wasm_targets, [_][]const u8{ "", "-simd128" }) |q, suffix| {
        const obj = b.addObject(.{
            .name = b.fmt("raster-wasm-check{s}", .{suffix}),
            .root_module = rasterUser(b, "src/Raster/wasm_check.zig", b.resolveTargetQuery(q), .ReleaseSmall),
        });
        // Asking for the object runs code generation too (SIMD128 lowering).
        _ = obj.getEmittedBin();
        wasm_step.dependOn(&obj.step);
    }
    wasm_step.dependOn(&font_wasm.step);
    raster_step.dependOn(wasm_step);
    // `zig build bench-raster`: frame timings on this machine (ReleaseFast;
    // not run by the tests).
    const raster_bench = b.addExecutable(.{ .name = "raster-bench", .root_module = rasterUser(b, "src/Raster/bench.zig", target, .ReleaseFast) });
    b.step("bench-raster", "Time Raster frames of phone-sized text (1170x2532) in ReleaseFast").dependOn(&b.addRunArtifact(raster_bench).step);

    // Reusable library module "Renderer" (src/root.zig): Instanced2D. Needs
    // only the Vulkan package and works for any target. It ships no
    // shaders: the app passes its own SPIR-V to Instanced2D.init (its
    // "Shader contract"), compiled from Zig with `addShader` below.
    const vulkan_lib = b.dependency("Vulkan", .{ .target = target, .optimize = optimize }).module("Vulkan");
    const lib_mod = b.addModule("Renderer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Vulkan", .module = vulkan_lib }},
    });
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const lib_step = b.step("test-lib", "Test the Renderer library module (and the Font, Raster and Window modules)");
    lib_step.dependOn(&b.addRunArtifact(lib_tests).step);
    // Test shaders (src/testing): only Renderer's own tests and the
    // window-smoke step use them, never the library module.
    const test_shaders = b.createModule(.{
        .root_source_file = b.path("src/testing/shaders.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Renderer", .module = lib_mod }},
    });
    for ([_][]const u8{ "solid_vert", "solid_frag" }) |name| {
        const spv = addShader(b, name, b.path(b.fmt("src/testing/shaders/{s}.zig", .{name})));
        test_shaders.addAnonymousImport(b.fmt("{s}.spv", .{name}), .{ .root_source_file = spv });
    }
    const shader_tests = b.addTest(.{ .root_module = test_shaders });
    lib_step.dependOn(&b.addRunArtifact(shader_tests).step);
    lib_step.dependOn(font_step);
    lib_step.dependOn(raster_step);

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
    addWindowImports(b, window_mod, target, optimize, lib_mod, ios_objc_mod, font_mod);
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
    // resolve there. Compiling still analyses every
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
            .{ .name = "test_shaders", .module = test_shaders },
        },
    }) });
    b.step("window-smoke", "Open a Window here and check present, wake, timed wait and clipboard at runtime").dependOn(&b.addRunArtifact(smoke).step);

    // `zig build test`: every module's tests and the compile-only checks
    // (test-lib covers test-font, test-raster and test-window). `zig build`
    // compiles the same without running anything, so a plain build still
    // checks the code.
    b.step("test", "Run all tests (test-lib: the Renderer, Font, Raster and Window modules) and the compile checks").dependOn(lib_step);
    b.getInstallStep().dependOn(&lib_tests.step);
    b.getInstallStep().dependOn(&shader_tests.step);
    b.getInstallStep().dependOn(&font_tests.step);
    b.getInstallStep().dependOn(&window_tests.step);
    b.getInstallStep().dependOn(cross_step);
    b.getInstallStep().dependOn(&font_wasm.step);
    b.getInstallStep().dependOn(&raster_text_tests.step);
    b.getInstallStep().dependOn(wasm_step);
    b.getInstallStep().dependOn(&raster_bench.step);
    b.getInstallStep().dependOn(&smoke.step);
}

/// A root module (a test, check or tool) importing "Raster" and "Font",
/// both built for `t` and `optimize`.
fn rasterUser(b: *std.Build, root: []const u8, t: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = t,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Raster", .module = b.createModule(.{ .root_source_file = b.path("src/Raster/root.zig"), .target = t, .optimize = optimize }) },
            .{ .name = "Font", .module = b.createModule(.{ .root_source_file = b.path("src/Font/root.zig"), .target = t, .optimize = optimize }) },
        },
    });
}

/// Compiles a shader written in Zig (one entry point `export fn main()`
/// with `callconv(.spirv_vertex)`, `.spirv_fragment` or `.spirv_kernel`;
/// the calling convention sets the stage) to SPIR-V for Vulkan, with the
/// Zig compiler's self-hosted backend: no glslc or Vulkan SDK. Returns the
/// .spv file. For apps, from their build.zig:
///
///     const spv = @import("Renderer").addShader(b, "quad_vert", b.path("src/shaders/quad_vert.zig"));
///     mod.addAnonymousImport("quad_vert.spv", .{ .root_source_file = spv });
///
/// and in the module: `const vert align(4) = @embedFile("quad_vert.spv").*;`,
/// passed to Instanced2D.init as `.vertex_spirv = &vert`.
pub fn addShader(b: *std.Build, name: []const u8, root_source_file: std.Build.LazyPath) std.Build.LazyPath {
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = b.resolveTargetQuery(.{ .cpu_arch = .spirv32, .os_tag = .vulkan, .ofmt = .spirv }),
            .optimize = .ReleaseFast,
        }),
        .use_llvm = false,
    });
    return obj.getEmittedBin();
}

/// Imports for module "Window": "Renderer" (for Instanced2D.SurfaceSource)
/// and the target OS's bindings package; on Linux also "Font" (the title
/// bar the Wayland backend draws where the compositor draws none). `font`
/// is the package's own Font module, so an app that imports both Window
/// and Font compiles one instance of it.
fn addWindowImports(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    renderer: *std.Build.Module,
    ios_objc: ?*std.Build.Module,
    font: *std.Build.Module,
) void {
    mod.addImport("Renderer", renderer);
    switch (target.result.os.tag) {
        .windows => mod.addImport("Windows", b.dependency("Windows", .{ .target = target, .optimize = optimize }).module("Windows")),
        // iOS reuses the Objective-C runtime types from ../MacOS (ios_objc.zig).
        .macos => mod.addImport("MacOS", b.dependency("MacOS", .{ .target = target, .optimize = optimize }).module("MacOS")),
        .ios => mod.addImport("IosObjC", ios_objc orelse iosObjcModule(b, target, optimize)),
        else => {
            mod.addImport("Wayland", b.dependency("Wayland", .{ .target = target, .optimize = optimize }).module("Wayland"));
            mod.addImport("Font", font);
        },
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
    const renderer = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = t,
        .optimize = .Debug,
        .imports = &.{.{ .name = "Vulkan", .module = vulkan }},
    });
    const window = b.createModule(.{ .root_source_file = b.path("src/Window/root.zig"), .target = t, .optimize = .Debug });
    const font = b.createModule(.{ .root_source_file = b.path("src/Font/root.zig"), .target = t, .optimize = .Debug });
    addWindowImports(b, window, t, .Debug, renderer, null, font);
    return window;
}
