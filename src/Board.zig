const Self = @This();

const std = @import("std");
const assert = std.debug.assert;

const serde = @import("serde.zig");

const State = @import("State.zig");
const Side = State.Side;

const moves = @import("moves.zig");
const Move = moves.Move;
const AvailableMoves = moves.AvailableMoves;

// TODO: Rename
const TileIndex = u16;

pub const SIZE: TileIndex = 8;
pub const MAX_PIECE_COUNT: usize = SIZE * 2 * Side.COUNT;

tiles: [SIZE * SIZE]TileEntry,
// TODO: Move to `State`
taken: [Piece.Kind.COUNT * Side.COUNT]u32,

// TODO: Make better
// TODO: Document
pub const TileEntry = packed struct(u7) {
    // TODO: Rename
    kind: enum(u1) { empty, full },
    data: packed union {
        empty: void,
        full: packed struct(u6) {
            piece: Piece,
            changed: bool,
            // TODO: Document
            special: bool,
        },
    },

    const empty = @This(){
        .kind = .empty,
        .data = .{ .empty = {} },
    };

    pub fn serialize(self: *const TileEntry, writer: *std.Io.Writer) serde.SerError!void {
        try serde.serialize(u7, &@bitCast(self.*), writer);
    }

    pub fn deserialize(
        reader: *std.Io.Reader,
    ) serde.DeError!TileEntry {
        return @bitCast(try serde.deserialize(u7, reader));
    }
};

pub const PieceUpdate = struct {
    index: usize,
    entry: TileEntry,
};

pub fn new() Self {
    var self = Self{
        .tiles = [_]TileEntry{.empty} ** SIZE ** SIZE,
        .taken = [1]u32{0} ** (Piece.Kind.COUNT * Side.COUNT),
    };

    for (0..8) |i| {
        const file: TileIndex = @intCast(i);
        _ = self.set(.{ .rank = 1, .file = file }, .{ .kind = .pawn, .side = .black });
        _ = self.set(.{ .rank = 6, .file = file }, .{ .kind = .pawn, .side = .white });
    }
    for ([2]usize{ 0, 7 }, [2]Side{ .black, .white }) |i, side| {
        const rank: TileIndex = @intCast(i);
        _ = self.set(.{ .rank = rank, .file = 0 }, .{ .kind = .rook, .side = side });
        _ = self.set(.{ .rank = rank, .file = 1 }, .{ .kind = .knight, .side = side });
        _ = self.set(.{ .rank = rank, .file = 2 }, .{ .kind = .bishop, .side = side });
        _ = self.set(.{ .rank = rank, .file = 4 }, .{ .kind = .king, .side = side });
        _ = self.set(.{ .rank = rank, .file = 3 }, .{ .kind = .queen, .side = side });
        _ = self.set(.{ .rank = rank, .file = 5 }, .{ .kind = .bishop, .side = side });
        _ = self.set(.{ .rank = rank, .file = 6 }, .{ .kind = .knight, .side = side });
        _ = self.set(.{ .rank = rank, .file = 7 }, .{ .kind = .rook, .side = side });
    }

    for (0..SIZE * SIZE) |i| {
        switch (self.tiles[i].kind) {
            .full => {
                var full = &self.tiles[i].data.full;
                full.changed = false;
            },
            else => {},
        }
    }

    return self;
}

pub fn get(self: *const Self, tile: Tile) ?Piece {
    assert(tile.isInBounds());

    const entry = self.tiles[tile.rank * SIZE + tile.file];

    switch (entry.kind) {
        .empty => return null,
        .full => {
            return entry.data.full.piece;
        },
    }
}

pub fn set(self: *Self, tile: Tile, piece: ?Piece) PieceUpdate {
    return self.setInner(tile, piece, false);
}

// TODO: Make better
// PERF: Return `null` if no change was made
pub fn setInner(self: *Self, tile: Tile, piece: ?Piece, special: bool) PieceUpdate {
    assert(tile.isInBounds());

    const entry = if (piece) |piece_unwrapped|
        TileEntry{
            .kind = .full,
            .data = .{ .full = .{
                .piece = piece_unwrapped,
                .changed = true,
                .special = special,
            } },
        }
    else
        TileEntry.empty;

    const index = tile.rank * SIZE + tile.file;
    self.tiles[index] = entry;

    return .{ .index = index, .entry = entry };
}

pub fn hasChanged(self: *const Self, tile: Tile) bool {
    assert(tile.isInBounds());

    const entry = self.tiles[tile.rank * SIZE + tile.file];

    switch (entry.kind) {
        .empty => return false,
        .full => return entry.data.full.changed,
    }
}

pub fn isSpecial(self: *const Self, tile: Tile) bool {
    assert(tile.isInBounds());

    const entry = self.tiles[tile.rank * SIZE + tile.file];

    switch (entry.kind) {
        .empty => return false,
        .full => return entry.data.full.special,
    }
}

pub fn getTaken(self: *const Self, piece: Piece) u32 {
    return self.taken[piece.toInt()];
}

