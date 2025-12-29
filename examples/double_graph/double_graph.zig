const std = @import("std");
const rl = @import("raylib");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");

// =============================================================================
// Demo: Double-buffered audio graph with pointer-based nodes
//
// This demonstrates swapping between two different graph topologies while
// maintaining continuous oscillator phase and filter state. Press SPACE to
// swap between graphs. The phase continuity proves the state separation works.
// =============================================================================

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();

// Scratch allocator for audio callback
var scratch_mem: [256 * 1024]u8 = undefined;
var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
var context: audio.Context = undefined;

// Shared voice state - persists across graph swaps
var voice_state: audio.VoiceState = .{};

// Graph A nodes: osc -> lpf (low cutoff) -> [dist] -> adsr -> gain
var osc_a: audio.Osc = undefined;
var lpf_a: audio.Lpf = undefined;
var dist_a: audio.Distortion = undefined;
var adsr_a: audio.Adsr = undefined;
var gain_a: audio.Gain = undefined;

// Graph B nodes: osc -> lpf (high cutoff) -> [dist] -> adsr -> gain
var osc_b: audio.Osc = undefined;
var lpf_b: audio.Lpf = undefined;
var dist_b: audio.Distortion = undefined;
var adsr_b: audio.Adsr = undefined;
var gain_b: audio.Gain = undefined;

// Track if distortion has been added to each graph
var has_dist_a: bool = false;
var has_dist_b: bool = false;

// Double-buffered graph
var dbl_graph: audio.DoubleBufferedGraph = undefined;

// Control: which graph is shown (for UI display)
var g_active_label = std.atomic.Value(u8).init(0);

// Oscillator frequency control
var g_freq = std.atomic.Value(u32).init(440);

// Note on/off
var g_note_on = std.atomic.Value(bool).init(false);

// libsoundio
var sio: ?*c.SoundIo = null;
var out: ?*c.SoundIoOutStream = null;
var g_sio_ptr = std.atomic.Value(?*c.SoundIo).init(null);
var g_run_audio = std.atomic.Value(bool).init(true);

fn must(ok: c_int) void {
    if (ok != c.SoundIoErrorNone) @panic("soundio error");
}

