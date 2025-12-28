const std = @import("std");
const midi = @import("midi.zig");

pub const Step = union(enum) {
    Rest,
    Note: u8,
};

pub const Sequencer = struct {
    pattern: []const Step,
    index: usize = 0,
    sample_accum: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, pattern_in: []const Step) !Sequencer {
        const pattern = try alloc.alloc(Step, pattern_in.len);
        std.mem.copyForwards(Step, pattern, pattern_in);

        return .{
            .pattern = pattern,
            .index = pattern.len - 1,
        };
    }

    pub fn deinit(self: *Sequencer, alloc: std.mem.Allocator) void {
        alloc.free(self.pattern);
    }

    pub fn advance(self: *Sequencer, sample_rate: f32, bpm: f32, frames_elapsed: u64, q: *midi.NoteQueue) void {
        const samples_per_beat: u64 = @intFromFloat((60.0 / bpm) * sample_rate);

        self.sample_accum += frames_elapsed;

        if (self.sample_accum >= samples_per_beat) {
            self.sample_accum %= samples_per_beat;
            switch (self.pattern[self.index]) {
                .Note => |n| {
                    while (!q.push(.{ .Off = n })) {}
                },
                .Rest => {},
            }
            self.index = (self.index + 1) % self.pattern.len;

            switch (self.pattern[self.index]) {
                .Note => |n| {
                    while (!q.push(.{ .On = n })) {}
                },
                .Rest => {},
            }
        }
    }
};
