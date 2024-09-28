const c = @cImport(@cInclude("soundio/soundio.h"));
const std = @import("std");

pub const OscType = enum { sine, square, triangle, saw };

pub const OscConfig = struct {
    freq: f32,
    osc_type: OscType,
    phase: f32,

    pub fn init(freq: f32, osc_type: OscType) OscConfig {
        return OscConfig{ .freq = freq, .osc_type = osc_type, .phase = 0.0 };
    }

    /// Generate samples with phase continuity
    pub fn process(self: *OscConfig, frame_count: usize, sample_rate: f32) []f32 {
        const radians_per_second = self.freq * 2.0 * std.math.pi;
        var samples = std.heap.page_allocator.alloc(f32, frame_count) catch unreachable;

        for (0..frame_count) |i| {
            samples[i] = switch (self.osc_type) {
                OscType.sine => std.math.sin(self.phase),
                OscType.square => if (self.phase < std.math.pi) 1.0 else -1.0,
                OscType.triangle => 2.0 * @abs(2.0 * (self.phase / (2.0 * std.math.pi) - std.math.floor(self.phase / (2.0 * std.math.pi) + 0.5))) - 1.0,
                OscType.saw => 2.0 * (self.phase / (2.0 * std.math.pi)) - 1.0,
            };

            // Increment phase based on the frequency and sample rate
            self.phase += radians_per_second / sample_rate;
            // Keep phase within the range [0, 2π)
            self.phase = @mod(self.phase, 2.0 * std.math.pi);
        }

        return samples;
    }
};
