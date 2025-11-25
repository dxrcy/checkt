const Self = @This();

const std = @import("std");
const assert = std.debug.assert;

const Channel = @import("../concurrent.zig").Channel;
const Connection = @import("../connection/Connection.zig");

const Move = @import("moves.zig").Move;
pub const State = @import("State.zig");
const Board = State.Board;
const Side = State.Side;
const Tile = State.Tile;

pub const Message = union(enum) {
    ping: void,
    pong: void,

    position: State.Player,
    commit_move: CommitMove,

    debug_set_status: State.Status,
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

pub fn moveFocus(state: *State, direction: enum { left, right, up, down }) void {
    assert(state.status == .play);

    const player = &state.player_local;
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

pub fn advanceNextTurn(state: *State) void {
    const current = state.status.play;

    if (isWin(state)) |winning_side| {
        assert(winning_side == current);
        state.status = .{ .win = winning_side };
    } else {
        state.status = .{ .play = current.flip() };
    }
}

/// Returns which side has won the game, if any.
fn isWin(state: *const State) ?Side {
    const alive_white = state.board.isPieceAlive(.{ .kind = .king, .side = .white });
    const alive_black = state.board.isPieceAlive(.{ .kind = .king, .side = .black });

    assert(alive_white or alive_black);
    if (!alive_white) {
        return .black;
    }
    if (!alive_black) {
        return .white;
    }
    return null;
}

pub fn isMoveValid(
    state: *const State,
    side: Side,
    origin: Tile,
    move: Move,
) bool {
    const active_side = switch (state.status) {
        .play => |active_side| active_side,
        else => return false,
    };
    if (side != active_side) {
        return false;
    }

    const expected_move = state.getAvailableMove(origin, move.destination) orelse {
        return false;
    };
    if (!move.eql(expected_move)) {
        return false;
    }

    return true;
}

pub fn selectOrMove(
    state: *State,
    allow_invalid: bool,
    channel: *Channel(Message),
) void {
    const side = switch (state.status) {
        .play => |side| side,
        else => unreachable,
    };

    if (!state.isLocalSideActive()) {
        return;
    }

    const player = &state.player_local;

    const selected = player.selected orelse {
        const piece = state.board.get(player.focus);
        if (piece != null and
            piece.?.side == side)
        {
            player.selected = player.focus;
        }
        return;
    };

    if (selected.eql(player.focus)) {
        player.selected = null;
        return;
    }

    const piece = state.board.get(selected);
    assert(piece.?.side == side);

    // DEBUG
    // TODO: Merge these branches
    if (allow_invalid) {
        if (state.board.get(player.focus)) |piece_taken| {
            state.board.addTaken(piece_taken);
        }

        player.selected = null;

        const move = Move{
            .destination = player.focus,
            .mark_special = false,
            .move_alt = null,
            // TODO: Take piece if piece exists in destination
            .take = null,
        };
        applyAndCommitMove(state, selected, move, true, channel);
        advanceNextTurn(state);
        return;
    }

    player.selected = null;

    const move = state.getAvailableMove(selected, player.focus) orelse
        return;
    assert(move.destination.eql(player.focus));

    applyAndCommitMove(state, selected, move, false, channel);
    advanceNextTurn(state);
}

/// Does **not** validate move.
fn applyAndCommitMove(
    state: *State,
    origin: State.Tile,
    move: Move,
    debug_force: bool,
    channel: *Channel(Message),
) void {
    state.board.applyMove(origin, move);

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
