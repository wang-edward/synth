const std = @import("std");
const rl = @import("raylib");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");
const synth = @import("synth.zig");

const SharedParams = struct {
    oscA_hz: f32 = 440.0,
    oscB_hz: f32 = 523.25,
    oscC_hz: f32 = 659.255,
    drive: f32 = 4.0,
    mix: f32 = 1.0,
    cutoff: f32 = 2000.0,
};

var g_params_slots: [2]SharedParams = .{ .{}, .{} }; // front/back
var g_params_idx = std.atomic.Value(u8).init(0); // index of *current* (front) slot

inline fn paramsReadSnapshot() SharedParams {
    // Audio thread: acquire to see a consistent published slot
    const i = g_params_idx.load(.acquire);
    return g_params_slots[i]; // copy to a local snapshot (small POD copy)
}

inline fn paramsPublish(newp: SharedParams) void {
    const r = g_params_idx.load(.acquire);
    const w = r ^ 1; // back slot
    g_params_slots[w] = newp; // copy the whole struct
    g_params_idx.store(w, .release);
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();

// Scratch allocator for audio callback (no sys allocs in callback)
var scratch_mem: [64 * 1024]u8 = undefined;
var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
var context: audio.Context = undefined;

// graph objects
var oscA = audio.Osc.init(440, .{ .sine = .{} });
var oscB = audio.Osc.init(523.25, .{ .pwm = .{} });
var oscC = audio.Osc.init(659.255, .{ .saw = .{} });
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
var dist: audio.Distortion = undefined;
var hpf: audio.Lpf = undefined;

// libsoundio state (used only on audio thread)
var sio: ?*c.SoundIo = null;
var out: ?*c.SoundIoOutStream = null;

// shared sio pointer to allow main to kill sio
var g_sio_ptr = std.atomic.Value(?*c.SoundIo).init(null);

// Run flag for audio thread
var g_run_audio = std.atomic.Value(bool).init(true);

fn must(ok: c_int) void {
    if (ok != c.SoundIoErrorNone) @panic("soundio error");
}

fn write_callback(
    maybe_outstream: ?[*]c.SoundIoOutStream,
    _min: c_int,
    max: c_int,
) callconv(.c) void {
    // exit early if program ended
    if (!g_run_audio.load(.acquire)) return;

    _ = _min;
    const outstream: *c.SoundIoOutStream = &maybe_outstream.?[0];
    const layout = &outstream.layout;
    const chans: usize = @intCast(layout.channel_count);

    // Snapshot params once per callback
    const p = paramsReadSnapshot();

    // Apply to graph up-front (no atomics in hot loop)
    oscA.freq = p.oscA_hz;
    oscB.freq = p.oscB_hz;
    oscC.freq = p.oscC_hz;
    dist.drive = p.drive;
    dist.mix = p.mix;
    hpf.cutoff = p.cutoff;

    var frames_left = max;

    // Rebuild the temp arena for this callback
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    context.arena = std.heap.ArenaAllocator.init(scratch_fba.allocator());

    while (frames_left > 0) {
        var frame_count = frames_left;

        var areas: [*]c.SoundIoChannelArea = undefined;
        must(c.soundio_outstream_begin_write(maybe_outstream, @ptrCast(&areas), &frame_count));
        if (frame_count == 0) break;

        // Render one block (mono) from the graph
        context.beginBlock();
        const mono = context.tmp().alloc(audio.Sample, @intCast(frame_count)) catch unreachable;
        root.v.process(root.ptr, &context, mono);

        // Fan-out mono -> all channels (non-interleaved areas)
        var f: c_int = 0;
        while (f < frame_count) : (f += 1) {
            const s = mono[@intCast(f)];
            var ch: usize = 0;
            while (ch < chans) : (ch += 1) {
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

fn underflow_callback(_: ?[*]c.SoundIoOutStream) callconv(.c) void {
    // avoid I/O here in production; okay to leave empty
}

// =============================== Audio thread entry ==================================
fn audioThreadMain() !void {
    // Build graph heap storage (Mixer inputs array)
    mixer = try audio.Mixer.init(A, &[_]*const audio.Node{ &nodeGA, &nodeGB, &nodeGC });
    defer A.free(mixer.inputs);
    defer A.destroy(mixer);
    // dist = audio.Distortion.init(&mixer.asNode(), 4.0, 1.0, .hard);
    hpf = audio.Lpf.init(
        &mixer.asNode(),
        1.0,
        1.0,
        1_000,
    );
    root = hpf.asNode();

    // SoundIO setup
    sio = c.soundio_create();
    if (sio == null) return error.NoMem;
    g_sio_ptr.store(sio, .release);
    defer {
        g_sio_ptr.store(null, .release); // clear
        if (sio) |p| c.soundio_destroy(p);
        sio = null;
    }
    must(c.soundio_connect(sio));
    c.soundio_flush_events(sio);
    const idx = c.soundio_default_output_device_index(sio);
    if (idx < 0) return error.NoOutputDeviceFound;
    const dev = c.soundio_get_output_device(sio, idx) orelse return error.NoMem;
    defer c.soundio_device_unref(dev);
    out = c.soundio_outstream_create(dev) orelse return error.NoMem;
    defer {
        if (out) |p| c.soundio_outstream_destroy(p);
        out = null;
    }
    out.?.*.format = c.SoundIoFormatFloat32NE;
    out.?.*.write_callback = write_callback;
    out.?.*.underflow_callback = underflow_callback;
    // optional explicit rate
    // out.?.*.sample_rate = 48000;
    must(c.soundio_outstream_open(out.?));

    // Init graph context with chosen sample rate
    const sr: f32 = @floatFromInt(out.?.*.sample_rate);
    context = audio.Context.init(scratch_fba.allocator(), sr);

    must(c.soundio_outstream_start(out.?));

    // Pump events (stays on audio thread)
    while (g_run_audio.load(.acquire)) {
        c.soundio_wait_events(sio);
    }
}

// main (raylib on UI thread)
fn clampF(v: f32, lo: f32, hi: f32) f32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

pub fn main() !void {
    defer _ = gpa.deinit();

    // start audio thread first
    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer {
        g_run_audio.store(false, .release);
        // wake audio thread out of soundio_wait_events
        if (g_sio_ptr.load(.acquire)) |p| {
            c.soundio_wakeup(p);
        }
        audio_thread.join();
    }

    // raylib window on the main thread
    const screenWidth = 800;
    const screenHeight = 450;
    rl.initWindow(screenWidth, screenHeight, "raylib + libsoundio (ping-pong params)");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var x: i32 = 200;
    var y: i32 = 200;

    while (!rl.windowShouldClose()) {
        // move a circle (just to have some UI activity)
        if (rl.isKeyDown(.right)) x += 5;
        if (rl.isKeyDown(.left)) x -= 5;
        if (rl.isKeyDown(.up)) y -= 5;
        if (rl.isKeyDown(.down)) y += 5;

        // read current slot (optional; for displaying current values)
        const cur = g_params_slots[g_params_idx.load(.acquire)];

        var a = cur.oscA_hz;
        var d = cur.drive;
        var m = cur.mix;
        var cut = cur.cutoff;

        // controls: A/Z = freqA +/- ; S/X = drive +/- ; D/C = mix +/-
        if (rl.isKeyPressed(.a)) a += 10.0;
        if (rl.isKeyPressed(.z)) a -= 10.0;
        if (rl.isKeyPressed(.s)) d += 0.25;
        if (rl.isKeyPressed(.x)) d -= 0.25;
        if (rl.isKeyPressed(.d)) m += 0.05;
        if (rl.isKeyPressed(.c)) m -= 0.05;
        if (rl.isKeyPressed(.q)) cut -= 200.0;
        if (rl.isKeyPressed(.w)) cut += 200.0;

        a = clampF(a, 50.0, 2000.0);
        d = clampF(d, 1.0, 10.0);
        m = clampF(m, 0.0, 1.0);
        cut = clampF(cut, 100.0, 10000.0);

        // read current (front) to start from existing values
        var next = g_params_slots[g_params_idx.load(.acquire)];

        // tweak fields from UI
        next.oscA_hz = a;
        next.drive = d;
        next.mix = m;
        next.cutoff = cut;

        // publish to back, then flip
        paramsPublish(next);

        // Draw
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
        rl.drawCircle(x, y, 60, .white);

        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrintZ(
            &buf,
            "A/Z freqA: {d:.1}  S/X drive: {d:.2}  D/C mix: {d:.2}  Q/W cutoff: {d:.0}",
            .{ a, d, m, cut },
        ) catch "params";
        rl.drawText(line, 20, 20, 20, .light_gray);
        rl.drawText("Audio on dedicated thread; params via double buffer + atomic index.", 20, 50, 18, .gray);
    }
}
