const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const posix = std.posix;

const output = @import("../env/output.zig");

original_termios: ?posix.termios,
/// Most methods do **not** modify this field. Eg. [`print`].
cursor: Cursor,
/// Most methods do **not** modify this field. Eg. [`print`].
attributes: Attributes,

pub const Cursor = struct {
    row: usize,
    col: usize,

    pub fn eql(lhs: Cursor, rhs: Cursor) bool {
        return lhs.row == rhs.row and lhs.col == rhs.col;
    }
};

pub const Attributes = struct {
    fg: Color = .unset,
    bg: Color = .unset,
    style: Style = .{},

    pub fn eql(lhs: Attributes, rhs: Attributes) bool {
        return lhs.fg == rhs.fg and
            lhs.bg == rhs.bg and
            lhs.style.eql(rhs.style);
    }

    /// Use [`Color.unset`] for default color.
    pub const Color = enum(u8) {
        black = 30,
        red = 31,
        green = 32,
        yellow = 33,
        blue = 34,
        magenta = 35,
        cyan = 36,
        white = 37,
        unset = 39,
        bright_black = 90,
        bright_red = 91,
        bright_green = 92,
        bright_yellow = 93,
        bright_blue = 94,
        bright_magenta = 95,
        bright_cyan = 96,
        bright_white = 97,
    };

    pub const Style = packed struct {
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,

        pub fn eql(lhs: Style, rhs: Style) bool {
            return lhs.bold == rhs.bold and
                lhs.dim == rhs.dim and
                lhs.italic == rhs.italic;
        }
    };
};

pub fn new() Self {
    return Self{
        .original_termios = null,
        .cursor = .{ .row = 0, .col = 0 },
        .attributes = Attributes{},
    };
}

pub fn saveTermios(self: *Self) !void {
    if (self.original_termios != null) {
        panic("tried to save termios twice", .{});
    }
    self.original_termios = try posix.tcgetattr(posix.STDIN_FILENO);
}

pub fn restoreTermios(self: *Self) !void {
    const termios = self.original_termios orelse {
        panic("tried to restore termios before saving", .{});
    };
    try self.setTermios(termios);
    self.original_termios = null;
}

pub fn setTermios(self: *Self, termios: posix.termios) !void {
    _ = self;
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, termios);
}

pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    output.stdout.print(fmt, args);
}

pub fn flush(self: *Self) void {
    _ = self;
    output.stdout.flush();
}

pub fn setAlternativeScreen(self: *Self, state: enum { enter, exit }) void {
    self.print("\x1b[?1049{c}", .{
        @as(u8, if (state == .enter) 'h' else 'l'),
    });
}

pub fn setCursorVisibility(self: *Self, state: enum { visible, hidden }) void {
    self.print("\x1b[?25{c}", .{
        @as(u8, if (state == .visible) 'h' else 'l'),
    });
}

pub fn clearEntireScreen(self: *Self) void {
    self.print("\x1b[2J", .{});
}

/// Returns `true` if cursor changed.
pub fn updateCursor(self: *Self, cursor: Cursor) bool {
    if (cursor.eql(self.cursor)) {
        return false;
    }
    self.print("\x1b[{};{}H", .{ cursor.row, cursor.col });
    self.cursor = cursor;
    return true;
}

/// Returns `true` if any attributes changed.
pub fn updateAttributes(self: *Self, attributes: Attributes) bool {
    var any_changed = false;

    if (attributes.fg != self.attributes.fg) {
        self.print("\x1b[{d}m", .{@intFromEnum(attributes.fg) + 0});
        any_changed = true;
    }

    if (attributes.bg != self.attributes.bg) {
        self.print("\x1b[{d}m", .{@intFromEnum(attributes.bg) + 10});
        any_changed = true;
    }

    // TODO: Support all style attributes
    if (attributes.style.bold != self.attributes.style.bold) {
        self.print("\x1b[{d}m", .{@as(u8, if (attributes.style.bold) 1 else 22)});
        any_changed = true;
    }

    self.attributes = attributes;
    return any_changed;
}
