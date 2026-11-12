//! System fonts: a monospace primary face (plus bold when available) and
//! lazily loaded fallbacks for characters the primary lacks (CJK, emoji,
//! symbols). Glyphs are rasterised into cell-sized coverage bitmaps, so
//! the renderer just draws one quad per cell.
//!
//! Font files are read at runtime from the OS font directories; nothing is
//! bundled. They are treated as untrusted (see ttf.zig): a broken font is
//! skipped, and a missing glyph becomes a replacement box.

const std = @import("std");
const builtin = @import("builtin");
const ttf = @import("ttf.zig");
const raster = @import("raster.zig");

const max_font_bytes = 64 << 20;

const FontRef = struct { path: []const u8, index: u32 = 0 };

const primary_paths: []const FontRef = switch (builtin.os.tag) {
    .windows => &.{ .{ .path = "C:\\Windows\\Fonts\\consola.ttf" }, .{ .path = "C:\\Windows\\Fonts\\cour.ttf" } },
    .macos => &.{ .{ .path = "/System/Library/Fonts/Menlo.ttc", .index = 0 }, .{ .path = "/System/Library/Fonts/Monaco.ttf" } },
    else => &.{
        .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf" },
        .{ .path = "/usr/share/fonts/TTF/DejaVuSansMono.ttf" },
        .{ .path = "/usr/share/fonts/dejavu/DejaVuSansMono.ttf" },
        .{ .path = "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf" },
        .{ .path = "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf" },
        .{ .path = "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf" },
        .{ .path = "/usr/share/fonts/TTF/LiberationMono-Regular.ttf" },
    },
};

const bold_paths: []const FontRef = switch (builtin.os.tag) {
    .windows => &.{ .{ .path = "C:\\Windows\\Fonts\\consolab.ttf" }, .{ .path = "C:\\Windows\\Fonts\\courbd.ttf" } },
    .macos => &.{.{ .path = "/System/Library/Fonts/Menlo.ttc", .index = 1 }},
    else => &.{
        .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf" },
        .{ .path = "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf" },
        .{ .path = "/usr/share/fonts/dejavu/DejaVuSansMono-Bold.ttf" },
        .{ .path = "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf" },
    },
};

