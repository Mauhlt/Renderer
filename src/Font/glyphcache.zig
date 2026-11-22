//! Glyph coverage cache for drawing text on the CPU (module "Raster" blits
//! the coverage): the same glyph bitmaps the GPU atlas holds, from the same
//! `FontSet.render`, kept as 8-bit coverage (w = cells * cell_w, h =
//! cell_h, row-major, 0 = empty, 255 = fully inked) under a fixed memory
//! cap with least-recently-used eviction.
//!
//! A cache belongs to one font set: entries are keyed by
//! `fontset.glyphKey` (code point, em size, style, cell span), like the
//! atlas. `cap_bytes` bounds the coverage plus a fixed per-entry
//! bookkeeping charge (`entry_cost`); the one exception is a glyph larger
//! than the whole cap, rendered into a scratch buffer instead of cached.
//! Not thread-safe.

const std = @import("std");
const fontset = @import("fontset.zig");

pub const Glyph = struct {
    w: u32,
    h: u32,
    /// w * h bytes. Valid until the next `get` or `clear` (which may evict
    /// it): draw it before asking for the next glyph.
    coverage: []const u8,
};

const none = std.math.maxInt(u32);

const Entry = struct {
    key: u64,
    cov: []u8,
    w: u32,
    h: u32,
    /// Recency list: `prev` towards the most recently used (head).
    prev: u32 = none,
    next: u32 = none,
};

/// What each cached glyph costs on top of its coverage bytes: the entry and
/// its hash map slot (key, value, metadata), rounded up.
pub const entry_cost = @sizeOf(Entry) + 16;

