const SpscQueue = @import("queue.zig").SpscQueue;
pub const PlaybackOp = union(enum) {
    TogglePlay,
    Reset,
    Seek: u64,
};

pub const ParamId = union(enum) {
    Lpf: LpfParam,
};

pub const LpfParam = enum {
    Drive,
    Resonance,
    Cutoff,
};

pub const ParamOp = struct {
    track_id: usize,
    plugin_id: usize,
    id: ParamId,
    value: f32,
};

pub const Op = union(enum) {
    Playback: PlaybackOp,
    Param: ParamOp,
};

pub const OpQueue = SpscQueue(Op, 32);
