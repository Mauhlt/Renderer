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

## Module `Window` (src/Window): native windows on Win32, Wayland and macOS

Owner decision: Portal has no window code of its own; windowing lives here,
on the owner's binding repos. Chain: Portal -> Renderer (`Window` +
`Instanced2D`) -> Vulkan + Windows / Wayland / MacOS.

* `src/Window/root.zig` (public module **`Window`**): the interface, the
  shared event types (`Event`, `Key`, `Mods`, `MouseButton`), the `Queue`
  (never drops `.close`), `LiveFn`, `forever`, `SurfaceSource` (=
  `Instanced2D.SurfaceSource`), and helpers (`sanitizeClipboard`,
  `titleZ`). `Window.Window` is the platform's backend. API:

  | call | meaning |
  |------|---------|
  | `init(gpa, title, w, h) !*Window` | logical size, scaled by DPI |
  | `deinit()` | |
  | `setLiveCallback(ctx, fn)` | redraw hook while the OS runs a modal resize loop (Win32 border drag, macOS live resize) |
  | `pollEvent() ?Event` | non-blocking, pumps the OS queue |
  | `pollQueued() ?Event` | queued events only (safe inside the live callback) |
  | `waitEvents(timeout_ms)` | blocks until input, `wake()` or the timeout; `forever` = none |
  | `wake()` | any thread, coalesced |
  | `framebufferSize() [2]u32`, `scale() f32` | pixels; 1.0 = 96 dpi / 1x |
  | `surfaceSource()` | for `Instanced2D.init` |
  | `setTitle(utf8)`, `hide()` | |
  | `clipboardText(gpa, max_units) ?[]u8`, `setClipboardText(utf8) bool` | UTF-8; at most `max_units` UTF-16 units; invalid -> U+FFFD |

  Events: `close`, `resize` (px), `scale`, `expose`, `key` (named keys +
  mods), `char` (text; Ctrl+letter = lowercase letter with `mods.ctrl`,
  Alt+char with `mods.alt`), `mouse_down` (left/right/middle + mods),
  `mouse_move` (left drags only), `mouse_up` (left), `scroll` (new: notches,
  `dy` > 0 = away from the user), `zoom` (Ctrl + = / - / 0). Same semantics
  as Portal's former platform layer.
* `checkInterface(W)` runs at compile time for the selected backend: every
  method must exist with the exact signature, and taking each method's
  address makes the compiler analyse its body, so a cross-compile
  type-checks the whole backend.
* Event driven everywhere; the only fixed-rate timer is Win32's 16 ms
  `SetTimer` during a modal resize drag (as Portal had before).
* `win32.zig`: Portal's `client/src/view/platform/win32.zig` moved here
  onto `../Windows` (`USER`, `KERNEL`, `TYPES`, `ENUMS`, `STRUCTS`); its
  hand-declared user32 externs are gone. New: `WM_MOUSEWHEEL` /
  `WM_MOUSEHWHEEL` -> `scroll`, `hide()`. DPI functions through
  `USER.load` (runtime-resolved).
* `wayland.zig` (Linux only; no X11): xdg-shell toplevel, xdg-decoration
  (server side when offered), wl_seat keyboard via xkbcommon (keymap fd,
  modifiers, repeat from `repeat_info` on a **timerfd** in the same poll),
  wl_pointer (buttons, drags, value120 / discrete / continuous scroll),
  scale from `wl_surface.preferred_buffer_scale` (v6) or the entered
  outputs' `wl_output.scale` (`set_buffer_scale`), clipboard through
  wl_data_device (pipe + 2 s deadline; our own selection is answered
  locally), wake via an **eventfd**; one `poll` with libwayland's
  prepare_read / read_events protocol. A lost compositor turns into one
  `.close`.
* `wl_data.zig`: **local shim** for wl_data_device_manager / device /
  source / offer v3 (see "Missing in the binding repos").
