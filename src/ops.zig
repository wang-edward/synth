const SpscQueue = @import("queue.zig").SpscQueue;
pub const PlaybackOp = union(enum) {
    Play,
    Pause,
    Reset,
    Seek: u64,
};

pub const Op = union(enum) {
    Playback: PlaybackOp,
};

pub const OpQueue = SpscQueue(Op, 32);
