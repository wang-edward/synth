const std = @import("std");

pub const Sample = f32;

pub const Context = struct {
    sample_rate: f32,
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator, sr: f32) Context {
        return .{ .sample_rate = sr, .arena = std.heap.ArenaAllocator.init(backing) };
    }
    pub fn beginBlock(self: *Context) void {
        _ = self.arena.reset(.retain_capacity);
    }
    pub fn tmp(self: *Context) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// =============================================================================
// Oscillator - state separated from params
// =============================================================================
pub const Osc = struct {
    pub const State = struct {
        phase: f32 = 0,

        pub fn reset(self: *State) void {
            self.phase = 0;
        }
    };

    pub const Kind = union(enum) {
        sine: void,
        saw: void,
        pwm: struct { duty: f32 = 0.5 },
        sub: struct { duty: f32 = 0.5, offset: f32 = -12 },
    };

    freq: f32,
    kind: Kind,
    state: *State,

    pub fn init(freq: f32, kind: Kind, state: *State) Osc {
        return .{ .freq = freq, .kind = kind, .state = state };
    }

    pub fn process(self: *Osc, ctx: *Context, out: []Sample) void {
        const base_inc = self.freq / ctx.sample_rate;
        const inc = switch (self.kind) {
            .sub => |sub| base_inc * std.math.exp2(sub.offset / 12.0),
            else => base_inc,
        };
        for (0..out.len) |i| {
            const sample: Sample = switch (self.kind) {
                .sine => std.math.sin(self.state.phase * 2.0 * std.math.pi),
                .saw => 2.0 * self.state.phase - 1.0,
                .pwm => |pwm| if (self.state.phase < pwm.duty) @as(f32, 1.0) else @as(f32, -1.0),
                .sub => |sub| if (self.state.phase < sub.duty) @as(f32, 1.0) else @as(f32, -1.0),
            };
            out[i] = sample;
            self.state.phase += inc;
            while (self.state.phase >= 1.0) self.state.phase -= 1.0;
        }
    }
};

// =============================================================================
// Low-pass filter (Moog ladder) - state separated from params
// =============================================================================
pub const Lpf = struct {
    pub const THERMAL_VOLTAGE = 0.312;

    pub const State = struct {
        V: [4]f32 = .{ 0, 0, 0, 0 },
        dV: [4]f32 = .{ 0, 0, 0, 0 },
        tV: [4]f32 = .{ 0, 0, 0, 0 },
    };

    input: u16,
    drive: f32,
    resonance: f32,
    cutoff: f32,
    state: *State,

    pub fn init(input: u16, drive: f32, resonance: f32, cutoff: f32, state: *State) Lpf {
        return .{ .input = input, .drive = drive, .resonance = resonance, .cutoff = cutoff, .state = state };
    }

    pub fn process(self: *Lpf, ctx: *Context, in: []const Sample, out: []Sample) void {
        const x = (std.math.pi * self.cutoff) / ctx.sample_rate;
        const g = 4.0 * std.math.pi * THERMAL_VOLTAGE * self.cutoff * (1.0 - x) / (1.0 + x);
        const st = self.state;

        for (0..out.len) |i| {
            const dV0 = -g * (std.math.tanh((self.drive * in[i] + self.resonance * st.V[3] / (2.0 * THERMAL_VOLTAGE)) + st.tV[0]));
            st.V[0] += (dV0 + st.dV[0]) / (2.0 * ctx.sample_rate);
            st.dV[0] = dV0;
            st.tV[0] = std.math.tanh(st.V[0] / (2.0 * THERMAL_VOLTAGE));

            const dV1 = g * (st.tV[0] - st.tV[1]);
            st.V[1] += (dV1 + st.dV[1]) / (2.0 * ctx.sample_rate);
            st.dV[1] = dV1;
            st.tV[1] = std.math.tanh(st.V[1] / (2.0 * THERMAL_VOLTAGE));

            const dV2 = g * (st.tV[1] - st.tV[2]);
            st.V[2] += (dV2 + st.dV[2]) / (2.0 * ctx.sample_rate);
            st.dV[2] = dV2;
            st.tV[2] = std.math.tanh(st.V[2] / (2.0 * THERMAL_VOLTAGE));

            const dV3 = g * (st.tV[2] - st.tV[3]);
            st.V[3] += (dV3 + st.dV[3]) / (2.0 * ctx.sample_rate);
            st.dV[3] = dV3;
            st.tV[3] = std.math.tanh(st.V[3] / (2.0 * THERMAL_VOLTAGE));

            out[i] = st.V[3];
        }
    }
};

