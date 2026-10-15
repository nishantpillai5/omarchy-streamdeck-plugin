# Known bugs and review findings

Code review from 2026-10-15. Nothing here has been tested on hardware yet;
each finding comes from reading the code.

- **Upstream** = `Fragggy/omarchy-streamdeck-plugin` at `6db254a` (same as local
  `master`). Line numbers refer to that version.
- **Fork** = `origin/streamdeck-plus` (`890f0ea`, Stream Deck Plus support).
  Line numbers refer to that branch.

Every upstream bug is also present on the fork unless marked otherwise.

---

## Upstream bugs

### U1. Unplugging the deck is never detected, and replugging doesn't reconnect — fixed on fork
- `scripts/StreamDeck/Devices/StreamDeck.py:207-209` (vendored): on `TransportError`
  the reader thread stops and closes the device without telling anyone.
- `scripts/streamdeck-bridge:438`: `disconnected` is only sent from `disconnect()`,
  which only runs on a `reconnect` op.
- `Service.qml:294`: the 10-second auto-connect timer does nothing while `phase === "ready"`.

**Effect:** after an unplug the shell still shows "ready", and after a replug the deck
stays dead until you reconnect by hand. On the fork, the dials and touch strip die too.

**Fix:** check `deck.connected()` regularly (the fork's main-loop timeout is a natural
place) and send `disconnected` when it drops.

### U2. Every Ctrl combo fails through `wtype` — fixed on fork
`scripts/streamdeck-bridge:303, 340`. For `ctrl` the bridge passes `-M control` / `-m control`
to `wtype`, but `wtype` only knows `shift`, `ctrl`, `alt`, `logo`, `win`, `capslock` and
`altgr`. It exits with "Invalid modifier name", so no Ctrl shortcut works. A `CONTROL`
modifier written in a combo is also silently dropped.

*Correction:* the first version of this file said `key.capitalize()` breaks names like
`slash` and `XF86AudioRaiseVolume`. It doesn't: `wtype` looks key names up
case-insensitively (`XKB_KEYSYM_CASE_INSENSITIVE`). Only the `ydotool` fallback cared
about the key's name.

**Fix:** map `ctrl`/`control` to `wtype`'s `ctrl`, report unknown modifiers instead of
dropping them, and pass the key through as typed.

### U3. The `hyprctl` and `ydotool` keybinding fallbacks are broken — fixed on fork
- `:363`: runs `hyprctl dispatch exec "ydotool key SUPER_ALT_RETURN"`, which isn't valid
  `ydotool` input. Hyprland's `sendshortcut` isn't a replacement: it sends keys straight
  to a window and skips Hyprland's own binds, which is what most deck keys trigger.
  The branch has been removed.
- `:382`: the direct `ydotool` route sends `125:1 56:1 a`. It presses modifiers but never
  releases them (`:0`), and `a` isn't a keycode, so modifiers could stay stuck. It now
  maps keys to Linux key codes and releases everything it presses.

### U4. Custom icons from different profiles overwrite each other — fixed on fork
`Panel.qml:172, 188`. Uploads are saved as `icons/btn_<index>.png`, with no profile in the
name, so button 0 in profile B overwrites button 0's icon in profile A. QML's image cache
can also keep showing the old picture.

**Fix:** include the profile id (or a content hash) in the file name.

### U5. A file name can break, or inject into, the icon copy command — fixed on fork
`Panel.qml:173`. The chosen path is put inside single quotes in a `bash -c` string, so a
name containing `'` breaks the command or runs arbitrary code.

**Fix:** pass the paths as arguments:
`["sh", "-c", 'mkdir -p "$1" && cp "$2" "$3"', "sh", dir, src, dst]`.

### U6. Uploading an icon saves the form and closes it — fixed on fork
`Panel.qml:190`. `copyIconProc.onExited` calls `saveEdit()`, which saves half-typed
label/action text and closes the editor. It reads `editingIndex` after the copy finishes,
so if the user has moved on by then, the icon lands on the wrong button.

### U7. Changing profiles in place doesn't refresh the panel — fixed on fork
`Service.qml:148, 159, 167, 183-185, 199`. `push`, `splice`, swapping entries,
`p.name = …` and `defaults[k] = …` change `profiles`/`defaults` in place, and QML
doesn't notice in-place changes. The panel only refreshes because saving the file makes
the file watcher reload it, which also pushes the buttons to the device twice. Commit
`6db254a` worked around the same problem for button saves only.

**Fix:** assign new arrays/objects instead (`profiles = profiles.concat([p])`, etc.).
Pushes are also skipped when the buttons haven't changed since the last one, so the
reload after a save no longer redraws every key.

