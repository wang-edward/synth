const std = @import("std");
const rl = @import("raylib");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");

// =============================================================================
// Double-buffered audio graph demo
//
// Architecture:
// - One unified graph containing ALL nodes (voices + master mixer)
// - StateStore holds all persistent state (osc phases, filter state, etc.)
// - UI thread modifies back buffer, then swaps atomically
// - Audio thread only reads the active graph
// - No params.zig - all changes go through graph rebuilds
// =============================================================================

const NUM_VOICES = 4;

// Per-voice node layout (6 nodes each):
//   0: pwm osc
//   1: saw osc
//   2: sub osc
//   3: osc mixer
//   4: lpf
//   5: adsr
// Then at the end: master mixer

const NODES_PER_VOICE = 6;
const TOTAL_NODES = NUM_VOICES * NODES_PER_VOICE + 1; // +1 for master mixer
const MASTER_MIXER_IDX = NUM_VOICES * NODES_PER_VOICE;

fn voiceNodeIdx(voice: usize, offset: u16) u16 {
    return @intCast(voice * NODES_PER_VOICE + offset);
}

// =============================================================================
// State store - persists across graph swaps
// =============================================================================

const StateStore = struct {
    voices: [NUM_VOICES]audio.VoiceState,
    // Track which note each voice is playing (for voice allocation)
    voice_notes: [NUM_VOICES]?u8,

    fn init() StateStore {
        return .{
            .voices = [_]audio.VoiceState{.{}} ** NUM_VOICES,
            .voice_notes = [_]?u8{null} ** NUM_VOICES,
        };
    }
};

var g_state: StateStore = StateStore.init();

// =============================================================================
// Synth params - modified by UI, applied via graph rebuild
// =============================================================================

const SynthParams = struct {
    cutoff: f32 = 5000.0,
    resonance: f32 = 0.5,
    attack: f32 = 0.01,
    decay: f32 = 0.1,
    sustain: f32 = 0.4,
    release: f32 = 0.6,
};

var g_params: SynthParams = .{};

// =============================================================================
// Graph building
// =============================================================================

// Storage for both graph buffers
var g_nodes_a: [TOTAL_NODES]audio.Node = undefined;
var g_nodes_b: [TOTAL_NODES]audio.Node = undefined;

// Mixer input/gain arrays (need stable memory)
var g_osc_mixer_inputs: [NUM_VOICES][3]u16 = undefined;
var g_osc_mixer_gains: [NUM_VOICES][3]f32 = undefined;
var g_master_inputs: [NUM_VOICES]u16 = undefined;
var g_master_gains: [NUM_VOICES]f32 = undefined;

fn buildGraph(nodes: []audio.Node, params: SynthParams) audio.Graph {
    // Build each voice
    for (0..NUM_VOICES) |v| {
        const vs = &g_state.voices[v];

        // Oscillators
        nodes[voiceNodeIdx(v, 0)] = .{ .osc = .{
            .freq = 440,
            .kind = .{ .pwm = .{} },
            .state = &vs.pwm,
        } };
        nodes[voiceNodeIdx(v, 1)] = .{ .osc = .{
            .freq = 440,
            .kind = .saw,
            .state = &vs.saw,
        } };
        nodes[voiceNodeIdx(v, 2)] = .{ .osc = .{
            .freq = 440,
            .kind = .{ .sub = .{} },
            .state = &vs.sub,
        } };

        // Osc mixer
        g_osc_mixer_inputs[v] = .{ voiceNodeIdx(v, 0), voiceNodeIdx(v, 1), voiceNodeIdx(v, 2) };
        g_osc_mixer_gains[v] = .{ 0.33, 0.33, 0.33 };
        nodes[voiceNodeIdx(v, 3)] = .{ .mixer = .{
            .inputs = &g_osc_mixer_inputs[v],
            .gains = &g_osc_mixer_gains[v],
        } };

        // LPF
        nodes[voiceNodeIdx(v, 4)] = .{ .lpf = .{
            .input = voiceNodeIdx(v, 3),
            .drive = 1.0,
            .resonance = params.resonance,
            .cutoff = params.cutoff,
            .state = &vs.lpf,
        } };

        // ADSR
        nodes[voiceNodeIdx(v, 5)] = .{ .adsr = .{
            .input = voiceNodeIdx(v, 4),
            .attack = params.attack,
            .decay = params.decay,
            .sustain = params.sustain,
            .release = params.release,
            .state = &vs.adsr,
        } };

        // Master mixer input
        g_master_inputs[v] = voiceNodeIdx(v, 5);
        g_master_gains[v] = 0.25;
    }

    // Master mixer
    nodes[MASTER_MIXER_IDX] = .{ .mixer = .{
        .inputs = &g_master_inputs,
        .gains = &g_master_gains,
    } };

    return .{ .nodes = nodes, .output = MASTER_MIXER_IDX };
}

