const std = @import("std");
const uni = @import("uni.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
const interface = @import("interface.zig");
const rl = @import("raylib");

pub const RenderCtx = struct {
    playhead_beat: f32,
    cursor_beat: f32,
    active_track: usize,
    viewport_left: f32,
    viewport_width: f32,
    scroll_offset: usize,
    mode_insert: bool,
    sr: f32,
    bpm: f32,
};

fn frameToBeat(frame: midi.Frame, sr: f32, bpm: f32) f32 {
    return @as(f32, @floatFromInt(frame)) * bpm / (sr * 60.0);
}

fn beatToPx(beat: f32, vp_left: f32, vp_width: f32) i32 {
    return @intFromFloat((beat - vp_left) / vp_width * 128.0);
}

pub fn renderPluginSelector(selected: usize) void {
    rl.drawText("Add Plugin", 1, 1, 10, rl.Color.white);
    const fields = @typeInfo(PluginTag).@"enum".fields;
    inline for (fields, 0..) |field, i| {
        const y: i32 = 16 + @as(i32, @intCast(i)) * 16;
        rl.drawText(field.name, 8, y, 10, if (i == selected) rl.Color.green else rl.Color.white);
    }
}

pub const Timeline = struct {
    pub const MAX_TRACKS = 8;

    alloc: std.mem.Allocator,
    tracks: [MAX_TRACKS]Track,
    track_count: usize,
    vt: audio.VTable = .{ .process = _process },

    pub fn init(
        alloc: std.mem.Allocator,
        num_tracks: usize,
        voices_per_track: usize,
        notes_per_track: []const []const midi.Note,
    ) !Timeline {
        std.debug.assert(num_tracks <= MAX_TRACKS);
        std.debug.assert(notes_per_track.len == num_tracks);

        var timeline: Timeline = .{
            .alloc = alloc,
            .tracks = undefined,
            .track_count = num_tracks,
        };

        // initialize active tracks with notes
        for (0..num_tracks) |i| {
            timeline.tracks[i] = try Track.init(alloc, voices_per_track, notes_per_track[i]);
        }
        // initialize remaining tracks with empty notes
        for (num_tracks..MAX_TRACKS) |i| {
            timeline.tracks[i] = try Track.init(alloc, voices_per_track, &.{});
        }

        return timeline;
    }

    pub fn deinit(self: *Timeline) void {
        for (&self.tracks) |*t| t.deinit(self.alloc);
    }

    pub fn asNode(self: *Timeline) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }

    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Timeline = @ptrCast(@alignCast(p));
        @memset(out, 0);
        for (self.tracks[0..self.track_count]) |*track| {
            const track_out = ctx.tmp().alloc(audio.Sample, out.len) catch unreachable;
            const node = track.asNode();
            node.v.process(node.ptr, ctx, track_out);
            for (out, track_out) |*o, t| o.* += t;
        }
    }

    pub fn render(self: *Timeline, ctx: RenderCtx) void {
        var buf: [32]u8 = undefined;
        // Header
        rl.drawText(if (ctx.mode_insert) "I" else "N", 1, 1, 10, if (ctx.mode_insert) rl.Color.magenta else rl.Color.white);
        const bt = std.fmt.bufPrintZ(&buf, "{d:.1}", .{ctx.cursor_beat}) catch unreachable;
        rl.drawText(bt, 40, 1, 10, rl.Color.white);
        var buf2: [8]u8 = undefined;
        const tt = std.fmt.bufPrintZ(&buf2, "T{}", .{ctx.active_track}) catch unreachable;
        rl.drawText(tt, 108, 1, 10, rl.Color.white);
        rl.drawLine(0, 12, 128, 12, rl.Color.dark_gray);
        // Track rows
        const row_h: i32 = 29;
        for (0..4) |i| {
            const idx = ctx.scroll_offset + i;
            if (idx >= self.track_count) break;
            const y: i32 = 12 + @as(i32, @intCast(i)) * row_h;
            self.tracks[idx].renderTimeline(y, row_h, ctx, idx);
        }
    }
};

pub const PluginTag = enum { lpf };

pub const Plugin = union(PluginTag) {
    lpf: audio.Lpf,

    pub fn deinitState(self: Plugin, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |p| {
                if (@hasField(@TypeOf(p), "state")) {
                    if (@hasDecl(@TypeOf(p.state.*), "deinit")) {
                        p.state.deinit(alloc);
                    } else {
                        alloc.destroy(p.state);
                    }
                }
            },
        }
    }

    pub fn asNode(self: *Plugin) audio.Node {
        switch (self.*) {
            inline else => |*p| return p.asNode(),
        }
    }

    pub fn setInput(self: *Plugin, input: audio.Node) void {
        switch (self.*) {
            inline else => |*p| {
                p.input = input;
            },
        }
    }
};

