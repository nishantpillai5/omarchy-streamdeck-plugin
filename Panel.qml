import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Stream Deck XL bar widget and panel.
// State lives in Service.qml (one per session); this panel is one per monitor.
Panel {
  id: root
  moduleName: "elgato.streamdeck"
  ipcTarget: "elgato.streamdeck"
  manageIpc: false

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("elgato.streamdeck") : null
  readonly property bool serviceReady: service !== null
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/elgato.streamdeck"
  readonly property string iconDir: Quickshell.env("HOME") + "/.config/omarchy/streamdeck/icons"

  // Proxy state from service
  readonly property string phase: serviceReady ? service.phase : "idle"
  readonly property string lastError: serviceReady ? service.lastError : ""
  readonly property var buttons: serviceReady ? service.buttons : []
  readonly property int brightness: serviceReady ? service.brightness : 50
  readonly property bool isReady: phase === "ready"
  readonly property bool hasError: phase === "error"
  readonly property string deckType: serviceReady ? service.deckType : ""
  readonly property string activeProfileId: serviceReady ? service.activeProfileId : ""
  readonly property var profiles: serviceReady ? service.profiles : []
  readonly property var defaults: serviceReady ? service.defaults : ({})
  readonly property bool followDevice: serviceReady ? service.followDevice : true

  // Display name of the active profile.
  readonly property string activeProfileName: {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].id === activeProfileId) return profiles[i].name;
    }
    return "";
  }

  // The profile currently selected in the manager (defaults to active).
  readonly property var selectedProfile: {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].id === selectedProfileId) return profiles[i];
    }
    return null;
  }

  readonly property bool selectedIsDefaultXl: selectedProfile ? (defaults.xl === selectedProfile.id) : false
  readonly property bool selectedIsDefaultOriginal: selectedProfile ? (defaults.original === selectedProfile.id) : false

  // Button count of the active profile (the grid shows/edits this profile).
  readonly property int activeButtonCount: buttons.length > 0 ? buttons.length : 32

  // Layout: XL = 8×4 (32), Original/Original V2 = 5×3 (15)
  readonly property int colCount: activeButtonCount === 15 ? 5 : 8
  readonly property int rowCount: activeButtonCount === 15 ? 3 : 4

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property string barIcon: "󰥻"

  // ---------------------------------------------------------------- edit state
  property int editingIndex: -1
  property string editLabelDraft: ""
  property string editActionDraft: ""
  property string editTypeDraft: "command"
  property string editIconDraft: ""

  // ---------------------------------------------------------------- profile mgmt state
  property bool profileManagerOpen: false
  property string selectedProfileId: ""
  property string nameDraft: ""
  property string newProfileName: ""
  property string newProfileLayout: "xl"

  // ---------------------------------------------------------------- cursor
  property int cursorIndex: 0
  property bool cursorActive: false

  function moveCursor(dx, dy) {
    if (!cursorActive) { cursorActive = true; return }
    var row = Math.floor(cursorIndex / colCount)
    var col = cursorIndex % colCount
    col = Math.max(0, Math.min(colCount - 1, col + dx))
    row = Math.max(0, Math.min(rowCount - 1, row + dy))
    cursorIndex = row * colCount + col
  }

  function activateCursor() {
    if (editingIndex >= 0) { editingIndex = -1; return }
    editButtonAt(cursorIndex)
  }

  function editButtonAt(index) {
    if (index < 0 || index >= activeButtonCount) return
    editingIndex = index
    var btn = buttons[index] || Model.emptyButton(index)
    editLabelDraft = btn.label || ""
    editActionDraft = btn.action_value || ""
    editTypeDraft = btn.action_type || "command"
    editIconDraft = btn.icon_path || ""
  }

  function saveEdit() {
    if (editingIndex < 0) return
    var newButtons = buttons.slice()
    newButtons[editingIndex] = {
      index: editingIndex,
      label: editLabelDraft,
      icon_path: editIconDraft,
      action_type: editTypeDraft,
      action_value: editActionDraft
    }
    if (serviceReady) service.saveProfileButtons(activeProfileId, newButtons)
    editingIndex = -1
  }

  function cancelEdit() {
    editingIndex = -1
  }

  function openProfileManager() {
    profileManagerOpen = true
    selectedProfileId = activeProfileId
    nameDraft = activeProfileName
  }

  function selectProfileForEdit(id) {
    selectedProfileId = id
    var p = null
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].id === id) { p = profiles[i]; break }
    }
    nameDraft = p ? p.name : ""
  }

  function commitRename() {
    if (selectedProfileId !== "" && nameDraft.trim() !== "") {
      if (serviceReady) service.renameProfile(selectedProfileId, nameDraft.trim())
    }
  }

  function toggleDefault(layoutKey) {
    if (!serviceReady || !selectedProfile) return
    var current = defaults[layoutKey]
    // Toggle: if this profile is already the default, clear it; otherwise set it.
    service.setDefaultForLayout(layoutKey, current === selectedProfile.id ? "" : selectedProfile.id)
  }

  function openIconPicker() {
    console.log("[StreamDeck] openIconPicker called")
    iconPickerProc.running = true
  }

  property Process iconPickerProc: Process {
    command: ["zenity", "--file-selection", "--file-filter=*.png", "--title=Select Button Icon"]
    stdout: SplitParser {
      onRead: function(value) {
        var picked = String(value || "").trim()
        console.log("[StreamDeck] zenity picked:", picked)
        if (picked !== "" && picked.indexOf("/") >= 0) {
          var targetDir = root.iconDir
          var targetPath = targetDir + "/btn_" + root.editingIndex + ".png"
          copyIconProc.command = ["bash", "-c", "mkdir -p '" + targetDir + "' && cp '" + picked + "' '" + targetPath + "'"]
          copyIconProc.running = true
        }
      }
    }
    onExited: function(exitCode) {
      console.log("[StreamDeck] zenity exited with code", exitCode)
    }
  }

  property Process copyIconProc: Process {
    command: ["true"]
    onExited: function(exitCode) {
      console.log("[StreamDeck] copyIconProc exited with code", exitCode)
      if (exitCode === 0) {
        root.editIconDraft = root.iconDir + "/btn_" + root.editingIndex + ".png"
        // Auto-save the icon so it persists immediately
        root.saveEdit()
      }
    }
  }

  // ---------------------------------------------------------------- panel

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      editingIndex = -1
    }
  }

  // ---------------------------------------------------------------- IPC

  IpcHandler {
    target: "elgato.streamdeck"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function setButton(index, label, actionType, actionValue, iconPath): string {
      if (index < 0 || index >= root.activeButtonCount) return "invalid index"
      if (!serviceReady) return "service unavailable"
      var newButtons = buttons.slice()
      newButtons[index] = {
        index: index,
        label: label || "",
        icon_path: iconPath || "",
        action_type: actionType || "command",
        action_value: actionValue || ""
      }
      service.saveProfileButtons(root.activeProfileId, newButtons)
      return "ok"
    }

    function clearButton(index): string {
      if (index < 0 || index >= root.activeButtonCount) return "invalid index"
      if (!serviceReady) return "service unavailable"
      var newButtons = buttons.slice()
      newButtons[index] = Model.emptyButton(index)
      service.saveProfileButtons(root.activeProfileId, newButtons)
      return "ok"
    }

    function setBrightness(value): string {
      if (!serviceReady) return "service unavailable"
      service.brightness = Math.max(0, Math.min(100, Number(value) || 50))
      service.pushBrightness()
      return "ok"
    }

    function reconnect(): string {
      if (!serviceReady) return "service unavailable"
      service.reconnect()
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        phase: root.phase,
        error: root.lastError,
        brightness: root.brightness,
        deckType: root.deckType,
        activeProfileId: root.activeProfileId,
        followDevice: root.followDevice,
        buttonCount: root.activeButtonCount,
        configured: buttons.filter(function(b) { return Model.hasAction(b) }).length
      })
    }
  }

  // ---------------------------------------------------------------- bar button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    active: root.hasError
    dimmed: !root.isReady
    onPressed: root.toggle()
  }

  // ---------------------------------------------------------------- popup panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(key) {
        var lower = String(key).toLowerCase()
        if (lower === "r") {
          if (serviceReady) service.reconnect()
        }
        else if (lower === "e") root.activateCursor()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.spacing.md

        // ---------- Header ----------
        PanelHero {
          title: "Stream Deck"
          meta: root.isReady ? "Ready" : (root.lastError || (root.phase === "connecting" ? "Connecting..." : "Not connected"))
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.isReady ? 1.0 : 0.5

          iconComponent: Component {
            Text {
              text: root.barIcon
              color: root.hasError ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            Row {
              spacing: Style.spacing.md
              PanelActionButton {
                iconText: "󰑖"
                tooltipText: "Reconnect"
                foreground: Qt.darker(root.foreground, 1.4)
                fontFamily: root.fontFamily
                onClicked: {
                  if (serviceReady) service.reconnect()
                }
              }
            }
          }
        }

        // ---------- Profile selector ----------
        Column {
          width: parent.width
          visible: root.editingIndex < 0
          spacing: Style.spacing.sm

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              text: "Profile"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.activeProfileName
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              text: root.profileManagerOpen ? "Done" : "Manage"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: {
                if (root.profileManagerOpen) {
                  root.profileManagerOpen = false
                } else {
                  root.openProfileManager()
                }
              }
            }
          }

          // Profile manager (two-pane: list + detail)
          Column {
            width: parent.width
            visible: root.profileManagerOpen
            spacing: Style.spacing.md

            // ---- List pane ----
            Column {
              width: parent.width
              spacing: Style.spacing.xs

              Repeater {
                model: root.profiles

                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  width: parent.width
                  height: Style.space(36)
                  radius: Style.cornerRadius
                  color: modelData.id === root.selectedProfileId ? root.selectedFill : "transparent"
                  border.width: modelData.id === root.activeProfileId ? 1 : 0
                  border.color: root.accent

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectProfileForEdit(modelData.id)
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.spacing.sm

                    Text {
                      text: modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: modelData.id === root.activeProfileId
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      width: parent.width - Style.space(120)
                    }

                    Text {
                      text: modelData.layout === "xl" ? "XL" : "Orig"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      visible: modelData.id === root.activeProfileId
                      text: "✓"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }

              // New profile row
              Row {
                width: parent.width
                spacing: Style.spacing.sm

                TextField {
                  width: parent.width - Style.space(200)
                  text: root.newProfileName
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  placeholderText: "New profile name"
                  onTextChanged: root.newProfileName = text
                }

                Button {
                  text: "XL"
                  selected: root.newProfileLayout === "xl"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.newProfileLayout = "xl"
                }

                Button {
                  text: "Orig"
                  selected: root.newProfileLayout === "original"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.newProfileLayout = "original"
                }

                Button {
                  text: "+"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (serviceReady && root.newProfileName.trim() !== "") {
                      var id = service.createProfile(root.newProfileName.trim(), root.newProfileLayout)
                      root.newProfileName = ""
                      root.selectProfileForEdit(id)
                    }
                  }
                }
              }
            }

            // ---- Detail pane (selected profile) ----
            Column {
              width: parent.width
              visible: root.selectedProfile !== null
              spacing: Style.spacing.sm

              PanelSectionHeader {
                text: "PROFILE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              // Name
              Column {
                width: parent.width
                spacing: Style.spacing.xs

                Text {
                  text: "Name"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                TextField {
                  width: parent.width
                  text: root.nameDraft
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  onTextChanged: root.nameDraft = text
                  onEditingFinished: root.commitRename()
                }
              }

              // Layout (read-only)
              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  text: "Layout"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.selectedProfile ? (root.selectedProfile.layout === "xl" ? "Stream Deck XL (8×4)" : "Stream Deck Original (5×3)") : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // Default for
              Column {
                width: parent.width
                spacing: Style.spacing.xs

                Text {
                  text: "Default for"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Button {
                    text: "XL"
                    selected: root.selectedIsDefaultXl
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.toggleDefault("xl")
                  }

                  Button {
                    text: "Original"
                    selected: root.selectedIsDefaultOriginal
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.toggleDefault("original")
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  text: "When a device connects, its default profile is applied automatically."
                }
              }

              // Actions
              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Button {
                  text: "Apply"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (serviceReady && root.selectedProfile) service.applyProfile(root.selectedProfile.id)
                  }
                }

                Button {
                  text: "↑"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  onClicked: { if (serviceReady && root.selectedProfile) service.moveProfile(root.selectedProfile.id, -1) }
                }

                Button {
                  text: "↓"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  onClicked: { if (serviceReady && root.selectedProfile) service.moveProfile(root.selectedProfile.id, 1) }
                }

                Button {
                  text: "Delete"
                  foreground: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (serviceReady && root.selectedProfile) {
                      service.deleteProfile(root.selectedProfile.id)
                      root.selectedProfileId = root.activeProfileId
                    }
                  }
                }
              }

              Button {
                visible: !root.followDevice
                text: "Follow device"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: { if (serviceReady) service.resumeFollowDevice() }
              }
            }
          }
        }

        // ---------- Error ----------
        Rectangle {
          width: parent.width
          visible: root.hasError
          height: visible ? errorText.implicitHeight + Style.space(16) : 0
          color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12)
          radius: Style.cornerRadius

          Text {
            id: errorText
            anchors.centerIn: parent
            width: parent.width - Style.space(16)
            wrapMode: Text.WordWrap
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Brightness ----------
        Column {
          width: parent.width
          visible: root.editingIndex < 0
          spacing: Style.spacing.sm

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              text: "Brightness"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.brightness + "%"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.brightness
            fillColor: root.accent
            onMoved: function(v) {
              if (serviceReady) {
                service.brightness = v
                service.pushBrightness()
              }
            }
          }
        }

        // ---------- Button grid ----------
        Column {
          width: parent.width
          visible: root.editingIndex < 0 && (root.isReady || buttons.some(function(b) { return Model.hasAction(b) }))
          spacing: Style.spacing.md

          PanelSectionHeader {
            text: "BUTTONS (" + root.colCount + "×" + root.rowCount + ")"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Grid {
            id: buttonGrid
            width: parent.width
            columns: root.colCount
            spacing: Style.spacing.sm

            Repeater {
              model: root.activeButtonCount

              delegate: Rectangle {
                required property int index
                readonly property var btn: root.buttons[index] || Model.emptyButton(index)

                width: (buttonGrid.width - (buttonGrid.columns - 1) * buttonGrid.spacing) / buttonGrid.columns
                height: width * (root.colCount === 5 ? 1.0 : 0.6)
                radius: Style.cornerRadius > 0 ? Style.space(2) : 0
                color: {
                  if (root.cursorActive && root.cursorIndex === index) return root.selectedFill
                  if (mouseArea.containsMouse) return root.hoverFill
                  return Model.hasAction(btn) ? Qt.darker(root.accent, 2.5) : Color.background
                }
                border.width: 1
                border.color: root.cursorActive && root.cursorIndex === index
                  ? root.accent
                  : (mouseArea.containsMouse ? root.accent : Qt.darker(Color.background, 1.3))

                MouseArea {
                  id: mouseArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.cursorIndex = index
                  onClicked: root.editButtonAt(index)
                }

                Column {
                  anchors.centerIn: parent
                  spacing: Style.spacing.xxs
                  width: parent.width - Style.space(4)

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    color: Model.hasAction(btn) ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: Model.hasAction(btn)
                    text: btn.label || String(index + 1)
                  }

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    text: Model.actionSummary(btn)
                    visible: text !== "empty"
                  }
                }
              }
            }
          }
        }

        // ---------- Not connected hint ----------
        Column {
          width: parent.width
          visible: !root.isReady && !root.hasError
          spacing: Style.spacing.xl

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "Connect your Stream Deck via USB. Make sure udev rules are installed for non-root access."
          }

          Button {
            text: "Check connection"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: {
              if (serviceReady) service.reconnect()
            }
          }
        }

        // ---------- Keyboard hints ----------
        Text {
          width: parent.width
          visible: root.editingIndex < 0 && root.isReady
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          text: "←→↑↓ Move · Enter Edit · r Reconnect · Esc Close · Tab Next"
        }

        // ---------- Edit form ----------
        Column {
          width: parent.width
          visible: root.editingIndex >= 0
          spacing: Style.spacing.md

          PanelSectionHeader {
            text: "EDIT BUTTON " + (root.editingIndex + 1)
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              text: "Label"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            TextField {
              width: parent.width
              text: root.editLabelDraft
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              placeholderText: "e.g. Terminal"
              onTextChanged: root.editLabelDraft = text
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              text: "Action"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              RadioButton {
                text: "Command"
                checked: root.editTypeDraft === "command"
                onCheckedChanged: if (checked) root.editTypeDraft = "command"
              }

              RadioButton {
                text: "Keybinding"
                checked: root.editTypeDraft === "keybinding"
                onCheckedChanged: if (checked) root.editTypeDraft = "keybinding"
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              text: root.editTypeDraft === "command" ? "Shell command" : "Key combo"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: root.editTypeDraft === "command"
                ? "Run as-is in a shell."
                : "Format: SUPER+ALT+Enter. Available keys: Enter, Space, a-z, 0-9, F1-F12, etc."
            }

            TextField {
              width: parent.width
              text: root.editActionDraft
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              placeholderText: root.editTypeDraft === "command" ? "alacritty" : "SUPER+ALT+Enter"
              onTextChanged: root.editActionDraft = text
            }
          }

          // ---------- Icon upload ----------
          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              text: "Icon"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              // Preview
              Rectangle {
                width: Style.space(48)
                height: width
                color: Color.background
                border.width: 1
                border.color: root.dim
                radius: Style.space(2)
                visible: root.editIconDraft !== "" || root.editLabelDraft !== ""

                Image {
                  anchors.fill: parent
                  anchors.margins: 2
                  source: root.editIconDraft !== "" ? "file://" + root.editIconDraft : ""
                  visible: root.editIconDraft !== ""
                  fillMode: Image.PreserveAspectFit
                }

                Text {
                  anchors.centerIn: parent
                  text: root.editLabelDraft.substring(0, 2).toUpperCase()
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  visible: root.editIconDraft === "" && root.editLabelDraft !== ""
                }
              }

              Column {
                spacing: Style.spacing.xs

                Text {
                  text: root.editIconDraft === "" ? "No custom icon" : root.editIconDraft.substring(root.editIconDraft.lastIndexOf("/") + 1)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                  width: parent.width
                }

                Row {
                  spacing: Style.spacing.sm

                  Button {
                    text: "Upload PNG"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: {
                      console.log("[StreamDeck] Upload PNG clicked")
                      root.openIconPicker()
                    }
                  }

                  Button {
                    text: "Clear"
                    visible: root.editIconDraft !== ""
                    foreground: root.dim
                    fontFamily: root.fontFamily
                    onClicked: root.editIconDraft = ""
                  }
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Button {
              text: "Save"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.saveEdit()
            }

            Button {
              text: "Clear"
              foreground: root.dim
              fontFamily: root.fontFamily
              onClicked: {
                root.editLabelDraft = ""
                root.editActionDraft = ""
                root.editIconDraft = ""
                root.saveEdit()
              }
            }

            Button {
              text: "Cancel"
              foreground: root.dim
              fontFamily: root.fontFamily
              onClicked: root.cancelEdit()
            }
          }
        }
        }
      }
    }
  }
}
