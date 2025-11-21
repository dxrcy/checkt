const Self = @This();

const std = @import("std");
const net = std.net;

const State = @import("State.zig");
const serde = @import("serde.zig");

server: ?net.Server,
port: u16,
stream: net.Stream,

writer: net.Stream.Writer,
reader: net.Stream.Reader,
write_buffer: [WRITE_BUFFER_SIZE]u8,
read_buffer: [READ_BUFFER_SIZE]u8,

dummy: bool = false,

const START_ADDRESS = net.Address.parseIp4("127.0.0.1", 5100) catch unreachable;
const PORT_RANGE = 400;

const WRITE_BUFFER_SIZE = 1024;
const READ_BUFFER_SIZE = 1024;

const InitError =
    net.Server.AcceptError ||
    net.TcpConnectToAddressError;

pub fn newServer() !Self {
    const server = try createServer() orelse {
        return error.NoAvailablePort;
    };
    return Self{
        .server = server,
        .port = server.listen_address.getPort(),
        .stream = undefined,
        .writer = undefined,
        .reader = undefined,
        .write_buffer = undefined,
        .read_buffer = undefined,
    };
}

pub fn newClient(port: u16) Self {
    return Self{
        .server = null,
        .port = port,
        .stream = undefined,
        .writer = undefined,
        .reader = undefined,
        .write_buffer = undefined,
        .read_buffer = undefined,
    };
}

fn createServer() !?net.Server {
    for (0..PORT_RANGE) |i| {
        var addr = START_ADDRESS;
        addr.setPort(START_ADDRESS.getPort() + @as(u16, @intCast(i)));
        return addr.listen(.{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => |err2| return err2,
        };
    }
    return null;
}

pub fn init(self: *Self) InitError!void {
    if (self.dummy) {
        return;
    }

    if (self.server) |*server| {
        const connection = try server.accept();
        self.stream = connection.stream;
    } else {
        var addr = START_ADDRESS;
        addr.setPort(self.port);
        self.stream = try net.tcpConnectToAddress(addr);
    }

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
