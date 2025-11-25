const std = @import("std");
const assert = std.debug.assert;
const Thread = std.Thread;

const handlers = @import("env/handlers.zig");

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
    completion: Completion,

    /// How to 'use' a thread.
    const Completion = enum {
        /// Wait for completion.
        join,
        /// Ignore and forget.
        detach,
    };

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
        comptime lifetime: Completion,
        comptime function: anytype,
        args: @typeInfo(@TypeOf(function)).@"fn".params[0].type.?,
    ) !Self {
        const thread = try Thread.spawn(.{}, functionWrapper, .{ name, function, args });
        return Self{
            .thread = thread,
            .completion = lifetime,
        };
    }

    pub fn complete(self: Self) void {
        switch (self.completion) {
            .join => self.thread.join(),
            .detach => self.thread.detach(),
        }
    }
};

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        queue: Queue(T),
        discard: bool,

        mutex: Thread.Mutex,
        can_send: Thread.Condition,
        can_recv: Thread.Condition,

        pub const empty = Self{
            .queue = .empty,
            .discard = false,
            .mutex = .{},
            .can_send = .{},
            .can_recv = .{},
        };

        pub fn send(self: *Self, item: T) void {
            if (self.discard) {
                return;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.queue.length >= Queue(T).BUFFER_SIZE) {
                self.can_send.wait(&self.mutex);
            }

            self.queue.push(item);
            self.can_recv.signal();
        }

        pub fn recv(self: *Self) T {
            assert(!self.discard);

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.queue.length == 0) {
                self.can_recv.wait(&self.mutex);
            }

            const item = self.queue.pop();
            self.can_send.signal();
            return item;
        }
    };
}

// PERF: Convert to ring buffer
fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        const BUFFER_SIZE = 32;

        buffer: [BUFFER_SIZE]T,
        length: usize,

        pub const empty = Self{
            .buffer = undefined,
            .length = 0,
        };

        pub fn push(self: *Self, item: T) void {
            self.buffer[self.length] = item;
            self.length += 1;
        }

        pub fn pop(self: *Self) T {
            assert(self.length > 0);

            const item = self.buffer[0];
            self.length -= 1;
            for (0..self.length) |i| {
                self.buffer[i] = self.buffer[i + 1];
            }
            return item;
        }
    };
}
