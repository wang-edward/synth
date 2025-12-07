const std = @import("std");
const rl = @import("raylib");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");
const uni = @import("uni.zig");
const seq = @import("sequencer.zig");
const queue = @import("queue.zig");
const synth = @import("synth.zig");

const SharedParams = struct {
    drive: f32 = 1.0,
    resonance: f32 = 1.0,
    cutoff: f32 = 4000.0,
};

var g_params_slots: [2]SharedParams = .{ .{}, .{} }; // front/back
var g_params_idx = std.atomic.Value(u8).init(0); // index of *current* (front) slot
var g_note_queue: queue.SpscQueue(synth.NoteMsg, 16) = .{};
var g_samples_processed: std.atomic.Value(u64) = .init(0);
var g_seq: seq.Sequencer = undefined;

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
    const p = paramsReadSnapshot();
    leSynth.setLpfCutoff(p.cutoff);

    var frames_left = max;

    // Rebuild the temp arena for this callback
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    context.arena = std.heap.ArenaAllocator.init(scratch_fba.allocator());

    while (frames_left > 0) {
        var frame_count = frames_left;

        var areas: [*]c.SoundIoChannelArea = undefined;
        must(c.soundio_outstream_begin_write(maybe_outstream, @ptrCast(&areas), &frame_count));
        if (frame_count == 0) break;

        while (true) {
            const msg = g_note_queue.pop() orelse break;
            switch (msg) {
                .Off => |note| {
                    leSynth.noteOff(note);
                },
                .On => |note| {
                    leSynth.noteOn(note);
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

        _ = g_samples_processed.fetchAdd(@intCast(frame_count), .release);

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

    leSynth = try uni.Uni.init(A, 4);
    defer leSynth.deinit(A);
    var delay = try audio.Delay.init(A, leSynth.asNode(), 0.5 * 48_000);
    defer delay.deinit(A);

    root = delay.asNode();

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

    // Pump events (stays on audio thread)
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

    const w = 720;
    const h = 480;
    rl.initWindow(w, h, "leSynth");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    const note_keys = [_]rl.KeyboardKey{
        .a, .w, .s, .e, .d,         .f,          .t, .g, .y, .h, .u, .j,
        .k, .o, .l, .p, .semicolon, .apostrophe,
    };

    var params = SharedParams{};
    paramsPublish(params);

    const pat = [_]seq.Step{
        .{ .Note = 58 }, // bf3
        .{ .Note = 39 }, // ef2
        .{ .Note = 70 }, // bf4
        .{ .Note = 51 }, // ef3
        .{ .Note = 49 }, // df3
        .{ .Note = 58 }, // bf3
        .{ .Note = 39 }, // ef2
        .{ .Note = 61 }, // df4
        .{ .Note = 51 }, // ef3
        .{ .Note = 58 }, // bf3
        .{ .Note = 61 }, // df4
        .{ .Note = 70 }, // bf4
        .{ .Note = 70 }, // bf4
        .{ .Note = 51 }, // ef3
        .{ .Note = 51 }, // ef3
        .{ .Note = 58 }, // bf3
        .{ .Note = 59 }, // cf3
        .{ .Note = 51 }, // ef3
        .{ .Note = 71 }, // cf4
        .{ .Note = 59 }, // cf3
        .{ .Note = 54 }, // gf3
        .{ .Note = 71 }, // cf4
        .{ .Note = 59 }, // cf3
        .{ .Note = 66 }, // gf4
        .{ .Note = 71 }, // cf4
        .{ .Note = 71 }, // cf4
        .{ .Note = 66 }, // gf4
        .{ .Note = 71 }, // cf4
        .{ .Note = 71 }, // cf4
        .{ .Note = 59 }, // cf3
        .{ .Note = 51 }, // ef3
        .{ .Note = 59 }, // cf3
        .{ .Note = 59 }, // cf3
        .{ .Note = 51 }, // ef3
        .{ .Note = 71 }, // cf4
        .{ .Note = 59 }, // cf3
        .{ .Note = 51 }, // ef3
        .{ .Note = 59 }, // cf3
        .{ .Note = 56 }, // af3
        .{ .Note = 63 }, // ef4
        .{ .Note = 71 }, // cf4
        .{ .Note = 59 }, // cf3
        .{ .Note = 63 }, // ef4
        .{ .Note = 71 }, // cf4
        .{ .Note = 71 }, // cf4
        .{ .Note = 56 }, // af3
        .{ .Note = 49 }, // df3
        .{ .Note = 59 }, // cf3
        .{ .Note = 58 }, // bf3
        .{ .Note = 49 }, // df3
        .{ .Note = 70 }, // bf4
        .{ .Note = 58 }, // bf3
        .{ .Note = 49 }, // df3
        .{ .Note = 58 }, // bf3
        .{ .Note = 58 }, // bf3
        .{ .Note = 61 }, // df4
        .{ .Note = 49 }, // df3
        .{ .Note = 58 }, // bf3
        .{ .Note = 61 }, // df4
        .{ .Note = 70 }, // bf4
        .{ .Note = 70 }, // bf4
        .{ .Note = 58 }, // bf3
        .{ .Note = 54 }, // gf3
        .{ .Note = 58 }, // bf3
    };

    g_seq = try seq.Sequencer.init(A, pat[0..]);
    defer g_seq.deinit(A);
    var seq_ctx = audio.Context.init(A, 48_000, 420); // TODO just have 2 floats for sr and bpm?

    var offset: i8 = 0;
    var key_state = std.AutoHashMap(rl.KeyboardKey, ?u8).init(A);
    defer key_state.deinit();
    for (note_keys) |k| try key_state.put(k, null);

    var last_samples_seen: u64 = 0;

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

        const total = g_samples_processed.load(.acquire);
        if (total < last_samples_seen) unreachable;
        const delta = total - last_samples_seen;
        last_samples_seen = total;
        g_seq.advance(&seq_ctx, delta, &g_note_queue);

        if (rl.isKeyPressed(.up)) params.cutoff *= 1.1;
        if (rl.isKeyPressed(.down)) params.cutoff *= 0.9;
        params.cutoff = std.math.clamp(params.cutoff, 100.0, 5000.0);

        paramsPublish(params);

        if (rl.isKeyPressed(.x)) offset += 12;
        if (rl.isKeyPressed(.z)) offset -= 12;

        // draw UI
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
        rl.drawText("Press A-L keys to play notes (W, E, etc. for sharp/flat)", 20, 20, 20, .white);
        rl.drawText("Z/X to change octave", 20, 40, 20, .white);

        rl.drawText("Press ESC to quit", 20, 440, 20, .gray);
        rl.drawText("Up / Down to change filter cutoff", 20, 70, 20, .white);
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrintZ(
            &buf,
            "cutoff: {d:.0}, offset: {d:.0}",
            .{ params.cutoff, @divTrunc(offset, 12) },
        ) catch "params";
        rl.drawText(line, 360, 240, 20, .white);
    }
}
