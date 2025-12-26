const std = @import("std.zig");
const uni = @import("uni.zig");
const midi = @import("midi.zig");
pub const Timeline = struct {
    tracks: []Track,
};

pub const Track = struct {
    synth: *uni.Uni,
    player: midi.Player,

    pub fn init(alloc: std.mem.Allocator, synth: *uni.Uni, notes_in: []const midi.Note) !Track {
        return .{
            .synth = synth,
            .player = try midi.Player.init(alloc, notes_in),
        };
    }
    pub fn deinit(self: Track, alloc: std.mem.Allocator) void {
        self.player.deinit(alloc);
    }
};
