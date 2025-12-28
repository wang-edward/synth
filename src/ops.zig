const SpscQueue = @import("queue.zig").SpscQueue;
pub const PlaybackOp = union(enum) {
    TogglePlay,
    Reset,
    Seek: u64,
};

pub const ParamType = union(enum) {
    Uni: UniParam,
};

pub const UniParam = enum {
    Cutoff,
};

pub const InstrParamOp = struct {
    track_id: usize,
    id: ParamType,
    value: f32,
};

pub const Op = union(enum) {
    Playback: PlaybackOp,
    InstrParam: InstrParamOp,
};

pub const OpQueue = SpscQueue(Op, 32);
