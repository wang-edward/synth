const std = @import("std");
const SpscQueue = @import("queue").SpscQueue;

pub const ParamRef = union(enum) {
    Lpf: Lpf.Params,
};
pub const Op = union(enum) {
    SetParam: struct {
        track_id: u32,
        plugin_id: u32,
        param: ParamRef,
        from: f32,
        to: f32,
    },
};

pub const Lpf = struct {
    pub const Params = struct {
        drive: f32,
        resonance: f32,
        cutoff: f32,
    };
    params: Params,

    pub fn init(params: Params) Lpf {
        return .{ .params = params };
    }
};

var opQueue: SpscQueue(Op, 16) = .{};
var myLpf = Lpf.init(.{ 0.1, 1.0, 10.0 });

fn audioThreadMain() !void {
    while (true) {
        if (opQueue.pop()) |op| {
            switch (op) {
                Op.SetParam => std.debug.print("set param {}\n", .{op}),
            }
        }
    }
}

pub fn main() !void {
    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer audio_thread.join();
    while (true) {
        while (!opQueue.push(.{ .SetParam = .{
            .track_id = 0,
            .plugin_id = 0,
            .param = .{ .Lpf = .{
                .drive = 0.5,
                .resonance = 0.7,
                .cutoff = 1000.0,
            } },
            .from = 0.0,
            .to = 1.0,
        } })) {}
    }
}
