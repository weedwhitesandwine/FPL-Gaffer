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
  // that stays up for days. So the open refuses on its own terms and hands
  // back nothing at all rather than something over the ceiling. O_NOFOLLOW
  // covers the final name only — a link in a parent directory is still
  // followed, which is the same trust already placed in the home directory.
  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except FileNotFoundError:',
    '    raise SystemExit(2)',
    'except OSError:',
    '    raise SystemExit(1)',
    'try:',
    '    if not stat.S_ISREG(os.fstat(fd).st_mode):',
    '        raise SystemExit(1)',
    '    with os.fdopen(fd, "rb") as handle:',
    '        fd = None',
    '        raw = handle.read(ceiling + 1)',
    'except OSError:',
    '    raise SystemExit(1)',
    'finally:',
    '    if fd is not None:',
    '        os.close(fd)',
    'if len(raw) > ceiling:',
    '    raise SystemExit(1)',
    'sys.stdout.buffer.write(raw)'
  ].join("
")
  moduleName: "io.github.weedwhitesandwine.gaffer"

  property string home: Quickshell.env("HOME")
  property var barData: ({})
  property int tick: 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Counts down between engine writes rather than repeating whatever the
  // last one said. `tick` is what re-evaluates it; without the subtraction it
  // was a ticking property that never changed, and the tooltip below read the
  // frozen number straight from the file.
  readonly property real deadlineLeft: {
    root.tick
    if (!root.barData || root.barData.deadline_at === undefined
        || root.barData.deadline_at === null) {
      if (!root.barData || root.barData.deadline_in === undefined
          || root.barData.deadline_in === null) return -1
      return root.barData.deadline_in
    }
    return Math.max(0, root.barData.deadline_at - (Date.now() / 1000))
  }

  readonly property bool statto: root.barData && root.barData.mode === "statto"

  // ---------------------------------------------------------------- settings
  // The flash is the bar icon's own business, so it lives in the widget's
  // shell.json entry rather than in the engine's settings file: one thing
  // writes each, and the bar's own settings panel can turn it off.
  readonly property bool blinkOnEvents: root.setting("blinkOnEvents", true) !== false

  // ------------------------------------------------------------------- flash
  // The engine counts the things it has told you about the football. When the
  // count moves, something happened in a match, and the icon says so for a
  // couple of seconds — a glance at the bar, rather than a toast you have to
  // still be at the machine to catch.
  property int lastSeq: -1
  property bool flash: false

  onBarDataChanged: {
    var seq = Number(root.barData ? root.barData.event_seq : NaN)
    if (!isFinite(seq)) return
    // The first reading only establishes where the count is. Flashing on it
    // would mean a flash at every login for a goal scored last Saturday.
    if (root.lastSeq >= 0 && seq > root.lastSeq && root.blinkOnEvents)
      eventFlash.restart()
    root.lastSeq = seq
  }

  SequentialAnimation {
    id: eventFlash
    loops: 3
    PropertyAction { target: root; property: "flash"; value: true }
    PauseAnimation { duration: 320 }
    PropertyAction { target: root; property: "flash"; value: false }
    PauseAnimation { duration: 320 }
  }

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

  // ------------------------------------------------------------ popout order
  // The bar holds one popout open at a time and asks the outgoing one to close
  // when another opens. Gaffer is a layer of its own rather than one of the
  // bar's popup cards, so it has to say when it is up: without this it stays
  // over the clock or the weather with an exclusive keyboard grab, and their
  // keys go nowhere.
  //
  // The token registered is the overlay itself, not this widget. There is one
  // overlay and one widget per monitor, and if each screen registered itself
  // the second would be told to close the first — which is the same overlay.
  readonly property var popoutToken: GafferState.overlay
  function closeForPopoutSwitch() {
    if (GafferState.overlay) GafferState.overlay.closeForPopoutSwitch()
  }

  onOpenedChanged: {
    if (!root.bar || !root.popoutToken) return
    if (root.opened) root.bar.requestPopout(root.popoutToken)
    else if (root.bar.activePopout === root.popoutToken)
      root.bar.releasePopout(root.popoutToken)
  }

  function refreshNow() {
    if (GafferState.overlay) GafferState.overlay.refreshNow()
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

  // Left button opens the dashboard; middle button asks the engine for fresh
  // numbers without opening anything, which is the whole gesture for "is that
  // score right?" while you are looking at the bar.
  function press(b) {
    if (!GafferState.overlay) return
    if (b === Qt.MiddleButton) { root.refreshNow(); return }
    if (GafferState.overlay.opened) GafferState.overlay.dismiss()
    else GafferState.overlay.openAt(root.anchorCenterX())
  }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uF1E3"
    active: root.flash
    activeColor: Color.accent
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
      if (root.deadlineLeft > 0) bits.push("Deadline in " + Fmt.countdown(root.deadlineLeft))
      return root.plain(bits.join("\n"))
    }
    onPressed: function(b) { root.press(b) }
  }
}
