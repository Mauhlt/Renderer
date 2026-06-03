const std = @import("std");

pub const Event = union(enum) {
    resize: struct { w: u32, h: u32 },
    close,
    timer,
};
