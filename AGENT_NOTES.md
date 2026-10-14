# Stream Deck Plus — Agent Notes

> Read this before touching the Stream Deck setup. This documents the **heavily
> patched** local version of the `elgato.streamdeck` Omarchy shell plugin, wired up
> for an **Elgato Stream Deck Plus**. The upstream `README.md` describes the
> *unmodified* plugin and is mostly out of date for this box.

## TL;DR

- Device: **Elgato Stream Deck Plus** (`0fd9:0084`) — **8 keys (4×2)**, **4 dials**, **touch strip** (800×100).
- Plugin: Omarchy shell plugin `elgato.streamdeck`, installed from
  `Fragggy/omarchy-streamdeck-plugin` and **patched locally** (see "Patches" below).
- **No reserved keys.** All 8 keys are profile-driven and editable in the panel.
  Audio cycling and Element launch are *regular* command keys, not special-cased.
- **Profiles** = pages of 8 keys. **Swipe left/right on the touch strip** to page
  between profiles (wraps).
- **4 dials** are always audio (never remapped per profile):
  `0=system volume`, `1=focused-app volume`, `2=mic input`, `3=pinned-app call volume (auto-detect Element→Discord/Brave)`.
- **Touch strip** shows 4 status tiles (one per dial) + tap-to-mute per tile.
- The Python **bridge** runs **unsandboxed** as a child of the shell process and
  talks to it over **stdin/stdout JSON**.

## Architecture / data flow

```
Panel.qml  (bar widget + config UI)
   │  calls functions on the Service singleton
Service.qml (singleton: owns profiles, config, active profile)
   │  bridgeController.send({op: ...})   /   onLine → handleEvent(ev)
BridgeController.qml  (spawns + pipes the Python bridge)
   │  stdin: JSON ops        stdout: JSON events
scripts/streamdeck-bridge  (Python: device I/O, icon rendering, audio, actions)
   │  ctypes + hidapi (vendored StreamDeck/ package)
Stream Deck Plus hardware
```

- The bridge is a **long-lived Python process**. The shell starts it, sends ops
  (`config`, `set_buttons`, `set_brightness`, `reconnect`, `exit`), and reads events
  (`ready`, `disconnected`, `error`, `swipe`, `button_down/up`, `audio_key`, debug).
- **Two threads inside the bridge**:
  - **Reader thread** (from the vendored device lib): fires `key`/`dial`/`touchscreen`
    callbacks → `_on_key_change`, `_on_dial`, `_on_touchscreen`.
  - **Main thread**: reads stdin ops via a **reader-thread + `queue.Queue`** (see
    Patches — do NOT use `select()` on `sys.stdin`; it deadlocks).
  - All hardware writes (`set_key_image` / `set_touchscreen_image`) go through the
    locked helpers `_set_key_image` / `_set_touchscreen_image` (`self._lock`, an `RLock`).
    Keep it that way.

## Key files

| File | Role |
|------|------|
| `scripts/streamdeck-bridge` | The Python bridge. **Most logic lives here.** ~1300 lines. |
| `Model.js` | Config schema (v3), `hasAction()`, `actionSummary()`, layouts, `newProfile()`. |
| `Service.qml` | Singleton: profiles, `applyProfile()`, `pushButtons()`, `handleEvent()` (incl. `swipe`), timers. |
| `Panel.qml` | Bar widget + config panel UI (grid, profile mgmt, dial/strip display, button editor). |
| `BridgeController.qml` | Process management (spawn, pipe stdin/stdout). |
| `scripts/StreamDeck/` | Vendored `streamdeck` Python package (MIT). `Devices/StreamDeckPlus.py` is the device. |
| `manifest.json` | Plugin declaration (id `elgato.streamdeck`, entry points). |

## Locations

| What | Path |
|------|------|
| Plugin dir | `~/.config/omarchy/plugins/elgato.streamdeck/` |
| Config (profiles/buttons) | `~/.config/omarchy/streamdeck/buttons.json` |
| Icons (official Elgato SVGs) | `~/.config/omarchy/streamdeck/icons/` |
| Bridge log | `~/.cache/omarchy-streamdeck-bridge.log` |
| udev rule | `/etc/udev/rules.d/40-streamdeck.rules` (`MODE="0666"` for `0fd9:0084`) |

## Current configuration (as of last edit)

Config is **schema v3**: `{ version, activeProfileId, profiles: [{id,name,layout,buttons[]}], defaults:{xl,original,plus} }`.
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

**Dials (hardcoded in the bridge, `_on_dial`):** turn = volume ±, push = mute toggle.
- dial 0: `wpctl set-volume @DEFAULT_AUDIO_SINK@` / `wpctl set-mute @DEFAULT_AUDIO_SINK@`
- dial 1: focused-app stream via `pactl set-sink-input-volume <idx>` (finds stream from `hyprctl activewindow`)
- dial 2: `wpctl set-volume @DEFAULT_AUDIO_SOURCE@` / mic mute
- dial 3: pinned-app stream (auto-detect) via `pactl set-sink-input-volume <idx>`

**Touch strip (800×100, 4 tiles of 200×100):**
- x=0-200 volume, x=200-400 app, x=400-600 mic, x=600-800 pinned.
- **Tap** a tile → toggle that tile's mute. **Swipe** (drag ≥60px, mostly horizontal) → page profiles.
- Tiles only update on dial turn/tap (no background refresh) — that's intentional.

## Action types

