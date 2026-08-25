import QtQuick
import Quickshell.Io

// Owns the helper process and the only NDJSON write path.
QtObject {
  id: root

  required property string executable
  property var args: []
  property int protocolVersion: 1
  readonly property bool running: process.running
  readonly property bool restarting: restartCommand !== null
  property var restartCommand: null

  signal line(string value)
  signal ready()
  signal failed(string message)

  function commandFor(demoMode) {
    var command = [root.executable]
    if (root.args && root.args.length > 0) {
      for (var i = 0; i < root.args.length; i++) {
        command.push(root.args[i])
      }
    }
    return command
  }

  function ensureStarted(demoMode) {
    var wanted = root.commandFor(demoMode)
    if (process.running) {
      if (JSON.stringify(process.command) === JSON.stringify(wanted)
          && root.restartCommand === null) return true
      root.restartCommand = wanted
      process.signal(15)
      return false
    }
    process.command = wanted
    process.running = true
    return false
  }

  function send(command) {
    if (!process.running || root.restartCommand !== null) return false
    var payload = {}
    for (var key in command) payload[key] = command[key]
    payload.protocolVersion = root.protocolVersion
    process.write(JSON.stringify(payload) + "\n")
    return true
  }

  property Process process: Process {
    command: [root.executable]
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(value) { root.line(value) }
    }

    onStarted: {
      root.ready()
    }

    onExited: function(exitCode) {
      if (root.restartCommand !== null) {
        process.command = root.restartCommand
        root.restartCommand = null
        process.running = true
        return
      }
      root.failed("Bridge exited (code " + exitCode + ").")
    }
  }
}
