//! iOS window backend (UIKit through the Objective-C runtime, in the style
//! of the macOS backend on ../MacOS; runtime types from ../MacOS, symbol
//! binding in ios_objc.zig). Surface: the CAMetalLayer of a UIView subclass
//! (+layerClass), for VK_EXT_metal_surface on MoltenVK.
//!
//! Inverted control
//! ----------------
//! UIApplicationMain owns the main thread and never returns; desktops run
//! the app's own loop (`while (pollEvent) ...; draw; waitEvents`). Instead of
//! turning the shared app into callbacks, the loop runs unchanged on an
//! **app thread**:
//!
//!   main thread (UIKit)                    app thread (shared app code)
//!   runApp -> UIApplicationMain            entry(ctx): Window.init, the
//!   scene connects: UIWindow, Metal view,  same pollEvent / draw /
//!     start the app thread  ------------>  waitEvents loop as on desktops
//!   touches, layout, keyboard, lifecycle
//!     -> push Event, signal  ------------>  waitEvents wakes
//!   UI changes (text field, cover) <-----  dispatch_async to the main queue
//!
//! Vulkan (MoltenVK) may present to a CAMetalLayer from any thread, so the
//! renderer runs on the app thread as on every other platform. Every UIKit
//! call happens on the main thread: the app thread only records what it
//! wants (text field rect/text) and posts one coalesced main-queue
//! dispatch. `wake()` from any thread signals the app thread's condition
//! variable directly (the waiter is the app thread, so no main-queue hop is
//! needed); `waitEvents` blocks on that condition (pthread_cond_wait, or a
//! relative timed wait for a deadline). No timers, no polling.
//!
//! Background: on sceneDidEnterBackground the main thread pushes
//! `.background` and waits (at most 2 s) until the app thread has taken it
//! from the queue, i.e. finished any frame in flight; the app must not draw
//! until `.foreground` (iOS terminates apps that use the GPU in the
//! background).
//!
//! Privacy (AppOptions, off by default): third-party keyboards refused,
//! an opaque cover over the UI while inactive (before the app-switcher
//! snapshot) and while the screen is captured, and a lock that keeps the
//! cover after a background trip until the app calls `unlock()`.
//!
//! Text input: a UITextView placed over the UI's input slot
//! (showTextInput), so the system keyboard, autocorrect and dictation
//! work; changes and Return arrive as `.text_input` events and the text is
//! read with textInputText. The keyboard's behaviour (smart punctuation,
//! capitals, appearance, Return key) is TextField.traits.
//!
//! STATUS: compile-checked by cross-compilation (aarch64-ios objects) only;
//! links and runs only with the iOS SDK on a Mac (frameworks UIKit,
//! QuartzCore, Foundation, libobjc). Never run.

const std = @import("std");
const root = @import("root.zig");
pub const objc = @import("IosObjC");

const Object = objc.Object;
const Class = objc.Class;
const Selector = objc.Selector;
const BOOL = objc.BOOL;
const CGFloat = objc.CGFloat;
const CGRect = objc.CGRect;
const CGPoint = objc.CGPoint;
const CGSize = objc.CGSize;
const msgSend = objc.msgSend;
const sel = objc.sel;
const Event = root.Event;

// UIKit (link with -framework UIKit).
extern fn UIApplicationMain(argc: c_int, argv: ?[*]?[*:0]u8, principal: ?*Object, delegate: ?*Object) c_int;
extern const UIKeyboardWillChangeFrameNotification: ?*Object;
extern const UIKeyboardFrameEndUserInfoKey: ?*Object;
extern const UIScreenCapturedDidChangeNotification: ?*Object;
extern const UIApplicationKeyboardExtensionPointIdentifier: ?*Object;

// libSystem.
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *?[*]?[*:0]u8;
extern "c" fn pthread_cond_timedwait_relative_np(cond: *std.c.pthread_cond_t, mutex: *std.c.pthread_mutex_t, rel: *const std.c.timespec) c_int;

const app_delegate_name = "RendererAppDelegate";
const scene_delegate_name = "RendererSceneDelegate";
const view_class_name = "RendererMetalView";
const text_delegate_name = "RendererTextDelegate";

/// Longest native text field content kept (bytes).
const max_text = 4096;
/// Longest lock message kept (bytes).
const max_lock_msg = 512;

// ------------------------------------------------------------ the state

