const Self = @This();

const std = @import("std");
const net = std.net;

server: ?net.Server,
stream: net.Stream,

const ADDRESS = net.Address.parseIp4("127.0.0.1", 5720) catch unreachable;

pub fn connectServer() !Self {
    var server = try ADDRESS.listen(.{});
    std.log.info("waiting for client to join...\n", .{});
    const connection = try server.accept();
    return Self{
        .server = server,
        .stream = connection.stream,
    };
}

pub fn connectClient() !Self {
    const stream = try net.tcpConnectToAddress(ADDRESS);
    return Self{
        .server = null,
        .stream = stream,
    };
}

pub fn deinit(self: *Self) void {
    self.stream.close();
    if (self.server) |*server| {
        server.deinit();
    }
}
