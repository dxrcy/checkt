const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;

const State = @import("State.zig");
const Player = State.Player;
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
show_debug: bool,

pub const tile_size = struct {
    pub const WIDTH: usize = Piece.WIDTH + PADDING_LEFT + PADDING_RIGHT;
    pub const HEIGHT: usize = Piece.HEIGHT + PADDING_TOP + PADDING_BOTTOM;

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

pub fn new(ascii: bool) Self {
    return Self{
        .terminal = Terminal.new(),
        .frames = [1]Frame{Frame.new()} ** 2,
        .current_frame = 0,
        .ascii = ascii,
        .show_debug = false,
    };
}

pub fn enter(self: *Self) !void {
    self.terminal.setAlternativeScreen(.enter);
    self.terminal.setCursorVisibility(.hidden);
    self.terminal.clearEntireScreen();
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

pub fn render(self: *Self, state: *const State) void {
    self.getForeFrame().clear();

    // Board tile
    for (0..Board.SIZE) |rank| {
        for (0..Board.SIZE) |file| {
            const tile = Tile{ .rank = rank, .file = file };
            self.renderRectSolid(getTileRect(tile), .{
                .char = ' ',
                .bg = if (tile.isEven()) .bright_black else .black,
            });
        }
    }

    // Board piece icons
    for (0..Board.SIZE) |rank| {
        for (0..Board.SIZE) |file| {
            const tile = Tile{ .rank = rank, .file = file };
            if (state.board.get(tile)) |piece| {
                self.renderPiece(piece, tile, .{});
            }
        }
    }

    // Taken piece icons
    for (std.meta.tags(Player), 0..) |player, y| {
        var x: usize = 0;

        for (std.meta.tags(Piece.Kind)) |kind| {
            const piece = Piece{ .kind = kind, .player = player };

            const count = state.board.getTaken(piece);
            if (count == 0) {
                continue;
            }

            const tile = Tile{
                .rank = Board.SIZE + y,
                .file = x % Board.SIZE,
            };

            self.renderPiece(piece, tile, .{});

            if (count > 1) {
                self.renderDecimalInt(
                    count,
                    tile.rank * tile_size.HEIGHT + 1,
                    tile.file * tile_size.WIDTH + tile_size.PADDING_LEFT + Piece.WIDTH + 1,
                    .{
                        .fg = .yellow,
                        .bold = true,
                    },
                );
            }

            x += 1;
        }

        // Placeholder
        if (x == 0) {
            const piece = Piece{ .kind = .pawn, .player = player };
            const tile = Tile{
                .rank = Board.SIZE + y,
                .file = x % Board.SIZE,
            };

            self.renderPiece(piece, tile, .{
                .fg = .bright_black,
                .bold = false,
            });
        }
    }

    switch (state.status) {
        .win => |player| {
            self.renderTextLarge(&[_][]const u8{
                "game",
                "over",
            }, 14, 20);

            const string = if (player == .white)
                "Blue wins"
            else
                "Red wins";
            const origin_x = (Board.SIZE * tile_size.WIDTH - string.len) / 2;
            self.renderTextLineNormal(string, 26, origin_x, .{
                .bold = true,
            });
        },

        .play => |player| {
            if (state.board.isPlayerInCheck(player)) {
                const king = state.board.getKing(player);
                self.renderRectSolid(getTileRect(king), .{
                    .bg = .white,
                });
                self.renderPiece(.{
                    .kind = .king,
                    .player = player,
                }, king, .{
                    .fg = if (player == .white) .cyan else .red,
                });
            }

            // Selected, available moves
            if (state.selected) |selected| {
                var available_moves = state.board.getAvailableMoves(selected);
                var has_available = false;
                while (available_moves.next()) |available| {
                    has_available = true;

                    if (state.board.get(available.destination)) |piece| {
                        // Take direct
                        self.renderPiece(piece, available.destination, .{
                            .fg = .bright_white,
                        });
                    } else {
                        // No take or take indirect
                        const piece = state.board.get(selected) orelse
                            continue;

                        self.renderPiece(piece, available.destination, .{
                            .fg = if (available.destination.isEven()) .black else .bright_black,
                        });

                        // Take indirect
                        if (available.take) |take| {
                            self.renderPiece(piece, take, .{
                                .fg = .white,
                            });
                        }
                    }

                    if (available.move_alt) |move_alt| {
                        const piece = state.board.get(move_alt.origin) orelse unreachable;
                        self.renderPiece(piece, move_alt.origin, .{
                            .fg = .white,
                        });
                    }
                }

                self.renderRectSolid(getTileRect(selected), .{
                    // TODO: Extract this ternary as a function
                    .bg = if (player == .white) .cyan else .red,
                });

                if (state.board.get(selected)) |piece| {
                    self.renderPiece(piece, selected, .{
                        .fg = if (has_available) .black else .white,
                    });
                }
            }

            // Focus
            self.renderRectHighlight(getTileRect(state.focus), .{
                .fg = if (player == .white) .cyan else .red,
                .bold = true,
            });
        },
    }
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

    const string = piece.string();

    for (0..Piece.HEIGHT) |y| {
        for (0..Piece.WIDTH) |x| {
            frame.set(
                tile.rank * tile_size.HEIGHT + y + tile_size.PADDING_TOP,
                tile.file * tile_size.WIDTH + x + tile_size.PADDING_LEFT,
                (Cell.Options{
                    .char = string[y * Piece.WIDTH + x],
                    .fg = if (piece.player == .white) .cyan else .red,
                    .bold = true,
                }).join(options),
            );
        }
    }
}

fn getTileRect(tile: Tile) Rect {
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