/// One app, one scene, one window: the backend state is a singleton shared
/// by the main thread (UIKit callbacks) and the app thread (Window API).
/// `mutex` guards the fields marked (m).
const State = struct {
    mutex: std.c.pthread_mutex_t = .{},
    /// Signalled when an event is pushed or wake() is called.
    cond: std.c.pthread_cond_t = .{},
    /// Signalled when the app thread took `.background`.
    ack_cond: std.c.pthread_cond_t = .{},
    queue: root.Queue = .{}, // (m)
    woken: bool = false, // (m)
    background_taken: bool = true, // (m)

    options: root.AppOptions = .{},
    entry: ?root.EntryFn = null,
    entry_ctx: ?*anyopaque = null,
    started: bool = false,
    ready: std.atomic.Value(bool) = .init(false),

    // Main thread only.
    window: ?*Object = null,
    view: ?*Object = null,
    layer: ?*Object = null,
    cover: ?*Object = null,
    text_view: ?*Object = null,
    text_delegate: ?*Object = null,
    inactive: bool = false,
    captured: bool = false,
    locked: bool = false,
    /// The unlock handler was already asked during this activation cycle
    /// (cleared on didEnterBackground): becoming active again (e.g. after
    /// the Face ID sheet closes with a cancel) does not ask again; a tap
    /// on the cover does.
    prompted: bool = false,
    /// The lock message on the cover (a UILabel), shown while locked.
    lock_label: ?*Object = null,
    touch: ?*Object = null,
    touch_last: CGPoint = .{},
    /// The scene's last interface orientation (UIInterfaceOrientation):
    /// a change cancels the touch in flight, including a 180 degree turn
    /// that leaves the size and insets as they were.
    orientation: objc.NSInteger = 0,
    /// The keyboard's end frame in screen coordinates, from the last
    /// keyboard-frame notification (null before the first). updateGeometry
    /// measures it against the view's bounds at that moment, so a
    /// notification that arrives mid-rotation (old bounds) is corrected by
    /// the layout pass that follows.
    kb_frame: ?CGRect = null,

    // Geometry (m): written on the main thread, read by the app thread.
    width: u32 = 0,
    height: u32 = 0,
    content_scale: f32 = 1,
    insets: root.Insets = .{},

    // Native text field (m). `want_*` is what the app thread asked for;
    // the main thread applies it in applyUi.
    want_shown: bool = false,
    want_field: root.TextField = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// A focus request not yet applied (m). Set by showTextInput when the
    /// field asks for focus and cleared only once the main thread made it
    /// first responder, so a request that is true for one frame is never
    /// lost to a later frame that no longer asks (applyUi coalesces).
    focus_pending: bool = false,
    want_text_gen: u64 = 0,
    applied_text_gen: u64 = 0,
    /// The traits last set on the text view (main thread only).
    applied_traits: ?root.TextTraits = null,
    text_buf: [max_text]u8 = undefined,
    text_len: usize = 0,
    ui_posted: std.atomic.Value(bool) = .init(false),

    window_handle: Window = .{},
    /// Main thread: the app's handler for "the lock wants lifting" (e.g.
    /// ask for Face ID): called when the app becomes active while locked
    /// and when the cover is tapped.
    unlock_request: ?*const fn () void = null,
    /// The lock message (m): AppOptions.lock_message, then setLockMessage.
    lock_msg_buf: [max_lock_msg]u8 = undefined,
    lock_msg_len: usize = 0,

    fn lock(s: *State) void {
        _ = std.c.pthread_mutex_lock(&s.mutex);
    }
    fn unlock(s: *State) void {
        _ = std.c.pthread_mutex_unlock(&s.mutex);
    }

    /// Main thread: queue an event for the app thread and wake it.
    fn push(s: *State, e: Event) void {
        s.lock();
        s.queue.push(e);
        _ = std.c.pthread_cond_signal(&s.cond);
        s.unlock();
    }
};

var state: State = .{};

// ------------------------------------------------------------- runApp

/// See root.runApp. Main thread; never returns.
pub fn runApp(options: root.AppOptions, entry: root.EntryFn, ctx: ?*anyopaque) noreturn {
    state.options = options;
    // Before UIApplicationMain: the scene's first updateCover and first
    // didBecomeActive already see the lock.
    state.locked = options.start_locked;
    storeLockMessage(options.lock_message);
    state.entry = entry;
    state.entry_ctx = ctx;
    const pool = objc.AutoreleasePool.push();
    _ = appDelegateClass();
    _ = sceneDelegateClass();
    _ = viewClass();
    const name = objc.newString(app_delegate_name);
    pool.pop();
    _ = UIApplicationMain(_NSGetArgc().*, _NSGetArgv().*, null, name);
    std.c.exit(0);
}

/// pthread directly (std.Thread.spawn would do too, but keeping std's
/// thread code out lets the Renderer's iOS check build without the
/// patched Zig lib; see ios_check.zig).
fn startAppThread() void {
    var attr: std.c.pthread_attr_t = undefined;
    _ = std.c.pthread_attr_init(&attr);
    _ = std.c.pthread_attr_setstacksize(&attr, 16 << 20);
    var t: std.c.pthread_t = undefined;
    if (std.c.pthread_create(&t, &attr, appThread, null) != .SUCCESS) @panic("cannot start the app thread");
    _ = std.c.pthread_detach(t);
}

fn appThread(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    const pool = objc.AutoreleasePool.push();
    if (state.entry) |f| f(state.entry_ctx);
    pool.pop();
    std.c.exit(0);
}

// --------------------------------------------------------- Window (API)

