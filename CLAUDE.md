# ScrollSpace.spoon

A Hammerspoon Spoon providing i3/niri-style virtual workspaces with built-in
PaperWM-style scrolling column tiling, **without** using native macOS Spaces.
Replaces PaperWM.spoon entirely — tiling is implemented in-house so that
window position/order survives hide/show across workspace switches.

Also replaces FlashSpace entirely. FlashSpace was the interim
workspace-switcher (see `flashspace/` config + `sketchybar/items/
flashspace.lua` in the parent repo, both being retired alongside this
Spoon's introduction) — ScrollSpace now owns workspace identity and
switching itself instead of delegating it to an external app, since it
already needs to track workspace membership for tiling. There is no
external workspace manager left in the stack; `switchWorkspace`/
`current_workspace` here are the only source of truth.

## Why not just use PaperWM.spoon

PaperWM.spoon's `window_list` is keyed by real macOS Space id
(`Spaces.windowSpaces(window)[1]`). When a window is hidden (minimized) it's
fully removed from `window_list` via `removeWindow()`; when it reappears,
`addWindow()` re-inserts it either next to the focused window or by comparing
`frame().center.x` against existing columns — never at its original position.
Layering a virtual-workspace switcher on top of PaperWM by minimizing windows
therefore causes the column order to reflow every time you switch back to a
workspace.

The fix: key the tiling data structure by **our own virtual workspace id**
instead of a real Space, and never remove a hidden window from that
structure — just skip it when tiling. Switching workspaces becomes a pure
visibility operation; layout position is never touched, so there's nothing to
restore.

PaperWM.spoon's tiling algorithm (`tileColumn`/`tileSpace`/`addWindow`/
`removeWindow`/`index_table`) is a good reference implementation to port from
— reuse the algorithm, re-key it to `workspace` instead of `space`, and drop
everything related to `hs.spaces` / real Mission Control spaces.

Reference source: https://github.com/Hammerspoon/Spoons/blob/master/Source/PaperWM.spoon/init.lua

## Core design decisions (already made — implement as specified)

- **No native macOS Spaces.** Everything happens on one real Space (or
  spans monitors — see below). `hs.spaces` is not used at all.
