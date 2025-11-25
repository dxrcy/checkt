const std = @import("std");
const assert = std.debug.assert;

pub const Board = @import("Board.zig");
pub const Piece = Board.Piece;
pub const Tile = Board.Tile;
const moves = @import("moves.zig");
const Move = moves.Move;

// TODO: Perhaps merge this struct with `Game`, and make `Status` the new
// `State`

// TODO: RENAME!!!
pub const Status = union(enum) {
    const Self = @This();

    play: struct {
        active: Side,
        board: Board,
        player_local: Player,
        player_remote: ?Player,
    },
    win: struct {
        winner: Side,
        board: Board,
    },

    pub fn getBoard(self: *const Self) ?*const Board {
        return switch (self.*) {
            .play => |*play| &play.board,
            .win => |*win| &win.board,
        };
    }

    pub fn getPlayerLocal(self: *const Self) ?*const Player {
        return switch (self.*) {
            .play => |*play| &play.player_local,
            else => null,
        };
    }
};

pub const Side = enum(u1) {
    white = 0,
    black = 1,

    pub const COUNT = 2;

    pub fn flip(self: Side) Side {
        return if (self == .white) .black else .white;
    }
};

pub const Player = struct {
    focus: Tile,
    selected: ?Tile,

    pub fn eql(lhs: Player, rhs: Player) bool {
        return lhs.focus.eql(rhs.focus) and
            optionalEql(lhs.selected, rhs.selected);
    }

    fn optionalEql(lhs: anytype, rhs: anytype) bool {
        return (lhs == null and rhs == null) or
            (lhs != null and rhs != null and lhs.?.eql(rhs.?));
    }
};