/// Handle returned by init; all state lives in the singleton above.
pub const Window = struct {
    gpa: ?std.mem.Allocator = null,
    live_ctx: ?*anyopaque = null,
    live_fn: ?root.LiveFn = null,

    /// App thread (inside runApp's entry). Title and size are ignored: the
    /// window is the whole screen.
    pub fn init(gpa: std.mem.Allocator, title: []const u8, width: u32, height: u32) !*Window {
        _ = title;
        _ = width;
        _ = height;
        if (!state.ready.load(.acquire)) return error.NotRunningUnderRunApp;
        state.window_handle.gpa = gpa;
        return &state.window_handle;
    }

    /// The UIWindow lives as long as the process (iOS apps do not close
    /// their window); nothing to free.
    pub fn deinit(self: *Window) void {
        _ = self;
    }

    /// Never fires: iOS has no modal resize loop.
    pub fn setLiveCallback(self: *Window, ctx: *anyopaque, f: root.LiveFn) void {
        self.live_ctx = ctx;
        self.live_fn = f;
    }

    pub fn pollEvent(self: *Window) ?Event {
        _ = self;
        state.lock();
        defer state.unlock();
        const e = state.queue.pop() orelse return null;
        if (e == .background) {
            state.background_taken = true;
            _ = std.c.pthread_cond_broadcast(&state.ack_cond);
        }
        return e;
    }

    pub fn pollQueued(self: *Window) ?Event {
        return self.pollEvent();
    }

    /// Blocks on the condition variable until an event, wake() or the
    /// timeout.
    pub fn waitEvents(self: *Window, timeout_ms: u32) void {
        _ = self;
        state.lock();
        defer state.unlock();
        if (!state.queue.pending() and !state.woken and timeout_ms != 0) {
            if (timeout_ms == root.forever) {
                while (!state.queue.pending() and !state.woken)
                    _ = std.c.pthread_cond_wait(&state.cond, &state.mutex);
            } else {
                const rel: std.c.timespec = .{
                    .sec = @intCast(timeout_ms / 1000),
                    .nsec = @intCast(@as(u64, timeout_ms % 1000) * std.time.ns_per_ms),
                };
                // One timed wait; a spurious wake-up just returns early
                // (the caller's loop re-evaluates its deadline).
                _ = pthread_cond_timedwait_relative_np(&state.cond, &state.mutex, &rel);
            }
        }
        state.woken = false;
    }

    /// Any thread. Coalesced: one pending wake ends one waitEvents.
    pub fn wake(self: *Window) void {
        _ = self;
        state.lock();
        state.woken = true;
        _ = std.c.pthread_cond_signal(&state.cond);
        state.unlock();
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        _ = self;
        state.lock();
        defer state.unlock();
        return .{ state.width, state.height };
    }

    /// UIKit content scale (2.0 or 3.0 on iPhones).
    pub fn scale(self: *const Window) f32 {
        _ = self;
        state.lock();
        defer state.unlock();
        return state.content_scale;
    }

    pub fn surfaceSource(self: *const Window) root.SurfaceSource {
        _ = self;
        return .{ .metal = .{ .layer = @ptrCast(state.layer.?) } };
    }

    /// iOS windows have no title.
    pub fn setTitle(self: *Window, title: []const u8) void {
        _ = self;
        _ = title;
    }

    /// Nothing to unmap on iOS (the process ends instead).
    pub fn hide(self: *Window) void {
        _ = self;
    }

    // ---------------------------------------------------------- clipboard

    pub fn clipboardText(self: *Window, gpa: std.mem.Allocator, max_units: usize) ?[]u8 {
        _ = self;
        var job: ClipJob = .{ .gpa = gpa, .max_units = max_units };
        objc.onMainSync(&job, ClipJob.read);
        return job.out;
    }

    pub fn setClipboardText(self: *Window, utf8: []const u8) bool {
        _ = self;
        var job: ClipJob = .{ .text = utf8 };
        objc.onMainSync(&job, ClipJob.write);
        return job.ok;
    }

    // ------------------------------------------------------ touch extras

    pub fn insets(self: *const Window) root.Insets {
        _ = self;
        state.lock();
        defer state.unlock();
        return state.insets;
    }

    /// Shows (or moves) the native text field; the keyboard comes up when
    /// it first appears. Cheap to call every frame: nothing is posted to
    /// the main thread unless the field changed.
    pub fn showTextInput(self: *Window, field: root.TextField) bool {
        _ = self;
        state.lock();
        const changed = !state.want_shown or !std.meta.eql(state.want_field, field) or (field.focus and !state.focus_pending);
        if (field.focus) state.focus_pending = true;
        state.want_shown = true;
        state.want_field = field;
        state.unlock();
        if (changed) postUi();
        return true;
    }

    pub fn hideTextInput(self: *Window) void {
        _ = self;
        state.lock();
        const changed = state.want_shown;
        state.want_shown = false;
        state.focus_pending = false;
        state.unlock();
        if (changed) postUi();
    }

    pub fn textInputText(self: *Window, buf: []u8) []const u8 {
        _ = self;
        state.lock();
        defer state.unlock();
        const n = @min(buf.len, state.text_len);
        @memcpy(buf[0..n], state.text_buf[0..n]);
        return buf[0..utf8Prefix(buf[0..n])];
    }

    pub fn setTextInputText(self: *Window, utf8: []const u8) void {
        _ = self;
        state.lock();
        const n = utf8Prefix(utf8[0..@min(utf8.len, max_text)]);
        @memcpy(state.text_buf[0..n], utf8[0..n]);
        state.text_len = n;
        state.want_text_gen += 1;
        state.unlock();
        postUi();
    }
};

const utf8Prefix = root.utf8Prefix;

// ---------------------------------------------- extras for the iOS app

/// Main thread: the Metal view (UIView), e.g. to add a camera preview
/// layer on top. Null before the scene connected.
pub fn rootView() ?*Object {
    return state.view;
}

/// Any thread: lifts the lock cover set by `lock_after_background` (call
/// after the user authenticated). The cover stays while the app is
/// inactive or the screen is captured.
pub fn unlock() void {
    objc.onMainAsync(null, struct {
        fn f(_: ?*anyopaque) callconv(.c) void {
            state.locked = false;
            updateCover();
            postUi();
        }
    }.f);
}

/// Any thread: covers the UI until `unlock()` (e.g. at launch, before the
/// first authentication).
pub fn lock() void {
    objc.onMainAsync(null, struct {
        fn f(_: ?*anyopaque) callconv(.c) void {
            state.locked = true;
            updateCover();
        }
    }.f);
}

/// Sets what lifts the lock (`lock_after_background`, `start_locked`,
/// `lock()`): called on the main thread the first time the app becomes
/// active while locked in each activation cycle (once after launch, once
/// after each return from the background; not again when e.g. the Face ID
/// sheet closes with a cancel) and on every tap on the cover. The
/// handler calls `unlock()` once the user is authenticated. Set it before
/// runApp.
pub fn setUnlockHandler(f: ?*const fn () void) void {
    state.unlock_request = f;
}

/// Any thread: the text on the lock cover (e.g. "Face ID is off for this
/// app: ..."), replacing AppOptions.lock_message. Longer text is cut at
/// 512 bytes (at a UTF-8 boundary).
pub fn setLockMessage(text: []const u8) void {
    storeLockMessage(text);
    objc.onMainAsync(null, struct {
        fn f(_: ?*anyopaque) callconv(.c) void {
            applyLockMessage();
        }
    }.f);
}

