const std = @import("std");
const assert = std.debug.assert;

const Board = @import("Board.zig");
const Tile = Board.Tile;
const Piece = Board.Piece;

const RULES = @import("move_rules.zig").RULES;

pub const Move = struct {
    destination: Tile,
    take: ?Tile,
    move_alt: ?MoveAlt,
    mark_special: bool,

    const MoveAlt = struct {
        origin: Tile,
        destination: Tile,

        pub fn eql(lhs: MoveAlt, rhs: MoveAlt) bool {
            return lhs.origin.eql(rhs.origin) and
                lhs.destination.eql(rhs.destination);
        }
    };

    pub fn eql(lhs: Move, rhs: Move) bool {
        return lhs.destination.eql(rhs.destination) and
            optionalEql(lhs.take, rhs.take) and
            optionalEql(lhs.move_alt, rhs.move_alt) and
            lhs.mark_special == rhs.mark_special;
    }

    fn optionalEql(lhs: anytype, rhs: anytype) bool {
        return (lhs == null and rhs == null) or
            (lhs != null and rhs != null and lhs.?.eql(rhs.?));
    }
};

pub const AvailableMoves = struct {
    const Self = @This();

    board: *const Board,
    origin: Tile,

    /// If `true`, requirement checking will never itself check available moves
    /// (recursively).
    /// To prevent recursion >1 for check/attacked requirement.
    no_recurse: bool,

    /// Index of next rule to consider.
    index: usize,
    /// For `MoveRule.position.many`.
    /// Index/scale of next option in rule.
    many_index: usize,

    pub fn new(board: *const Board, origin: Tile, no_recurse: bool) Self {
        return Self{
            .board = board,
            .origin = origin,
            .no_recurse = no_recurse,
            .index = 0,
            .many_index = 0,
        };
    }

    pub fn next(self: *AvailableMoves) ?Move {
        const piece = self.board.get(self.origin) orelse
            return null;
        const rules = RULES[@intFromEnum(piece.kind)];

        while (self.index < rules.len) {
            const rule = rules[self.index];

            const move = self.tryApplyRule(rule, piece) orelse {
                continue;
            };
            if (!self.checkAllows(piece, move)) {
                continue;
            }
            return move;
        }
        return null;
    }

    fn checkAllows(self: *Self, piece: Piece, move: Move) bool {
        if (self.no_recurse or !self.board.isSideInCheck(piece.side)) {
            return true;
        }

        // PERF: Could reuse board if we really care
        var board = Board.new();
        @memcpy(&board.tiles, &self.board.tiles);
        board.applyMove(self.origin, move);

        return !board.isSideInCheck(piece.side);
    }

    fn tryApplyRule(self: *Self, rule: MoveRule, piece: Piece) ?Move {
        switch (rule.dest) {
            .single => |offset| {
                self.updateIndex();

                const move = self.calculateMove(
                    rule,
                    piece,
                    offset.applyTo(self.origin, piece),
                ) orelse {
                    return null;
                };
                return move;
            },

            .many => |many| {
                assert(self.many_index <= Board.SIZE * Board.SIZE);
                self.many_index += 1;

                const move = self.calculateMove(
                    rule,
                    piece,
                    many.scale(self.many_index).applyTo(self.origin),
                ) orelse {
                    self.updateIndex();
                    return null;
                };

                if (self.board.get(move.destination) != null) {
                    self.updateIndex();
                }
                return move;
            },
        }
    }

    fn updateIndex(self: *Self) void {
        self.index += 1;
        self.many_index = 0;
    }

    fn calculateMove(
        self: *const Self,
        rule: MoveRule,
        piece: Piece,
        destination_opt: ?Tile,
    ) ?Move {
        const destination = destination_opt orelse {
            return null;
        };

        const context = Requirement.Context{
            .board = self.board,
            .piece = piece,
            .origin = self.origin,
            .destination = destination,
            .no_recurse = self.no_recurse,
            .rule = rule,
        };

        if (!rule.requirement.isSatisfied(context)) {
            return null;
        }

        // TODO: Extract as method?
        const move_alt = if (rule.move_alt) |move_alt| blk: {
            break :blk Move.MoveAlt{
                .origin = move_alt.origin.applyTo(self.origin, piece) orelse
                    unreachable,
                .destination = move_alt.destination.applyTo(self.origin, piece) orelse
                    unreachable,
            };
        } else null;

        return Move{
            .destination = destination,
            .take = context.getTakeTile(),
            .move_alt = move_alt,
            .mark_special = rule.mark_special,
        };
    }
};

