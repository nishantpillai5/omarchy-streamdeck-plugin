import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Service singleton that owns the bridge.
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
  property var buttons: []
  property int brightness: 50
  property string deckType: ""
  property int deviceButtonCount: 32

  readonly property bool isReady: phase === "ready"
  readonly property bool hasError: phase === "error"

  property FileView configFile: FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("")
    onFileChanged: reload()
  }

  function loadConfig(text) {
    console.log("[StreamDeck Service] loadConfig called, text length:", String(text || "").length)
    var parsed = Model.parseConfig(text)
    buttons = parsed.config.buttons
    console.log("[StreamDeck Service] Buttons loaded:", buttons.length, "configured:", buttons.filter(function(b) { return Model.hasAction(b) }).length)
    if (parsed.error) {
      lastError = parsed.error
      if (phase !== "ready") phase = "error"
    }
    if (isReady && bridgeController.running) {
      pushButtons()
    }
  }

  function saveConfig(newButtons) {
    var config = {
      version: Model.SCHEMA_VERSION,
      buttons: newButtons
    }
    var text = Model.serializeConfig(config)
    configFile.setText(text)
    buttons = newButtons
    if (isReady && bridgeController.running) {
      pushButtons()
    }
  }

  function pushButtons() {
    console.log("[StreamDeck Service] pushButtons called, bridge running:", bridgeController.running, "buttons:", buttons.length)
    if (!bridgeController.running) {
      console.log("[StreamDeck Service] Bridge not running, aborting")
      return
    }
    var activeButtons = buttons.filter(function(b) { return Model.hasAction(b) })
    console.log("[StreamDeck Service] Sending", activeButtons.length, "buttons to bridge")
    var payload = {
      op: "set_buttons",
      buttons: activeButtons
    }
    console.log("[StreamDeck Service] Payload:", JSON.stringify(payload).substring(0, 200))
    var sent = bridgeController.send(payload)
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
      // Delay push to ensure bridge is in its main stdin-reading loop
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