### U8. IPC commands are probably broken — fixed on fork
- `Panel.qml:216, 231, 240`: `setButton`, `clearButton` and `setBrightness` have untyped
  arguments. Quickshell's `IpcHandler` needs typed arguments, so these are probably not
  callable, including the README example. *(Not checked against a running shell.)*
- The `IpcHandler` lives in `Panel.qml`, which exists once per monitor, so the same IPC
  target is registered more than once. With no bar widget there's no IPC at all.
- `Panel.qml:242`: `Number(value) || 50` turns `setBrightness 0` into 50.

**Fix:** typed arguments; `setBrightness` validates 0–100. The handler stays in
`Panel.qml` (its `toggle`/`open` need a panel), but only one panel enables it: the first
to load claims it through the service, and another takes over if that one goes away.
Still true: with no bar widget there's no IPC.

### U9. Brightness isn't saved, and the manifest setting is ignored — fixed on fork
The `brightness` default in `manifest.json` is never read; `Service.qml:27` hard-codes 50.
Changes from the slider are lost when the shell restarts.

**Fix:** brightness is saved as `brightness` in `buttons.json` (written once the slider
settles) and read by the bridge at startup. The unused manifest setting was removed,
since the Omarchy widget-settings API wasn't available to wire it up.

### U10. Launched commands share the bridge's stdin — fixed on fork
`scripts/streamdeck-bridge:275`. `Popen(action_value, shell=True)` inherits the bridge's
stdin, which is the pipe the shell sends commands on, so a child that reads stdin can
steal them. Children also stay tied to the bridge's process group and lifetime.

**Fix:** `stdin=subprocess.DEVNULL, start_new_session=True`.

### Smaller upstream issues
All fixed on the fork unless noted.
- **Startup config load is dead code** (`main()`, `:523`): it reads a top-level
  `buttons` key that the v3 format doesn't have, so it loads nothing. *(Fixed on the fork.)*
- **The icon cache never helps** (`:202-208`): it shares one key for all buttons,
  is cleared on every `set_buttons`, and stores a `str` key in a `dict[int, bytes]`.
  *(Fixed on the fork.)*
- **The log file grows forever**: every event and debug line is appended to
  `~/.cache/omarchy-streamdeck-bridge.log`. Debug lines also go to stdout, where the
  shell parses each one. *(Now rotated to `.log.1` past 1 MB at startup; debug lines
  go to the file only.)*
- **Output lines can mix together**: `log()` is called from the main thread and the
  device thread, and `print` can interleave their partial lines.
- **Slow key handling**: `subprocess.run(["which", …])` runs on every key press (use
  `shutil.which`), and `time.sleep(0.05)` runs on the device thread.
- **Fast presses are dropped**: the 300 ms debounce throws away legitimate quick taps,
  such as repeated volume-up. *(Now 100 ms; untested against real key bounce.)*
- **Duplicate profile ids**: `Model.js` `parseConfig` gives id-less profiles
  `Date.now()` ids, so profiles parsed in the same millisecond get the same id.
- **Theme colours with transparency are read wrong**: QML prints them as `#aarrggbb`,
  and `_hex_to_rgb` takes the first six hex digits.
- **The `e` key** opens the editor for button 0 even before the cursor is active.
- **`_lock`** is never used (upstream). *(The fork uses it for HID writes.)*
- **Outdated docs and text**: the README shows the v1 config format; the bridge docstring
  and manifest still say XL-only; the missing-dependency message tells you to install
  `python3-streamdeck`, which is already bundled; the `"Stream Deck Original V2"` string
  in `_find_deck` never matches (V2 reports `"Stream Deck Original"`).
- **Design**: the grid size follows the active profile, not the connected device, so an
  XL profile on an Original quietly shows only 15 keys. *(Not changed: swipe and device
  defaults now keep each device on its own profiles.)* `pluginDir` is hard-coded rather
  than worked out from where the plugin is installed. *(Now taken from where
  `Service.qml` was loaded, falling back to the default install path.)*

---

## Fork bugs (`streamdeck-plus`)

### F1. With no focused window, dial 2 changes a random app's volume — fixed
`scripts/streamdeck-bridge:723` (`_find_app_stream`). On an empty workspace
`_focused_window()` returns `("", "")`. Then `cl in c` is `"" in c`, which is always
true, so every stream scores 80 and the first one wins. Dial 2 (push and turn) and the
app tile on the touch strip act on an arbitrary stream.

**Fix:** return `None` when both class and title are empty.

### F2. Swiping pages through profiles for other devices — fixed
`Service.qml` `case "swipe"` goes through every profile. A fresh config has XL, Original
and Plus profiles, so swiping on a Plus loads the 32-key XL profile: only keys 0–7 show
and the panel switches to an 8×4 grid. Each swipe also runs `applyProfile` →
`saveConfig` (a file write, a reload and two pushes to the device).