pub const MoveRule = struct {
    dest: union(enum) {
        single: Offset,
        many: AbsoluteOffset,
    },
    /// If piece to take is different to destination (eg. in en-passant).
    take_alt: ?Offset = null,
    /// If another piece of the same colour is moved (eg. in castling).
    move_alt: ?MoveAlt = null,
    // TODO: Document
    mark_special: bool = false,
    requirement: Requirement = .{},

    const MoveAlt = struct {
        kind: Piece.Kind,
        origin: Offset,
        destination: Offset,
    };
};

/// Use `null` for any unrestricted fields.
pub const Requirement = struct {
    const Self = @This();

    /// Whether a piece must take (`always`), must **not** take (`never`).
    take: ?enum { always, never } = null,
    /// If `true`, rule is invalid if piece has ever moved (including moving
    /// back to original tile).
    /// This includes any pieces moved by `MoveRule.move_alt`; they must have
    /// also not moved before.
    /// For 2-tile pawn move and castling.
    first_move: bool = false,
    // TODO: Document
    take_special: bool = false,
    /// Requires this tile to be free. Treats out-of-bounds tiles as free.
    /// For en-passant.
    /// Similar to `MoveRule.position.many`.
    free: ?Offset = null,
    /// If `true`, rule is invalid while in this piece is attacked by other
    /// side.
    not_attacked: []const Offset = &[0]Offset{},

    pub fn isSatisfied(self: *const Self, context: Context) bool {
        // Can never take/overwrite own piece
        if (context.board.get(context.destination)) |piece_take| {
            if (piece_take.side == context.piece.side) {
                return false;
            }
        }

        return self.isTakeSatisfied(context) and
            self.isFirstMoveSatisfied(context) and
            self.isTakeSpecialSatisfied(context) and
            self.isFreeSatisfied(context) and
            self.isNotAttackedSatisfied(context) and
            self.isMoveAltSatisfied(context);
    }

    fn isTakeSatisfied(self: *const Self, context: Context) bool {
        const take = self.take orelse {
            return true;
        };

        const will_take = context.willTake();
        return switch (take) {
            .always => will_take == .take,
            .never => will_take == .no_take,
        };
    }

    fn isFirstMoveSatisfied(self: *const Self, context: Context) bool {
        if (!self.first_move) {
            return true;
        }
        if (context.board.hasChanged(context.origin)) {
            return false;
        }
        if (context.rule.move_alt) |move_alt| {
            const origin = move_alt.origin.applyTo(context.origin, context.piece) orelse {
                // Out-of-bounds `move_alt` should be handled elsewhere
                return true;
            };
            if (context.board.hasChanged(origin)) {
                return false;
            }
        }
        return true;
    }

    fn isTakeSpecialSatisfied(self: *const Self, context: Context) bool {
        if (!self.take_special) {
            return true;
        }
        assert(self.take == .always);

        const tile_take = context.getTakeTileUnchecked() orelse {
            return false;
        };
        const piece_take = context.board.get(tile_take) orelse {
            return false;
        };
        if (piece_take.side == context.piece.side) {
            return false;
        }
        return context.board.isSpecial(tile_take);
    }

    fn isFreeSatisfied(self: *const Self, context: Context) bool {
        const free = self.free orelse {
            return true;
        };

        const tile = free.applyTo(context.origin, context.piece) orelse {
            return true;
        };
        return context.board.get(tile) == null;
    }

    fn isNotAttackedSatisfied(self: *const Self, context: Context) bool {
        if (context.no_recurse) {
            return true;
        }

        for (self.not_attacked) |offset| {
            const target = offset.applyTo(context.origin, context.piece) orelse
                continue;

            if (context.board.isSideAttackedAt(context.piece.side, target)) {
                return false;
            }
        }

        return true;
    }

    fn isMoveAltSatisfied(self: *const Self, context: Context) bool {
        _ = self;
        const move_alt = context.rule.move_alt orelse {
            return true;
        };

        const origin = move_alt.origin.applyTo(context.origin, context.piece) orelse {
            return false;
        };
        const piece = context.board.get(origin) orelse {
            return false;
        };
        if (piece.kind != move_alt.kind or
            piece.side != context.piece.side)
        {
            return false;
        }

        const destination = move_alt.destination.applyTo(context.origin, context.piece) orelse {
            return false;
        };
        if (context.board.get(destination) != null) {
            return false;
        }

        return true;
    }

    pub const Context = struct {
        board: *const Board,
        piece: Piece,
        origin: Tile,
        destination: Tile,
        no_recurse: bool,
        rule: MoveRule,

        pub fn willTake(self: *const Context) enum { invalid, take, no_take } {
            const tile_take = self.getTakeTileUnchecked() orelse {
                return .invalid;
            };
            const piece_take = self.board.get(tile_take) orelse {
                return .no_take;
            };
            if (piece_take.side == self.piece.side) {
                return .invalid;
            }
            return .take;
        }

        /// Returns `null` if tile is out-of-bounds **OR** empty.
        /// Asserts piece-to-take is opposite color.
        pub fn getTakeTile(self: *const Context) ?Tile {
            const tile = self.getTakeTileUnchecked() orelse
                return null;
            const piece = self.board.get(tile) orelse
                return null;
            assert(piece.side == self.piece.side.flip());
            return tile;
        }

        /// Returns `null` if tile is out-of-bounds.
        /// Does **NOT** check any status of piece-to-take.
        pub fn getTakeTileUnchecked(self: *const Context) ?Tile {
            if (self.rule.take_alt) |take| {
                return take.applyTo(self.origin, self.piece);
            }
            return self.destination;
        }
    };
};

