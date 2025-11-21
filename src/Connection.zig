const Self = @This();

const std = @import("std");
const Io = std.Io;
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

    // TODO: Handle malformed messages
    const discriminant = try reader.takeByte();
    switch (discriminant) {
        1 => {
            const count = try reader.takeInt(u32, ENDIAN);
            return .{ .count = count };
        },

        2 => {
            const focus_rank = try reader.takeInt(u16, ENDIAN);
            const focus_file = try reader.takeInt(u16, ENDIAN);

            const selected_set = try reader.takeByte() != 0;
            const selected_rank = try reader.takeInt(u16, ENDIAN);
            const selected_file = try reader.takeInt(u16, ENDIAN);

            return .{ .player = State.Player{
                .focus = .{ .rank = focus_rank, .file = focus_file },
                .selected = if (selected_set)
                    .{ .rank = selected_rank, .file = selected_file }
                else
                    null,
            } };
        },

        3 => {
            const tile_rank = try reader.takeInt(u16, ENDIAN);
            const tile_file = try reader.takeInt(u16, ENDIAN);

            const piece_set = try reader.takeByte() != 0;
            const piece_kind = try reader.takeInt(u8, ENDIAN);
            const piece_side = try reader.takeInt(u8, ENDIAN);

            return .{ .piece = .{
                .tile = .{ .rank = tile_rank, .file = tile_file },
                .piece = if (piece_set)
                    .{
                        .kind = @enumFromInt(piece_kind),
                        .side = @enumFromInt(piece_side),
                    }
                else
                    null,
            } };
        },

        4 => {
            const status_discriminant = try reader.takeByte();
            const status: State.Status = blk: switch (status_discriminant) {
                0 => {
                    const side = try reader.takeInt(u8, ENDIAN);
                    break :blk .{ .play = @enumFromInt(side) };
                },
                1 => {
                    const side = try reader.takeInt(u8, ENDIAN);
                    break :blk .{ .play = @enumFromInt(side) };
                },
                else => return error.InvalidMessage,
            };

            return .{ .status = status };
        },

        else => return error.InvalidMessage,
    }
}

// TODO: Move to new file
// TODO: Move deserialization to member function here
// TODO: Use functions for common ser/de (eg. Tile)
// TODO: Maybe dangerous using automatic enum discriminants
pub const Message = union(enum) {
    player: State.Player,
    piece: struct {
        tile: State.Tile,
        piece: ?State.Piece,
    },
    status: State.Status,

    // DEBUG
    count: u32,

    pub fn format(
        self: *const Message,
        writer: *Io.Writer,
    ) Io.Writer.Error!void {
        switch (self.*) {
            .count => |count| {
                try writer.writeByte(1);
                try writer.writeInt(u32, count, ENDIAN);
            },

            .player => |player| {
                try writer.writeByte(2);
                try writer.writeInt(u16, player.focus.rank, ENDIAN);
                try writer.writeInt(u16, player.focus.file, ENDIAN);
                if (player.selected) |selected| {
                    try writer.writeByte(1);
                    try writer.writeInt(u16, selected.rank, ENDIAN);
                    try writer.writeInt(u16, selected.file, ENDIAN);
                } else {
                    try writer.writeByte(0);
                    try writer.writeInt(u32, 0, ENDIAN);
                    try writer.writeInt(u32, 0, ENDIAN);
                }
            },

            .piece => |update| {
                try writer.writeByte(3);
                try writer.writeInt(u16, update.tile.rank, ENDIAN);
                try writer.writeInt(u16, update.tile.file, ENDIAN);
                if (update.piece) |piece| {
                    try writer.writeByte(1);
                    try writer.writeInt(u8, @intFromEnum(piece.kind), ENDIAN);
                    try writer.writeInt(u8, @intFromEnum(piece.side), ENDIAN);
                } else {
                    try writer.writeByte(0);
                    try writer.writeInt(u8, 0, ENDIAN);
                    try writer.writeInt(u8, 0, ENDIAN);
                }
            },

            .status => |status| {
                try writer.writeByte(4);
                switch (status) {
                    .play => |side| {
                        try writer.writeByte(0);
                        try writer.writeInt(u8, @intFromEnum(side), ENDIAN);
                    },
                    .win => |side| {
                        try writer.writeByte(1);
                        try writer.writeInt(u8, @intFromEnum(side), ENDIAN);
                    },
                }
            },
        }
    }
};

fn waitForever() noreturn {
    var mutex = std.Thread.Mutex{};
    mutex.lock();
    defer mutex.unlock();
    var condition = std.Thread.Condition{};
    condition.wait(&mutex);
    unreachable;
}
