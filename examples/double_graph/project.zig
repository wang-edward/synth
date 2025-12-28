const std = @import("std");
const audio = @import("audio.zig");
const synth_mod = @import("synth.zig");
const midi = @import("midi.zig");

// =============================================================================
// Project - Timeline with multiple Tracks, builds unified graph
// =============================================================================

pub const Track = struct {
    synth: *synth_mod.Synth,
    player: midi.Player,
    params: synth_mod.SynthParams = .{},

    pub fn init(alloc: std.mem.Allocator, voice_count: usize, notes_in: []const midi.Note) !Track {
        return .{
            .synth = try synth_mod.Synth.init(alloc, voice_count),
            .player = try midi.Player.init(alloc, notes_in),
        };
    }

    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
    }
};

pub const Timeline = struct {
    tracks: []Track,
    alloc: std.mem.Allocator,

    // Storage for master mixer
    master_inputs: []u16,
    master_gains: []f32,

    pub fn init(
        alloc: std.mem.Allocator,
        num_tracks: usize,
        voices_per_track: usize,
        notes_per_track: []const []const midi.Note,
    ) !Timeline {
        std.debug.assert(notes_per_track.len == num_tracks);

        const tracks = try alloc.alloc(Track, num_tracks);
        for (tracks, 0..) |*t, i| {
            t.* = try Track.init(alloc, voices_per_track, notes_per_track[i]);
        }

        const master_inputs = try alloc.alloc(u16, num_tracks);
        const master_gains = try alloc.alloc(f32, num_tracks);

        return .{
            .tracks = tracks,
            .alloc = alloc,
            .master_inputs = master_inputs,
            .master_gains = master_gains,
        };
    }

    pub fn deinit(self: *Timeline, alloc: std.mem.Allocator) void {
        for (self.tracks) |*t| t.deinit(alloc);
        alloc.free(self.tracks);
        alloc.free(self.master_inputs);
        alloc.free(self.master_gains);
    }

    /// Total nodes needed for entire timeline
    pub fn nodeCount(self: *const Timeline) usize {
        var total: usize = 0;
        for (self.tracks) |*t| {
            total += t.synth.nodeCount();
        }
        return total + 1; // +1 for master mixer
    }

    /// Build the complete graph into the provided node slice
    pub fn buildGraph(self: *Timeline, nodes: []audio.Node) audio.Graph {
        var base_idx: u16 = 0;

        for (self.tracks, 0..) |*track, i| {
            const output_idx = track.synth.buildNodes(nodes, base_idx, track.params);
            self.master_inputs[i] = output_idx;
            self.master_gains[i] = 1.0 / @as(f32, @floatFromInt(self.tracks.len));
            base_idx += @intCast(track.synth.nodeCount());
        }

        // Master mixer
        const master_idx = base_idx;
        nodes[master_idx] = .{ .mixer = .{
            .inputs = self.master_inputs,
            .gains = self.master_gains,
        } };

        return .{ .nodes = nodes, .output = master_idx };
    }

    /// Copy voice frequencies from one node slice to another
    pub fn copyFreqs(self: *Timeline, from: []audio.Node, to: []audio.Node) void {
        var base_idx: u16 = 0;
        for (self.tracks) |*track| {
            track.synth.copyFreqs(from, to, base_idx);
            base_idx += @intCast(track.synth.nodeCount());
        }
    }

    /// Get the base node index for a track
    pub fn trackBaseIdx(self: *const Timeline, track_idx: usize) u16 {
        var base: u16 = 0;
        for (0..track_idx) |i| {
            base += @intCast(self.tracks[i].synth.nodeCount());
        }
        return base;
    }
};
