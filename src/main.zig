const std = @import("std");
const rl = @import("raylib");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");
const uni = @import("uni.zig");
const queue = @import("queue.zig");
const synth = @import("synth.zig");
const midi = @import("midi.zig");
const ops = @import("ops.zig");
const interface = @import("interface.zig");

const SharedParams = struct {
    drive: f32 = 1.0,
    resonance: f32 = 1.0,
    cutoff: f32 = 4000.0,
};

var g_params_slots: [2]SharedParams = .{ .{}, .{} }; // front/back
var g_params_idx = std.atomic.Value(u8).init(0); // index of *current* (front) slot
var g_note_queue: synth.NoteQueue = .{};
var g_playhead: u64 = 0;
var g_playing: bool = false;
var g_midi_player: midi.Player = undefined;
var g_op_queue: ops.OpQueue = .{};

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
var scratch_mem: [512 * 1024]u8 = undefined;
var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
var context: audio.Context = undefined;

// graph objects
var leSynth: *uni.Uni = undefined;
var root: audio.Node = undefined;

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
    const params = paramsReadSnapshot();
    leSynth.setLpfCutoff(params.cutoff);

    var frames_left = max;
    var midi_notes: [midi.MAX_NOTES_PER_BLOCK]synth.NoteMsg = undefined;

    // Rebuild the temp arena for this callback
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    context.arena = std.heap.ArenaAllocator.init(scratch_fba.allocator());

    while (frames_left > 0) {
        var frame_count = frames_left;

        var areas: [*]c.SoundIoChannelArea = undefined;
        must(c.soundio_outstream_begin_write(maybe_outstream, @ptrCast(&areas), &frame_count));
        if (frame_count == 0) break;

        // process note
        while (g_note_queue.pop()) |msg| {
            switch (msg) {
                .Off => |note| leSynth.noteOff(note),
                .On => |note| leSynth.noteOn(note),
            }
        }

        // process Ops
        while (g_op_queue.pop()) |op| {
            std.debug.print("op: {}\n", .{op});
            switch (op) {
                .Playback => |p| switch (p) {
                    .TogglePlay => {
                        leSynth.allNotesOff();
                        g_playing = !g_playing;
                    },
                    .Reset => {
                        leSynth.allNotesOff();
                        g_playhead = 0;
                    },
                    .Seek => |frame| {
                        leSynth.allNotesOff();
                        g_playhead = frame;
                    },
                },
            }
        }

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

        // advance playhead
        if (g_playing) {
            const start = g_playhead;
            g_playhead += @intCast(frame_count);

            const n = g_midi_player.advance(start, g_playhead, &midi_notes);
            for (midi_notes[0..n]) |msg| {
                switch (msg) {
                    .Off => |note| leSynth.noteOff(note),
                    .On => |note| leSynth.noteOn(note),
                }
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
    leSynth = try uni.Uni.init(A, 4);
    defer leSynth.deinit(A);

    root = leSynth.asNode();

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
    // TODO make sample rate setting better
    out.?.*.sample_rate = 48_000;
    out.?.*.software_latency = 0.02;
    must(c.soundio_outstream_open(out.?));

    // Init graph context with chosen sample rate
    const sr: f32 = @floatFromInt(out.?.*.sample_rate);
    const bpm: f32 = 120;
    context = audio.Context.init(scratch_fba.allocator(), sr, bpm);

    must(c.soundio_outstream_start(out.?));

    // lesynth setup
    const tempo: f32 = 120;
    const notes = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, &context), .end = midi.beatsToFrames(0.9, tempo, &context), .note = 60 },
        .{ .start = midi.beatsToFrames(1.0, tempo, &context), .end = midi.beatsToFrames(1.9, tempo, &context), .note = 60 },
        .{ .start = midi.beatsToFrames(2.0, tempo, &context), .end = midi.beatsToFrames(2.9, tempo, &context), .note = 67 },
        .{ .start = midi.beatsToFrames(3.0, tempo, &context), .end = midi.beatsToFrames(3.9, tempo, &context), .note = 67 },
        .{ .start = midi.beatsToFrames(4.0, tempo, &context), .end = midi.beatsToFrames(4.9, tempo, &context), .note = 69 },
        .{ .start = midi.beatsToFrames(5.0, tempo, &context), .end = midi.beatsToFrames(5.9, tempo, &context), .note = 69 },
        .{ .start = midi.beatsToFrames(6.0, tempo, &context), .end = midi.beatsToFrames(7.9, tempo, &context), .note = 67 },
        .{ .start = midi.beatsToFrames(8.0, tempo, &context), .end = midi.beatsToFrames(8.9, tempo, &context), .note = 65 },
        .{ .start = midi.beatsToFrames(9.0, tempo, &context), .end = midi.beatsToFrames(9.9, tempo, &context), .note = 65 },
        .{ .start = midi.beatsToFrames(10.0, tempo, &context), .end = midi.beatsToFrames(10.9, tempo, &context), .note = 64 },
        .{ .start = midi.beatsToFrames(11.0, tempo, &context), .end = midi.beatsToFrames(11.9, tempo, &context), .note = 64 },
        .{ .start = midi.beatsToFrames(12.0, tempo, &context), .end = midi.beatsToFrames(12.9, tempo, &context), .note = 62 },
        .{ .start = midi.beatsToFrames(13.0, tempo, &context), .end = midi.beatsToFrames(13.9, tempo, &context), .note = 62 },
        .{ .start = midi.beatsToFrames(14.0, tempo, &context), .end = midi.beatsToFrames(15.9, tempo, &context), .note = 60 },
    };

    g_midi_player = try midi.Player.init(A, &notes);
    defer g_midi_player.deinit(A);

    while (g_run_audio.load(.acquire)) {
        c.soundio_wait_events(sio);
    }
}

