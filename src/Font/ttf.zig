//! TrueType (glyf-flavoured sfnt) parser: head, hhea, maxp, cmap, hmtx, loca,
//! glyf, plus .ttc collections.
//!
//! Font files are untrusted input. Every read goes through `Reader`, which
//! bounds-checks and returns `error.Malformed` instead of panicking; all
//! offset arithmetic is overflow-checked; composite glyph recursion and
//! point counts are capped. Nothing here asserts on file contents.

const std = @import("std");

pub const Error = error{ Malformed, Unsupported, OutOfMemory };

/// Caps that keep hostile files from consuming unbounded CPU or memory.
pub const max_points_per_glyph = 1 << 16;
pub const max_contours_per_glyph = 1 << 14;
pub const max_composite_depth = 8;
pub const max_components = 256;

const Reader = struct {
    data: []const u8,

    fn slice(r: Reader, off: usize, len: usize) Error![]const u8 {
        const end = std.math.add(usize, off, len) catch return error.Malformed;
        if (end > r.data.len) return error.Malformed;
        return r.data[off..end];
    }
    fn u8At(r: Reader, off: usize) Error!u8 {
        if (off >= r.data.len) return error.Malformed;
        return r.data[off];
    }
    fn u16At(r: Reader, off: usize) Error!u16 {
        const s = try r.slice(off, 2);
        return std.mem.readInt(u16, s[0..2], .big);
    }
    fn i16At(r: Reader, off: usize) Error!i16 {
        return @bitCast(try r.u16At(off));
    }
    fn u32At(r: Reader, off: usize) Error!u32 {
        const s = try r.slice(off, 4);
        return std.mem.readInt(u32, s[0..4], .big);
    }
};

fn addOff(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.Malformed;
}

pub const Point = struct { x: f32, y: f32, on: bool };

/// A glyph outline in font units (y up). Contours are closed implicitly.
pub const Outline = struct {
    points: std.ArrayList(Point) = .empty,
    /// Index one past the last point of each contour.
    contour_ends: std.ArrayList(u32) = .empty,

    pub fn deinit(o: *Outline, gpa: std.mem.Allocator) void {
        o.points.deinit(gpa);
        o.contour_ends.deinit(gpa);
    }
    pub fn clear(o: *Outline) void {
        o.points.clearRetainingCapacity();
        o.contour_ends.clearRetainingCapacity();
    }
};

const Table = struct { off: usize, len: usize };

pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    num_glyphs: u16,
    num_hmetrics: u16,
    long_loca: bool,
    loca: Table,
    glyf: Table,
    hmtx: Table,
    /// Offset of the chosen cmap subtable (absolute) and its format.
    cmap_sub: usize,
    cmap_format: u16,

    /// Parses a font. `index` selects a face in a .ttc collection (ignored
    /// for single fonts). `data` must outlive the Font.
    pub fn init(data: []const u8, index: u32) Error!Font {
        const r: Reader = .{ .data = data };
        var base: usize = 0;
        const tag = try r.u32At(0);
        if (tag == 0x74746366) { // 'ttcf'
            const n = try r.u32At(8);
            if (index >= n) return error.Malformed;
            base = try r.u32At(try addOff(12, @as(usize, index) * 4));
        }
        const version = try r.u32At(base);
        switch (version) {
            0x00010000, 0x74727565 => {}, // 1.0, 'true'
            0x4F54544F => return error.Unsupported, // 'OTTO': CFF outlines
            else => return error.Malformed,
        }
        const num_tables = try r.u16At(base + 4);
        var head: ?Table = null;
        var hhea: ?Table = null;
        var maxp: ?Table = null;
        var cmap: ?Table = null;
        var hmtx: ?Table = null;
        var loca: ?Table = null;
        var glyf: ?Table = null;
        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = try addOff(base + 12, i * 16);
            const t = try r.slice(rec, 4);
            const off = try r.u32At(rec + 8);
            const len = try r.u32At(rec + 12);
            _ = try r.slice(off, len); // table must lie inside the file
            const tbl: Table = .{ .off = off, .len = len };
            if (std.mem.eql(u8, t, "head")) head = tbl;
            if (std.mem.eql(u8, t, "hhea")) hhea = tbl;
            if (std.mem.eql(u8, t, "maxp")) maxp = tbl;
            if (std.mem.eql(u8, t, "cmap")) cmap = tbl;
            if (std.mem.eql(u8, t, "hmtx")) hmtx = tbl;
            if (std.mem.eql(u8, t, "loca")) loca = tbl;
            if (std.mem.eql(u8, t, "glyf")) glyf = tbl;
        }
        const h = head orelse return error.Malformed;
        const hh = hhea orelse return error.Malformed;
        const mp = maxp orelse return error.Malformed;
        const cm = cmap orelse return error.Malformed;
        const hm = hmtx orelse return error.Malformed;
        const lc = loca orelse return error.Unsupported;
        const gl = glyf orelse return error.Unsupported;
        if (h.len < 54 or hh.len < 36 or mp.len < 6) return error.Malformed;

        const upem = try r.u16At(h.off + 18);
        if (upem < 16 or upem > 16384) return error.Malformed;
        const loca_format = try r.i16At(h.off + 50);
        if (loca_format != 0 and loca_format != 1) return error.Malformed;
        const num_glyphs = try r.u16At(mp.off + 4);
        const num_hmetrics = try r.u16At(hh.off + 34);
        if (num_glyphs == 0 or num_hmetrics == 0) return error.Malformed;
        if (@as(usize, num_hmetrics) * 4 > hm.len) return error.Malformed;
        const loca_entry: usize = if (loca_format == 1) 4 else 2;
        if ((@as(usize, num_glyphs) + 1) * loca_entry > lc.len) return error.Malformed;

        var font: Font = .{
            .data = data,
            .units_per_em = upem,
            .ascender = try r.i16At(hh.off + 4),
            .descender = try r.i16At(hh.off + 6),
            .line_gap = try r.i16At(hh.off + 8),
            .num_glyphs = num_glyphs,
            .num_hmetrics = num_hmetrics,
            .long_loca = loca_format == 1,
            .loca = lc,
            .glyf = gl,
            .hmtx = hm,
            .cmap_sub = 0,
            .cmap_format = 0,
        };
        try font.pickCmap(cm);
        return font;
    }

    /// Number of faces in a .ttc (1 for a plain font).
    pub fn faceCount(data: []const u8) Error!u32 {
        const r: Reader = .{ .data = data };
        if (try r.u32At(0) == 0x74746366) return r.u32At(8);
        return 1;
    }

    fn pickCmap(f: *Font, cm: Table) Error!void {
        const r: Reader = .{ .data = f.data };
        const n = try r.u16At(cm.off + 2);
        var best_score: u8 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = try addOff(cm.off + 4, i * 8);
            const platform = try r.u16At(rec);
            const encoding = try r.u16At(rec + 2);
            const sub_off = try addOff(cm.off, try r.u32At(rec + 4));
            if (sub_off >= cm.off + cm.len) continue;
            const format = r.u16At(sub_off) catch continue;
            const score: u8 = switch (format) {
                12 => if ((platform == 3 and encoding == 10) or platform == 0) 4 else 0,
                4 => if ((platform == 3 and encoding == 1) or platform == 0) 3 else 0,
                else => 0,
            };
            if (score > best_score) {
                best_score = score;
                f.cmap_sub = sub_off;
                f.cmap_format = format;
            }
        }
        if (best_score == 0) return error.Unsupported;
    }

    /// Glyph index for a code point, 0 (.notdef) if absent or on bad data.
    pub fn glyphIndex(f: *const Font, cp: u21) u16 {
        return f.glyphIndexChecked(cp) catch 0;
    }

    fn glyphIndexChecked(f: *const Font, cp: u21) Error!u16 {
        const r: Reader = .{ .data = f.data };
        const s = f.cmap_sub;
        switch (f.cmap_format) {
            4 => {
                if (cp > 0xffff) return 0;
                const c: u16 = @intCast(cp);
                const seg_x2 = try r.u16At(s + 6);
                const segs: usize = seg_x2 / 2;
                if (segs == 0) return 0;
                const ends = s + 14;
                const starts = try addOff(ends, @as(usize, seg_x2) + 2);
                const deltas = try addOff(starts, seg_x2);
                const ranges = try addOff(deltas, seg_x2);
                // Binary search for the first segment whose end >= c.
                var lo: usize = 0;
                var hi: usize = segs;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (try r.u16At(ends + mid * 2) < c) lo = mid + 1 else hi = mid;
                }
                if (lo >= segs) return 0;
                const start = try r.u16At(starts + lo * 2);
                if (c < start) return 0;
                const delta = try r.u16At(deltas + lo * 2);
                const range_pos = ranges + lo * 2;
                const range = try r.u16At(range_pos);
                if (range == 0) return c +% delta;
                const gaddr = try addOff(try addOff(range_pos, range), @as(usize, c - start) * 2);
                const g = try r.u16At(gaddr);
                if (g == 0) return 0;
                return g +% delta;
            },
            12 => {
                const ngroups = try r.u32At(s + 12);
                var lo: usize = 0;
                var hi: usize = ngroups;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const g = try addOff(s + 16, mid * 12);
                    const start = try r.u32At(g);
                    const end = try r.u32At(g + 4);
                    if (cp < start) {
                        hi = mid;
                    } else if (cp > end) {
                        lo = mid + 1;
                    } else {
                        // A hostile startGlyphID near 2^32 must not overflow.
                        const gid = std.math.add(u32, try r.u32At(g + 8), cp - start) catch return 0;
                        return if (gid < f.num_glyphs) @intCast(gid) else 0;
                    }
                }
                return 0;
            },
            else => return 0,
        }
    }

    /// Advance width in font units.
    pub fn advance(f: *const Font, gid: u16) u16 {
        const r: Reader = .{ .data = f.data };
        const i: usize = @min(gid, f.num_hmetrics - 1);
        return r.u16At(f.hmtx.off + i * 4) catch 0;
    }

    fn glyphRange(f: *const Font, gid: u16) Error!?Table {
        if (gid >= f.num_glyphs) return error.Malformed;
        const r: Reader = .{ .data = f.data };
        var a: usize = undefined;
        var b: usize = undefined;
        if (f.long_loca) {
            a = try r.u32At(f.loca.off + @as(usize, gid) * 4);
            b = try r.u32At(f.loca.off + (@as(usize, gid) + 1) * 4);
        } else {
            a = @as(usize, try r.u16At(f.loca.off + @as(usize, gid) * 2)) * 2;
            b = @as(usize, try r.u16At(f.loca.off + (@as(usize, gid) + 1) * 2)) * 2;
        }
        if (b <= a) return null; // empty glyph (space) or bogus order
        if (b > f.glyf.len) return error.Malformed;
        return .{ .off = f.glyf.off + a, .len = b - a };
    }

    /// Appends the glyph's outline (font units) to `out`. On error the
    /// outline may be partially filled; callers should treat it as missing.
    pub fn glyphOutline(f: *const Font, gpa: std.mem.Allocator, gid: u16, out: *Outline) Error!void {
        var components: usize = 0;
        try f.appendGlyph(gpa, gid, out, .identity, 0, &components);
    }

    const Xform = struct {
        a: f32,
        b: f32,
        c: f32,
        d: f32,
        dx: f32,
        dy: f32,
        const identity: Xform = .{ .a = 1, .b = 0, .c = 0, .d = 1, .dx = 0, .dy = 0 };
        fn apply(t: Xform, x: f32, y: f32) [2]f32 {
            return .{ t.a * x + t.c * y + t.dx, t.b * x + t.d * y + t.dy };
        }
        fn then(inner: Xform, outer: Xform) Xform {
            // result(p) = outer(inner(p))
            return .{
                .a = outer.a * inner.a + outer.c * inner.b,
                .b = outer.b * inner.a + outer.d * inner.b,
                .c = outer.a * inner.c + outer.c * inner.d,
                .d = outer.b * inner.c + outer.d * inner.d,
                .dx = outer.a * inner.dx + outer.c * inner.dy + outer.dx,
                .dy = outer.b * inner.dx + outer.d * inner.dy + outer.dy,
            };
        }
    };

    fn appendGlyph(
        f: *const Font,
        gpa: std.mem.Allocator,
        gid: u16,
        out: *Outline,
        xf: Xform,
        depth: usize,
        components: *usize,
    ) Error!void {
        if (depth > max_composite_depth) return error.Malformed;
        const range = (try f.glyphRange(gid)) orelse return;
        const r: Reader = .{ .data = f.data };
        const g = range.off;
        if (range.len < 10) return error.Malformed;
        const ncont = try r.i16At(g);
        if (ncont >= 0) return f.appendSimple(gpa, r, range, @intCast(ncont), out, xf);

        // Composite glyph.
        var p: usize = g + 10;
        const end = g + range.len;
        while (true) {
            components.* += 1;
            if (components.* > max_components) return error.Malformed;
            if (p + 4 > end) return error.Malformed;
            const flags = try r.u16At(p);
            const child = try r.u16At(p + 2);
            p += 4;
            var arg1: f32 = 0;
            var arg2: f32 = 0;
            if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
                arg1 = @floatFromInt(try r.i16At(p));
                arg2 = @floatFromInt(try r.i16At(p + 2));
                p += 4;
            } else {
                arg1 = @floatFromInt(@as(i8, @bitCast(try r.u8At(p))));
                arg2 = @floatFromInt(@as(i8, @bitCast(try r.u8At(p + 1))));
                p += 2;
            }
            var t: Xform = .identity;
            if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
                const s = f2dot14(try r.i16At(p));
                t.a = s;
                t.d = s;
                p += 2;
            } else if (flags & 0x0040 != 0) { // X_AND_Y_SCALE
                t.a = f2dot14(try r.i16At(p));
                t.d = f2dot14(try r.i16At(p + 2));
                p += 4;
            } else if (flags & 0x0080 != 0) { // TWO_BY_TWO
                t.a = f2dot14(try r.i16At(p));
                t.b = f2dot14(try r.i16At(p + 2));
                t.c = f2dot14(try r.i16At(p + 4));
                t.d = f2dot14(try r.i16At(p + 6));
                p += 8;
            }
            if (flags & 0x0002 != 0) { // ARGS_ARE_XY_VALUES
                t.dx = arg1;
                t.dy = arg2;
            } // else: point matching; rare in practice, offsets left at 0.
            if (child == gid) return error.Malformed;
            try f.appendGlyph(gpa, child, out, t.then(xf), depth + 1, components);
            if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
        }
    }

    fn appendSimple(
        f: *const Font,
        gpa: std.mem.Allocator,
        r: Reader,
        range: Table,
        ncont: usize,
        out: *Outline,
        xf: Xform,
    ) Error!void {
        _ = f;
        if (ncont == 0) return;
        if (ncont > max_contours_per_glyph) return error.Malformed;
        const g = range.off;
        const end = g + range.len;
        const ends_off = g + 10;
        if (ends_off + ncont * 2 + 2 > end) return error.Malformed;
        const last_end = try r.u16At(ends_off + (ncont - 1) * 2);
        const npts: usize = @as(usize, last_end) + 1;
        if (out.points.items.len + npts > max_points_per_glyph) return error.Malformed;
        const instr_len = try r.u16At(ends_off + ncont * 2);
        var p = try addOff(ends_off + ncont * 2 + 2, instr_len);
        if (p > end) return error.Malformed;

        const base: u32 = @intCast(out.points.items.len);
        // Contour ends must be strictly increasing.
        var prev: i32 = -1;
        for (0..ncont) |i| {
            const e = try r.u16At(ends_off + i * 2);
            if (@as(i32, e) <= prev) return error.Malformed;
            prev = e;
        }

        // Flags (with repeats) go into a temporary array.
        const flags = try gpa.alloc(u8, npts);
        defer gpa.free(flags);
        var i: usize = 0;
        while (i < npts) {
            if (p >= end) return error.Malformed;
            const fl = r.data[p];
            p += 1;
            flags[i] = fl;
            i += 1;
            if (fl & 0x08 != 0) { // REPEAT
                if (p >= end) return error.Malformed;
                const rep = r.data[p];
                p += 1;
                var k: usize = 0;
                while (k < rep) : (k += 1) {
                    if (i >= npts) return error.Malformed;
                    flags[i] = fl;
                    i += 1;
                }
            }
        }

        const xs = try gpa.alloc(i32, npts);
        defer gpa.free(xs);
        var v: i32 = 0;
        for (flags, 0..) |fl, k| {
            if (fl & 0x02 != 0) { // X_SHORT
                if (p >= end) return error.Malformed;
                const d: i32 = r.data[p];
                p += 1;
                v += if (fl & 0x10 != 0) d else -d;
            } else if (fl & 0x10 == 0) {
                if (p + 2 > end) return error.Malformed;
                v += try r.i16At(p);
                p += 2;
            }
            xs[k] = v;
        }
        try out.points.ensureUnusedCapacity(gpa, npts);
        v = 0;
        for (flags, 0..) |fl, k| {
            if (fl & 0x04 != 0) { // Y_SHORT
                if (p >= end) return error.Malformed;
                const d: i32 = r.data[p];
                p += 1;
                v += if (fl & 0x20 != 0) d else -d;
            } else if (fl & 0x20 == 0) {
                if (p + 2 > end) return error.Malformed;
                v += try r.i16At(p);
                p += 2;
            }
            const xy = xf.apply(@floatFromInt(xs[k]), @floatFromInt(v));
            out.points.appendAssumeCapacity(.{ .x = xy[0], .y = xy[1], .on = fl & 0x01 != 0 });
        }
        try out.contour_ends.ensureUnusedCapacity(gpa, ncont);
        for (0..ncont) |k| {
            const e = try r.u16At(ends_off + k * 2);
            out.contour_ends.appendAssumeCapacity(base + @as(u32, e) + 1);
        }
    }
};

