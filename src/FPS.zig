const std = @import("std");

const Config = struct {
    interval_ms: i64 = 17,
    io: std.Io,
};

frames: u64 = 0,
accumulated: std.Io.Duration = .{ .nanoseconds = 0 },
fps: f64 = 0.0,
interval_ns: i96,
prev: std.Io.Timestamp = undefined,

pub fn init(config: Config) @This() {
    return .{
        .interval_ns = @as(i96, config.interval_ms) * std.time.ns_per_ms,
        .prev = std.Io.Clock.awake.now(config.io),
    };
}

pub fn tick(self: *@This(), delta: std.Io.Duration) bool {
    self.frames += 1;
    self.accumulated.nanoseconds = delta.nanoseconds;
    if (self.accumulated.nanoseconds >= self.interval_ns) {
        const secs = @as(f64, @floatFromInt(self.accumulated.nanoseconds)) / 1e9;
        self.fps = @as(f64, @floatFromInt(self.frames)) / secs;
        self.frames = 0;
        self.accumulated.nanoseconds = 0;
        return true;
    }
    return false;
}

pub fn update(self: *@This(), io: std.Io) f64 {
    const now: std.Io.Timestamp = std.Io.Clock.awake.now(io);
    const delta: std.Io.Duration = self.prev.durationTo(now);
    self.prev = now;
    _ = self.tick(delta);
    return self.fps;
}
