const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const posix = std.posix;
const Thread = std.Thread;

const Board = @import("Board.zig");
const State = @import("State.zig");
const Ui = @import("Ui.zig");
const Connection = @import("Connection.zig");

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

    var conn = switch (role) {
        .host => try Connection.connectServer(),
        .join => try Connection.connectClient(),
    };
    defer conn.deinit();

    const state = State.new(role);

    var ui = Ui.new(ascii);
    try ui.enter();
    // Restore terminal, if anything goes wrong
    errdefer ui.exit() catch unreachable;

    {
        var shared = Shared{
            .state = state,
            .ui = ui,
            .render_trigger = std.Thread.ResetEvent{},
        };
        shared.render_trigger.set();

        const render_thread = try Thread.spawn(.{}, render_worker, .{&shared});
        const input_thread = try Thread.spawn(.{}, input_worker, .{&shared});

        // Wait
        input_thread.join();
        // Cancel
        _ = render_thread;
    }

    // Don't `defer`, so that error can be returned if possible
    try ui.exit();

    return 0;
}

const Shared = struct {
    state: State,
    ui: Ui,
    render_trigger: Thread.ResetEvent,
};

fn render_worker(shared: *Shared) void {
    while (true) {
        shared.render_trigger.wait();
        shared.render_trigger.reset();

        shared.ui.render(&shared.state);
        shared.ui.draw();
    }
}

fn input_worker(shared: *Shared) !void {
    const state = &shared.state;
    var stdin = fs.File.stdin();

    while (true) {
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
                state.player_local.selected = null;
            },

            'r' => if (state.status == .win) {
                state.resetGame();
            },

            't' => switch (state.status) {
                .play => |*side| {
                    side.* = side.flip();
                    state.player_local.selected = null;
                    if (state.player_remote) |*player_other| {
                        player_other.selected = null;
                    }
                },
                else => {},
            },
            'y' => if (state.status == .play) {
                state.toggleSelection(true);
            },

            'o' => {
                state.player_local.selected = null;
                if (state.player_remote) |*player_other| {
                    player_other.selected = null;
                }
                state.simulating_other ^= true;
            },
            'p' => {
                shared.ui.show_debug ^= true;
            },

            else => {},
        }

        shared.render_trigger.set();
    }
}
