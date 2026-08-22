import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui as Ui
import "."
import "Fmt.js" as Fmt

// Bar readout for FPL Gaffer. Shows your live gameweek score while matches
// are on, and the countdown to the next deadline when they aren't. Reads a
// tiny file the engine writes for exactly this purpose, so the bar never
// waits on anything.
//
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — a bare `BarWidget` would resolve to the file itself.)
Ui.BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.gaffer"

  property string home: Quickshell.env("HOME")
  property var barData: ({})
  property int tick: 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property real deadlineLeft: {
    root.tick
    if (!root.barData || root.barData.deadline_in === undefined || root.barData.deadline_in === null) return -1
    return root.barData.deadline_in
  }

  readonly property bool statto: root.barData && root.barData.mode === "statto"

  // The bar earns its width with one number and nothing else: your points
  // in Gaffer mode, the count of matches in play in statto mode. Deadlines,
  // kick-off times and the rest live in the tooltip, where they cost nothing.
  readonly property string readout: {
    if (!root.barData) return ""
    if (root.statto)
      return root.barData.live_matches > 0 ? String(root.barData.live_matches) : ""
    if (root.barData.points === undefined || root.barData.points === null) return ""
    return String(root.barData.points)
  }

  function anchorCenterX() {
    var g = button.mapToItem(null, button.width / 2, 0)
    return g.x
  }

  // Shape contract for shell summon/toggle routing — forward to the overlay.
  readonly property bool opened: GafferState.overlay ? GafferState.overlay.opened === true : false
  function open() { if (GafferState.overlay) GafferState.overlay.openAt(root.anchorCenterX()) }
  function close() { if (GafferState.overlay) GafferState.overlay.dismiss() }

  FileView {
    path: root.home + "/.local/state/gaffer/bar.json"
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        var b = JSON.parse(text())
        if (b && typeof b === "object") root.barData = b
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.tick++
  }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.readout === "" ? "\uF1E3" : "\uF1E3 " + root.readout
    tooltipText: {
      if (!root.barData || root.barData.gw === undefined) return "FPL Gaffer"
      if (root.statto) {
        var s = ["Gameweek " + root.barData.gw]
        if (root.barData.live_matches > 0) s.push(root.barData.live_matches + " match(es) in play")
        else if (root.barData.next_kickoff) s.push("Next kick-off " + Fmt.kickoff(root.barData.next_kickoff))
        return s.join("\n")
      }
      var bits = ["GW" + root.barData.gw + ": " + root.barData.points + " points"]
      if (root.barData.provisional) bits.push("includes provisional bonus")
      if (root.barData.to_play) bits.push(root.barData.to_play + " still to play")
      if (root.barData.captain) bits.push("Captain " + root.barData.captain
                                      + " on " + root.barData.captain_points)
      if (root.barData.rank) bits.push("Overall rank " + Fmt.commas(root.barData.rank))
      if (root.barData.deadline_in) bits.push("Deadline in " + Fmt.countdown(root.barData.deadline_in))
      return bits.join("\n")
    }
    onPressed: function(b) {
      if (!GafferState.overlay) return
      if (GafferState.overlay.opened) GafferState.overlay.dismiss()
      else GafferState.overlay.openAt(root.anchorCenterX())
    }
  }
}
