const Self = @This();

const std = @import("std");
const assert = std.debug.assert;

const State = @import("State.zig");
const Move = @import("moves.zig").Move;

const Connection = @import("Connection.zig");
const Channel = @import("concurrent.zig").Channel;

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

    if (!state.isSelfActive()) {
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
        if (!state.updateStatus()) {
            state.status = .{ .play = side.flip() };
        }
        return;
    }

    const move = state.getAvailableMove(selected, player.focus) orelse
        return;
    assert(move.destination.eql(player.focus));

    applyAndCommitMove(state, selected, move, channel);

    player.selected = null;

    if (!state.updateStatus()) {
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
