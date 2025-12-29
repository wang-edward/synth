const std = @import("std");

pub const Sample = f32;

const ProcessFn = *const fn (self: *anyopaque, ctx: *Context, out: []Sample) void;
pub const VTable = struct { process: ProcessFn };
pub const Node = struct { ptr: *anyopaque, v: *const VTable };

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
    vt: VTable = .{ .process = _process },

    pub fn init(freq: f32, kind: Kind, state: *State) Osc {
        return .{ .freq = freq, .kind = kind, .state = state };
    }

    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Osc = @ptrCast(@alignCast(p));
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

    pub fn asNode(self: *Osc) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Lpf = struct {
    pub const THERMAL_VOLTAGE = 0.312;

    pub const State = struct {
        V: [4]f32 = .{ 0, 0, 0, 0 },
        dV: [4]f32 = .{ 0, 0, 0, 0 },
        tV: [4]f32 = .{ 0, 0, 0, 0 },
    };

    input: Node,
    drive: f32,
    resonance: f32,
    cutoff: f32,
    state: *State,
    vt: VTable = .{ .process = _process },

    pub fn init(input: Node, drive: f32, resonance: f32, cutoff: f32, state: *State) Lpf {
        return .{ .input = input, .drive = drive, .resonance = resonance, .cutoff = cutoff, .state = state };
    }

    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Lpf = @ptrCast(@alignCast(p));
        const in = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, in);

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

    pub fn asNode(self: *Lpf) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

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

    input: Node,
    attack: f32,
    decay: f32,
    sustain: f32,
    release: f32,
    state: *State,
    vt: VTable = .{ .process = _process },

    pub fn init(input: Node, params: Params, state: *State) Adsr {
        return .{
            .input = input,
            .attack = params.attack,
            .decay = params.decay,
            .sustain = params.sustain,
            .release = params.release,
            .state = state,
        };
    }

    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Adsr = @ptrCast(@alignCast(p));
        const st = self.state;

        if (st.stage == .idle) {
            @memset(out, 0);
            return;
        }

        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);

        const sr = ctx.sample_rate;
        for (out, tmp) |*o, x| {
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

    pub fn asNode(self: *Adsr) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Gain = struct {
    input: Node,
    gain: f32,
    vt: VTable = .{ .process = _process },

    pub fn init(input: Node, g: f32) Gain {
        return .{ .input = input, .gain = g };
    }

    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Gain = @ptrCast(@alignCast(p));
        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);
        for (out, tmp) |*o, x| o.* = x * self.gain;
    }

    pub fn asNode(self: *Gain) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Distortion = struct {
    pub const Mode = enum { hard, soft, tanh };

    input: Node,
    drive: f32,
    mix: f32,
    mode: Mode,
    vt: VTable = .{ .process = _process },

    pub fn init(input: Node, drive: f32, mix: f32, mode: Mode) Distortion {
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

    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Distortion = @ptrCast(@alignCast(p));
        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);

        for (out, tmp) |*o, x| {
            const wet = self.shape(x);
            o.* = x + (wet - x) * self.mix;
        }
    }

    pub fn asNode(self: *Distortion) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Mixer = struct {
    inputs: []const Node,
    vt: VTable = .{ .process = _process },

    pub fn init(inputs: []const Node) Mixer {
        return .{ .inputs = inputs };
    }

    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Mixer = @ptrCast(@alignCast(p));
        @memset(out, 0);

        for (self.inputs) |n| {
            const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
            n.v.process(n.ptr, ctx, tmp);
            for (out, tmp) |*o, x| o.* += x;
        }
    }

    pub fn asNode(self: *Mixer) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const VoiceState = struct {
    osc1: Osc.State = .{},
    osc2: Osc.State = .{},
    lpf: Lpf.State = .{},
    adsr: Adsr.State = .{},
};

// =============================================================================
pub const DoubleBufferedGraph = struct {
    outputs: [2]Node,
    active: std.atomic.Value(u8),
    state: *VoiceState,

    pub fn init(state: *VoiceState) DoubleBufferedGraph {
        return .{
            .outputs = undefined,
            .active = std.atomic.Value(u8).init(0),
            .state = state,
        };
    }

    pub fn setOutput(self: *DoubleBufferedGraph, idx: u8, output: Node) void {
        self.outputs[idx] = output;
    }

    pub fn activeOutput(self: *DoubleBufferedGraph) Node {
        return self.outputs[self.active.load(.acquire)];
    }

    pub fn swap(self: *DoubleBufferedGraph) void {
        const cur = self.active.load(.acquire);
        self.active.store(cur ^ 1, .release);
    }

    pub fn process(self: *DoubleBufferedGraph, ctx: *Context, out: []Sample) void {
        const output = self.activeOutput();
        output.v.process(output.ptr, ctx, out);
    }
};
