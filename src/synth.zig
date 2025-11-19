const audio = @import("audio.zig");
const uni = @import("uni.zig");
const SpscQueue = @import("queue.zig").SpscQueue;

pub const NoteMsg = union(enum) {
    On: u8,
    Off: u8,
};

pub const Synth = union(enum) {
    Uni: uni.Uni,
    pub fn noteOn(self: *@This(), note: u8) void {
        switch (self.*) {
            .Uni => |*u| u.noteOn(note),
        }
    }
    pub fn noteOff(self: *@This(), note: u8) void {
        switch (self.*) {
            .Uni => |*u| u.noteOff(note),
        }
    }
    pub fn process(self: *@This(), ctx: *audio.Context, out: []f32) void {
        switch (self.*) {
            .Uni => |*u| u.process(ctx, out),
        }
    }
};

pub const NoteQueue = SpscQueue(NoteMsg, 16);
