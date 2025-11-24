const Self = @This();

const std = @import("std");
const assert = std.debug.assert;

const Connection = @import("Connection.zig");
const Channel = @import("concurrent.zig").Channel;
const Board = @import("Board.zig");
const Move = @import("moves.zig").Move;

const State = @import("State.zig");
const Side = State.Side;
const Tile = State.Tile;

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

/// Returns `true` if status changed.
// TODO: There is a better way of doing this. Perhaps remove this function
pub fn updateStatus(state: *State) bool {
    const alive_white = state.board.isPieceAlive(.{ .kind = .king, .side = .white });
    const alive_black = state.board.isPieceAlive(.{ .kind = .king, .side = .black });

    assert(alive_white or alive_black);
    if (!alive_white) {
        state.status = .{ .win = .black };
        return true;
    }
    if (!alive_black) {
        state.status = .{ .win = .white };
        return true;
    }

    return false;
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

// TODO: Rename
pub fn toggleSelection(
    state: *State,
    allow_invalid: bool,
    channel: *Channel(Connection.Message),
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
    if (allow_invalid) {
        if (state.board.get(player.focus)) |piece_taken| {
            state.board.addTaken(piece_taken);
        }

        const move = Move{
            .destination = player.focus,
            .mark_special = false,
            .move_alt = null,
            // TODO: Take piece if piece exists in destination
            .take = null,
        };
        applyAndCommitMove(state, selected, move, channel);

        player.selected = null;
        if (!updateStatus(state)) {
            state.status = .{ .play = side.flip() };
        }
        return;
    }

    const move = state.getAvailableMove(selected, player.focus) orelse
        return;
    assert(move.destination.eql(player.focus));

    applyAndCommitMove(state, selected, move, channel);

    player.selected = null;

    if (!updateStatus(state)) {
        state.status = .{ .play = side.flip() };
    }
}

/// Does **not** validate move.
fn applyAndCommitMove(
    state: *State,
    origin: State.Tile,
    move: Move,
    channel: *Channel(Connection.Message),
) void {
    // TODO: Change method to return void???
    _ = state.board.applyMove(origin, move);

    channel.send(.{ .commit_move = .{
        .origin = origin,
        .move = move,
    } });
}