const fallback_paths: []const FontRef = switch (builtin.os.tag) {
    .windows => &.{
        .{ .path = "C:\\Windows\\Fonts\\seguisym.ttf" },
        .{ .path = "C:\\Windows\\Fonts\\msgothic.ttc" },
        .{ .path = "C:\\Windows\\Fonts\\malgun.ttf" },
        .{ .path = "C:\\Windows\\Fonts\\simsun.ttc" },
        .{ .path = "C:\\Windows\\Fonts\\seguiemj.ttf" },
        .{ .path = "C:\\Windows\\Fonts\\arial.ttf" },
    },
    .macos => &.{
        .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
        .{ .path = "/Library/Fonts/Arial Unicode.ttf" },
        .{ .path = "/System/Library/Fonts/Apple Symbols.ttf" },
    },
    else => &.{
        .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
        .{ .path = "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf" },
        .{ .path = "/usr/share/fonts/google-droid/DroidSansFallbackFull.ttf" },
        .{ .path = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc" },
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf" },
    },
};

const Face = struct {
    data: []u8,
    font: ttf.Font,
};

pub const Style = packed struct(u2) { bold: bool = false, italic: bool = false };

pub const Metrics = struct {
    em: f32,
    cell_w: u32,
    cell_h: u32,
    baseline: f32,
    /// Underline position (top) and stroke thickness, pixels.
    underline_y: u32,
    stroke: u32,
};

pub const FontSet = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    regular: Face,
    bold: ?Face,
    fallbacks: [fallback_paths.len]?Face = @splat(null),
    fallback_tried: [fallback_paths.len]bool = @splat(false),
    outline: ttf.Outline = .{},

    pub fn load(gpa: std.mem.Allocator, io: std.Io) !FontSet {
        const regular = loadFirst(gpa, io, primary_paths) orelse return error.NoMonospaceFont;
        return .{
            .gpa = gpa,
            .io = io,
            .regular = regular,
            .bold = loadFirst(gpa, io, bold_paths),
        };
    }

    pub fn deinit(fs: *FontSet) void {
        fs.gpa.free(fs.regular.data);
        if (fs.bold) |b| fs.gpa.free(b.data);
        for (fs.fallbacks) |f| if (f) |face| fs.gpa.free(face.data);
        fs.outline.deinit(fs.gpa);
    }

    fn loadFirst(gpa: std.mem.Allocator, io: std.Io, refs: []const FontRef) ?Face {
        for (refs) |r| if (loadFace(gpa, io, r)) |f| return f;
        return null;
    }

    fn loadFace(gpa: std.mem.Allocator, io: std.Io, r: FontRef) ?Face {
        const data = std.Io.Dir.cwd().readFileAlloc(io, r.path, gpa, .limited(max_font_bytes)) catch return null;
        const font = ttf.Font.init(data, r.index) catch {
            gpa.free(data);
            return null;
        };
        // A primary face must actually have the basic Latin glyphs.
        if (font.glyphIndex('M') == 0 and font.glyphIndex(0x4E00) == 0 and font.glyphIndex(0x2605) == 0) {
            gpa.free(data);
            return null;
        }
        return .{ .data = data, .font = font };
    }

    /// Cell metrics for an em size in pixels.
    pub fn metrics(fs: *const FontSet, em: f32) Metrics {
        const f = &fs.regular.font;
        const scale = em / @as(f32, @floatFromInt(f.units_per_em));
        const adv: f32 = @floatFromInt(f.advance(f.glyphIndex('M')));
        const asc: f32 = @floatFromInt(f.ascender);
        const desc: f32 = @floatFromInt(f.descender);
        const gap: f32 = @floatFromInt(@max(f.line_gap, 0));
        const cell_w: u32 = @intFromFloat(@max(1, @round(adv * scale)));
        const cell_h: u32 = @intFromFloat(@max(2, @ceil((asc - desc + gap) * scale)));
        const baseline = @round(asc * scale + gap * scale * 0.5);
        const stroke: u32 = @max(1, @as(u32, @intFromFloat(@round(em / 14))));
        const ul = @min(cell_h - stroke, @as(u32, @intFromFloat(baseline)) + @max(1, stroke));
        return .{ .em = em, .cell_w = cell_w, .cell_h = cell_h, .baseline = baseline, .underline_y = ul, .stroke = stroke };
    }

    /// Ratio of cell height to width, for fitting.
    pub fn aspect(fs: *const FontSet) struct { w_per_em: f32, h_per_em: f32 } {
        const f = &fs.regular.font;
        const upem: f32 = @floatFromInt(f.units_per_em);
        const adv: f32 = @floatFromInt(f.advance(f.glyphIndex('M')));
        const lh: f32 = @floatFromInt(@as(i32, f.ascender) - f.descender + @max(f.line_gap, 0));
        return .{ .w_per_em = adv / upem, .h_per_em = lh / upem };
    }

    fn fallbackFor(fs: *FontSet, cp: u21) ?*const Face {
        for (fallback_paths, 0..) |ref, i| {
            if (!fs.fallback_tried[i]) {
                fs.fallback_tried[i] = true;
                fs.fallbacks[i] = loadFace(fs.gpa, fs.io, ref);
            }
            if (fs.fallbacks[i]) |*face| {
                if (face.font.glyphIndex(cp) != 0) return face;
            }
        }
        return null;
    }

    /// Renders `cp` into `cov` (w*h bytes, w = cells * cell_w, h = cell_h).
    pub fn render(fs: *FontSet, cp: u21, style: Style, m: Metrics, cells: u32, cov: []u8) void {
        const w = cells * m.cell_w;
        const h = m.cell_h;
        @memset(cov, 0);
        if (cp == ' ' or cp == 0) return;
        if (drawBoxChar(cp, w, h, m, cov)) return;

        var face: *const Face = &fs.regular;
        var synthetic_bold = style.bold;
        if (style.bold) {
            if (fs.bold) |*b| if (b.font.glyphIndex(cp) != 0) {
                face = b;
                synthetic_bold = false;
            };
        }
        var gid = face.font.glyphIndex(cp);
        var is_fallback = false;
        if (gid == 0) {
            face = &fs.regular;
            gid = face.font.glyphIndex(cp);
            if (gid == 0) {
                if (fs.fallbackFor(cp)) |fb| {
                    face = fb;
                    gid = fb.font.glyphIndex(cp);
                    is_fallback = true;
                }
            }
        }
        if (gid == 0) return drawReplacementBox(w, h, m, cov);

        fs.outline.clear();
        face.font.glyphOutline(fs.gpa, gid, &fs.outline) catch return drawReplacementBox(w, h, m, cov);

        var canvas = raster.Canvas.init(fs.gpa, w, h) catch return;
        defer canvas.deinit(fs.gpa);
        const f = &face.font;
        const upem: f32 = @floatFromInt(f.units_per_em);
        var scale = m.em / upem;
        var origin_x: f32 = 0;
        var baseline = m.baseline;
        const adv = @as(f32, @floatFromInt(f.advance(gid))) * scale;
        if (is_fallback) {
            // Fit the fallback's line height into the cell, centre horizontally.
            const lh: f32 = @floatFromInt(@as(i32, f.ascender) - f.descender);
            if (lh > 0) scale = @min(scale, @as(f32, @floatFromInt(h)) / lh * 0.98);
            const fadv = @as(f32, @floatFromInt(f.advance(gid))) * scale;
            if (fadv > @as(f32, @floatFromInt(w))) scale *= @as(f32, @floatFromInt(w)) / fadv;
            origin_x = (@as(f32, @floatFromInt(w)) - @as(f32, @floatFromInt(f.advance(gid))) * scale) / 2;
            baseline = @round(@as(f32, @floatFromInt(f.ascender)) * scale + (@as(f32, @floatFromInt(h)) - lh * scale) / 2);
        } else if (cells == 2 and adv < @as(f32, @floatFromInt(w)) * 0.75) {
            origin_x = (@as(f32, @floatFromInt(w)) - adv) / 2;
        }
        const skew: f32 = if (style.italic) 0.18 else 0;
        if (style.italic) origin_x -= skew * (@as(f32, @floatFromInt(h)) - baseline) * 0.5;
        raster.fillOutline(&canvas, &fs.outline, .{ .scale = scale, .origin_x = origin_x, .baseline_y = baseline, .skew = skew });
        canvas.finish(cov);
        if (synthetic_bold) embolden(cov, w, h, @max(1, m.em / 24));
    }
};

