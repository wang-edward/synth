const std = @import("std");
const rl = @import("raylib");
const interface = @import("interface.zig");

pub fn render() void {
    for (0..interface.WIDTH) |x| {
        for (0..interface.HEIGHT) |y| {
            if ((x + y) % 2 == 0) {
                rl.drawPixel(@intCast(x), @intCast(y), rl.Color.red);
            }
        }
    }
}
