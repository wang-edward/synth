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
    };

    pub const Kind = union(enum) {
        sine: void,
        saw: void,
        square: struct { duty: f32 = 0.5 },
    };

    freq: f32,
    kind: Kind,
    state: *State,

    pub fn init(freq: f32, kind: Kind, state: *State) Osc {
        return .{ .freq = freq, .kind = kind, .state = state };
    }

    pub fn process(self: *Osc, ctx: *Context, out: []Sample) void {
        const inc = self.freq / ctx.sample_rate;
        for (0..out.len) |i| {
            const sample: Sample = switch (self.kind) {
                .sine => std.math.sin(self.state.phase * 2.0 * std.math.pi),
                .saw => 2.0 * self.state.phase - 1.0,
                .square => |sq| if (self.state.phase < sq.duty) @as(f32, 1.0) else @as(f32, -1.0),
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

    drive: f32,
    resonance: f32,
    cutoff: f32,
    state: *State,

    pub fn init(drive: f32, resonance: f32, cutoff: f32, state: *State) Lpf {
        return .{ .drive = drive, .resonance = resonance, .cutoff = cutoff, .state = state };
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
    };

    params: Params,
    state: *State,

    pub fn init(params: Params, state: *State) Adsr {
        return .{ .params = params, .state = state };
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
                    st.value += 1.0 / (self.params.attack * sr);
                    if (st.value >= 1.0) {
                        st.value = 1.0;
                        st.stage = .decay;
                    }
                },
                .decay => {
                    st.value -= (1.0 - self.params.sustain) / (self.params.decay * sr);
                    if (st.value <= self.params.sustain) {
                        st.value = self.params.sustain;
                        st.stage = .sustain;
                    }
                },
                .sustain => {},
                .release => {
                    st.value -= self.params.sustain / (self.params.release * sr);
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
// Gain - stateless, just processes samples
// =============================================================================
pub const Gain = struct {
    gain: f32,

    pub fn init(g: f32) Gain {
        return .{ .gain = g };
    }

    pub fn process(self: *Gain, in: []const Sample, out: []Sample) void {
        for (out, in) |*o, x| o.* = x * self.gain;
    }
};

// =============================================================================
// Graph node - tagged union representing any node type with its inputs
// =============================================================================
pub const Node = union(enum) {
    osc: Osc,
    lpf: struct { params: Lpf, input: u16 },
    adsr: struct { params: Adsr, input: u16 },
    gain: struct { params: Gain, input: u16 },
    mixer: struct { inputs: []const u16, gains: []const f32 },
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
                lpf.params.process(ctx, tmp, out);
            },
            .adsr => |*adsr| {
                const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                self.processNode(ctx, adsr.input, tmp);
                adsr.params.process(ctx, tmp, out);
            },
            .gain => |*g| {
                const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                self.processNode(ctx, g.input, tmp);
                g.params.process(tmp, out);
            },
            .mixer => |mix| {
                @memset(out, 0);
                for (mix.inputs, mix.gains) |inp, gn| {
                    const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                    self.processNode(ctx, inp, tmp);
                    for (out, tmp) |*o, x| o.* += x * gn;
                }
            },
        }
    }
};

// =============================================================================
// SharedState - all accumulator state for a synth voice
// =============================================================================
pub const VoiceState = struct {
    osc1: Osc.State = .{},
    osc2: Osc.State = .{},
    lpf: Lpf.State = .{},
    adsr: Adsr.State = .{},
};

// =============================================================================
// DoubleBufferedGraph - two graphs, atomic swap, shared state
// =============================================================================
pub const DoubleBufferedGraph = struct {
    graphs: [2]Graph,
    active: std.atomic.Value(u8),
    state: *VoiceState,

    pub fn init(state: *VoiceState) DoubleBufferedGraph {
        return .{
            .graphs = undefined,
            .active = std.atomic.Value(u8).init(0),
            .state = state,
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
