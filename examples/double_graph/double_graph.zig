const std = @import("std");
const rl = @import("raylib");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");
const synth_mod = @import("synth.zig");
const midi = @import("midi.zig");
const ops = @import("ops.zig");
const project = @import("project.zig");

// =============================================================================
// Double-buffered audio graph with project structure
//
// Architecture:
// - Timeline contains multiple Tracks
// - Each Track has a Synth (voice states) and Player (note sequence)
// - One unified graph is built from the entire Timeline
// - Param changes rebuild the back graph and swap atomically
// =============================================================================

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();

// =============================================================================
// Project & Graph
// =============================================================================

var g_timeline: project.Timeline = undefined;

// Double-buffered nodes (sized dynamically)
var g_nodes_a: []audio.Node = undefined;
var g_nodes_b: []audio.Node = undefined;
var g_graph: audio.DoubleBufferedGraph = audio.DoubleBufferedGraph.init();

// Queues
var g_note_queue: midi.NoteQueue = .{};
var g_op_queue: ops.OpQueue = .{};

// Playback state
var g_playhead: u64 = 0;
var g_playing: bool = false;
var g_active_track: usize = 0;

fn rebuildAndSwap() void {
    const back = g_graph.backIdx();
    const nodes = if (back == 0) g_nodes_a else g_nodes_b;
    const active_nodes = g_graph.graphs[g_graph.activeIdx()].nodes;

    const graph = g_timeline.buildGraph(nodes);

    // Copy voice frequencies from active to new graph
    g_timeline.copyFreqs(active_nodes, nodes);

    g_graph.setGraph(back, graph);
    g_graph.swap();
}

