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

        // Initialize active tracks with notes
        for (0..num_tracks) |i| {
            timeline.tracks[i] = try Track.init(alloc, voices_per_track, notes_per_track[i]);
        }
        // Initialize remaining tracks with empty notes
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

/// Plugin state owned by Track, persists across graph swaps
pub const PluginState = union(PluginTag) {
    lpf: audio.Lpf.State,
    distortion: void,
    delay: *audio.Delay.State,
    gain: void,

    pub fn init(alloc: std.mem.Allocator, tag: PluginTag) !PluginState {
        return switch (tag) {
            .lpf => .{ .lpf = .{} },
            .distortion => .{ .distortion = {} },
            .delay => .{ .delay = try audio.Delay.State.init(alloc, 48_000 * 2) },
            .gain => .{ .gain = {} },
        };
    }

    pub fn deinit(self: PluginState, alloc: std.mem.Allocator) void {
        switch (self) {
            .delay => |s| s.deinit(alloc),
            else => {},
        }
    }
};

/// Plugin node in chain (just topology, no state)
pub const Plugin = union(PluginTag) {
    lpf: *audio.Lpf,
    distortion: *audio.Distortion,
    delay: *audio.Delay,
    gain: *audio.Gain,

    pub fn deinit(self: Plugin, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |p| alloc.destroy(p),
        }
    }
    pub fn asNode(self: Plugin) audio.Node {
        return switch (self) {
            inline else => |p| p.asNode(),
        };
    }
    pub fn setInput(self: Plugin, input: audio.Node) void {
        switch (self) {
            inline else => |p| p.input = input,
        }
    }
};

// chain is: input -> plugins[0] -> plugins[1] -> ... -> output
pub const PluginChain = struct {
    pub const MAX_PLUGINS = 8;

    alloc: std.mem.Allocator,
    input: audio.Node,
    plugins: [MAX_PLUGINS]Plugin,
    len: usize,

    pub fn init(alloc: std.mem.Allocator, input: audio.Node) PluginChain {
        return .{
            .alloc = alloc,
            .input = input,
            .plugins = undefined,
            .len = 0,
        };
    }
    pub fn deinit(self: *PluginChain) void {
        for (self.plugins[0..self.len]) |p| {
            p.deinit(self.alloc);
        }
    }
    pub fn output(self: *const PluginChain) audio.Node {
        if (self.len > 0) {
            return self.plugins[self.len - 1].asNode();
        }
        return self.input;
    }
    pub fn append(self: *PluginChain, plugin: Plugin) void {
        std.debug.assert(self.len < MAX_PLUGINS);
        var p = plugin;
        p.setInput(self.output());
        self.plugins[self.len] = p;
        self.len += 1;
    }
    pub fn pop(self: *PluginChain) void {
        if (self.len > 0) {
            self.plugins[self.len - 1].deinit(self.alloc);
            self.len -= 1;
        }
    }
    pub fn clear(self: *PluginChain) void {
        for (self.plugins[0..self.len]) |p| {
            p.deinit(self.alloc);
        }
        self.len = 0;
    }

};

pub const Track = struct {
    pub const MAX_PLUGINS = PluginChain.MAX_PLUGINS;

    synth: *uni.Uni,
    player: midi.Player,
    alloc: std.mem.Allocator,

    // source of truth: which plugins are enabled + their state
    plugin_states: [MAX_PLUGINS]?PluginState,
    plugin_count: usize,

    // double-buffered plugin chains (derived from plugin_states)
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
            .plugin_states = .{null} ** MAX_PLUGINS,
            .plugin_count = 0,
            .chains = .{ PluginChain.init(alloc, synth_node), PluginChain.init(alloc, synth_node) },
            .active = std.atomic.Value(u8).init(0),
        };
    }

    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
        self.chains[0].deinit();
        self.chains[1].deinit();
        for (self.plugin_states[0..self.plugin_count]) |*ps| {
            if (ps.*) |s| s.deinit(alloc);
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

    fn findState(self: *Track, tag: PluginTag) ?usize {
        for (self.plugin_states[0..self.plugin_count], 0..) |ps, i| {
            if (ps != null and ps.? == tag) return i;
        }
        return null;
    }

    fn rebuildChain(self: *Track, chain: *PluginChain) !void {
        chain.clear();
        for (self.plugin_states[0..self.plugin_count]) |*ps| {
            if (ps.*) |*state| {
                const plugin = try self.createNode(state, chain.output());
                chain.append(plugin);
            }
        }
    }

    fn createNode(self: *Track, state: *PluginState, input: audio.Node) !Plugin {
        return switch (state.*) {
            .lpf => |*s| blk: {
                const n = try self.alloc.create(audio.Lpf);
                n.* = audio.Lpf.init(input, 1.0, 2.0, 2000.0, s);
                break :blk .{ .lpf = n };
            },
            .distortion => blk: {
                const n = try self.alloc.create(audio.Distortion);
                n.* = audio.Distortion.init(input, 8.0, 0.7, .soft);
                break :blk .{ .distortion = n };
            },
            .delay => |s| blk: {
                const n = try self.alloc.create(audio.Delay);
                n.* = audio.Delay.init(input, 0.25, 0.4, 0.3, s);
                break :blk .{ .delay = n };
            },
            .gain => blk: {
                const n = try self.alloc.create(audio.Gain);
                n.* = audio.Gain.init(input, 1.0);
                break :blk .{ .gain = n };
            },
        };
    }

    pub fn togglePlugin(self: *Track, tag: PluginTag) !void {
        const active_idx = self.active.load(.acquire);
        const inactive_idx = active_idx ^ 1;

        if (self.findState(tag)) |idx| {
            // remove: rebuild inactive, swap, rebuild other, free state
            self.plugin_states[idx].?.deinit(self.alloc);
            self.plugin_states[idx] = null;
            // compact
            for (idx..self.plugin_count - 1) |i| self.plugin_states[i] = self.plugin_states[i + 1];
            self.plugin_states[self.plugin_count - 1] = null;
            self.plugin_count -= 1;
        } else {
            // add: create state
            self.plugin_states[self.plugin_count] = try PluginState.init(self.alloc, tag);
            self.plugin_count += 1;
        }
        try self.rebuildChain(&self.chains[inactive_idx]);
        self.active.store(inactive_idx, .release);
        try self.rebuildChain(&self.chains[active_idx]);
    }

    pub fn hasPlugin(self: *Track, tag: PluginTag) bool {
        return self.findState(tag) != null;
    }

    pub fn clear(self: *Track) void {
        self.player.clear();
        self.synth.allNotesOff();
        self.chains[0].clear();
        self.chains[1].clear();
        for (self.plugin_states[0..self.plugin_count]) |*ps| {
            if (ps.*) |s| s.deinit(self.alloc);
            ps.* = null;
        }
        self.plugin_count = 0;
    }
};