fn keyToMidi(key: rl.KeyboardKey) ?u8 {
    return switch (key) {
        // --- white keys (A–L) ---
        .a => 48, // C3
        .s => 50, // D3
        .d => 52, // E3
        .f => 53, // F3
        .g => 55, // G3
        .h => 57, // A3
        .j => 59, // B3
        .k => 60, // C4
        .l => 62, // D4
        .semicolon => 64, // E4
        .apostrophe => 65, // F4

        // --- black keys (W–O) ---
        .w => 49, // C#3
        .e => 51, // D#3
        .t => 54, // F#3
        .y => 56, // G#3
        .u => 58, // A#3
        .o => 61, // C#4
        .p => 63, // D#4
        else => null,
    };
}

pub fn main() !void {
    defer _ = gpa.deinit();

    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer {
        g_run_audio.store(false, .release);
        if (g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    try interface.init(A);
    defer interface.deinit(); // TODO pass A?
    const note_keys = [_]rl.KeyboardKey{
        .a, .w, .s, .e, .d,         .f,          .t, .g, .y, .h, .u, .j,
        .k, .o, .l, .p, .semicolon, .apostrophe,
    };

    var params = SharedParams{};
    paramsPublish(params);

    var offset: i8 = 0;
    var key_state = std.AutoHashMap(rl.KeyboardKey, ?u8).init(A);
    defer key_state.deinit();
    for (note_keys) |k| try key_state.put(k, null);

    while (!rl.windowShouldClose()) {
        for (note_keys) |key| {
            const down = rl.isKeyDown(key);
            const active_note = key_state.get(key).?;

            if (down and active_note == null) {
                if (keyToMidi(key)) |base| {
                    const note: u8 = @intCast(@as(i16, base) + @as(i16, offset));
                    while (!g_note_queue.push(.{ .On = note })) {} // TODO remove blocking?
                    try key_state.put(key, note);

                    std.debug.print("key pressed {}\n", .{key});
                }
            } else if (!down and active_note != null) {
                while (!g_note_queue.push(.{ .Off = active_note.? })) {} // TODO remove blocking?
                try key_state.put(key, null);

                std.debug.print("key released {}\n", .{key});
            }
        }

        if (rl.isKeyPressed(.up)) params.cutoff *= 1.1;
        if (rl.isKeyPressed(.down)) params.cutoff *= 0.9;
        params.cutoff = std.math.clamp(params.cutoff, 100.0, 5000.0);

        paramsPublish(params);

        if (rl.isKeyPressed(.x)) offset += 12;
        if (rl.isKeyPressed(.z)) offset -= 12;

        if (rl.isKeyPressed(.space)) {
            while (!g_op_queue.push(.{ .Playback = .TogglePlay })) {}
        }

        if (rl.isKeyPressed(.r)) {
            while (!g_op_queue.push(.{ .Playback = .Reset })) {}
        }

        // draw UI
        interface.preRender();
        defer interface.postRender();
        {
            rl.drawText("A-L: play notes", 2, 2, 10, .white);
            rl.drawText("Z/X: change octave", 2, 14, 10, .white);

            var buf: [160]u8 = undefined;
            const line = std.fmt.bufPrintZ(
                &buf,
                "cutoff: {d:.0}, offset: {d:.0}",
                .{ params.cutoff, @divTrunc(offset, 12) },
            ) catch "params";
            rl.drawText(line, 2, 26, 10, .white);
            rl.drawRectangleLines(0, 0, 128, 128, rl.Color.purple);
        }
    }
}
