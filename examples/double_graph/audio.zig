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
// State types - these persist across graph swaps
// =============================================================================

pub const OscState = struct {
    phase: f32 = 0,

    pub fn reset(self: *OscState) void {
        self.phase = 0;
    }
};

pub const LpfState = struct {
    V: [4]f32 = .{ 0, 0, 0, 0 },
    dV: [4]f32 = .{ 0, 0, 0, 0 },
    tV: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const AdsrState = struct {
    pub const Stage = enum { idle, attack, decay, sustain, release };

    value: f32 = 0.0,
    stage: Stage = .idle,

    pub fn noteOn(self: *AdsrState) void {
        self.stage = .attack;
    }
    pub fn noteOff(self: *AdsrState) void {
        if (self.stage != .idle) self.stage = .release;
    }
    pub fn isIdle(self: *AdsrState) bool {
        return self.stage == .idle;
    }
};

pub const DelayState = struct {
    buffer: []Sample,
    write_pos: usize = 0,

    pub fn init(alloc: std.mem.Allocator, buffer_size: usize) !*DelayState {
        const s = try alloc.create(DelayState);
        s.buffer = try alloc.alloc(Sample, buffer_size);
        s.write_pos = 0;
        @memset(s.buffer, 0);
        return s;
    }

    pub fn deinit(self: *DelayState, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
        alloc.destroy(self);
    }
};

// =============================================================================
// VoiceState - all state for one synth voice
// =============================================================================

pub const VoiceState = struct {
    pwm: OscState = .{},
    saw: OscState = .{},
    sub: OscState = .{},
    lpf: LpfState = .{},
    adsr: AdsrState = .{},

    pub fn resetOscs(self: *VoiceState) void {
        self.pwm.reset();
        self.saw.reset();
        self.sub.reset();
    }
};

// =============================================================================
// Node types - contain params + pointer to state
// =============================================================================

pub const Osc = struct {
    pub const Kind = union(enum) {
        sine: void,
        saw: void,
        pwm: struct { duty: f32 = 0.5 },
        sub: struct { duty: f32 = 0.5, offset: f32 = -12 },
    };

    freq: f32,
    kind: Kind,
    state: *OscState,

    pub fn process(self: *const Osc, ctx: *const Context, out: []Sample) void {
        const base_inc = self.freq / ctx.sample_rate;
        const inc = switch (self.kind) {
            .sub => |sub| base_inc * std.math.exp2(sub.offset / 12.0),
            else => base_inc,
        };
        const state = self.state;
        for (0..out.len) |i| {
            const sample: Sample = switch (self.kind) {
                .sine => std.math.sin(state.phase * 2.0 * std.math.pi),
                .saw => 2.0 * state.phase - 1.0,
                .pwm => |pwm| if (state.phase < pwm.duty) @as(f32, 1.0) else @as(f32, -1.0),
                .sub => |sub| if (state.phase < sub.duty) @as(f32, 1.0) else @as(f32, -1.0),
            };
            out[i] = sample;
            state.phase += inc;
            while (state.phase >= 1.0) state.phase -= 1.0;
        }
    }
};

pub const Lpf = struct {
    pub const THERMAL_VOLTAGE: f32 = 0.312;

    input: u16,
    drive: f32,
    resonance: f32,
    cutoff: f32,
    state: *LpfState,

    pub fn process(self: *const Lpf, ctx: *const Context, in: []const Sample, out: []Sample) void {
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

pub const Adsr = struct {
    input: u16,
    attack: f32,
    decay: f32,
    sustain: f32,
    release: f32,
    state: *AdsrState,

    pub fn process(self: *const Adsr, ctx: *const Context, in: []const Sample, out: []Sample) void {
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

pub const Gain = struct {
    input: u16,
    gain: f32,

    pub fn process(self: *const Gain, in: []const Sample, out: []Sample) void {
        for (out, in) |*o, x| o.* = x * self.gain;
    }
};

pub const Mixer = struct {
    inputs: []const u16,
    gains: []const f32,
};

pub const Delay = struct {
    input: u16,
    delay_time: f32,
    feedback: f32,
    mix: f32,
    state: *DelayState,

    pub fn process(self: *const Delay, ctx: *const Context, in: []const Sample, out: []Sample) void {
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
// Node union
// =============================================================================

pub const Node = union(enum) {
    osc: Osc,
    lpf: Lpf,
    adsr: Adsr,
    gain: Gain,
    mixer: Mixer,
    delay: Delay,
};

// =============================================================================
// Graph - processes nodes by index
// =============================================================================

pub const Graph = struct {
    nodes: []Node,
    output: u16,

    pub fn process(self: *const Graph, ctx: *Context, out: []Sample) void {
        self.processNode(ctx, self.output, out);
    }

    fn processNode(self: *const Graph, ctx: *Context, idx: u16, out: []Sample) void {
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
            .delay => |*d| {
                const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
                self.processNode(ctx, d.input, tmp);
                d.process(ctx, tmp, out);
            },
        }
    }
};

// =============================================================================
// DoubleBufferedGraph - atomic swap between two graphs
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

    pub fn activeIdx(self: *DoubleBufferedGraph) u8 {
        return self.active.load(.acquire);
    }

    pub fn backIdx(self: *DoubleBufferedGraph) u8 {
        return self.active.load(.acquire) ^ 1;
    }

    pub fn swap(self: *DoubleBufferedGraph) void {
        const cur = self.active.load(.acquire);
        self.active.store(cur ^ 1, .release);
    }

    pub fn process(self: *DoubleBufferedGraph, ctx: *Context, out: []Sample) void {
        self.graphs[self.activeIdx()].process(ctx, out);
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
