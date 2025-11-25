const Self = @This();

const std = @import("std");

const output = @import("env/output.zig");
const State = @import("game/State.zig");

ascii: bool,
small: bool,
// TODO: Use new union type with port if joining
role: ?State.Role,
port: ?u16,

/// Returns `null` if arguments are invalid.
pub fn parse() ?Self {
    var args = std.process.args();
    _ = args.next();

    var ascii = false;
    var small = false;
    var role: ?State.Role = null;
    var port: ?u16 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
        } else if (std.mem.eql(u8, arg, "--small")) {
            small = true;
        } else if (std.mem.eql(u8, arg, "host")) {
            if (role != null) {
                output.stderr.print("invalid argument\n", .{});
                return null;
            }
            role = .host;
        } else if (std.mem.eql(u8, arg, "join")) {
            if (role != null) {
                output.stderr.print("invalid argument\n", .{});
                return null;
            }
            role = .join;

            const port_str = args.next() orelse {
                output.stderr.print("missing value\n", .{});
                return null;
            };
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                output.stderr.print("invalid value\n", .{});
                return null;
            };
        } else {
            output.stderr.print("invalid argument\n", .{});
            return null;
        }
    }

    return Self{
        .ascii = ascii,
        .small = small,
        .role = role,
        .port = port,
    };
}
