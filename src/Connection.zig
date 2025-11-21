const Self = @This();

const std = @import("std");
const Io = std.Io;
const math = std.math;
const net = std.net;

const State = @import("State.zig");

server: ?net.Server,
stream: net.Stream,

writer: net.Stream.Writer,
reader: net.Stream.Reader,
write_buffer: [WRITE_BUFFER_SIZE]u8,
read_buffer: [READ_BUFFER_SIZE]u8,

dummy: bool = false,

const ADDRESS = net.Address.parseIp4("127.0.0.1", 5720) catch unreachable;

const WRITE_BUFFER_SIZE = 1024;
const READ_BUFFER_SIZE = 1024;

const ENDIAN = std.builtin.Endian.big;

pub fn newServer() !Self {
    const server = try ADDRESS.listen(.{});
    return Self{
        .server = server,
        .stream = undefined,
        .writer = undefined,
        .reader = undefined,
        .write_buffer = undefined,
        .read_buffer = undefined,
    };
}

pub fn newClient() Self {
    return Self{
        .server = null,
        .stream = undefined,
        .writer = undefined,
        .reader = undefined,
        .write_buffer = undefined,
        .read_buffer = undefined,
    };
}

pub fn init(self: *Self) !void {
    if (self.dummy) {
        return;
    }

    self.stream = if (self.server) |*server|
        (try server.accept()).stream
    else
        try net.tcpConnectToAddress(ADDRESS);

    self.writer = self.stream.writer(&self.write_buffer);
    self.reader = self.stream.reader(&self.read_buffer);
}

pub fn deinit(self: *Self) void {
    if (self.dummy) {
        return;
    }

    self.stream.close();
    if (self.server) |*server| {
        server.deinit();
    }
}

pub fn send(self: *Self, message: Message) !void {
    if (self.dummy) {
        return;
    }

    try self.writer.interface.print("{f}", .{message});
    try self.writer.interface.flush();
}

pub fn recv(self: *Self) !Message {
    if (self.dummy) {
        waitForever();
    }

    var reader = self.reader.interface();

    const discriminant = try reader.takeByte();
    switch (discriminant) {
        1 => {
            const count = try deserialize(u32, reader);
            return .{ .count = count };
        },

        2 => {
            const player = try deserialize(State.Player, reader);
            return .{ .player = player };
        },

        3 => {
            const update = try deserialize(Message.PieceUpdate, reader);
            return .{ .piece = update };
        },

        4 => {
            const status_discriminant = try deserialize(u8, reader);
            const status: State.Status = blk: switch (status_discriminant) {
                0 => {
                    const side = try deserialize(State.Side, reader);
                    break :blk .{ .play = side };
                },
                1 => {
                    const side = try deserialize(State.Side, reader);
                    break :blk .{ .win = side };
                },
                else => return error.Malformed,
            };

            return .{ .status = status };
        },

        else => return error.Malformed,
    }
}

// TODO: Move to new file
// TODO: Move deserialization to member function here
// TODO: Use functions for common ser/de (eg. Tile)
// TODO: Maybe dangerous using automatic enum discriminants
pub const Message = union(enum) {
    player: State.Player,
    piece: PieceUpdate,
    status: State.Status,

    // DEBUG
    count: u32,

    const PieceUpdate = struct {
        tile: State.Tile,
        piece: ?State.Piece,
    };

    pub fn format(
        self: *const Message,
        writer: *Io.Writer,
    ) Io.Writer.Error!void {
        switch (self.*) {
            .count => |count| {
                try serialize(u8, 1, writer);
                try serialize(u32, count, writer);
            },

            .player => |player| {
                try serialize(u8, 2, writer);
                try serialize(State.Player, player, writer);
            },

            .piece => |update| {
                try serialize(u8, 3, writer);
                try serialize(PieceUpdate, update, writer);
            },

            .status => |status| {
                try serialize(u8, 4, writer);
                switch (status) {
                    .play => |side| {
                        try serialize(u8, 0, writer);
                        try serialize(State.Side, side, writer);
                    },
                    .win => |side| {
                        try serialize(u8, 1, writer);
                        try serialize(State.Side, side, writer);
                    },
                }
            },
        }
    }
};

fn deserialize(comptime T: type, reader: *Io.Reader) !T {
    switch (@typeInfo(T)) {
        .int => {
            comptime std.debug.assert(!std.mem.eql(u8, @typeName(T), "usize"));
            const padded = try reader.takeInt(resizeIntToBytes(T), ENDIAN);
            return math.cast(T, padded) orelse {
                return error.Malformed;
            };
        },

        .@"enum" => |enm| {
            const int = try deserialize(enm.tag_type, reader);
            return std.meta.intToEnum(T, int) catch {
                return error.Malformed;
            };
        },

        .optional => |optional| {
            const discriminant = try deserialize(u8, reader);
            if (discriminant == 1) {
                const child_value = try deserialize(optional.child, reader);
                return child_value;
            } else if (discriminant == 0) {
                return null;
            } else {
                return error.Malformed;
            }
        },

        .@"struct" => |strct| {
            var value: T = undefined;
            inline for (strct.fields) |field| {
                const field_value = try deserialize(field.type, reader);
                @field(value, field.name) = field_value;
            }
            return value;
        },

        else => @compileError("deserialization is not supported for type `" ++ @typeName(T) ++ "`"),
    }
}

fn serialize(comptime T: type, value: T, writer: *Io.Writer) !void {
    switch (@typeInfo(T)) {
        .int => {
            comptime std.debug.assert(!std.mem.eql(u8, @typeName(T), "usize"));
            try writer.writeInt(resizeIntToBytes(T), value, ENDIAN);
        },

        .@"enum" => {
            const int = @intFromEnum(value);
            try serialize(@TypeOf(int), int, writer);
        },

        .optional => |optional| {
            if (value) |value_child| {
                try serialize(u8, 1, writer);
                try serialize(optional.child, value_child, writer);
            } else {
                try serialize(u8, 0, writer);
            }
        },

        .@"struct" => |strct| {
            inline for (strct.fields) |field| {
                const field_value = @field(value, field.name);
                try serialize(@TypeOf(field_value), field_value, writer);
            }
        },

        else => @compileError("serialization is not supported for type `" ++ @typeName(T) ++ "`"),
    }
}

fn resizeIntToBytes(comptime T: type) type {
    const int = @typeInfo(T).int;
    const bits = 8 * (math.divCeil(u16, int.bits, 8) catch unreachable);
    return @Type(std.builtin.Type{ .int = .{
        .bits = bits,
        .signedness = int.signedness,
    } });
}

fn getIntOfSize(comptime T: type) type {
    return @Type(std.builtin.Type{ .int = .{
        .bits = @bitSizeOf(T),
        .signedness = .unsigned,
    } });
}

fn waitForever() noreturn {
    var mutex = std.Thread.Mutex{};
    mutex.lock();
    defer mutex.unlock();
    var condition = std.Thread.Condition{};
    condition.wait(&mutex);
    unreachable;
}
