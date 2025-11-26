const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;

const Game = @import("../game/Game.zig");
const Board = Game.Board;
const Piece = Board.Piece;
const Side = Game.Side;
const Tile = Game.Tile;

const Frame = @import("Frame.zig");
const Cell = Frame.Cell;
const Position = Frame.Position;
const Terminal = @import("Terminal.zig");
const Color = Terminal.Attributes.Color;
const text = @import("text.zig");

terminal: Terminal,
frames: [2]Frame,
current_frame: u1,

ascii: bool,
small: bool,

debug_render_info: bool,

pub const tile_size = struct {
    pub const WIDTH: usize = Piece.WIDTH + PADDING_LEFT + PADDING_RIGHT;
    pub const HEIGHT: usize = Piece.HEIGHT + PADDING_TOP + PADDING_BOTTOM;

    const WIDTH_SMALL: usize = 6;
    const HEIGHT_SMALL: usize = 3;
    const PADDING_LEFT_SMALL: usize = 2;
    const PADDING_TOP_SMALL: usize = 1;

    const PADDING_LEFT: usize = 3;
    const PADDING_RIGHT: usize = 3;
    const PADDING_TOP: usize = 1;
    const PADDING_BOTTOM: usize = 1;
};

const Edge = enum {
    left,
    right,
    top,
    bottom,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

const Rect = struct {
    position: Position,
    size: Position,
};

pub fn new(ascii: bool, small: bool) Self {
    return Self{
        .terminal = Terminal.new(),
        .frames = [1]Frame{Frame.new()} ** 2,
        .current_frame = 0,
        .ascii = ascii,
        .small = small,
        .debug_render_info = false,
    };
}

pub fn enter(self: *Self) !void {
    self.terminal.setAlternativeScreen(.enter);
    self.terminal.setCursorVisibility(.hidden);
    self.terminal.flush();

    try self.terminal.saveTermios();
    var termios = self.terminal.original_termios orelse unreachable;
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.lflag.ISIG = false;
    try self.terminal.setTermios(termios);
}

pub fn exit(self: *Self) !void {
    self.terminal.setCursorVisibility(.visible);
    self.terminal.setAlternativeScreen(.exit);
    self.terminal.flush();

    try self.terminal.restoreTermios();
}

/// Clear back frame and erase terminal screen.
/// Does **not** clear fore frame; this would be unnecessary.
pub fn clear(self: *Self) void {
    self.getBackFrame().clear();
    self.terminal.clearEntireScreen();
}

const colors = struct {
    pub const TILE_WHITE = .bright_black;
    pub const TILE_BLACK = .black;

    pub const PIECE_WHITE = .red;
    pub const PIECE_BLACK = .cyan;

    pub const AVAILABLE = .bright_white;
    pub const UNAVAILABLE = .white;
    pub const ALTERNATIVE = .white;

    pub const PLACEHOLDER = .bright_black;
    pub const HIGHLIGHT = .yellow;

    pub const REMOTE = .blue;
};

pub fn render(self: *Self, game: *const Game) void {
    self.getForeFrame().clear();

    // Board tile
    for (0..Board.SIZE) |rank| {
        for (0..Board.SIZE) |file| {
            const tile = Tile{ .rank = @intCast(rank), .file = @intCast(file) };
            self.renderRectSolid(self.getTileRect(tile), .{
                .char = ' ',
                .bg = getTileColor(tile, false),
            });
        }
    }

    if (game.state.getBoard()) |board| {
        // Board piece icons
        for (0..Board.SIZE) |rank| {
            for (0..Board.SIZE) |file| {
                const tile = Tile{ .rank = @intCast(rank), .file = @intCast(file) };
                if (board.get(tile)) |piece| {
                    self.renderPiece(piece, tile, .{});
                }
            }
        }

        // Taken piece icons
        for (std.meta.tags(Side), 0..) |side, y| {
            var x: usize = 0;

            for (std.meta.tags(Piece.Kind)) |kind| {
                const piece = Piece{ .kind = kind, .side = side };

                const count = board.getTaken(piece);
                if (count == 0) {
                    continue;
                }

                const tile = Tile{
                    .rank = @intCast(Board.SIZE + y),
                    .file = @intCast(x % Board.SIZE),
                };

                self.renderPiece(piece, tile, .{});

                if (count > 1) {
                    const position: Position = if (self.small) .{
                        .y = tile.rank * tile_size.HEIGHT_SMALL + 1,
                        .x = tile.file * tile_size.WIDTH_SMALL + tile_size.PADDING_LEFT_SMALL + 2,
                    } else .{
                        .y = tile.rank * tile_size.HEIGHT + 1,
                        .x = tile.file * tile_size.WIDTH + tile_size.PADDING_LEFT + Piece.WIDTH + 1,
                    };

                    self.renderDecimalInt(
                        count,
                        position,
                        .{
                            .fg = colors.HIGHLIGHT,
                            .bold = true,
                        },
                    );
                }

                x += 1;
            }

            // Placeholder
            if (x == 0) {
                const piece = Piece{ .kind = .pawn, .side = side };
                const tile = Tile{
                    .rank = @intCast(Board.SIZE + y),
                    .file = @intCast(x % Board.SIZE),
                };

                self.renderPiece(piece, tile, .{
                    .fg = colors.PLACEHOLDER,
                    .bold = false,
                });
            }
        }
    }

    switch (game.state) {
        .connect => |*connect| {
            self.renderTextLarge(
                &[_][]const u8{
                    "chess",
                },
                .center_x,
                if (self.small)
                    .{ .y = 3 }
                else
                    .{ .y = 8 },
            );

            const ORIGIN =
                if (self.small)
                    Position{ .y = 10, .x = 0 }
                else
                    Position{ .y = 17, .x = 0 };
            const SIZE =
                if (self.small)
                    Position{ .y = 3, .x = 20 }
                else
                    Position{ .y = 3, .x = 24 };
            const GAP_Y: usize = if (self.small) 1 else 2;
            const PADDING_Y = 1;

            const lines = [_][]const u8{
                "Singleplayer",
                "Host a game",
                "Join a game",
            };

            for (lines, 0..) |line, i| {
                const focus = (i == connect.button_focus);

                const rect = Rect{
                    .position = ORIGIN.add(.{
                        .y = (SIZE.y + GAP_Y) * i,
                    }),
                    .size = SIZE,
                };

                const aligned = Alignment.applyRect(.center_x, self.small, rect);

                // TODO: The following can be extracted as a `renderButton`
                // method

                self.renderRectSolid(aligned, .{
                    .bg = if (focus) .bright_white else .white,
                });
                self.renderRectHighlight(aligned, .{
                    .fg = if (focus) .white else .bright_white,
                    .bold = true,
                });

                self.renderTextLineNormal(
                    line,
                    .center_x,
                    rect.position.add(.{
                        .y = PADDING_Y,
                    }),
                    .{
                        .fg = .black,
                        .bold = (focus),
                    },
                );
            }
        },

        .start => {
            self.renderTextLarge(
                &[_][]const u8{
                    "ready?",
                },
                .center_x,
                if (self.small)
                    .{ .y = 8 }
                else
                    .{ .y = 16 },
            );

            self.renderTextLineNormal(
                "Press SPACE to start",
                .center_x,
                .{ .y = if (self.small) 15 else 23 },
                .{ .bold = true },
            );
        },

        .win => |win| {
            self.renderTextLarge(
                &[_][]const u8{
                    "game",
                    "over",
                },
                .center_x,
                if (self.small)
                    .{ .y = 6 }
                else
                    .{ .y = 14 },
            );

            self.renderTextLineNormal(
                if (win.winner == .white)
                    "Blue wins"
                else
                    "Red wins",
                .center_x,
                .{ .y = if (self.small) 18 else 26 },
                .{ .bold = true },
            );
        },

        .play => |play| {
            const player = play.player_local;

            const side: Side = if (game.role == .single)
                play.active
            else
                (if (game.role == .host) .white else .black);

            // Highlight check
            if (play.board.isSideInCheck(side)) {
                const king = play.board.getKing(side);
                self.renderRectSolid(self.getTileRect(king), .{
                    .bg = colors.UNAVAILABLE,
                });
                self.renderPiece(.{
                    .kind = .king,
                    .side = side,
                }, king, .{
                    .fg = getPieceColor(side),
                });
            }

            // Selected, available moves
            if (player.selected) |selected| {
                var available_moves = play.board.getAvailableMoves(selected);
                var has_available = false;
                while (available_moves.next()) |available| {
                    has_available = true;

                    if (play.board.get(available.destination)) |piece| {
                        // Take direct
                        self.renderPiece(piece, available.destination, .{
                            .fg = colors.AVAILABLE,
                        });
                    } else {
                        // No take or take indirect
                        const piece = play.board.get(selected) orelse
                            continue;

                        self.renderPiece(piece, available.destination, .{
                            .fg = getTileColor(available.destination, true),
                        });

                        // Take indirect (en passant)
                        if (available.take) |take| {
                            if (play.board.get(take)) |piece_take| {
                                self.renderPiece(piece_take, take, .{
                                    .fg = colors.ALTERNATIVE,
                                });
                            }
                        }
                    }

                    // Additionally moved pieces (castling)
                    if (available.move_alt) |move_alt| {
                        const piece = play.board.get(move_alt.origin) orelse unreachable;
                        self.renderPiece(piece, move_alt.origin, .{
                            .fg = colors.ALTERNATIVE,
                        });
                    }
                }

                // Highlight selected
                self.renderRectSolid(self.getTileRect(selected), .{
                    .bg = getPieceColor(side),
                });

                // Available move destination
                if (play.board.get(selected)) |piece| {
                    self.renderPiece(piece, selected, .{
                        .fg = if (has_available) colors.TILE_BLACK else colors.UNAVAILABLE,
                    });
                }
            }

            // Focus - remote
            if (play.player_remote) |player_remote| {
                if (player_remote.selected) |selected| {
                    self.renderRectSolid(self.getTileRect(selected), .{
                        .bg = colors.REMOTE,
                    });

                    if (play.board.get(selected)) |piece| {
                        self.renderPiece(piece, selected, .{
                            .fg = colors.TILE_BLACK,
                        });
                    }
                }

                self.renderRectHighlight(self.getTileRect(player_remote.focus), .{
                    .fg = colors.REMOTE,
                    .bold = true,
                });
            }

            // Focus - local
            self.renderRectHighlight(self.getTileRect(play.player_local.focus), .{
                .fg = if (game.isLocalSideActive())
                    getPieceColor(side)
                else
                    colors.UNAVAILABLE,
                .bold = true,
            });
        },
    }

    // DEBUG

    // if (self.last_ping) |last_ping| {
    //     const time_ms = (std.time.Instant.now() catch unreachable)
    //         .since(last_ping.*) / std.time.ns_per_ms;
    //
    //     var buffer: [32]u8 = undefined;
    //     const string = std.fmt.bufPrint(&buffer, "{:10}", .{time_ms}) catch unreachable;
    //     self.renderTextLineNormal(string, 0, 0, .{});
    // }
}

const Alignment = enum {
    normal,
    center_x,

    pub fn apply(
        self: Alignment,
        small: bool,
        offset: Position,
        size: Position,
    ) Position {
        const tile_width = if (small)
            tile_size.WIDTH_SMALL
        else
            tile_size.WIDTH;

        const screen_width = Board.SIZE * (tile_width);

        const origin: Position = switch (self) {
            .normal => .{},
            .center_x => .{
                .x = std.math.divCeil(usize, screen_width - size.x, 2) catch 0,
            },
        };

        return origin.add(offset);
    }

    pub fn applyRect(self: Alignment, small: bool, rect: Rect) Rect {
        return Rect{
            .position = self.apply(
                small,
                rect.position,
                rect.size,
            ),
            .size = rect.size,
        };
    }
};

fn renderTextLineNormal(
    self: *Self,
    line: []const u8,
    alignment: Alignment,
    offset: Position,
    options: Cell.Options,
) void {
    var frame = self.getForeFrame();

    const origin = alignment.apply(self.small, offset, .{
        .x = line.len,
    });

    for (line, 0..) |char, x| {
        frame.set(
            origin.add(.{ .x = x }),
            (Cell.Options{
                .char = char,
                .fg = .white,
                .bold = false,
            }).join(options),
        );
    }
}

fn renderTextLarge(
    self: *Self,
    lines: []const []const u8,
    alignment: Alignment,
    offset: Position,
) void {
    for (lines, 0..) |line, row| {
        self.renderTextLine(
            line,
            alignment,
            offset.add(.{
                .y = row * (text.HEIGHT + text.GAP_Y),
            }),
        );
    }
}

fn renderTextLine(
    self: *Self,
    line: []const u8,
    alignment: Alignment,
    offset: Position,
) void {
    var frame = self.getForeFrame();

    const origin = alignment.apply(self.small, offset, .{
        .x = text.WIDTH * line.len +
            text.GAP_X * (line.len -| 1),
    });

    for (line, 0..) |letter, i| {
        const template = text.largeLetter(letter);

        for (0..text.HEIGHT) |y| {
            for (0..text.WIDTH) |x| {
                const symbol = template[y * (text.WIDTH + 1) + x];
                const char = text.translateSymbol(symbol, self.ascii);

                frame.set(
                    origin.add(.{
                        .y = y,
                        .x = i * (text.WIDTH + text.GAP_X) + x,
                    }),
                    .{
                        .char = char,
                        .fg = .white,
                    },
                );
            }
        }
    }
}

fn renderDecimalInt(
    self: *Self,
    value: anytype,
    position: Position,
    options: Cell.Options,
) void {
    var frame = self.getForeFrame();

    const char = if (value < 10)
        @as(u8, @intCast(value)) + '0'
    else
        '*';

    frame.set(position, options.join(.{
        .char = char,
    }));
}

fn renderPiece(self: *Self, piece: Piece, tile: Tile, options: Cell.Options) void {
    var frame = self.getForeFrame();

    if (self.small) {
        frame.set(
            .{
                .y = tile.rank * tile_size.HEIGHT_SMALL + tile_size.PADDING_TOP_SMALL,
                .x = tile.file * tile_size.WIDTH_SMALL + tile_size.PADDING_LEFT_SMALL,
            },
            (Cell.Options{
                .char = piece.char(),
                .fg = getPieceColor(piece.side),
                .bold = true,
            }).join(options),
        );
        return;
    }

    const string = piece.string();

    for (0..Piece.HEIGHT) |y| {
        for (0..Piece.WIDTH) |x| {
            frame.set(
                .{
                    .y = tile.rank * tile_size.HEIGHT + y + tile_size.PADDING_TOP,
                    .x = tile.file * tile_size.WIDTH + x + tile_size.PADDING_LEFT,
                },
                (Cell.Options{
                    .char = string[y * Piece.WIDTH + x],
                    .fg = getPieceColor(piece.side),
                    .bold = true,
                }).join(options),
            );
        }
    }
}

fn getTileColor(tile: Tile, flip: bool) Color {
    return if (tile.isEven() != flip) colors.TILE_WHITE else colors.TILE_BLACK;
}
fn getPieceColor(side: Side) Color {
    return if (side == .white) colors.PIECE_WHITE else colors.PIECE_BLACK;
}

fn getTileRect(self: *const Self, tile: Tile) Rect {
    if (self.small) {
        return Rect{
            .position = .{
                .y = tile.rank * tile_size.HEIGHT_SMALL,
                .x = tile.file * tile_size.WIDTH_SMALL,
            },
            .size = .{
                .y = tile_size.HEIGHT_SMALL,
                .x = tile_size.WIDTH_SMALL,
            },
        };
    }

    return Rect{
        .position = .{
            .y = tile.rank * tile_size.HEIGHT,
            .x = tile.file * tile_size.WIDTH,
        },
        .size = .{
            .y = tile_size.HEIGHT,
            .x = tile_size.WIDTH,
        },
    };
}

fn renderRectSolid(
    self: *Self,
    rect: Rect,
    options: Cell.Options,
) void {
    var frame = self.getForeFrame();

    for (0..rect.size.y) |y| {
        for (0..rect.size.x) |x| {
            frame.set(rect.position.add(.{ .y = y, .x = x }), options);
        }
    }
}

fn renderRectHighlight(
    self: *Self,
    rect: Rect,
    options: Cell.Options,
) void {
    var frame = self.getForeFrame();

    for (1..rect.size.x - 1) |x| {
        frame.set(
            rect.position.add(.{
                .x = x,
            }),
            (Cell.Options{ .char = self.getEdge(.top) }).join(options),
        );
        frame.set(
            rect.position.add(.{
                .y = rect.size.y - 1,
                .x = x,
            }),
            (Cell.Options{ .char = self.getEdge(.bottom) }).join(options),
        );
    }

    for (1..rect.size.y - 1) |y| {
        frame.set(
            rect.position.add(.{
                .y = y,
            }),
            (Cell.Options{ .char = self.getEdge(.left) }).join(options),
        );
        frame.set(
            rect.position.add(.{
                .y = y,
                .x = rect.size.x - 1,
            }),
            (Cell.Options{ .char = self.getEdge(.right) }).join(options),
        );
    }

    const corners = [_]struct { usize, usize, Edge }{
        .{ 0, 0, .top_left },
        .{ 0, 1, .top_right },
        .{ 1, 0, .bottom_left },
        .{ 1, 1, .bottom_right },
    };

    inline for (corners) |corner| {
        const y = corner[0];
        const x = corner[1];
        const edge = corner[2];
        frame.set(
            rect.position.add(.{
                .y = y * (rect.size.y - 1),
                .x = x * (rect.size.x - 1),
            }),
            (Cell.Options{ .char = self.getEdge(edge) }).join(options),
        );
    }
}

pub fn draw(self: *Self) void {
    const Updates = struct {
        cursor: usize = 0,
        attr: usize = 0,
        print: usize = 0,
    };
    var updates = Updates{};

    for (0..Frame.HEIGHT) |y| {
        for (0..Frame.WIDTH) |x| {
            const cell_fore = self.getForeFrame().get(.{ .y = y, .x = x });
            const cell_back = self.getBackFrame().get(.{ .y = y, .x = x });

            if (cell_back.eql(cell_fore.*)) {
                continue;
            }

            if (self.terminal.updateCursor(.{ .row = y + 1, .col = x + 1 })) {
                updates.cursor += 1;
            }
            if (self.terminal.updateAttributes(cell_fore.attributes)) {
                updates.attr += 1;
            }

            self.terminal.print("{u}", .{cell_fore.char});
            self.terminal.cursor.col += 1;
            updates.print += 1;

            cell_back.* = cell_fore.*;
        }
    }

    inline for (@typeInfo(Updates).@"struct".fields, 0..) |field, i| {
        _ = self.terminal.updateCursor(.{ .row = Frame.HEIGHT + i + 1, .col = 1 });
        _ = self.terminal.updateAttributes(.{});

        self.terminal.print("\r\x1b[K", .{});

        if (self.debug_render_info) {
            self.terminal.print("{s}\t{}", .{
                field.name,
                @field(updates, field.name),
            });
        }
    }

    self.terminal.flush();
    self.swapFrames();
}

fn getForeFrame(self: *Self) *Frame {
    return &self.frames[self.current_frame];
}
fn getBackFrame(self: *Self) *Frame {
    assert(@TypeOf(self.current_frame) == u1);
    return &self.frames[self.current_frame +% 1];
}
fn swapFrames(self: *Self) void {
    assert(@TypeOf(self.current_frame) == u1);
    self.current_frame +%= 1;
}

fn getEdge(self: *const Self, edge: Edge) u21 {
    return if (self.ascii) switch (edge) {
        .left, .right => '|',
        .top, .bottom => '-',
        else => '+',
    } else switch (edge) {
        .left => '▌',
        .right => '▐',
        .top => '🬂',
        .bottom => '🬭',
        .top_left => '🬕',
        .top_right => '🬨',
        .bottom_left => '🬲',
        .bottom_right => '🬷',
    };
}
