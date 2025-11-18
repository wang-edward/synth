const Queue = @import("queue.zig").Queue;
const std = @import("std");

test "basic push/pop" {
    var q: Queue(u32, 4) = .{};

    try std.testing.expect(q.pop() == null); // empty

    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(q.push(3));

    try std.testing.expect(!q.push(4)); // full

    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    try std.testing.expectEqual(@as(?u32, 3), q.pop());
    try std.testing.expect(q.pop() == null); // empty again
}

test "wraparound correctness" {
    var q: Queue(u32, 3) = .{};

    try std.testing.expect(q.push(10));
    try std.testing.expect(q.push(20));
    try std.testing.expectEqual(@as(?u32, 10), q.pop());

    try std.testing.expect(q.push(30)); // wraps to slot 0
    try std.testing.expect(q.push(40)); // fills last slot

    try std.testing.expect(!q.push(50)); // full

    try std.testing.expectEqual(@as(?u32, 20), q.pop());
    try std.testing.expectEqual(@as(?u32, 30), q.pop());
    try std.testing.expectEqual(@as(?u32, 40), q.pop());
    try std.testing.expect(q.pop() == null);
}

test "stress single-thread" {
    var q: Queue(u32, 128) = .{};

    for (0..100_000) |i| {
        // fill it
        while (q.push(@intCast(i)) == false) {}
        // drain it
        try std.testing.expectEqual(@as(?u32, @intCast(i)), q.pop());
    }
}

test "2-thread correctness" {
    const COUNT = 200_000;
    var q: Queue(u32, 256) = .{};

    var producer = try std.Thread.spawn(.{}, struct {
        fn run() void {
            var i: u32 = 0;
            while (i < COUNT) : (i += 1) {
                while (!q.push(i)) {}
            }
        }
    }.run, .{});

    var consumer = try std.Thread.spawn(.{}, struct {
        fn run() void {
            var expected: u32 = 0;
            while (expected < COUNT) {
                if (q.pop()) |val| {
                    if (val != expected)
                        @panic("ORDER VIOLATION");
                    expected += 1;
                }
            }
        }
    }.run, .{});

    producer.join();
    consumer.join();
}

test "full/empty flip stress" {
    var q: Queue(u8, 2) = .{}; // smallest nontrivial queue

    inline for (0..10000) |_| {
        try std.testing.expect(q.push(1));
        try std.testing.expect(q.pop() == 1);
    }
}
