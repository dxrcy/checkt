const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const posix = std.posix;

const Board = @import("Board.zig");
const State = @import("State.zig");
const Ui = @import("Ui.zig");

pub fn main() !u8 {
    var args = std.process.args();
    _ = args.next();

    var ascii = false;
    var role_opt: ?State.Role = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
        }
        if (std.mem.eql(u8, arg, "host")) {
            if (role_opt != null) {
                std.log.err("invalid argument\n", .{});
                return 1;
            }
            role_opt = .host;
        }
        if (std.mem.eql(u8, arg, "join")) {
            if (role_opt != null) {
                std.log.err("invalid argument\n", .{});
                return 1;
            }
            role_opt = .join;
        }
    }

    const role = role_opt orelse {
        std.log.err("missing argument\n", .{});
        return 1;
    };

    var state = State.new(role);

    var ui = Ui.new(ascii);
    try ui.enter();
    // Restore terminal, if anything goes wrong
    errdefer ui.exit() catch unreachable;

    var stdin = fs.File.stdin();

    while (true) {
        ui.render(&state);
        ui.draw();

        var buffer: [1]u8 = undefined;
        const bytes_read = try stdin.read(&buffer);
        if (bytes_read < 1) {
            break;
        }

        switch (buffer[0]) {
            0x03 => break,

            'h' => if (state.status == .play) state.moveFocus(.left),
            'l' => if (state.status == .play) state.moveFocus(.right),
            'k' => if (state.status == .play) state.moveFocus(.up),
            'j' => if (state.status == .play) state.moveFocus(.down),

            0x20 => if (state.status == .play) {
                state.toggleSelection(false);
            },
            0x1b => if (state.status == .play) {
                state.player_self.selected = null;
            },

            'r' => if (state.status == .win) {
                state.resetGame();
            },

            't' => switch (state.status) {
                .play => |*side| {
                    side.* = side.flip();
                    state.player_self.selected = null;
                    if (state.player_other) |*player_other| {
                        player_other.selected = null;
                    }
                },
                else => {},
            },
            'y' => if (state.status == .play) {
                state.toggleSelection(true);
            },

            'o' => {
                state.player_self.selected = null;
                if (state.player_other) |*player_other| {
                    player_other.selected = null;
                }
                state.simulating_other ^= true;
            },
            'p' => {
                ui.show_debug ^= true;
            },

            else => {},
        }
    }

    // Don't `defer`, so that error can be returned if possible
    try ui.exit();

    return 0;
}