// Set frequency for a voice in a graph
fn setVoiceFreq(nodes: []audio.Node, voice: usize, freq: f32) void {
    for (0..3) |osc_offset| {
        switch (nodes[voiceNodeIdx(voice, @intCast(osc_offset))]) {
            .osc => |*o| o.freq = freq,
            else => {},
        }
    }
}

// =============================================================================
// Double-buffered graph
// =============================================================================

var g_graph: audio.DoubleBufferedGraph = audio.DoubleBufferedGraph.init();

fn rebuildAndSwap() void {
    const back = g_graph.backIdx();
    const nodes = if (back == 0) &g_nodes_a else &g_nodes_b;
    const graph = buildGraph(nodes, g_params);

    // Copy current voice frequencies from active graph
    const active_nodes = g_graph.graphs[g_graph.activeIdx()].nodes;
    for (0..NUM_VOICES) |v| {
        if (g_state.voice_notes[v] != null) {
            // Get freq from active graph
            const freq = switch (active_nodes[voiceNodeIdx(v, 0)]) {
                .osc => |o| o.freq,
                else => 440.0,
            };
            setVoiceFreq(nodes, v, freq);
        }
    }

    g_graph.setGraph(back, graph);
    g_graph.swap();
}

// =============================================================================
// Voice allocation
// =============================================================================

fn findFreeVoice() ?usize {
    for (0..NUM_VOICES) |v| {
        if (g_state.voice_notes[v] == null and g_state.voices[v].adsr.isIdle()) {
            return v;
        }
    }
    return null;
}

var g_next_voice: usize = 0;

fn noteOn(note: u8) void {
    const voice = findFreeVoice() orelse blk: {
        const v = g_next_voice;
        g_next_voice = (g_next_voice + 1) % NUM_VOICES;
        break :blk v;
    };

    g_state.voice_notes[voice] = note;
    g_state.voices[voice].resetOscs();
    g_state.voices[voice].adsr.noteOn();

    // Update freq in active graph directly (timing critical)
    const freq = audio.noteToFreq(note);
    setVoiceFreq(g_graph.graphs[g_graph.activeIdx()].nodes, voice, freq);
    // Also update back buffer so next swap has correct freq
    setVoiceFreq(g_graph.graphs[g_graph.backIdx()].nodes, voice, freq);
}

fn noteOff(note: u8) void {
    for (0..NUM_VOICES) |v| {
        if (g_state.voice_notes[v] == note) {
            g_state.voice_notes[v] = null;
            g_state.voices[v].adsr.noteOff();
        }
    }
}

// =============================================================================
// Audio
// =============================================================================

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();

