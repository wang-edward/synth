const std = @import("std");
const uni = @import("uni.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
const interface = @import("interface.zig");
const rl = @import("raylib");

pub const Timeline = struct {
    tracks: []Track,
    mixer: *audio.Mixer,

    pub fn init(
        alloc: std.mem.Allocator,
        num_tracks: usize,
        voices_per_track: usize,
        notes_per_track: []const []const midi.Note,
    ) !Timeline {
        std.debug.assert(notes_per_track.len == num_tracks);
        const tracks = try alloc.alloc(Track, num_tracks);
        for (tracks, 0..) |*t, i| {
            t.* = try Track.init(
                alloc,
                voices_per_track,
                notes_per_track[i],
            );
        }
        var nodes = try alloc.alloc(audio.Node, num_tracks);
        defer alloc.free(nodes);
        for (tracks, 0..) |*t, i| {
            nodes[i] = t.asNode();
        }
        const mixer = try audio.Mixer.init(alloc, nodes);
        return .{
            .tracks = tracks,
            .mixer = mixer,
        };
    }
    pub fn deinit(self: *Timeline, alloc: std.mem.Allocator) void {
        for (self.tracks) |*t| t.deinit(alloc);
        alloc.free(self.tracks);
        self.mixer.deinit(alloc);
        alloc.destroy(self.mixer);
    }
    pub fn asNode(self: *Timeline) audio.Node {
        return self.mixer.asNode();
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

pub const Plugin = union(enum) {
    lpf: *audio.Lpf,
    distortion: *audio.Distortion,
    delay: *audio.Delay,
    gain: *audio.Gain,

    /// Deinit the plugin node only (not the state - state is owned by Track)
    pub fn deinit(self: Plugin, alloc: std.mem.Allocator) void {
        switch (self) {
            .lpf => |p| alloc.destroy(p),
            .distortion => |p| alloc.destroy(p),
            .delay => |p| alloc.destroy(p), // Don't free state - Track owns it
            .gain => |p| alloc.destroy(p),
        }
    }
    pub fn asNode(self: Plugin) audio.Node {
        return switch (self) {
            .lpf => |p| p.asNode(),
            .distortion => |p| p.asNode(),
            .delay => |p| p.asNode(),
            .gain => |p| p.asNode(),
        };
    }
    pub fn setInput(self: Plugin, input: audio.Node) void {
        switch (self) {
            .lpf => |p| p.input = input,
            .distortion => |p| p.input = input,
            .delay => |p| p.input = input,
            .gain => |p| p.input = input,
        }
    }
};

pub const PluginTag = std.meta.Tag(Plugin);

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

    /// Check if chain has a plugin of the given type
    pub fn hasPlugin(self: *const PluginChain, comptime tag: PluginTag) bool {
        for (self.plugins[0..self.len]) |p| {
            if (p == tag) return true;
        }
        return false;
    }

    /// Remove the first plugin of the given type
    pub fn removePlugin(self: *PluginChain, comptime tag: PluginTag) void {
        for (0..self.len) |i| {
            if (self.plugins[i] == tag) {
                self.plugins[i].deinit(self.alloc);
                for (i..self.len - 1) |j| {
                    self.plugins[j] = self.plugins[j + 1];
                }
                self.len -= 1;
                self.rewire();
                return;
            }
        }
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
    synth: *uni.Uni,
    player: midi.Player,
    alloc: std.mem.Allocator,

    // Double-buffered plugin chains
    chains: [2]PluginChain,
    active: std.atomic.Value(u8),

    // State for stateful plugins (shared across both chains)
    lpf_state: audio.Lpf.State,
    delay_state: ?*audio.Delay.State,

    vt: audio.VTable = .{ .process = Track._process },

    pub fn init(alloc: std.mem.Allocator, voice_count: usize, notes_in: []const midi.Note) !Track {
        const synth = try uni.Uni.init(alloc, voice_count);
        const synth_node = synth.asNode();

        return .{
            .synth = synth,
            .player = try midi.Player.init(alloc, notes_in),
            .alloc = alloc,
            .chains = .{
                PluginChain.init(alloc, synth_node),
                PluginChain.init(alloc, synth_node),
            },
            .active = std.atomic.Value(u8).init(0),
            .lpf_state = .{},
            .delay_state = null,
        };
    }
    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
        self.chains[0].deinit();
        self.chains[1].deinit();
        if (self.delay_state) |ds| {
            ds.deinit(alloc);
        }
    }
    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Track = @ptrCast(@alignCast(p));
        const chain = &self.chains[self.active.load(.acquire)];
        const node = chain.output();
        node.v.process(node.ptr, ctx, out);
    }
    pub fn asNode(self: *Track) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }

    /// Generic toggle using double-buffer swap pattern
    fn togglePlugin(
        self: *Track,
        comptime tag: PluginTag,
        createFn: fn (*Track, *PluginChain) anyerror!void,
    ) !void {
        const active_idx = self.active.load(.acquire);
        const inactive_idx = active_idx ^ 1;

        if (self.chains[active_idx].hasPlugin(tag)) {
            // Remove from inactive, swap, remove from other
            self.chains[inactive_idx].removePlugin(tag);
            self.active.store(inactive_idx, .release);
            self.chains[active_idx].removePlugin(tag);
        } else {
            // Add to inactive, swap, add to other
            try createFn(self, &self.chains[inactive_idx]);
            self.active.store(inactive_idx, .release);
            try createFn(self, &self.chains[active_idx]);
        }
    }

    fn createLpf(self: *Track, chain: *PluginChain) !void {
        const lpf = try self.alloc.create(audio.Lpf);
        lpf.* = audio.Lpf.init(chain.output(), 1.0, 2.0, 2000.0, &self.lpf_state);
        chain.append(.{ .lpf = lpf });
    }

    fn createDistortion(_: *Track, chain: *PluginChain) !void {
        const dist = try chain.alloc.create(audio.Distortion);
        dist.* = audio.Distortion.init(chain.output(), 8.0, 0.7, .soft);
        chain.append(.{ .distortion = dist });
    }

    fn createDelay(self: *Track, chain: *PluginChain) !void {
        // Create shared state if it doesn't exist
        if (self.delay_state == null) {
            self.delay_state = try audio.Delay.State.init(self.alloc, 48000 * 2); // 2 sec buffer
        }
        const delay = try self.alloc.create(audio.Delay);
        delay.* = audio.Delay.init(chain.output(), 0.25, 0.4, 0.3, self.delay_state.?);
        chain.append(.{ .delay = delay });
    }

    pub fn hasLpf(self: *Track) bool {
        return self.chains[self.active.load(.acquire)].hasPlugin(.lpf);
    }
    pub fn hasDistortion(self: *Track) bool {
        return self.chains[self.active.load(.acquire)].hasPlugin(.distortion);
    }
    pub fn hasDelay(self: *Track) bool {
        return self.chains[self.active.load(.acquire)].hasPlugin(.delay);
    }

    pub fn toggleLpf(self: *Track) !void {
        try self.togglePlugin(.lpf, createLpf);
    }
    pub fn toggleDistortion(self: *Track) !void {
        try self.togglePlugin(.distortion, createDistortion);
    }
    pub fn toggleDelay(self: *Track) !void {
        try self.togglePlugin(.delay, createDelay);
    }
};
