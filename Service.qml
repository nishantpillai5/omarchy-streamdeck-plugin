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
  // The directory this file was loaded from, so the bridge is found wherever
  // the plugin is installed. Falls back to the default install location if
  // the plugin was not loaded from a local file.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) {
      return decodeURIComponent(url.substring(7)).replace(/\/$/, "")
    }
    return home + "/.config/omarchy/plugins/elgato.streamdeck"
  }
  readonly property string helper: pluginDir + "/scripts/streamdeck-bridge"
  readonly property string pythonBin: "/usr/bin/python3"
  readonly property string configPath: home + "/.config/omarchy/streamdeck/buttons.json"

  property string phase: "idle"
  property string lastError: ""
  property int brightness: 50
  property var pinnedApps: null       // optional Stream Deck + pinned-app list (null = bridge default)
  property string deckType: ""
  property int deviceButtonCount: 32

  // Profile state.
  property var profiles: []            // array of { id, name, layout, buttons }
  property string activeProfileId: ""  // profile currently shown/edited/pushed
  property var defaults: ({})          // { xl: profileId, original: profileId, plus: profileId }
  property bool followDevice: true     // auto-apply the per-device default on connect
  property bool configLoaded: false    // true once buttons.json has been read (or found missing)
  property var ipcOwner: null          // the one Panel serving IPC (see Panel.claimIpc)

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
    // Skip while a slider change is waiting to be saved, so an older file
    // doesn't snap the slider back.
    if (parsed.config.brightness !== brightness && !saveBrightnessTimer.running) {
      brightness = parsed.config.brightness
      if (isReady) pushBrightness()
    }
    if (JSON.stringify(parsed.config.pinnedApps) !== JSON.stringify(pinnedApps)) {
      pinnedApps = parsed.config.pinnedApps
      if (bridgeController.running) bridgeController.send({ op: "config", pinned_apps: pinnedApps })
    }
    if (parsed.error) {
      lastError = parsed.error
      if (phase !== "ready") phase = "error"
    }
    // If the device connected before the config finished loading, the
    // "ready" handler skipped picking its profile; do it now.
    var firstLoad = !configLoaded
    configLoaded = true
    if (firstLoad && isReady && followDevice) {
      activeProfileId = ensureDeviceProfile(Model.layoutKeyForDeckType(deckType))
    }
    console.log("[StreamDeck Service] profiles:", profiles.length, "active:", activeProfileId)
    if (isReady && bridgeController.running) {
      pushButtons()
    }
  }

  function saveConfig() {
    var config = {
      version: Model.SCHEMA_VERSION,
      activeProfileId: activeProfileId,
      profiles: profiles,
      defaults: defaults,
      brightness: brightness
    }
    // Only written when the user set one, so the default list can change.
    if (pinnedApps) config.pinnedApps = pinnedApps
    configFile.setText(Model.serializeConfig(config))
  }

  // JSON of the last button set sent to the bridge. Saving the config makes
  // the file watcher reload it, which would push the same buttons again and
  // redraw every key; this skips that. Cleared whenever the device (re)connects.
  property string lastPushedButtons: ""

  function pushButtons() {
    if (!bridgeController.running) {
      console.log("[StreamDeck Service] Bridge not running, not pushing buttons")
      return
    }
    var activeButtons = buttons.filter(function(b) { return Model.hasAction(b) })
    var json = JSON.stringify(activeButtons)
    if (json === lastPushedButtons) return
    console.log("[StreamDeck Service] Sending", activeButtons.length, "buttons to bridge")
    if (bridgeController.send({ op: "set_buttons", buttons: activeButtons })) {
      lastPushedButtons = json
    }
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
      },
      pinned_apps: pinnedApps
    })
  }

  function pushBrightness() {
    if (!bridgeController.running) return
    bridgeController.send({ op: "set_brightness", value: brightness })
  }

  // Set, apply and (after a short delay) persist the deck brightness.
  function setBrightness(value) {
    var v = Math.max(0, Math.min(100, Math.round(Number(value))))
    if (isNaN(v)) return
    brightness = v
    pushBrightness()
    saveBrightnessTimer.restart()
  }

  function reconnect() {
    if (!bridgeController.running) {
      bridgeController.ensureStarted(false)
      return
    }
    bridgeController.send({ op: "reconnect" })
  }

  // ---------------------------------------------------------------- profile ops

  // `profiles` and `defaults` are plain JS values: QML only notices a change
  // when the property is assigned, not when an element or field is mutated
  // in place. Every edit below therefore builds a new array/object.

  // Return a copy of profile `id` with `changes` applied, in a new array.
  function profilesWithChange(id, changes) {
    return profiles.map(function(p) {
      if (p.id !== id) return p
      var copy = {}
      for (var k in p) copy[k] = p[k]
      for (var c in changes) copy[c] = changes[c]
      return copy
    })
  }

  function defaultsWithChange(layoutKey, profileId) {
    var copy = {}
    for (var k in defaults) copy[k] = defaults[k]
    copy[layoutKey] = profileId
    return copy
  }

  function createProfile(name, layoutKey) {
    var p = Model.newProfile(name, layoutKey)
    profiles = profiles.concat([p])
    activeProfileId = p.id
    followDevice = false
    saveConfig()
    if (isReady && bridgeController.running) pushButtons()
    return p.id
  }

  function renameProfile(id, newName) {
    if (!profileById(id)) return
    profiles = profilesWithChange(id, { name: newName })
    saveConfig()
  }

  function deleteProfile(id) {
    var idx = profileIndexById(id)
    if (idx < 0) return
    if (profiles.length <= 1) return  // keep at least one profile
    profiles = profiles.filter(function(p) { return p.id !== id })
    // Clear any default pointing at the deleted profile.
    var newDefaults = {}
    for (var k in defaults) newDefaults[k] = defaults[k] === id ? "" : defaults[k]
    defaults = newDefaults
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
    var reordered = profiles.slice()
    reordered[idx] = profiles[target]
    reordered[target] = profiles[idx]
    profiles = reordered
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
    defaults = defaultsWithChange(layoutKey, profileId)
    saveConfig()
  }

  function resumeFollowDevice() {
    followDevice = true
    if (phase === "ready") {
      activeProfileId = ensureDeviceProfile(Model.layoutKeyForDeckType(deckType))
      if (bridgeController.running) pushButtons()
    }
  }

  // Return the default profile id for a layout, making sure one exists.
  // Configs created before a layout existed (e.g. "plus") have no profile or
  // default for it: use the first profile with that layout, or create one,
  // and record it as the default. Only saves when something changed.
  function ensureDeviceProfile(layoutKey) {
    var layout = Model.layoutByKey(layoutKey)
    if (!layout) return activeProfileId
    var def = defaults[layoutKey]
    if (def && profileById(def)) return def

    var match = null
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].layout === layoutKey) { match = profiles[i]; break }
    }
    if (!match) {
      match = Model.newProfile(layout.label, layoutKey)
      profiles = profiles.concat([match])
    }
    defaults = defaultsWithChange(layoutKey, match.id)
    saveConfig()
    return match.id
  }

  // Replace the buttons for a profile, then persist.
  function saveProfileButtons(profileId, newButtons) {
    if (!profileById(profileId)) return
    profiles = profilesWithChange(profileId, { buttons: newButtons })
    if (profileId === activeProfileId && isReady && bridgeController.running) {
      pushButtons()
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
      if (followDevice && configLoaded) {
        root.activeProfileId = root.ensureDeviceProfile(Model.layoutKeyForDeckType(root.deckType))
      }
      console.log("[StreamDeck Service] device ready, active profile:", root.activeProfileId)
      // A (re)connected deck starts blank: force the next push through.
      root.lastPushedButtons = ""
      delayPushTimer.start()
      break
    case "disconnected":
      root.phase = "idle"
      root.lastPushedButtons = ""
      break
    case "error":
      root.phase = "error"
      root.lastError = event.message || "Unknown error"
      break
    case "swipe": {
      // Page between the connected device's profiles: swipe left -> next,
      // right -> previous (wraps). Profiles for other layouts are skipped.
      var dir = (event.direction === undefined) ? 0 : event.direction
      if (dir === 0) break
      var layoutKey = Model.layoutKeyForDeckType(root.deckType)
      var pages = root.profiles.filter(function(p) { return p.layout === layoutKey })
      if (pages.length === 0) break
      var idx = -1
      for (var i = 0; i < pages.length; i++) {
        if (pages[i].id === root.activeProfileId) { idx = i; break }
      }
      var next
      if (idx < 0) {
        // Active profile is for another layout: jump into this device's pages.
        next = dir > 0 ? 0 : pages.length - 1
      } else {
        next = (idx + dir + pages.length) % pages.length
      }
      if (next !== idx) root.applyProfile(pages[next].id)
      break
    }
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
      root.lastPushedButtons = ""
    }
  }

  // Brightness changes arrive on every slider step; write the config once the
  // slider has settled rather than on each step.
  property Timer saveBrightnessTimer: Timer {
    interval: 600
    repeat: false
    onTriggered: root.saveConfig()
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