// =============================================================================
// ADSR envelope - state separated from params
// =============================================================================
pub const Adsr = struct {
    pub const Params = struct {
        attack: f32,
        decay: f32,
        sustain: f32,
        release: f32,
    };

    pub const Stage = enum { idle, attack, decay, sustain, release };

    pub const State = struct {
        value: f32 = 0.0,
        stage: Stage = .idle,

        pub fn noteOn(self: *State) void {
            self.stage = .attack;
        }
        pub fn noteOff(self: *State) void {
            if (self.stage != .idle) self.stage = .release;
        }
        pub fn isIdle(self: *State) bool {
            return self.stage == .idle;
        }
    };

    input: u16,
    attack: f32,
    decay: f32,
    sustain: f32,
    release: f32,
    state: *State,

    pub fn init(input: u16, params: Params, state: *State) Adsr {
        return .{
            .input = input,
            .attack = params.attack,
            .decay = params.decay,
            .sustain = params.sustain,
            .release = params.release,
            .state = state,
        };
    }

    pub fn process(self: *Adsr, ctx: *Context, in: []const Sample, out: []Sample) void {
        const st = self.state;
        if (st.stage == .idle) {
            @memset(out, 0);
            return;
        }

        const sr = ctx.sample_rate;
        for (out, in) |*o, x| {
            switch (st.stage) {
                .idle => st.value = 0.0,
                .attack => {
                    st.value += 1.0 / (self.attack * sr);
                    if (st.value >= 1.0) {
                        st.value = 1.0;
                        st.stage = .decay;
                    }
                },
                .decay => {
                    st.value -= (1.0 - self.sustain) / (self.decay * sr);
                    if (st.value <= self.sustain) {
                        st.value = self.sustain;
                        st.stage = .sustain;
                    }
                },
                .sustain => {},
                .release => {
                    st.value -= self.sustain / (self.release * sr);
                    if (st.value <= 0.0) {
                        st.value = 0.0;
                        st.stage = .idle;
                    }
                },
            }
            o.* = x * st.value;
        }
    }
};

// =============================================================================
// Gain - stateless
// =============================================================================
pub const Gain = struct {
    input: u16,
    gain: f32,

    pub fn init(input: u16, g: f32) Gain {
        return .{ .input = input, .gain = g };
    }

    pub fn process(self: *Gain, in: []const Sample, out: []Sample) void {
        for (out, in) |*o, x| o.* = x * self.gain;
    }
};

// =============================================================================
// Mixer - stateless, sums multiple inputs with gains
// =============================================================================
pub const Mixer = struct {
    inputs: []const u16,
    gains: []const f32,

    pub fn init(inputs: []const u16, gains: []const f32) Mixer {
        return .{ .inputs = inputs, .gains = gains };
    }
};

// =============================================================================
// Distortion - stateless
// =============================================================================
pub const Distortion = struct {
    pub const Mode = enum { hard, soft, tanh };

    input: u16,
    drive: f32,
    mix: f32,
    mode: Mode,

    pub fn init(input: u16, drive: f32, mix: f32, mode: Mode) Distortion {
        return .{ .input = input, .drive = drive, .mix = mix, .mode = mode };
    }

    fn shape(self: *const Distortion, x: Sample) Sample {
        var y: f32 = x * self.drive;
        switch (self.mode) {
            .hard => {
                if (y > 1.0) y = 1.0;
                if (y < -1.0) y = -1.0;
            },
            .soft => {
                const y3 = y * y * y;
                y = y - (y3 * (1.0 / 3.0));
            },
            .tanh => {
                y = std.math.tanh(y);
            },
        }
        if (self.drive > 1.0) y /= self.drive;
        return y;
    }

    pub fn process(self: *Distortion, in: []const Sample, out: []Sample) void {
        for (out, in) |*o, x| {
            const wet = self.shape(x);
            o.* = x + (wet - x) * self.mix;
        }
    }
};

// =============================================================================
// Gate - stateless (open/close is a param, not state)
// =============================================================================
pub const Gate = struct {
    input: u16,
    open: bool,

    pub fn init(input: u16) Gate {
        return .{ .input = input, .open = false };
    }
};