// =============================================================================
// Audio
// =============================================================================

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
    var midi_notes: [midi.MAX_NOTES_PER_BLOCK]midi.NoteMsg = undefined;

    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    context.arena = std.heap.ArenaAllocator.init(scratch_fba.allocator());

    while (frames_left > 0) {
        var frame_count = frames_left;
        var areas: [*]c.SoundIoChannelArea = undefined;
        must(c.soundio_outstream_begin_write(maybe_outstream, @ptrCast(&areas), &frame_count));
        if (frame_count == 0) break;

        const active_nodes = g_graph.graphs[g_graph.activeIdx()].nodes;

        // Process note queue (keyboard input)
        while (g_note_queue.pop()) |msg| {
            const track = &g_timeline.tracks[g_active_track];
            const base_idx = g_timeline.trackBaseIdx(g_active_track);
            switch (msg) {
                .Off => |note| track.synth.noteOff(note),
                .On => |note| track.synth.noteOn(note, active_nodes, base_idx),
            }
        }

        // Process ops
        while (g_op_queue.pop()) |op| {
            switch (op) {
                .Playback => |p| switch (p) {
                    .TogglePlay => {
                        for (g_timeline.tracks) |*t| t.synth.allNotesOff();
                        g_playing = !g_playing;
                    },
                    .Reset => {
                        for (g_timeline.tracks) |*t| t.synth.allNotesOff();
                        g_playhead = 0;
                    },
                    .Seek => |frame| {
                        for (g_timeline.tracks) |*t| t.synth.allNotesOff();
                        g_playhead = frame;
                    },
                },
            }
        }

        // Render audio
        context.beginBlock();
        const mono = context.tmp().alloc(audio.Sample, @intCast(frame_count)) catch unreachable;
        g_graph.process(&context, mono);

        // Copy to output
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

        // Advance playhead & trigger sequenced notes
        if (g_playing) {
            const start = g_playhead;
            g_playhead += @intCast(frame_count);

            for (g_timeline.tracks, 0..) |*track, i| {
                const base_idx = g_timeline.trackBaseIdx(i);
                const n = track.player.advance(start, g_playhead, &midi_notes);
                for (midi_notes[0..n]) |msg| {
                    switch (msg) {
                        .Off => |note| track.synth.noteOff(note),
                        .On => |note| track.synth.noteOn(note, active_nodes, base_idx),
                    }
                }
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

    // Build project
    const sr: f32 = 48_000;
    const tempo: f32 = 120;

    const melody = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, sr), .end = midi.beatsToFrames(0.9, tempo, sr), .note = 60 },
        .{ .start = midi.beatsToFrames(1.0, tempo, sr), .end = midi.beatsToFrames(1.9, tempo, sr), .note = 60 },
        .{ .start = midi.beatsToFrames(2.0, tempo, sr), .end = midi.beatsToFrames(2.9, tempo, sr), .note = 67 },
        .{ .start = midi.beatsToFrames(3.0, tempo, sr), .end = midi.beatsToFrames(3.9, tempo, sr), .note = 67 },
        .{ .start = midi.beatsToFrames(4.0, tempo, sr), .end = midi.beatsToFrames(4.9, tempo, sr), .note = 69 },
        .{ .start = midi.beatsToFrames(5.0, tempo, sr), .end = midi.beatsToFrames(5.9, tempo, sr), .note = 69 },
        .{ .start = midi.beatsToFrames(6.0, tempo, sr), .end = midi.beatsToFrames(7.9, tempo, sr), .note = 67 },
        .{ .start = midi.beatsToFrames(8.0, tempo, sr), .end = midi.beatsToFrames(8.9, tempo, sr), .note = 65 },
        .{ .start = midi.beatsToFrames(9.0, tempo, sr), .end = midi.beatsToFrames(9.9, tempo, sr), .note = 65 },
        .{ .start = midi.beatsToFrames(10.0, tempo, sr), .end = midi.beatsToFrames(10.9, tempo, sr), .note = 64 },
        .{ .start = midi.beatsToFrames(11.0, tempo, sr), .end = midi.beatsToFrames(11.9, tempo, sr), .note = 64 },
        .{ .start = midi.beatsToFrames(12.0, tempo, sr), .end = midi.beatsToFrames(12.9, tempo, sr), .note = 62 },
        .{ .start = midi.beatsToFrames(13.0, tempo, sr), .end = midi.beatsToFrames(13.9, tempo, sr), .note = 62 },
        .{ .start = midi.beatsToFrames(14.0, tempo, sr), .end = midi.beatsToFrames(15.9, tempo, sr), .note = 60 },
    };

    const bass = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, sr), .end = midi.beatsToFrames(2.0, tempo, sr), .note = 48 },
        .{ .start = midi.beatsToFrames(2.0, tempo, sr), .end = midi.beatsToFrames(4.0, tempo, sr), .note = 48 },
        .{ .start = midi.beatsToFrames(4.0, tempo, sr), .end = midi.beatsToFrames(6.0, tempo, sr), .note = 43 },
        .{ .start = midi.beatsToFrames(6.0, tempo, sr), .end = midi.beatsToFrames(8.0, tempo, sr), .note = 43 },
        .{ .start = midi.beatsToFrames(8.0, tempo, sr), .end = midi.beatsToFrames(10.0, tempo, sr), .note = 41 },
        .{ .start = midi.beatsToFrames(10.0, tempo, sr), .end = midi.beatsToFrames(12.0, tempo, sr), .note = 40 },
        .{ .start = midi.beatsToFrames(12.0, tempo, sr), .end = midi.beatsToFrames(14.0, tempo, sr), .note = 38 },
        .{ .start = midi.beatsToFrames(14.0, tempo, sr), .end = midi.beatsToFrames(16.0, tempo, sr), .note = 36 },
    };

    const notes_per_track = [_][]const midi.Note{ &melody, &bass };
    g_timeline = try project.Timeline.init(A, 2, 4, &notes_per_track);
    defer g_timeline.deinit(A);

    // Allocate node buffers
    const node_count = g_timeline.nodeCount();
    g_nodes_a = try A.alloc(audio.Node, node_count);
    g_nodes_b = try A.alloc(audio.Node, node_count);
    defer A.free(g_nodes_a);
    defer A.free(g_nodes_b);

    // Build initial graphs
    g_graph.setGraph(0, g_timeline.buildGraph(g_nodes_a));
    g_graph.setGraph(1, g_timeline.buildGraph(g_nodes_b));

    // Start audio
    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer {
        g_run_audio.store(false, .release);
        if (g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    // UI
    rl.initWindow(640, 480, "Double-Buffered Audio Graph");
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
                    while (!g_note_queue.push(.{ .On = note })) {}
                    try key_state.put(key, note);
                }
            } else if (!down and active != null) {
                while (!g_note_queue.push(.{ .Off = active.? })) {}
                try key_state.put(key, null);
            }
        }

        // Param changes -> rebuild and swap
        var changed = false;
        const track = &g_timeline.tracks[g_active_track];

        if (rl.isKeyPressed(.up)) {
            track.params.cutoff = @min(track.params.cutoff * 1.2, 10000);
            changed = true;
        }
        if (rl.isKeyPressed(.down)) {
            track.params.cutoff = @max(track.params.cutoff * 0.8, 100);
            changed = true;
        }
        if (rl.isKeyPressed(.left)) {
            track.params.resonance = @max(track.params.resonance - 0.1, 0);
            changed = true;
        }
        if (rl.isKeyPressed(.right)) {
            track.params.resonance = @min(track.params.resonance + 0.1, 4);
            changed = true;
        }

        if (changed) rebuildAndSwap();

        // Other controls
        if (rl.isKeyPressed(.z)) offset -= 12;
        if (rl.isKeyPressed(.x)) offset += 12;
        if (rl.isKeyPressed(.space)) while (!g_op_queue.push(.{ .Playback = .TogglePlay })) {};
        if (rl.isKeyPressed(.r)) while (!g_op_queue.push(.{ .Playback = .Reset })) {};
        if (rl.isKeyPressed(.one)) g_active_track = 0;
        if (rl.isKeyPressed(.two)) g_active_track = 1;

        // Draw
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);

        rl.drawText("Double-Buffered Audio Graph", 20, 20, 24, .white);
        rl.drawText("----------------------------------", 20, 50, 16, .gray);

        var buf: [128]u8 = undefined;

        const track_txt = std.fmt.bufPrintZ(&buf, "Active Track: {d} (1/2 to switch)", .{g_active_track + 1}) catch "?";
        rl.drawText(track_txt, 20, 80, 18, .yellow);

        const cutoff_txt = std.fmt.bufPrintZ(&buf, "Cutoff: {d:.0} Hz", .{track.params.cutoff}) catch "?";
        rl.drawText(cutoff_txt, 20, 110, 18, .green);

        const res_txt = std.fmt.bufPrintZ(&buf, "Resonance: {d:.2}", .{track.params.resonance}) catch "?";
        rl.drawText(res_txt, 20, 135, 18, .green);

        const play_txt = if (g_playing) "Playing" else "Stopped";
        rl.drawText(play_txt, 20, 170, 18, if (g_playing) .lime else .red);

        const graph_txt = std.fmt.bufPrintZ(&buf, "Active graph: {d}  ({d} nodes)", .{ g_graph.activeIdx(), g_timeline.nodeCount() }) catch "?";
        rl.drawText(graph_txt, 20, 200, 16, .dark_gray);

        rl.drawText("----------------------------------", 20, 240, 16, .gray);
        rl.drawText("A-L: play notes   Z/X: octave", 20, 270, 16, .gray);
        rl.drawText("UP/DOWN: cutoff   LEFT/RIGHT: resonance", 20, 290, 16, .gray);
        rl.drawText("SPACE: play/stop  R: reset", 20, 310, 16, .gray);
        rl.drawText("1/2: switch track", 20, 330, 16, .gray);

        rl.drawText("Param changes rebuild & swap the entire graph!", 20, 380, 14, .dark_gray);
    }
}
