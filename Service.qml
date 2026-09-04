import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Service singleton that owns the bridge and user-managed button profiles.
// Mounted once per session; bar widgets reach it via bar.shell.serviceFor("elgato.streamdeck").
QtObject {
  id: root

  Component.onCompleted: {
    Model.setHomeDir(Quickshell.env("HOME"))
    // Auto-connect on startup. The bridge stays alive even when no device is
    // present, so a later reconnect (or the retry timer) can pick it up.
    Qt.callLater(function() { root.reconnect() })
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/elgato.streamdeck"
  readonly property string helper: pluginDir + "/scripts/streamdeck-bridge"
  readonly property string pythonBin: "/usr/bin/python3"
  readonly property string configPath: home + "/.config/omarchy/streamdeck/buttons.json"

  property string phase: "idle"
  property string lastError: ""
  property int brightness: 50
  property string deckType: ""
  property int deviceButtonCount: 32

  // Profile state.
  property var profiles: []            // array of { id, name, layout, buttons }
  property string activeProfileId: ""  // profile currently shown/edited/pushed
  property var defaults: ({})          // { xl: profileId, original: profileId }
  property bool followDevice: true     // auto-apply the per-device default on connect

  readonly property bool isReady: phase === "ready"
  readonly property bool hasError: phase === "error"

  // The active profile object.
  readonly property var activeProfile: {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].id === activeProfileId) return profiles[i];
    }
    return profiles.length > 0 ? profiles[0] : null;
  }

  // Buttons for the active profile, as an array indexed by button index.
  readonly property var buttons: activeProfile ? activeProfile.buttons : []

  property FileView configFile: FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("")
    onFileChanged: reload()
  }

  function profileById(id) {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].id === id) return profiles[i];
    }
    return null;
  }

  function profileIndexById(id) {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].id === id) return i;
    }
    return -1;
  }

  function loadConfig(text) {
    console.log("[StreamDeck Service] loadConfig called, text length:", String(text || "").length)
    var parsed = Model.parseConfig(text)
    profiles = parsed.config.profiles
    defaults = parsed.config.defaults
    activeProfileId = parsed.config.activeProfileId
    if (parsed.error) {
      lastError = parsed.error
      if (phase !== "ready") phase = "error"
    }
    console.log("[StreamDeck Service] profiles:", profiles.length, "active:", activeProfileId)
    if (isReady && bridgeController.running) {
      pushButtons()
    }
  }

  function saveConfig() {
    var text = Model.serializeConfig({
      version: Model.SCHEMA_VERSION,
      activeProfileId: activeProfileId,
      profiles: profiles,
      defaults: defaults
    })
    configFile.setText(text)
  }

  function pushButtons(buttonsArg) {
    console.log("[StreamDeck Service] pushButtons called, bridge running:", bridgeController.running)
    if (!bridgeController.running) {
      console.log("[StreamDeck Service] Bridge not running, aborting")
      return
    }
    // Accept an explicit button list (e.g. freshly-saved buttons) to avoid the
    // stale-binding problem: mutating a nested property of `profiles` does not
    // re-evaluate the `buttons` binding, so callers that just changed buttons
    // pass them in directly.
    var list = buttonsArg !== undefined ? buttonsArg : buttons
    var activeButtons = list.filter(function(b) { return Model.hasAction(b) })
    console.log("[StreamDeck Service] Sending", activeButtons.length, "buttons to bridge")
    var sent = bridgeController.send({ op: "set_buttons", buttons: activeButtons })
    console.log("[StreamDeck Service] send() returned:", sent)
  }

  function pushConfig() {
    if (!bridgeController.running) return
    bridgeController.send({
      op: "config",
      brightness: brightness,
      colors: {
        fg: Color.foreground.toString(),
        bg: Color.background.toString(),
        accent: Color.accent.toString()
      }
    })
  }

  function pushBrightness() {
    if (!bridgeController.running) return
    bridgeController.send({ op: "set_brightness", value: brightness })
  }

  function reconnect() {
    if (!bridgeController.running) {
      bridgeController.ensureStarted(false)
      return
    }
    bridgeController.send({ op: "reconnect" })
  }

  // ---------------------------------------------------------------- profile ops

  function createProfile(name, layoutKey) {
    var p = Model.newProfile(name, layoutKey)
    profiles.push(p)
    activeProfileId = p.id
    followDevice = false
    saveConfig()
    if (isReady && bridgeController.running) pushButtons()
    return p.id
  }

  function renameProfile(id, newName) {
    var p = profileById(id)
    if (!p) return
    p.name = newName
    saveConfig()
  }

  function deleteProfile(id) {
    var idx = profileIndexById(id)
    if (idx < 0) return
    if (profiles.length <= 1) return  // keep at least one profile
    profiles.splice(idx, 1)
    // Clear any default pointing at the deleted profile.
    if (defaults.xl === id) defaults.xl = ""
    if (defaults.original === id) defaults.original = ""
    if (activeProfileId === id) {
      activeProfileId = profiles[0].id
      if (isReady && bridgeController.running) pushButtons()
    }
    saveConfig()
  }

  function moveProfile(id, delta) {
    var idx = profileIndexById(id)
    if (idx < 0) return
    var target = idx + delta
    if (target < 0 || target >= profiles.length) return
    var tmp = profiles[idx]
    profiles[idx] = profiles[target]
    profiles[target] = tmp
    saveConfig()
  }

  function applyProfile(id) {
    if (!profileById(id)) return
    activeProfileId = id
    followDevice = false
    if (isReady && bridgeController.running) pushButtons()
    saveConfig()
  }

  function setDefaultForLayout(layoutKey, profileId) {
    if (!Model.layoutByKey(layoutKey)) return
    defaults[layoutKey] = profileId
    saveConfig()
  }

  function resumeFollowDevice() {
    followDevice = true
    if (phase === "ready") {
      var key = Model.layoutKeyForDeckType(deckType)
      var def = defaults[key]
      if (def && profileById(def)) {
        activeProfileId = def
        if (bridgeController.running) pushButtons()
      }
    }
  }

  // Replace the buttons for a profile, then persist.
  function saveProfileButtons(profileId, newButtons) {
    var p = profileById(profileId)
    if (!p) return
    p.buttons = newButtons
    if (profileId === activeProfileId && isReady && bridgeController.running) {
      pushButtons(newButtons)
    }
    saveConfig()
  }

  function handleEvent(line) {
    console.log("[StreamDeck Service] handleEvent received:", String(line || "").substring(0, 100))
    var text = String(line || "").trim()
    if (!text) return
    var event
    try { event = JSON.parse(text) } catch (e) { return }
    if (!event || typeof event !== "object") return
    console.log("[StreamDeck Service] Event type:", event.ev)

    switch (event.ev) {
    case "ready":
      root.phase = "ready"
      root.lastError = ""
      root.deckType = event.deck_type || ""
      if (event.button_count) root.deviceButtonCount = event.button_count
      if (followDevice) {
        var key = Model.layoutKeyForDeckType(root.deckType)
        var def = root.defaults[key]
        if (def && root.profileById(def)) {
          root.activeProfileId = def
        }
      }
      console.log("[StreamDeck Service] device ready, active profile:", root.activeProfileId)
      delayPushTimer.start()
      break
    case "disconnected":
      root.phase = "idle"
      break
    case "error":
      root.phase = "error"
      root.lastError = event.message || "Unknown error"
      break
    case "button_down":
      break
    case "button_up":
      break
    }
  }

  property BridgeController bridgeController: BridgeController {
    executable: root.pythonBin
    args: [root.helper]
    protocolVersion: 1
    onLine: function(value) { root.handleEvent(value) }
    onFailed: function(message) {
      root.phase = "error"
      root.lastError = message
    }
  }

  property Timer delayPushTimer: Timer {
    interval: 800
    repeat: false
    onTriggered: {
      console.log("[StreamDeck Service] delayPushTimer triggered")
      root.pushConfig()
      root.pushButtons()
    }
  }

  // Periodic auto-connect retry. Only fires when not connected, so it is a
  // no-op while a deck is present. Handles the deck being plugged in after
  // the shell has already started.
  property Timer autoConnectTimer: Timer {
    interval: 10000
    repeat: true
    running: true
    onTriggered: {
      if (root.phase === "ready") return
      if (!bridgeController.running) {
        console.log("[StreamDeck Service] auto-connect: starting bridge")
        root.reconnect()
      } else {
        console.log("[StreamDeck Service] auto-connect: sending reconnect")
        bridgeController.send({ op: "reconnect" })
      }
    }
  }
}
