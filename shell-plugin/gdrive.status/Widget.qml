import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Google Drive status for the bar, fed by `omarchy-gdrive status --json`.
// Normal color: connected. Theme accent, pulsing: uploading. Dimmed: off or
// waiting for the network. Urgent color: an error that needs attention.
// Left click opens Drive in Files, right click the Google Drive menu,
// middle click the status in a terminal.
BarWidget {
  id: root
  moduleName: "gdrive.status"

  readonly property string cli: Quickshell.env("HOME") + "/.local/share/omarchy-gdrive/bin/omarchy-gdrive"
  property string driveState: ""
  property string tooltip: "Google Drive"
  property bool pulse: false

  readonly property bool syncing: driveState === "syncing"
  readonly property bool failed: driveState === "error"
  readonly property bool idle: driveState === "disconnected" || driveState === "offline" || driveState === "starting"

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshSoon() {
    soonTimer.restart()
  }

  function apply(text) {
    try {
      var data = JSON.parse(text)
      driveState = String(data.state || "")
      tooltip = String(data.tooltip || "Google Drive")
    } catch (error) {
      driveState = "error"
      tooltip = "Google Drive: could not read the status"
    }
  }

  visible: driveState !== "" && driveState !== "unconfigured"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "gdrive.status"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.apply(statusOut.text)
      else root.driveState = ""
    }
  }

  Timer {
    interval: root.syncing || root.driveState === "starting" ? 2000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: soonTimer
    interval: 1500
    onTriggered: root.refresh()
  }

  Timer {
    interval: 700
    running: root.syncing
    repeat: true
    onTriggered: root.pulse = !root.pulse
    onRunningChanged: if (!running) root.pulse = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰊶"
    slotSize: Style.bar.statusSlot
    foreground: root.failed ? (root.bar ? root.bar.urgent : Commons.Color.urgent)
      : root.syncing ? Commons.Color.accent
      : (root.bar ? root.bar.barForeground : Commons.Color.foreground)
    dimmed: root.idle || root.pulse
    tooltipText: root.tooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        Quickshell.execDetached(["omarchy-menu", "summon", "gdrive"])
      } else if (buttonCode === Qt.MiddleButton) {
        Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.cli + " status"])
      } else {
        Quickshell.execDetached([root.cli, "open"])
      }
      root.refreshSoon()
    }
  }
}
