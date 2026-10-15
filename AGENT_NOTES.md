# Stream Deck Plus — Agent Notes

> Read this before touching the Stream Deck setup. This documents the **forked**
> version of the `elgato.streamdeck` Omarchy shell plugin, wired up for an
> **Elgato Stream Deck Plus**. Known bugs and what has been fixed are tracked in
> `BUGS.md`.

## TL;DR

- Device: **Elgato Stream Deck Plus** (`0fd9:0084`) — **8 keys (4×2)**, **4 dials**, **touch strip** (800×100).
- Plugin: Omarchy shell plugin `elgato.streamdeck`. Upstream is
  `Fragggy/omarchy-streamdeck-plugin`; this fork is
  `nishantpillai5/omarchy-streamdeck-plugin`, branch **`streamdeck-plus`**.
- **No reserved keys.** All 8 keys are profile-driven and editable in the panel.
  Audio cycling and Element launch are *regular* keys, not special-cased.
- **Profiles** = pages of keys. **Swipe left/right on the touch strip** to page
  between the profiles for the connected device's layout (wraps; other layouts are skipped).
- **4 dials** are always audio (never remapped per profile):
  `0=system volume`, `1=focused-app volume`, `2=mic input`, `3=pinned-app call volume (auto-detect, Element→Discord/Brave by default)`.
- **Touch strip** shows 4 status tiles (one per dial) + tap-to-mute per tile.
- The Python **bridge** runs **unsandboxed** as a child of the shell process and
  talks to it over **stdin/stdout JSON**.

## Architecture / data flow

```
Panel.qml  (bar widget + config UI, one per bar/monitor)
   │  calls functions on the Service singleton
Service.qml (singleton: owns profiles, config, active profile, brightness)
   │  bridgeController.send({op: ...})   /   onLine → handleEvent(ev)
BridgeController.qml  (spawns + pipes the Python bridge)
   │  stdin: JSON ops        stdout: JSON events
scripts/streamdeck-bridge  (Python: device I/O, icon rendering, audio, actions)
   │  ctypes + hidapi (vendored StreamDeck/ package)
Stream Deck Plus hardware
```

- The bridge is a **long-lived Python process**. The shell starts it, sends ops
  (`config`, `set_buttons`, `set_brightness`, `reconnect`, `ping`, `exit`), and reads
  events (`ready`, `disconnected`, `error`, `swipe`, `button_down/up`, `audio_key`, …).
  The full protocol is in the bridge's docstring.
- **Threads inside the bridge:**
  - **Device reader thread** (from the vendored lib): fires `key`/`dial`/`touchscreen`
    callbacks → `_on_key_change`, `_on_dial`, `_on_touchscreen`. These must stay
    fast: they only queue work, never call `wpctl`/`pactl`/`wtype` themselves.
  - **Task worker** (`_task_worker`, queue `self._tasks`): runs dial turns/pushes,
    strip taps and keybindings one at a time. Dial notches that arrive while a turn
    is queued are merged into it (`_pending_turns`), so fast spins don't lag.
  - **Main thread**: reads stdin ops via a **stdin reader thread + `queue.Queue`**
    (do NOT use `select()` on `sys.stdin`; it deadlocks when two ops arrive in one
    read chunk). Its 0.5–3 s timeout also drives `_check_connection()` (unplug
    detection) and the audio/magnitude key refresh.
  - Audio-output cycling runs on its own short-lived thread (`_handle_audio_cycle`).
  - All hardware writes go through `_set_key_image` / `_set_touchscreen_image`,
    which hold `self._lock` (an `RLock`). Keep it that way.
- **Shell side:** profile edits in `Service.qml` always assign new arrays/objects
  (`profilesWithChange`, `defaultsWithChange`); QML doesn't notice in-place changes.
  `pushButtons()` skips a push identical to the last one (`lastPushedButtons`).
  Only one `Panel` serves IPC at a time (`service.ipcOwner`).

## Key files

| File | Role |
|------|------|
| `scripts/streamdeck-bridge` | The Python bridge. **Most logic lives here.** ~1,570 lines. |
| `Model.js` | Config schema (v3), parsing/migration, `hasAction()`, `actionSummary()`, layouts, `newProfile()`. |
| `Service.qml` | Singleton: profiles, `applyProfile()`, `ensureDeviceProfile()`, `pushButtons()`, `setBrightness()`, `handleEvent()` (incl. `swipe`), timers. |
| `Panel.qml` | Bar widget + config panel UI (grid, profile mgmt, dial/strip display, button editor, IPC). |
| `BridgeController.qml` | Process management (spawn, pipe stdin/stdout). |
| `scripts/StreamDeck/` | Vendored `streamdeck` Python package (MIT). `Devices/StreamDeckPlus.py` is the device. |
| `manifest.json` | Plugin declaration (id `elgato.streamdeck`, entry points). |
| `BUGS.md` | Review findings and their status. |