var scratch_mem: [512 * 1024]u8 = undefined;
var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
var context: audio.Context = undefined;

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
    const chans: usize = @intCast(outstream.layout.channel_count);

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
        g_graph.process(&context, mono);

        var f: c_int = 0;
        while (f < frame_count) : (f += 1) {
            const s = mono[@intCast(f)];
            for (0..chans) |ch| {
                const step: usize = @intCast(areas[ch].step);
                const ptr = areas[ch].ptr + step * @as(usize, @intCast(f));
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

// =============================================================================
// Main
// =============================================================================

fn keyToMidi(key: rl.KeyboardKey) ?u8 {
    return switch (key) {
        .a => 48, .w => 49, .s => 50, .e => 51, .d => 52,
        .f => 53, .t => 54, .g => 55, .y => 56, .h => 57,
        .u => 58, .j => 59, .k => 60, .o => 61, .l => 62,
        .p => 63, .semicolon => 64, .apostrophe => 65,
        else => null,
    };
}

pub fn main() !void {
    defer _ = gpa.deinit();

    // Build initial graphs (both buffers)
    g_graph.setGraph(0, buildGraph(&g_nodes_a, g_params));
    g_graph.setGraph(1, buildGraph(&g_nodes_b, g_params));

    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer {
        g_run_audio.store(false, .release);
        if (g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    rl.initWindow(640, 400, "Double-Buffered Audio Graph");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const note_keys = [_]rl.KeyboardKey{
        .a, .w, .s, .e, .d, .f, .t, .g, .y, .h, .u, .j,
        .k, .o, .l, .p, .semicolon, .apostrophe,
    };

    var key_state = std.AutoHashMap(rl.KeyboardKey, ?u8).init(A);
    defer key_state.deinit();
    for (note_keys) |k| try key_state.put(k, null);

    var offset: i8 = 0;

    while (!rl.windowShouldClose()) {
        // Keyboard -> MIDI
        for (note_keys) |key| {
            const down = rl.isKeyDown(key);
            const active = key_state.get(key).?;

            if (down and active == null) {
                if (keyToMidi(key)) |base| {
                    const note: u8 = @intCast(@as(i16, base) + offset);
                    noteOn(note);
                    try key_state.put(key, note);
                }
            } else if (!down and active != null) {
                noteOff(active.?);
                try key_state.put(key, null);
            }
        }

        // Param changes -> rebuild graph and swap
        var changed = false;
        if (rl.isKeyPressed(.up)) {
            g_params.cutoff = @min(g_params.cutoff * 1.2, 10000);
            changed = true;
        }
        if (rl.isKeyPressed(.down)) {
            g_params.cutoff = @max(g_params.cutoff * 0.8, 100);
            changed = true;
        }
        if (rl.isKeyPressed(.left)) {
            g_params.resonance = @max(g_params.resonance - 0.1, 0);
            changed = true;
        }
        if (rl.isKeyPressed(.right)) {
            g_params.resonance = @min(g_params.resonance + 0.1, 4);
            changed = true;
        }

        if (changed) {
            rebuildAndSwap();
        }

        if (rl.isKeyPressed(.z)) offset -= 12;
        if (rl.isKeyPressed(.x)) offset += 12;

        // Draw
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);

        rl.drawText("Double-Buffered Audio Graph", 20, 20, 24, .white);
        rl.drawText("----------------------------------", 20, 50, 16, .gray);

        var buf: [128]u8 = undefined;
        const cutoff_txt = std.fmt.bufPrintZ(&buf, "Cutoff: {d:.0} Hz", .{g_params.cutoff}) catch "?";
        rl.drawText(cutoff_txt, 20, 80, 20, .green);

        const res_txt = std.fmt.bufPrintZ(&buf, "Resonance: {d:.2}", .{g_params.resonance}) catch "?";
        rl.drawText(res_txt, 20, 110, 20, .green);

        const active_txt = std.fmt.bufPrintZ(&buf, "Active graph: {d}", .{g_graph.activeIdx()}) catch "?";
        rl.drawText(active_txt, 20, 140, 20, .yellow);

        rl.drawText("----------------------------------", 20, 180, 16, .gray);
        rl.drawText("A-L keys: play notes", 20, 210, 16, .gray);
        rl.drawText("UP/DOWN: cutoff", 20, 230, 16, .gray);
        rl.drawText("LEFT/RIGHT: resonance", 20, 250, 16, .gray);
        rl.drawText("Z/X: octave", 20, 270, 16, .gray);

        rl.drawText("Param changes rebuild & swap graph!", 20, 320, 14, .dark_gray);
    }
}
