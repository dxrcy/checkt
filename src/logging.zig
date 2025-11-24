const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const log = std.log;

pub fn logFn(
    comptime message_level: log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    logToFile(message_level, scope, fmt, args) catch |err| {
        log.defaultLog(.warn, .default, "failed to write to log file: {}", .{err});
        log.defaultLog(message_level, scope, fmt, args);
    };
}

const BUFFER_SIZE = 64;
const FILENAME = "log";

var LOG_FILE: ?struct {
    file: fs.File,
    writer: fs.File.Writer,
    buffer: [BUFFER_SIZE]u8,
} = null;

pub fn init() !void {
    assert(LOG_FILE == null);

    const flags: fs.File.CreateFlags = .{
        .read = false,
        .truncate = true,
        .exclusive = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    };

    const file = try fs.cwd().createFile(FILENAME, flags);

    LOG_FILE = .{
        .file = file,
        .writer = undefined,
        .buffer = undefined,
    };

    LOG_FILE.?.writer = LOG_FILE.?.file.writer(&LOG_FILE.?.buffer);
}

fn getWriter() ?*fs.File.Writer {
    if (LOG_FILE) |*file| {
        return &file.writer;
    }
    return null;
}

fn logToFile(
    comptime message_level: log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const writer = getWriter() orelse {
        return error.NotInitialized;
    };

    const level_txt = comptime message_level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    nosuspend {
        try writer.interface.print(
            level_txt ++ prefix ++ fmt ++ "\n",
            args,
        );
        try writer.interface.flush();
    }
}