fn storeLockMessage(text: []const u8) void {
    var n = @min(text.len, max_lock_msg);
    // Do not cut a UTF-8 sequence (newString refuses invalid UTF-8).
    if (n < text.len) {
        while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    }
    state.lock();
    defer state.unlock();
    @memcpy(state.lock_msg_buf[0..n], text[0..n]);
    state.lock_msg_len = n;
}

/// Main thread: the stored lock message into the cover's label.
fn applyLockMessage() void {
    const label = state.lock_label orelse return;
    var buf: [max_lock_msg]u8 = undefined;
    state.lock();
    const n = state.lock_msg_len;
    @memcpy(buf[0..n], state.lock_msg_buf[0..n]);
    state.unlock();
    const s = objc.newString(buf[0..n]);
    defer if (s) |x| objc.release(x);
    msgSend(void, label, sel("setText:"), .{s});
}

/// Any thread: queue an event for the app thread (e.g. a scanned QR code
/// arrived; the app reads its own state on the next loop).
pub fn postEvent(e: Event) void {
    state.push(e);
}

// ------------------------------------------------------- main-thread UI

fn postUi() void {
    if (state.ui_posted.swap(true, .acq_rel)) return;
    objc.onMainAsync(null, applyUi);
}

/// Main thread: brings the text field in line with what the app asked.
fn applyUi(_: ?*anyopaque) callconv(.c) void {
    state.ui_posted.store(false, .release);
    const view = state.view orelse return;
    state.lock();
    const shown = state.want_shown;
    const field = state.want_field;
    const s = state.content_scale;
    const gen = state.want_text_gen;
    const focus = state.focus_pending;
    var tmp: [max_text]u8 = undefined;
    const n = state.text_len;
    @memcpy(tmp[0..n], state.text_buf[0..n]);
    state.unlock();

    if (!shown) {
        if (state.text_view) |tv| {
            _ = msgSend(BOOL, tv, sel("resignFirstResponder"), .{});
            msgSend(void, tv, sel("setHidden:"), .{objc.YES});
        }
        return;
    }
    const tv = state.text_view orelse makeTextView(view) orelse return;
    const k: CGFloat = if (s > 0) s else 1;
    msgSend(void, tv, sel("setFrame:"), .{CGRect.init(@as(CGFloat, field.x) / k, @as(CGFloat, field.y) / k, @as(CGFloat, field.w) / k, @as(CGFloat, field.h) / k)});
    msgSend(void, tv, sel("setTextColor:"), .{objc.color(field.fg)});
    msgSend(void, tv, sel("setBackgroundColor:"), .{objc.color(field.bg)});
    const pt: CGFloat = if (field.font_px > 0) @as(CGFloat, field.font_px) / k else 17;
    const font = msgSend(?*Object, objc.getClass("UIFont"), sel("monospacedSystemFontOfSize:weight:"), .{ pt, @as(CGFloat, 0) });
    msgSend(void, tv, sel("setFont:"), .{font});
    if (state.applied_traits == null or !std.meta.eql(state.applied_traits.?, field.traits)) {
        state.applied_traits = field.traits;
        applyTraits(tv, field.traits);
    }
    if (gen != state.applied_text_gen) {
        state.applied_text_gen = gen;
        const str = objc.newString(tmp[0..n]);
        defer if (str) |x| objc.release(x);
        msgSend(void, tv, sel("setText:"), .{str});
    }
    msgSend(void, tv, sel("setHidden:"), .{objc.NO});
    // Locked or inactive: the request stays pending; unlock() and
    // didBecomeActive post applyUi again.
    if (focus and !state.locked and !state.inactive) {
        _ = msgSend(BOOL, tv, sel("becomeFirstResponder"), .{});
        state.lock();
        state.focus_pending = false;
        state.unlock();
    }
}

fn makeTextView(view: *Object) ?*Object {
    const a = msgSend(?*Object, objc.getClass("UITextView"), sel("alloc"), .{}) orelse return null;
    const tv = msgSend(?*Object, a, sel("initWithFrame:"), .{CGRect{}}) orelse return null;
    const del = msgSend(?*Object, textDelegateClass(), sel("new"), .{});
    state.text_delegate = del;
    msgSend(void, tv, sel("setDelegate:"), .{del});
    msgSend(void, view, sel("addSubview:"), .{tv});
    state.text_view = tv;
    return tv;
}

/// Sets the text view's input traits (UITextInputTraits). The enums carry
/// UIKit's raw values. Called when they change; a keyboard that is already
/// up picks the new ones up on reloadInputViews.
fn applyTraits(tv: *Object, t: root.TextTraits) void {
    msgSend(void, tv, sel("setSmartQuotesType:"), .{@as(objc.NSInteger, @backingInt(t.smart_quotes))});
    msgSend(void, tv, sel("setSmartDashesType:"), .{@as(objc.NSInteger, @backingInt(t.smart_dashes))});
    msgSend(void, tv, sel("setSmartInsertDeleteType:"), .{@as(objc.NSInteger, @backingInt(t.smart_insert_delete))});
    msgSend(void, tv, sel("setAutocapitalizationType:"), .{@as(objc.NSInteger, @backingInt(t.capitalization))});
    msgSend(void, tv, sel("setKeyboardAppearance:"), .{@as(objc.NSInteger, @backingInt(t.keyboard_appearance))});
    msgSend(void, tv, sel("setReturnKeyType:"), .{@as(objc.NSInteger, @backingInt(t.return_key))});
    if (msgSend(BOOL, tv, sel("isFirstResponder"), .{}) == objc.YES) msgSend(void, tv, sel("reloadInputViews"), .{});
}