- **Hide/show mechanism: `window:minimize()` / `window:unminimize()`.**
  Off-screen positioning was ruled out — macOS clamps windows back onto the
  visible screen margin (confirmed in PaperWM's own docs), so it can't
  reliably hide anything.
- **Tiling: full scrolling column layout, PaperWM/niri-style.** Windows
  tile left-to-right in columns; columns can hold multiple windows stacked
  vertically; column widths vary; layout scrolls horizontally past screen
  edges. Port PaperWM's `tileColumn`/`tileSpace` algorithm directly, just
  re-keyed by workspace id instead of Space id.
- **Data model:** `window_list[workspace][col][row] = hs.window`, plus
  `index_table[window_id] = {workspace, col, row}` for O(1) lookup — same
  shape as PaperWM, `space` replaced with our own `workspace` integer.
- **State is persisted externally, not just held in memory.** On every
  change to `window_list`/`index_table`/floating set/scratchpad/
  `current_workspace` (debounced, not synchronous per-event), write a
  JSON snapshot to a state file (e.g. `~/.hammerspoon/scrollspace-state.json`
  — internal cache, distinct from any user-facing config). This serves two
  purposes:
  1. **Reload survival.** `hs.reload()` wipes the in-memory Lua state;
     on init, load the snapshot and reconcile it against
     `window_filter:getWindows()` (drop entries for windows that no
     longer exist, keep everything else including minimized/hidden
     windows — do **not** rebuild placement from scratch, that would
     defeat the entire point of this design, same as the hide/show
     rule above).
  2. **External consumers** (sketchybar workspace pills, replacing what
     `sketchybar/items/flashspace.lua` did via the `flashspace` CLI).
     Old pattern to adapt, from `hammerspoon/paperwm-sketchybar.lua`
     (deleted, see git history): write state, then
     `hs.task.new('/bin/sh', nil, {'-c', 'sketchybar --trigger
     scrollspace_workspace_change'})` so sketchybar re-reads on change
     instead of polling. That module used a hand-rolled line format
     because SbarLua has no Lua-side JSON decoder for general use —
     still true here, so either keep emitting a second line-format file
     alongside the JSON snapshot, or have the sketchybar item shell out
     to `jq`/similar to parse the JSON one. Decide when the sketchybar
     item is built, not blocking on it now.
- **Hidden windows stay in `window_list`.** Do not remove a window from the
  list when it's minimized for a workspace switch. `tileWorkspace()` simply
  skips windows that are currently minimized/not visible when computing
  frames. Only remove a window from the list when it's actually destroyed
  (`windowDestroyed`), or explicitly moved to another workspace, or made
  floating.
- **Per-window (not per-app) assignment rules**, evaluated at window
  creation against app name + window title using Lua patterns:
  ```lua
  VirtualWorkspaces.rules = {
    { app = "kitty", title = "^btop", workspace = 3 },
    { app = "Zen Browser", title = "Anthropic", workspace = 2 },
    { app = "Zen Browser", workspace = 1 }, -- fallback for that app
  }
  ```
  First matching rule wins; no match → assign to `current_workspace` at
  creation time. Optional nice-to-have: also re-run rules on
  `windowTitleChanged` (hs.window.filter supports this event) so windows
  can be reassigned dynamically as their title changes, not just once at
  creation — this is a step beyond what AeroSpace/FlashSpace do.
- **Floating windows are assigned to a workspace** (hidden/shown with it
  when switching), they're just excluded from tiling math — same as
  PaperWM's `is_floating` set, but tag each entry with its owning
  workspace id so switching hides/shows it correctly.
- **Scratchpad**: a single window (or small set) invocable from *any*
  workspace regardless of which one is active. Lives entirely outside
  `window_list`/`index_table` — not a workspace member, not tiled. Toggle
  hotkey does `minimize()`/`unminimize()`+`focus()` on the scratchpad
  window id. Independent of `current_workspace` state.
- **Picture-in-picture windows are always static/global** — never tracked,
  never minimized, never tiled. Exclude them at the `window_filter` level
  (PaperWM already excludes non-standard windows via
  `allowRoles = "AXStandardWindow"`; add a defensive `subrole()` check too
  since native PiP windows report a distinct subrole).
- **Multi-monitor: deferred.** Current plan (not yet implemented) is that a
  workspace spans all connected monitors at once, rather than being
  per-monitor. Build for single-monitor first (`Screen.primaryScreen()`),
  but don't hardcode assumptions that would make spanning multiple screens
  hard to add later — keep monitor/canvas lookup as its own function.

## Features to implement

1. **Workspace switching**: `switchWorkspace(n)` — minimize all windows
   (tiled + floating) belonging to `current_workspace`, unminimize all
   windows belonging to `n`, retile `n`, focus last-focused window of `n`
   (track `last_focused[workspace] = window_id` on every `windowFocused`
   event).
2. **Move window to workspace**: remove from current column position
   (list surgery only, keep the `uielement` watcher alive), insert into
   target workspace's list, minimize if target isn't active.
3. **Scrolling column tiling**: port `tileColumn`/`tileSpace` from
   PaperWM, `window_gap`, `screen_margin`, `window_ratios` for width
   cycling — same config shape as PaperWM.
4. **Focus/swap navigation**: `focusWindow(direction)`,
   `swapWindows(direction)` for left/right/up/down — port from PaperWM.
5. **Resize cycling**: `cycleWindowSize` through `window_ratios` — port
   from PaperWM. Slurp/barf (move window into/out of adjacent column) is
   nice-to-have, can be added after the core works.
6. **Floating toggle**: `toggleFloating()` on focused window.
7. **Scratchpad**: `setScratchpad()` (assign focused window as scratchpad,
   remove from its workspace/floating tracking, minimize it),
   `toggleScratchpad()`.
8. **Hotkeys**: `switch_workspace_1..9`, `move_window_1..9`,
   `focus_left/right/up/down`, `swap_left/right/up/down`, `cycle_width`,
   `toggle_floating`, `toggle_scratchpad`, `set_scratchpad`,
   `center_window`, `full_width`, `refresh_windows`, `stop_events` — same
   naming convention as PaperWM's `default_hotkeys` table for familiarity.

## Event handling notes

- Use one `hs.window.filter` instance (the "which windows do we manage at
  all" filter, PiP/panels excluded) subscribed to `windowVisible`,
  `windowNotVisible`, `windowFocused`, `windowDestroyed`,
  `windowFullscreened`, `windowUnfullscreened` — same event set PaperWM
  subscribes to.
- `windowVisible`: only call `addWindow()` if the window isn't already in
  `index_table` (guards against our own `unminimize()` calls re-triggering
  this).
- `windowNotVisible`: do **not** remove the window from `window_list` here
  — this fires for our own `minimize()` calls during a workspace switch,
  and removing it would defeat the whole point of this design. Only
  `windowDestroyed` should do real list surgery + watcher cleanup.
- Per-window `uielement` watcher on `windowMoved`/`windowResized` (as
  PaperWM does) to retile after manual drag/resize of a tiled window.

## Explicitly out of scope for v1

- Multi-monitor spanning (design intent noted above, not implemented yet).
- Slurp/barf (can port from PaperWM later if wanted).
- Reacting to a user manually minimizing a window via the traffic-light
  button (currently only our own explicit calls are expected to minimize
  tracked windows).
