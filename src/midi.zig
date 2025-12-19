const std = @import("std");
const synth = @import("synth.zig");

pub const Frame = u64;

pub const MidiNote = struct {
    start: Frame,
    end: Frame,
    note: u8,
};

pub const MidiPlayer = struct {
    notes: []MidiNote,
    sample_accum: Frame = 0,
    pub fn init(alloc: std.mem.Allocator, notes_in: []const MidiNote) !MidiPlayer {
        const notes = try alloc.alloc(MidiNote, notes_in.len);
        std.mem.copyForwards(MidiNote, notes, notes_in);

        return .{
            .notes = notes,
            .sample_accum = 0,
        };
    }
    pub fn deinit(self: *MidiPlayer, alloc: std.mem.Allocator) void {
        alloc.free(self.notes);
    }
    pub fn advance(self: *MidiPlayer, ctx: *audio.Context, samples_elapsed: u64, q: *synth.NoteQueue) void {
        const pre_accum = self.sample_accum;
        const post_accum = self.sample_accum + samples_elapsed;
        self.sample_accum = post_accum;

        for (notes) |n| {
            if (pre_accum <= n.start and n.start <= post_accum) {
                q.push(.{ .On = n.note });
            }
            // TODO what if both start and end pass in the same samples_elapsed?
            // might lead to a hanging note?
            if (pre_accum <= n.end and n.end <= post_accum) {
                q.push(.{ .Off = n.note });
            }
        }
    }
};
