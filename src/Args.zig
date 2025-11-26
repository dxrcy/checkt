const Self = @This();

const std = @import("std");

const output = @import("env/output.zig");
const Game = @import("game/Game.zig");

ascii: bool,
small: bool,

/// Returns `null` if arguments are invalid.
pub fn parse() ?Self {
    var args = std.process.args();
    _ = args.next();

    var ascii = false;
    var small = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
        } else if (std.mem.eql(u8, arg, "--small")) {
            small = true;
        } else {
            output.stderr.print("invalid argument\n", .{});
            return null;
        }
    }

    return Self{
        .ascii = ascii,
        .small = small,
    };
}
