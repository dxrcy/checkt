const std = @import("std");
const assert = std.debug.assert;
const Thread = std.Thread;

const handlers = @import("handlers.zig");

pub fn MutexPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: Thread.Mutex,
        object: *T,

        pub fn new(object: *T) Self {
            return Self{
                .mutex = .{},
                .object = object,
            };
        }

        pub fn lock(self: *Self) *T {
            self.mutex.lock();
            return self.object;
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock();
        }
    };
}

pub const Worker = struct {
    const Self = @This();

    thread: Thread,
    // TODO: Rename
    lifetime: Lifetime,

    // TODO: Rename
    // TODO: Rename variants
    const Lifetime = enum { join, detach };

    fn functionWrapper(
        comptime name: []const u8,
        comptime function: anytype,
        args: @typeInfo(@TypeOf(function)).@"fn".params[0].type.?,
    ) void {
        handlers.THREAD_NAME = name;

        switch (@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?)) {
            .void => {
                function(args);
            },
            .error_union => |error_union| {
                comptime assert(error_union.payload == void);
                function(args) catch |err| {
                    std.debug.panic("returned {}", .{err});
                };
            },
            else => comptime unreachable,
        }
    }

    pub fn spawn(
        comptime name: []const u8,
        comptime lifetime: Lifetime,
        comptime function: anytype,
        args: @typeInfo(@TypeOf(function)).@"fn".params[0].type.?,
    ) !Self {
        const thread = try Thread.spawn(.{}, functionWrapper, .{ name, function, args });
        return Self{
            .thread = thread,
            .lifetime = lifetime,
        };
    }

    // TODO: Rename
    pub fn consume(self: Self) void {
        switch (self.lifetime) {
            .join => self.thread.join(),
            .detach => self.thread.detach(),
        }
    }
};
