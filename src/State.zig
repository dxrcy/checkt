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

pub fn moveFocus(self: *Self, direction: enum { left, right, up, down }) void {
    assert(self.status == .play);

    const player = &self.player_local;
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

// TODO: Rename
pub fn toggleSelection(self: *Self, allow_invalid: bool) void {
    const side = switch (self.status) {
        .play => |side| side,
        else => unreachable,
    };

    if (!self.isSelfActive()) {
        return;
    }

    const player = &self.player_local;

    const selected = player.selected orelse {
        const piece = self.board.get(player.focus);
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

    const piece = self.board.get(selected);
    assert(piece.?.side == side);

    if (allow_invalid) {
        if (self.board.get(player.focus)) |piece_taken| {
            self.board.addTaken(piece_taken);
        }
        self.board.set(player.focus, piece);
        self.board.set(selected, null);
        player.selected = null;
        if (!self.updateStatus()) {
            self.status = .{ .play = side.flip() };
        }
        return;
    }

    const move = self.getAvailableMove(selected, player.focus) orelse
        return;
    assert(move.destination.eql(player.focus));

    self.board.applyMove(selected, move);
    player.selected = null;

    if (!self.updateStatus()) {
        self.status = .{ .play = side.flip() };
    }
}

pub fn isSelfActive(self: *const Self) bool {
    const side = switch (self.status) {
        .play => |side| side,
        else => return false,
    };
    if (self.role == null) {
        return true;
    }
    return (side == .white) == (self.role == .host);
}

fn updateStatus(self: *Self) bool {
    const alive_white = self.board.isPieceAlive(.{ .kind = .king, .side = .white });
    const alive_black = self.board.isPieceAlive(.{ .kind = .king, .side = .black });

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
