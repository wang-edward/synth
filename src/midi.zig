const std = @import("std");
const audio = @import("audio.zig");
const synth = @import("synth.zig");

pub const Frame = u64;

pub const Note = struct {
    start: Frame,
    end: Frame,
    note: u8,
};

pub fn beatsToSamples(beats: f32, tempo: f32, ctx: *audio.Context) Frame {
    return @intFromFloat((60.0 / tempo) * ctx.sample_rate * beats);
}

pub const Player = struct {
    notes: []Note,
    sample_accum: Frame = 0,
    pub fn init(alloc: std.mem.Allocator, notes_in: []const Note) !Player {
        const notes = try alloc.alloc(Note, notes_in.len);
        std.mem.copyForwards(Note, notes, notes_in);

        return .{
            .notes = notes,
            .sample_accum = 0,
        };
    }
    pub fn deinit(self: *Player, alloc: std.mem.Allocator) void {
        alloc.free(self.notes);
    }
    pub fn advance(self: *Player, samples_elapsed: u64, q: *synth.NoteQueue) void {
        const pre_accum = self.sample_accum;
        const post_accum = self.sample_accum + samples_elapsed;
        self.sample_accum = post_accum;

        // std.debug.print("samples_elapsed: {}, pre_accum: {}, post_accum: {}\n", .{ samples_elapsed, pre_accum, post_accum });
        std.debug.assert(samples_elapsed < 8192);

        for (self.notes) |n| {
            // TODO check what happens when advance() is called on the latter boundary wrt <, <=
            // so what if pre_accum == n.start... is this even a problem?
            if (pre_accum <= n.start and n.start < post_accum) {
                // std.debug.print("on: {}\n", .{n});
                while (q.push(.{ .On = n.note })) {}
            }
            // TODO what if both start and end pass in the same samples_elapsed?
            // might lead to a hanging note?
            if (pre_accum <= n.end and n.end < post_accum) {
                // std.debug.print("off: {}\n", .{n});
                while (q.push(.{ .Off = n.note })) {}
            }
        }
    }
};
