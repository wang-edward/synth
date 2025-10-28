const audio = @import("audio.zig");

const Voice = struct {
    pwm: audio.Osc,
    saw: audio.Osc,
    sub: audio.Osc,
    // noise: audio.Noise, // TODO
};
