const interface = @import("interface.zig");
const std = @import("std");
const rl = @import("raylib");

pub const App = struct {
    // const Screen = enum { timeline, plugin_sel };
    timeline: Timeline,
    // screen: Screen,
    pub fn render(self: *App) void {
        switch (self.screen) {
            .timeline => self.timeline.render(),
            .track => self.timeline.track.render(),
            .plugin_sel => unreachable,
        }

        // draw after for overlay
        for (0..interface.WIDTH) |x| {
            for (0..interface.HEIGHT) |y| {
                if (x == 0 or y == 0) {
                    rl.drawPixel(@intCast(x), @intCast(y), rl.Color.purple);
                }
            }
        }
    }

    pub fn handleEvent(self: *App, event: interface.Event) interface.Action {
        if (event.type != .key_press) return .None;

        return self.timeline.handleEvent(event);
        // switch (self.screen) {
        //     .timeline => self.timeline.handleEvent(event),
        //     .plugin_sel => unreachable,
        // }
    }
};

pub const Timeline = struct {
    const Screen = enum { overview, track, midi_editor };
    track: Track,
    midi_editor: MidiEditor,
    screen: Screen,
    pub fn render(self: *Timeline) void {
        switch (self.screen) {
            .overview => {
                for (0..interface.WIDTH) |x| {
                    for (0..interface.HEIGHT) |y| {
                        if ((x + y) % 2 == 0) {
                            // rl.drawPixel(@intCast(x), @intCast(y), rl.Color.red);
                        }
                    }
                }
                rl.drawText("TIMELINE_OVERVIEW", 30, 30, 10, rl.Color.light_gray);
            },
            .track => self.track.render(),
            .midi_editor => self.midi_editor.render(),
        }
    }

    pub fn handleEvent(self: *Timeline, event: interface.Event) interface.Action {
        if (event.type != .key_press) return .None;

        const action = switch (self.screen) {
            .overview => {
                switch (event.key) {
                    .p => std.debug.print("in the TRACK\n", .{}),
                    .enter => self.screen = .track,
                    .e => self.screen = .midi_editor,
                    else => {},
                }
                return .None;
            },
            .track => self.track.handleEvent(event),
            .midi_editor => self.midi_editor.handleEvent(event),
        };

        switch (action) {
            .GoBack => self.screen = .overview,
            else => {},
        }

        return .None;
    }
};

pub const Track = struct {
    pub fn render(self: *Track) void {
        _ = self;
        for (0..interface.WIDTH) |x| {
            for (0..interface.HEIGHT) |y| {
                if ((x + y) % 2 == 0) {
                    // rl.drawPixel(@intCast(x), @intCast(y), rl.Color.green);
                }
            }
        }
        rl.drawText("TRACK", 30, 30, 10, rl.Color.light_gray);
    }

    pub fn handleEvent(self: *Track, event: interface.Event) interface.Action {
        _ = self;
        if (event.type != .key_press) return .None;

        switch (event.key) {
            .p => std.debug.print("in the TRACK\n", .{}),
            .backspace => return .GoBack,
            else => {},
        }
        return .None;
    }
};

pub const MidiEditor = struct {
    pub fn render(self: *MidiEditor) void {
        _ = self;
        for (0..interface.WIDTH) |x| {
            for (0..interface.HEIGHT) |y| {
                if ((x + y) % 2 == 0) {
                    // rl.drawPixel(@intCast(x), @intCast(y), rl.Color.brown);
                }
            }
        }

        rl.drawText("MIDI_EDITOR", 30, 30, 10, rl.Color.light_gray);
    }

    pub fn handleEvent(self: *MidiEditor, event: interface.Event) interface.Action {
        _ = self;
        if (event.type != .key_press) return .None;

        switch (event.key) {
            .p => std.debug.print("in the MIDI EDITOR\n", .{}),
            .backspace => return .GoBack,
            else => {},
        }
        return .None;
    }
};
