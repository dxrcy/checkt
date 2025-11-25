const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;

pub fn Output(buffer_size: usize) type {
    return struct {
        const Self = @This();

        inner: ?struct {
            file: fs.File,
            writer: fs.File.Writer,
            buffer: [buffer_size]u8,
        },

        pub const uninit = Self{ .inner = null };

        pub fn init(self: *Self, file: fs.File) void {
            assert(self.inner == null);
            self.inner = .{
                .file = file,
                .writer = undefined,
                .buffer = undefined,
            };
            const inner = &self.inner.?;
            inner.writer = inner.file.writer(&inner.buffer);
        }

        pub fn writer(self: *Self) *fs.File.Writer {
            return self.tryWriter() orelse unreachable;
        }

        pub fn tryWriter(self: *Self) ?*fs.File.Writer {
            return if (self.inner) |*inner|
                &inner.writer
            else
                null;
        }
    };
}
