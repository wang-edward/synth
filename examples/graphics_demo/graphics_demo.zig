const std = @import("std");
const rl = @import("raylib");
const interface = @import("interface.zig");
const project = @import("project2.zig");

const WIDTH = 128;
const HEIGHT = 128;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try interface.init();
    defer interface.deinit();

    var circle_x: f32 = WIDTH / 2;
    var circle_y: f32 = HEIGHT / 2;
    const speed: f32 = 2.0;

    var app: project.App = .{ .timeline = .{ .track = .{}, .midi_editor = .{}, .screen = .overview } };

    while (!interface.shouldClose()) {
        // poll events
        while (interface.nextEvent()) |ev| {
            std.debug.print("event: {s} {s}\n", .{ @tagName(ev.type), @tagName(ev.key) });
            _ = app.handleEvent(ev);
        }

        // update
        if (rl.isKeyDown(.right)) circle_x += speed;
        if (rl.isKeyDown(.left)) circle_x -= speed;
        if (rl.isKeyDown(.up)) circle_y -= speed;
        if (rl.isKeyDown(.down)) circle_y += speed;

        // clamp position in screen
        circle_x = @max(0, @min(WIDTH, circle_x));
        circle_y = @max(0, @min(HEIGHT, circle_y));

        interface.preRender();
        defer interface.postRender();
        {
            rl.drawCircle(
                @intFromFloat(circle_x),
                @intFromFloat(circle_y),
                8,
                rl.Color.white,
            );

            rl.drawText("128x128", 2, 2, 10, rl.Color.light_gray);
            rl.drawRectangleLines(0, 0, WIDTH, HEIGHT, rl.Color.purple);

            app.render();
        }
    }
}
