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

  // A file this plugin reads but does not own can be anything by the time it
  // is opened: a link pointing elsewhere, a pipe that never produces anything,
  // or something far too large. `head` opens a path the ordinary way and would
  // follow the first and wait forever on the second, inside a shell process
  // that stays up for days. So the open itself refuses — no links, no waiting,
  // nothing that is not a plain file — and hands back nothing at all rather
  // than something over the ceiling.
  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except OSError:',
    '    raise SystemExit',
    'try:',
    '    if not stat.S_ISREG(os.fstat(fd).st_mode):',
    '        raise SystemExit',
    '    with os.fdopen(fd, "rb") as handle:',
    '        raw = handle.read(ceiling + 1)',
    'finally:',
    '    try:',
    '        os.close(fd)',
    '    except OSError:',
    '        pass',
    'if len(raw) <= ceiling:',
    '    sys.stdout.buffer.write(raw)'
  ].join("\n")
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

  // Just the ball. A bar icon should say "this is here", not report a score
  // you did not ask to see every time you glance at the clock. Points, rank,
  // deadline and what is in play all live in the tooltip.

  function anchorCenterX() {
    var g = button.mapToItem(null, button.width / 2, 0)
    return g.x
  }

  // Shape contract for shell summon/toggle routing — forward to the overlay.
  readonly property bool opened: GafferState.overlay ? GafferState.overlay.opened === true : false
  function open() { if (GafferState.overlay) GafferState.overlay.openAt(root.anchorCenterX()) }
  function close() { if (GafferState.overlay) GafferState.overlay.dismiss() }
  function toggle() {
    if (!GafferState.overlay) return
    if (GafferState.overlay.opened) root.close()
    else root.open()
  }

  readonly property string stateDir: {
    var base = Quickshell.env("XDG_STATE_HOME")
    return (base ? base : root.home + "/.local/state") + "/gaffer"
  }

  // bar.json is a dozen short values, but it lives on disk where a restored
  // backup could put anything, and the bar is up for as long as the session is.
  // FileView cannot stop short of the end of a file, so it does not do the
  // reading: it watches with blockAllReads set, never pulling the file into
  // memory, and `head` does the read with the ceiling in front of it.
  readonly property int barCeiling: 64 * 1024

  FileView {
    path: root.stateDir + "/bar.json"
    printErrors: false
    watchChanges: true
    blockAllReads: true
    preload: false
    onFileChanged: root.readBar()
  }

  function readBar() { barReader.running = false; barReader.running = true }

  Process {
    id: barReader
    command: ["python3", "-c", root.safeRead,
              root.stateDir + "/bar.json", String(root.barCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var b = JSON.parse(text)
          if (b && typeof b === "object" && !Array.isArray(b)) root.barData = b
        } catch (e) {}
      }
    }
  }

  Component.onCompleted: root.readBar()

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.tick++
  }

  // The bar tooltip is drawn by Omarchy's own button, whose text element
  // leaves Qt to guess whether a string is plain writing or markup. The
  // captain's name in there comes from the internet, so strip anything that
  // could be read as a tag before it reaches a renderer we do not own.
  // Everything the overlay draws itself is pinned to plain text at source.
  function plain(s) { return String(s).replace(/[<>]/g, "") }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uF1E3"
    tooltipText: {
      if (!root.barData || root.barData.gw === undefined) return "FPL Gaffer"
      if (root.statto) {
        var s = ["Gameweek " + root.barData.gw]
        if (root.barData.live_matches > 0) s.push(root.barData.live_matches + " match(es) in play")
        else if (root.barData.next_kickoff) s.push("Next kick-off " + Fmt.kickoff(root.barData.next_kickoff))
        return root.plain(s.join("\n"))
      }
      var bits = ["GW" + root.barData.gw + ": " + root.barData.points + " points"]
      if (root.barData.provisional) bits.push("includes provisional bonus")
      if (root.barData.to_play) bits.push(root.barData.to_play + " still to play")
      if (root.barData.captain) bits.push("Captain " + root.barData.captain
                                      + " on " + root.barData.captain_points)
      if (root.barData.rank) bits.push("Overall rank " + Fmt.commas(root.barData.rank))
      if (root.barData.deadline_in) bits.push("Deadline in " + Fmt.countdown(root.barData.deadline_in))
      return root.plain(bits.join("\n"))
    }
    onPressed: function(b) {
      if (!GafferState.overlay) return
      if (GafferState.overlay.opened) GafferState.overlay.dismiss()
      else GafferState.overlay.openAt(root.anchorCenterX())
    }
  }
}
