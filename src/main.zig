const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const posix = std.posix;
const Thread = std.Thread;

const Args = @import("Args.zig");
const Board = @import("Board.zig");
const Ui = @import("Ui.zig");
const Connection = @import("Connection.zig");

const State = @import("State.zig");
const Tile = State.Tile;

const channel = @import("channel.zig");
const Channel = channel.Channel;
const Queue = channel.Queue;

pub fn main() !u8 {
    const args = Args.parse() orelse {
        return 1;
    };

    var conn = if (args.role) |role| switch (role) {
        .host => try Connection.newServer(),
        .join => Connection.newClient(args.port orelse unreachable),
    } else Connection.newSingle();
    if (args.role == .host) {
        std.log.info("hosting on port {}.", .{conn.port});
        std.log.info("waiting for client to join...", .{});
    }
    try conn.init();
    defer conn.deinit();

    const state = State.new(args.role);

    var ui = Ui.new(args.ascii);
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
            .send_channel = .empty,
        };

        const render_thread = try Thread.spawn(.{}, render_worker, .{&shared});
        const input_thread = try Thread.spawn(.{}, input_worker, .{&shared});
        const send_thread = try Thread.spawn(.{}, send_worker, .{&shared});
        const recv_thread = try Thread.spawn(.{}, recv_worker, .{&shared});

        input_thread.join();
        render_thread.detach();
        send_thread.detach();
        recv_thread.detach();
    }

    // Don't `defer`, so that error can be returned if possible
    try ui.exit();

    return 0;
}

fn handleSignal(sig_num: c_int) callconv(.c) void {
    _ = sig_num;
    EVENTS.send(.redraw);
}

// TODO: Rename
// TODO: Make non-global. Somehow still has to be accessible by signal handler
var EVENTS = Channel(Event).empty;

// TODO: Rename
const Event = enum {
    redraw,
    update,
};

const Shared = struct {
    // TODO: Use pointers?
    state: State,
    ui: Ui,
    connection: *Connection,

    send_channel: Channel(Connection.Message),
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

fn input_worker(shared: *Shared) void {
    const state = &shared.state;
    var previous_state: State = undefined;

    var stdin = fs.File.stdin();

    while (true) {
        previous_state = state.*;

        var buffer: [1]u8 = undefined;
        const bytes_read = stdin.read(&buffer) catch {
            return;
        };
        if (bytes_read < 1) {
            return;
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

        // TODO: Move the following to a function

        // TODO: Make this much better please!
        if (!state.player_local.focus.eql(previous_state.player_local.focus) or
            (state.player_local.selected == null) != (previous_state.player_local.selected == null) or
            (state.player_local.selected != null and
                previous_state.player_local.selected != null and
                state.player_local.selected.?.eql(previous_state.player_local.selected.?)))
        {
            shared.send_channel.send(.{ .player = state.player_local });
        }

        for (0..Board.SIZE) |rank| {
            for (0..Board.SIZE) |file| {
                const tile = Tile{ .rank = @intCast(rank), .file = @intCast(file) };
                const piece_current = state.board.get(tile);
                const piece_previous = previous_state.board.get(tile);
                if (piece_current != piece_previous) {
                    shared.send_channel.send(.{ .piece = .{
                        .tile = tile,
                        .piece = piece_current,
                    } });
                }
            }
        }

        for (std.meta.tags(State.Side)) |side| {
            for (std.meta.tags(State.Piece.Kind)) |kind| {
                const piece = State.Piece{ .kind = kind, .side = side };
                const current = state.board.getTaken(piece);
                const previous = previous_state.board.getTaken(piece);
                if (current != previous) {
                    shared.send_channel.send(.{ .taken = .{
                        .piece = piece,
                        .count = current,
                    } });
                }
            }
        }

        if (!state.status.eql(previous_state.status)) {
            shared.send_channel.send(.{ .status = state.status });
        }
    }
}

fn send_worker(shared: *Shared) void {
    while (true) {
        const message = shared.send_channel.recv();
        shared.connection.send(message) catch |err| switch (err) {
            error.WriteFailed => {
                // TODO: Handle
            },
        };
    }
}

// FIXME: Lock state on modification
fn recv_worker(shared: *Shared) void {
    while (true) {
        const message = shared.connection.recv() catch |err| switch (err) {
            error.Malformed => {
                // TODO: Handle
                continue;
            },
            error.ReadFailed => {
                // TODO: Handle
                return;
            },
            error.EndOfStream => {
                // TODO: Handle
                return;
            },
            // else => |err2| return err2,
        };
        switch (message) {
            .count => |count| {
                shared.state.count = count;
                EVENTS.send(.update);
            },

            .player => |player| {
                shared.state.player_remote = player;
                EVENTS.send(.update);
            },

            .piece => |update| {
                shared.state.board.set(update.tile, update.piece);
                EVENTS.send(.update);
            },

            .taken => |update| {
                shared.state.board.setTaken(update.piece, update.count);
                EVENTS.send(.update);
            },

            .status => |status| {
                shared.state.status = status;
                EVENTS.send(.update);
            },
        }
    }
}
