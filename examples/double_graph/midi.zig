const std = @import("std");
const SpscQueue = @import("queue.zig").SpscQueue;

pub const Frame = u64;
pub const MAX_NOTES_PER_BLOCK = 1024;

pub const Note = struct {
    start: Frame,
    end: Frame,
    note: u8,
};

pub const NoteMsg = union(enum) {
    On: u8,
    Off: u8,
};

pub const NoteQueue = SpscQueue(NoteMsg, 16);

pub fn beatsToFrames(beats: f32, tempo: f32, sample_rate: f32) Frame {
    return @intFromFloat((60.0 / tempo) * sample_rate * beats);
}

pub const Player = struct {
    notes: []Note,

    pub fn init(alloc: std.mem.Allocator, notes_in: []const Note) !Player {
        const notes = try alloc.alloc(Note, notes_in.len);
        std.mem.copyForwards(Note, notes, notes_in);
        return .{ .notes = notes };
    }

    pub fn deinit(self: *Player, alloc: std.mem.Allocator) void {
        alloc.free(self.notes);
    }

    pub fn advance(self: *Player, start: Frame, end: Frame, out: []NoteMsg) usize {
        std.debug.assert(end >= start);
        std.debug.assert(end - start < 8192);

        var count: usize = 0;

        for (self.notes) |n| {
            if (start <= n.start and n.start < end) {
                if (count < out.len) {
                    out[count] = .{ .On = n.note };
                    count += 1;
                }
            }
            if (start <= n.end and n.end < end) {
                if (count < out.len) {
                    out[count] = .{ .Off = n.note };
                    count += 1;
                }
            }
        }
        return count;
    }
};