* `cocoa.zig` (macOS): NSApplication + NSWindow, a CAMetalLayer content view
  (`View.useMetalLayer`), a real NSWindowDelegate subclass
  (`RendererWindowDelegate`, objc_allocateClassPair through
  `OBJC.ClassBuilder`) for close / resize / backing scale, live-resize
  redraw from `windowDidResize:` while `inLiveResize`; waits in
  `nextEventMatchingMask:untilDate:` (distantFuture for `forever`); `wake()`
  posts an application-defined NSEvent (`postEvent:atStart:`), coalesced by
  an atomic flag; NSPasteboard clipboard. arm64 and x86_64 (the binding's
  `msgSend` handles `_stret`). Replaces Portal's polling cocoa backend (it
  slept at most 50 ms at a time and had no wake).
* `smoke.zig`: `zig build window-smoke` opens a window on the host and
  checks present, wake from a thread, timed waits, clipboard round trip and
  title at runtime (run it on Linux / macOS to test those backends).

### Instanced2D

* `SurfaceSource` gained **`wayland`** (`VK_KHR_wayland_surface`,
  `vk.createWaylandSurfaceKHR`). **`xlib` and `xcb` were removed**: nothing
  uses them any more (Portal's X11 backend is gone; X11 is not supported).

### build.zig / build.zig.zon

* New dependencies `Wayland` (`../Wayland`) and `MacOS` (`../MacOS`), path
  deps like `Windows`.
* New public module `Window` (imports `Renderer` and only the target OS's
  bindings: `Windows`, `Wayland` or `MacOS`; libc is linked off Windows for
  dlopen, never on Windows).
* `zig build test-window`: Window unit tests (native) plus `check-window`.
  `test-lib` now includes it.
* `zig build check-window`: compile-only check of the Window module (all
  backend methods) for x86_64-windows, x86_64-linux-gnu, aarch64-macos.
* `zig build window-smoke`: the runtime smoke test above.
* Existing modules, steps and options are unchanged. (The demo build,
  `zig build` / `zig build test` with `-Ddemo=true`, still needs
  `Vulkan/Bin/glslc.exe` and `Vulkan/Lib`, which this worktree lacks; it
  failed the same way before these changes.)

### Missing in the binding repos (not modified; for the owner)

* **../Windows** `KERNEL`: `GlobalAlloc`, `GlobalLock`, `GlobalUnlock`,
  `GlobalFree`, `GlobalSize` and `GMEM_MOVEABLE` (clipboard memory).
  Declared locally at the top of `src/Window/win32.zig`. No named
  `MWMO_INPUTAVAILABLE` constant either (local const).
* **../Wayland**: no `wl_data_device_manager`, `wl_data_device`,
  `wl_data_source`, `wl_data_offer` (clipboard). Shimmed in
  `src/Window/wl_data.zig`, written like the package's protocol files on
  its public `CLIENT` helpers so it can move there unchanged. Also absent:
  `wp_fractional_scale_v1` / `wp_viewporter` (fractional scaling) and a
  cursor (wl_cursor / cursor-shape-v1), so the window shows whatever cursor
  the compositor last set; `XKB.Keysym` lacks keypad names (raw keysym
  values are used).
* **../MacOS**: `OBJC.msgSend` stops at 8 arguments, but
  `+[NSEvent otherEventWithType:...data2:]` needs 9 (`cocoa.zig` `wake`
  casts `objc_msgSend` itself); no `postEvent:atStart:` wrapper; no
  `subtype` / `data1` event accessors; `Application.nextEvent` has no
  timeout (only wait / no wait), so `cocoa.zig` sends
  `nextEventMatchingMask:untilDate:inMode:dequeue:` itself; no
  `NSPasteboard` wrapper; no `NSString initWithBytes:length:encoding:`; no
  `NSWindow inLiveResize`; `WindowEvents` / `windowDelegate` is flags-only
  (no callback, so live-resize redraw needs its own delegate class, which
  `cocoa.zig` registers).

### Status

* Win32: runtime-tested (window-smoke; Portal's unit tests and e2e).
* Wayland and macOS: compile-checked only (cross-compiled from Windows),
  never run. Untested at runtime: all of it, i.e. mapping/configure, Vulkan
  surface creation (Wayland surface; MoltenVK), xkb keymaps and repeat,
  scale changes, clipboard pipes / NSPasteboard, the wake paths, macOS
  live resize. `zig build window-smoke` on each OS is the first check.