## Locations

| What | Path |
|------|------|
| Plugin dir | `~/.config/omarchy/plugins/elgato.streamdeck/` (the shell finds the bridge relative to `Service.qml`) |
| Config (profiles/buttons/brightness) | `~/.config/omarchy/streamdeck/buttons.json` |
| Icons (official Elgato SVGs + uploads) | `~/.config/omarchy/streamdeck/icons/` |
| Bridge log | `~/.cache/omarchy-streamdeck-bridge.log` (rotated to `.log.1` past 1 MB at bridge start) |
| udev rule | `/etc/udev/rules.d/40-streamdeck.rules` (`MODE="0666"` for `0fd9:0084`) |

## Current configuration (as of last edit)

Config is **schema v3**:
`{ version, activeProfileId, profiles: [{id,name,layout,buttons[]}], defaults:{xl,original,plus}, brightness, pinnedApps? }`.
Each button: `{ index (0-7), label, icon_path, action_type, action_value }`.

**Key indexing is row-major, top-to-bottom:** `0-3` = top row, `4-7` = bottom row.

- **Page 1** (`id: "plus"`, the active + default profile):
  - key 1 **Night** → `omarchy-toggle-nightlight` (icon `night.svg`)
  - key 2 **Lock** → `omarchy-system-lock` (icon `lock.svg`)
  - key 3 **Discord** → `omarchy-launch-webapp https://discord.com/channels/@me` (icon `logo-discord.svg`)
  - key 4 **Audio out** → `action_type: "audio_output"` (composite volume icon + live device name; cycles output on press)
  - key 7 **Element** → `element-desktop` (icon `speech.svg`)
  - keys 0, 5, 6 empty
- **Page 2** (`id: "page2"`): all 8 keys are **test keys** (`"2·1"`…`"2·8"`, command `true`).
  Delete/replace this once real profiles are built.

**Dials (hardcoded in the bridge, `_dial_turn` / `_dial_push`):** turn = volume ±, push = mute toggle.
- dial 0: `wpctl set-volume @DEFAULT_AUDIO_SINK@` / `wpctl set-mute @DEFAULT_AUDIO_SINK@`
- dial 1: focused-app stream via `pactl set-sink-input-volume <idx>` (finds stream from `hyprctl activewindow`;
  does nothing when no window is focused)
- dial 2: `wpctl set-volume @DEFAULT_AUDIO_SOURCE@` / mic mute
- dial 3: pinned-app stream (auto-detect) via `pactl set-sink-input-volume <idx>`.
  The apps it looks for come from `pinnedApps` in `buttons.json` if set, else
  `PINNED_APPS` in the bridge (Element, then Brave as web-app Discord).

**Touch strip (800×100, 4 tiles of 200×100):**
- x=0-200 volume, x=200-400 app, x=400-600 mic, x=600-800 pinned.
- **Tap** a tile → toggle that tile's mute. **Swipe** (drag ≥60px, mostly horizontal) → page profiles.
- Tiles only update on dial turn/tap (no background refresh) — that's intentional.
- Tile drawing shares helpers (`_new_tile`, `_draw_tile_value`, `_draw_tile_caption`,
  `_send_tile`, `_update_level_tile`).

## Action types

Set in the panel's button editor, or in `buttons.json`:
- **`command`** — run a shell command (detached `subprocess.Popen`, own session, no stdin). Most keys.
- **`keybinding`** — send a key combo (`SUPER+ALT+Return`, `CTRL+SHIFT+t`,
  `XF86AudioRaiseVolume`) through `wtype`, or `ydotool` (needs `ydotoold`) if `wtype`
  is missing. Both go through a virtual keyboard, so Hyprland binds fire. Modifiers:
  `SUPER`/`WIN`/`CMD`, `CTRL`/`CONTROL`, `ALT`, `SHIFT`; anything else is rejected and logged.
- **`audio_output`** — special (see below). `action_value` is empty. `hasAction()` returns true for it.
- **`magnitude`** — personal: a shell command (like `command`) that toggles the local
  Magnitude model, plus a live label. Not in the panel's type picker; set it in
  `buttons.json`. See below.

### `audio_output` (the live audio key)
- Renders a **composite icon**: Elgato `volume.svg` glyph (48px, fg-tinted) + the **current
  default output device name** wrapped at the bottom (max 2 lines). Black bg, no border
  (matches the other icons). See `_generate_glyph_label_icon()`.
- **On press** → cycles the default output via `omarchy-audio-output-switch` (matches the
  status bar), on a **background thread** (`_handle_audio_cycle`) so the reader thread isn't blocked.
