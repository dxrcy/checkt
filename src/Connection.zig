const Self = @This();

const std = @import("std");
const net = std.net;

const State = @import("State.zig");
const serde = @import("serde.zig");

server: ?net.Server,
stream: net.Stream,

writer: net.Stream.Writer,
reader: net.Stream.Reader,
write_buffer: [WRITE_BUFFER_SIZE]u8,
read_buffer: [READ_BUFFER_SIZE]u8,

dummy: bool = false,

const ADDRESS = net.Address.parseIp4("127.0.0.1", 5721) catch unreachable;

const WRITE_BUFFER_SIZE = 1024;
const READ_BUFFER_SIZE = 1024;

const InitError =
    net.Server.AcceptError ||
    net.TcpConnectToAddressError;

pub fn newServer() net.Address.ListenError!Self {
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

pub fn init(self: *Self) InitError!void {
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

pub fn send(self: *Self, message: Message) serde.SerError!void {
    if (self.dummy) {
        return;
    }

    try serde.serialize(Message, message, &self.writer.interface);
    try self.writer.interface.flush();
}

pub fn recv(self: *Self) serde.DeError!Message {
    if (self.dummy) {
        waitForever();
    }

    return try serde.deserialize(Message, self.reader.interface());
}

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
};

fn waitForever() noreturn {
    var mutex = std.Thread.Mutex{};
    mutex.lock();
    defer mutex.unlock();
    var condition = std.Thread.Condition{};
    condition.wait(&mutex);
    unreachable;
}
