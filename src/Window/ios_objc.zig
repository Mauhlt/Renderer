//! Objective-C runtime for the iOS backend: libobjc linked directly
//! (extern), not dlopen'd.
//!
//! The owner's ../MacOS package has the same runtime layer for macOS
//! (OBJC.sel / getClass / msgSend / ClassBuilder), but its `OBJC.load()`
//! always opens AppKit, which does not exist on iOS, and its symbol table
//! is private, so its message-sending functions cannot run on an iPhone.
//! This file reuses MacOS's types and its comptime `MsgSendFn` signature
//! builder and supplies only the iOS-side symbol binding (see
//! CHANGES-ios.md, "Gaps in ../MacOS"). An iOS app links libobjc anyway
//! (`-lobjc`, with the iOS SDK), so the externs resolve at link time on the
//! Mac; on other hosts they compile into objects only.

const std = @import("std");
const Mac = @import("MacOS");
pub const OBJC = Mac.OBJC;
pub const TYPES = Mac.TYPES;

pub const Object = OBJC.Object;
pub const Class = OBJC.Class;
pub const Selector = OBJC.Selector;
pub const BOOL = OBJC.BOOL;
pub const YES = OBJC.YES;
pub const NO = OBJC.NO;
pub const toBOOL = OBJC.toBOOL;
pub const CGFloat = TYPES.CGFloat;
pub const CGPoint = TYPES.CGPoint;
pub const CGSize = TYPES.CGSize;
pub const CGRect = TYPES.CGRect;
pub const NSUInteger = TYPES.NSUInteger;
pub const NSInteger = TYPES.NSInteger;

/// UIEdgeInsets.
pub const EdgeInsets = extern struct { top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0 };
/// NSRange.
pub const Range = extern struct { location: NSUInteger, length: NSUInteger };

pub const Protocol = opaque {};

// libobjc (link with -lobjc).
extern fn objc_getClass(name: [*:0]const u8) ?*Class;
extern fn objc_getProtocol(name: [*:0]const u8) ?*Protocol;
extern fn objc_allocateClassPair(superclass: ?*Class, name: [*:0]const u8, extra: usize) ?*Class;
extern fn objc_registerClassPair(cls: *Class) void;
extern fn objc_msgSend() void;
extern fn objc_msgSendSuper() void;
extern fn objc_autoreleasePoolPush() ?*anyopaque;
extern fn objc_autoreleasePoolPop(token: ?*anyopaque) void;
extern fn sel_registerName(name: [*:0]const u8) ?*Selector;
extern fn class_addMethod(cls: *Class, name: *Selector, imp: OBJC.Imp, types: [*:0]const u8) BOOL;
extern fn class_addProtocol(cls: *Class, protocol: *Protocol) BOOL;
extern fn object_getClass(obj: ?*anyopaque) ?*Class;

/// Registered selector for `name`, cached after the first call.
pub fn sel(comptime name: [:0]const u8) *Selector {
    const Cache = struct {
        var value: std.atomic.Value(usize) = .init(0);
    };
    var v = Cache.value.load(.acquire);
    if (v == 0) {
        v = @intFromPtr(sel_registerName(name.ptr) orelse @panic("sel_registerName failed: " ++ name));
        Cache.value.store(v, .release);
    }
    return @ptrFromInt(v);
}

/// Class named `name` (null if no linked framework defines it).
pub fn lookUpClass(name: [*:0]const u8) ?*Class {
    return objc_getClass(name);
}

pub fn getClass(comptime name: [:0]const u8) *Class {
    return objc_getClass(name.ptr) orelse @panic("Objective-C class not found: " ++ name);
}

/// `[target selector args...]`, exact C signature from `Ret` and the
/// argument tuple (arm64: no _stret variant). Argument types must be
/// concrete.
pub fn msgSend(comptime Ret: type, target: anytype, selector: *Selector, args: anytype) Ret {
    const F = OBJC.MsgSendFn(Ret, @TypeOf(args));
    const f: *const F = @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ @as(?*Object, @ptrCast(target)), selector } ++ args);
}

/// struct objc_super.
const Super = extern struct { receiver: ?*Object, super_class: ?*Class };

/// `[super selector args...]` from a method of a class whose superclass is
/// `superclass`.
pub fn msgSendSuper(comptime Ret: type, self: *Object, superclass: *Class, selector: *Selector, args: anytype) Ret {
    var sup: Super = .{ .receiver = self, .super_class = superclass };
    const A = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const S = *Selector;
    const P = *Super;
    const F = switch (A.len) {
        0 => fn (P, S) callconv(.c) Ret,
        1 => fn (P, S, A[0]) callconv(.c) Ret,
        2 => fn (P, S, A[0], A[1]) callconv(.c) Ret,
        else => @compileError("msgSendSuper supports up to 2 arguments"),
    };
    const f: *const F = @ptrCast(&objc_msgSendSuper);
    return @call(.auto, f, .{ &sup, selector } ++ args);
}

pub fn retain(obj: anytype) @TypeOf(obj) {
    return @ptrCast(msgSend(?*Object, obj, sel("retain"), .{}));
}
pub fn release(obj: anytype) void {
    msgSend(void, obj, sel("release"), .{});
}

pub const AutoreleasePool = struct {
    token: ?*anyopaque,
    pub fn push() AutoreleasePool {
        return .{ .token = objc_autoreleasePoolPush() };
    }
    pub fn pop(self: AutoreleasePool) void {
        objc_autoreleasePoolPop(self.token);
    }
};

