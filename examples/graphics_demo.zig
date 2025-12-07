const std = @import("std");
const rl = @import("raylib");

const WIDTH = 128;
const HEIGHT = 128;

const Event = struct {
    type: EventType,
    key: rl.KeyboardKey,
};

const EventType = enum {
    key_press,
    key_release,
};

const Interface = struct {
    target: rl.RenderTexture2D,
    keys_pressed: std.AutoHashMap(i32, bool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Interface {
        rl.setConfigFlags(.{ .window_resizable = true });
        rl.initWindow(512, 512, "raylib - Rescalable 128x128 render");

        const target = try rl.loadRenderTexture(WIDTH, HEIGHT);
        rl.setTargetFPS(60);
        rl.setExitKey(.null); // ESC doesn't close program

        var keys_pressed = std.AutoHashMap(i32, bool).init(allocator);

        // Initialize common keys
        const tracked_keys = [_]rl.KeyboardKey{
            .up,    .down,  .left,   .right,
            .w,     .a,     .s,      .d,
            .space, .enter, .escape,
        };

        for (tracked_keys) |key| {
            try keys_pressed.put(@intFromEnum(key), false);
        }

        return Interface{
            .target = target,
            .keys_pressed = keys_pressed,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Interface) void {
        self.keys_pressed.deinit();
        rl.unloadRenderTexture(self.target);
        rl.closeWindow();
    }

    pub fn preRender(self: *Interface) void {
        rl.beginTextureMode(self.target);
        rl.clearBackground(rl.Color.black);
    }

    pub fn postRender(self: *Interface) void {
        const screen_width = rl.getScreenWidth();
        const screen_height = rl.getScreenHeight();
        const square_len = @min(screen_width, screen_height);
        const pos_x: f32 = @floatFromInt(@divTrunc(screen_width - square_len, 2));
        const pos_y: f32 = @floatFromInt(@divTrunc(screen_height - square_len, 2));
        const square_len_f: f32 = @floatFromInt(square_len);

        rl.endTextureMode();
        rl.beginDrawing();
        defer rl.endDrawing();

        // Draw the 128x128 render texture scaled to fit the window
        rl.drawTexturePro(
            self.target.texture,
            rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(self.target.texture.width),
                .height = -@as(f32, @floatFromInt(self.target.texture.height)), // flip Y
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

    pub fn pollEvent(self: *Interface, event: *Event) bool {
        var iter = self.keys_pressed.iterator();
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

    pub fn shouldClose(self: *Interface) bool {
        _ = self;
        return rl.windowShouldClose();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var interface = try Interface.init(allocator);
    defer interface.deinit();

    // Example: simple drawing state
    var circle_x: f32 = WIDTH / 2;
    var circle_y: f32 = HEIGHT / 2;
    const speed: f32 = 2.0;

    while (!interface.shouldClose()) {
        // Poll events
        var event: Event = undefined;
        if (interface.pollEvent(&event)) {
            if (event.type == .key_press) {
                std.debug.print("Key pressed: {}\n", .{event.key});
            }
        }

        // Update
        if (rl.isKeyDown(.right)) circle_x += speed;
        if (rl.isKeyDown(.left)) circle_x -= speed;
        if (rl.isKeyDown(.up)) circle_y -= speed;
        if (rl.isKeyDown(.down)) circle_y += speed;

        // Clamp to 128x128 area
        circle_x = @max(0, @min(WIDTH, circle_x));
        circle_y = @max(0, @min(HEIGHT, circle_y));

        // Render to 128x128 texture
        interface.preRender();
        {
            // Draw your 128x128 content here
            rl.drawCircle(
                @intFromFloat(circle_x),
                @intFromFloat(circle_y),
                8,
                rl.Color.white,
            );

            rl.drawText("128x128", 2, 2, 10, rl.Color.light_gray);
            rl.drawRectangleLines(0, 0, WIDTH, HEIGHT, rl.Color.dark_gray);
        }
        interface.postRender();
    }
}
