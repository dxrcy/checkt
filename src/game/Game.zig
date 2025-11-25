const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const log = std.log;

const concurrent = @import("../concurrent.zig");
const Channel = concurrent.Channel;
const MutexPtr = concurrent.MutexPtr;
const Connection = @import("../connection/Connection.zig");
const Ui = @import("../ui/Ui.zig");

const Move = @import("moves.zig").Move;
pub const State = @import("State.zig");
const Status = State.Status;
const Board = State.Board;
const Side = State.Side;
const Tile = State.Tile;

// TODO: Use 3-variant enum?
role: ?Role,
// TODO: Rename to `state` and `State`
status: Status,

pub const Role = enum {
    host,
    join,
};

pub const Message = union(enum) {
    ping: void,
    pong: void,

    position: State.Player,
    commit_move: CommitMove,

    // TODO: Re-add
    // debug_set_status: State.Status,
    debug_force_commit_move: CommitMove,
    debug_kill_remote: void,

    const TakenUpdate = struct {
        piece: State.Piece,
        count: u32,
    };

    const CommitMove = struct {
        origin: State.Tile,
        move: Move,
        // TODO: Add more information, to ensure everything is synced and valid
    };
};

// TODO: Do something better -- i forgot what
pub const Input = enum(u8) {
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
};

pub fn new(role: ?Role) Self {
    var self = Self{
        .role = role,
        .status = undefined,
    };
    self.resetGame();
    return self;
}

pub fn resetGame(self: *Self) void {
    const FOCUS_WHITE = Tile{ .rank = 5, .file = 6 };
    const FOCUS_BLACK = Tile{ .rank = 2, .file = 1 };

    self.status = .{ .play = .{
        .active = .white,
        .board = Board.new(),

        .player_local = .{
            .focus = if (self.role == .join) FOCUS_BLACK else FOCUS_WHITE,
            .selected = null,
        },
        .player_remote = if (self.role == null) null else .{
            .focus = if (self.role == .join) FOCUS_WHITE else FOCUS_BLACK,
            .selected = null,
        },
    } };
}

/// Returns `true` if loop should break.
pub fn handleInput(
    self: *Self,
    input: Input,
    ui_mutex: *MutexPtr(Ui),
    channel: *Channel(Message),
) bool {
    log.scoped(.input).info("{t}", .{input});

    switch (input) {
        .quit => return true,

        .left => if (self.status == .play) moveFocus(self, .left),
        .right => if (self.status == .play) moveFocus(self, .right),
        .up => if (self.status == .play) moveFocus(self, .up),
        .down => if (self.status == .play) moveFocus(self, .down),

        .confirm => if (self.status == .play) {
            selectOrMove(self, false, channel);
        },
        .cancel => switch (self.status) {
            .play => |*play| play.player_local.selected = null,
            else => {},
        },

        .reset => if (self.status == .win) {
            self.resetGame();
        },

        .debug_switch_side => switch (self.status) {
            .play => |*play| {
                play.active = play.active.flip();
                // TODO:
                // channel.send(.{ .debug_set_status = state.status });

                play.player_local.selected = null;
                if (play.player_remote) |*player_remote| {
                    player_remote.selected = null;
                }
            },
            else => {},
        },

        .debug_force_move => if (self.status == .play) {
            selectOrMove(self, true, channel);
        },

        .debug_toggle_info => {
            const ui = ui_mutex.lock();
            defer ui_mutex.unlock();

            ui.debug_render_info ^= true;
        },

        .debug_kill_remote => {
            channel.send(.{ .debug_kill_remote = {} });
        },
    }

    return false;
}

pub fn advanceNextTurn(self: *Self) void {
    const play = switch (self.status) {
        .play => |*play| play,
        else => unreachable,
    };

    if (play.board.isWin()) |winner| {
        assert(winner == play.active);
        self.status = .{ .win = .{
            .winner = winner,
            .board = play.board,
        } };
    } else {
        play.active = play.active.flip();
    }
}

fn moveFocus(self: *Self, direction: enum { left, right, up, down }) void {
    const player = switch (self.status) {
        .play => |*play| &play.player_local,
        else => unreachable,
    };

    const tile = &player.focus;

    switch (direction) {
        .left => if (tile.file == 0) {
            tile.file = Board.SIZE - 1;
        } else {
            tile.file -= 1;
        },
        .right => if (tile.file >= Board.SIZE - 1) {
            tile.file = 0;
        } else {
            tile.file += 1;
        },
        .up => if (tile.rank == 0) {
            tile.rank = Board.SIZE - 1;
        } else {
            tile.rank -= 1;
        },
        .down => if (tile.rank >= Board.SIZE - 1) {
            tile.rank = 0;
        } else {
            tile.rank += 1;
        },
    }
}

fn selectOrMove(
    self: *Self,
    allow_invalid: bool,
    channel: *Channel(Message),
) void {
    const play = switch (self.status) {
        .play => |*play| play,
        else => unreachable,
    };

    if (!self.isLocalSideActive()) {
        return;
    }

    const player = &play.player_local;

    const selected = player.selected orelse {
        const piece = play.board.get(player.focus);
        if (piece != null and
            piece.?.side == play.active)
        {
            player.selected = player.focus;
        }
        return;
    };

    if (selected.eql(player.focus)) {
        player.selected = null;
        return;
    }

    const piece = play.board.get(selected);
    assert(piece.?.side == play.active);

    // DEBUG
    // TODO: Merge these branches
    if (allow_invalid) {
        if (play.board.get(player.focus)) |piece_taken| {
            play.board.addTaken(piece_taken);
        }

        player.selected = null;

        const move = Move{
            .destination = player.focus,
            .mark_special = false,
            .move_alt = null,
            // TODO: Take piece if piece exists in destination
            .take = null,
        };
        applyAndCommitMove(self, selected, move, true, channel);
        advanceNextTurn(self);
        return;
    }

    player.selected = null;

    const move = play.board.getMatchingAvailableMove(selected, player.focus) orelse
        return;
    assert(move.destination.eql(player.focus));

    applyAndCommitMove(self, selected, move, false, channel);
    advanceNextTurn(self);
}

/// Does **not** validate move.
fn applyAndCommitMove(
    self: *Self,
    origin: Tile,
    move: Move,
    debug_force: bool,
    channel: *Channel(Message),
) void {
    const play = switch (self.status) {
        .play => |*play| play,
        else => unreachable,
    };

    play.board.applyMove(origin, move);

    if (debug_force) {
        channel.send(.{ .debug_force_commit_move = .{
            .origin = origin,
            .move = move,
        } });
    } else {
        channel.send(.{ .commit_move = .{
            .origin = origin,
            .move = move,
        } });
    }
}

pub fn isMoveValid(
    self: *const Self,
    side: Side,
    origin: Tile,
    move: Move,
) bool {
    const play = switch (self.status) {
        .play => |play| play,
        else => return false,
    };

    if (side != play.active) {
        return false;
    }

    const expected_move = play.board.getMatchingAvailableMove(
        origin,
        move.destination,
    ) orelse {
        return false;
    };
    if (!move.eql(expected_move)) {
        return false;
    }

    return true;
}

pub fn getLocalSide(self: *const Self) Side {
    return if (self.role == .host) .white else .black;
}

pub fn isLocalSideActive(self: *const Self) bool {
    switch (self.status) {
        .play => |*play| {
            return self.role == null or
                play.active == self.getLocalSide();
        },
        else => return false,
    }
}
