const Self = @This();

const std = @import("std");
const net = std.net;

const serde = @import("serde.zig");

// TODO: Use union for fields

// TODO: Rename
single: bool,
server: ?net.Server,
port: u16,
stream: net.Stream,

writer: net.Stream.Writer,
reader: net.Stream.Reader,
write_buffer: [WRITE_BUFFER_SIZE]u8,
read_buffer: [READ_BUFFER_SIZE]u8,

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
        .single = false,
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
        .single = false,
        .server = null,
        .port = port,
        .stream = undefined,
        .writer = undefined,
        .reader = undefined,
        .write_buffer = undefined,
        .read_buffer = undefined,
    };
}

// TODO: Rename
pub fn newSingle() Self {
    return Self{
        .single = true,
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
    if (self.single) {
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
    if (self.single) {
        return;
    }

    self.stream.close();
    if (self.server) |*server| {
        server.deinit();
    }
}

pub fn send(self: *Self, message: Message) serde.SerError!void {
    if (self.single) {
        return;
    }

    simulateLatency();

    try serde.serialize(Message, &message, &self.writer.interface);
    try self.writer.interface.flush();
}

pub fn recv(self: *Self) serde.DeError!Message {
    if (self.single) {
        waitForever();
    }

    simulateLatency();

    return try serde.deserialize(Message, self.reader.interface());
}

fn simulateLatency() void {
    const MINIMUM_MS = 0;
    const EXTRA_MS = 200;

    var random: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&random)) catch unreachable;

    const time_ms = @mod(random, EXTRA_MS) + MINIMUM_MS;
    std.Thread.sleep(time_ms * std.time.ns_per_ms);
}

// TODO: Move elsewhere!
pub const Message = union(enum) {
    const State = @import("State.zig");
    const Move = @import("moves.zig").Move;

    // TODO: Rename
    position: State.Player,
    commit_move: CommitMove,

    debug_set_status: State.Status,
    debug_force_commit_move: CommitMove,

    const TakenUpdate = struct {
        piece: State.Piece,
        count: u32,
    };

    const CommitMove = struct {
        origin: State.Tile,
        move: Move,
        // TODO: Add more information, to ensure everything is synced and valid
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