/// An offset which is dependant on the piece's attributes (eg. color determines
/// direction).
// TODO: (DO LATER) Depending on how many variants are added, this abstraction
// could possibly be removed or improved somehow.
pub const Offset = union(enum) {
    absolute: AbsoluteOffset,
    advance: AbsoluteOffset,

    pub fn applyTo(self: Offset, tile: Tile, piece: Piece) ?Tile {
        switch (self) {
            .absolute => |offset| {
                return offset.applyTo(tile);
            },
            .advance => |offset| {
                var real_offset = offset;
                real_offset.rank *= if (piece.side == .white) -1 else 1;
                return real_offset.applyTo(tile);
            },
        }
    }
};

/// An offset which is independant of a piece's attributes, ie. absolute offset
/// on the board.
pub const AbsoluteOffset = struct {
    const Self = @This();

    rank: isize,
    file: isize,

    pub fn applyTo(self: Self, tile: Tile) ?Tile {
        const rank = @as(isize, @intCast(tile.rank)) + self.rank;
        const file = @as(isize, @intCast(tile.file)) + self.file;

        if (rank < 0 or file < 0 or rank >= Board.SIZE or file >= Board.SIZE) {
            return null;
        }

        return Tile{
            .rank = @intCast(rank),
            .file = @intCast(file),
        };
    }

    pub fn scale(self: Self, amount: usize) Self {
        return Self{
            .rank = self.rank * @as(isize, @intCast(amount)),
            .file = self.file * @as(isize, @intCast(amount)),
        };
    }
};
