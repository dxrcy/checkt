const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const log = std.log;

const Output = @import("output.zig").Output;

pub fn logFn(
    comptime message_level: log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    logToFile(message_level, scope, fmt, args) catch {};
}

const LOG_DIR = switch (@import("builtin").os.tag) {
    // TODO: Support more systems obviously
    .linux => "/tmp/checkt",
    else => @compileError("unsupported system"),
};

var LOG_FILE = Output(64).uninit;
/// `true` if already tried `init` log file, but failed.
var INIT_FAILED = false;

/// Idempotent.
pub fn init() void {
    tryInit() catch {
        INIT_FAILED = true;
    };
}

/// Idempotent.
fn tryInit() !void {
    if (LOG_FILE.inner != null or INIT_FAILED) {
        return;
    }

    // TODO: Make portable (at least for posix)
    const pid = std.os.linux.getpid();
    const timestamp = std.time.microTimestamp();

    var filename_buffer: [32]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buffer, "{}-{}.log", .{ timestamp, pid });

    const dir_options: fs.Dir.OpenOptions = .{};
    const dir = fs.cwd().openDir(LOG_DIR, dir_options) catch |err| switch (err) {
        error.FileNotFound => try fs.cwd().makeOpenPath(LOG_DIR, dir_options),
        else => |err2| return err2,
    };

    const file_flags: fs.File.CreateFlags = .{
        .read = false,
        .truncate = true,
        .exclusive = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    };
    const file = try dir.createFile(filename, file_flags);

    LOG_FILE.init(file);
}

fn logToFile(
    comptime message_level: log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    if (INIT_FAILED) {
        return;
    }

    const writer = LOG_FILE.tryWriter() orelse {
        return error.NotInitialized;
    };

    const timestamp = std.time.timestamp();
    const level_txt = comptime message_level.asText();
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

    nosuspend {
        try writer.interface.print("[{}] ", .{timestamp});
        try writer.interface.print(
            level_txt ++ prefix ++ ": " ++ fmt ++ "\n",
            args,
        );
        try writer.interface.flush();
    }
}
