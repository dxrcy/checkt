const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const posix = std.posix;
const Thread = std.Thread;

const Channel = @import("Channel.zig");
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
        .host => try Connection.newServer(),
        .join => Connection.newClient(),
    };
    if (role == .host) {
        std.log.info("waiting for client to join...\n", .{});
    }
    try conn.init();
    defer conn.deinit();

    const state = State.new(role);

    var ui = Ui.new(ascii);
    try ui.enter();
    // Restore terminal, if anything goes wrong
    errdefer ui.exit() catch unreachable;

    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &action, null);

    {
        var shared = Shared{
            .state = state,
            .ui = ui,
            .connection = &conn,
        };

        const render_thread = try Thread.spawn(.{}, render_worker, .{&shared});
        const input_thread = try Thread.spawn(.{}, input_worker, .{&shared});
        const recv_thread = try Thread.spawn(.{}, recv_worker, .{&shared});
        const temp_thread = try Thread.spawn(.{}, temp_worker, .{&shared});

        // Wait
        input_thread.join();
        // Cancel
        _ = render_thread;
        _ = recv_thread;
        _ = temp_thread;
    }

    // Don't `defer`, so that error can be returned if possible
    try ui.exit();

    return 0;
}

fn handleSignal(sig_num: c_int) callconv(.c) void {
    _ = sig_num;
    EVENTS.send(.redraw);
}

var EVENTS = Channel.init();

const Shared = struct {
    // TODO: Use pointers?
    state: State,
    ui: Ui,
    connection: *Connection,
};

fn render_worker(shared: *Shared) void {
    EVENTS.send(.update);

    while (true) {
        const event = EVENTS.recv();
        switch (event) {
            .redraw => shared.ui.clear(),
            .update => {},
        }

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
                    if (state.player_remote) |*player_remote| {
                        player_remote.selected = null;
                    }
                },
                else => {},
            },
            'y' => if (state.status == .play) {
                state.toggleSelection(true);
            },

            'p' => {
                shared.ui.show_debug ^= true;
            },

            else => {},
        }

        EVENTS.send(.update);

        // PERF: Only send if changed (send on change)
        try shared.connection.send(.{ .player = shared.state.player_local });
    }
}

fn recv_worker(shared: *Shared) !void {
    while (true) {
        const message = try shared.connection.recv();
        switch (message) {
            .count => |count| {
                shared.state.count = count;
                EVENTS.send(.update);
            },

            .player => |player| {
                shared.state.player_remote = player;
                EVENTS.send(.update);
            },
        }
    }
}

fn temp_worker(shared: *Shared) !void {
    if (shared.state.role != .host) {
        return;
    }

    while (true) {
        Thread.sleep(500 * std.time.ns_per_ms);
        shared.state.count += 1;

        EVENTS.send(.update);
        try shared.connection.send(.{ .count = shared.state.count });
    }
}
