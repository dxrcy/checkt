const std = @import("std");
const assert = std.debug.assert;
const Thread = std.Thread;

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        queue: Queue(T),

        mutex: Thread.Mutex,
        can_send: Thread.Condition,
        can_recv: Thread.Condition,

        pub fn init() Self {
            return Self{
                .queue = Queue(T).init(),
                .mutex = .{},
                .can_send = .{},
                .can_recv = .{},
            };
        }

        pub fn send(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.queue.length >= Queue(T).BUFFER_SIZE) {
                self.can_send.wait(&self.mutex);
            }

            self.queue.push(item);
            self.can_recv.signal();
        }

        pub fn recv(self: *Self) T {
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
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        const BUFFER_SIZE = 32;

        buffer: [BUFFER_SIZE]T,
        length: usize,

        pub fn init() Self {
            return Self{
                .buffer = undefined,
                .length = 0,
            };
        }

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
