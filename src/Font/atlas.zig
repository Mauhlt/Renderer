//! Glyph atlas: a CPU-side RGBA8 image with a shelf packer and a cache from
//! (code point, size, style, cell count) to atlas slot. Newly rasterised
//! glyphs extend a dirty rectangle that the caller uploads once per frame.
//! Texel (0,0)-(1,1) is opaque white, for solid fills.

const std = @import("std");
const fontset = @import("fontset.zig");

pub const Slot = struct { x: u16, y: u16, w: u16, h: u16 };

const Shelf = struct { y: u32, h: u32, x: u32 };

pub const Atlas = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,
    map: std.AutoHashMapUnmanaged(u64, Slot) = .empty,
    shelves: std.ArrayList(Shelf) = .empty,
    next_y: u32 = 0,
    dirty: ?[4]u32 = null, // x0, y0, x1, y1
    scratch: []u8 = &.{},
    /// Incremented when the atlas is wiped (all slots invalid).
    epoch: u32 = 0,
    /// Height of the GPU texture the atlas lives in, for UVs. The texture
    /// may be taller than the atlas (TermView keeps inline images below it).
    tex_h: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Atlas {
        const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
        var a: Atlas = .{ .gpa = gpa, .width = width, .height = height, .pixels = pixels };
        a.wipe();
        return a;
    }

    pub fn deinit(a: *Atlas) void {
        a.gpa.free(a.pixels);
        a.gpa.free(a.scratch);
        a.map.deinit(a.gpa);
        a.shelves.deinit(a.gpa);
    }

    /// Clears every glyph (e.g. after a font size change or when full).
    pub fn wipe(a: *Atlas) void {
        @memset(a.pixels, 0);
        a.map.clearRetainingCapacity();
        a.shelves.clearRetainingCapacity();
        // 2x2 white block at the origin.
        for ([_]usize{ 0, 1 }) |y| for ([_]usize{ 0, 1 }) |x| {
            @memset(a.pixels[(y * a.width + x) * 4 ..][0..4], 255);
        };
        a.next_y = 2;
        a.dirty = .{ 0, 0, a.width, a.height };
        a.epoch +%= 1;
    }

    pub fn whiteUv(a: *const Atlas) [4]f32 {
        const u = 1.0 / @as(f32, @floatFromInt(a.width));
        const v = 1.0 / @as(f32, @floatFromInt(a.texHeight()));
        return .{ u * 0.5, v * 0.5, u * 1.5, v * 1.5 };
    }

    pub fn texHeight(a: *const Atlas) u32 {
        return @max(a.tex_h, a.height);
    }

    pub fn uv(a: *const Atlas, s: Slot) [4]f32 {
        const fw: f32 = @floatFromInt(a.width);
        const fh: f32 = @floatFromInt(a.texHeight());
        return .{
            @as(f32, @floatFromInt(s.x)) / fw,
            @as(f32, @floatFromInt(s.y)) / fh,
            @as(f32, @floatFromInt(@as(u32, s.x) + s.w)) / fw,
            @as(f32, @floatFromInt(@as(u32, s.y) + s.h)) / fh,
        };
    }

    fn alloc(a: *Atlas, w: u32, h: u32) ?Slot {
        if (w + 1 > a.width or h + 1 > a.height) return null;
        for (a.shelves.items) |*s| {
            if (s.h == h and s.x + w + 1 <= a.width) {
                const slot: Slot = .{ .x = @intCast(s.x), .y = @intCast(s.y), .w = @intCast(w), .h = @intCast(h) };
                s.x += w + 1;
                return slot;
            }
        }
        if (a.next_y + h + 1 > a.height) return null;
        a.shelves.append(a.gpa, .{ .y = a.next_y, .h = h, .x = w + 1 }) catch return null;
        const slot: Slot = .{ .x = 0, .y = @intCast(a.next_y), .w = @intCast(w), .h = @intCast(h) };
        a.next_y += h + 1;
        return slot;
    }

    /// Returns the slot for a glyph, rasterising it on first use. Null if the
    /// atlas is full (the caller should wipe and redraw next frame).
    pub fn get(a: *Atlas, fonts: *fontset.FontSet, cp: u21, style: fontset.Style, m: fontset.Metrics, cells: u32) ?Slot {
        const k = fontset.glyphKey(cp, m.em, style, cells);
        if (a.map.get(k)) |s| return s;
        const w = m.cell_w * cells;
        const h = m.cell_h;
        const slot = a.alloc(w, h) orelse return null;
        const n = @as(usize, w) * h;
        if (a.scratch.len < n) {
            a.gpa.free(a.scratch);
            a.scratch = a.gpa.alloc(u8, n) catch {
                a.scratch = &.{};
                return null;
            };
        }
        const cov = a.scratch[0..n];
        fonts.render(cp, style, m, cells, cov);
        for (0..h) |y| {
            const dst = a.pixels[((slot.y + y) * a.width + slot.x) * 4 ..][0 .. w * 4];
            for (0..w) |x| {
                dst[x * 4 + 0] = 255;
                dst[x * 4 + 1] = 255;
                dst[x * 4 + 2] = 255;
                dst[x * 4 + 3] = cov[y * w + x];
            }
        }
        a.map.put(a.gpa, k, slot) catch return null;
        a.markDirty(slot);
        return slot;
    }

    fn markDirty(a: *Atlas, s: Slot) void {
        const r = [4]u32{ s.x, s.y, @as(u32, s.x) + s.w, @as(u32, s.y) + s.h };
        if (a.dirty) |*d| {
            d[0] = @min(d[0], r[0]);
            d[1] = @min(d[1], r[1]);
            d[2] = @max(d[2], r[2]);
            d[3] = @max(d[3], r[3]);
        } else a.dirty = r;
    }

    /// Copies the dirty rows' region out as tightly packed RGBA (full width
    /// rows, simplest correct upload), returning x, y, w, h and the bytes.
    pub fn takeDirty(a: *Atlas) ?struct { x: u32, y: u32, w: u32, h: u32, bytes: []const u8 } {
        const d = a.dirty orelse return null;
        a.dirty = null;
        // Full-width rows are contiguous in `pixels`, so no repacking needed.
        return .{
            .x = 0,
            .y = d[1],
            .w = a.width,
            .h = d[3] - d[1],
            .bytes = a.pixels[@as(usize, d[1]) * a.width * 4 .. @as(usize, d[3]) * a.width * 4],
        };
    }
};

test "atlas packs and caches" {
    const gpa = std.testing.allocator;
    var fs = fontset.FontSet.load(gpa, std.testing.io) catch return error.SkipZigTest;
    defer fs.deinit();
    var a = try Atlas.init(gpa, 256, 256);
    defer a.deinit();
    _ = a.takeDirty();
    const m = fs.metrics(14);
    const s1 = a.get(&fs, 'a', .{}, m, 1).?;
    const s2 = a.get(&fs, 'a', .{}, m, 1).?;
    try std.testing.expectEqual(s1, s2);
    const s3 = a.get(&fs, 'a', .{ .bold = true }, m, 1).?;
    try std.testing.expect(s3.x != s1.x or s3.y != s1.y);
    try std.testing.expect(a.takeDirty() != null);
    // Fill it up: eventually returns null instead of overflowing.
    var cp: u21 = 0x21;
    var full = false;
    while (cp < 0x2000) : (cp += 1) {
        if (a.get(&fs, cp, .{}, m, 1) == null) {
            full = true;
            break;
        }
    }
    try std.testing.expect(full);
    a.wipe();
    try std.testing.expect(a.get(&fs, 'a', .{}, m, 1) != null);
}
