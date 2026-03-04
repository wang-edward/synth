const interface = @import("interface.zig");
const rl = @import("raylib");

pub const App = struct {
    const Screen = enum { timeline, track, plugin_sel };
    timeline: Timeline,
    pub fn render(self: *App) void {
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

pub const Timeline = struct {
    track: Track,
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

pub const Track = struct {
    pub fn render(self: *Track) void {
        _ = self;
        for (0..interface.WIDTH) |x| {
            for (0..interface.HEIGHT) |y| {
                if ((x + y) % 2 == 0) {
                    rl.drawPixel(@intCast(x), @intCast(y), rl.Color.green);
                }
            }
        }
    }
};
