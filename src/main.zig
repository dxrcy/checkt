const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const posix = std.posix;
const Thread = std.Thread;

const Board = @import("Board.zig");
const State = @import("State.zig");
const Ui = @import("Ui.zig");
const Connection = @import("Connection.zig");

pub fn main() !u8 {
    var args = std.process.args();
    _ = args.next();

    var ascii = false;
    var role_opt: ?State.Role = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
        }
        if (std.mem.eql(u8, arg, "host")) {
            if (role_opt != null) {
                std.log.err("invalid argument\n", .{});
                return 1;
            }
            role_opt = .host;
        }
        if (std.mem.eql(u8, arg, "join")) {
            if (role_opt != null) {
                std.log.err("invalid argument\n", .{});
                return 1;
            }
            role_opt = .join;
        }
    }

    const role = role_opt orelse {
        std.log.err("missing argument\n", .{});
        return 1;
    };

    var conn = switch (role) {
        .host => try Connection.connectServer(),
        .join => try Connection.connectClient(),
    };
    defer conn.deinit();

    const state = State.new(role);

    var ui = Ui.new(ascii);
    try ui.enter();
    // Restore terminal, if anything goes wrong
    errdefer ui.exit() catch unreachable;

    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &action, null);

    {
        var shared = Shared{
            .state = state,
            .ui = ui,
        };

        const render_thread = try Thread.spawn(.{}, render_worker, .{&shared});
        const input_thread = try Thread.spawn(.{}, input_worker, .{&shared});

        // Wait
        input_thread.join();
        // Cancel
        _ = render_thread;
    }

    // Don't `defer`, so that error can be returned if possible
    try ui.exit();

    return 0;
}

fn handleSignal(sig_num: c_int) callconv(.c) void {
    _ = sig_num;
    EVENTS.push(.redraw);
}

var EVENTS = Queue.init();

// FIXME: Make thread-safe
const Queue = struct {
    const Self = @This();

    buffer: [BUFFER_SIZE]Item,
    length: usize,

    const BUFFER_SIZE = 4;

    const Item = enum {
        redraw,
        update,
    };

    pub fn init() Self {
        return Self{
            .buffer = undefined,
            .length = 0,
        };
    }

    pub fn push(self: *Self, item: Item) void {
        while (self.length >= BUFFER_SIZE) {}
        self.buffer[self.length] = item;
        self.length += 1;
    }

    pub fn pop(self: *Self) Item {
        while (self.length == 0) {}
        self.length -= 1;
        return self.buffer[self.length];
    }
};

const Shared = struct {
    state: State,
    ui: Ui,
};

fn render_worker(shared: *Shared) void {
    EVENTS.push(.update);

    while (true) {
        const event = EVENTS.pop();
        switch (event) {
            .redraw => shared.ui.clear(),
            .update => {},
        }

        shared.ui.render(&shared.state);
        shared.ui.draw();
    }
}

fn input_worker(shared: *Shared) !void {
    const state = &shared.state;
    var stdin = fs.File.stdin();

    while (true) {
        var buffer: [1]u8 = undefined;
        const bytes_read = try stdin.read(&buffer);
        if (bytes_read < 1) {
            break;
        }

        switch (buffer[0]) {
            0x03 => break,

            'h' => if (state.status == .play) state.moveFocus(.left),
            'l' => if (state.status == .play) state.moveFocus(.right),
            'k' => if (state.status == .play) state.moveFocus(.up),
            'j' => if (state.status == .play) state.moveFocus(.down),

            0x20 => if (state.status == .play) {
                state.toggleSelection(false);
            },
            0x1b => if (state.status == .play) {
                state.player_local.selected = null;
            },

            'r' => if (state.status == .win) {
                state.resetGame();
            },

            't' => switch (state.status) {
                .play => |*side| {
                    side.* = side.flip();
                    state.player_local.selected = null;
                    if (state.player_remote) |*player_other| {
                        player_other.selected = null;
                    }
                },
                else => {},
            },
            'y' => if (state.status == .play) {
                state.toggleSelection(true);
            },

            'o' => {
                state.player_local.selected = null;
                if (state.player_remote) |*player_other| {
                    player_other.selected = null;
                }
                state.simulating_other ^= true;
            },
            'p' => {
                shared.ui.show_debug ^= true;
            },

            else => {},
        }

        EVENTS.push(.update);
    }
}
