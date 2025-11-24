const Self = @This();

const std = @import("std");
const assert = std.debug.assert;

pub const Board = @import("Board.zig");
pub const Tile = Board.Tile;
pub const Piece = Board.Piece;

const moves = @import("moves.zig");
const Move = moves.Move;

role: ?Role,
status: Status,
board: Board,
player_local: Player,
player_remote: ?Player,

pub const Role = enum {
    host,
    join,
};

pub const Player = struct {
    focus: Tile,
    selected: ?Tile,
};

pub const Status = union(enum) {
    play: Side,
    win: Side,

    pub fn eql(lhs: Status, rhs: Status) bool {
        // Cheap hack!
        const size = @sizeOf(Status);
        const lhs_bytes = @as(*const [size]u8, @ptrCast(@alignCast(&lhs)));
        const rhs_bytes = @as(*const [size]u8, @ptrCast(@alignCast(&rhs)));
        return std.mem.eql(u8, lhs_bytes, rhs_bytes);
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

pub fn new(role: ?Role) Self {
    var self = Self{
        .role = role,
        .status = undefined,
        .board = undefined,
        .player_local = undefined,
        .player_remote = undefined,
    };
    self.resetGame();
    return self;
}

pub fn resetGame(self: *Self) void {
    const FOCUS_WHITE = Tile{ .rank = 5, .file = 6 };
    const FOCUS_BLACK = Tile{ .rank = 2, .file = 1 };

    self.status = .{ .play = .white };
    self.board = Board.new();

    self.player_local = .{
        .focus = if (self.role == .join) FOCUS_BLACK else FOCUS_WHITE,
        .selected = null,
    };
    self.player_remote = if (self.role == null) null else .{
        .focus = if (self.role == .join) FOCUS_WHITE else FOCUS_BLACK,
        .selected = null,
    };
}

pub fn getLocalSide(self: *const Self) Side {
    return if (self.role == .host) .white else .black;
}

pub fn isLocalSideActive(self: *const Self) bool {
    switch (self.status) {
        .play => |active_side| {
            return self.role == null or
                active_side == self.getLocalSide();
        },
        else => return false,
    }
}

pub fn getAvailableMove(self: *const Self, origin: Tile, destination: Tile) ?Move {
    var available_moves = self.board.getAvailableMoves(origin);
    while (available_moves.next()) |available| {
        if (available.destination.eql(destination)) {
            return available;
        }
    }
    return null;
}
