const std = @import("std");
const win = @import("Windows");
const utf8ToUtf16 = std.unicode.utf8ToUtf16LeStringLiteral;
const Windows = @This();

instance: win.TYPES.HINSTANCE = .null,
class_name: [*:0]const u16,
title: [*:0]const u16,
hwnd: win.TYPES.HWND = .null,
msg: win.STRUCTS.MSG = undefined,

pub fn init(
    comptime name: []const u8,
    comptime title: []const u8,
    width: u32,
    height: u32,
) !Windows {
    const instance = win.KERNEL.GetModuleHandleW(null);
    const dpi_awareness_context: win.ENUMS.DpiAwarenessContext = switch (@import("builtin").target.cpu.arch) {
        .aarch64, .aarch64_be => .per_monitor_aware_v2,
        .x86_64, .x86, .x86_16 => .unaware,
        else => unreachable,
    };
    if (!win.USER.SetProcessDpiAwarenessContext(dpi_awareness_context).toBool())
        std.debug.print("Set Process DPI Awareness Context Failed.\n", .{});
    // wide strings
    const class_name = utf8ToUtf16(name);
    const window_title = utf8ToUtf16(title);
    // icons + cursors
    const icon = win.USER.LoadIconW(.null, win.ENUMS.SystemIcon.application.nameW());
    const cursor = win.USER.LoadCursorW(.null, win.ENUMS.SystemCursor.arrow.nameW());
    const WND_PROC = WndProc;
    var wc: win.STRUCTS.WNDCLASSEXW = .{
        .style = .{}, // .redraw to repaint on resize
        .wnd_proc = WND_PROC,
        .cls_extra = 0,
        .wnd_extra = 0,
        .instance = instance,
        .icon = icon,
        .cursor = cursor,
        .brush = win.USER.GetSysColorBrush(.window),
        .menu_name = null,
        .class_name = class_name,
        .small_icon = icon,
    };
    // window register
    // register
    if (win.USER.RegisterClassExW(&wc) == .null) //
        return error.FailedToRegisterClass;
    // HWND
    const hwnd = switch (win.USER.CreateWindowExW(
        .{},
        class_name,
        window_title,
        win.ENUMS.WindowStyle.overlapped_window,
        100,
        100,
        @intCast(width),
        @intCast(height),
        .null,
        .null,
        instance,
        null,
    )) {
        .null => return error.FailedToCreateWindow,
        else => |value| value,
    };
    return .{
        .instance = instance,
        .class_name = class_name,
        .title = window_title,
        .hwnd = hwnd,
    };
}

pub fn deinit(self: *Windows) void {
    _ = win.USER.DestroyWindow(self.hwnd); // fails harmlessly if already destroyed
    _ = win.USER.UnregisterClassW(
        self.class_name,
        self.instance,
    );
}

pub fn show(self: *const Windows) void {
    _ = win.USER.ShowWindow(self.hwnd, .show);
}

const PM_REMOVE: u32 = 0x0001;
pub fn pollBlock() bool {
    var msg: win.STRUCTS.MSG = undefined;
    // 0 = WM_QUIT, -1 = error
    if (win.USER.GetMessageW(&msg, .null, 0, 0) <= 0) return false;
    switch (@as(win.ENUMS.Messages, @enumFromInt(msg.msg))) {
        .nc_destroy, .quit => return false, // quit = thread message + never dispatch, nc destroy = window already destroyed
        .close, .destroy => {
            // dispatch so wndproc can cleanup (DestroyWindow / PostQuitMessage)
            _ = win.USER.TranslateMessage(&msg);
            _ = win.USER.DispatchMessageW(&msg);
            return false;
        },
        else => {},
    }
    _ = win.USER.TranslateMessage(&msg);
    _ = win.USER.DispatchMessageW(&msg);
    return true;
}

pub fn pollPeek() bool {
    var msg: win.STRUCTS.MSG = undefined;
    while (win.USER.PeekMessageW(&msg, .null, 0, 0, .remove).toBool()) {
        switch (@as(win.ENUMS.Messages, @enumFromInt(msg.msg))) {
            .nc_destroy, .quit => {
                // win.USER.PostQuitMessage(0);
                return false;
            },
            .destroy, .close => {
                _ = win.USER.TranslateMessage(&msg);
                _ = win.USER.DispatchMessageW(&msg);
                return false;
            },
            else => {},
        }
        _ = win.USER.TranslateMessage(&msg);
        _ = win.USER.DispatchMessageW(&msg);
    }
    return true;
}

pub fn clientSize(self: *const Windows) struct { w: i32, h: i32 } {
    // drawable space
    var rect: win.STRUCTS.RECT = undefined;
    _ = win.USER.GetClientRect(self.hwnd, &rect);
    return .{ .w = rect.width(), .h = rect.height() };
}

pub fn windowSize(self: *const Windows) struct { w: i32, h: i32 } {
    // full window size
    var rect: win.STRUCTS.RECT = undefined;
    _ = win.USER.GetWindowRect(self.hwnd, &rect);
    return .{ .w = rect.width(), .h = rect.height() };
}

fn WndProc(
    hwnd: win.TYPES.HWND,
    msg: u32,
    wParam: win.TYPES.WPARAM,
    lParam: win.TYPES.LPARAM,
) callconv(.winapi) win.TYPES.LRESULT {
    switch (@as(win.ENUMS.Messages, @enumFromInt(msg))) {
        .close => {
            // immediate exit
            _ = win.USER.DestroyWindow(hwnd);
            return .null;
        },
        .destroy => {
            // goes 1 last loop
            win.USER.PostQuitMessage(0);
            return .null;
        },
        .size => {
            // framebuffer_resized = true;
            return .null;
        },
        // .changing => { // continue polling },
        .enter_size_move => {
            _ = win.USER.SetTimer(hwnd, 1, 16, null); // ~60fps during drag
            return .null;
        },
        // .timer => {
        //     // if (framebuffer_resized) {
        //     //     framebuffer_resized = true;
        //     //     recreateSwapchain() catch {};
        //     // }
        //     // drawFrame() catch {};
        //     // return .null;
        // },
        .exit_size_move => {
            _ = win.USER.KillTimer(hwnd, 1);
            // framebuffer_resized = true;
            return .null;
        },
        else => {
            return win.USER.DefWindowProcW(hwnd, msg, wParam, lParam);
        }
    }
    // to access recreateSwapchain/drawFrame from inside wndproc -> use
    // win.USER.setUserData(hwnd, app_ptr); when creating window
    // in wndproc, retrieve ptr: const app = win.USER.getUserData(App, hwnd).?;
}

pub fn shouldClose(self: *Windows) bool {
    _ = win.USER.PeekMessageW(&self.msg, .null, 0, 0, .remove);
    return switch (@as(win.ENUMS.Messages, @enumFromInt(self.msg.msg))) {
        .quit => true,
        else => false,
    };
}