fn f2dot14(v: i16) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// DejaVu Sans Mono 2.37 (testdata/, see testdata/LICENSE.txt), embedded so
/// the tests run the same on every machine and target.
pub const test_font: []const u8 = @embedFile("testdata/DejaVuSansMono.ttf");

/// A heap copy of the test font (the corruption tests mutate it).
fn loadTestFont(gpa: std.mem.Allocator) ?[]u8 {
    return gpa.dupe(u8, test_font) catch null;
}

test "cmap format 12: startGlyphID overflow maps to .notdef" {
    // One format-12 subtable, one group 0x41..0x5A -> startGlyphID 0xFFFFFFFF.
    var sub_buf: [28]u8 = undefined;
    std.mem.writeInt(u16, sub_buf[0..2], 12, .big);
    std.mem.writeInt(u16, sub_buf[2..4], 0, .big);
    std.mem.writeInt(u32, sub_buf[4..8], 28, .big);
    std.mem.writeInt(u32, sub_buf[8..12], 0, .big);
    std.mem.writeInt(u32, sub_buf[12..16], 1, .big);
    std.mem.writeInt(u32, sub_buf[16..20], 0x41, .big);
    std.mem.writeInt(u32, sub_buf[20..24], 0x5A, .big);
    std.mem.writeInt(u32, sub_buf[24..28], 0xFFFF_FFFF, .big);
    const empty: Table = .{ .off = 0, .len = 0 };
    const f: Font = .{
        .data = &sub_buf,
        .units_per_em = 1000,
        .ascender = 800,
        .descender = -200,
        .line_gap = 0,
        .num_glyphs = 100,
        .num_hmetrics = 1,
        .long_loca = false,
        .loca = empty,
        .glyf = empty,
        .hmtx = empty,
        .cmap_sub = 0,
        .cmap_format = 12,
    };
    try testing.expectEqual(@as(u16, 0), f.glyphIndex('A'));
    try testing.expectEqual(@as(u16, 0), f.glyphIndex('Z'));
    try testing.expectEqual(@as(u16, 0), f.glyphIndex('a'));
}

