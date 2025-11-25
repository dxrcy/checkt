const moves = @import("moves.zig");
const MoveRule = moves.MoveRule;
const Offset = moves.Offset;

pub const RULES = &[_][]const MoveRule{
    // PAWN
    &[_]MoveRule{
        .{
            .dest = .{ .single = .{ .advance = .{ .rank = 1, .file = 0 } } },
            .requirement = .{ .take = .never },
        },
        // First move, 2 tiles
        .{
            .dest = .{ .single = .{ .advance = .{ .rank = 2, .file = 0 } } },
            .mark_special = true,
            .requirement = .{
                .take = .never,
                .first_move = true,
                .free = .{ .advance = .{ .rank = 1, .file = 0 } },
            },
        },
        // Normal take
        .{
            .dest = .{ .single = .{ .advance = .{ .rank = 1, .file = -1 } } },
            .requirement = .{ .take = .always },
        },
        .{
            .dest = .{ .single = .{ .advance = .{ .rank = 1, .file = 1 } } },
            .requirement = .{ .take = .always },
        },
        // En-passant take
        .{
            .dest = .{ .single = .{ .advance = .{ .rank = 1, .file = -1 } } },
            .take_alt = .{ .absolute = .{ .rank = 0, .file = -1 } },
            .requirement = .{
                .take = .always,
                .take_special = true,
            },
        },
        .{
            .dest = .{ .single = .{ .advance = .{ .rank = 1, .file = 1 } } },
            .take_alt = .{ .absolute = .{ .rank = 0, .file = 1 } },
            .requirement = .{
                .take = .always,
                .take_special = true,
            },
        },
    },

    // ROOK
    &[_]MoveRule{
        .{ .dest = .{ .many = .{ .rank = -1, .file = 0 } } },
        .{ .dest = .{ .many = .{ .rank = 1, .file = 0 } } },
        .{ .dest = .{ .many = .{ .rank = 0, .file = -1 } } },
        .{ .dest = .{ .many = .{ .rank = 0, .file = 1 } } },
    },

    // KNIGHT
    &[_]MoveRule{
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = -1, .file = -2 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = -2, .file = -1 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = -1, .file = 2 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = -2, .file = 1 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 1, .file = -2 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 2, .file = -1 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 1, .file = 2 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 2, .file = 1 } } } },
    },

    // BISHOP
    &[_]MoveRule{
        .{ .dest = .{ .many = .{ .rank = -1, .file = -1 } } },
        .{ .dest = .{ .many = .{ .rank = -1, .file = 1 } } },
        .{ .dest = .{ .many = .{ .rank = 1, .file = -1 } } },
        .{ .dest = .{ .many = .{ .rank = 1, .file = 1 } } },
    },

    // KING
    &[_]MoveRule{
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = -1, .file = -1 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = -1, .file = 0 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = -1, .file = 1 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 0, .file = -1 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 0, .file = 1 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 1, .file = -1 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 1, .file = 0 } } } },
        .{ .dest = .{ .single = .{ .absolute = .{ .rank = 1, .file = 1 } } } },
        // Castling (kingside)
        .{
            .dest = .{ .single = .{ .absolute = .{ .rank = 0, .file = 2 } } },
            .move_alt = .{
                .kind = .rook,
                .origin = .{ .absolute = .{ .rank = 0, .file = 3 } },
                .destination = .{ .absolute = .{ .rank = 0, .file = 1 } },
            },
            .requirement = .{
                .take = .never,
                .first_move = true,
                .not_attacked = &[_]Offset{
                    .{ .absolute = .{ .rank = 0, .file = 0 } },
                    .{ .absolute = .{ .rank = 0, .file = 1 } },
                    .{ .absolute = .{ .rank = 0, .file = 2 } },
                },
            },
        },
        // Castling (queenside)
        .{
            .dest = .{ .single = .{ .absolute = .{ .rank = 0, .file = -3 } } },
            .move_alt = .{
                .kind = .rook,
                .origin = .{ .absolute = .{ .rank = 0, .file = -4 } },
                .destination = .{ .absolute = .{ .rank = 0, .file = -2 } },
            },
            .requirement = .{
                .take = .never,
                .first_move = true,
                .free = .{ .absolute = .{ .rank = 0, .file = -1 } },
                .not_attacked = &[_]Offset{
                    .{ .absolute = .{ .rank = 0, .file = 0 } },
                    .{ .absolute = .{ .rank = 0, .file = -1 } },
                    .{ .absolute = .{ .rank = 0, .file = -2 } },
                    .{ .absolute = .{ .rank = 0, .file = -3 } },
                },
            },
        },
    },

    // QUEEN
    &[_]MoveRule{
        .{ .dest = .{ .many = .{ .rank = -1, .file = 0 } } },
        .{ .dest = .{ .many = .{ .rank = 1, .file = 0 } } },
        .{ .dest = .{ .many = .{ .rank = 0, .file = -1 } } },
        .{ .dest = .{ .many = .{ .rank = 0, .file = 1 } } },
        .{ .dest = .{ .many = .{ .rank = -1, .file = -1 } } },
        .{ .dest = .{ .many = .{ .rank = -1, .file = 1 } } },
        .{ .dest = .{ .many = .{ .rank = 1, .file = -1 } } },
        .{ .dest = .{ .many = .{ .rank = 1, .file = 1 } } },
    },
};