fn write_callback(
    maybe_outstream: ?[*]c.SoundIoOutStream,
    _min: c_int,
    max: c_int,
) callconv(.c) void {
    if (!g_run_audio.load(.acquire)) return;
    _ = _min;
    const outstream: *c.SoundIoOutStream = &maybe_outstream.?[0];
    const layout = &outstream.layout;
    const chans: usize = @intCast(layout.channel_count);

    // Update frequency in both graphs' oscillators
    const freq: f32 = @floatFromInt(g_freq.load(.acquire));
    osc_a.freq = freq;
    osc_b.freq = freq;

    // Handle note on/off
    if (g_note_on.load(.acquire)) {
        if (voice_state.adsr.stage == .idle) {
            voice_state.adsr.noteOn();
        }
    } else {
        if (voice_state.adsr.stage != .idle and voice_state.adsr.stage != .release) {
            voice_state.adsr.noteOff();
        }
    }

    var frames_left = max;
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    context.arena = std.heap.ArenaAllocator.init(scratch_fba.allocator());

    while (frames_left > 0) {
        var frame_count = frames_left;
        var areas: [*]c.SoundIoChannelArea = undefined;
        must(c.soundio_outstream_begin_write(maybe_outstream, @ptrCast(&areas), &frame_count));
        if (frame_count == 0) break;

        context.beginBlock();
        const mono = context.tmp().alloc(audio.Sample, @intCast(frame_count)) catch unreachable;
        dbl_graph.process(&context, mono);

        var f: c_int = 0;
        while (f < frame_count) : (f += 1) {
            const s = mono[@intCast(f)] * 0.3; // master volume
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

fn underflow_callback(_: ?[*]c.SoundIoOutStream) callconv(.c) void {}

fn audioThreadMain() !void {
    const adsr_params: audio.Adsr.Params = .{ .attack = 0.01, .decay = 0.1, .sustain = 0.7, .release = 0.3 };

    // Build Graph A: osc -> lpf (low cutoff 800 Hz) -> adsr -> gain
    // "warm, filtered" sound
    osc_a = audio.Osc.init(440, .saw, &voice_state.osc1);
    lpf_a = audio.Lpf.init(osc_a.asNode(), 1.0, 2.0, 800, &voice_state.lpf);
    adsr_a = audio.Adsr.init(lpf_a.asNode(), adsr_params, &voice_state.adsr);
    gain_a = audio.Gain.init(adsr_a.asNode(), 1.0);

    // Build Graph B: osc -> lpf (high cutoff 4000 Hz) -> adsr -> gain
    // "bright, open" sound - same state, different cutoff
    osc_b = audio.Osc.init(440, .saw, &voice_state.osc1);
    lpf_b = audio.Lpf.init(osc_b.asNode(), 1.0, 2.0, 4000, &voice_state.lpf);
    adsr_b = audio.Adsr.init(lpf_b.asNode(), adsr_params, &voice_state.adsr);
    gain_b = audio.Gain.init(adsr_b.asNode(), 1.0);

    dbl_graph = audio.DoubleBufferedGraph.init(&voice_state);
    dbl_graph.setOutput(0, gain_a.asNode());
    dbl_graph.setOutput(1, gain_b.asNode());

    // SoundIO setup
    sio = c.soundio_create();
    if (sio == null) return error.NoMem;
    g_sio_ptr.store(sio, .release);
    defer {
        g_sio_ptr.store(null, .release);
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
    out.?.*.sample_rate = 48_000;
    out.?.*.software_latency = 0.02;
    must(c.soundio_outstream_open(out.?));

    const sr: f32 = @floatFromInt(out.?.*.sample_rate);
    context = audio.Context.init(scratch_fba.allocator(), sr);

    must(c.soundio_outstream_start(out.?));

    while (g_run_audio.load(.acquire)) {
        c.soundio_wait_events(sio);
    }
}

pub fn main() !void {
    defer _ = gpa.deinit();

    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer {
        g_run_audio.store(false, .release);
        if (g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    const w = 640;
    const h = 400;
    rl.initWindow(w, h, "Double-Buffered Audio Graph Demo");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        // SPACE: swap graphs
        if (rl.isKeyPressed(.space)) {
            dbl_graph.swap();
            const cur = g_active_label.load(.acquire);
            g_active_label.store(cur ^ 1, .release);
        }

        // D key: insert distortion into inactive graph, then swap
        if (rl.isKeyPressed(.d)) {
            const active = dbl_graph.active.load(.acquire);
            const inactive = active ^ 1;

            if (inactive == 0 and !has_dist_a) {
                // Rebuild graph A with distortion: osc -> lpf -> dist -> adsr -> gain
                dist_a = audio.Distortion.init(lpf_a.asNode(), 30.0, 0.7, .soft);
                adsr_a.input = dist_a.asNode();
                dbl_graph.setOutput(0, gain_a.asNode());
                has_dist_a = true;
            } else if (inactive == 1 and !has_dist_b) {
                // Rebuild graph B with distortion: osc -> lpf -> dist -> adsr -> gain
                dist_b = audio.Distortion.init(lpf_b.asNode(), 30.0, 0.7, .soft);
                adsr_b.input = dist_b.asNode();
                dbl_graph.setOutput(1, gain_b.asNode());
                has_dist_b = true;
            }

            // Swap to the newly modified graph
            dbl_graph.swap();
            const cur = g_active_label.load(.acquire);
            g_active_label.store(cur ^ 1, .release);
        }

        // A key: note on/off
        g_note_on.store(rl.isKeyDown(.a), .release);

        // UP/DOWN: frequency
        if (rl.isKeyPressed(.up)) {
            const f = g_freq.load(.acquire);
            g_freq.store(@min(f + 50, 2000), .release);
        }
        if (rl.isKeyPressed(.down)) {
            const f = g_freq.load(.acquire);
            g_freq.store(@max(f -| 50, 100), .release);
        }

        // Draw
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);

        rl.drawText("Double-Buffered Audio Graph Demo", 20, 20, 24, .white);
        rl.drawText("----------------------------------------", 20, 50, 16, .gray);

        const label = if (g_active_label.load(.acquire) == 0) "A (warm, low cutoff)" else "B (bright, high cutoff)";
        var buf: [64]u8 = undefined;
        const active_txt = std.fmt.bufPrintZ(&buf, "Active Graph: {s}", .{label}) catch "?";
        rl.drawText(active_txt, 20, 80, 20, .green);

        var buf2: [64]u8 = undefined;
        const freq_txt = std.fmt.bufPrintZ(&buf2, "Frequency: {d} Hz", .{g_freq.load(.acquire)}) catch "?";
        rl.drawText(freq_txt, 20, 110, 20, .yellow);

        const phase_txt = std.fmt.bufPrintZ(&buf, "Osc Phase: {d:.3}", .{voice_state.osc1.phase}) catch "?";
        rl.drawText(phase_txt, 20, 140, 20, .sky_blue);

        var buf3: [64]u8 = undefined;
        const env_txt = std.fmt.bufPrintZ(&buf3, "Envelope: {d:.2}", .{voice_state.adsr.value}) catch "?";
        rl.drawText(env_txt, 20, 170, 20, .sky_blue);

        const dist_status = if (g_active_label.load(.acquire) == 0)
            (if (has_dist_a) "YES" else "no")
        else
            (if (has_dist_b) "YES" else "no");
        var buf4: [64]u8 = undefined;
        const dist_txt = std.fmt.bufPrintZ(&buf4, "Distortion: {s}", .{dist_status}) catch "?";
        rl.drawText(dist_txt, 20, 200, 20, if ((g_active_label.load(.acquire) == 0 and has_dist_a) or (g_active_label.load(.acquire) == 1 and has_dist_b)) .orange else .gray);

        rl.drawText("----------------------------------------", 20, 230, 16, .gray);
        rl.drawText("Controls:", 20, 260, 18, .white);
        rl.drawText("  SPACE  - Swap graph (A <-> B)", 20, 285, 16, .gray);
        rl.drawText("  D key  - Add distortion to inactive, swap", 20, 305, 16, .gray);
        rl.drawText("  A key  - Hold to play note", 20, 325, 16, .gray);
        rl.drawText("  UP/DOWN - Change frequency", 20, 345, 16, .gray);
        rl.drawText("  ESC    - Quit", 20, 365, 16, .gray);
    }
}
