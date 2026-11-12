//! wl_data_device_manager / wl_data_device / wl_data_source / wl_data_offer
//! (core wayland.xml, version 3): the clipboard.
//!
//! LOCAL SHIM: ../Wayland does not bind these interfaces yet. Written the
//! same way as the package's own protocol files (interface tables checked
//! at compile time, typed opaque proxies) on its public CLIENT helpers, so
//! it can move into ../Wayland's wayland_protocol.zig unchanged. Listed for
//! the owner in CHANGES-portal-client.md.

const W = @import("Wayland");
const c = W.CLIENT;
const WL = W.WL;
const Argument = c.Argument;
const Fixed = c.Fixed;
const Interface = c.Interface;
const msg = c.msg;

pub const wl_data_device_manager_interface: Interface = .init("wl_data_device_manager", 3, &.{
    msg("create_data_source", "n", &.{&wl_data_source_interface}),
    msg("get_data_device", "no", &.{ &wl_data_device_interface, &WL.wl_seat_interface }),
}, &.{});

pub const wl_data_source_interface: Interface = .init("wl_data_source", 3, &.{
    msg("offer", "s", &.{null}),
    msg("destroy", "", &.{}),
    msg("set_actions", "3u", &.{null}),
}, &.{
    msg("target", "?s", &.{null}),
    msg("send", "sh", &.{ null, null }),
    msg("cancelled", "", &.{}),
    msg("dnd_drop_performed", "3", &.{}),
    msg("dnd_finished", "3", &.{}),
    msg("action", "3u", &.{null}),
});

pub const wl_data_offer_interface: Interface = .init("wl_data_offer", 3, &.{
    msg("accept", "u?s", &.{ null, null }),
    msg("receive", "sh", &.{ null, null }),
    msg("destroy", "", &.{}),
    msg("finish", "3", &.{}),
    msg("set_actions", "3uu", &.{ null, null }),
}, &.{
    msg("offer", "s", &.{null}),
    msg("source_actions", "3u", &.{null}),
    msg("action", "3u", &.{null}),
});

pub const wl_data_device_interface: Interface = .init("wl_data_device", 3, &.{
    msg("start_drag", "?oo?ou", &.{ &wl_data_source_interface, &WL.wl_surface_interface, &WL.wl_surface_interface, null }),
    msg("set_selection", "?ou", &.{ &wl_data_source_interface, null }),
    msg("release", "2", &.{}),
}, &.{
    msg("data_offer", "n", &.{&wl_data_offer_interface}),
    msg("enter", "uoff?o", &.{ null, &WL.wl_surface_interface, null, null, &wl_data_offer_interface }),
    msg("leave", "", &.{}),
    msg("motion", "uff", &.{ null, null, null }),
    msg("drop", "", &.{}),
    msg("selection", "?o", &.{&wl_data_offer_interface}),
});

pub const DataDeviceManager = opaque {
    pub const interface = wl_data_device_manager_interface;
    pub const Event = noreturn;

    pub fn createDataSource(self: *DataDeviceManager) error{OutOfMemory}!*DataSource {
        return c.requestNew(DataSource, self, 0, &.{Argument.new_id});
    }
    pub fn getDataDevice(self: *DataDeviceManager, seat: *WL.Seat) error{OutOfMemory}!*DataDevice {
        return c.requestNew(DataDevice, self, 1, &.{ Argument.new_id, .object(seat) });
    }
    pub fn destroy(self: *DataDeviceManager) void {
        c.destroyProxy(self);
    }
};

