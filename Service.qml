import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Injected by omarchy-shell (the plugin service loader).
  property var shell: null

  // Resolves next to this file, so the service works from any install path.
  readonly property string scriptPath: {
    var url = Qt.resolvedUrl("scripts/update-opencode-go").toString()
    if (url.indexOf("file://") === 0) url = decodeURIComponent(url.substring(7))
    return url
  }

  // The script caches each API response for a few minutes internally, so the
  // wall-clock cadence here is cheap: providers without resolvable
  // credentials exit immediately, failed fetches leave previous records
  // untouched.
  readonly property int intervalSec: 300

  function refresh(force) {
    if (updateProc.running) return
    // $1 is consumed by the guard itself: shift before exec so the script
    // only ever sees the real flags.
    var command = ["bash", "-c", "[[ -x \"$1\" ]] && { p=$1; shift; exec \"$p\" \"$@\"; }", "bash", root.scriptPath]
    if (force === true) command.push("--force")
    updateProc.command = command
    updateProc.running = true
  }

  IpcHandler {
    target: "ziouf.opencode-go-quotas"

    function refresh(): string { root.refresh(true); return "ok" }
  }

  Timer {
    interval: root.intervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: updateProc

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("opencode-go-quotas", text.trim())
    }
  }
}