fn makeCover(window: *Object) void {
    const a = msgSend(?*Object, objc.getClass("UIView"), sel("alloc"), .{}) orelse return;
    const v = msgSend(?*Object, a, sel("initWithFrame:"), .{msgSend(CGRect, window, sel("bounds"), .{})}) orelse return;
    msgSend(void, v, sel("setBackgroundColor:"), .{objc.color(state.options.cover_rgb)});
    // UIViewAutoresizingFlexibleWidth | FlexibleHeight.
    msgSend(void, v, sel("setAutoresizingMask:"), .{@as(objc.NSUInteger, 2 | 16)});
    msgSend(void, v, sel("setHidden:"), .{objc.YES});
    // Taps on the cover go to the app's unlock handler (setUnlockHandler).
    if (msgSend(?*Object, objc.getClass("UITapGestureRecognizer"), sel("alloc"), .{})) |ga| {
        const target = msgSend(?*Object, sceneDelegateClass(), sel("new"), .{});
        if (msgSend(?*Object, ga, sel("initWithTarget:action:"), .{ target, sel("coverTapped:") })) |g|
            msgSend(void, v, sel("addGestureRecognizer:"), .{g});
    }
    // The lock message: centred, wrapping, 24 pt side margins.
    if (msgSend(?*Object, objc.getClass("UILabel"), sel("alloc"), .{})) |la| {
        const b = msgSend(CGRect, v, sel("bounds"), .{});
        const margin: CGFloat = 24;
        const r: CGRect = .{ .origin = .{ .x = margin, .y = 0 }, .size = .{ .width = @max(0, b.size.width - 2 * margin), .height = b.size.height } };
        if (msgSend(?*Object, la, sel("initWithFrame:"), .{r})) |label| {
            msgSend(void, label, sel("setAutoresizingMask:"), .{@as(objc.NSUInteger, 2 | 16)});
            msgSend(void, label, sel("setNumberOfLines:"), .{@as(objc.NSInteger, 0)});
            msgSend(void, label, sel("setTextAlignment:"), .{@as(objc.NSInteger, 1)}); // NSTextAlignmentCenter (iOS)
            msgSend(void, label, sel("setTextColor:"), .{objc.color(state.options.lock_text_rgb)});
            msgSend(void, label, sel("setFont:"), .{msgSend(?*Object, objc.getClass("UIFont"), sel("systemFontOfSize:"), .{@as(CGFloat, 17)})});
            msgSend(void, label, sel("setHidden:"), .{objc.YES});
            msgSend(void, v, sel("addSubview:"), .{label});
            state.lock_label = label;
            applyLockMessage();
        }
    }
    msgSend(void, window, sel("addSubview:"), .{v});
    state.cover = v;
}

/// Main thread: cover up while inactive (option), captured (option) or
/// locked.
fn updateCover() void {
    const cover = state.cover orelse return;
    const o = state.options;
    const up = state.locked or (o.cover_when_inactive and state.inactive) or (o.cover_when_captured and state.captured);
    if (up) {
        if (state.window) |w| msgSend(void, w, sel("bringSubviewToFront:"), .{cover});
        if (state.text_view) |tv| _ = msgSend(BOOL, tv, sel("resignFirstResponder"), .{});
    }
    msgSend(void, cover, sel("setHidden:"), .{objc.toBOOL(!up)});
    if (state.lock_label) |l| msgSend(void, l, sel("setHidden:"), .{objc.toBOOL(!state.locked)});
}

fn mainScreen() ?*Object {
    return msgSend(?*Object, objc.getClass("UIScreen"), sel("mainScreen"), .{});
}

/// Main thread: size, scale, safe area and the keyboard's height from the
/// view's current bounds. Queues `.resize` / `.insets` (when `emit`) only
/// for what changed.
fn updateGeometry(emit: bool) void {
    const view = state.view orelse return;
    const b = msgSend(CGRect, view, sel("bounds"), .{});
    const k = msgSend(CGFloat, view, sel("contentScaleFactor"), .{});
    const w: u32 = @intFromFloat(@max(0, @round(b.size.width * k)));
    const h: u32 = @intFromFloat(@max(0, @round(b.size.height * k)));
    if (state.layer) |layer| {
        msgSend(void, layer, sel("setContentsScale:"), .{k});
        msgSend(void, layer, sel("setDrawableSize:"), .{CGSize{ .width = @floatFromInt(w), .height = @floatFromInt(h) }});
    }
    const safe = msgSend(objc.EdgeInsets, view, sel("safeAreaInsets"), .{});
    const kb: CGFloat = if (state.kb_frame) |f| keyboardCovered(view, b, f) else 0;
    state.lock();
    const resized = w != state.width or h != state.height;
    const old = state.insets;
    state.width = w;
    state.height = h;
    state.content_scale = @floatCast(k);
    state.insets.top = @floatCast(safe.top * k);
    state.insets.left = @floatCast(safe.left * k);
    state.insets.bottom = @floatCast(safe.bottom * k);
    state.insets.right = @floatCast(safe.right * k);
    state.insets.keyboard = @floatCast(kb * k);
    const inset_changed = !std.meta.eql(old, state.insets);
    if (emit) {
        if (resized) state.queue.push(.{ .resize = .{ .width = w, .height = h } });
        if (inset_changed) state.queue.push(.insets);
        if (resized or inset_changed) _ = std.c.pthread_cond_signal(&state.cond);
    }
    state.unlock();
}

/// Main thread: the height (points) of `view`, whose bounds are `b`, that
/// the keyboard at `screen_rect` (screen coordinates) covers from the
/// bottom edge; 0 when it is off screen.
fn keyboardCovered(view: *Object, b: CGRect, screen_rect: CGRect) CGFloat {
    const space = if (mainScreen()) |scr| msgSend(?*Object, scr, sel("coordinateSpace"), .{}) else null;
    const r = if (space) |s|
        msgSend(CGRect, view, sel("convertRect:fromCoordinateSpace:"), .{ screen_rect, s })
    else
        msgSend(CGRect, view, sel("convertRect:fromView:"), .{ screen_rect, @as(?*Object, null) });
    if (r.size.width <= 0 or r.size.height <= 0) return 0;
    return std.math.clamp(b.origin.y + b.size.height - r.origin.y, 0, b.size.height);
}

