# Omarchy Stream Deck Plugin

Omarchy shell plugin for Elgato Stream Deck devices (XL, Original / Original V2 / MK.2, Stream Deck +).

## Features

- **Bar Widget**: Shows connection status in the Omarchy bar
- **Auto-connect**: Connects automatically on startup, notices when the deck is unplugged, and retries every 10s
- **Multi-device**: Supports Stream Deck XL (8×4), Original / V2 / MK.2 (5×3) and Stream Deck + (4×2, dials, touch strip)
- **Profiles**: Several button layouts per device; each device type can have a default profile
- **Configuration Panel**: Visual button grid for mapping buttons to actions
- **Action Types**: Shell commands and keyboard shortcuts (e.g. `SUPER+ALT+Return`)
- **Custom Icons**: Upload a PNG, JPEG or SVG per button via the edit form
- **Brightness Control**: Adjust Stream Deck brightness from the panel (remembered across restarts)
- **Theme Integration**: Auto-generated icons respect current Omarchy theme colors
- **IPC Commands**: Scriptable via `omarchy-shell elgato.streamdeck ...`

## Installation

```bash
omarchy plugin install https://github.com/Fragggy/omarchy-streamdeck-plugin.git --enable
```

The plugin is self-contained: it vendors the `streamdeck` Python package under
`scripts/StreamDeck/` and runs the bridge with system `python3`. Dependencies:

- `python3` (system)
- `python-pillow` (system package)
- `hidapi` (system package, via `libhidapi-libusb.so`)
- `librsvg` (system package, provides `rsvg-convert`; needed for SVG icons)

## Quick Start

1. Install udev rules (see Troubleshooting) so your user can access the device
2. The plugin auto-starts with the Omarchy shell and auto-connects
3. Look for the controller icon in your bar (right section)
4. Click it to open the configuration panel
5. Click any button in the grid to assign an action

## Configuration

Config stored in `~/.config/omarchy/streamdeck/buttons.json`:

```json
{
  "version": 3,
  "activeProfileId": "xl",
  "profiles": [
    {
      "id": "xl",
      "name": "Stream Deck XL",
      "layout": "xl",
      "buttons": [
        {
          "index": 0,
          "label": "Terminal",
          "icon_path": "",
          "action_type": "command",
          "action_value": "alacritty"
        }
      ]
    }
  ],
  "defaults": { "xl": "xl", "original": "", "plus": "" },
  "brightness": 50
}
```

`layout` is `xl` (32 keys), `original` (15 keys) or `plus` (8 keys). `defaults`
names the profile applied automatically when that kind of device connects.
`action_type` is `command`, `keybinding` (e.g. `SUPER+ALT+Return`) or
`audio_output`. `icon_path` may point to a custom PNG, JPEG or SVG (see
"Upload icon" in the panel). Older `version: 1` and `version: 2` files are
migrated automatically.

## IPC Commands

```bash
# Open/close panel
omarchy-shell elgato.streamdeck toggle

# Set a button on the active profile: index label action_type action_value icon_path
omarchy-shell elgato.streamdeck setButton 0 "Firefox" command firefox ""

# Clear a button
omarchy-shell elgato.streamdeck clearButton 0

# Set brightness (0-100)
omarchy-shell elgato.streamdeck setBrightness 70

# Check status
omarchy-shell elgato.streamdeck status

# Reconnect device
omarchy-shell elgato.streamdeck reconnect
```

## Keyboard Shortcuts in Panel

- `← → ↑ ↓` — Navigate grid
- `Enter` / `e` — Edit selected button
- `r` — Reconnect device
- `Esc` — Close panel
- `Tab` — Next panel

## Troubleshooting

**Device not found**: Make sure udev rules are installed:
```bash
sudo cp /usr/share/omarchy/default/udev/40-streamdeck.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**Plugin not showing**: Restart the shell:
```bash
omarchy restart shell
```

## File Structure

```
~/.config/omarchy/plugins/elgato.streamdeck/
├── manifest.json          # Plugin declaration
├── Model.js               # Button config logic
├── Service.qml            # Singleton owning the bridge process
├── Panel.qml              # Bar widget + panel
├── BridgeController.qml   # Process management
└── scripts/
    ├── streamdeck-bridge  # Python helper (device detection, icons, actions)
    └── StreamDeck/        # Vendored `streamdeck` package (MIT)
```
