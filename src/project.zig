const std = @import("std");
const uni = @import("uni.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
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
            nodes[i] = t.synth.asNode();
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
};

pub const Track = struct {
    synth: *uni.Uni,
    player: midi.Player,

    pub fn init(alloc: std.mem.Allocator, voice_count: usize, notes_in: []const midi.Note) !Track {
        return .{
            .synth = try uni.Uni.init(alloc, voice_count),
            .player = try midi.Player.init(alloc, notes_in),
        };
    }
    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
    }
};
