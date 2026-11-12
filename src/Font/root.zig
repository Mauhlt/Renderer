//! Public module "Font" (see build.zig): text for anything that draws a
//! terminal or other monospace text, independent of how it is drawn.
//!
//! Depends on nothing but std: no Vulkan, no window system, no libc. It
//! compiles for wasm32-freestanding as well as native targets, so a
//! browser client can use the same parser, rasteriser and width table as
//! a native window and as the terminal emulator that produces the grid.
//!
//!   ttf       TrueType (glyf) parser and .ttc collections; untrusted input
//!   raster    exact-area scanline rasteriser for glyph outlines
//!   wcwidth   terminal cell width of a code point (0, 1 or 2)
//!   fontset   system monospace font + fallbacks, cell-sized glyph bitmaps,
//!             procedural box drawing (reads OS font files through std.Io;
//!             native only)
//!   atlas     CPU-side RGBA8 glyph atlas with a shelf packer and a dirty
//!             rectangle to upload (e.g. to Instanced2D's texture)

pub const ttf = @import("ttf.zig");
pub const raster = @import("raster.zig");
pub const wcwidth = @import("wcwidth.zig");
pub const fontset = @import("fontset.zig");
pub const atlas = @import("atlas.zig");

test {
    _ = ttf;
    _ = raster;
    _ = wcwidth;
    _ = fontset;
    _ = atlas;
}
