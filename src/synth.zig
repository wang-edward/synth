const audio = @import("audio.zig");
const SpscQueue = @import("queue.zig").SpscQueue;

pub const NoteMsg = union(enum) {
    On: u8,
    Off: u8,
};

pub const NoteQueue = SpscQueue(NoteMsg, 16);
