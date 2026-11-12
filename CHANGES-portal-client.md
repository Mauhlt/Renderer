# Changes on branch `portal-client`

For the owner's review. Purpose: let Portal's native client (and later
Portal's own GUI terminal) draw with this Renderer, as a reusable module,
without changing how the existing demo works.

## New files

* `src/Instanced2D.zig`: a small reusable 2D renderer. Draws a list of
  textured, tinted quads in one instanced draw call per frame, sampling one
  RGBA8 texture (an atlas).
  * `init(gpa, surface_source, width, height, options) !*Instanced2D`.
    `SurfaceSource` is a union of native handles (`win32`, `xlib`, `xcb`,
    `metal`), so the file has no window code and works with any platform
    layer. Picks instance extensions per surface type; opts into
    `VK_KHR_portability_enumeration` / `VK_KHR_portability_subset` when
    present (MoltenVK).
  * `resize(w, h)`, `framebufferSize()`, `updateTexture(x, y, w, h, rgba)`
    (staging upload + layout barriers, synchronous), `drawFrame(clear,
    instances)`. Instance rects are in framebuffer pixels; converted to NDC on
    the CPU, so the shaders need no uniforms or push constants.
  * Swapchain: prefers a UNORM format (colours are passed through as given),
    FIFO present mode, recreated on resize/`OutOfDateKHR`/`SuboptimalKHR`,
    skipped while minimised. Two frames in flight; per-frame host-visible
    instance buffers that grow on demand; one render-finished semaphore per
    swapchain image. Every Vulkan error becomes a Zig error (no `unreachable`).
* `src/Shaders/instanced2d_vert.zig`, `src/Shaders/instanced2d_frag.zig`:
  the shaders, written in Zig and compiled to SPIR-V by the Zig compiler
  (`spirv32-vulkan`, self-hosted backend). No glslc needed. They end in
  `.zig`, so the existing GLSL shader loop in build.zig ignores them.
* `src/root.zig` (was empty): module root, exports `Instanced2D` and `vk`.

## build.zig / build.zig.zon

* New public module **`Renderer`** (`b.addModule("Renderer", ...)`, root
  `src/root.zig`) with the Vulkan package imported, target/optimize passed
  through, and the two Zig shaders compiled by `addZigShader` and embedded
  with `@embedFile`.
* New step `zig build test-lib` (tests the module).
* New option `-Ddemo=<bool>` (default **true**, i.e. unchanged behaviour).
  Packages that only want the library pass `.demo = false` so the demo's
  dependencies (Image, Windows, glslc in `Vulkan/Bin`) are never needed.
* The "Unsupported OS" check now applies to the demo only (it logs and skips
  the demo instead of hitting `unreachable` for non-Windows targets), so the
  library cross-compiles for Linux and macOS.
* `Image` is now a lazy dependency (`.lazy = true`), fetched with
  `b.lazyDependency` only when the demo is built. The demo itself
  (`Renderer2D.run`, `src/main.zig`, the GLSL shader compile and texture
  install) is unchanged.

## Not changed

`Renderer2D.zig`, `os/Windows.zig`, `Modern/Renderer.zig`, the GLSL shaders
and all other existing files are untouched.

## Verified

* `zig build test-lib -Ddemo=false` passes; the module is compiled for
  x86_64-windows, x86_64-linux-gnu and aarch64-macos by the client's builds.
* Running on Windows (NVIDIA, Vulkan 1.4 loader) through portal-client:
  glyph atlas uploads, thousands of instances per frame, live window resize.
* The demo build was not run in this worktree (it needs `../Image` and
  `Vulkan/Bin/glslc.exe`, which only exist next to the main checkout).
