const std = @import("std");
const audio = @import("audio.zig");

const NoteState = union(enum) {
    Off,
    On: u8,
};

const Voice = struct {
    pwm: audio.Osc,
    saw: audio.Osc,
    sub: audio.Osc,
    // noise: audio.Noise, // TODO

    noteState: NoteState = .Off,

    pub fn init(freq: f32) Voice {
        return .{
            .pwm = audio.Osc.init(freq, .{ .pwm = .{} }),
            .saw = audio.Osc.init(freq, .{ .saw = .{} }),
            .sub = audio.Osc.init(freq, .{ .sub = .{} }),
            .noteState = .Off,
        };
    }
};

const Synth = struct {
    const SYNTH_TUNING: f32 = 440.0;
    voices: []Voice,
    next_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, count: usize) !*Synth {
        const s = try allocator.create(Synth);
        s.voices = try allocator.alloc(Voice, count);
        s.next_idx = 0;
        for (s.voices) |*v| v.* = Voice.init(0.0);
        return s;
    }

    pub fn deinit(self: *Synth, allocator: std.mem.Allocator) void {
        allocator.free(self.voices);
        allocator.destroy(self);
    }

    pub fn noteOn(self: *Synth, note: u8) void {
        const idx = self.next_idx;
        self.next_idx = (self.next_idx + 1) % self.voices.len;

        var v = &self.voices[idx];
        const freq = noteToFreq(note);
        v.pwm.freq = freq;
        v.saw.freq = freq;
        v.sub.freq = freq;
        v.noteState = NoteState.On(note);
    }

    pub fn noteOff(self: *Synth, note: u8) void {
        for (self.voices) |*v| {
            switch (v.noteState) {
                .Off => {},
                .On => |on| {
                    if (on == note)
                        v.noteState = .Off;
                },
            }
        }
        // TODO raise warning if note not found?
    }
};

fn noteToFreq(note: u8) f32 {
    return Synth.SYNTH_TUNING * std.math.exp2((note - 69) / 12);
}
