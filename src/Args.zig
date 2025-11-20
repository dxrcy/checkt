const Self = @This();

const std = @import("std");

const State = @import("State.zig");

ascii: bool,
dummy: bool,
role: State.Role,

pub fn parse() ?Self {
    var args = std.process.args();
    _ = args.next();

    var ascii = false;
    var dummy = false;
    var role_opt: ?State.Role = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
        }

        if (std.mem.eql(u8, arg, "--dummy")) {
            dummy = true;
        }

        if (std.mem.eql(u8, arg, "host")) {
            if (role_opt != null) {
                std.log.err("invalid argument\n", .{});
                return null;
            }
            role_opt = .host;
        }

        if (std.mem.eql(u8, arg, "join")) {
            if (role_opt != null) {
                std.log.err("invalid argument\n", .{});
                return null;
            }
            role_opt = .join;
        }
    }

    const role = role_opt orelse {
        std.log.err("missing argument\n", .{});
        return null;
    };

    return Self{
        .ascii = ascii,
        .dummy = dummy,
        .role = role,
    };
}
