//! `zig build window-smoke`: opens a Window on this machine and checks the
//! runtime behaviour that a compile check cannot: the window maps, a Vulkan
//! surface + swapchain come up and present, wake() from another thread ends
//! a waitEvents(forever), a timed wait returns on time, the clipboard round
//! trips, and the title can change. Closes itself after ~2 s of events
//! (or when you close it). Exits non-zero on a failed check.

const std = @import("std");
const Window = @import("Window");
const Renderer = @import("Renderer");

fn waker(w: *Window.Window) void {
    w.wake();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var failed = false;

    const win = try Window.Window.init(gpa, "Window smoke test", 640, 400);
    defer win.deinit();
    var fb = win.framebufferSize();
    std.debug.print("window: {d}x{d} px, scale {d}\n", .{ fb[0], fb[1], win.scale() });
    const r = try Renderer.Instanced2D.init(gpa, win.surfaceSource(), fb[0], fb[1], .{ .app_name = "Window smoke" });
    defer r.deinit();
    try r.updateTexture(0, 0, 1, 1, &.{ 255, 255, 255, 255 });

    // wake() from another thread must end a wait with no timeout.
    {
        const t0 = std.Io.Timestamp.now(io, .awake);
        const th = try std.Thread.spawn(.{}, waker, .{win});
        // Drain what the OS queued at creation first, so the wait below
        // really sleeps until the wake.
        while (win.pollEvent()) |_| {}
        win.waitEvents(Window.forever);
        th.join();
        const ms = t0.untilNow(io, .awake).toMilliseconds();
        std.debug.print("wake: waitEvents(forever) returned after {d} ms\n", .{ms});
        if (ms > 2000) failed = true;
    }
    // A timed wait returns at its deadline when nothing happens (the first
    // rounds may end early on the window's own startup messages).
    for (0..4) |_| {
        var drained: u32 = 0;
        while (win.pollEvent()) |e| {
            drained += 1;
            std.debug.print("  queued: {t}\n", .{e});
        }
        const t0 = std.Io.Timestamp.now(io, .awake);
        win.waitEvents(150);
        const ms = t0.untilNow(io, .awake).toMilliseconds();
        std.debug.print("timed wait: waitEvents(150) returned after {d} ms ({d} events before)\n", .{ ms, drained });
        if (ms > 2000) failed = true;
    }
    // Clipboard round trip (the previous contents are restored).
    {
        const saved = win.clipboardText(gpa, 1 << 20);
        defer if (saved) |s| gpa.free(s);
        const text = "Window smoke \u{2713} \u{1F600}";
        const set = win.setClipboardText(text);
        const back = win.clipboardText(gpa, 1000);
        defer if (back) |b| gpa.free(b);
        const same = back != null and std.mem.eql(u8, back.?, text);
        std.debug.print("clipboard: set={} read back equal={}\n", .{ set, same });
        if (!set or !same) failed = true;
        if (saved) |s| _ = win.setClipboardText(s);
    }
    win.setTitle("Window smoke test: drawing (close me or wait 2 s)");

    var frames: u32 = 0;
    var events: u32 = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    loop: while (start.untilNow(io, .awake).toMilliseconds() < 2000) {
        while (win.pollEvent()) |e| {
            events += 1;
            switch (e) {
                .close => break :loop,
                .resize => |s| r.resize(s.width, s.height),
                .key, .char, .mouse_down, .scroll, .zoom => std.debug.print("event: {any}\n", .{e}),
                else => {},
            }
        }
        fb = win.framebufferSize();
        const w: f32 = @floatFromInt(fb[0]);
        const h: f32 = @floatFromInt(fb[1]);
        const k: f32 = @floatFromInt(frames % 60);
        try r.drawFrame(.{ 0.08, 0.09, 0.11, 1 }, &.{
            .{ .rect = .{ w * 0.1 + k * 4, h * 0.3, w * 0.3, h * 0.4 }, .uv = .{ 0, 0, 0, 0 }, .color = .{ 0x6C, 0xC0, 0x70, 255 } },
        });
        frames += 1;
        win.waitEvents(16); // a real deadline: animate for the test only
    }
    std.debug.print("presented {d} frames, {d} events\n", .{ frames, events });
    if (frames == 0) failed = true;
    win.hide();
    if (failed) {
        std.debug.print("window-smoke: FAILED\n", .{});
        std.process.exit(1);
    }
    std.debug.print("window-smoke: ok\n", .{});
}
