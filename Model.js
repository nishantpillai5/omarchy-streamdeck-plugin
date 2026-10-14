// Stream Deck button configuration model.
//
// Persisted in ~/.config/omarchy/streamdeck/buttons.json
//
// Schema v3 (user-managed profiles):
// {
//   "version": 3,
//   "activeProfileId": "work-xl",
//   "profiles": [
//     {
//       "id": "work-xl",
//       "name": "Work XL",
//       "layout": "xl",          // "xl" (32 keys) | "original" (15 keys)
//       "buttons": [ { "index": 0, "label": "...", "icon_path": "", "action_type": "command", "action_value": "..." }, ... ]
//     }
//   ],
//   "defaults": {
//     "xl": "work-xl",           // profile id auto-applied when an XL connects
//     "original": "work-orig"    // profile id auto-applied when an Original connects
//   }
// }
//
// Legacy schemas are migrated on load:
//   v1: { "version": 1, "buttons": [ ...32 entries... ] }
//   v2: { "version": 2, "profiles": { "xl": {...}, "original": {...} } }

var SCHEMA_VERSION = 3;
// Pass home dir from QML side to avoid Quickshell dependency in JS module.
var CONFIG_DIR = "";
var CONFIG_PATH = "";

function setHomeDir(home) {
  CONFIG_DIR = home + "/.config/omarchy/streamdeck";
  CONFIG_PATH = CONFIG_DIR + "/buttons.json";
}

// Available layouts. `key` is the stable identifier; `buttonCount` drives the
// grid and the number of button slots a profile holds.
var LAYOUTS = [
  { key: "xl", label: "Stream Deck XL", buttonCount: 32, cols: 8, rows: 4 },
  { key: "original", label: "Stream Deck Original", buttonCount: 15, cols: 5, rows: 3 },
  { key: "plus", label: "Stream Deck +", buttonCount: 8, cols: 4, rows: 2, dials: 4, touchStrip: true }
];

function layoutByKey(key) {
  for (var i = 0; i < LAYOUTS.length; i++) {
    if (LAYOUTS[i].key === key) return LAYOUTS[i];
  }
  return null;
}

