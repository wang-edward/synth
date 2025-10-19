const std = @import("std");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");

// Globals used by the audio callback
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();

// Scratch for the audio thread: no sys allocs in callback
var scratch_mem: [64 * 1024]u8 = undefined;
var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
var context: audio.Context = undefined;

// Graph objects
var oscA = audio.Sine.init(440);
var oscB = audio.Sine.init(523.25);
var oscC = audio.Sine.init(659.255);
var nodeOscA = oscA.asNode();
var nodeOscB = oscB.asNode();
var nodeOscC = oscC.asNode();

var gA = audio.Gain.init(&nodeOscA, 0.2);
var gB = audio.Gain.init(&nodeOscB, 0.2);
var gC = audio.Gain.init(&nodeOscC, 0.2);
var nodeGA = gA.asNode();
var nodeGB = gB.asNode();
var nodeGC = gC.asNode();

var mixer: *audio.Mixer = undefined;
var root: audio.Node = undefined;

// libsoundio glue
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
        const mono = context.tmp().alloc(audio.Sample, @intCast(frame_count)) catch unreachable;
        root.v.process(root.ptr, &context, mono);

        // Fan-out mono → all channels
        var f: c_int = 0;
        while (f < frame_count) : (f += 1) {
            const s = mono[@intCast(f)];
            var ch: usize = 0;
            while (ch < chans) : (ch += 1) {
                // libsoundio uses non-interleaved channel areas with a byte step per frame
                const step: usize = @intCast(areas[ch].step);
                const fi: usize = @intCast(f);
                const ptr = areas[ch].ptr + step * fi;
                const sample_ptr: *f32 = @ptrCast(@alignCast(ptr));
                sample_ptr.* = s;
            }
        }

        frames_left -= frame_count;
        must(c.soundio_outstream_end_write(maybe_outstream));
    }
}

pub fn main() !void {
    defer _ = gpa.deinit();

    // Build graph storage on heap (for Mixer inputs array)
    mixer = try audio.Mixer.init(A, &[_]*const audio.Node{ &nodeGA, &nodeGB, &nodeGC });
    defer {
        A.free(mixer.inputs);
        A.destroy(mixer);
    }
    var dist = audio.Distortion.init(&mixer.asNode(), 4.0, 1.0, .hard);
    root = dist.asNode();

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
    context = audio.Context.init(scratch_fba.allocator(), sr);

    must(c.soundio_outstream_start(out));

    // Pump events
    while (true) {
        c.soundio_wait_events(sio);
    }
}
