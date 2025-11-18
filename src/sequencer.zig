pub const synth = @import("synth.zig");
pub const Sequencer = struct {
    synth: synth.Synth,
    pub fn tick() void {}
};