pub const DataSource = opaque {
    pub const interface = wl_data_source_interface;

    pub const Event = union(enum) {
        target: struct { mime_type: ?[*:0]const u8 },
        /// Write the data as `mime_type` to `fd`, then close it.
        send: struct { mime_type: [*:0]const u8, fd: i32 },
        /// Another client took the selection: destroy this source.
        cancelled,
        dnd_drop_performed,
        dnd_finished,
        action: struct { action: u32 },
    };
    pub fn decodeEvent(opcode: u32, a: [*]Argument) ?Event {
        return switch (opcode) {
            0 => .{ .target = .{ .mime_type = a[0].s } },
            1 => .{ .send = .{ .mime_type = a[0].s.?, .fd = a[1].h } },
            2 => .cancelled,
            3 => .dnd_drop_performed,
            4 => .dnd_finished,
            5 => .{ .action = .{ .action = a[0].u } },
            else => null,
        };
    }
    pub fn setListener(self: *DataSource, comptime Data: type, comptime cb: fn (*DataSource, Event, Data) void, data: Data) void {
        c.setListener(DataSource, self, Data, cb, data);
    }
    pub fn offer(self: *DataSource, mime_type: [*:0]const u8) void {
        c.request(self, 0, &.{.string(mime_type)});
    }
    pub fn destroy(self: *DataSource) void {
        c.requestDestroy(self, 1, &.{});
    }
};

pub const DataOffer = opaque {
    pub const interface = wl_data_offer_interface;

    pub const Event = union(enum) {
        offer: struct { mime_type: [*:0]const u8 },
        source_actions: struct { actions: u32 },
        action: struct { action: u32 },
    };
    pub fn decodeEvent(opcode: u32, a: [*]Argument) ?Event {
        return switch (opcode) {
            0 => .{ .offer = .{ .mime_type = a[0].s.? } },
            1 => .{ .source_actions = .{ .actions = a[0].u } },
            2 => .{ .action = .{ .action = a[0].u } },
            else => null,
        };
    }
    pub fn setListener(self: *DataOffer, comptime Data: type, comptime cb: fn (*DataOffer, Event, Data) void, data: Data) void {
        c.setListener(DataOffer, self, Data, cb, data);
    }
    /// The source writes the data to `fd` (the write end of a pipe; close
    /// your copy after the request is flushed).
    pub fn receive(self: *DataOffer, mime_type: [*:0]const u8, fd: i32) void {
        c.request(self, 1, &.{ .string(mime_type), .fd(fd) });
    }
    pub fn destroy(self: *DataOffer) void {
        c.requestDestroy(self, 2, &.{});
    }
};

pub const DataDevice = opaque {
    pub const interface = wl_data_device_interface;

    pub const Event = union(enum) {
        /// A new offer; its mime types follow as `DataOffer` `offer` events.
        data_offer: struct { id: ?*DataOffer },
        enter: struct { serial: u32, surface: ?*WL.Surface, x: Fixed, y: Fixed, id: ?*DataOffer },
        leave,
        motion: struct { time: u32, x: Fixed, y: Fixed },
        drop,
        /// The clipboard offer (null: the clipboard is empty).
        selection: struct { id: ?*DataOffer },
    };
    pub fn decodeEvent(opcode: u32, a: [*]Argument) ?Event {
        return switch (opcode) {
            0 => .{ .data_offer = .{ .id = c.argObject(DataOffer, a[0]) } },
            1 => .{ .enter = .{ .serial = a[0].u, .surface = c.argObject(WL.Surface, a[1]), .x = a[2].f, .y = a[3].f, .id = c.argObject(DataOffer, a[4]) } },
            2 => .leave,
            3 => .{ .motion = .{ .time = a[0].u, .x = a[1].f, .y = a[2].f } },
            4 => .drop,
            5 => .{ .selection = .{ .id = c.argObject(DataOffer, a[0]) } },
            else => null,
        };
    }
    pub fn setListener(self: *DataDevice, comptime Data: type, comptime cb: fn (*DataDevice, Event, Data) void, data: Data) void {
        c.setListener(DataDevice, self, Data, cb, data);
    }
    /// `serial`: of the input event that caused this (key press, click).
    pub fn setSelection(self: *DataDevice, source: ?*DataSource, serial: u32) void {
        c.request(self, 1, &.{ .object(source), .uint(serial) });
    }
    pub fn release(self: *DataDevice) void {
        if (c.version(self) >= 2) c.requestDestroy(self, 2, &.{}) else c.destroyProxy(self);
    }
};
