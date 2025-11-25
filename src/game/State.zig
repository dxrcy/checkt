const Self = @This();

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
};

// TODO: Use 3-variant enum?
role: ?Role,
status: Status,

pub const Role = enum {
    host,
    join,
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

pub fn getBoard(self: *const Self) ?*const Board {
    return switch (self.status) {
        .play => |*play| &play.board,
        .win => |*win| &win.board,
    };
}

pub fn getPlayerLocal(self: *const Self) ?*const Player {
    return switch (self.status) {
        .play => |*play| &play.player_local,
        else => null,
    };
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