/// Horizontal dilation for a synthetic bold.
fn embolden(cov: []u8, w: u32, h: u32, amount: f32) void {
    const px: u32 = @intFromFloat(@max(1, @round(amount)));
    for (0..h) |y| {
        const row = cov[y * w ..][0..w];
        var x: usize = w;
        while (x > 0) {
            x -= 1;
            var v: u8 = row[x];
            var k: usize = 1;
            while (k <= px and k <= x) : (k += 1) v = @max(v, row[x - k]);
            row[x] = v;
        }
    }
}

fn fillRect(cov: []u8, w: u32, h: u32, x0: i64, y0: i64, x1: i64, y1: i64, value: u8) void {
    const ax: usize = @intCast(std.math.clamp(x0, 0, w));
    const bx: usize = @intCast(std.math.clamp(x1, 0, w));
    const ay: usize = @intCast(std.math.clamp(y0, 0, h));
    const by: usize = @intCast(std.math.clamp(y1, 0, h));
    var y = ay;
    while (y < by) : (y += 1) {
        var x = ax;
        while (x < bx) : (x += 1) cov[y * w + x] = @max(cov[y * w + x], value);
    }
}

fn drawReplacementBox(w: u32, h: u32, m: Metrics, cov: []u8) void {
    const s: i64 = m.stroke;
    const x0: i64 = @intCast(w / 8 + 1);
    const x1: i64 = @as(i64, w) - x0;
    const y0: i64 = @intCast(h / 6);
    const y1: i64 = @as(i64, h) - y0;
    fillRect(cov, w, h, x0, y0, x1, y0 + s, 200);
    fillRect(cov, w, h, x0, y1 - s, x1, y1, 200);
    fillRect(cov, w, h, x0, y0, x0 + s, y1, 200);
    fillRect(cov, w, h, x1 - s, y0, x1, y1, 200);
}

