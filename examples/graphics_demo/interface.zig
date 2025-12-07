const std = @import("std");
const rl = @import("raylib");

const WIDTH = 128;
const HEIGHT = 128;

pub const Event = struct {
    type: EventType,
    key: rl.KeyboardKey,
};

pub const EventType = enum {
    key_press,
    key_release,
};

var target: rl.RenderTexture2D = undefined;
var keys_pressed: std.AutoHashMap(i32, bool) = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(512, 512, "LeDaw");

    target = try rl.loadRenderTexture(WIDTH, HEIGHT);
    rl.setTargetFPS(60);
    rl.setExitKey(.null); // ESC doesn't close program

    keys_pressed = std.AutoHashMap(i32, bool).init(allocator);

    // Initialize common keys
    const tracked_keys = [_]rl.KeyboardKey{
        .up,    .down,  .left,   .right,
        .w,     .a,     .s,      .d,
        .space, .enter, .escape,
    };

    for (tracked_keys) |key| {
        try keys_pressed.put(@intFromEnum(key), false);
    }
}

pub fn deinit() void {
    keys_pressed.deinit();
    rl.unloadRenderTexture(target);
    rl.closeWindow();
}

pub fn preRender() void {
    rl.beginTextureMode(target);
    rl.clearBackground(rl.Color.black);
}

pub fn postRender() void {
    const screen_width = rl.getScreenWidth();
    const screen_height = rl.getScreenHeight();
    const square_len = @min(screen_width, screen_height);
    const pos_x: f32 = @floatFromInt(@divTrunc(screen_width - square_len, 2));
    const pos_y: f32 = @floatFromInt(@divTrunc(screen_height - square_len, 2));
    const square_len_f: f32 = @floatFromInt(square_len);

    rl.endTextureMode();
    rl.beginDrawing();
    defer rl.endDrawing();

    // render the 128x128 square
    rl.drawTexturePro(
        target.texture,
        rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(target.texture.width),
            .height = -@as(f32, @floatFromInt(target.texture.height)), // flip Y
        },
        rl.Rectangle{
            .x = pos_x,
            .y = pos_y,
            .width = square_len_f,
            .height = square_len_f,
        },
        rl.Vector2{ .x = 0, .y = 0 },
        0.0,
        rl.Color.white,
    );
}

pub fn pollEvent(event: *Event) bool {
    var iter = keys_pressed.iterator();
    while (iter.next()) |entry| {
        const key_int = entry.key_ptr.*;
        const is_pressed = entry.value_ptr;
        const key: rl.KeyboardKey = @enumFromInt(key_int);

        if (rl.isKeyDown(key)) {
            if (!is_pressed.*) {
                is_pressed.* = true;
                event.type = .key_press;
                event.key = key;
                return true;
            }
        } else if (is_pressed.*) {
            is_pressed.* = false;
            event.type = .key_release;
            event.key = key;
            return true;
        }
    }
    return false;
}

pub fn shouldClose() bool {
    return rl.windowShouldClose();
}