Set in the panel's button editor, or in `buttons.json`:
- **`command`** — run a shell command (detached `subprocess.Popen`). Most keys.
- **`keybinding`** — send a key combo (`SUPER+ALT+Enter`); tries `wtype`, then `hyprctl`/`ydotool`.
- **`audio_output`** — special (see below). `action_value` is empty. `hasAction()` returns true for it.

### `audio_output` (the live audio key)
- Renders a **composite icon**: Elgato `volume.svg` glyph (48px, fg-tinted) + the **current
  default output device name** wrapped at the bottom (max 2 lines). Black bg, no border
  (matches the other icons). See `_generate_audio_icon()`.
- **On press** → cycles the default output via `omarchy-audio-output-switch` (matches the
  status bar), on a **background thread** (`_handle_audio_cycle`) so the reader thread isn't blocked.
- **On external change** → a **3s poll** (`_maybe_refresh_audio_keys`, on the stdin-queue
  timeout) redraws the key **only when the device name actually changes** (no flicker).
- The device name prefers the bracketed tag (e.g. `WaveShare-119`) from the sink description.
- You can put an `audio_output` key on **any** key in **any** profile.

## Icons

- Official Elgato SVGs live in `~/.config/omarchy/streamdeck/icons/` (24×24, `fill="currentColor"`).
- A button's `icon_path` may point to an **`.svg`** (rendered via `rsvg-convert`, tinted with the
  theme **foreground** color, centered at `ICON_GLYPH_SIZE=48` on black) **or a raster** (PNG, resized to fill).
- To add an icon: copy the SVG from the `elgatosf/icons` GitHub repo (`svg/l/` = 24px, `svg/m/` = 20px)
  into the icons dir, then set the button's `icon_path` to the full path.
- Current icons: `volume.svg`, `volume-muted.svg`, `microphone.svg`, `microphone-off.svg`,
  `sound-effect.svg` (touch strip), plus `night.svg`, `lock.svg`, `logo-discord.svg`, `speech.svg` (keys).
- There is **no Element logo** in the Elgato set — `speech.svg` (chat bubble) is the stand-in.

## How to make changes

**Edit a key / profile:**
- Easiest: open the panel (bar widget → Stream Deck) and click a key.
- Or edit `~/.config/omarchy/streamdeck/buttons.json` directly, then **restart** (below).
  The shell also auto-reloads on file change (`onFileChanged`), but a restart is the reliable path.

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
```

**After editing the Python bridge:** always `python3 -m py_compile scripts/streamdeck-bridge`
then restart the shell.

## Debugging

- **Log:** `~/.cache/omarchy-streamdeck-bridge.log` (JSON lines; bridge writes here, not stdout).
- `status` → `phase` (`ready`/`idle`/`error`), `configured` (count of action-bearing keys), `activeProfileId`.
- **Audio key not updating?** Cycle the output (`omarchy-audio-output-switch`) and watch for
  `{"ev":"audio_key","label":...}` within ~3s.
- **Swipe not paging?** Look for `strip drag x0=... dx=... dy=...` debug lines — if drags never
  fire or `dx` is always 0, the DRAG event shape differs from what `_handle_strip_swipe` expects.
- **Key press not acting?** Look for `_handle_press(N)` + `action[N]` errors.
- **Deck stuck/blank after a firmware wedge:** physically **unplug/replug** the USB cable, then
  `omarchy-shell elgato.streamdeck reconnect`.

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
- **Patches are local and lost on re-clone.** Re-running `omarchy plugin install <url>` wipes them.

## Patches applied to the upstream plugin (re-apply if re-cloned)

All in the local copy; **none are upstream**. If the plugin is re-cloned, redo these:

1. **Device whitelist** — `_find_deck()` accepts `"Stream Deck +"` (upstream only lists
   XL/Original/Original V2). Also registers `set_dial_callback` + `set_touchscreen_callback`.
2. **Dials** — `_on_dial()` implements the 4 audio dials (turn/push) + `_find_app_stream()`,
   `_find_pinned_stream()`, `PINNED_APPS`.
3. **Touch strip** — `_on_touchscreen()` (tap-to-mute per tile), `_handle_strip_swipe()` (page
   profiles), and the 4 indicator renderers (`_update_volume/mic/app/pinned_indicator`).
4. **Profiles + swipe** — `Model.js` schema v3 (profiles), `Service.qml` `applyProfile()` +
   `handleEvent` `case "swipe"`, `Panel.qml` profile UI. No reserved keys.
5. **`audio_output` action type** — `Model.hasAction`/`actionSummary`, `Panel.qml` "Audio out"
   radio, bridge `_generate_audio_icon()` + `_handle_audio_cycle()` + 3s poll in `run()`.
6. **SVG icon support** — `_get_icon()` renders `.svg` `icon_path` via `rsvg-convert` (fg-tinted,
   centered at `ICON_GLYPH_SIZE` on black).
7. **`run()` stdin via reader-thread + queue** (NOT `select()` on `sys.stdin` — that deadlocks when
   two ops arrive in one read chunk).
8. **Icon cache** — per-index `_cache_keys` (a single global key never hits with mixed labels).
9. **Thread-safe HID writes** — `_set_key_image` / `_set_touchscreen_image` under `self._lock` (`RLock`);
   audio switch runs on a background thread (`_handle_audio_cycle`).
10. **`main()` loads config v3** (active profile's buttons), not the legacy flat `buttons` array.
11. **Panel dial display** — all 4 dials shown assigned; dial 4 labeled "Call" (was "unassigned").

Dead code left in place (harmless, safe to delete): `_update_audio_key`, `_update_element_key`,
`AUDIO_KEY` constant, `_clear_strip_sections`.

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
