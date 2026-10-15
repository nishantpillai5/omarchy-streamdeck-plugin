# Omarchy Stream Deck Plugin

Omarchy shell plugin for Elgato Stream Deck devices (XL, Original, Original V2).

## Features

- **Bar Widget**: Shows connection status in the Omarchy bar
- **Auto-connect**: Connects automatically on startup and retries every 10s
- **Multi-device**: Supports Stream Deck XL (8×4), Original, and Original V2 (5×3)
- **Configuration Panel**: Visual button grid for mapping buttons to actions
- **Action Types**: Shell commands and keyboard shortcuts (e.g. `SUPER+ALT+Return`)
- **Custom Icons**: Upload a PNG per button via the edit form
- **Brightness Control**: Adjust Stream Deck brightness from the panel
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
  "version": 1,
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
```

Buttons with an `index` beyond the connected device's key count are stored
but not displayed until a larger device is connected. `icon_path` may point to
a custom PNG (see "Upload PNG" in the panel).

## IPC Commands

```bash
# Open/close panel
omarchy-shell elgato.streamdeck toggle

# Set a button
omarchy-shell elgato.streamdeck setButton 0 "Firefox" command firefox ""

# Check status
omarchy-shell elgato.streamdeck status

# Reconnect device
omarchy-shell elgato.streamdeck reconnect
```

## Keyboard Shortcuts in Panel

- `← → ↑ ↓` — Navigate grid
- `Enter` — Edit selected button
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