- **On external change** → a **3s poll** (`_maybe_refresh_audio_keys`, on the stdin-queue
  timeout) redraws the key **only when the device name actually changes** (no flicker).
- The device name prefers the bracketed tag (e.g. `WaveShare-119`) from the sink description.
- You can put an `audio_output` key on **any** key in **any** profile.

### `magnitude` (local model toggle)
- `action_value` is the toggle script, run like a `command`.
- The key shows `server.svg` above `<model name> ON|OFF|<transitional state>`
  (`_generate_magnitude_icon`, `_magnitude_label`).
- State comes from `~/.magnitude/state/models.json` (primary slot) and
  `/usr/lib/magnitude-desktop/resources/magnitude models status <id>`, falling back
  to `pgrep` on the inference worker.
- Polls every 0.5 s for 15 s after a press, and while the state is transitional;
  otherwise every 3 s.
- Machine-specific: keep it out of anything sent upstream.

## Icons

- Official Elgato SVGs live in `~/.config/omarchy/streamdeck/icons/` (24×24, `fill="currentColor"`).
- A button's `icon_path` may point to an **`.svg`** anywhere (rendered via `rsvg-convert`,
  tinted with the theme **foreground** color, centered at `ICON_GLYPH_SIZE=48` on black)
  **or a raster** (PNG/JPEG, resized to fill). Failed SVG renders are cached until the
  theme changes.
- The panel's **Upload icon** copies the chosen file to
  `icons/<profile>_btn<n>_<timestamp>.<ext>`; it only fills the draft until you click Save.
  Old uploads are not cleaned up.
- To add an official icon: copy the SVG from the `elgatosf/icons` GitHub repo (`svg/l/` = 24px,
  `svg/m/` = 20px) into the icons dir, then set the button's `icon_path` to the full path.
- Current icons: `volume.svg`, `volume-muted.svg`, `microphone.svg`, `microphone-off.svg`,
  `sound-effect.svg` (touch strip), `server.svg` (magnitude key), plus `night.svg`,
  `lock.svg`, `logo-discord.svg`, `speech.svg` (keys).
- There is **no Element logo** in the Elgato set — `speech.svg` (chat bubble) is the stand-in.

## How to make changes

**Edit a key / profile:**
- Easiest: open the panel (bar widget → Stream Deck) and click a key.
- Or edit `~/.config/omarchy/streamdeck/buttons.json` directly. The shell reloads it on
  change (`onFileChanged`); a restart is the fallback if something looks stale.

**Restart (picks up bridge + QML + config changes):**
```bash
omarchy restart shell
sleep 12
omarchy-shell elgato.streamdeck status
```

**Check state / log:**
```bash
omarchy-shell elgato.streamdeck status
tail -f ~/.cache/omarchy-streamdeck-bridge.log
grep -iE "error|traceback|audio_key|set_buttons" ~/.cache/omarchy-streamdeck-bridge.log
```

**IPC commands:**
```bash
omarchy-shell elgato.streamdeck status
omarchy-shell elgato.streamdeck reconnect
omarchy-shell elgato.streamdeck toggle
omarchy-shell elgato.streamdeck setButton <index> "<label>" <command|keybinding|audio_output> "<value>" "<icon_path>"
omarchy-shell elgato.streamdeck clearButton <index>
omarchy-shell elgato.streamdeck setBrightness <0-100>
```

**After editing the Python bridge:** always `python3 -m py_compile scripts/streamdeck-bridge`
then restart the shell.

**Committing:** this repo belongs to a personal GitHub account; see `CLAUDE.local.md`
for how commits are made.

## Debugging

- **Log:** `~/.cache/omarchy-streamdeck-bridge.log` (JSON lines). Events go to both
  stdout (for the shell) and the log; `{"ev":"debug"}` lines go to the log only.
- `status` → `phase` (`ready`/`idle`/`error`), `configured` (count of action-bearing keys), `activeProfileId`.
- **Audio key not updating?** Cycle the output (`omarchy-audio-output-switch`) and watch for
  `{"ev":"audio_key","label":...}` within ~3s.
- **Swipe not paging?** Look for `strip drag x0=... dx=... dy=...` debug lines — if drags never
  fire or `dx` is always 0, the DRAG event shape differs from what `_handle_strip_swipe` expects.
  Swipes only page through profiles whose layout matches the connected deck.
- **Key press not acting?** Look for `_handle_press(N)` + `action[N]` errors, and
  `Keybinding '…'` errors for rejected combos.
- **Unplugged deck:** detected within ~3 s (`{"ev":"disconnected","reason":"device lost"}`);
  the shell retries every 10 s, so a replug reconnects on its own.
