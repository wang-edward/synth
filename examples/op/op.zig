const std = @import("std");
const SpscQueue = @import("queue").SpscQueue;

pub const ParamRef = union(enum) {
    Lpf: Lpf.Param,
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
    pub const Param = enum {
        drive,
        resonance,
        cutoff,
    };
    params: Params,

    pub fn init(params: Params) Lpf {
        return .{ .params = params };
    }
    pub fn setParam(self: *Lpf, p: Param, to: f32) void {
        switch (p) {
            .drive => self.params.drive = to,
            .resonance => self.params.resonance = to,
            .cutoff => self.params.cutoff = to,
        }
    }
};

var opQueue: SpscQueue(Op, 16) = .{};
var myLpf = Lpf.init(.{ .drive = 0.1, .resonance = 1.0, .cutoff = 10.0 });

fn audioThreadMain() !void {
    while (true) {
        if (opQueue.pop()) |op| {
            switch (op) {
                .SetParam => |sp| switch (sp.param) {
                    .Lpf => |p| myLpf.setParam(p, sp.to),
                },
            }
        }
        std.debug.print("lpf: {}\n", .{myLpf});
    }
}

pub fn main() !void {
    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer audio_thread.join();
    while (true) {
        while (!opQueue.push(.{ .SetParam = .{
            .track_id = 0,
            .plugin_id = 0,
            .param = .{ .Lpf = .cutoff },
            .from = 0.0,
            .to = 1.0,
        } })) {}
    }
}
