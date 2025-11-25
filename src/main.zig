const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const log = std.log;
const time = std.time;
const Instant = std.time.Instant;

const output = @import("env/output.zig");
const Connection = @import("connection/Connection.zig");
const handlers = @import("env/handlers.zig");
const logging = @import("env/logging.zig");
const Game = @import("game/Game.zig");
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

pub fn main() !u8 {
    output.stdout.init();
    output.stderr.init();
    logging.init();

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

    var game = Game.new(args.role);
    const is_multiplayer = game.role != null;

    log.info("starting game loop", .{});
    {
        var game_mutex = MutexPtr(Game).new(&game);
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
            try Worker.spawn("render", .detach, renderWorker, .{
                .game = &game_mutex,
                .ui = &ui_mutex,
                .render_channel = &render_channel,
            }),

            try Worker.spawn("input", .join, inputWorker, .{
                .game = &game_mutex,
                .ui = &ui_mutex,
                .render_channel = &render_channel,
                .send_channel = &send_channel,
            }),

            if (!is_multiplayer) null else //
            try Worker.spawn("send", .detach, sendWorker, .{
                .connection = &connection,
                .send_channel = &send_channel,
            }),

            if (!is_multiplayer) null else //
            try Worker.spawn("recv", .detach, recvWorker, .{
                .game = &game_mutex,
                .connection = &connection,
                .render_channel = &render_channel,
                .send_channel = &send_channel,
                .last_ping = &last_ping,
            }),

            if (!is_multiplayer) null else //
            try Worker.spawn("ping", .detach, pingWorker, .{
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

// TODO: Rename shared mutex fields *_mutex ? and elsewhere
fn renderWorker(shared: struct {
    game: *MutexPtr(Game),
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
            const game = shared.game.lock();
            defer shared.game.unlock();

            ui.render(game);
        }

        ui.draw();
    }
}

fn inputWorker(shared: struct {
    game: *MutexPtr(Game),
    ui: *MutexPtr(Ui),
    render_channel: *Channel(RenderMessage),
    send_channel: *Channel(Game.Message),
}) void {
    var previous_state: Game.State = undefined;

    var stdin = std.fs.File.stdin();

    while (true) {
        const byte = try readByte(&stdin) orelse {
            return;
        };
        const input = inputFromByte(byte) orelse {
            continue;
        };

        const game = shared.game.lock();
        defer shared.game.unlock();

        previous_state = game.state;

        if (game.handleInput(
            input,
            shared.ui,
            shared.send_channel,
        )) {
            break;
        }

        shared.render_channel.send(.update);

        if (game.state.getPlayerLocal()) |player_local| {
            if (previous_state.getPlayerLocal()) |previous| {
                if (!player_local.eql(previous.*)) {
                    shared.send_channel.send(.{ .position = player_local.* });
                }
            }
        }
    }
}

/// Returns `null` on **EOF** or if zero bytes were read.
fn readByte(file: *fs.File) !?u8 {
    var buffer: [1]u8 = undefined;
    const bytes_read = file.read(&buffer) catch {
        return null;
    };
    if (bytes_read < 1) {
        return null;
    }
    return buffer[0];
}

fn inputFromByte(byte: u8) ?Game.Input {
    const keys = struct {
        const CTRL_C = 0x03;
        const ESCAPE = 0x1b;
        const SPACE = 0x20;
    };

    return switch (byte) {
        keys.CTRL_C => .quit,

        'h' => .left,
        'l' => .right,
        'k' => .up,
        'j' => .down,

        keys.SPACE => .confirm,
        keys.ESCAPE => .cancel,
        'r' => .reset,

        't' => .debug_switch_side,
        'y' => .debug_force_move,
        'p' => .debug_toggle_info,
        'X' => .debug_kill_remote,

        else => return null,
    };
}

fn sendWorker(shared: struct {
    connection: *Connection,
    send_channel: *Channel(Game.Message),
}) !void {
    var connection_mutex = MutexPtr(Connection).new(shared.connection);

    while (true) {
        const message = shared.send_channel.recv();
        _ = try std.Thread.spawn(.{}, sendWorkerAction, .{ &connection_mutex, message });
    }
}

// NOTE: This is useful for simulating latency without blocking subsequent messages
fn sendWorkerAction(
    connection_mutex: *MutexPtr(Connection),
    message: Game.Message,
) void {
    const scoped = log.scoped(.send);

    Connection.simulateLatency();

    if (message != .ping and message != .pong) {
        scoped.info("{t}", .{message});
    }

    const connection = connection_mutex.lock();
    defer connection_mutex.unlock();

    connection.send(message) catch |err| switch (err) {
        error.WriteFailed => {
            scoped.warn("write failed", .{});
        },
    };
}

fn recvWorker(shared: struct {
    game: *MutexPtr(Game),
    connection: *Connection,
    render_channel: *Channel(RenderMessage),
    send_channel: *Channel(Game.Message),
    last_ping: *Instant,
}) !void {
    const scoped = log.scoped(.recv);

    while (true) {
        const message = shared.connection.recv() catch |err| switch (err) {
            error.Malformed => {
                scoped.warn("malformed message", .{});
                continue;
            },
            error.ReadFailed => {
                scoped.err("read failed", .{});
                return;
            },
            error.EndOfStream => {
                scoped.err("unexpected end of stream", .{});
                return;
            },
        };

        if (message != .ping and message != .pong) {
            scoped.info("{t}", .{message});
        }

        handleMessage(.{
            .game = shared.game,
            .render_channel = shared.render_channel,
            .send_channel = shared.send_channel,
            .last_ping = shared.last_ping,
        }, message) catch |err| switch (err) {
            error.IllegalMessage => {
                scoped.warn("illegal message: {}", .{message});
            },
            else => |err2| return err2,
        };
    }
}

fn handleMessage(
    shared: struct {
        game: *MutexPtr(Game),
        render_channel: *Channel(RenderMessage),
        send_channel: *Channel(Game.Message),
        last_ping: *Instant,
    },
    message: Game.Message,
) !void {
    const game = shared.game.lock();
    defer shared.game.unlock();

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
                return error.IllegalMessage;
            }

            const play = switch (game.state) {
                .play => |*play| play,
                else => return error.IllegalMessage,
            };

            play.player_remote = position;

            shared.render_channel.send(.update);
        },

        .commit_move => |commit_move| {
            if (!Game.isMoveValid(
                game,
                game.getLocalSide().flip(),
                commit_move.origin,
                commit_move.move,
            )) {
                return error.IllegalMessage;
            }

            const play = switch (game.state) {
                .play => |*play| play,
                else => return error.IllegalMessage,
            };

            play.board.applyMove(commit_move.origin, commit_move.move);
            Game.advanceNextTurn(game);

            shared.render_channel.send(.update);
        },

        // TODO:
        // .debug_set_state => |state| {
        //     game.state = state;
        //     shared.render_channel.send(.update);
        // },

        .debug_force_commit_move => |commit_move| {
            const play = switch (game.state) {
                .play => |*play| play,
                else => return error.IllegalMessage,
            };

            play.board.applyMove(commit_move.origin, commit_move.move);
            Game.advanceNextTurn(game);

            shared.render_channel.send(.update);
        },

        .debug_kill_remote => {
            suddenlyDie("killed by remote", .{});
        },
    }
}

fn pingWorker(shared: struct {
    send_channel: *Channel(Game.Message),
    last_ping: *Instant,
}) !void {
    const PING_NS = 400 * time.ns_per_ms;
    const TIMEOUT_NS = 4 * time.ns_per_s;

    const scoped = log.scoped(.ping);

    while (true) {
        std.Thread.sleep(PING_NS);
        shared.send_channel.send(.{ .ping = {} });

        const now = try Instant.now();
        const time_since_last = now.since(shared.last_ping.*);

        if (time_since_last > 2 * time.ns_per_s) {
            scoped.warn(
                "ms since last ping: {}",
                .{time_since_last / time.ns_per_ms},
            );
        }

        if (time_since_last > TIMEOUT_NS) {
            suddenlyDie("remote timeout", .{});
        }
    }
}

fn suddenlyDie(comptime fmt: []const u8, args: anytype) noreturn {
    log.warn(fmt, args);

    if (handlers.globals.UI) |ui| {
        ui.exit() catch {};
    }

    output.stderr.print("exiting: " ++ fmt ++ "\n", args);
    output.stderr.flush();

    std.process.exit(0);
}
