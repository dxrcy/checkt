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

const ADDRESS = net.Address.parseIp4("127.0.0.1", 5720) catch unreachable;

const WRITE_BUFFER_SIZE = 1024;
const READ_BUFFER_SIZE = 1024;

const ENDIAN = std.builtin.Endian.big;

pub fn connectServer() !Self {
    var server = try ADDRESS.listen(.{});
    std.log.info("waiting for client to join...\n", .{});
    const connection = try server.accept();
    return Self{
        .server = server,
        .stream = connection.stream,
        .writer = undefined,
        .reader = undefined,
        .write_buffer = undefined,
        .read_buffer = undefined,
    };
}

pub fn connectClient() !Self {
    const stream = try net.tcpConnectToAddress(ADDRESS);
    return Self{
        .server = null,
        .stream = stream,
        .writer = undefined,
        .reader = undefined,
        .write_buffer = undefined,
        .read_buffer = undefined,
    };
}

pub fn init(self: *Self) void {
    self.writer = self.stream.writer(&self.write_buffer);
    self.reader = self.stream.reader(&self.read_buffer);
}

pub fn deinit(self: *Self) void {
    self.stream.close();
    if (self.server) |*server| {
        server.deinit();
    }
}

pub fn send(self: *Self, message: Message) !void {
    try self.writer.interface.print("{f}", .{message});
    try self.writer.interface.flush();
}

pub fn recv(self: *Self) !Message {
    var reader = self.reader.interface();

    const discriminant = try reader.takeByte();
    switch (discriminant) {
        1 => {
            const count = try reader.takeInt(u32, ENDIAN);
            return .{ .count = count };
        },

        2 => {
            const focus_rank = try reader.takeInt(u32, ENDIAN);
            const focus_file = try reader.takeInt(u32, ENDIAN);

            const selected_set = try reader.takeByte() != 0;
            const selected_rank = try reader.takeInt(u32, ENDIAN);
            const selected_file = try reader.takeInt(u32, ENDIAN);

            const player = State.Player{
                .focus = .{ .rank = focus_rank, .file = focus_file },
                .selected = if (selected_set)
                    .{ .rank = selected_rank, .file = selected_file }
                else
                    null,
            };

            return .{ .player = player };
        },

        else => return error.InvalidMessage,
    }
}

// TODO: Move to new file
// TODO: Move deserialization to member function here
pub const Message = union(enum) {
    player: State.Player,

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
                try writer.writeInt(u32, @intCast(player.focus.rank), ENDIAN);
                try writer.writeInt(u32, @intCast(player.focus.file), ENDIAN);
                if (player.selected) |selected| {
                    try writer.writeByte(1);
                    try writer.writeInt(u32, @intCast(selected.rank), ENDIAN);
                    try writer.writeInt(u32, @intCast(selected.file), ENDIAN);
                } else {
                    try writer.writeByte(0);
                    try writer.writeInt(u32, 0, ENDIAN);
                    try writer.writeInt(u32, 0, ENDIAN);
                }
            },
        }
    }
};