test "parse real monospace font" {
    const gpa = testing.allocator;
    const data = loadTestFont(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    const f = try Font.init(data, 0);
    try testing.expect(f.units_per_em >= 1000);
    const a = f.glyphIndex('A');
    const m = f.glyphIndex('M');
    try testing.expect(a != 0 and m != 0 and a != m);
    // Monospace: same advance.
    try testing.expectEqual(f.advance(a), f.advance(m));
    try testing.expectEqual(f.advance(a), f.advance(f.glyphIndex('i')));
    var o: Outline = .{};
    defer o.deinit(gpa);
    try f.glyphOutline(gpa, a, &o);
    try testing.expect(o.points.items.len > 4);
    try testing.expect(o.contour_ends.items.len >= 2); // 'A' has a hole
    // Accented letters are usually composites.
    o.clear();
    try f.glyphOutline(gpa, f.glyphIndex(0xE9), &o); // é
    try testing.expect(o.contour_ends.items.len >= 2);
    // Space has no outline; unmapped code point maps to .notdef.
    o.clear();
    try f.glyphOutline(gpa, f.glyphIndex(' '), &o);
    try testing.expectEqual(@as(usize, 0), o.points.items.len);
    try testing.expectEqual(@as(u16, 0), f.glyphIndex(0x10FFFD));
}

fn exerciseFont(gpa: std.mem.Allocator, data: []const u8) void {
    const f = Font.init(data, 0) catch return;
    var o: Outline = .{};
    defer o.deinit(gpa);
    const cps = [_]u21{ 'A', 'g', '@', 0xE9, 0x2500, 0x4E00, 0x1F600, 0xFFFF, 0 };
    for (cps) |cp| {
        o.clear();
        const gid = f.glyphIndex(cp);
        _ = f.advance(gid);
        f.glyphOutline(gpa, gid, &o) catch {};
    }
    // Every glyph id, including ones beyond num_glyphs.
    var gid: u32 = 0;
    while (gid < @min(@as(u32, f.num_glyphs) + 2, 400)) : (gid += 1) {
        o.clear();
        f.glyphOutline(gpa, @intCast(gid), &o) catch {};
    }
}

test "truncated and corrupted fonts never panic" {
    const gpa = testing.allocator;
    const data = loadTestFont(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);

    // Truncations at many lengths, including inside the table directory.
    var len: usize = 0;
    while (len < data.len) : (len += if (len < 4096) 37 else data.len / 61) {
        exerciseFont(gpa, data[0..len]);
    }

    // Random byte corruption (deterministic seed).
    const copy = try gpa.dupe(u8, data);
    defer gpa.free(copy);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    for (0..60) |_| {
        @memcpy(copy, data);
        for (0..64) |_| {
            // Bias corruption toward the header/tables directory and early tables.
            const limit = if (rand.boolean()) @min(copy.len, 2048) else copy.len;
            copy[rand.uintLessThan(usize, limit)] = rand.int(u8);
        }
        exerciseFont(gpa, copy);
    }
}

test "garbage and tiny inputs" {
    const gpa = testing.allocator;
    try testing.expectError(error.Malformed, Font.init("", 0));
    try testing.expectError(error.Malformed, Font.init("\x00\x01\x00\x00", 0));
    try testing.expectError(error.Malformed, Font.init("ttcf\x00\x01\x00\x00\x00\x00\x00\x05", 9));
    try testing.expectError(error.Unsupported, Font.init("OTTO\x00\x00\x00\x00\x00\x00\x00\x00", 0));
    var prng = std.Random.DefaultPrng.init(42);
    var buf: [512]u8 = undefined;
    for (0..2000) |k| {
        prng.random().bytes(&buf);
        // Make some of them look like fonts so parsing gets further.
        if (k % 2 == 0) std.mem.writeInt(u32, buf[0..4], 0x00010000, .big);
        if (k % 4 == 1) @memcpy(buf[0..4], "ttcf");
        buf[4] = 0;
        exerciseFont(gpa, &buf);
    }
}
