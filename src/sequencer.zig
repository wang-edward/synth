const std = @import("std");
const synth = @import("synth.zig");
const audio = @import("audio.zig");

pub const Step = union(enum) {
    Rest,
    Note: u8,
};

pub const Sequencer = struct {
    pattern: []const Step,
    index: usize = 0,
    sample_accum: u64 = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        pattern_in: []const Step,
    ) !Sequencer {
        const pattern = try alloc.alloc(Step, pattern_in.len);
        std.mem.copyForwards(Step, pattern, pattern_in);

        return .{
            .pattern = pattern,
            // TODO workaround because notes can only be 1 slot long
            // we wanna generate noteOn for the first note instead of skipping it
            .index = pattern.len - 1,
        };
    }

    pub fn deinit(self: *Sequencer, alloc: std.mem.Allocator) void {
        alloc.free(self.pattern);
    }

    // TODO is it right to pass in context here?
    // using the allocator in the main thread is race condition
    // right now only sample_rate and bpm are being read so its chill
    // but its possible to make mistakes later?
    // and like do i need to break the clean-ness just to get 2 floats in
    pub fn advance(self: *Sequencer, ctx: *audio.Context, samples_elapsed: u64, q: *synth.NoteQueue) void {
        // update state after samples_elapsed samples
        const samples_per_beat: u64 = @intFromFloat((60.0 / ctx.bpm) * ctx.sample_rate);

        self.sample_accum += samples_elapsed;

        if (self.sample_accum >= samples_per_beat) { // TODO >?
            self.sample_accum %= samples_per_beat;
            switch (self.pattern[self.index]) {
                .Note => |n| {
                    // TODO have a variable size queue on the Sequencer and try to drain it every time?
                    while (!q.push(.{ .Off = n })) {} // blocking push?
                },
                .Rest => {},
            }
            self.index = (self.index + 1) % self.pattern.len;

            switch (self.pattern[self.index]) {
                .Note => |n| {
                    while (!q.push(.{ .On = n })) {} // blocking push?
                },
                .Rest => {},
            }
        } else {}
    }
};
