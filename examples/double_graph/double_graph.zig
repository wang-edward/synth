const std = @import("std");
const rl = @import("raylib");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");
const uni = @import("uni.zig");
const queue = @import("queue.zig");
const midi = @import("midi.zig");
const ops = @import("ops.zig");
const interface = @import("interface.zig");
const project = @import("project.zig");

// =============================================================================
// Global state
// =============================================================================
var g_note_queue: midi.NoteQueue = .{};
var g_playhead: u64 = 0;
var g_playing: bool = false;
var g_timeline: project.Timeline = undefined;
var g_op_queue: ops.OpQueue = .{};
var g_active_track: usize = 0;

inline fn getActiveTrack() *project.Track {
    return &g_timeline.tracks[g_active_track];
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();

// Scratch allocator for audio callback
var scratch_mem: [512 * 1024]u8 = undefined;
var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
var context: audio.Context = undefined;

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

    var frames_left = max;
    var midi_notes: [midi.MAX_NOTES_PER_BLOCK]midi.NoteMsg = undefined;

    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    context.arena = std.heap.ArenaAllocator.init(scratch_fba.allocator());

    while (frames_left > 0) {
        var frame_count = frames_left;

        var areas: [*]c.SoundIoChannelArea = undefined;
        must(c.soundio_outstream_begin_write(maybe_outstream, @ptrCast(&areas), &frame_count));
        if (frame_count == 0) break;

        // Process note queue
        while (g_note_queue.pop()) |msg| {
            switch (msg) {
                .Off => |note| getActiveTrack().synth.noteOff(note),
                .On => |note| getActiveTrack().synth.noteOn(note),
            }
        }

        // Process ops
        while (g_op_queue.pop()) |op| {
            switch (op) {
                .Playback => |p| switch (p) {
                    .TogglePlay => {
                        getActiveTrack().synth.allNotesOff();
                        g_playing = !g_playing;
                    },
                    .Reset => {
                        getActiveTrack().synth.allNotesOff();
                        g_playhead = 0;
                    },
                    .Seek => |frame| {
                        getActiveTrack().synth.allNotesOff();
                        g_playhead = frame;
                    },
                },
            }
        }

        // Render audio
        context.beginBlock();
        const mono = context.tmp().alloc(audio.Sample, @intCast(frame_count)) catch unreachable;
        g_timeline.process(&context, mono);

        // Copy to output channels
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

        // Advance playhead
        if (g_playing) {
            const start = g_playhead;
            g_playhead += @intCast(frame_count);

            for (g_timeline.tracks) |*track| {
                const n = track.player.advance(start, g_playhead, &midi_notes);
                for (midi_notes[0..n]) |msg| {
                    switch (msg) {
                        .Off => |note| track.synth.noteOff(note),
                        .On => |note| track.synth.noteOn(note),
                    }
                }
            }
        }

        frames_left -= frame_count;
        must(c.soundio_outstream_end_write(maybe_outstream));
    }
}

fn underflow_callback(_: ?[*]c.SoundIoOutStream) callconv(.c) void {}

// =============================================================================
// Audio thread
// =============================================================================
fn audioThreadMain() !void {
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

    // Build timeline
    const tempo: f32 = 120;
    const notes = [_]midi.Note{
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
    const bass_notes = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, sr), .end = midi.beatsToFrames(2.0, tempo, sr), .note = 48 },
        .{ .start = midi.beatsToFrames(2.0, tempo, sr), .end = midi.beatsToFrames(4.0, tempo, sr), .note = 48 },
        .{ .start = midi.beatsToFrames(4.0, tempo, sr), .end = midi.beatsToFrames(6.0, tempo, sr), .note = 43 },
        .{ .start = midi.beatsToFrames(6.0, tempo, sr), .end = midi.beatsToFrames(8.0, tempo, sr), .note = 43 },
        .{ .start = midi.beatsToFrames(8.0, tempo, sr), .end = midi.beatsToFrames(10.0, tempo, sr), .note = 41 },
        .{ .start = midi.beatsToFrames(10.0, tempo, sr), .end = midi.beatsToFrames(12.0, tempo, sr), .note = 40 },
        .{ .start = midi.beatsToFrames(12.0, tempo, sr), .end = midi.beatsToFrames(14.0, tempo, sr), .note = 38 },
        .{ .start = midi.beatsToFrames(14.0, tempo, sr), .end = midi.beatsToFrames(16.0, tempo, sr), .note = 36 },
    };
    const notes_per_track = [_][]const midi.Note{ &notes, &bass_notes };

    g_timeline = try project.Timeline.init(A, 2, 4, &notes_per_track);
    defer g_timeline.deinit(A);

    while (g_run_audio.load(.acquire)) {
        c.soundio_wait_events(sio);
    }
}

fn keyToMidi(key: rl.KeyboardKey) ?u8 {
    return switch (key) {
        .a => 48,
        .s => 50,
        .d => 52,
        .f => 53,
        .g => 55,
        .h => 57,
        .j => 59,
        .k => 60,
        .l => 62,
        .semicolon => 64,
        .apostrophe => 65,
        .w => 49,
        .e => 51,
        .t => 54,
        .y => 56,
        .u => 58,
        .o => 61,
        .p => 63,
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

    try interface.init();
    defer interface.deinit();

    const note_keys = [_]rl.KeyboardKey{
        .a, .w, .s, .e, .d,         .f,          .t, .g, .y, .h, .u, .j,
        .k, .o, .l, .p, .semicolon, .apostrophe,
    };

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
                    while (!g_note_queue.push(.{ .On = note })) {}
                    try key_state.put(key, note);
                }
            } else if (!down and active_note != null) {
                while (!g_note_queue.push(.{ .Off = active_note.? })) {}
                try key_state.put(key, null);
            }
        }

        if (rl.isKeyPressed(.up)) {
            const curr = getActiveTrack().synth.params.get(.cutoff);
            getActiveTrack().synth.params.set(.cutoff, curr * 1.1);
        }
        if (rl.isKeyPressed(.down)) {
            const curr = getActiveTrack().synth.params.get(.cutoff);
            getActiveTrack().synth.params.set(.cutoff, curr * 0.9);
        }

        if (rl.isKeyPressed(.x)) offset += 12;
        if (rl.isKeyPressed(.z)) offset -= 12;

        if (rl.isKeyPressed(.space)) {
            while (!g_op_queue.push(.{ .Playback = .TogglePlay })) {}
        }

        if (rl.isKeyPressed(.r)) {
            while (!g_op_queue.push(.{ .Playback = .Reset })) {}
        }

        interface.preRender();
        defer interface.postRender();
        g_timeline.render();
    }
}
