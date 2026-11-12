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

* `src/Font/` (module **`Font`**): text, for anything that uses fonts,
  with no Vulkan, window-system or libc dependency (only std), so it builds
  for wasm32-freestanding as well as native targets. Moved here from
  Portal, where two copies lived (the native client's `client/src/view/font`
  and the browser client's `src/wasm/font`) plus two copies of the width
  table (`src/vt_width.zig`, `client/src/view/wcwidth.zig`).
  * `ttf.zig`: TrueType (glyf) parser, .ttc collections. Font files are
    untrusted: bounds-checked reads, overflow-checked offsets, capped
    recursion/points. Fixed while moving: a cmap format-12 group whose
    startGlyphID is near 2^32 overflowed a `u32` add (a panic in safe
    builds); it now maps to .notdef (new test).
  * `raster.zig`: exact-area scanline rasteriser for quadratic outlines.
  * `wcwidth.zig`: terminal cell width (0/1/2) of a code point.
  * `fontset.zig`: system monospace font (+ bold) and lazily loaded
    fallbacks, cell-sized coverage bitmaps, procedural box drawing and
    replacement box. Reads OS font files through `std.Io` (native only; the
    browser client uses `ttf` + `raster` directly with bundled fonts).
  * `atlas.zig`: CPU-side RGBA8 glyph atlas (shelf packer, glyph cache,
    dirty rectangle to upload with `Instanced2D.updateTexture`).
  * `root.zig`: module root. `wasm_check.zig`: compile check for wasm32.
  * `testdata/DejaVuSansMono.ttf` (+ `LICENSE.txt`, `README.md`): the tests'
    font, embedded with `@embedFile`, so they no longer depend on
    `C:\Windows\Fonts\consola.ttf`. (`fontset`/`atlas` tests still use
    system fonts and skip when there are none.)
* `.gitignore`: `zig-pkg/` (the package cache the 0.18 build creates), `.zig-cache/`, `zig-out/`.

## build.zig / build.zig.zon

* New public module **`Renderer`** (`b.addModule("Renderer", ...)`, root
  `src/root.zig`) with the Vulkan package imported, target/optimize passed
  through, and the two Zig shaders compiled by `addZigShader` and embedded
  with `@embedFile`.
* New step `zig build test-lib` (tests the module).
* New public module **`Font`** (`b.addModule("Font", ...)`, root
  `src/Font/root.zig`, no imports). The `Renderer` module also imports it
  and re-exports it as `Renderer.Font`; packages that need only text import
  `Font` directly (Portal's wasm browser client and its server's width
  table do), which never compiles the Vulkan bindings.
* New step `zig build test-font`: Font unit tests plus a wasm32-freestanding
  compile check; `test-lib` now also runs it.
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

* `zig build test-lib -Ddemo=false` passes (incl. `test-font`, 12 tests); the module is compiled for
  x86_64-windows, x86_64-linux-gnu and aarch64-macos by the client's builds.
* Running on Windows (NVIDIA, Vulkan 1.4 loader) through portal-client:
  glyph atlas uploads, thousands of instances per frame, live window resize.
* The demo build was not run in this worktree (it needs `../Image` and
  `Vulkan/Bin/glslc.exe`, which only exist next to the main checkout).
