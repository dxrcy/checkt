const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const posix = std.posix;
const Thread = std.Thread;

const Args = @import("Args.zig");
const Board = @import("Board.zig");
const Connection = @import("Connection.zig");
const Game = @import("Game.zig");
const Ui = @import("Ui.zig");

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

    var state = State.new(args.role);

    {
        var state_mutex = MutexPtr(State).new(&state);
        var ui_mutex = MutexPtr(Ui).new(&ui);

        var render_channel = Channel(RenderMessage).empty;
        var send_channel = Channel(Connection.Message).empty;

        RENDER_CHANNEL = &render_channel;
        defer RENDER_CHANNEL = null;

        const workers = [_]Worker{
            try Worker.spawn("render", .detach, render_worker, .{
                .state = &state_mutex,
                .ui = &ui_mutex,
                .render_channel = &render_channel,
            }),
            try Worker.spawn("input", .join, input_worker, .{
                .state = &state_mutex,
                .ui = &ui_mutex,
                .render_channel = &render_channel,
                .send_channel = &send_channel,
            }),
            try Worker.spawn("send", .detach, send_worker, .{
                .connection = &connection,
                .send_channel = &send_channel,
            }),
            try Worker.spawn("recv", .detach, recv_worker, .{
                .state = &state_mutex,
                .connection = &connection,
                .render_channel = &render_channel,
            }),
        };

        for (&workers) |*worker| {
            worker.consume();
        }
    }

    // Don't `defer`, so that error can be returned if possible
    try ui.exit();

    return 0;
}

fn MutexPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: Thread.Mutex,
        object: *T,

        pub fn new(object: *T) Self {
            return Self{
                .mutex = .{},
                .object = object,
            };
        }

        pub fn lock(self: *Self) *T {
            self.mutex.lock();
            return self.object;
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock();
        }
    };
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
        comptime name: []const u8,
        comptime lifetime: Lifetime,
        comptime function: anytype,
        args: @typeInfo(@TypeOf(function)).@"fn".params[0].type.?,
    ) !Self {
        var thread = try Thread.spawn(.{}, function, .{args});
        try thread.setName(name);
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

fn render_worker(shared: struct {
    state: *MutexPtr(State),
    ui: *MutexPtr(Ui),
    render_channel: *Channel(RenderMessage),
}) void {
    shared.render_channel.send(.update);

    while (true) {
        const event = shared.render_channel.recv();

        const ui = shared.ui.lock();
        defer shared.ui.unlock();

        switch (event) {
            .redraw => ui.clear(),
            .update => {},
        }

        {
            const state = shared.state.lock();
            defer shared.state.unlock();

            ui.render(state);
        }

        ui.draw();
    }
}

fn input_worker(shared: struct {
    state: *MutexPtr(State),
    ui: *MutexPtr(Ui),
    render_channel: *Channel(RenderMessage),
    send_channel: *Channel(Connection.Message),
}) void {
    var previous_state: State = undefined;

    var stdin = fs.File.stdin();

    while (true) {
        var buffer: [1]u8 = undefined;
        const bytes_read = stdin.read(&buffer) catch {
            return;
        };
        if (bytes_read < 1) {
            return;
        }

        const state = shared.state.lock();
        defer shared.state.unlock();

        previous_state = state.*;

        // TODO: Map input to enum variant, then handle in `Game`

        const Input = enum(u8) {
            quit,

            up,
            down,
            left,
            right,

            confirm,
            cancel,
            reset,

            debug_switch_side,
            debug_force_move,
            debug_toggle_info,

            _,
        };

        const input: Input = switch (buffer[0]) {
            0x03 => .quit,

            'h' => .left,
            'l' => .right,
            'k' => .up,
            'j' => .down,

            0x20 => .confirm,
            0x1b => .cancel,
            'r' => .reset,

            't' => .debug_switch_side,
            'y' => .debug_force_move,
            'p' => .debug_toggle_info,

            else => continue,
        };

        switch (input) {
            .quit => break,

            .left => if (state.status == .play) state.moveFocus(.left),
            .right => if (state.status == .play) state.moveFocus(.right),
            .up => if (state.status == .play) state.moveFocus(.up),
            .down => if (state.status == .play) state.moveFocus(.down),

            .confirm => if (state.status == .play) {
                Game.toggleSelection(state, false, shared.send_channel);
            },
            .cancel => if (state.status == .play) {
                state.player_local.selected = null;
            },

            .reset => if (state.status == .win) {
                state.resetGame();
            },

            .debug_switch_side => switch (state.status) {
                .play => |*side| {
                    side.* = side.flip();
                    state.player_local.selected = null;
                    if (state.player_remote) |*player_remote| {
                        player_remote.selected = null;
                    }
                },
                else => {},
            },
            .debug_force_move => if (state.status == .play) {
                Game.toggleSelection(state, true, shared.send_channel);
            },

            .debug_toggle_info => {
                const ui = shared.ui.lock();
                defer shared.ui.unlock();

                ui.show_debug ^= true;
            },

            _ => {},
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
    state: *MutexPtr(State),
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

        const state = shared.state.lock();
        defer shared.state.unlock();

        switch (message) {
            .player => |player| {
                state.player_remote = player;
                shared.render_channel.send(.update);
            },

            .piece => |update| {
                assert(update.index < Board.SIZE * Board.SIZE);
                state.board.tiles[update.index] = update.entry;
                shared.render_channel.send(.update);
            },

            .taken => |update| {
                state.board.setTaken(update.piece, update.count);
                shared.render_channel.send(.update);
            },

            .status => |status| {
                state.status = status;
                shared.render_channel.send(.update);
            },
        }
    }
}
