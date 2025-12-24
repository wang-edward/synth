pub const PlaybackOp = union(enum) {
    Play,
    Pause,
    Reset,
    Seek: u64,
};

pub const Op = union(enum) {
    Playback: PlaybackOp,
};