/// Line segment weights for U+2500..U+257F: up, right, down, left
/// (0 none, 1 light, 2 heavy, 3 double).
fn boxSpec(cp: u21) ?[4]u2 {
    return switch (cp) {
        0x2500, 0x2504, 0x2508, 0x254C => .{ 0, 1, 0, 1 },
        0x2501, 0x2505, 0x2509, 0x254D => .{ 0, 2, 0, 2 },
        0x2502, 0x2506, 0x250A, 0x254E => .{ 1, 0, 1, 0 },
        0x2503, 0x2507, 0x250B, 0x254F => .{ 2, 0, 2, 0 },
        0x250C, 0x256D => .{ 0, 1, 1, 0 },
        0x250F => .{ 0, 2, 2, 0 },
        0x2510, 0x256E => .{ 0, 0, 1, 1 },
        0x2513 => .{ 0, 0, 2, 2 },
        0x2514, 0x2570 => .{ 1, 1, 0, 0 },
        0x2517 => .{ 2, 2, 0, 0 },
        0x2518, 0x256F => .{ 1, 0, 0, 1 },
        0x251B => .{ 2, 0, 0, 2 },
        0x251C => .{ 1, 1, 1, 0 },
        0x2523 => .{ 2, 2, 2, 0 },
        0x2524 => .{ 1, 0, 1, 1 },
        0x252B => .{ 2, 0, 2, 2 },
        0x252C => .{ 0, 1, 1, 1 },
        0x2533 => .{ 0, 2, 2, 2 },
        0x2534 => .{ 1, 1, 0, 1 },
        0x253B => .{ 2, 2, 0, 2 },
        0x253C => .{ 1, 1, 1, 1 },
        0x254B => .{ 2, 2, 2, 2 },
        0x2550 => .{ 0, 3, 0, 3 },
        0x2551 => .{ 3, 0, 3, 0 },
        0x2554 => .{ 0, 3, 3, 0 },
        0x2557 => .{ 0, 0, 3, 3 },
        0x255A => .{ 3, 3, 0, 0 },
        0x255D => .{ 3, 0, 0, 3 },
        0x2560 => .{ 3, 3, 3, 0 },
        0x2563 => .{ 3, 0, 3, 3 },
        0x2566 => .{ 0, 3, 3, 3 },
        0x2569 => .{ 3, 3, 0, 3 },
        0x256C => .{ 3, 3, 3, 3 },
        0x2574 => .{ 0, 0, 0, 1 },
        0x2575 => .{ 1, 0, 0, 0 },
        0x2576 => .{ 0, 1, 0, 0 },
        0x2577 => .{ 0, 0, 1, 0 },
        else => null,
    };
}

