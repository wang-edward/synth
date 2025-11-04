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
    mixer: *audio.Mixer, // TODO rename mixer

    noteState: NoteState = .Off,

    pub fn init(alloc: std.mem.Allocator, freq: f32) !*Voice {
        const v = try alloc.create(Voice);
        v.pwm = audio.Osc.init(freq, .{ .pwm = .{} });
        v.saw = audio.Osc.init(freq, .{ .saw = .{} });
        v.sub = audio.Osc.init(freq, .{ .sub = .{} });
        v.mixer = try audio.Mixer.init(alloc, &[_]audio.Node{
            v.pwm.asNode(), v.saw.asNode(), v.sub.asNode(),
        });
        v.noteState = .Off;
        return v;
    }
    pub fn deinit(self: *Voice, alloc: std.mem.Allocator) void {
        alloc.free(self.mixer.inputs);
        alloc.destroy(self.mixer);
        alloc.destroy(self);
    }
    pub fn asNode(self: *Voice) audio.Node {
        return self.mixer.asNode();
    }
};

pub const Synth = struct {
    const SYNTH_TUNING: f32 = 440.0;
    voices: []*Voice,
    mixer: *audio.Mixer,
    next_idx: usize = 0,

    pub fn init(alloc: std.mem.Allocator, count: usize) !*Synth {
        const s = try alloc.create(Synth);
        s.voices = try alloc.alloc(*Voice, count);
        for (s.voices) |*v| v.* = try Voice.init(alloc, 0.0);

        const NODE_BUF_SIZE = 16;
        std.debug.assert(count <= NODE_BUF_SIZE);
        var node_buf: [NODE_BUF_SIZE]audio.Node = undefined;
        const nodes = node_buf[0..count];
        for (s.voices, 0..) |*v, i| nodes[i] = v.*.asNode(); // const?

        s.mixer = try audio.Mixer.init(alloc, nodes);
        s.next_idx = 0;

        return s;
    }
    pub fn deinit(self: *Synth, alloc: std.mem.Allocator) void {
        for (self.voices) |*v| v.*.deinit(alloc);
        alloc.free(self.mixer.inputs);
        alloc.destroy(self.mixer);
        alloc.free(self.voices);
        alloc.destroy(self);
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
    pub fn asNode(self: *Synth) audio.Node {
        return self.mixer.asNode();
    }
};

fn noteToFreq(note: u8) f32 {
    return Synth.SYNTH_TUNING * std.math.exp2((note - 69) / 12);
}
