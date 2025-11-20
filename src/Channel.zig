const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const Thread = std.Thread;

queue: Queue,

mutex: Thread.Mutex,
can_send: Thread.Condition,
can_recv: Thread.Condition,

pub fn init() Self {
    return Self{
        .queue = Queue.init(),
        .mutex = .{},
        .can_send = .{},
        .can_recv = .{},
    };
}

pub fn send(self: *Self, item: Queue.Item) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.queue.length >= Queue.BUFFER_SIZE) {
        self.can_send.wait(&self.mutex);
    }

    self.queue.push(item);
    self.can_recv.signal();
}

pub fn recv(self: *Self) Queue.Item {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.queue.length == 0) {
        self.can_recv.wait(&self.mutex);
    }

    const item = self.queue.pop();
    self.can_send.signal();
    return item;
}

// PERF: Convert to ring buffer
// TODO: Make generic over `Item`
const Queue = struct {
    const BUFFER_SIZE = 32;

    buffer: [BUFFER_SIZE]Item,
    length: usize,

    const Item = enum {
        redraw,
        update,
    };

    pub fn init() Queue {
        return Queue{
            .buffer = undefined,
            .length = 0,
        };
    }

    pub fn push(self: *Queue, item: Item) void {
        self.buffer[self.length] = item;
        self.length += 1;
    }

    pub fn pop(self: *Queue) Item {
        assert(self.length > 0);

        const item = self.buffer[0];
        self.length -= 1;
        for (0..self.length) |i| {
            self.buffer[i] = self.buffer[i + 1];
        }
        return item;
    }
};