// =============================================================================
// Delay - has state (buffer + write position)
// =============================================================================
pub const Delay = struct {
    pub const State = struct {
        buffer: []Sample,
        write_pos: usize = 0,

        pub fn init(alloc: std.mem.Allocator, buffer_size: usize) !*State {
            const s = try alloc.create(State);
            s.buffer = try alloc.alloc(Sample, buffer_size);
            s.write_pos = 0;
            @memset(s.buffer, 0);
            return s;
        }

        pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
            alloc.free(self.buffer);
            alloc.destroy(self);
        }
    };

    input: u16,
    delay_time: f32,
    feedback: f32,
    mix: f32,
    state: *State,

    pub fn init(input: u16, delay_time: f32, feedback: f32, mix: f32, state: *State) Delay {
        return .{
            .input = input,
            .delay_time = delay_time,
            .feedback = feedback,
            .mix = mix,
            .state = state,
        };
    }

    pub fn process(self: *Delay, ctx: *Context, in: []const Sample, out: []Sample) void {
        const delay_samples = @as(usize, @intFromFloat(self.delay_time * ctx.sample_rate));
        const buffer_len = self.state.buffer.len;
        const st = self.state;

        std.debug.assert(delay_samples < buffer_len);

        for (out, in) |*o, dry| {
            const read_pos = if (st.write_pos >= delay_samples)
                st.write_pos - delay_samples
            else
                buffer_len - (delay_samples - st.write_pos);

            const delayed = st.buffer[read_pos];
            st.buffer[st.write_pos] = dry + (delayed * self.feedback);
            o.* = dry * (1.0 - self.mix) + delayed * self.mix;
            st.write_pos = (st.write_pos + 1) % buffer_len;
        }
    }
};

// =============================================================================
// Graph node - flattened tagged union
// =============================================================================
pub const Node = union(enum) {
    osc: Osc,
    lpf: Lpf,
    adsr: Adsr,
    gain: Gain,
    mixer: Mixer,
    distortion: Distortion,
    gate: Gate,
    delay: Delay,
};

// =============================================================================
// Graph - array of nodes with process traversal
// =============================================================================
pub const Graph = struct {
    nodes: []Node,
    output: u16,

    pub fn process(self: *Graph, ctx: *Context, out: []Sample) void {
        self.processNode(ctx, self.output, out);
    }

    fn processNode(self: *Graph, ctx: *Context, idx: u16, out: []Sample) void {
        switch (self.nodes[idx]) {
            .osc => |*osc| osc.process(ctx, out),
            .lpf => |*lpf| {
                const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                self.processNode(ctx, lpf.input, tmp);
                lpf.process(ctx, tmp, out);
            },
            .adsr => |*adsr| {
                const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                self.processNode(ctx, adsr.input, tmp);
                adsr.process(ctx, tmp, out);
            },
            .gain => |*g| {
                const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                self.processNode(ctx, g.input, tmp);
                g.process(tmp, out);
            },
            .mixer => |mix| {
                @memset(out, 0);
                for (mix.inputs, mix.gains) |inp, gn| {
                    const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                    self.processNode(ctx, inp, tmp);
                    for (out, tmp) |*o, x| o.* += x * gn;
                }
            },
            .distortion => |*dist| {
                const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                self.processNode(ctx, dist.input, tmp);
                dist.process(tmp, out);
            },
            .gate => |*g| {
                if (!g.open) {
                    @memset(out, 0);
                    return;
                }
                self.processNode(ctx, g.input, out);
            },
            .delay => |*d| {
                const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                self.processNode(ctx, d.input, tmp);
                d.process(ctx, tmp, out);
            },
        }
    }
};

// =============================================================================
// VoiceState - all accumulator state for a single synth voice
// =============================================================================
pub const VoiceState = struct {
    pwm: Osc.State = .{},
    saw: Osc.State = .{},
    sub: Osc.State = .{},
    lpf: Lpf.State = .{},
    adsr: Adsr.State = .{},

    pub fn resetOscs(self: *VoiceState) void {
        self.pwm.reset();
        self.saw.reset();
        self.sub.reset();
    }
};

// =============================================================================
// DoubleBufferedGraph - two graphs, atomic swap, shared state
// =============================================================================
pub const DoubleBufferedGraph = struct {
    graphs: [2]Graph,
    active: std.atomic.Value(u8),

    pub fn init() DoubleBufferedGraph {
        return .{
            .graphs = undefined,
            .active = std.atomic.Value(u8).init(0),
        };
    }

    pub fn setGraph(self: *DoubleBufferedGraph, idx: u8, graph: Graph) void {
        self.graphs[idx] = graph;
    }

    pub fn activeGraph(self: *DoubleBufferedGraph) *Graph {
        return &self.graphs[self.active.load(.acquire)];
    }

    pub fn swap(self: *DoubleBufferedGraph) void {
        const cur = self.active.load(.acquire);
        self.active.store(cur ^ 1, .release);
    }

    pub fn process(self: *DoubleBufferedGraph, ctx: *Context, out: []Sample) void {
        self.activeGraph().process(ctx, out);
    }
};

// =============================================================================
// Utility
// =============================================================================
pub fn noteToFreq(note: u8) f32 {
    const TUNING: f32 = 440.0;
    const semitone_offset = @as(f32, @floatFromInt(@as(i16, @intCast(note)) - 69));
    return TUNING * std.math.exp2(semitone_offset / 12.0);
}
