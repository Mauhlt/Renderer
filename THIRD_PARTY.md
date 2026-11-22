# Third-party material

Renderer's own code is under the MIT licence in `LICENSE`. The material
below is not, and keeps its own terms; it is not relicensed.

## DejaVu Sans Mono

- File: `src/Font/fonts/dejavu/DejaVuSansMono.ttf`, the unmodified
  `ttf/DejaVuSansMono.ttf` from the DejaVu Fonts 2.37 release (sha256 in
  `src/Font/fonts/dejavu/README.md`).
- Used by the Font module's unit tests (`@embedFile`), and published for
  apps to ship as the named lazy path `dejavu_sans_mono` (Portal's browser
  client embeds it). Its licence is published beside it as
  `dejavu_sans_mono_licence`; an app that ships the font ships that too.
- Licence: the Bitstream Vera Fonts licence (Copyright (c) 2003 Bitstream,
  Inc.) and the Arev Fonts licence (Copyright (c) 2006 Tavmjong Bah) for the
  glyphs imported from Arev; DejaVu's own changes are public domain. The full
  text is `src/Font/fonts/dejavu/LICENSE.txt`, which must stay next to the font
  (it ships in the package, since `src` is in `build.zig.zon`'s paths).

## Dependencies (fetched, not vendored)

Pinned in `build.zig.zon`, each with its own licence and notices in its own
repository: Vulkan (bindings generated from the Khronos Vulkan registry),
Windows, Wayland, MacOS.

## References, no copied code

- `src/Font/raster.zig` implements exact-area scanline coverage, the
  technique described for font-rs and stb_truetype v2. It is written for
  this repository; no source from either project is included.
- `src/Font/wcwidth.zig` holds its own range tables for cell widths, chosen
  from the Unicode East Asian Width and general-category properties. No
  Unicode data file is included.
