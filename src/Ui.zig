const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;

const State = @import("State.zig");
const Side = State.Side;
const Board = State.Board;
const Piece = State.Board.Piece;
const Tile = State.Tile;

const Terminal = @import("Terminal.zig");
const Color = Terminal.Attributes.Color;

const Frame = @import("Frame.zig");
const Cell = Frame.Cell;

const text = @import("text.zig");

terminal: Terminal,
frames: [2]Frame,
current_frame: u1,

ascii: bool,
small: bool,

show_debug: bool,

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

const Rect = struct { y: usize, x: usize, h: usize, w: usize };

pub fn new(ascii: bool, small: bool) Self {
    return Self{
        .terminal = Terminal.new(),
        .frames = [1]Frame{Frame.new()} ** 2,
        .current_frame = 0,
        .ascii = ascii,
        .small = small,
        .show_debug = false,
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

pub fn render(self: *Self, state: *const State) void {
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

    // Board piece icons
    for (0..Board.SIZE) |rank| {
        for (0..Board.SIZE) |file| {
            const tile = Tile{ .rank = @intCast(rank), .file = @intCast(file) };
            if (state.board.get(tile)) |piece| {
                self.renderPiece(piece, tile, .{});
            }
        }
    }

    // Taken piece icons
    for (std.meta.tags(Side), 0..) |side, y| {
        var x: usize = 0;

        for (std.meta.tags(Piece.Kind)) |kind| {
            const piece = Piece{ .kind = kind, .side = side };

            const count = state.board.getTaken(piece);
            if (count == 0) {
                continue;
            }

            const tile = Tile{
                .rank = @intCast(Board.SIZE + y),
                .file = @intCast(x % Board.SIZE),
            };

            self.renderPiece(piece, tile, .{});

            if (count > 1) {
                const position: struct { x: usize, y: usize } = if (self.small)
                    .{
                        .x = tile.file * tile_size.WIDTH_SMALL + tile_size.PADDING_LEFT_SMALL + 2,
                        .y = tile.rank * tile_size.HEIGHT_SMALL + 1,
                    }
                else
                    .{
                        .x = tile.file * tile_size.WIDTH + tile_size.PADDING_LEFT + Piece.WIDTH + 1,
                        .y = tile.rank * tile_size.HEIGHT + 1,
                    };

                self.renderDecimalInt(
                    count,
                    position.y,
                    position.x,
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

    switch (state.status) {
        .win => |side| {
            self.renderTextLarge(
                &[_][]const u8{
                    "game",
                    "over",
                },
                if (self.small) 6 else 14,
                if (self.small) 8 else 20,
            );

            const string = if (side == .white)
                "Blue wins"
            else
                "Red wins";

            const tile_width = if (self.small)
                tile_size.WIDTH_SMALL
            else
                tile_size.WIDTH;

            self.renderTextLineNormal(
                string,
                if (self.small) 18 else 26,
                (Board.SIZE * (tile_width) - string.len) / 2,
                .{
                    .bold = true,
                },
            );
        },

        .play => |active_side| {
            const player = state.player_local;
            const side: Side = if (state.role == null)
                active_side
            else if (state.role == .host) .white else .black;

            if (state.board.isSideInCheck(side)) {
                const king = state.board.getKing(side);
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
                var available_moves = state.board.getAvailableMoves(selected);
                var has_available = false;
                while (available_moves.next()) |available| {
                    has_available = true;

                    if (state.board.get(available.destination)) |piece| {
                        // Take direct
                        self.renderPiece(piece, available.destination, .{
                            .fg = colors.AVAILABLE,
                        });
                    } else {
                        // No take or take indirect
                        const piece = state.board.get(selected) orelse
                            continue;

                        self.renderPiece(piece, available.destination, .{
                            .fg = getTileColor(available.destination, true),
                        });

                        // Take indirect
                        if (available.take) |take| {
                            self.renderPiece(piece, take, .{
                                .fg = colors.ALTERNATIVE,
                            });
                        }
                    }

                    if (available.move_alt) |move_alt| {
                        const piece = state.board.get(move_alt.origin) orelse unreachable;
                        self.renderPiece(piece, move_alt.origin, .{
                            .fg = colors.ALTERNATIVE,
                        });
                    }
                }

                self.renderRectSolid(self.getTileRect(selected), .{
                    .bg = getPieceColor(side),
                });

                if (state.board.get(selected)) |piece| {
                    self.renderPiece(piece, selected, .{
                        .fg = if (has_available) colors.TILE_BLACK else colors.UNAVAILABLE,
                    });
                }
            }

            // Focus, remote
            if (state.player_remote) |player_remote| {
                if (player_remote.selected) |selected| {
                    self.renderRectSolid(self.getTileRect(selected), .{
                        .bg = colors.REMOTE,
                    });

                    if (state.board.get(selected)) |piece| {
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

            // Focus, local
            self.renderRectHighlight(self.getTileRect(state.player_local.focus), .{
                .fg = if (state.isLocalSideActive())
                    getPieceColor(side)
                else
                    colors.UNAVAILABLE,
                .bold = true,
            });
        },
    }

    // var buffer: [10]u8 = undefined;
    // const string = std.fmt.bufPrint(&buffer, "{}", .{state.count}) catch unreachable;
    // self.renderTextLineNormal(string, 0, 0, .{});

    // self.renderTextLineNormal(
    //     if (state.role == .host) "host" else "join",
    //     0,
    //     0,
    //     .{},
    // );
    // self.renderTextLineNormal(
    //     if (state.status.play == .white) "white" else "black",
    //     1,
    //     0,
    //     .{},
    // );
    // self.renderTextLineNormal(
    //     if (state.simulating_remote) "other" else "self",
    //     2,
    //     0,
    //     .{},
    // );
}

fn renderTextLineNormal(
    self: *Self,
    string: []const u8,
    origin_y: usize,
    origin_x: usize,
    options: Cell.Options,
) void {
    var frame = self.getForeFrame();

    for (string, 0..) |char, x| {
        frame.set(
            origin_y,
            origin_x + x,
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
    origin_y: usize,
    origin_x: usize,
) void {
    for (lines, 0..) |string, row| {
        self.renderTextLineLine(
            string,
            origin_y + row * (text.HEIGHT + text.GAP_Y),
            origin_x,
        );
    }
}

fn renderTextLineLine(
    self: *Self,
    string: []const u8,
    origin_y: usize,
    origin_x: usize,
) void {
    var frame = self.getForeFrame();

    for (string, 0..) |letter, i| {
        const template = text.largeLetter(letter);

        for (0..text.HEIGHT) |y| {
            for (0..text.WIDTH) |x| {
                const symbol = template[y * (text.WIDTH + 1) + x];
                const char = text.translateSymbol(symbol, self.ascii);

                frame.set(
                    origin_y + y,
                    origin_x + i * (text.WIDTH + text.GAP_X) + x,
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
    y: usize,
    x: usize,
    options: Cell.Options,
) void {
    var frame = self.getForeFrame();

    const char = if (value < 10)
        @as(u8, @intCast(value)) + '0'
    else
        '*';

    frame.set(y, x, options.join(.{
        .char = char,
    }));
}

fn renderPiece(self: *Self, piece: Piece, tile: Tile, options: Cell.Options) void {
    var frame = self.getForeFrame();

    if (self.small) {
        frame.set(
            tile.rank * tile_size.HEIGHT_SMALL + tile_size.PADDING_TOP_SMALL,
            tile.file * tile_size.WIDTH_SMALL + tile_size.PADDING_LEFT_SMALL,
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
                tile.rank * tile_size.HEIGHT + y + tile_size.PADDING_TOP,
                tile.file * tile_size.WIDTH + x + tile_size.PADDING_LEFT,
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
fn getPieceColor(side: State.Side) Color {
    return if (side == .white) colors.PIECE_WHITE else colors.PIECE_BLACK;
}

fn getTileRect(self: *const Self, tile: Tile) Rect {
    if (self.small) {
        return Rect{
            .y = tile.rank * tile_size.HEIGHT_SMALL,
            .x = tile.file * tile_size.WIDTH_SMALL,
            .h = tile_size.HEIGHT_SMALL,
            .w = tile_size.WIDTH_SMALL,
        };
    }

    return Rect{
        .y = tile.rank * tile_size.HEIGHT,
        .x = tile.file * tile_size.WIDTH,
        .h = tile_size.HEIGHT,
        .w = tile_size.WIDTH,
    };
}

fn renderRectSolid(
    self: *Self,
    rect: Rect,
    options: Cell.Options,
) void {
    var frame = self.getForeFrame();

    for (0..rect.h) |y| {
        for (0..rect.w) |x| {
            frame.set(rect.y + y, rect.x + x, options);
        }
    }
}

fn renderRectHighlight(
    self: *Self,
    rect: Rect,
    options: Cell.Options,
) void {
    var frame = self.getForeFrame();

    for (1..rect.w - 1) |x| {
        frame.set(
            rect.y,
            rect.x + x,
            (Cell.Options{ .char = self.getEdge(.top) }).join(options),
        );
        frame.set(
            rect.y + rect.h - 1,
            rect.x + x,
            (Cell.Options{ .char = self.getEdge(.bottom) }).join(options),
        );
    }

    for (1..rect.h - 1) |y| {
        frame.set(
            rect.y + y,
            rect.x,
            (Cell.Options{ .char = self.getEdge(.left) }).join(options),
        );
        frame.set(
            rect.y + y,
            rect.x + rect.w - 1,
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
            rect.y + y * (rect.h - 1),
            rect.x + x * (rect.w - 1),
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
            const cell_fore = self.getForeFrame().get(y, x);
            const cell_back = self.getBackFrame().get(y, x);

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

        if (self.show_debug) {
            self.terminal.print("{s}\t{}", .{
                field.name,
                @field(updates, field.name),
            });
        }
    }

    self.terminal.flush();
    self.swapFrames();
}

pub fn getForeFrame(self: *Self) *Frame {
    return &self.frames[self.current_frame];
}
pub fn getBackFrame(self: *Self) *Frame {
    assert(@TypeOf(self.current_frame) == u1);
    return &self.frames[self.current_frame +% 1];
}
pub fn swapFrames(self: *Self) void {
    assert(@TypeOf(self.current_frame) == u1);
    self.current_frame +%= 1;
}

pub fn getEdge(self: *const Self, edge: Edge) u21 {
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
