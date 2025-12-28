const std = @import("std");
const audio = @import("audio.zig");

// =============================================================================
// Synth - manages voice states and builds graph nodes
//
// This doesn't own the graph directly. Instead it:
// 1. Holds VoiceState for each voice (persistent across graph swaps)
// 2. Tracks voice allocation (which note each voice plays)
// 3. Provides buildNodes() to populate a slice of nodes
// =============================================================================

pub const SynthParams = struct {
    cutoff: f32 = 5000.0,
    resonance: f32 = 0.5,
    drive: f32 = 1.0,
    attack: f32 = 0.01,
    decay: f32 = 0.1,
    sustain: f32 = 0.4,
    release: f32 = 0.6,
};

pub const NODES_PER_VOICE = 6;
// Node offsets within a voice:
// 0: pwm osc
// 1: saw osc
// 2: sub osc
// 3: osc mixer
// 4: lpf
// 5: adsr

pub const Synth = struct {
    voice_count: usize,
    voice_states: []audio.VoiceState,
    voice_notes: []?u8,
    next_voice: usize = 0,

    // Storage for mixer arrays (need stable addresses)
    osc_mixer_inputs: [][3]u16,
    osc_mixer_gains: [][3]f32,
    voice_mixer_inputs: []u16,
    voice_mixer_gains: []f32,

    pub fn init(alloc: std.mem.Allocator, voice_count: usize) !*Synth {
        const s = try alloc.create(Synth);
        s.voice_count = voice_count;
        s.voice_states = try alloc.alloc(audio.VoiceState, voice_count);
        s.voice_notes = try alloc.alloc(?u8, voice_count);
        s.osc_mixer_inputs = try alloc.alloc([3]u16, voice_count);
        s.osc_mixer_gains = try alloc.alloc([3]f32, voice_count);
        s.voice_mixer_inputs = try alloc.alloc(u16, voice_count);
        s.voice_mixer_gains = try alloc.alloc(f32, voice_count);
        s.next_voice = 0;

        for (0..voice_count) |i| {
            s.voice_states[i] = .{};
            s.voice_notes[i] = null;
        }

        return s;
    }

    pub fn deinit(self: *Synth, alloc: std.mem.Allocator) void {
        alloc.free(self.voice_states);
        alloc.free(self.voice_notes);
        alloc.free(self.osc_mixer_inputs);
        alloc.free(self.osc_mixer_gains);
        alloc.free(self.voice_mixer_inputs);
        alloc.free(self.voice_mixer_gains);
        alloc.destroy(self);
    }

    /// Returns total nodes needed for this synth (voices + voice mixer)
    pub fn nodeCount(self: *const Synth) usize {
        return self.voice_count * NODES_PER_VOICE + 1; // +1 for voice mixer
    }

    /// Build nodes into the provided slice. base_idx is where this synth starts in the global graph.
    /// Returns the output node index (the voice mixer).
    pub fn buildNodes(self: *Synth, nodes: []audio.Node, base_idx: u16, params: SynthParams) u16 {
        const vc = self.voice_count;

        for (0..vc) |v| {
            const vs = &self.voice_states[v];
            const voice_base = base_idx + @as(u16, @intCast(v * NODES_PER_VOICE));

            // Oscillators
            nodes[voice_base + 0] = .{ .osc = .{
                .freq = 440,
                .kind = .{ .pwm = .{} },
                .state = &vs.pwm,
            } };
            nodes[voice_base + 1] = .{ .osc = .{
                .freq = 440,
                .kind = .saw,
                .state = &vs.saw,
            } };
            nodes[voice_base + 2] = .{ .osc = .{
                .freq = 440,
                .kind = .{ .sub = .{} },
                .state = &vs.sub,
            } };

            // Osc mixer
            self.osc_mixer_inputs[v] = .{ voice_base + 0, voice_base + 1, voice_base + 2 };
            self.osc_mixer_gains[v] = .{ 0.33, 0.33, 0.33 };
            nodes[voice_base + 3] = .{ .mixer = .{
                .inputs = &self.osc_mixer_inputs[v],
                .gains = &self.osc_mixer_gains[v],
            } };

            // LPF
            nodes[voice_base + 4] = .{ .lpf = .{
                .input = voice_base + 3,
                .drive = params.drive,
                .resonance = params.resonance,
                .cutoff = params.cutoff,
                .state = &vs.lpf,
            } };

            // ADSR
            nodes[voice_base + 5] = .{ .adsr = .{
                .input = voice_base + 4,
                .attack = params.attack,
                .decay = params.decay,
                .sustain = params.sustain,
                .release = params.release,
                .state = &vs.adsr,
            } };

            // Voice mixer input
            self.voice_mixer_inputs[v] = voice_base + 5;
            self.voice_mixer_gains[v] = 1.0 / @as(f32, @floatFromInt(vc));
        }

        // Voice mixer (sums all voices)
        const mixer_idx = base_idx + @as(u16, @intCast(vc * NODES_PER_VOICE));
        nodes[mixer_idx] = .{ .mixer = .{
            .inputs = self.voice_mixer_inputs,
            .gains = self.voice_mixer_gains,
        } };

        return mixer_idx;
    }

    /// Update frequencies for a voice in existing nodes
    pub fn setVoiceFreq(_: *Synth, nodes: []audio.Node, base_idx: u16, voice: usize, freq: f32) void {
        const voice_base = base_idx + @as(u16, @intCast(voice * NODES_PER_VOICE));
        for (0..3) |osc_offset| {
            switch (nodes[voice_base + osc_offset]) {
                .osc => |*o| o.freq = freq,
                else => {},
            }
        }
    }

    /// Copy frequencies from one node slice to another (for graph swap)
    pub fn copyFreqs(self: *Synth, from: []audio.Node, to: []audio.Node, base_idx: u16) void {
        for (0..self.voice_count) |v| {
            if (self.voice_notes[v] != null) {
                const voice_base = base_idx + @as(u16, @intCast(v * NODES_PER_VOICE));
                const freq = switch (from[voice_base]) {
                    .osc => |o| o.freq,
                    else => 440.0,
                };
                self.setVoiceFreq(to, base_idx, v, freq);
            }
        }
    }

    fn findFreeVoice(self: *Synth) ?usize {
        for (0..self.voice_count) |v| {
            if (self.voice_notes[v] == null and self.voice_states[v].adsr.isIdle()) {
                return v;
            }
        }
        return null;
    }

    pub fn noteOn(self: *Synth, note: u8, nodes: []audio.Node, base_idx: u16) void {
        const voice = self.findFreeVoice() orelse blk: {
            const v = self.next_voice;
            self.next_voice = (self.next_voice + 1) % self.voice_count;
            break :blk v;
        };

        self.voice_notes[voice] = note;
        self.voice_states[voice].resetOscs();
        self.voice_states[voice].adsr.noteOn();

        const freq = audio.noteToFreq(note);
        self.setVoiceFreq(nodes, base_idx, voice, freq);
    }

    pub fn noteOff(self: *Synth, note: u8) void {
        for (0..self.voice_count) |v| {
            if (self.voice_notes[v] == note) {
                self.voice_notes[v] = null;
                self.voice_states[v].adsr.noteOff();
            }
        }
    }

    pub fn allNotesOff(self: *Synth) void {
        for (0..self.voice_count) |v| {
            if (self.voice_notes[v]) |_| {
                self.voice_notes[v] = null;
                self.voice_states[v].adsr.noteOff();
            }
        }
    }
};
