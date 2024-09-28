const c = @cImport(@cInclude("soundio/soundio.h"));
const std = @import("std");

pub const OscType = enum { sine, square, triangle, saw };

pub const OscConfig = struct {
    freq: f32,
    level: f32,
    osc_type: OscType,
    phase: f32,

    pub fn init(freq: f32, level: f32, osc_type: OscType) OscConfig {
        return OscConfig{ .freq = freq, .level = level, .osc_type = osc_type, .phase = 0.0 };
    }

    pub fn process(self: *OscConfig, audio_buffer: []f32, sample_rate: f32) void {
        const radians_per_second = self.freq * 2.0 * std.math.pi;

        for (0..audio_buffer.len) |i| {
            var sample: f32 = undefined;
            sample = switch (self.osc_type) {
                OscType.sine => std.math.sin(self.phase),
                OscType.square => if (self.phase < std.math.pi) 1.0 else -1.0,
                OscType.triangle => 2.0 * @abs(2.0 * (self.phase / (2.0 * std.math.pi) - std.math.floor(self.phase / (2.0 * std.math.pi) + 0.5))) - 1.0,
                OscType.saw => 2.0 * (self.phase / (2.0 * std.math.pi)) - 1.0,
            };

            audio_buffer[i] = sample * self.level;

            self.phase += radians_per_second / sample_rate;
            self.phase = @mod(self.phase, 2.0 * std.math.pi);
        }
    }
};
