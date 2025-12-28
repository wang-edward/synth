const std = @import("std");
const audio = @import("audio.zig");
const Params = @import("params.zig").Params;

const NoteState = union(enum) {
    Off,
    On: u8,
};

// =============================================================================
// Voice - a single synth voice with separated state and topology
// =============================================================================
pub const Voice = struct {
    // Persistent state (survives graph swaps)
    state: *audio.VoiceState,

    // Graph topology (can be rebuilt/swapped)
    nodes: []audio.Node,
    graph: audio.Graph,

    // Voice control
    note_state: NoteState = .Off,

    // Node indices (for updating params)
    const PWM_IDX: u16 = 0;
    const SAW_IDX: u16 = 1;
    const SUB_IDX: u16 = 2;
    const MIXER_IDX: u16 = 3;
    const LPF_IDX: u16 = 4;
    const ADSR_IDX: u16 = 5;
    const NODE_COUNT: usize = 6;

    pub fn init(alloc: std.mem.Allocator) !*Voice {
        const v = try alloc.create(Voice);
        v.state = try alloc.create(audio.VoiceState);
        v.state.* = .{};
        v.nodes = try alloc.alloc(audio.Node, NODE_COUNT);
        v.note_state = .Off;

        // Build initial graph topology
        v.buildGraph(440.0, 5000.0);

        return v;
    }

    pub fn deinit(self: *Voice, alloc: std.mem.Allocator) void {
        alloc.free(self.nodes);
        alloc.destroy(self.state);
        alloc.destroy(self);
    }

    fn buildGraph(self: *Voice, freq: f32, cutoff: f32) void {
        // Node 0: PWM oscillator
        self.nodes[PWM_IDX] = .{ .osc = audio.Osc.init(freq, .{ .pwm = .{} }, &self.state.pwm) };

        // Node 1: Saw oscillator
        self.nodes[SAW_IDX] = .{ .osc = audio.Osc.init(freq, .saw, &self.state.saw) };

        // Node 2: Sub oscillator
        self.nodes[SUB_IDX] = .{ .osc = audio.Osc.init(freq, .{ .sub = .{} }, &self.state.sub) };

        // Node 3: Mixer (sums the 3 oscillators)
        self.nodes[MIXER_IDX] = .{ .mixer = audio.Mixer.init(
            &[_]u16{ PWM_IDX, SAW_IDX, SUB_IDX },
            &[_]f32{ 0.33, 0.33, 0.33 },
        ) };

        // Node 4: Low-pass filter
        self.nodes[LPF_IDX] = .{ .lpf = audio.Lpf.init(MIXER_IDX, 1.0, 0.5, cutoff, &self.state.lpf) };

        // Node 5: ADSR envelope
        self.nodes[ADSR_IDX] = .{ .adsr = audio.Adsr.init(
            LPF_IDX,
            .{ .attack = 0.01, .decay = 0.1, .sustain = 0.4, .release = 0.6 },
            &self.state.adsr,
        ) };

        self.graph = .{ .nodes = self.nodes, .output = ADSR_IDX };
    }

    pub fn setFreq(self: *Voice, freq: f32) void {
        // Update frequency in all oscillators
        switch (self.nodes[PWM_IDX]) {
            .osc => |*o| o.freq = freq,
            else => {},
        }
        switch (self.nodes[SAW_IDX]) {
            .osc => |*o| o.freq = freq,
            else => {},
        }
        switch (self.nodes[SUB_IDX]) {
            .osc => |*o| o.freq = freq,
            else => {},
        }
    }

    pub fn setCutoff(self: *Voice, cutoff: f32) void {
        switch (self.nodes[LPF_IDX]) {
            .lpf => |*l| l.cutoff = cutoff,
            else => {},
        }
    }

    pub fn setNoteOn(self: *Voice, note: u8) void {
        self.note_state = .{ .On = note };
        const freq = audio.noteToFreq(note);
        self.state.resetOscs();
        self.setFreq(freq);
        self.state.adsr.noteOn();
    }

    pub fn setNoteOff(self: *Voice, note: u8) void {
        switch (self.note_state) {
            .On => |on| if (on == note) {
                self.note_state = .Off;
                self.state.adsr.noteOff();
            },
            else => {},
        }
    }

    pub fn isIdle(self: *Voice) bool {
        return self.note_state == .Off and self.state.adsr.isIdle();
    }

    pub fn process(self: *Voice, ctx: *audio.Context, out: []audio.Sample) void {
        self.graph.process(ctx, out);
    }
};

// =============================================================================
// Uni - polyphonic synth with multiple voices
// =============================================================================
pub const Uni = struct {
    params: Params(UniParams),
    voices: []*Voice,
    next_idx: usize = 0,

    const UniParams = struct {
        cutoff: f32 = 5000.0,
    };

    pub fn init(alloc: std.mem.Allocator, count: usize) !*Uni {
        const s = try alloc.create(Uni);
        s.params = Params(UniParams).init(.{});
        s.voices = try alloc.alloc(*Voice, count);
        for (s.voices) |*v| v.* = try Voice.init(alloc);
        s.next_idx = 0;
        return s;
    }

    pub fn deinit(self: *Uni, alloc: std.mem.Allocator) void {
        for (self.voices) |v| v.deinit(alloc);
        alloc.free(self.voices);
        alloc.destroy(self);
    }

    fn findFreeVoice(self: *Uni) ?*Voice {
        for (self.voices) |v| {
            if (v.isIdle()) return v;
        }
        return null;
    }

    pub fn noteOn(self: *Uni, note: u8) void {
        if (self.findFreeVoice()) |v| {
            v.setNoteOn(note);
        } else {
            // Voice stealing: use round-robin
            const idx = self.next_idx;
            self.next_idx = (self.next_idx + 1) % self.voices.len;
            self.voices[idx].setNoteOn(note);
        }
    }

    pub fn noteOff(self: *Uni, note: u8) void {
        for (self.voices) |v| v.setNoteOff(note);
    }

    pub fn allNotesOff(self: *Uni) void {
        for (self.voices) |v| {
            switch (v.note_state) {
                .On => |note| v.setNoteOff(note),
                .Off => {},
            }
        }
    }

    pub fn process(self: *Uni, ctx: *audio.Context, out: []audio.Sample) void {
        // Apply params
        const p = self.params.snapshot();
        for (self.voices) |v| {
            v.setCutoff(p.cutoff);
        }

        // Sum all voices
        @memset(out, 0);
        for (self.voices) |v| {
            const tmp = ctx.tmp().alloc(audio.Sample, out.len) catch unreachable;
            v.process(ctx, tmp);
            for (out, tmp) |*o, x| o.* += x;
        }
    }
};