**Fix:** only go through profiles whose `layout` matches the connected device.

### F3. Existing users never get a Plus profile — fixed
Only `Model.emptyConfig()` creates a `plus` profile. Upgraded v3 configs and the v1/v2
migrations get `defaults.plus = ""` and no Plus profile, so a connected Plus shows
whichever profile was active (usually XL).

**Fix:** when a Plus connects and has no default, create a Plus profile and make it the default.

### F4. Dial and touch handling blocks the reader thread — fixed
`_on_dial` / `_on_touchscreen` run on the library's single reader thread and call
external programs synchronously. One notch on dial 1 runs `wpctl set`, `wpctl get` and
`pactl get-sink-mute`. Dial 4 runs `pactl list sink-inputs` up to 5 times (once per
`PINNED_APPS` term) and again for the indicator. Key presses and later notches queue
behind this, so volume lags and overshoots.

**Fix:** move the work off the reader thread (as already done for `_handle_audio_cycle`),
list sink inputs once and match all terms against that, and merge rapid notches.

### F5. A temp file leaks on every icon render when `rsvg-convert` fails — fixed
`_render_official_icon` (`:172-186`). The temporary `.svg` is only deleted on success,
and failures aren't cached. The strip tiles re-render on every dial notch, so a missing
`rsvg-convert` leaves a new file in `/tmp` each time. `rsvg-convert` (librsvg) also isn't
listed as a dependency.

**Fix:** clean up in `try/finally`, cache failures, and document the dependency.

### F6. SVG icons only load from the icons folder — fixed
`_get_icon` (`:374-378`) reduces an `.svg` `icon_path` to its file name and loads it from
`~/.config/omarchy/streamdeck/icons/`. An SVG anywhere else quietly falls back to the
text label. The panel's upload dialog only accepts `*.png`.

### F7. Two neighbouring panel buttons are both labelled "+" — fixed
The new-profile row in `Panel.qml` has the Plus-layout button right next to the Create
button, and both read `+`.

### F8. On XL/Original, the touch-strip check never filters anything — fixed
`hasattr(self.deck, "set_touchscreen_image")` is always true, because every device
class defines that method (it does nothing on non-Plus decks). So `connect()` on an
XL/Original still runs about a dozen `wpctl`/`pactl`/`hyprctl` calls and draws four
tiles that go nowhere.

**Fix:** check `self.deck.TOUCHSCREEN_PIXEL_WIDTH > 0`.

### Things to tidy on the fork
- **Undocumented `magnitude` action type**: it hard-codes
  `/usr/lib/magnitude-desktop/...` and `~/.magnitude/state/models.json`, polls every
  0.5 s, and isn't in the commit message, `AGENT_NOTES.md` or the panel's edit form.
  It's specific to this machine; keep it out of anything sent upstream.
- **`PINNED_APPS`** (Element, and Brave treated as Discord) is specific to this setup.
  Make it configurable before sending upstream.
- **Dead code**: `_update_audio_key`, `_update_element_key`, `AUDIO_KEY`,
  `_clear_strip_sections`.
- **Copy-pasted drawing code**: `_generate_audio_icon` / `_generate_magnitude_icon`
  are near-copies, and so are the four `_update_*_indicator` tile functions. Shared
  helpers would remove about 200 lines.
- **Outdated header**: the bridge docstring still describes the XL-only protocol, with
  no dials, touch, `swipe`, `audio_output` or `magnitude`.
- **`_magnitude_state` fallback**: the `pgrep` call in its fallback can raise outside a
  `try`, which logs a "Command error" on every poll.
- **`AGENT_NOTES.md` mistakes**:
  - it says the log goes to the file "not stdout", but `log()` writes to both
  - it lists profiles as a local patch, but they're upstream (`78cb619`)
  - it says the bridge is ~1,300 lines; it's about 1,530 now
  - it names this machine's audio devices and mic source in a public repo

### What the fork already fixes from upstream
- per-button icon cache (`_cache_keys`)
- `main()` reads the v3 config
- stdin is read through a thread and queue (avoids the `select()` deadlock)
- HID writes are serialised with an `RLock`; audio cycling runs off the reader thread

---

## Suggested order
1. ~~F1, F2, F4~~ (all F items fixed).
2. ~~U1~~ (fixed).
3. ~~U2, U3~~ (fixed).
4. ~~U4, U5, U6~~ (fixed).
5. ~~U7–U10 and the smaller issues~~ (fixed).

Fixes that only touch upstream code (U2–U10) could be sent upstream as PRs.
