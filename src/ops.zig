const SpscQueue = @import("queue.zig").SpscQueue;
const project = @import("project.zig");

pub const PlaybackOp = union(enum) {
    TogglePlay,
    Reset,
    Seek: u64,
};

pub const RecordOp = union(enum) {
    ToggleRecord: usize, // track index to record to
};

pub const Op = union(enum) {
    Playback: PlaybackOp,
    Record: RecordOp,
};

pub const OpQueue = SpscQueue(Op, 32);

pub const GraphOp = union(enum) {
    AddPlugin: struct { track: usize, plugin: project.Plugin },
    RemovePlugin: struct { track: usize, tag: project.PluginTag },
    AddTrack,
    RemoveTrack: usize,
};

pub const GraphQueue = SpscQueue(GraphOp, 32);
pub const GarbageQueue = SpscQueue(project.Plugin, 32);
