const std = @import("std");
const audio = @import("audio.zig");
const synth = @import("synth.zig");

pub const Frame = u64;

pub const Note = struct {
    start: Frame,
    end: Frame,
    note: u8,
};

pub fn beatsToFrames(beats: f32, tempo: f32, ctx: *audio.Context) Frame {
    return @intFromFloat((60.0 / tempo) * ctx.sample_rate * beats);
}

pub const Player = struct {
    notes: []Note,
    pub fn init(alloc: std.mem.Allocator, notes_in: []const Note) !Player {
        const notes = try alloc.alloc(Note, notes_in.len);
        std.mem.copyForwards(Note, notes, notes_in);

        return .{
            .notes = notes,
        };
    }
    pub fn deinit(self: *Player, alloc: std.mem.Allocator) void {
        alloc.free(self.notes);
    }
    pub fn advance(self: *Player, start: Frame, end: Frame, q: *synth.NoteQueue) void {
        // std.debug.print("start: {}, end: {}", .{ start, end });
        // std.debug.print("notes: {any}", .{self.notes});
        std.debug.assert(end >= start);
        std.debug.assert(end - start < 8192);

        for (self.notes) |n| {
            // TODO check what happens when advance() is called on the latter boundary wrt <, <=
            // so what if pre_accum == n.start... is this even a problem?
            if (start <= n.start and n.start < end) {
                std.debug.print("on: {}\n", .{n});
                while (!q.push(.{ .On = n.note })) {}
            }
            if (start <= n.end and n.end < end) {
                std.debug.print("off: {}\n", .{n});
                while (!q.push(.{ .Off = n.note })) {}
            }
        }
    }
};
