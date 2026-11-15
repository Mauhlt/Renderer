//! Root of the aarch64-ios compile check (`zig build check-window`): the
//! Window module as an object, every backend method analysed through
//! checkInterface.
//!
//! The panic handler is replaced here only because std's default one
//! reaches std.Io.Threaded, which does not compile for iOS in Zig
//! 0.18.0-dev.4 (Threaded.getDevNullFd reads `null_file.fd`, a field its
//! iOS NullFile lacks). Real iOS apps build against a copy of the Zig lib
//! with that one line fixed (the app's own iOS build prepares it), so they
//! keep the default panic handler.

const std = @import("std");

comptime {
    _ = @import("Window");
}

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        _ = msg;
        std.c.abort();
    }
}.f);