/// Builds a subclass at runtime (delegates, the Metal view).
pub const ClassBuilder = struct {
    class: *Class,

    /// Null if a class named `name` already exists.
    pub fn begin(superclass: *Class, name: [*:0]const u8) ?ClassBuilder {
        return .{ .class = objc_allocateClassPair(superclass, name, 0) orelse return null };
    }
    /// Instance method. `imp`: callconv(.c) fn (self, _cmd, args...).
    pub fn addMethod(self: ClassBuilder, comptime name: [:0]const u8, imp: anytype, types: [*:0]const u8) void {
        _ = class_addMethod(self.class, sel(name), @ptrCast(imp), types);
    }
    /// Class method (added to the metaclass), e.g. +layerClass.
    pub fn addClassMethod(self: ClassBuilder, comptime name: [:0]const u8, imp: anytype, types: [*:0]const u8) void {
        const meta = object_getClass(self.class) orelse return;
        _ = class_addMethod(meta, sel(name), @ptrCast(imp), types);
    }
    /// Declares conformance (some UIKit paths check conformsToProtocol:).
    pub fn addProtocol(self: ClassBuilder, name: [*:0]const u8) void {
        if (objc_getProtocol(name)) |p| _ = class_addProtocol(self.class, p);
    }
    pub fn register(self: ClassBuilder) *Class {
        objc_registerClassPair(self.class);
        return self.class;
    }
};

// ------------------------------------------------------------ strings

const NSUTF8StringEncoding: NSUInteger = 4;

/// A new (+1, caller releases) NSString from UTF-8 bytes; null for invalid
/// UTF-8.
pub fn newString(utf8: []const u8) ?*Object {
    const a = msgSend(?*Object, getClass("NSString"), sel("alloc"), .{}) orelse return null;
    return msgSend(?*Object, a, sel("initWithBytes:length:encoding:"), .{
        @as([*]const u8, utf8.ptr), @as(NSUInteger, utf8.len), NSUTF8StringEncoding,
    });
}

/// The UTF-8 bytes of an NSString (valid until the enclosing autorelease
/// pool drains).
pub fn stringBytes(s: ?*Object) []const u8 {
    const p = msgSend(?[*:0]const u8, s orelse return "", sel("UTF8String"), .{}) orelse return "";
    return std.mem.span(p);
}

pub fn isEqualString(a: ?*Object, b: ?*Object) bool {
    if (a == null or b == null) return false;
    return msgSend(BOOL, a, sel("isEqualToString:"), .{b}) != 0;
}

/// [UIColor colorWithRed:green:blue:alpha:] (autoreleased).
pub fn color(rgb: [3]u8) ?*Object {
    const c = struct {
        fn f(v: u8) CGFloat {
            return @as(CGFloat, @floatFromInt(v)) / 255.0;
        }
    }.f;
    return msgSend(?*Object, getClass("UIColor"), sel("colorWithRed:green:blue:alpha:"), .{ c(rgb[0]), c(rgb[1]), c(rgb[2]), @as(CGFloat, 1) });
}

// ------------------------------------------------------------- blocks

/// A global (non-capturing) Objective-C block literal, for completion
/// handlers (LocalAuthentication, AVFoundation, NetworkExtension).
/// `invoke` is a `callconv(.c) fn (*const Block, args...)`; state goes
/// through globals, since a global block captures nothing. Clang ABI: isa
/// = _NSConcreteGlobalBlock, flags = BLOCK_IS_GLOBAL; copying such a block
/// returns it unchanged, so one in static memory is valid for ever.
pub const Block = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const Descriptor,

    pub const Descriptor = extern struct { reserved: c_ulong = 0, size: c_ulong };
    pub const default_descriptor: Descriptor = .{ .size = @sizeOf(Block) };
    const BLOCK_IS_GLOBAL: c_int = 1 << 28;

    pub fn global(invoke: *const anyopaque) Block {
        return .{ .isa = @ptrCast(&_NSConcreteGlobalBlock), .flags = BLOCK_IS_GLOBAL, .invoke = invoke, .descriptor = &default_descriptor };
    }
};
extern var _NSConcreteGlobalBlock: [32]usize;

// ------------------------------------------------- main queue (libdispatch)

pub const DispatchFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;
extern "c" var _dispatch_main_q: u8;
extern "c" fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: DispatchFn) void;
extern "c" fn dispatch_sync_f(queue: *anyopaque, ctx: ?*anyopaque, work: DispatchFn) void;
extern "c" fn pthread_main_np() c_int;
extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) ?*anyopaque;

pub fn isMainThread() bool {
    return pthread_main_np() != 0;
}

/// Runs `work(ctx)` on the main thread later (any thread).
pub fn onMainAsync(ctx: ?*anyopaque, work: DispatchFn) void {
    dispatch_async_f(@ptrCast(&_dispatch_main_q), ctx, work);
}

/// The main dispatch queue (e.g. for delegate callbacks).
pub fn mainQueue() *anyopaque {
    return @ptrCast(&_dispatch_main_q);
}

/// Runs `work(ctx)` on a background queue (blocking work such as starting
/// a camera session).
pub fn onBackgroundAsync(ctx: ?*anyopaque, work: DispatchFn) void {
    const q = dispatch_get_global_queue(0, 0) orelse return work(ctx);
    dispatch_async_f(q, ctx, work);
}

/// Runs `work(ctx)` on the main thread and waits (inline when already on
/// it). Never call while holding a lock the main thread may take.
pub fn onMainSync(ctx: ?*anyopaque, work: DispatchFn) void {
    if (isMainThread()) return work(ctx);
    dispatch_sync_f(@ptrCast(&_dispatch_main_q), ctx, work);
}
