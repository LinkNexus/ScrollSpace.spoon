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
- **Full-workspace hide/show mechanism: `window:minimize()` /
  `window:unminimize()`.** Applies to switching workspaces (hide every
  window of the outgoing workspace, show every window of the incoming
  one) and the scratchpad toggle — there coordinate positioning genuinely
  can't hide a window (macOS clamps it back onto the visible screen
  margin, confirmed in PaperWM's own docs). This does **not** extend to
  intra-workspace scroll overflow — see the off-viewport-columns note
  under Multi-monitor below, which deliberately uses coordinate
  positioning instead for that case.
- **Tiling: full scrolling column layout, PaperWM/niri-style.** Windows
  tile left-to-right in columns; columns can hold multiple windows stacked
  vertically; column widths vary; layout scrolls horizontally past screen
  edges. Port PaperWM's `tileColumn`/`tileSpace` algorithm directly, just
  re-keyed by workspace id instead of Space id.
- **Data model:** `window_list[workspace][strip][col][row] = hs.window`,
  plus `index_table[window_id] = {workspace, strip, col, row}` for O(1)
  lookup — same shape as PaperWM, `space` replaced with our own
  `workspace` integer, and a `strip` level added (see Multi-monitor).
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
  list when it's minimized for a workspace switch. Only remove a window
  from the list when it's actually destroyed (`windowDestroyed`), or
  explicitly moved to another workspace, or made floating.

  Tiling skips them: `tiling.lua`'s `visible_columns()` projects a
  strip's columns down to just the windows that are on screen right now,
  preserving column indices so an anchor's `col` stays meaningful. A
  minimized window left in the layout math would claim a share of its
  column's height, and a fully hidden column would leave a gap that
  shifts every column to its right. A hidden window can't serve as a
  tiling anchor either (`canAnchor` / `getFirstVisibleWindow`).
- **Per-window (not per-app) assignment rules**, evaluated at window
  creation against app name + window title using Lua patterns:
  ```lua
  VirtualWorkspaces.rules = {
    { app = "kitty", title = "^btop", workspace = 3 },
    { app = "Zen Browser", title = "Anthropic", workspace = 2 },
    { app = "Zen Browser", workspace = 1 }, -- fallback for that app
  }
  ```
  First matching rule wins. `Rules.assign` returns **nil** when nothing
  matched — the fallback belongs to the caller, because the two callers
  need different behaviour:
  - `windows.addWindow` falls back to `current_workspace`: a brand new
    window with no rule does belong on whatever workspace is active.
  - the `windowTitleChanged` handler does **not** fall back: it only acts
    on an explicit match. Rules are re-run on title change (a step beyond
    what AeroSpace/FlashSpace do) so a window can follow its own title
    between workspaces, but a non-match must leave the window exactly
    where it is. Folding the fallback into `assign` made every retitle of
    an already-tracked window — a browser switching tabs, a shell changing
    directory — look like a match for the active workspace and drag the
    window out of the workspace it was living on.
