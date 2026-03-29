Everything compiles cleanly. Here's a summary of what was implemented across 3 files:

  src/interface.zig — Added drawBorder() helper for mode/recording indicators.

  src/project.zig — Added:
  - RenderCtx struct to pass UI state without circular imports
  - frameToBeat/beatToPx conversion helpers
  - Timeline.render(ctx) — draws header (mode indicator, beat position, track number) + 4 visible track
  rows
  - Track.renderTimeline() — draws track label, green clip rectangles from player notes, white playhead
  line, orange cursor outline on active track
  - Track.renderDetail() — draws plugin grid (4x2 cells with names/selection), header, footer hints
  - renderPluginSelector() — lists all PluginTag enum variants with selection highlight

  src/main.zig — Added:
  - Screen enum (timeline/track/plugin_selector) and Mode enum (normal/insert) with state globals
  - Viewport state (g_cursor_beat, g_viewport_center, g_viewport_radius, g_scroll_offset)
  - addSelectedPlugin() — creates plugin from selector index via switch on PluginTag
  - Modal input: i toggles mode (releases held notes on exit), insert mode gets piano/octave/cutoff,
  normal mode dispatches per-screen (timeline: hjkl nav, space/backspace/r playback, enter→track, -/=
  zoom; track: hl plugin nav, a→selector, x delete, esc back; selector: jk nav, enter add, esc back)
  - Screen-switched rendering with mode border (magenta=insert, red=recording)