/// Draws box-drawing and block characters procedurally so they join
/// seamlessly across cells regardless of the font's metrics.
fn drawBoxChar(cp: u21, w: u32, h: u32, m: Metrics, cov: []u8) bool {
    const W: i64 = w;
    const H: i64 = h;
    if (boxSpec(cp)) |spec| {
        const light: i64 = m.stroke;
        const cx = @divFloor(W - light, 2);
        const cy = @divFloor(H - light, 2);
        const dashed = (cp >= 0x2504 and cp <= 0x250B) or (cp >= 0x254C and cp <= 0x254F);
        for (spec, 0..) |weight, dir| {
            if (weight == 0) continue;
            const t: i64 = if (weight == 2) light * 2 else light;
            const off: i64 = if (weight == 2) @divFloor(light, 2) else 0;
            const gap: i64 = light + 1; // double-line spacing
            const lines: []const i64 = if (weight == 3) &.{ -gap, gap } else &.{0};
            for (lines) |d| {
                switch (dir) {
                    0 => fillRect(cov, w, h, cx - off + d, 0, cx - off + d + t, cy + t, 255), // up
                    1 => fillRect(cov, w, h, cx, cy - off + d, W, cy - off + d + t, 255), // right
                    2 => fillRect(cov, w, h, cx - off + d, cy, cx - off + d + t, H, 255), // down
                    else => fillRect(cov, w, h, 0, cy - off + d, cx + t, cy - off + d + t, 255), // left
                }
            }
        }
        if (dashed) {
            // Punch gaps: horizontal dashes along x, vertical along y.
            const horizontal = spec[1] != 0;
            const n: i64 = if (horizontal) W else H;
            const seg = @max(2, @divFloor(n, 4));
            var i: i64 = 0;
            while (i < n) : (i += seg) {
                const g0 = i + seg - @max(1, @divFloor(seg, 3));
                const g1 = i + seg;
                if (horizontal) clearRect(cov, w, h, g0, 0, g1, H) else clearRect(cov, w, h, 0, g0, W, g1);
            }
        }
        return true;
    }
    switch (cp) {
        0x2588 => fillRect(cov, w, h, 0, 0, W, H, 255),
        0x2580 => fillRect(cov, w, h, 0, 0, W, @divFloor(H, 2), 255),
        0x2581...0x2587 => {
            const eighths: i64 = @as(i64, cp - 0x2580);
            fillRect(cov, w, h, 0, H - @divFloor(H * eighths, 8), W, H, 255);
        },
        0x2589...0x258F => {
            const eighths: i64 = 8 - @as(i64, cp - 0x2588);
            fillRect(cov, w, h, 0, 0, @divFloor(W * eighths, 8), H, 255);
        },
        0x2590 => fillRect(cov, w, h, @divFloor(W, 2), 0, W, H, 255),
        0x2591 => fillRect(cov, w, h, 0, 0, W, H, 64),
        0x2592 => fillRect(cov, w, h, 0, 0, W, H, 128),
        0x2593 => fillRect(cov, w, h, 0, 0, W, H, 192),
        0x2594 => fillRect(cov, w, h, 0, 0, W, @max(1, @divFloor(H, 8)), 255),
        0x2595 => fillRect(cov, w, h, W - @max(1, @divFloor(W, 8)), 0, W, H, 255),
        else => return false,
    }
    return true;
}

fn clearRect(cov: []u8, w: u32, h: u32, x0: i64, y0: i64, x1: i64, y1: i64) void {
    const ax: usize = @intCast(std.math.clamp(x0, 0, w));
    const bx: usize = @intCast(std.math.clamp(x1, 0, w));
    const ay: usize = @intCast(std.math.clamp(y0, 0, h));
    const by: usize = @intCast(std.math.clamp(y1, 0, h));
    var y = ay;
    while (y < by) : (y += 1) @memset(cov[y * w + ax .. y * w + @max(ax, bx)], 0);
}

test "font set renders glyphs, boxes and replacement" {
    const gpa = std.testing.allocator;
    var fs = FontSet.load(gpa, std.testing.io) catch return error.SkipZigTest;
    defer fs.deinit();
    const m = fs.metrics(16);
    try std.testing.expect(m.cell_w >= 6 and m.cell_w <= 12);
    try std.testing.expect(m.cell_h >= 14 and m.cell_h <= 24);
    const buf = try gpa.alloc(u8, 2 * m.cell_w * m.cell_h);
    defer gpa.free(buf);
    const one = buf[0 .. m.cell_w * m.cell_h];
    fs.render('A', .{}, m, 1, one);
    var ink: usize = 0;
    for (one) |v| ink += v;
    try std.testing.expect(ink > 1000);
    fs.render('A', .{ .bold = true }, m, 1, one);
    fs.render('A', .{ .italic = true }, m, 1, one);
    // Box drawing reaches the cell edges (so rows join).
    fs.render(0x2502, .{}, m, 1, one);
    try std.testing.expect(one[m.cell_w / 2 - 1] + one[m.cell_w / 2] > 0);
    try std.testing.expect(one[(m.cell_h - 1) * m.cell_w + m.cell_w / 2 - 1] + one[(m.cell_h - 1) * m.cell_w + m.cell_w / 2] > 0);
    // A private-use code point no font has: replacement box.
    fs.render(0x10FFFD, .{}, m, 1, one);
    ink = 0;
    for (one) |v| ink += @intFromBool(v > 0);
    try std.testing.expect(ink > 0);
    fs.render(0x4E2D, .{}, m, 2, buf); // wide, probably via fallback
    for ([_]u21{ 0x2550, 0x256C, 0x2591, 0x2581, 0x258F, 0x2504 }) |cp| fs.render(cp, .{}, m, 1, one);
}