pub fn setTaken(self: *Self, piece: Piece, count: u32) void {
    self.taken[piece.toInt()] = count;
}

pub fn addTaken(self: *Self, piece: Piece) void {
    self.taken[piece.toInt()] += 1;
}

// TODO: Create iterator for pieces/tiles?

pub fn getTileOfFirst(self: *const Self, target: Piece) ?Tile {
    for (0..SIZE) |rank| {
        for (0..SIZE) |file| {
            const tile = Tile{ .rank = @intCast(rank), .file = @intCast(file) };
            const piece = self.get(tile) orelse
                continue;
            if (piece.eql(target)) {
                return tile;
            }
        }
    }
    return null;
}

pub fn isPieceAlive(self: *const Self, target: Piece) bool {
    return self.getTileOfFirst(target) != null;
}

pub fn getAvailableMoves(board: *const Self, origin: Tile) AvailableMoves {
    return AvailableMoves.new(board, origin, false);
}

pub fn getKing(self: *const Self, side: Side) Tile {
    return self.getTileOfFirst(.{
        .kind = .king,
        .side = side,
    }) orelse unreachable;
}

pub fn isSideAttackedAt(self: *const Self, side: Side, target: Tile) bool {
    for (0..SIZE) |rank| {
        for (0..SIZE) |file| {
            const tile = Tile{ .rank = @intCast(rank), .file = @intCast(file) };

            const piece = self.get(tile) orelse
                continue;
            if (piece.side != side.flip()) {
                continue;
            }

            var available_moves = AvailableMoves.new(self, tile, true);
            while (available_moves.next()) |available| {
                const take = available.take orelse available.destination;
                if (take.eql(target)) {
                    return true;
                }
            }
        }
    }
    return false;
}

pub fn isSideInCheck(self: *const Self, side: Side) bool {
    return self.isSideAttackedAt(side, self.getKing(side));
}

/// Does **not** validate move.
// TODO: Create type for return array
pub fn applyMove(self: *Self, origin: Tile, move: Move) [4]?PieceUpdate {
    if (move.take) |take| {
        const piece_taken = self.get(take) orelse unreachable;
        self.addTaken(piece_taken);
        // TODO: Is this right
        // self.set(take, null);
    }

    var updates = [1]?PieceUpdate{null} ** 4;

    if (move.move_alt) |move_alt| {
        const updates_new = self.movePieceOverride(
            move_alt.origin,
            move_alt.destination,
            false,
        );
        updates[2] = updates_new[0];
        updates[3] = updates_new[1];
    }

    {
        const updates_new = self.movePieceOverride(
            origin,
            move.destination,
            move.mark_special,
        );
        updates[0] = updates_new[0];
        updates[1] = updates_new[1];
    }

    return updates;
}

/// Clobbers any existing piece in `destination`.
// TODO: Rename
pub fn movePieceOverride(
    self: *Self,
    origin: Tile,
    destination: Tile,
    special: bool,
) [2]PieceUpdate {
    const piece = self.get(origin) orelse unreachable;

    const update_destination = self.setInner(destination, piece, special);
    const update_origin = self.set(origin, null);

    return [2]PieceUpdate{
        update_destination,
        update_origin,
    };
}

pub const Tile = struct {
    rank: TileIndex,
    file: TileIndex,

    pub fn eql(lhs: Tile, rhs: Tile) bool {
        return lhs.rank == rhs.rank and lhs.file == rhs.file;
    }

    pub fn isEven(self: Tile) bool {
        return (self.rank + self.file) % 2 == 0;
    }

    pub fn isInBounds(self: Tile) bool {
        return self.rank < SIZE and self.file < SIZE;
    }
};

pub const Piece = packed struct {
    kind: Kind,
    side: Side,

    pub const Kind = enum(u3) {
        pawn,
        rook,
        knight,
        bishop,
        king,
        queen,

        pub const COUNT: u8 = @typeInfo(Kind).@"enum".fields.len;
    };

    pub const HEIGHT: usize = 3;
    pub const WIDTH: usize = 3;

    pub fn string(self: Piece) *const [HEIGHT * WIDTH]u8 {
        return switch (self.kind) {
            .pawn =>
            \\ _ (_)/_\
            ,
            .rook =>
            \\vvv]_[[_]
            ,
            .knight =>
            \\/'|"/|/_|
            ,
            .bishop =>
            \\(^))_(/_\
            ,
            .king =>
            \\[+])_(/_\
            ,
            .queen =>
            \\\^/]_[/_\
            ,
        };
    }

    pub fn eql(lhs: Piece, rhs: Piece) bool {
        return lhs.kind == rhs.kind and lhs.side == rhs.side;
    }

    pub fn fromInt(value: u8) Piece {
        return Piece{
            .kind = @enumFromInt(value % Kind.COUNT),
            .side = @enumFromInt(value / Kind.COUNT),
        };
    }

    pub fn toInt(self: Piece) u8 {
        return @intFromEnum(self.kind) +
            @intFromEnum(self.side) * Kind.COUNT;
    }
};
