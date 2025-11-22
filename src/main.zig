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

    var connection = if (args.role) |role| switch (role) {
        .host => try Connection.newServer(),
        .join => Connection.newClient(args.port orelse unreachable),
    } else Connection.newSingle();
    if (args.role == .host) {
        std.log.info("hosting on port {}.", .{connection.port});
        std.log.info("waiting for client to join...", .{});
    }
    try connection.init();
    defer connection.deinit();

    var state = State.new(args.role);

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
        // FIXME: Wrap state in mutex

        var render_channel = Channel(RenderMessage).empty;
        var send_channel = Channel(Connection.Message).empty;

        RENDER_CHANNEL = &render_channel;
        defer RENDER_CHANNEL = null;

        const render_thread = try Worker.spawn(.detach, render_worker, .{
            .state = &state,
            .ui = &ui,
            .render_channel = &render_channel,
        });
        const input_thread = try Worker.spawn(.join, input_worker, .{
            .state = &state,
            .ui = &ui,
            .render_channel = &render_channel,
            .send_channel = &send_channel,
        });
        const send_thread = try Worker.spawn(.detach, send_worker, .{
            .connection = &connection,
            .send_channel = &send_channel,
        });
        const recv_thread = try Worker.spawn(.detach, recv_worker, .{
            .state = &state,
            .connection = &connection,
            .render_channel = &render_channel,
        });

        input_thread.consume();
        render_thread.consume();
        send_thread.consume();
        recv_thread.consume();
    }

    // Don't `defer`, so that error can be returned if possible
    try ui.exit();

    return 0;
}

const Worker = struct {
    const Self = @This();

    thread: Thread,
    // TODO: Rename
    lifetime: Lifetime,

    // TODO: Rename
    // TODO: Rename variants
    const Lifetime = enum { join, detach };

    pub fn spawn(
        comptime lifetime: Lifetime,
        comptime function: anytype,
        args: @typeInfo(@TypeOf(function)).@"fn".params[0].type.?,
    ) !Self {
        const thread = try Thread.spawn(.{}, function, .{args});
        return Self{
            .thread = thread,
            .lifetime = lifetime,
        };
    }

    // TODO: Rename
    pub fn consume(self: Self) void {
        switch (self.lifetime) {
            .join => self.thread.join(),
            .detach => self.thread.detach(),
        }
    }
};

fn handleSignal(sig_num: c_int) callconv(.c) void {
    _ = sig_num;
    if (RENDER_CHANNEL) |render_channel| {
        render_channel.send(.redraw);
    }
}

var RENDER_CHANNEL: ?*Channel(RenderMessage) = null;

// TODO: Rename
const RenderMessage = enum {
    redraw,
    update,
};

const Shared = struct {
    // TODO: Use pointers?
    state: State,
    ui: Ui,
    connection: *Connection,

    render_channel: Channel(RenderMessage),
    send_channel: Channel(Connection.Message),
};

fn render_worker(shared: struct {
    state: *State,
    ui: *Ui,
    render_channel: *Channel(RenderMessage),
}) void {
    shared.render_channel.send(.update);

    while (true) {
        const event = shared.render_channel.recv();
        switch (event) {
            .redraw => shared.ui.clear(),
            .update => {},
        }

        shared.ui.render(shared.state);
        shared.ui.draw();
    }
}

fn input_worker(shared: struct {
    state: *State,
    ui: *Ui,
    render_channel: *Channel(RenderMessage),
    send_channel: *Channel(Connection.Message),
}) void {
    const state = shared.state;
    var previous_state: State = undefined;

    var stdin = fs.File.stdin();

    while (true) {
        previous_state = shared.state.*;

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

        shared.render_channel.send(.update);

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

fn send_worker(shared: struct {
    connection: *Connection,
    send_channel: *Channel(Connection.Message),
}) void {
    while (true) {
        const message = shared.send_channel.recv();
        shared.connection.send(message) catch |err| switch (err) {
            error.WriteFailed => {
                // TODO: Handle
            },
        };
    }
}

fn recv_worker(shared: struct {
    state: *State,
    connection: *Connection,
    render_channel: *Channel(RenderMessage),
}) void {
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
        };

        switch (message) {
            .count => |count| {
                shared.state.count = count;
                shared.render_channel.send(.update);
            },

            .player => |player| {
                shared.state.player_remote = player;
                shared.render_channel.send(.update);
            },

            .piece => |update| {
                shared.state.board.set(update.tile, update.piece);
                shared.render_channel.send(.update);
            },

            .taken => |update| {
                shared.state.board.setTaken(update.piece, update.count);
                shared.render_channel.send(.update);
            },

            .status => |status| {
                shared.state.status = status;
                shared.render_channel.send(.update);
            },
        }
    }
}
