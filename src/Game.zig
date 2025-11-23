const Self = @This();

const std = @import("std");
const assert = std.debug.assert;

const State = @import("State.zig");

const Connection = @import("Connection.zig");
const Channel = @import("channel.zig").Channel;

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

        const updates = state.board.movePieceOverride(selected, player.focus, false);
        for (updates) |update| {
            channel.send(.{ .piece = update });
        }

        player.selected = null;
        if (!state.updateStatus()) {
            state.status = .{ .play = side.flip() };
        }
        return;
    }

    const move = state.getAvailableMove(selected, player.focus) orelse
        return;
    assert(move.destination.eql(player.focus));

    const updates = state.board.applyMove(selected, move);
    for (updates) |update_opt| {
        if (update_opt) |update| {
            channel.send(.{ .piece = update });
        }
    }

    player.selected = null;

    if (!state.updateStatus()) {
        state.status = .{ .play = side.flip() };
    }
}
