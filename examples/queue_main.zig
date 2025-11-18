const std = @import("std");

const Message = struct {
    id: u32,
    data: f32,
};

pub fn SpscQueue(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();
        write_idx: std.atomic.Value(usize) = .init(0),
        read_idx: std.atomic.Value(usize) = .init(0),
        buf: [N]T = undefined,

        pub fn push(self: *Self, value: T) bool {
            const w = self.write_idx.load(.monotonic);
            const r = self.read_idx.load(.acquire);

            if ((w + 1) % N == r) return false;

            self.buf[w] = value;
            self.write_idx.store((w + 1) % N, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const r = self.read_idx.load(.monotonic);
            const w = self.write_idx.load(.acquire);

            if (r == w) return null; // empty

            const val = self.buf[r];
            self.read_idx.store((r + 1) % N, .release);
            return val;
        }
    };
}

var queue: SpscQueue(Message, 2) = .{};

pub fn main() !void {
    const prod = try std.Thread.spawn(.{}, producer, .{});
    const cons = try std.Thread.spawn(.{}, consumer, .{});

    prod.join();
    cons.join();
}

fn producer() void {
    var x: f32 = 1.0;
    for (0..20) |i| {
        const ok = queue.push(.{ .id = @intCast(i), .data = x });
        if (!ok) std.debug.print("DROP {d}\n", .{i});
        x *= 1.3;
        std.Thread.sleep(30 * std.time.ns_per_ms);
    }
}

fn consumer() void {
    var got: usize = 0;
    while (got < 20) {
        if (queue.pop()) |msg| {
            std.debug.print("recv {d} {d}\n", .{ msg.id, msg.data });
            got += 1;
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
}
