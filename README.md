# Renderer

A small, generic Vulkan library for 2D and text, written in Zig. It draws
textured, tinted quads; the app supplies its own shaders (as SPIR-V) and
keeps all of its own drawing logic. Nothing here knows about any one app.

## Modules

| Module     | Root                   | What it is |
|------------|------------------------|------------|
| `Renderer` | `src/root.zig`         | `Instanced2D`: one instanced draw call per frame of quads sampling one RGBA8 texture (an atlas). Takes a native surface handle (Win32, Wayland, Metal through MoltenVK). Needs only the Vulkan package. |
| `Font`     | `src/Font/root.zig`    | TrueType parser, exact-area rasteriser, terminal cell widths, system font set and a CPU glyph atlas. Only std: also builds for wasm32-freestanding. |
| `Window`   | `src/Window/root.zig`  | A native window with one event-driven interface: Win32, Wayland (no X11), macOS AppKit and iOS UIKit. Only the target OS's bindings are imported. |
| `IosObjC`  | `src/Window/ios_objc.zig` | The iOS backend's Objective-C runtime layer on its own, for iOS code without a window (an app extension). |

There are no 3D, model or scene features, and the library ships no shaders.

## Shaders

The app passes its vertex and fragment SPIR-V to `Instanced2D.init`; the
pipeline they must match is the "Shader contract" at the top of
`src/Instanced2D.zig`. `build.zig` exports `addShader`, which compiles a
shader written in Zig to SPIR-V with the Zig compiler (no glslc or Vulkan
SDK):

```zig
// the app's build.zig
const spv = @import("Renderer").addShader(b, "quad_vert", b.path("src/shaders/quad_vert.zig"));
mod.addAnonymousImport("quad_vert.spv", .{ .root_source_file = spv });
```

```zig
// the app
const vert align(4) = @embedFile("quad_vert.spv").*;
const r = try Instanced2D.init(gpa, win.surfaceSource(), fb[0], fb[1], .{
    .vertex_spirv = &vert,
    .fragment_spirv = &frag,
});
```

## Using it

Add it as a URL package pinned to a commit
(`zig fetch --save "git+https://github.com/Mauhlt/Renderer#<commit>"`), then
import the modules you need:

```zig
const renderer = b.dependency("Renderer", .{ .target = target, .optimize = optimize });
mod.addImport("Renderer", renderer.module("Renderer"));
mod.addImport("Window", renderer.module("Window"));
mod.addImport("Font", renderer.module("Font"));
```

Its own dependencies (Vulkan, Windows, Wayland, MacOS) are URL packages too.
To build against local checkouts, use `zig build --fork=<path>`.

## Build steps

- `zig build test`: every module's tests plus compile checks of the Window
  module for x86_64-windows, x86_64-linux-gnu, aarch64-macos and aarch64-ios
  and of the Font module for wasm32-freestanding and aarch64-ios.
- `zig build window-smoke`: opens a window on this machine for about two
  seconds and checks present, wake, timed wait and the clipboard.

## Licence

MIT, see `LICENSE`. Third-party material (the DejaVu test font) keeps its
own licence, see `THIRD_PARTY.md`.
