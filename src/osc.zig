const c = @cImport(@cInclude("soundio/soundio.h"));
const std = @import("std");

pub const Type = enum { sine, square, triangle, saw };

pub const Config = struct {
    freq: f32,
    level: f32,
    osc_type: Type,
    phase: f32,

    pub fn init(freq: f32, level: f32, osc_type: Type) Config {
        return Config{ .freq = freq, .level = level, .osc_type = osc_type, .phase = 0.0 };
    }

    pub fn process(self: *Config, t: f32) f32 {
        const radians_per_second = self.freq * 2.0 * std.math.pi;
        const period = 1.0 / self.freq;
        const normalized_time = @mod(t, period) / period;

        return switch (self.osc_type) {
            Type.sine => std.math.sin(t * radians_per_second),
            Type.square => if (normalized_time < 0.5) 1.0 else -1.0,
            Type.triangle => 4.0 * @abs(normalized_time - 0.5) - 1.0,
            Type.saw => 2.0 * normalized_time - 1.0,
        };
    }
};
