const std = @import("std");
const win = @import("Windows");
const utf8ToUtf16 = std.unicode.utf8ToUtf16LeStringLiteral;
const Windows = @This();

instance: win.HINSTANCE = .null,
title: [*:0]const u16,
hwnd: win.HWND = .null,
msg: win.MSG = undefined,

pub fn init(
    comptime name: []const u8,
    comptime title: []const u8,
    width: u32,
    height: u32,
) !Windows {
    const instance = win.GetModuleHandleW(null);
    // wide strings
    const class_name = utf8ToUtf16(name);
    const window_title = utf8ToUtf16(title);
    // icons + cursors
    const icon = win.LoadIconW(.null, utf8ToUtf16("IDI_APPLICATION"));
    const cursor = win.LoadCursorW(.null, utf8ToUtf16("IDC_ARROW"));
    const WND_PROC = WndProc;
    var wc: win.WNDCLASSEXW = .{
        // .size = @sizeOf(@This()),
        .style = 0, // @as(u32, win.redraw.bits),
        .wnd_proc = WND_PROC,
        .cls_extra = 0,
        .wnd_extra = 0,
        .instance = instance,
        .icon = icon,
        .cursor = cursor,
        .brush = win.GetSysColorBrush(.window),
        .menu_name = null,
        .class_name = class_name,
        .small_icon = icon,
    };
    // register
    if (win.RegisterClassExW(&wc) == .null) //
        return error.FailedToRegisterClass;
    // HWND
    const hwnd = switch (win.CreateWindowExW(
        0,
        class_name,
        window_title,
        win.WindowStyle.overlapped_window,
        100,
        100,
        @intCast(width),
        @intCast(height),
        .null,
        .null,
        instance,
        .null,
    )) {
        .null => return error.FailedToCreateWindow,
        else => |value| value,
    };
    return .{
        .instance = instance,
        .title = window_title,
        .hwnd = hwnd,
    };
}

pub fn deinit(self: *Windows) void {
    _ = win.UnregisterClassW(
        self.title,
        self.instance,
    );
}

pub fn show(self: *const Windows) void {
    _ = win.ShowWindow(self.hwnd, .show);
}

const PM_REMOVE: u32 = 0x0001;
pub fn pollBlock() bool {
    var msg: win.MSG = undefined;
    switch (win.GetMessageW(&msg, .null, 0, 0)) {
        .false => return false,
        else => {},
    }
    switch (@as(win.Messages, msg.message)) {
        .nc_destroy, .quit => return false, // quit = thread message + never dispatch, nc destroy = window already destroyed
        .close, .destroy => {
            // dispatch so wndproc can cleanup (DestroyWindow / PostQuitMessage)
            _ = win.TranslateMessage(&msg);
            _ = win.DispatchMessageW(&msg);
            return false;
        },
        else => {},
        _ => {},
    }
    _ = win.TranslateMessage(&msg);
    _ = win.DispatchMessageW(&msg);
    return true;
}

pub fn pollPeek() bool {
    var msg: win.MSG = undefined;
    while (true) {
        switch (win.PeekMessageW(&msg, .null, 0, 0, win.RemoveMessage.remove)) {
            .false => break,
            else => {},
        }
        switch (@as(win.Messages, @enumFromInt(msg.msg))) {
            .nc_destroy, .quit => return false,
            .destroy, .close => {
                _ = win.TranslateMessage(&msg);
                _ = win.DispatchMessageW(&msg);
                return false;
            },
            else => {},
            _ => {},
        }
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageW(&msg);
    }
    return true;
}

pub fn clientSize(self: *const Windows) struct { w: i32, h: i32 } {
    // drawable space
    var rect: win.RECT = undefined;
    _ = win.GetClientRect(self.hwnd, &rect);
    return .{
        .w = rect.right - rect.left,
        .h = rect.bot - rect.top,
    };
}

pub fn windowSize(self: *const Windows) struct { w: i32, h: i32 } {
    // full window size
    var rect: win.RECT = undefined;
    _ = win.GetWindowRect(self.hwnd, &rect);
    return .{
        .w = rect.right - rect.left,
        .h = rect.bottom - rect.top,
    };
}

const Event = union(win.Messages) {
    null,
    create,
    destroy,
    move,
    size,
    sizing,
    enable,
    close,
    quit,
    query_open,
    show_window,
    activate_app,
    cancel_mode,
    child_activate,
    get_min_max_info,
    query_drag_icon,
    compacting,
    window_pos_changing,
    window_pos_changed,
    input_lang_request_change,
    input_lang_change,
    user_changed,
    style_changing,
    style_changed,
    nc_create,
    nc_destroy,
    nc_calc_size,
    nc_activate,
    get_icon,
    moving,
    enter_size_move,
    exit_size_move,
    theme_changed,
    timer,
};

fn WndProc(
    hwnd: win.HWND,
    msg: u32,
    wParam: win.WPARAM,
    lParam: win.LPARAM,
) callconv(.winapi) win.LRESULT {
    switch (@as(win.Messages, @enumFromInt(msg))) {
        .close => {
            // immediate exit
            _ = win.DestroyWindow(hwnd);
            return .null;
        },
        .destroy => {
            // goes 1 last loop
            _ = win.PostQuitMessage(0);
            return .null;
        },
        .size => {
            // framebuffer_resized = true;
            return .null;
        },
        // .changing => { // continue polling },
        .enter_size_move => {
            _ = win.SetTimer(hwnd, 1, 16, null); // ~60fps during drag
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
            _ = win.KillTimer(hwnd, 1);
            // framebuffer_resized = true;
            return .null;
        },
        else => {
            return win.DefWindowProcW(hwnd, msg, wParam, lParam);
        }
    }
    // to access recreateSwapchain/drawFrame from inside wndproc -> use
    // _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @intCast(@intFromPtr(app_ptr))); when creating window
    // in wndproc, retrieve ptr: const app: *App = @ptrFromInt(@as(usize, @intCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))));
}

pub fn shouldClose(self: *Windows) bool {
    _ = win.PeekMessageW(&self.msg, .null, 0, 0, .remove);
    return switch (@as(win.Messages, @enumFromInt(self.msg.msg))) {
        .quit => true,
        else => false,
    };
}