/// Main thread: end the touch in flight without acting on it (a mouse_up
/// with `cancelled`, at its last position). Nothing when no touch is
/// down, so callers may overlap.
fn cancelTouch() void {
    if (state.touch == null) return;
    state.touch = null;
    const at = MetalView.px(state.touch_last);
    state.push(.{ .mouse_up = .{ .x = at[0], .y = at[1], .cancelled = true } });
}

// ----------------------------------------------------------- clipboard

const ClipJob = struct {
    gpa: std.mem.Allocator = undefined,
    max_units: usize = 0,
    out: ?[]u8 = null,
    text: []const u8 = "",
    ok: bool = false,

    fn read(ctx: ?*anyopaque) callconv(.c) void {
        const j: *ClipJob = @ptrCast(@alignCast(ctx.?));
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const pb = msgSend(?*Object, objc.getClass("UIPasteboard"), sel("generalPasteboard"), .{}) orelse return;
        const s = msgSend(?*Object, pb, sel("string"), .{}) orelse return;
        j.out = root.sanitizeClipboard(j.gpa, objc.stringBytes(s), j.max_units);
    }

    fn write(ctx: ?*anyopaque) callconv(.c) void {
        const j: *ClipJob = @ptrCast(@alignCast(ctx.?));
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const pb = msgSend(?*Object, objc.getClass("UIPasteboard"), sel("generalPasteboard"), .{}) orelse return;
        const s = objc.newString(j.text) orelse return;
        defer objc.release(s);
        msgSend(void, pb, sel("setString:"), .{s});
        j.ok = true;
    }
};

// ------------------------------------------------------- app delegate

const AppDelegate = struct {
    fn didFinishLaunching(_: *Object, _: *Selector, _: ?*Object, _: ?*Object) callconv(.c) BOOL {
        return objc.YES;
    }

    /// One scene configuration, our scene delegate (no storyboard).
    fn configurationForConnecting(_: *Object, _: *Selector, _: ?*Object, session: ?*Object, _: ?*Object) callconv(.c) ?*Object {
        const role = msgSend(?*Object, session, sel("role"), .{});
        const name = objc.newString("Default");
        defer if (name) |n| objc.release(n);
        const cfg = msgSend(?*Object, objc.getClass("UISceneConfiguration"), sel("configurationWithName:sessionRole:"), .{ name, role }) orelse return null;
        msgSend(void, cfg, sel("setDelegateClass:"), .{sceneDelegateClass()});
        return cfg;
    }

    /// Third-party keyboards: refused when the app asked.
    fn shouldAllowExtension(_: *Object, _: *Selector, _: ?*Object, ident: ?*Object) callconv(.c) BOOL {
        if (state.options.block_keyboard_extensions and objc.isEqualString(ident, UIApplicationKeyboardExtensionPointIdentifier))
            return objc.NO;
        return objc.YES;
    }
};

fn appDelegateClass() *Class {
    if (objc.lookUpClass(app_delegate_name)) |c| return c;
    const b = objc.ClassBuilder.begin(objc.getClass("UIResponder"), app_delegate_name) orelse return objc.lookUpClass(app_delegate_name).?;
    b.addProtocol("UIApplicationDelegate");
    b.addMethod("application:didFinishLaunchingWithOptions:", &AppDelegate.didFinishLaunching, "B@:@@");
    b.addMethod("application:configurationForConnectingSceneSession:options:", &AppDelegate.configurationForConnecting, "@@:@@@");
    b.addMethod("application:shouldAllowExtensionPointIdentifier:", &AppDelegate.shouldAllowExtension, "B@:@@");
    return b.register();
}

// ----------------------------------------------------- scene delegate