pub const Track = struct {
    pub const MAX_PLUGINS = 8;

    synth: *uni.Uni,
    player: midi.Player,
    alloc: std.mem.Allocator,

    plugins: [MAX_PLUGINS]Plugin,
    plugin_count: usize,

    vt: audio.VTable = .{ .process = Track._process },

    pub fn init(alloc: std.mem.Allocator, voice_count: usize, notes_in: []const midi.Note) !Track {
        return .{
            .synth = try uni.Uni.init(alloc, voice_count),
            .player = try midi.Player.init(alloc, notes_in),
            .alloc = alloc,
            .plugins = undefined,
            .plugin_count = 0,
        };
    }

    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
        for (self.plugins[0..self.plugin_count]) |p| {
            p.deinitState(alloc);
        }
    }

    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Track = @ptrCast(@alignCast(p));
        const node = self.output();
        node.v.process(node.ptr, ctx, out);
    }

    fn output(self: *Track) audio.Node {
        if (self.plugin_count > 0) return self.plugins[self.plugin_count - 1].asNode();
        return self.synth.asNode();
    }

    pub fn asNode(self: *Track) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }

    pub fn addPlugin(self: *Track, plugin: Plugin) void {
        std.debug.assert(self.plugin_count < MAX_PLUGINS);
        self.plugins[self.plugin_count] = plugin;
        const prev = if (self.plugin_count > 0)
            self.plugins[self.plugin_count - 1].asNode()
        else
            self.synth.asNode();
        self.plugins[self.plugin_count].setInput(prev);
        self.plugin_count += 1;
    }

    pub fn removePlugin(self: *Track, idx: usize) Plugin {
        const plugin = self.plugins[idx];
        for (idx..self.plugin_count - 1) |i| {
            self.plugins[i] = self.plugins[i + 1];
        }
        self.plugin_count -= 1;
        self.rewire();
        return plugin;
    }

    // for testing, TODO remove
    pub fn hasPlugin(self: *Track, tag: PluginTag) bool {
        for (self.plugins[0..self.plugin_count]) |p| {
            if (p == tag) return true;
        }
        return false;
    }

    // for testing, TODO remove
    pub fn findPlugin(self: *Track, tag: PluginTag) ?usize {
        for (self.plugins[0..self.plugin_count], 0..) |p, i| {
            if (p == tag) return i;
        }
        return null;
    }

    // for testing, TODO remove
    pub fn removePluginByTag(self: *Track, tag: PluginTag) ?Plugin {
        if (self.findPlugin(tag)) |idx| {
            return self.removePlugin(idx);
        }
        return null;
    }

    pub fn clear(self: *Track) void {
        self.player.clear();
        self.synth.allNotesOff();
        self.plugin_count = 0;
    }

    pub fn renderTimeline(self: *Track, y: i32, h: i32, ctx: RenderCtx, idx: usize) void {
        const active = idx == ctx.active_track;
        var buf: [4]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{}", .{idx}) catch unreachable;
        rl.drawText(label, 1, y + 8, 10, if (active) rl.Color.yellow else rl.Color.gray);
        if (active) rl.drawRectangleLines(0, y, 128, h, rl.Color.yellow);
        // Clips
        for (self.player.notes.items) |note| {
            const sb = frameToBeat(note.start, ctx.sr, ctx.bpm);
            const eb = frameToBeat(note.end, ctx.sr, ctx.bpm);
            const x0 = beatToPx(sb, ctx.viewport_left, ctx.viewport_width);
            const x1 = beatToPx(eb, ctx.viewport_left, ctx.viewport_width);
            if (x1 < 10 or x0 >= 128) continue;
            rl.drawRectangle(@max(x0, 10), y + 2, @max(x1 - @max(x0, 10), 1), h - 4, rl.Color.green);
        }
        // Playhead
        const ph = beatToPx(ctx.playhead_beat, ctx.viewport_left, ctx.viewport_width);
        if (ph >= 10 and ph < 128) rl.drawLine(ph, y, ph, y + h, rl.Color.white);
        // Cursor
        if (active) {
            const cx = beatToPx(ctx.cursor_beat, ctx.viewport_left, ctx.viewport_width);
            if (cx >= 10 and cx < 128) rl.drawRectangleLines(cx - 1, y, 3, h, rl.Color.orange);
        }
    }

    pub fn renderDetail(self: *Track, selected: usize, track_idx: usize) void {
        var buf: [16]u8 = undefined;
        const title = std.fmt.bufPrintZ(&buf, "Track {}", .{track_idx}) catch unreachable;
        rl.drawText(title, 1, 1, 10, rl.Color.white);
        for (0..8) |i| {
            const col: i32 = @intCast(i % 4);
            const row: i32 = @intCast(i / 4);
            const x = col * 32;
            const dy = 16 + row * 48;
            rl.drawRectangleLines(x, dy, 32, 48, if (i == selected) rl.Color.green else rl.Color.dark_gray);
            if (i < self.plugin_count) {
                rl.drawText(@tagName(self.plugins[i]), x + 2, dy + 18, 10, rl.Color.white);
            } else {
                rl.drawText("---", x + 8, dy + 18, 10, rl.Color.dark_gray);
            }
        }
        rl.drawText("[esc]back [a]add [x]del", 1, 116, 8, rl.Color.gray);
    }

    fn rewire(self: *Track) void {
        var prev = self.synth.asNode();
        for (self.plugins[0..self.plugin_count]) |*p| {
            p.setInput(prev);
            prev = p.asNode();
        }
    }
};
