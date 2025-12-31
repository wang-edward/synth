const std = @import("std");
const uni = @import("uni.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
const interface = @import("interface.zig");
const rl = @import("raylib");

pub const Timeline = struct {
    tracks: []Track,
    mixer: *audio.Mixer,
    // TODO const tracks?
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

// TODO autogen this
pub const Plugin = union(enum) {
    distortion: *audio.Distortion,
    gain: *audio.Gain,
    delay: *audio.Delay,

    pub fn deinit(self: Plugin, alloc: std.mem.Allocator) void {
        switch (self) {
            .distortion => |p| alloc.destroy(p),
            .gain => |p| alloc.destroy(p),
            .delay => |p| p.deinit(alloc),
        }
    }
    pub fn asNode(self: Plugin) audio.Node {
        return switch (self) {
            .distortion => |p| p.asNode(),
            .gain => |p| p.asNode(),
            .delay => |p| p.asNode(),
        };
    }
    pub fn setInput(self: Plugin, input: audio.Node) void {
        switch (self) {
            .distortion => |p| p.input = input,
            .gain => |p| p.input = input,
            .delay => |p| p.input = input,
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
    // create and append a distortion plugin
    // TODO delete
    pub fn addDistortion(self: *PluginChain, drive: f32, mix: f32, mode: audio.Distortion.Mode) !void {
        const d = try self.alloc.create(audio.Distortion);
        d.* = audio.Distortion.init(self.output(), drive, mix, mode);
        self.append(.{ .distortion = d });
    }
    // check if chain has a distortion plugin
    // TODO delete
    pub fn hasDistortion(self: *const PluginChain) bool {
        for (self.plugins[0..self.len]) |p| {
            if (p == .distortion) return true;
        }
        return false;
    }
    // remove the first distortion plugin found
    // TODO delete
    pub fn removeDistortion(self: *PluginChain) void {
        for (0..self.len) |i| {
            if (self.plugins[i] == .distortion) {
                self.plugins[i].deinit(self.alloc);
                // Shift remaining plugins down
                for (i..self.len - 1) |j| {
                    self.plugins[j] = self.plugins[j + 1];
                }
                self.len -= 1;
                self.rewire();
                return;
            }
        }
    }
    /// rewire all plugins after a removal
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

    // double-buffered plugin chains
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
            .chains = .{
                PluginChain.init(alloc, synth_node),
                PluginChain.init(alloc, synth_node),
            },
            .active = std.atomic.Value(u8).init(0),
        };
    }
    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
        self.chains[0].deinit();
        self.chains[1].deinit();
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
    pub fn hasDistortion(self: *Track) bool {
        return self.chains[self.active.load(.acquire)].hasDistortion();
    }
    // demo: toggle distortion using graph swap
    pub fn toggleDistortion(self: *Track) !void {
        const active_idx = self.active.load(.acquire);
        const inactive_idx = active_idx ^ 1;

        if (self.hasDistortion()) {
            self.chains[inactive_idx].removeDistortion();
            self.active.store(inactive_idx, .release);
            self.chains[active_idx].removeDistortion();
        } else {
            try self.chains[inactive_idx].addDistortion(8.0, 0.7, .soft);
            self.active.store(inactive_idx, .release);
            try self.chains[active_idx].addDistortion(8.0, 0.7, .soft);
        }
    }
};