- **Floating windows are assigned to a workspace** (hidden/shown with it
  when switching), they're just excluded from tiling math — same as
  PaperWM's `is_floating` set, but tag each entry with its owning
  workspace id so switching hides/shows it correctly.

  Because they're outside `window_list`, a tiled window laid over the same
  area simply covers them and `focusWindow` can't dig them back out — it
  only walks `window_list`. `focusFloating()` (ported from PaperWM's
  action of the same name) is the way back: it focuses every floating
  window of the current workspace in turn, which activates each one's app
  and pulls the whole layer above the tiled strip, focusing its target
  last so that window ends up on top. Focusing each one rather than
  `window:raise()` is deliberate — `raise()` only reorders within the
  window's own app, so it can't lift a background app's window above the
  frontmost app's. Repeated calls cycle through the layer (window id
  order), so the hotkey walks it instead of toggling between two windows.

  `focusFloating`'s idea of "floating" is deliberately wider than
  `is_floating`: it also picks up visible windows ScrollSpace doesn't
  track at all (anything excluded at the `window_filter` level, e.g.
  Finder / System Settings in the parent config). Those are never tiled
  and never minimized by a switch, so they float in practice, and nothing
  else in the keyboard surface can reach them. Excluded from that second
  group: the scratchpad (it has its own toggle), PiP panels (per the
  always-global rule below), and non-standard windows.
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
- **Multi-monitor: implemented, as strips rather than per-display.** The
  unit of tiling is a **strip**: one continuous column sequence.
  `screens.lua` decides which displays back a strip, and the rule is the
  physical arrangement:
  - displays arranged **side by side** form a *single* strip that flows
    across them. Scrolling carries columns from one display onto the next;
    focus/swap/slurp/barf just walk the one column array, so they cross
    displays for free.
  - displays stacked **vertically** get *one strip each*. A strip has no
    business flowing through the bezel between a display and the one
    above it.

  Data model: `window_list[workspace][strip][col][row]`, where the strip
  key is the UUID of its **leftmost** display. A single-monitor setup's
  key is therefore just that display's UUID, so no state migration was
  needed for it. `index_table[window_id] = {workspace, strip, col, row}`.

  Adjacency (`screens.lua`) is judged on `fullFrame()`, not `frame()`:
  `frame()` is the usable area, so a Dock pinned to a left or right edge
  insets it and two physically flush displays would stop looking
  adjacent. Two displays join a strip when their edges touch within 2pt
  *and* they overlap vertically for at least 50% of the **shorter** one's
  height — the share is of the shorter display so a built-in beside an
  ultrawide still counts, while a display merely clipping a neighbour's
  corner does not. A strip is one-dimensional, so each display gets at
  most one left and one right neighbour; where two stacked displays both
  abut a third, the better-overlapping one continues the strip and the
  other becomes its own strip rather than making column order ambiguous.

  **Columns never straddle a display boundary.** A column that won't fit
  in the rest of the current display starts at the next display's left
  edge instead, leaving the slack as dead space at the previous display's
  right edge. Straddling would put one window across a physical bezel at
  two different scale factors. Absorbing the slack by widening the
  preceding column is deliberately *not* done: column widths are read
  back out of window frames on the next pass (`tileColumn`'s
  `w or frame.w`), so stretching would permanently overwrite the width
  the user picked with `cycleWindowSize`. Each column takes its vertical
  bounds from the display it lands on, so a short display beside a tall
  one tiles to its own height.

  Off-viewport columns (scrolled past the **strip's** own end) are still
  positioned off-canvas via coordinates clamped to `left_margin`/
  `right_margin` — **not** minimized. What changed is that those margins
  are now the strip's *outer* edges rather than each display's: an
  interior display edge is no longer somewhere to park. That was the bug
  — with per-display strips, a column scrolled off the ultrawide was
  parked 1pt inside the ultrawide's right edge, which left ~1pt on the
  ultrawide and the entire rest of the window visible on the built-in
  beside it. The CLAUDE.md note of 2026-08-17 described this as "a
  visible sliver on the neighboring screen", which understated it badly.

  An earlier revision minimized off-viewport columns instead, reasoning
  that macOS clamps a window's frame back onto the nearest connected
  screen. That's true, but it made ordinary horizontal scrolling visibly
  minimize/unminimize windows (Dock genie animation, Dock icon churn) on
  every scroll step, including on a single monitor. Reverted deliberately
  (user call, 2026-08-17) and still reverted: with strip-wide margins the
  interior-edge case that motivated it no longer exists. Full-workspace
  hide/show (`switchWorkspace`) and the scratchpad still use
  `minimize()`/`unminimize()` — unaffected and not in question.

  `State.reconcileStrips()` (called from `events.lua`'s screen_watcher,
  and mirrored in `State.load()` via `State.resolveStrip()`) re-keys
  buckets against the current arrangement, covering three cases with one
  rule — "ask screens.lua which strip holds this display, else fall back
  to the primary display's strip":
  - the display is gone (unplugged monitor): its windows merge onto the
    primary display's strip rather than being stranded.
  - the display is connected but no longer leftmost in its strip, because
    something was plugged in to its left: the bucket migrates to the new
    key, or it would tile as a second overlapping strip.
  - two strips have become one side-by-side run: they merge.

  It can only ever *merge* strips, never split one — columns don't record
  which display they were physically on, so breaking up a side-by-side
  strip lands every column on one of the results. Every window stays
  tracked, tiled and reachable, the same degrade as the unplug case.

  `move_window_to_next_strip` (was `move_window_to_next_screen`; the old
  action name stays resolvable in `actions.lua` for explicit bindings)
  cycles the focused window to the next strip, keeping its workspace. It
  no-ops when every display forms one strip, since there is nothing to
  move the window *to* — scrolling the strip is what puts a window on the
  next display over.

## Module layout

Same split as PaperWM.spoon, so the two stay diffable:

| ScrollSpace | PaperWM | contents |
| --- | --- | --- |
| `init.lua` | `init.lua` | metadata, module loading, `start`/`stop`/`tileWorkspace`/`bindHotkeys` |
| `config.lua` | `config.lua` | defaults applied onto the Spoon table |
| `state.lua` | `state.lua` | `window_list`/`index_table`/watchers/`x_positions` behind proxy tables, plus JSON persistence |
| `windows.lua` | `windows.lua` | window-list surgery (`addWindow`/`removeWindow`/`refreshWindows`) and per-window commands (focus/swap/center/cycle/slurp/barf/`moveWindow`) |
| `workspace.lua` | `space.lua` | switching (`switchWorkspace`), moving windows between workspaces and strips |
| `tiling.lua` | `tiling.lua` | `tileColumn` / `tileGroup` / `tileWorkspace` |
| `events.lua` | `events.lua` | window filter subscriptions, screen and app watchers |
| `actions.lua` | `actions.lua` | hotkey-bindable action spec |
| `floating.lua` | `floating.lua` | the floating layer |
| `screens.lua` | — | display topology: which displays form one strip |
| `rules.lua` | — | per-window workspace assignment rules |
| `scratchpad.lua` | — | the single global scratchpad window |
| `spec/` | `spec/` | busted specs against a mocked `hs` namespace |

`hs.spaces`, Mission Control, and swipe/drag/scroll gestures have no
counterpart here — `mission_control.lua`, `space_tracker.lua` and
`swipe.lua` are deliberately absent.

## Tests

`spec/` mirrors PaperWM's: busted specs over `spec/mocks.lua`, a stand-in
`hs` namespace. `spec/spec_helper.lua` loads every module against the
mocks and exposes `H.reset()` for `before_each`. Run from this directory:

```
busted spec/
```

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
6. **Floating toggle**: `toggleFloating()` on focused window, plus
   `focusFloating()` to bring the floating layer back above the tiled
   strip (see the floating bullet above).
7. **Scratchpad**: `setScratchpad()` (assign focused window as scratchpad,
   remove from its workspace/floating tracking, minimize it),
   `toggleScratchpad()`.
8. **Hotkeys**: `switch_workspace_1..9`, `move_window_1..9`,
   `focus_left/right/up/down`, `swap_left/right/up/down`, `cycle_width`,
   `toggle_floating`, `focus_floating`, `toggle_scratchpad`, `set_scratchpad`,
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

- Slurp/barf (can port from PaperWM later if wanted).
- Reacting to a user manually minimizing a window via the traffic-light
  button (currently only our own explicit calls are expected to minimize
  tracked windows).