- **Deck stuck/blank after a firmware wedge:** physically **unplug/replug** the USB cable, then
  `omarchy-shell elgato.streamdeck reconnect` if it doesn't come back by itself.

## Known quirks & pitfalls (this box)

- **pactl build is finicky** (pactl 17.0, PipeWire-backed). Do NOT use:
  - `pactl list --brief sink-inputs` (rejected)
  - `pactl get-sink-input-volume <idx>` / `get-sink-input-mute <idx>` ("No valid command")
  - **relative** volume changes like `set-sink-input-volume <idx> "2%+"` ("Invalid volume specification")
  - **Do use:** `pactl list sink-inputs` (parse `Sink Input #N` blocks) and **absolute**
    `pactl set-sink-input-volume <idx> "50%"`. That's why the bridge parses blocks and sets absolute values.
- **Per-app volume only works while the app is producing audio** (no stream = nothing to grab).
  PipeWire stream-restore remembers per-app volumes across stream recreations.
- **Discord is a web app** (`omarchy-launch-webapp https://discord.com/...` → Brave `--app` mode).
  Its audio is a **Brave** stream, so dial 3 / tap-mute "Discord" actually controls Brave's stream —
  which could be a non-Discord tab. Inherent limitation.
- **Default sink:** read the configured default from `wpctl status`; `pactl info` shows the
  runtime default which can lag. `_default_sink()` prefers `pactl get-default-sink`.
- **Brightness:** `brightnessctl` here only sees a scroll-lock LED. Use
  `omarchy-brightness-display ±10%` (DDC/CI, external monitor) for real screen brightness.
- **`omarchy-capture-screenshot --help` does NOT print help — it takes a screenshot** (and can hang
  on selection). Don't run it casually; the user doesn't use a screenshot key.
- **Hyprland:** `hyprctl windows` is "unknown request" on this build — use `hyprctl activewindow -j`.
  `hyprctl dispatch <subcmd>` works (workspace, fullscreen, togglefloating, split, killclient, ...).
  `hyprctl dispatch sendshortcut` sends keys to a window and **skips Hyprland binds**, so it is not
  used for keybinding keys.
- **Reinstalling from upstream loses the fork.** `omarchy plugin install` with the
  `Fragggy/…` URL replaces it; install from the fork's `streamdeck-plus` branch instead.

## What the fork adds on top of upstream

Upstream already has the v3 profile schema and profile UI. The fork adds:

1. **Stream Deck + support** — `_find_deck()` accepts `"Stream Deck +"` and registers the
   dial and touchscreen callbacks; `Model.js` has a `plus` layout; a Plus profile and
   default are created automatically if a config has none (`ensureDeviceProfile`).
2. **Dials** — `_on_dial()` → `_dial_turn()` / `_dial_push()` on the task worker,
   `_find_app_stream()`, `_find_pinned_stream()`, configurable pinned apps.
3. **Touch strip** — `_on_touchscreen()` → `_touch_tap()` (tap-to-mute per tile),
   `_handle_strip_swipe()` (page profiles), and the 4 tile renderers.
4. **Swipe paging** — `Service.qml` `handleEvent` `case "swipe"`.
5. **`audio_output` and `magnitude` action types** — see above.
6. **SVG icon support** — `_get_icon()` renders `.svg` `icon_path`s via `rsvg-convert`.
7. **stdin via reader thread + queue** in `run()`.
8. **Bug fixes** for everything listed in `BUGS.md` (upstream and fork), e.g. unplug
   detection, keybindings, icon uploads, IPC, saved brightness.

## Useful tools on this box

| Purpose | Command |
|---------|---------|
| Cycle audio output (matches status bar) | `omarchy-audio-output-switch` |
| Mute default sink | `pactl set-sink-mute @DEFAULT_SINK@ toggle` |
| Screen brightness (DDC) | `omarchy-brightness-display +10%` / `-10%` |
| Night light | `omarchy-toggle-nightlight` |
| Lock | `omarchy-system-lock` |
| Launch-or-focus an app | `omarchy-launch-or-focus <app>` (foot, brave, nautilus, ...) |
| Launch web app | `omarchy-launch-webapp <url>` |
| Fullscreen toggle | `omarchy-hyprland-window-tiled-fullscreen-toggle` |
| Record screen | `omarchy-capture-screenrecording` |
| Windows/workspaces | `hyprctl dispatch workspace N` / `fullscreen 1` / `togglefloating` / `split` / `killclient` |

Audio sinks (4 visible in the status bar): `WaveShare-119`, `AW3423DWF`, `Scarlett 2i2`, `S/PDIF`.
Mic source: `alsa_input.usb-Focusrite_Scarlett_2i2_USB_...-00.HiFi__Mic1__source`.
Font used for rendering: `/usr/share/fonts/liberation/LiberationSans-Regular.ttf`.
