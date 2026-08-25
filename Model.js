// Stream Deck button configuration model.
//
// Persisted in ~/.config/omarchy/streamdeck/buttons.json
// Schema:
// {
//   "version": 1,
//   "buttons": [
//     {
//       "index": 0,           // 0..31 (Stream Deck XL)
//       "label": "Terminal",
//       "icon_path": "",      // optional absolute path to custom image
//       "action_type": "command",     // "command" | "keybinding"
//       "action_value": "alacritty"
//     }
//   ]
// }

var SCHEMA_VERSION = 1;
var BUTTON_COUNT = 32;
// Pass home dir from QML side to avoid Quickshell dependency in JS module
var CONFIG_DIR = "";
var CONFIG_PATH = "";

function setHomeDir(home) {
  CONFIG_DIR = home + "/.config/omarchy/streamdeck";
  CONFIG_PATH = CONFIG_DIR + "/buttons.json";
}

function emptyButton(index) {
  return {
    index: index,
    label: "",
    icon_path: "",
    action_type: "command",
    action_value: ""
  };
}

function emptyConfig() {
  var buttons = [];
  for (var i = 0; i < BUTTON_COUNT; i++) {
    buttons.push(emptyButton(i));
  }
  return {
    version: SCHEMA_VERSION,
    buttons: buttons
  };
}

function parseConfig(text) {
  if (!text || !text.trim()) {
    return { config: emptyConfig(), error: "" };
  }
  try {
    var parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object") {
      return { config: emptyConfig(), error: "Invalid config format" };
    }
    // Normalize button array
    var buttons = [];
    for (var i = 0; i < BUTTON_COUNT; i++) {
      var btn = emptyButton(i);
      if (parsed.buttons && parsed.buttons[i]) {
        var src = parsed.buttons[i];
        if (typeof src.label === "string") btn.label = src.label;
        if (typeof src.icon_path === "string") btn.icon_path = src.icon_path;
        if (typeof src.action_type === "string") btn.action_type = src.action_type;
        if (typeof src.action_value === "string") btn.action_value = src.action_value;
      }
      buttons.push(btn);
    }
    return {
      config: { version: SCHEMA_VERSION, buttons: buttons },
      error: ""
    };
  } catch (e) {
    return { config: emptyConfig(), error: "JSON parse error: " + e.message };
  }
}

function serializeConfig(config) {
  return JSON.stringify(config, null, 2);
}

function exampleConfig() {
  return {
    version: SCHEMA_VERSION,
    buttons: [
      { index: 0, label: "Terminal", icon_path: "", action_type: "command", action_value: "alacritty" },
      { index: 1, label: "Browser", icon_path: "", action_type: "command", action_value: "firefox" },
      { index: 2, label: "Files", icon_path: "", action_type: "command", action_value: "thunar" },
      { index: 3, label: "Screenshot", icon_path: "", action_type: "command", action_value: "omarchy capture screenshot" },
      { index: 4, label: "Menu", icon_path: "", action_type: "keybinding", action_value: "SUPER+ALT+Enter" },
      { index: 5, label: "Lock", icon_path: "", action_type: "command", action_value: "omarchy system lock" },
      { index: 6, label: "Music", icon_path: "", action_type: "command", action_value: "spotify" },
      { index: 7, label: "Code", icon_path: "", action_type: "command", action_value: "code" },
      // Row 2
      { index: 8, label: "Vol -", icon_path: "", action_type: "command", action_value: "pamixer -d 5" },
      { index: 9, label: "Mute", icon_path: "", action_type: "command", action_value: "pamixer -t" },
      { index: 10, label: "Vol +", icon_path: "", action_type: "command", action_value: "pamixer -i 5" },
      { index: 11, label: "Play", icon_path: "", action_type: "command", action_value: "playerctl play-pause" },
      { index: 12, label: "Next", icon_path: "", action_type: "command", action_value: "playerctl next" },
      { index: 13, label: "Prev", icon_path: "", action_type: "command", action_value: "playerctl previous" },
      { index: 14, label: "Night", icon_path: "", action_type: "command", action_value: "omarchy toggle nightlight" },
      { index: 15, label: "Theme", icon_path: "", action_type: "command", action_value: "omarchy-shell shell summon omarchy.theme-switcher" },
    ]
  };
}

function rowForIndex(index) {
  return Math.floor(index / 8);
}

function colForIndex(index) {
  return index % 8;
}

function indexFromRowCol(row, col) {
  return row * 8 + col;
}

function hasAction(btn) {
  return btn && btn.action_value && btn.action_value.trim().length > 0;
}

function actionSummary(btn) {
  if (!hasAction(btn)) return "empty";
  var type = btn.action_type === "keybinding" ? "key" : "cmd";
  return type + ": " + btn.action_value;
}
