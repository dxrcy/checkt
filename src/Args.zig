const Self = @This();

const std = @import("std");

const State = @import("State.zig");

ascii: bool,
dummy: bool,
// TODO: Use new union type with port if joining
role: State.Role,
port: ?u16,

pub fn parse() ?Self {
    var args = std.process.args();
    _ = args.next();

    var ascii = false;
    var dummy = false;
    var role_opt: ?State.Role = null;
    var port: ?u16 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
        }

        if (std.mem.eql(u8, arg, "--dummy")) {
            dummy = true;
        }

        if (std.mem.eql(u8, arg, "host")) {
            if (role_opt != null) {
                std.log.err("invalid argument", .{});
                return null;
            }
            role_opt = .host;
        }

        if (std.mem.eql(u8, arg, "join")) {
            if (role_opt != null) {
                std.log.err("invalid argument", .{});
                return null;
            }
            role_opt = .join;

            const port_str = args.next() orelse {
                std.log.err("missing value", .{});
                return null;
            };
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.log.err("invalid value", .{});
                return null;
            };
        }
    }

    const role = role_opt orelse {
        std.log.err("missing argument", .{});
        return null;
    };

    return Self{
        .ascii = ascii,
        .dummy = dummy,
        .role = role,
        .port = port,
    };
}
