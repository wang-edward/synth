const std = @import("std");

pub const Sample = f32;

const ProcessFn = *const fn (self: *anyopaque, ctx: *Context, out: []Sample) void;
const VTable = struct { process: ProcessFn };
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

pub const Gain = struct {
    input: *const Node,
    gain: f32,
    vt: VTable = .{ .process = Gain._process },

    pub fn init(input: *const Node, gain: f32) Gain {
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
    inputs: []*const Node,
    vt: VTable = .{ .process = Mixer._process },

    pub fn init(a: std.mem.Allocator, inputs: []const *const Node) !*Mixer {
        const m = try a.create(Mixer);
        m.* = .{ .inputs = try a.alloc(*const Node, inputs.len) };
        std.mem.copyForwards(*const Node, m.inputs, inputs);
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

    input: *const Node,
    drive: f32, // >= 1.0 for more distortion
    mix: f32, // 0 = dry, 1 = wet
    mode: Mode = .soft,
    vt: VTable = .{ .process = Distortion._process },

    pub fn init(input: *const Node, drive: f32, mix: f32, mode: Mode) Distortion {
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