const SceneDelegate = struct {
    fn willConnect(self: *Object, _: *Selector, scene: ?*Object, _: ?*Object, _: ?*Object) callconv(.c) void {
        if (state.window != null) return; // one scene
        const wa = msgSend(?*Object, objc.getClass("UIWindow"), sel("alloc"), .{}) orelse return;
        const window = msgSend(?*Object, wa, sel("initWithWindowScene:"), .{scene}) orelse return;
        const vc = msgSend(?*Object, objc.getClass("UIViewController"), sel("new"), .{}) orelse return;
        const va = msgSend(?*Object, viewClass(), sel("alloc"), .{}) orelse return;
        const view = msgSend(?*Object, va, sel("initWithFrame:"), .{msgSend(CGRect, window, sel("bounds"), .{})}) orelse return;
        const k: CGFloat = if (mainScreen()) |scr| msgSend(CGFloat, scr, sel("scale"), .{}) else 2;
        msgSend(void, view, sel("setContentScaleFactor:"), .{k});
        msgSend(void, view, sel("setMultipleTouchEnabled:"), .{objc.NO});
        msgSend(void, vc, sel("setView:"), .{view});
        msgSend(void, window, sel("setRootViewController:"), .{vc});
        state.window = window;
        state.view = view;
        state.layer = msgSend(?*Object, view, sel("layer"), .{});
        makeCover(window);
        msgSend(void, window, sel("makeKeyAndVisible"), .{});

        const center = msgSend(?*Object, objc.getClass("NSNotificationCenter"), sel("defaultCenter"), .{});
        msgSend(void, center, sel("addObserver:selector:name:object:"), .{ self, sel("keyboardWillChange:"), UIKeyboardWillChangeFrameNotification, @as(?*Object, null) });
        msgSend(void, center, sel("addObserver:selector:name:object:"), .{ self, sel("capturedDidChange:"), UIScreenCapturedDidChangeNotification, @as(?*Object, null) });
        if (mainScreen()) |scr| state.captured = msgSend(BOOL, scr, sel("isCaptured"), .{}) != 0;
        updateCover();
        state.orientation = msgSend(objc.NSInteger, scene, sel("interfaceOrientation"), .{});
        updateGeometry(false);
        state.ready.store(true, .release);
        if (!state.started) {
            state.started = true;
            startAppThread();
        }
    }

    fn getWindow(_: *Object, _: *Selector) callconv(.c) ?*Object {
        return state.window;
    }
    fn setWindow(_: *Object, _: *Selector, _: ?*Object) callconv(.c) void {}

    fn didBecomeActive(_: *Object, _: *Selector, _: ?*Object) callconv(.c) void {
        state.inactive = false;
        updateCover();
        postUi();
        // At most once per activation cycle: the Face ID sheet itself
        // makes the scene resign and re-become active, so asking on every
        // activation would loop after a cancel (and race a success whose
        // unlock() is still on its way). After that, a tap on the cover.
        if (state.locked and !state.prompted) {
            if (state.unlock_request) |f| {
                state.prompted = true;
                f();
            }
        }
    }
    fn willResignActive(_: *Object, _: *Selector, _: ?*Object) callconv(.c) void {
        state.inactive = true;
        updateCover(); // before the app-switcher snapshot
    }
    fn didEnterBackground(_: *Object, _: *Selector, _: ?*Object) callconv(.c) void {
        if (state.options.lock_after_background) state.locked = true;
        state.prompted = false;
        updateCover();
        // Stop the app thread's drawing before returning: GPU use in the
        // background gets the app killed. Bounded wait, so a busy app
        // thread (or one waiting on the main queue) cannot hang UIKit.
        state.lock();
        state.background_taken = false;
        state.queue.push(.background);
        _ = std.c.pthread_cond_signal(&state.cond);
        const limit: std.c.timespec = .{ .sec = 2, .nsec = 0 };
        if (!state.background_taken) _ = pthread_cond_timedwait_relative_np(&state.ack_cond, &state.mutex, &limit);
        state.unlock();
    }
    fn willEnterForeground(_: *Object, _: *Selector, _: ?*Object) callconv(.c) void {
        state.push(.foreground);
    }

    /// The keyboard's end frame is kept in screen coordinates; the covered
    /// height is measured in updateGeometry against the bounds of the
    /// moment (and again by every layout pass, e.g. after a rotation).
    fn keyboardWillChange(_: *Object, _: *Selector, note: ?*Object) callconv(.c) void {
        const info = msgSend(?*Object, note, sel("userInfo"), .{});
        const value = msgSend(?*Object, info, sel("objectForKey:"), .{UIKeyboardFrameEndUserInfoKey}) orelse return;
        state.kb_frame = msgSend(CGRect, value, sel("CGRectValue"), .{});
        updateGeometry(true);
    }

    /// The interface orientation may have changed (both UIKit callbacks
    /// below land here; only a real change acts). A 90 degree turn also
    /// resizes, but a 180 degree one (landscape left <-> right) keeps the
    /// size and the insets, so it would otherwise send nothing: the touch
    /// in flight is cancelled (its coordinates no longer mean the same
    /// place) and `.expose` asks the app to lay out and draw again.
    fn orientationChanged(scene: ?*Object) void {
        const now = msgSend(objc.NSInteger, scene, sel("interfaceOrientation"), .{});
        if (now == state.orientation) return;
        state.orientation = now;
        cancelTouch();
        state.push(.expose);
    }

    /// windowScene:didUpdateCoordinateSpace:interfaceOrientation:traitCollection:
    /// (iOS 13 on; deprecated in iOS 26, which may call only the next one).
    fn didUpdateCoordinateSpace(_: *Object, _: *Selector, scene: ?*Object, _: ?*Object, _: objc.NSInteger, _: ?*Object) callconv(.c) void {
        orientationChanged(scene);
    }

    /// windowScene:didUpdateEffectiveGeometry: (iOS 26 on).
    fn didUpdateEffectiveGeometry(_: *Object, _: *Selector, scene: ?*Object, _: ?*Object) callconv(.c) void {
        orientationChanged(scene);
    }

    fn coverTapped(_: *Object, _: *Selector, _: ?*Object) callconv(.c) void {
        if (state.locked) if (state.unlock_request) |f| f();
    }

    fn capturedDidChange(_: *Object, _: *Selector, _: ?*Object) callconv(.c) void {
        if (mainScreen()) |scr| state.captured = msgSend(BOOL, scr, sel("isCaptured"), .{}) != 0;
        updateCover();
    }
};

fn sceneDelegateClass() *Class {
    if (objc.lookUpClass(scene_delegate_name)) |c| return c;
    const b = objc.ClassBuilder.begin(objc.getClass("UIResponder"), scene_delegate_name) orelse return objc.lookUpClass(scene_delegate_name).?;
    b.addProtocol("UIWindowSceneDelegate");
    b.addMethod("scene:willConnectToSession:options:", &SceneDelegate.willConnect, "v@:@@@");
    b.addMethod("window", &SceneDelegate.getWindow, "@@:");
    b.addMethod("setWindow:", &SceneDelegate.setWindow, "v@:@");
    b.addMethod("sceneDidBecomeActive:", &SceneDelegate.didBecomeActive, "v@:@");
    b.addMethod("sceneWillResignActive:", &SceneDelegate.willResignActive, "v@:@");
    b.addMethod("sceneDidEnterBackground:", &SceneDelegate.didEnterBackground, "v@:@");
    b.addMethod("sceneWillEnterForeground:", &SceneDelegate.willEnterForeground, "v@:@");
    b.addMethod("keyboardWillChange:", &SceneDelegate.keyboardWillChange, "v@:@");
    b.addMethod("windowScene:didUpdateCoordinateSpace:interfaceOrientation:traitCollection:", &SceneDelegate.didUpdateCoordinateSpace, "v@:@@q@");
    b.addMethod("windowScene:didUpdateEffectiveGeometry:", &SceneDelegate.didUpdateEffectiveGeometry, "v@:@@");
    b.addMethod("capturedDidChange:", &SceneDelegate.capturedDidChange, "v@:@");
    b.addMethod("coverTapped:", &SceneDelegate.coverTapped, "v@:@");
    return b.register();
}

