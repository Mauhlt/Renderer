//! macOS key mapping (cocoa.zig), kept apart from AppKit so it is tested on
//! every host.

const std = @import("std");
const root = @import("root.zig");

const Event = root.Event;
const Mods = root.Mods;

/// The event for a key pressed with Command or Control held, from the
/// key's characters ignoring modifiers (`plain`: NSEvent
/// charactersIgnoringModifiers, where Shift still applies, so Ctrl+Shift+K
/// gives "K"). Null: nothing is sent.
///
///   * Command or Control with = + - 0: zoom.
///   * Command+Q / Command+W (with or without Shift): close (there is no
///     app menu). Control+Q / Control+W are letters like any other.
///   * A letter with Control or Command: the lowercase letter as `.char`
///     with the mods, the way every backend sends Ctrl+letter (A-Z too:
///     Ctrl+Shift+letter arrives uppercase here). What Command+letter
///     means is the app's choice.
///   * Control with [ \ ] space /: `.char` with the mods.
pub fn shortcut(plain: []const u8, mods: Mods) ?Event {
    if (!mods.super and !mods.ctrl) return null;
    if (plain.len != 1) return null;
    const c = plain[0];
    switch (c) {
        '=', '+' => return .{ .zoom = .in },
        '-' => return .{ .zoom = .out },
        '0' => return .{ .zoom = .reset },
        else => {},
    }
    const lower = std.ascii.toLower(c);
    if (mods.super and (lower == 'q' or lower == 'w')) return .close;
    return switch (c) {
        'a'...'z', 'A'...'Z' => .{ .char = .{ .cp = lower, .mods = mods } },
        '[', '\\', ']', ' ', '/' => if (mods.ctrl) .{ .char = .{ .cp = c, .mods = mods } } else null,
        else => null,
    };
}

const testing = std.testing;

fn expectChar(e: ?Event, cp: u21, mods: Mods) !void {
    const ev = e orelse return error.TestExpectedChar;
    try testing.expect(ev == .char);
    try testing.expectEqual(cp, ev.char.cp);
    try testing.expectEqual(mods, ev.char.mods);
}

test "Ctrl+letter: lowercase, Ctrl+Shift+letter too" {
    const ctrl: Mods = .{ .ctrl = true };
    const ctrl_shift: Mods = .{ .ctrl = true, .shift = true };
    try expectChar(shortcut("c", ctrl), 'c', ctrl);
    try expectChar(shortcut("K", ctrl_shift), 'k', ctrl_shift);
    try expectChar(shortcut("Z", ctrl_shift), 'z', ctrl_shift);
    // Ctrl+Q / Ctrl+W are letters, not a close.
    try expectChar(shortcut("q", ctrl), 'q', ctrl);
    try expectChar(shortcut("W", ctrl_shift), 'w', ctrl_shift);
    try expectChar(shortcut("[", ctrl), '[', ctrl);
    try expectChar(shortcut(" ", ctrl), ' ', ctrl);
}

test "Command+letter reaches the app as the lowercase letter with super" {
    const cmd: Mods = .{ .super = true };
    const cmd_shift: Mods = .{ .super = true, .shift = true };
    try expectChar(shortcut("c", cmd), 'c', cmd);
    try expectChar(shortcut("v", cmd), 'v', cmd);
    try expectChar(shortcut("V", cmd_shift), 'v', cmd_shift);
    // Punctuation with Command alone: nothing.
    try testing.expect(shortcut("[", cmd) == null);
    try testing.expect(shortcut("/", cmd) == null);
}

test "Command+Q / Command+W close; zoom with either modifier" {
    try testing.expect(shortcut("q", .{ .super = true }).? == .close);
    try testing.expect(shortcut("w", .{ .super = true }).? == .close);
    try testing.expect(shortcut("W", .{ .super = true, .shift = true }).? == .close);
    try testing.expect(shortcut("=", .{ .super = true }).?.zoom == .in);
    try testing.expect(shortcut("+", .{ .ctrl = true }).?.zoom == .in);
    try testing.expect(shortcut("-", .{ .super = true }).?.zoom == .out);
    try testing.expect(shortcut("0", .{ .ctrl = true }).?.zoom == .reset);
}

test "no Command or Control, or not one character: nothing" {
    try testing.expect(shortcut("c", .{}) == null);
    try testing.expect(shortcut("c", .{ .shift = true }) == null);
    try testing.expect(shortcut("", .{ .ctrl = true }) == null);
    try testing.expect(shortcut("ab", .{ .super = true }) == null);
    try testing.expect(shortcut("\u{e9}", .{ .ctrl = true }) == null);
    try testing.expect(shortcut("1", .{ .ctrl = true }) == null);
}
