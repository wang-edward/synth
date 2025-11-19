const std = @import("std");

pub const Sample = f32;

const ProcessFn = *const fn (self: *anyopaque, ctx: *Context, out: []Sample) void;
const VTable = struct { process: ProcessFn };
pub const Node = struct { ptr: *anyopaque, v: *const VTable };

pub const Context = struct {
    sample_rate: f32,
    bpm: f32,
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator, sr: f32, bpm: f32) Context {
        return .{ .sample_rate = sr, .bpm = bpm, .arena = std.heap.ArenaAllocator.init(backing) };
    }
    pub fn beginBlock(self: *Context) void {
        _ = self.arena.reset(.retain_capacity);
    }
    pub fn tmp(self: *Context) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub const Osc = struct {
    freq: f32,
    phase: f32,
    kind: Kind,
    vt: VTable = .{ .process = Osc._process },

    pub const Kind = union(enum) {
        sine: struct {},
        pwm: struct { duty: f32 = 0.5 },
        saw: struct {},
        sub: struct { duty: f32 = 0.5, offset: f32 = -12 },
    };

    pub fn init(freq: f32, kind: Kind) Osc {
        return .{ .freq = freq, .phase = 0, .kind = kind };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Osc = @ptrCast(@alignCast(p));
        const base_inc = self.freq / ctx.sample_rate;
        const inc = switch (self.kind) {
            .sub => |sub| base_inc * std.math.exp2(sub.offset / 12.0),
            else => self.freq / ctx.sample_rate,
        };
        for (0..out.len) |i| {
            const sample: Sample = switch (self.kind) {
                .sine => std.math.sin(self.phase * 2.0 * std.math.pi),
                .pwm => |pwm| if (self.phase < pwm.duty) 1.0 else -1.0,
                .saw => 2.0 * self.phase - 1.0,
                .sub => |sub| if (self.phase < sub.duty) 1.0 else -1.0,
            };
            out[i] = @floatCast(sample);
            self.phase += inc;
            if (self.phase >= 1.0) self.phase -= 1.0;
        }
    }
    pub fn asNode(self: *Osc) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Lpf = struct {
    // References: "An Improved Virtual Analog Model of the Moog Ladder Filter"
    // Original Implementation: D'Angelo, Valimaki
    pub const THERMAL_VOLTAGE = 0.312;
    input: Node,
    V: [4]f32 = undefined,
    dV: [4]f32 = undefined,
    tV: [4]f32 = undefined,
    drive: f32,
    resonance: f32,
    cutoff: f32,
    vt: VTable = .{ .process = Lpf._process },

    pub fn init(input: Node, drive: f32, resonance: f32, cutoff: f32) Lpf {
        return .{ .input = input, .drive = drive, .resonance = resonance, .cutoff = cutoff };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Lpf = @ptrCast(@alignCast(p));
        const in = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, in);

        var dV0: f32 = undefined;
        var dV1: f32 = undefined;
        var dV2: f32 = undefined;
        var dV3: f32 = undefined;
        const x = (std.math.pi * self.cutoff) / ctx.sample_rate;
        const g = 4.0 * std.math.pi * THERMAL_VOLTAGE * self.cutoff * (1.0 - x) / (1.0 + x);
        for (0..out.len) |i| {
            dV0 = -g * (std.math.tanh((self.drive * in[i] + self.resonance * self.V[3] / (2.0 * THERMAL_VOLTAGE)) + self.tV[0]));
            self.V[0] += (dV0 + self.dV[0]) / (2.0 * ctx.sample_rate);
            self.dV[0] = dV0;
            self.tV[0] = std.math.tanh(self.V[0] / (2.0 * THERMAL_VOLTAGE));

            dV1 = g * (self.tV[0] - self.tV[1]);
            self.V[1] += (dV1 + self.dV[1]) / (2.0 * ctx.sample_rate);
            self.dV[1] = dV1;
            self.tV[1] = std.math.tanh(self.V[1] / (2.0 * THERMAL_VOLTAGE));

            dV2 = g * (self.tV[1] - self.tV[2]);
            self.V[2] += (dV2 + self.dV[2]) / (2.0 * ctx.sample_rate);
            self.dV[2] = dV2;
            self.tV[2] = std.math.tanh(self.V[2] / (2.0 * THERMAL_VOLTAGE));

            dV3 = g * (self.tV[2] - self.tV[3]);
            self.V[3] += (dV3 + self.dV[3]) / (2.0 * ctx.sample_rate);
            self.dV[3] = dV3;
            self.tV[3] = std.math.tanh(self.V[3] / (2.0 * THERMAL_VOLTAGE));

            out[i] = self.V[3];
        }
    }
    pub fn asNode(self: *Lpf) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Gain = struct {
    input: Node,
    gain: f32,
    vt: VTable = .{ .process = Gain._process },

    pub fn init(input: Node, gain: f32) Gain {
        return .{ .input = input, .gain = gain };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Gain = @ptrCast(@alignCast(p));
        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);
        for (out, tmp) |*o, x| o.* = x * self.gain;
    }
    pub fn asNode(self: *Gain) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Mixer = struct {
    inputs: []Node,
    vt: VTable = .{ .process = Mixer._process },

    pub fn init(a: std.mem.Allocator, inputs: []const Node) !*Mixer {
        const m = try a.create(Mixer);
        m.* = .{ .inputs = try a.alloc(Node, inputs.len) };
        std.mem.copyForwards(Node, m.inputs, inputs);
        return m;
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

pub const Distortion = struct {
    pub const Mode = enum { hard, soft, tanh };

    input: Node,
    drive: f32, // >= 1.0 for more distortion
    mix: f32, // 0 = dry, 1 = wet
    mode: Mode = .soft,
    vt: VTable = .{ .process = Distortion._process },

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
                // cubic soft clip (gentle, musical)
                const y3 = y * y * y;
                y = y - (y3 * (1.0 / 3.0));
            },
            .tanh => {
                y = std.math.tanh(y);
            },
        }
        // simple makeup so louder drive doesn’t explode output
        if (self.drive > 1.0) y /= self.drive;
        return y;
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Distortion = @ptrCast(@alignCast(p));
        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);

        // dry/wet blend
        for (out, tmp) |*o, x| {
            const wet = self.shape(x);
            o.* = x + (wet - x) * self.mix;
        }
    }
    pub fn asNode(self: *Distortion) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Gate = struct {
    input: Node,
    open: bool,
    vt: VTable = .{ .process = Gate._process },

    pub fn init(input: Node) Gate {
        return .{ .input = input, .open = false };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Gate = @ptrCast(@alignCast(p));
        if (!self.open) {
            @memset(out, 0);
            return;
        }
        self.input.v.process(self.input.ptr, ctx, out);
    }
    pub fn asNode(self: *Gate) Node {
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
    const State = enum { Idle, Attack, Decay, Sustain, Release };

    input: Node,
    params: Params,
    value: f32 = 0.0,
    state: State = .Idle,
    vt: VTable = .{ .process = Adsr._process },

    pub fn init(input: Node, params: Params) Adsr {
        return .{
            .input = input,
            .params = params,
        };
    }
    pub fn asNode(self: *Adsr) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
    pub fn noteOn(self: *Adsr) void {
        self.state = .Attack;
    }
    pub fn noteOff(self: *Adsr) void {
        if (self.state != .Idle) {
            self.state = .Release;
        }
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Adsr = @ptrCast(@alignCast(p));

        // short circuit dfs if idle
        if (self.state == .Idle) {
            @memset(out, 0);
            return;
        }

        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);

        const sr = ctx.sample_rate;
        for (out, tmp) |*o, x| {
            switch (self.state) {
                .Idle => self.value = 0.0,
                .Attack => {
                    self.value += 1.0 / (self.params.attack * sr);
                    if (self.value >= 1.0) {
                        self.value = 1.0;
                        self.state = .Decay;
                    }
                },
                .Decay => {
                    self.value -= (1.0 - self.params.sustain) / (self.params.decay * sr);
                    if (self.value <= self.params.sustain) {
                        self.value = self.params.sustain;
                        self.state = .Sustain;
                    }
                },
                .Sustain => {}, // hold
                .Release => {
                    self.value -= self.params.sustain / (self.params.release * sr);
                    if (self.value <= 0.0) {
                        self.value = 0.0;
                        self.state = .Idle;
                    }
                },
            }
            o.* = x * self.value;
        }
    }
};
