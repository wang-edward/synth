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
    mixer: *audio.Mixer,
    lpf: audio.Lpf,
    adsr: audio.Adsr,

    // TODO is notestate necessary if we have adsr?
    // technically adsr.state == .Idle has the same meaning
    // but then the caller has to reach deep into Voice
    noteState: NoteState = .Off,

    pub fn init(alloc: std.mem.Allocator, freq: f32) !*Voice {
        const v = try alloc.create(Voice);
        v.pwm = audio.Osc.init(freq, .{ .pwm = .{} });
        v.saw = audio.Osc.init(freq, .{ .saw = .{} });
        v.sub = audio.Osc.init(freq, .{ .sub = .{} });
        v.mixer = try audio.Mixer.init(alloc, &[_]audio.Node{
            v.pwm.asNode(), v.saw.asNode(), v.sub.asNode(),
        });
        v.lpf = audio.Lpf.init(v.mixer.asNode(), 1.0, 0.5, 5000.0);
        v.adsr = audio.Adsr.init(v.lpf.asNode(), .{ .attack = 0.01, .decay = 0.1, .sustain = 0.4, .release = 0.6 });
        v.noteState = .Off;
        return v;
    }
    pub fn deinit(self: *Voice, alloc: std.mem.Allocator) void {
        alloc.free(self.mixer.inputs);
        alloc.destroy(self.mixer);
        alloc.destroy(self);
    }
    pub fn asNode(self: *Voice) audio.Node {
        return self.adsr.asNode();
    }
    pub fn setNoteOn(self: *Voice, note: u8) void {
        self.noteState = .{ .On = note };
        const freq = noteToFreq(note);
        self.pwm.freq = freq;
        self.saw.freq = freq;
        self.sub.freq = freq;
        self.adsr.noteOn();
    }
    pub fn setNoteOff(self: *Voice, note: u8) void {
        switch (self.noteState) {
            .On => |on| if (on == note) {
                self.noteState = .Off;
                self.adsr.noteOff();
            },
            else => {},
        }
    }
    pub fn setLpfCutoff(self: *Voice, cutoff: f32) void {
        self.lpf.cutoff = cutoff;
    }
};

pub const Uni = struct {
    const SYNTH_TUNING: f32 = 440.0;
    voices: []*Voice,
    mixer: *audio.Mixer,
    next_idx: usize = 0,

    pub fn init(alloc: std.mem.Allocator, count: usize) !*Uni {
        const s = try alloc.create(Uni);
        s.voices = try alloc.alloc(*Voice, count);
        for (s.voices) |*v| v.* = try Voice.init(alloc, 0.0);

        const NODE_BUF_SIZE = 16;
        std.debug.assert(count <= NODE_BUF_SIZE);
        var node_buf: [NODE_BUF_SIZE]audio.Node = undefined;
        const nodes = node_buf[0..count];
        for (s.voices, 0..) |v, i| nodes[i] = v.asNode(); // const?

        s.mixer = try audio.Mixer.init(alloc, nodes);
        s.next_idx = 0;

        return s;
    }
    pub fn deinit(self: *Uni, alloc: std.mem.Allocator) void {
        for (self.voices) |v| v.deinit(alloc);
        alloc.free(self.mixer.inputs);
        alloc.destroy(self.mixer);
        alloc.free(self.voices);
        alloc.destroy(self);
    }
    pub fn asNode(self: *Uni) audio.Node {
        return self.mixer.asNode();
    }
    fn findFreeVoice(self: *Uni) ?*Voice {
        for (self.voices) |v| {
            switch (v.noteState) {
                .Off => return v,
                else => {},
            }
        }
        return null;
    }
    pub fn noteOn(self: *Uni, note: u8) void {
        const freeVoice = findFreeVoice(self);
        if (freeVoice) |v| {
            v.setNoteOn(note);
        } else {
            const idx = self.next_idx;
            self.next_idx = (self.next_idx + 1) % self.voices.len;
            self.voices[idx].setNoteOn(note);
        }
    }
    pub fn noteOff(self: *Uni, note: u8) void {
        // TODO weird logic here with repeat notes in Voices
        // not sure what to do in this case yet
        for (self.voices) |v| v.setNoteOff(note);
        // TODO raise warning if note not found?
    }
    pub fn setLpfCutoff(self: *Uni, cutoff: f32) void {
        for (self.voices) |v| v.setLpfCutoff(cutoff);
    }
};

fn noteToFreq(note: u8) f32 {
    const semitone_offset = @as(f32, @floatFromInt(@as(i16, @intCast(note)) - 69));
    return Uni.SYNTH_TUNING * std.math.exp2(semitone_offset / 12.0);
}
