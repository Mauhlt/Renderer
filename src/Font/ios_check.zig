//! Compile check (`zig build check-window`): the Font module's system font
//! set built for aarch64-ios, so its CoreText lookup (fontset.zig,
//! dlopen'd at run time) is analysed on the target that uses it. An object
//! only; the panic handler is replaced for the reason given in
//! src/Window/ios_check.zig.

const std = @import("std");
const Font = @import("root.zig");

export fn fontCheckIosLoad() bool {
    var fs = Font.fontset.FontSet.load(std.heap.c_allocator, ioForCheck()) catch {
        return Font.fontset.triedPaths().len != 0;
    };
    fs.deinit();
    return true;
}

/// A placeholder Io: the check only needs FontSet.load analysed, never run.
fn ioForCheck() std.Io {
    return undefined;
}

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        _ = msg;
        std.c.abort();
    }
}.f);
