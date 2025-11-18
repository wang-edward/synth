const std = @import("std");

const Message = struct {
    id: u32,
    data: f32,
};

pub fn Queue(comptime T: type, comptime N: usize) type {
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
