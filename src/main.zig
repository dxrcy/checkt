const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const time = std.time;
const Instant = std.time.Instant;

const output = @import("env/output.zig");
const Connection = @import("connection/Connection.zig");
const handlers = @import("env/handlers.zig");
const logging = @import("env/logging.zig");
const Game = @import("game/Game.zig");
const State = Game.State;
const Board = Game.State.Board;
const Tile = Game.State.Tile;
const Ui = @import("ui/Ui.zig");

const Args = @import("Args.zig");
const concurrent = @import("concurrent.zig");
const Channel = concurrent.Channel;
const MutexPtr = concurrent.MutexPtr;
const Worker = concurrent.Worker;

pub const panic = std.debug.FullPanic(handlers.panic);

pub const std_options = std.Options{
    .logFn = logging.logFn,
};

// TODO: Use log scopes

pub fn main() !u8 {
    output.stdout.init();
    output.stderr.init();
    try logging.init();

    handlers.THREAD_NAME = "main";

    const exit = run();

    output.stdout.flush();
    output.stderr.flush();

    return exit;
}

pub fn run() !u8 {
    const args = Args.parse() orelse {
        return 1;
    };

    log.info("role = {?}", .{args.role});

    var connection = if (args.role) |role| switch (role) {
        .host => try Connection.newServer(),
        .join => Connection.newClient(args.port orelse unreachable),
    } else Connection.newLocal();

    // TODO: Move to ui
    if (args.role == .host) {
        log.info("hosting: {}", .{connection.port});
        output.stdout.print("hosting on port {}.\n", .{connection.port});
        output.stdout.print("waiting for client to join...\n", .{});
        output.stdout.flush();
    } else if (args.role == .join) {
        log.info("joining: {}", .{connection.port});
        output.stdout.print("joining server...\n", .{});
        output.stdout.flush();
    }

    try connection.init();
    defer connection.deinit();

    if (args.role != null) {
        log.info("remote connected", .{});
    }

    var ui = Ui.new(args.ascii, args.small);
    try ui.enter();
    // Restore terminal, if anything goes wrong
    errdefer ui.exit() catch unreachable;

    handlers.globals.UI = &ui;
    defer handlers.globals.UI = null;

    handlers.registerSignalHandlers();

    var state = State.new(args.role);
    const is_multiplayer = state.role != null;

    log.info("starting game loop", .{});
    {
        var state_mutex = MutexPtr(State).new(&state);
        var ui_mutex = MutexPtr(Ui).new(&ui);

        var render_channel = Channel(RenderMessage).empty;
        var send_channel = Channel(Game.Message).empty;

        if (!is_multiplayer) {
            send_channel.discard = true;
        }

        var last_ping = try Instant.now();

        handlers.globals.RENDER_CHANNEL = &render_channel;
        defer handlers.globals.RENDER_CHANNEL = null;

        const workers = [_]?Worker{
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

            if (!is_multiplayer) null else //
            try Worker.spawn("send", .detach, send_worker, .{
                .connection = &connection,
                .send_channel = &send_channel,
            }),

            if (!is_multiplayer) null else //
            try Worker.spawn("recv", .detach, recv_worker, .{
                .state = &state_mutex,
                .connection = &connection,
                .render_channel = &render_channel,
                .send_channel = &send_channel,
                .last_ping = &last_ping,
            }),

            if (!is_multiplayer) null else //
            try Worker.spawn("ping", .detach, ping_worker, .{
                .send_channel = &send_channel,
                .last_ping = &last_ping,
            }),
        };

        for (&workers) |*worker_opt| {
            if (worker_opt.*) |*worker| {
                worker.complete();
            }
        }
    }

    log.info("end of game loop", .{});

    // Don't `defer`, so that error can be returned if possible
    try ui.exit();

    return 0;
}

pub const RenderMessage = enum {
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
    send_channel: *Channel(Game.Message),
}) void {
    var previous_state: State = undefined;

    var stdin = std.fs.File.stdin();

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
            debug_kill_remote,

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
            'X' => .debug_kill_remote,

            else => continue,
        };

        log.info("input: {}", .{input});

        switch (input) {
            .quit => break,

            .left => if (state.status == .play) Game.moveFocus(state, .left),
            .right => if (state.status == .play) Game.moveFocus(state, .right),
            .up => if (state.status == .play) Game.moveFocus(state, .up),
            .down => if (state.status == .play) Game.moveFocus(state, .down),

            .confirm => if (state.status == .play) {
                Game.selectOrMove(state, false, shared.send_channel);
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
                    shared.send_channel.send(.{ .debug_set_status = state.status });

                    state.player_local.selected = null;
                    if (state.player_remote) |*player_remote| {
                        player_remote.selected = null;
                    }
                },
                else => {},
            },

            .debug_force_move => if (state.status == .play) {
                Game.selectOrMove(state, true, shared.send_channel);
            },

            .debug_toggle_info => {
                const ui = shared.ui.lock();
                defer shared.ui.unlock();

                ui.debug_render_info ^= true;
            },

            .debug_kill_remote => {
                shared.send_channel.send(.{ .debug_kill_remote = {} });
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
            shared.send_channel.send(.{ .position = state.player_local });
        }
    }
}

