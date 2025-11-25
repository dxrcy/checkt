const std = @import("std");
const posix = std.posix;

const RenderEvent = @import("root").RenderEvent;

const Channel = @import("../concurrent.zig").Channel;
const Ui = @import("../ui/Ui.zig");

const handlers = @import("handlers.zig");

pub const globals = struct {
    pub var UI: ?*Ui = null;
    pub var RENDER_CHANNEL: ?*Channel(RenderEvent) = null;
};

pub threadlocal var THREAD_NAME: ?[]const u8 = null;

pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (globals.UI) |ui| {
        ui.exit() catch {};
    }

    std.debug.print("thread '{s}' panic: {s}\n", .{
        THREAD_NAME orelse "??",
        msg,
    });
    std.debug.dumpCurrentStackTrace(first_trace_addr orelse @returnAddress());

    std.process.abort();
}

pub fn registerSignalHandlers() void {
    const action = posix.Sigaction{
        .handler = .{ .handler = handlers.signal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.WINCH, &action, null);
}

fn signal(sig_num: c_int) callconv(.c) void {
    _ = sig_num;

    if (globals.RENDER_CHANNEL) |render_channel| {
        render_channel.send(.redraw);
    }
}