// ---------------------------------------------------------- Metal view

const MetalView = struct {
    fn layerClass(_: *Class, _: *Selector) callconv(.c) ?*Class {
        return objc.getClass("CAMetalLayer");
    }

    fn layoutSubviews(self: *Object, cmd: *Selector) callconv(.c) void {
        _ = cmd;
        objc.msgSendSuper(void, self, objc.getClass("UIView"), sel("layoutSubviews"), .{});
        updateGeometry(true);
    }

    fn safeAreaInsetsDidChange(self: *Object, cmd: *Selector) callconv(.c) void {
        _ = cmd;
        objc.msgSendSuper(void, self, objc.getClass("UIView"), sel("safeAreaInsetsDidChange"), .{});
        updateGeometry(true);
    }

    fn point(touches: ?*Object) ?struct { touch: *Object, p: CGPoint } {
        const t = msgSend(?*Object, touches, sel("anyObject"), .{}) orelse return null;
        return .{ .touch = t, .p = msgSend(CGPoint, t, sel("locationInView:"), .{state.view}) };
    }

    fn px(p: CGPoint) [2]f32 {
        const k: CGFloat = state.content_scale;
        return .{ @floatCast(p.x * k), @floatCast(p.y * k) };
    }

    /// One finger is the pointer (the view takes one touch at a time):
    /// mouse_down where it lands, mouse_move (left held) as it moves,
    /// mouse_up where it lifts. What a drag means (scrolling, a swipe) and
    /// what a tap is (a release without moving) is the app's to decide.
    fn began(_: *Object, _: *Selector, touches: ?*Object, _: ?*Object) callconv(.c) void {
        if (state.touch != null) return;
        const t = point(touches) orelse return;
        state.touch = t.touch;
        state.touch_last = t.p;
        const at = px(t.p);
        state.push(.{ .mouse_down = .{ .x = at[0], .y = at[1] } });
    }

    fn moved(_: *Object, _: *Selector, touches: ?*Object, _: ?*Object) callconv(.c) void {
        const t = point(touches) orelse return;
        if (state.touch != t.touch) return;
        state.touch_last = t.p;
        const at = px(t.p);
        state.push(.{ .mouse_move = .{ .x = at[0], .y = at[1], .left_held = true } });
    }

    fn ended(_: *Object, _: *Selector, touches: ?*Object, _: ?*Object) callconv(.c) void {
        const t = point(touches) orelse return;
        if (state.touch != t.touch) return;
        state.touch = null;
        const at = px(t.p);
        state.push(.{ .mouse_up = .{ .x = at[0], .y = at[1] } });
    }

    /// The system took the touch (a gesture, a call): the press ends
    /// without acting on it.
    fn cancelled(_: *Object, _: *Selector, _: ?*Object, _: ?*Object) callconv(.c) void {
        cancelTouch();
    }
};

fn viewClass() *Class {
    if (objc.lookUpClass(view_class_name)) |c| return c;
    const b = objc.ClassBuilder.begin(objc.getClass("UIView"), view_class_name) orelse return objc.lookUpClass(view_class_name).?;
    b.addClassMethod("layerClass", &MetalView.layerClass, "#@:");
    b.addMethod("layoutSubviews", &MetalView.layoutSubviews, "v@:");
    b.addMethod("safeAreaInsetsDidChange", &MetalView.safeAreaInsetsDidChange, "v@:");
    b.addMethod("touchesBegan:withEvent:", &MetalView.began, "v@:@@");
    b.addMethod("touchesMoved:withEvent:", &MetalView.moved, "v@:@@");
    b.addMethod("touchesEnded:withEvent:", &MetalView.ended, "v@:@@");
    b.addMethod("touchesCancelled:withEvent:", &MetalView.cancelled, "v@:@@");
    return b.register();
}

// ------------------------------------------------- text view delegate

const TextDelegate = struct {
    /// Typing, paste, autocorrect and dictation all end up here.
    fn didChange(_: *Object, _: *Selector, tv: ?*Object) callconv(.c) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const text = objc.stringBytes(msgSend(?*Object, tv, sel("text"), .{}));
        const n = utf8Prefix(text[0..@min(text.len, max_text)]);
        state.lock();
        @memcpy(state.text_buf[0..n], text[0..n]);
        state.text_len = n;
        state.queue.push(.{ .text_input = .changed });
        _ = std.c.pthread_cond_signal(&state.cond);
        state.unlock();
    }

    /// Return submits instead of inserting a newline.
    fn shouldChange(_: *Object, _: *Selector, _: ?*Object, _: objc.Range, replacement: ?*Object) callconv(.c) BOOL {
        const r = objc.stringBytes(replacement);
        if (std.mem.eql(u8, r, "\n")) {
            state.push(.{ .text_input = .submit });
            return objc.NO;
        }
        return objc.YES;
    }
};

fn textDelegateClass() *Class {
    if (objc.lookUpClass(text_delegate_name)) |c| return c;
    const b = objc.ClassBuilder.begin(objc.getClass("NSObject"), text_delegate_name) orelse return objc.lookUpClass(text_delegate_name).?;
    b.addProtocol("UITextViewDelegate");
    b.addMethod("textViewDidChange:", &TextDelegate.didChange, "v@:@");
    b.addMethod("textView:shouldChangeTextInRange:replacementText:", &TextDelegate.shouldChange, "B@:@{_NSRange=QQ}@");
    return b.register();
}

comptime {
    // Analyse the iOS-only extras in compile checks too.
    _ = &rootView;
    _ = &unlock;
    _ = &lock;
    _ = &postEvent;
    _ = &setUnlockHandler;
    _ = &setLockMessage;
    _ = &runApp;
}
