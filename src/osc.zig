const c = @cImport(@cInclude("soundio/soundio.h"));
const std = @import("std");

const OscType = enum { sine, square, triangle, saw }; // TODO pwm
const Osc = struct {
    freq: f32,
    osc_type: OscType,
    // pulseWidth: f32, // use union?
    // TODO: pulsewidth, pan, level, tune
    pub fn init(freq: f32, osc_type: OscType) Osc {
        return Osc{ .freq = freq, .osc_type = osc_type };
    }

    pub fn process(self: Osc, frame_count: usize, sample_rate: f32) void {
        const radians_per_second = self.freq * 2.0 * std.math.pi;
        var phase: f32 = 0;
        var samples = std.heap.page_allocator.alloc(f32, frame_count) catch unreachable;

        for (frame_count) |i| {
            samples[i] = switch (self.oscType) {
                OscType.sine => std.math.sin(phase),
                OscType.square => if (phase < std.math.pi) 1.0 else -1.0,
                OscType.triangle => 2.0 * std.math.abs(2.0 * (phase / (2.0 * std.math.pi) - std.math.floor(phase / (2.0 * std.math.pi) + 0.5))) - 1.0,
                OscType.saw => 2.0 * (phase / (2.0 * std.math.pi)) - 1.0,
            };

            phase += radians_per_second / sample_rate;
            phase = @mod(phase, 2.0 * std.math.pi);
        }
        return samples;
    }
};