pub const GlyphCache = struct {
    gpa: std.mem.Allocator,
    cap_bytes: usize,
    used: usize = 0,
    map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    /// Slots of evicted entries, reused before `entries` grows.
    free: std.ArrayList(u32) = .empty,
    head: u32 = none,
    tail: u32 = none,
    scratch: []u8 = &.{},
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, cap_bytes: usize) GlyphCache {
        return .{ .gpa = gpa, .cap_bytes = cap_bytes };
    }

    pub fn deinit(c: *GlyphCache) void {
        c.clear();
        c.map.deinit(c.gpa);
        c.entries.deinit(c.gpa);
        c.free.deinit(c.gpa);
        c.gpa.free(c.scratch);
        c.* = undefined;
    }

    /// Drops every glyph (e.g. after the font set changes).
    pub fn clear(c: *GlyphCache) void {
        for (c.entries.items) |e| c.gpa.free(e.cov);
        c.entries.clearRetainingCapacity();
        c.free.clearRetainingCapacity();
        c.map.clearRetainingCapacity();
        c.head = none;
        c.tail = none;
        c.used = 0;
    }

    /// Number of glyphs held.
    pub fn count(c: *const GlyphCache) usize {
        return c.map.count();
    }

    /// The coverage of `cp` as `fonts.render` draws it for metrics `m`
    /// (`cells` 1 or 2 wide), rendering it on a miss. Null only when memory
    /// runs out.
    pub fn get(c: *GlyphCache, fonts: *fontset.FontSet, cp: u21, style: fontset.Style, m: fontset.Metrics, cells: u32) ?Glyph {
        const key = fontset.glyphKey(cp, m.em, style, cells);
        if (c.map.get(key)) |i| {
            c.hits += 1;
            c.touch(i);
            const e = &c.entries.items[i];
            return .{ .w = e.w, .h = e.h, .coverage = e.cov };
        }
        c.misses += 1;
        const w = m.cell_w * cells;
        const h = m.cell_h;
        const n = @as(usize, w) * h;
        const cost = n + entry_cost;
        if (cost > c.cap_bytes) {
            // Never fits: render it uncached.
            if (c.scratch.len < n) {
                c.gpa.free(c.scratch);
                c.scratch = c.gpa.alloc(u8, n) catch {
                    c.scratch = &.{};
                    return null;
                };
            }
            fonts.render(cp, style, m, cells, c.scratch[0..n]);
            return .{ .w = w, .h = h, .coverage = c.scratch[0..n] };
        }
        // Make room; an evicted bitmap of the same size is reused (glyphs
        // of one font size all have the same size).
        var reuse: ?[]u8 = null;
        while (c.used + cost > c.cap_bytes) {
            const old = c.evictTail();
            if (reuse == null and old.len == n) reuse = old else c.gpa.free(old);
        }
        const cov = reuse orelse (c.gpa.alloc(u8, n) catch return null);
        const i: u32 = c.free.pop() orelse blk: {
            c.entries.append(c.gpa, undefined) catch {
                c.gpa.free(cov);
                return null;
            };
            break :blk @intCast(c.entries.items.len - 1);
        };
        c.map.put(c.gpa, key, i) catch {
            c.gpa.free(cov);
            c.free.append(c.gpa, i) catch {};
            return null;
        };
        fonts.render(cp, style, m, cells, cov);
        c.entries.items[i] = .{ .key = key, .cov = cov, .w = w, .h = h };
        c.linkHead(i);
        c.used += cost;
        return .{ .w = w, .h = h, .coverage = cov };
    }

    /// Removes the least recently used glyph and returns its bitmap (the
    /// caller frees or reuses it). The list is not empty when called:
    /// anything that does not fit an empty cache never gets here.
    fn evictTail(c: *GlyphCache) []u8 {
        const i = c.tail;
        const e = &c.entries.items[i];
        c.unlink(i);
        _ = c.map.remove(e.key);
        c.free.append(c.gpa, i) catch {}; // a lost slot only wastes the entry
        c.used -= e.cov.len + entry_cost;
        c.evictions += 1;
        const cov = e.cov;
        e.cov = &.{};
        return cov;
    }

    fn touch(c: *GlyphCache, i: u32) void {
        if (c.head == i) return;
        c.unlink(i);
        c.linkHead(i);
    }

    fn unlink(c: *GlyphCache, i: u32) void {
        const e = &c.entries.items[i];
        if (e.prev != none) c.entries.items[e.prev].next = e.next else c.head = e.next;
        if (e.next != none) c.entries.items[e.next].prev = e.prev else c.tail = e.prev;
        e.prev = none;
        e.next = none;
    }

    fn linkHead(c: *GlyphCache, i: u32) void {
        const e = &c.entries.items[i];
        e.prev = none;
        e.next = c.head;
        if (c.head != none) c.entries.items[c.head].prev = i;
        c.head = i;
        if (c.tail == none) c.tail = i;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;
const ttf = @import("ttf.zig");

fn testFonts() !fontset.FontSet {
    return fontset.FontSet.fromMemory(testing.allocator, std.Io.failing, ttf.test_font, null);
}

test "glyph cache: a hit returns the same coverage as FontSet.render" {
    var fs = try testFonts();
    defer fs.deinit();
    var c = GlyphCache.init(testing.allocator, 1 << 20);
    defer c.deinit();
    const m = fs.metrics(20);
    const g = c.get(&fs, 'A', .{}, m, 1).?;
    try testing.expectEqual(m.cell_w, g.w);
    try testing.expectEqual(m.cell_h, g.h);
    const want = try testing.allocator.alloc(u8, g.coverage.len);
    defer testing.allocator.free(want);
    fs.render('A', .{}, m, 1, want);
    try testing.expectEqualSlices(u8, want, g.coverage);
    const again = c.get(&fs, 'A', .{}, m, 1).?;
    try testing.expectEqual(g.coverage.ptr, again.coverage.ptr);
    try testing.expectEqual(@as(u64, 1), c.hits);
    try testing.expectEqual(@as(u64, 1), c.misses);
    // Style, size and span are part of the key.
    _ = c.get(&fs, 'A', .{ .bold = true }, m, 1).?;
    _ = c.get(&fs, 'A', .{}, fs.metrics(21), 1).?;
    const wide = c.get(&fs, 'A', .{}, m, 2).?;
    try testing.expectEqual(2 * m.cell_w, wide.w);
    try testing.expectEqual(@as(usize, 4), c.count());
    try testing.expectEqual(@as(u64, 4), c.misses);
}

test "glyph cache: stays under its cap and evicts the least recently used" {
    var fs = try testFonts();
    defer fs.deinit();
    const m = fs.metrics(16);
    const per = @as(usize, m.cell_w) * m.cell_h + entry_cost;
    var c = GlyphCache.init(testing.allocator, 3 * per);
    defer c.deinit();
    _ = c.get(&fs, 'a', .{}, m, 1).?;
    _ = c.get(&fs, 'b', .{}, m, 1).?;
    _ = c.get(&fs, 'c', .{}, m, 1).?;
    try testing.expectEqual(@as(u64, 0), c.evictions);
    _ = c.get(&fs, 'a', .{}, m, 1).?; // 'a' is now the most recent; 'b' the least
    _ = c.get(&fs, 'd', .{}, m, 1).?;
    try testing.expectEqual(@as(u64, 1), c.evictions);
    try testing.expectEqual(@as(usize, 3), c.count());
    try testing.expect(c.used <= c.cap_bytes);
    const misses = c.misses;
    _ = c.get(&fs, 'a', .{}, m, 1).?;
    _ = c.get(&fs, 'c', .{}, m, 1).?;
    _ = c.get(&fs, 'd', .{}, m, 1).?;
    try testing.expectEqual(misses, c.misses); // all three still cached
    const g = c.get(&fs, 'b', .{}, m, 1).?; // evicted: rendered again
    try testing.expectEqual(misses + 1, c.misses);
    const want = try testing.allocator.alloc(u8, g.coverage.len);
    defer testing.allocator.free(want);
    fs.render('b', .{}, m, 1, want);
    try testing.expectEqualSlices(u8, want, g.coverage);
    // Many glyphs through a small cache: bounded throughout.
    var cp: u21 = 0x21;
    while (cp < 0x7F) : (cp += 1) {
        _ = c.get(&fs, cp, .{}, m, 1).?;
        try testing.expect(c.used <= c.cap_bytes);
        try testing.expect(c.count() <= 3);
    }
    c.clear();
    try testing.expectEqual(@as(usize, 0), c.count());
    try testing.expectEqual(@as(usize, 0), c.used);
}

test "glyph cache: a glyph larger than the cap is drawn uncached" {
    var fs = try testFonts();
    defer fs.deinit();
    var c = GlyphCache.init(testing.allocator, 64);
    defer c.deinit();
    const m = fs.metrics(16);
    const g = c.get(&fs, 'M', .{}, m, 1).?;
    var ink: usize = 0;
    for (g.coverage) |v| ink += v;
    try testing.expect(ink > 0);
    try testing.expectEqual(@as(usize, 0), c.count());
}