fn send_worker(shared: struct {
    connection: *Connection,
    send_channel: *Channel(Game.Message),
}) !void {
    var connection_mutex = MutexPtr(Connection).new(shared.connection);

    while (true) {
        const message = shared.send_channel.recv();
        _ = try std.Thread.spawn(.{}, send_worker_action, .{ &connection_mutex, message });
    }
}

// NOTE: This is useful for simulating latency without blocking subsequent messages
fn send_worker_action(
    connection_mutex: *MutexPtr(Connection),
    message: Game.Message,
) void {
    Connection.simulateLatency();

    if (message != .ping and message != .pong) {
        log.info("send: {t}", .{message});
    }

    const connection = connection_mutex.lock();
    defer connection_mutex.unlock();

    connection.send(message) catch |err| switch (err) {
        error.WriteFailed => {
            // TODO: Handle
        },
    };
}

fn recv_worker(shared: struct {
    state: *MutexPtr(State),
    connection: *Connection,
    render_channel: *Channel(RenderMessage),
    send_channel: *Channel(Game.Message),
    last_ping: *Instant,
}) !void {
    while (true) {
        const message = shared.connection.recv() catch |err| switch (err) {
            error.Malformed => {
                log.warn("malformed message", .{});
                continue;
            },
            error.ReadFailed => {
                log.err("read failed", .{});
                return;
            },
            error.EndOfStream => {
                log.err("unexpected end of stream", .{});
                return;
            },
        };

        if (message != .ping and message != .pong) {
            log.info("recv: {t}", .{message});
        }

        const state = shared.state.lock();
        defer shared.state.unlock();

        // TODO: Move the following to a new function -> !void
        // And handle illegal move here (log)

        switch (message) {
            .ping => {
                shared.send_channel.send(.{ .pong = {} });
                shared.render_channel.send(.update);
            },
            .pong => {
                shared.last_ping.* = try Instant.now();
                shared.render_channel.send(.update);
            },

            .position => |position| {
                if (!position.focus.isInBounds() or
                    (position.selected != null and !position.selected.?.isInBounds()))
                {
                    log.warn("illegal message: {}", .{message});
                    continue;
                }

                state.player_remote = position;
                shared.render_channel.send(.update);
            },

            .commit_move => |commit_move| {
                if (!Game.isMoveValid(
                    state,
                    state.getLocalSide().flip(),
                    commit_move.origin,
                    commit_move.move,
                )) {
                    log.warn("illegal message: {}", .{message});
                    continue;
                }

                state.board.applyMove(commit_move.origin, commit_move.move);
                Game.advanceNextTurn(state);

                shared.render_channel.send(.update);
            },

            .debug_set_status => |status| {
                state.status = status;
                shared.render_channel.send(.update);
            },

            .debug_force_commit_move => |commit_move| {
                state.board.applyMove(commit_move.origin, commit_move.move);
                Game.advanceNextTurn(state);

                shared.render_channel.send(.update);
            },

            .debug_kill_remote => {
                log.warn("killed by remote", .{});
                handlers.exit();
            },
        }
    }
}

fn ping_worker(shared: struct {
    send_channel: *Channel(Game.Message),
    last_ping: *Instant,
}) !void {
    const PING_NS = 400 * time.ns_per_ms;
    const TIMEOUT_NS = 4 * time.ns_per_s;

    while (true) {
        std.Thread.sleep(PING_NS);
        shared.send_channel.send(.{ .ping = {} });

        const now = try Instant.now();
        const time_since_last = now.since(shared.last_ping.*);

        if (time_since_last > 2 * time.ns_per_s) {
            log.warn(
                "ms since last ping: {}",
                .{time_since_last / time.ns_per_ms},
            );
        }

        if (time_since_last > TIMEOUT_NS) {
            log.warn("remote timeout", .{});
            handlers.exit();
        }
    }
}