function layoutKeyForDeckType(deckType) {
  var t = String(deckType || "");
  if (t.indexOf("+") >= 0) return "plus";
  if (t.indexOf("XL") >= 0) return "xl";
  if (t.indexOf("Original") >= 0) return "original";
  return "xl";
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

function emptyButtons(count) {
  var arr = [];
  for (var i = 0; i < count; i++) {
    arr.push(emptyButton(i));
  }
  return arr;
}

function newProfileId() {
  return "profile-" + Date.now().toString(36);
}

function newProfile(name, layoutKey) {
  var layout = layoutByKey(layoutKey) || LAYOUTS[0];
  return {
    id: newProfileId(),
    name: name || layout.label,
    layout: layout.key,
    buttons: emptyButtons(layout.buttonCount)
  };
}

// A fresh config with three starter profiles (one per layout).
function emptyConfig() {
  var xl = newProfile("Stream Deck XL", "xl");
  xl.id = "xl";
  var orig = newProfile("Stream Deck Original", "original");
  orig.id = "original";
  var plus = newProfile("Stream Deck +", "plus");
  plus.id = "plus";
  return {
    version: SCHEMA_VERSION,
    activeProfileId: "xl",
    profiles: [xl, orig, plus],
    defaults: { xl: "xl", original: "original", plus: "plus" }
  };
}

// Normalize a single profile's buttons to exactly `count` entries.
function normalizeButtons(srcButtons, count) {
  var buttons = emptyButtons(count);
  var src = Array.isArray(srcButtons) ? srcButtons : [];
  for (var i = 0; i < count; i++) {
    var s = src[i];
    if (s && typeof s === "object") {
      if (typeof s.label === "string") buttons[i].label = s.label;
      if (typeof s.icon_path === "string") buttons[i].icon_path = s.icon_path;
      if (typeof s.action_type === "string") buttons[i].action_type = s.action_type;
      if (typeof s.action_value === "string") buttons[i].action_value = s.action_value;
    }
  }
  return buttons;
}

function normalizeProfile(src, fallbackId, fallbackName, fallbackLayout) {
  var layoutKey = (src && src.layout && layoutByKey(src.layout)) ? src.layout : fallbackLayout;
  var layout = layoutByKey(layoutKey);
  return {
    id: (src && typeof src.id === "string" && src.id) ? src.id : fallbackId,
    name: (src && typeof src.name === "string" && src.name) ? src.name : fallbackName,
    layout: layoutKey,
    buttons: normalizeButtons(src ? src.buttons : [], layout.buttonCount)
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

    // v1: flat 32-button array.
    if (parsed.version === 1 || (!parsed.profiles && Array.isArray(parsed.buttons))) {
      var legacy = Array.isArray(parsed.buttons) ? parsed.buttons : [];
      var xl = normalizeProfile({ buttons: legacy }, "xl", "Stream Deck XL", "xl");
      var orig = normalizeProfile({ buttons: legacy }, "original", "Stream Deck Original", "original");
      return {
        config: {
          version: SCHEMA_VERSION,
          activeProfileId: "xl",
          profiles: [xl, orig],
          defaults: { xl: "xl", original: "original", plus: "" }
        },
        error: ""
      };
    }

    // v2: profiles keyed by layout key.
    if (parsed.version === 2 && parsed.profiles && !Array.isArray(parsed.profiles)) {
      var p2 = parsed.profiles;
      var xl2 = normalizeProfile(p2.xl, "xl", "Stream Deck XL", "xl");
      var orig2 = normalizeProfile(p2.original, "original", "Stream Deck Original", "original");
      return {
        config: {
          version: SCHEMA_VERSION,
          activeProfileId: "xl",
          profiles: [xl2, orig2],
          defaults: { xl: "xl", original: "original", plus: "" }
        },
        error: ""
      };
    }

    // v3: array of profiles.
    var profiles = [];
    var srcProfiles = Array.isArray(parsed.profiles) ? parsed.profiles : [];
    for (var i = 0; i < srcProfiles.length; i++) {
      var sp = srcProfiles[i];
      if (!sp || typeof sp !== "object") continue;
      var layoutKey = (sp.layout && layoutByKey(sp.layout)) ? sp.layout : "xl";
      profiles.push(normalizeProfile(sp, newProfileId(), "Profile", layoutKey));
    }
    if (profiles.length === 0) {
      profiles = emptyConfig().profiles;
    }

    var activeId = (typeof parsed.activeProfileId === "string" && parsed.activeProfileId) ? parsed.activeProfileId : profiles[0].id;
    // Ensure active id exists.
    var activeExists = false;
    for (var j = 0; j < profiles.length; j++) {
      if (profiles[j].id === activeId) { activeExists = true; break; }
    }
    if (!activeExists) activeId = profiles[0].id;

    var defaults = { xl: "", original: "", plus: "" };
    if (parsed.defaults && typeof parsed.defaults === "object") {
      if (typeof parsed.defaults.xl === "string") defaults.xl = parsed.defaults.xl;
      if (typeof parsed.defaults.original === "string") defaults.original = parsed.defaults.original;
      if (typeof parsed.defaults.plus === "string") defaults.plus = parsed.defaults.plus;
    }

    return {
      config: {
        version: SCHEMA_VERSION,
        activeProfileId: activeId,
        profiles: profiles,
        defaults: defaults
      },
      error: ""
    };
  } catch (e) {
    return { config: emptyConfig(), error: "JSON parse error: " + e.message };
  }
}

function serializeConfig(config) {
  return JSON.stringify(config, null, 2);
}

function hasAction(btn) {
  if (!btn) return false;
  if (btn.action_type === "audio_output") return true;
  return btn.action_value && btn.action_value.trim().length > 0;
}

function actionSummary(btn) {
  if (!hasAction(btn)) return "empty";
  if (btn.action_type === "audio_output") return "audio output";
  var type = btn.action_type === "keybinding" ? "key" : "cmd";
  return type + ": " + btn.action_value;
}
