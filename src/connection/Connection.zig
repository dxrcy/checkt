const Self = @This();

const std = @import("std");
const net = std.net;

const Message = @import("../game/Game.zig").Message;

const serde = @import("serde.zig");

const START_ADDRESS = net.Address.parseIp4("127.0.0.1", 5100) catch unreachable;
const PORT_RANGE = 400;

const WRITE_BUFFER_SIZE = 1024;
const READ_BUFFER_SIZE = 1024;

// TODO: Use union for fields

/// `true` if then connection is not created, and methods are no-ops.
local: bool,

/// `null` if acting as a client.
server: ?net.Server,
port: u16,
stream: net.Stream,

writer: net.Stream.Writer,
reader: net.Stream.Reader,
write_buffer: [WRITE_BUFFER_SIZE]u8,
read_buffer: [READ_BUFFER_SIZE]u8,

const InitError =
    net.Server.AcceptError ||
    net.TcpConnectToAddressError;

pub fn newServer() !Self {
    const server = try createServer() orelse {
        return error.NoAvailablePort;
    };
    return Self{
        .local = false,
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
        .local = false,
        .server = null,
        .port = port,
        .stream = undefined,
        .writer = undefined,
        .reader = undefined,
        .write_buffer = undefined,
        .read_buffer = undefined,
    };
}

pub fn newLocal() Self {
    return Self{
        .local = true,
        .server = null,
        .port = undefined,
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
    if (self.local) {
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
    if (self.local) {
        return;
    }

    self.stream.close();
    if (self.server) |*server| {
        server.deinit();
    }
}

pub fn send(self: *Self, message: Message) serde.SerError!void {
    if (self.local) {
        return;
    }

    try serde.serialize(Message, &message, &self.writer.interface);
    try self.writer.interface.flush();
}

pub fn recv(self: *Self) serde.DeError!Message {
    if (self.local) {
        waitForever();
    }

    return try serde.deserialize(Message, self.reader.interface());
}

pub fn simulateLatency() void {
    const MINIMUM_MS = 100;
    const EXTRA_MS = 300;

    var random: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&random)) catch unreachable;

    const time_ms = @mod(random, EXTRA_MS) + MINIMUM_MS;
    std.Thread.sleep(time_ms * std.time.ns_per_ms);
}

fn waitForever() noreturn {
    var mutex = std.Thread.Mutex{};
    mutex.lock();
    defer mutex.unlock();
    var condition = std.Thread.Condition{};
    condition.wait(&mutex);
    unreachable;
}
