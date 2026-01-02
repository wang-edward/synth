const std = @import("std");
const uni = @import("uni.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
const interface = @import("interface.zig");
const rl = @import("raylib");

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

    pub fn addTrack(self: *Timeline) error{MaxTracksReached}!void {
        if (self.track_count >= MAX_TRACKS) return error.MaxTracksReached;
        self.tracks[self.track_count].clear();
        self.track_count += 1;
    }

    pub fn removeTrack(self: *Timeline, position: usize) void {
        if (position >= self.track_count) return;
        self.tracks[position].clear();
        // Rotate removed track to end via swaps
        for (position..self.track_count - 1) |i| {
            std.mem.swap(Track, &self.tracks[i], &self.tracks[i + 1]);
        }
        self.track_count -= 1;
    }
    pub fn render(self: *Timeline) void {
        _ = self;
        for (0..interface.WIDTH) |x| {
            for (0..interface.HEIGHT) |y| {
                if ((x + y) % 2 == 0) {
                    rl.drawPixel(@intCast(x), @intCast(y), rl.Color.red);
                }
            }
        }
    }
};

pub const PluginTag = enum { lpf, distortion, delay, gain };

pub const Plugin = union(PluginTag) {
    lpf: audio.Lpf,
    distortion: audio.Distortion,
    delay: audio.Delay,
    gain: audio.Gain,

    pub fn deinitState(self: Plugin, alloc: std.mem.Allocator) void {
        switch (self) {
            .lpf => |p| alloc.destroy(p.state),
            .delay => |p| p.state.deinit(alloc),
            .distortion, .gain => {},
        }
    }

    pub fn asNode(self: *Plugin) audio.Node {
        return switch (self.*) {
            .lpf => |*p| p.asNode(),
            .distortion => |*p| p.asNode(),
            .delay => |*p| p.asNode(),
            .gain => |*p| p.asNode(),
        };
    }

    pub fn setInput(self: *Plugin, input: audio.Node) void {
        switch (self.*) {
            .lpf => |*p| p.input = input,
            .distortion => |*p| p.input = input,
            .delay => |*p| p.input = input,
            .gain => |*p| p.input = input,
        }
    }

    pub fn getState(self: Plugin) ?*anyopaque {
        return switch (self) {
            .lpf => |p| @ptrCast(p.state),
            .delay => |p| @ptrCast(p.state),
            .distortion, .gain => null,
        };
    }
};

// chain is: input -> plugins[0] -> plugins[1] -> ... -> output
pub const PluginChain = struct {
    pub const MAX_PLUGINS = 8;

    input: audio.Node,
    plugins: [MAX_PLUGINS]Plugin,
    len: usize,

    pub fn init(input: audio.Node) PluginChain {
        return .{ .input = input, .plugins = undefined, .len = 0 };
    }

    pub fn output(self: *PluginChain) audio.Node {
        if (self.len > 0) return self.plugins[self.len - 1].asNode();
        return self.input;
    }

    pub fn append(self: *PluginChain, plugin: Plugin) void {
        std.debug.assert(self.len < MAX_PLUGINS);
        self.plugins[self.len] = plugin;
        self.plugins[self.len].setInput(self.prevOutput());
        self.len += 1;
    }

    pub fn remove(self: *PluginChain, idx: usize) void {
        if (idx >= self.len) return;
        for (idx..self.len - 1) |i| {
            self.plugins[i] = self.plugins[i + 1];
        }
        self.len -= 1;
        self.rewire();
    }

    fn prevOutput(self: *PluginChain) audio.Node {
        if (self.len > 0) return self.plugins[self.len - 1].asNode();
        return self.input;
    }

    fn rewire(self: *PluginChain) void {
        var prev = self.input;
        for (self.plugins[0..self.len]) |*p| {
            p.setInput(prev);
            prev = p.asNode();
        }
    }
};

pub const Track = struct {
    pub const MAX_PLUGINS = PluginChain.MAX_PLUGINS;

    synth: *uni.Uni,
    player: midi.Player,
    alloc: std.mem.Allocator,

    chains: [2]PluginChain,
    active: std.atomic.Value(u8),

    vt: audio.VTable = .{ .process = Track._process },

    pub fn init(alloc: std.mem.Allocator, voice_count: usize, notes_in: []const midi.Note) !Track {
        const synth = try uni.Uni.init(alloc, voice_count);
        const synth_node = synth.asNode();
        return .{
            .synth = synth,
            .player = try midi.Player.init(alloc, notes_in),
            .alloc = alloc,
            .chains = .{ PluginChain.init(synth_node), PluginChain.init(synth_node) },
            .active = std.atomic.Value(u8).init(0),
        };
    }

    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
        for (self.chains[0].plugins[0..self.chains[0].len]) |p| {
            p.deinitState(alloc);
        }
    }

    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Track = @ptrCast(@alignCast(p));
        const node = self.chains[self.active.load(.acquire)].output();
        node.v.process(node.ptr, ctx, out);
    }

    pub fn asNode(self: *Track) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }

    fn assertInvariant(self: *Track) void {
        std.debug.assert(self.chains[0].len == self.chains[1].len);
        for (self.chains[0].plugins[0..self.chains[0].len], self.chains[1].plugins[0..self.chains[1].len]) |p0, p1| {
            const tag0: PluginTag = p0;
            const tag1: PluginTag = p1;
            std.debug.assert(tag0 == tag1);
            std.debug.assert(p0.getState() == p1.getState());
        }
    }

    pub fn addPlugin(self: *Track, plugin: Plugin) void {
        self.assertInvariant();
        const active_idx = self.active.load(.acquire);
        const inactive_idx = active_idx ^ 1;

        // copy to inactive chain
        self.chains[inactive_idx].append(plugin);
        // swap
        self.active.store(inactive_idx, .release);
        // copy to other chain (same state pointer, different input wiring)
        self.chains[active_idx].append(plugin);

        self.assertInvariant();
    }

    pub fn removePlugin(self: *Track, idx: usize) void {
        self.assertInvariant();
        if (idx >= self.chains[0].len) return;

        const active_idx = self.active.load(.acquire);
        const inactive_idx = active_idx ^ 1;

        // grab plugin before removing (to free state later)
        const plugin = self.chains[0].plugins[idx];

        // remove from inactive, swap, remove from active
        self.chains[inactive_idx].remove(idx);
        self.active.store(inactive_idx, .release);
        self.chains[active_idx].remove(idx);

        // now safe to free state
        plugin.deinitState(self.alloc);

        self.assertInvariant();
    }

    pub fn hasPlugin(self: *Track, tag: PluginTag) bool {
        for (self.chains[0].plugins[0..self.chains[0].len]) |p| {
            if (p == tag) return true;
        }
        return false;
    }

    pub fn findPlugin(self: *Track, tag: PluginTag) ?usize {
        for (self.chains[0].plugins[0..self.chains[0].len], 0..) |p, i| {
            if (p == tag) return i;
        }
        return null;
    }

    pub fn removePluginByTag(self: *Track, tag: PluginTag) void {
        if (self.findPlugin(tag)) |idx| {
            self.removePlugin(idx);
        }
    }

    pub fn clear(self: *Track) void {
        self.player.clear();
        self.synth.allNotesOff();
        for (self.chains[0].plugins[0..self.chains[0].len]) |p| {
            p.deinitState(self.alloc);
        }
        self.chains[0].len = 0;
        self.chains[1].len = 0;
    }
};
