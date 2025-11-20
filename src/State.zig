const Self = @This();

const std = @import("std");
const assert = std.debug.assert;

pub const Board = @import("Board.zig");
pub const Tile = Board.Tile;
pub const Piece = Board.Piece;

const moves = @import("moves.zig");
const Move = moves.Move;

status: Status,
board: Board,
player_self: PlayerState,
player_other: ?PlayerState,

// TODO: Rename
const PlayerState = struct {
    focus: Tile,
    selected: ?Tile,
};

const Status = union(enum) {
    play: Player,
    win: Player,
};

// TODO: Rename
pub const Player = enum(u1) {
    white = 0,
    black = 1,

    pub const COUNT = 2;

    pub fn flip(self: Player) Player {
        return if (self == .white) .black else .white;
    }
};

pub fn new() Self {
    var self: Self = undefined;
    self.resetGame();
    return self;
}

pub fn resetGame(self: *Self) void {
    self.status = .{ .play = .white };
    self.board = Board.new();
    self.player_self = .{
        .focus = .{ .rank = 5, .file = 3 },
        .selected = null,
    };
    self.player_other = .{
        .focus = .{ .rank = 3, .file = 3 },
        .selected = null,
    };
}

pub fn moveFocus(self: *Self, direction: enum { left, right, up, down }) void {
    assert(self.status == .play);

    const tile = &self.player_self.focus;

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

// TODO: Rename
pub fn toggleSelection(self: *Self, allow_invalid: bool) void {
    // TODO: Rename
    const player = switch (self.status) {
        .play => |player| player,
        else => unreachable,
    };

    // TODO: Rename
    const player_state = &self.player_self;

    const selected = player_state.selected orelse {
        const piece = self.board.get(player_state.focus);
        if (piece != null and
            piece.?.player == player)
        {
            player_state.selected = player_state.focus;
        }
        return;
    };

    if (selected.eql(player_state.focus)) {
        player_state.selected = null;
        return;
    }

    const piece = self.board.get(selected);
    assert(piece.?.player == player);

    if (allow_invalid) {
        if (self.board.get(player_state.focus)) |piece_taken| {
            self.board.addTaken(piece_taken);
        }
        self.board.set(player_state.focus, piece);
        self.board.set(selected, null);
        player_state.selected = null;
        if (!self.updateStatus()) {
            self.status = .{ .play = player.flip() };
        }
        return;
    }

    const move = self.getAvailableMove(selected, player_state.focus) orelse
        return;
    assert(move.destination.eql(player_state.focus));

    self.board.applyMove(selected, move);
    player_state.selected = null;

    if (!self.updateStatus()) {
        self.status = .{ .play = player.flip() };
    }
}

fn updateStatus(self: *Self) bool {
    const alive_white = self.board.isPieceAlive(.{ .kind = .king, .player = .white });
    const alive_black = self.board.isPieceAlive(.{ .kind = .king, .player = .black });

    assert(alive_white or alive_black);
    if (!alive_white) {
        self.status = .{ .win = .black };
        return true;
    }
    if (!alive_black) {
        self.status = .{ .win = .white };
        return true;
    }

    return false;
}

fn getAvailableMove(self: *const Self, origin: Tile, destination: Tile) ?Move {
    var available_moves = self.board.getAvailableMoves(origin);
    while (available_moves.next()) |available| {
        if (available.destination.eql(destination)) {
            return available;
        }
    }
    return null;
}
