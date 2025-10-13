const std = @import("std");
const c = @cImport(@cInclude("soundio/soundio.h"));

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

const Sine = struct {
    freq: f32,
    phase: f32, // 0..1 cycles
    vt: VTable = .{ .process = Sine._process },

    pub fn init(freq: f32) Sine {
        return .{ .freq = freq, .phase = 0 };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Sine = @ptrCast(p);
        const inc = self.freq / ctx.sample_rate;
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            out[i] = @floatCast(std.math.sin(self.phase * 2.0 * std.math.pi));
            self.phase += inc;
            if (self.phase >= 1.0) self.phase -= 1.0;
        }
    }
    pub fn asNode(self: *Sine) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

const Gain = struct {
    input: *const Node,
    gain: f32,
    vt: VTable = .{ .process = Gain._process },

    pub fn init(input: *const Node, gain: f32) Gain {
        return .{ .input = input, .gain = gain };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Gain = @ptrCast(p);
        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);
        for (out, tmp) |*o, x| o.* = x * self.gain;
    }
    pub fn asNode(self: *Gain) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

const Mixer = struct {
    inputs: []const *const Node,
    vt: VTable = .{ .process = Mixer._process },

    pub fn init(a: std.mem.Allocator, inputs: []const *const Node) !*Mixer {
        const m = try a.create(Mixer);
        m.* = .{ .inputs = try a.alloc(*const Node, inputs.len) };
        std.mem.copy(*const Node, m.inputs, inputs);
        return m;
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Mixer = @ptrCast(p);
        std.mem.set(Sample, out, 0);
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

// --------- Globals used by the audio callback ----------
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();

// Scratch for the audio thread: no sys allocs in callback
var scratch_mem: [64 * 1024]u8 = undefined;
var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
var context: Context = undefined;

// Graph objects
var oscA = Sine.init(440);
var oscB = Sine.init(523.25);
var oscC = Sine.init(659.255);
var nodeOscA = oscA.asNode();
var nodeOscB = oscB.asNode();
var nodeOscC = oscC.asNode();

var gA = Gain.init(&nodeOscA, 0.2);
var gB = Gain.init(&nodeOscB, 0.2);
var gC = Gain.init(&nodeOscC, 0.2);
var nodeGA = gA.asNode();
var nodeGB = gB.asNode();
var nodeGC = gC.asNode();

var mix: *Mixer = undefined;
var root: Node = undefined;

// --------- libsoundio glue ----------
fn must(ok: c_int) void {
    if (ok != c.SoundIoErrorNone) @panic("soundio error");
}

fn write_callback(
    maybe_outstream: ?[*]c.SoundIoOutStream,
    _min: c_int,
    max: c_int,
) callconv(.c) void {
    _ = _min;
    const outstream: *c.SoundIoOutStream = &maybe_outstream.?[0];
    const layout = &outstream.layout;
    const chans: usize = @intCast(layout.channel_count);

    var frames_left = max;

    // reset the fixed-buffer + arena at start of this callback
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    context.arena = std.heap.ArenaAllocator.init(scratch_fba.allocator());

    while (frames_left > 0) {
        var frame_count = frames_left;

        var areas: [*]c.SoundIoChannelArea = undefined;
        must(c.soundio_outstream_begin_write(maybe_outstream, @ptrCast(&areas), &frame_count));
        if (frame_count == 0) break;

        // Render one block (mono) with the graph
        context.beginBlock();
        const mono = context.tmp().alloc(Sample, @intCast(frame_count)) catch unreachable;
        root.v.process(root.ptr, &context, mono);

        // Fan-out mono → all channels
        var f: c_int = 0;
        while (f < frame_count) : (f += 1) {
            const s = mono[@intCast(f)];
            var ch: usize = 0;
            while (ch < chans) : (ch += 1) {
                // libsoundio uses non-interleaved channel areas with a byte step per frame
                const ptr = areas[ch].ptr + areas[ch].step * f;
                const sample_ptr: *f32 = @ptrCast(@alignCast(ptr));
                sample_ptr.* = s;
            }
        }

        frames_left -= frame_count;
        must(c.soundio_outstream_end_write(maybe_outstream));
    }
}

// --------- App setup ----------
pub fn main() !void {
    defer _ = gpa.deinit();

    // Build graph storage on heap (for Mixer inputs array)
    mix = try Mixer.init(A, &[_]*const Node{ &nodeGA, &nodeGB, &nodeGC });
    defer {
        A.free(mix.inputs);
        A.destroy(mix);
    }
    root = mix.asNode();

    // soundio init
    const sio = c.soundio_create();
    if (sio == null) return error.NoMem;
    defer c.soundio_destroy(sio);

    must(c.soundio_connect(sio));
    c.soundio_flush_events(sio);

    const idx = c.soundio_default_output_device_index(sio);
    if (idx < 0) return error.NoOutputDeviceFound;

    const dev = c.soundio_get_output_device(sio, idx) orelse return error.NoMem;
    defer c.soundio_device_unref(dev);

    const out = c.soundio_outstream_create(dev) orelse return error.NoMem;
    defer c.soundio_outstream_destroy(out);

    out.*.format = c.SoundIoFormatFloat32NE;
    out.*.write_callback = write_callback;
    // optional: pick sample rate; if 0, backend chooses a default
    // out.*.sample_rate = 48000;

    must(c.soundio_outstream_open(out));

    // Initialize graph context with the chosen sample rate
    const sr: f32 = @floatFromInt(out.*.sample_rate);
    context = Context.init(scratch_fba.allocator(), sr);

    must(c.soundio_outstream_start(out));

    // Pump events
    while (true) c.soundio_wait_events(sio);
}
