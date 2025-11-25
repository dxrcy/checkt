const Self = @This();

const std = @import("std");
const assert = std.debug.assert;

const State = @import("../game/State.zig");
const Board = State.Board;
const Piece = State.Piece;
const Tile = State.Tile;

const Terminal = @import("Terminal.zig");
const Attributes = Terminal.Attributes;
const Ui = @import("Ui.zig");

pub const HEIGHT = (Board.SIZE + 2) * Ui.tile_size.HEIGHT;
pub const WIDTH = Board.SIZE * Ui.tile_size.WIDTH;

cells: [HEIGHT * WIDTH]Cell,

const Char = u21;

pub const Position = struct {
    y: usize,
    x: usize,

    pub fn isInBounds(self: Position) bool {
        return self.y < HEIGHT and self.x < WIDTH;
    }

    pub fn add(lhs: Position, rhs: Position) Position {
        return Position{
            .y = lhs.y + rhs.y,
            .x = lhs.x + rhs.x,
        };
    }
};

pub fn new() Self {
    return Self{
        .cells = [1]Cell{.{}} ** (HEIGHT * WIDTH),
    };
}

pub fn clear(self: *Self) void {
    for (&self.cells) |*cell| {
        cell.* = .{};
    }
}

pub fn set(self: *Self, position: Position, options: Cell.Options) void {
    assert(position.isInBounds());
    self.cells[position.y * WIDTH + position.x].apply(options);
}

pub fn get(self: *Self, position: Position) *Cell {
    assert(position.isInBounds());
    return &self.cells[position.y * WIDTH + position.x];
}

pub const Cell = struct {
    char: Char = ' ',
    attributes: Attributes = .{},

    pub fn eql(lhs: Cell, rhs: Cell) bool {
        return lhs.char == rhs.char and lhs.attributes.eql(rhs.attributes);
    }

    pub fn apply(self: *Cell, options: Options) void {
        if (options.char) |char| {
            self.char = char;
        }
        if (options.fg) |fg| {
            self.attributes.fg = fg;
        }
        if (options.bg) |bg| {
            self.attributes.bg = bg;
        }
        if (options.bold) |bold| {
            self.attributes.style.bold = bold;
        }
    }

    // TODO: Add more style attributes
    pub const Options = struct {
        char: ?Char = null,
        fg: ?Attributes.Color = null,
        bg: ?Attributes.Color = null,
        bold: ?bool = null,

        /// Merge two [`CellOptions`], preferring values of `rhs`.
        pub fn join(lhs: Options, rhs: Options) Options {
            return Options{
                .char = rhs.char orelse lhs.char orelse null,
                .fg = rhs.fg orelse lhs.fg orelse null,
                .bg = rhs.bg orelse lhs.bg orelse null,
                .bold = rhs.bold orelse lhs.bold orelse null,
            };
        }
    };
};
