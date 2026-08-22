import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

import qs.Commons
import qs.Ui
import "."
import "Fmt.js" as Fmt

// FPL Gaffer — a Fantasy Premier League dashboard for the Omarchy shell.
//
// Seven tabs: your Squad scored live, the Live match ticker and bonus race,
// the real Premier League Table, your mini-Leagues, a Fixtures difficulty
// grid, a Players explorer and a News/prices watchlist. Type to filter,
// Tab to cycle, Enter to act.
//
// All the thinking happens in gafferd.py, which writes a state file this
// overlay watches — so opening it is instant and nothing blocks on network.
// Every colour, font and gap comes from the shell's theme singletons, so
// Gaffer always matches the active Omarchy theme.
Item {
  id: root

  property string home: Quickshell.env("HOME")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int tabIndex: 0
  property int selectedIndex: 0
  property int tick: 0

  // Tabs marked `fpl` only exist when you're actually playing the game.
  readonly property var allTabs: [
    { id: "squad",    label: "Squad",    filter: "Find a player in your squad…", fpl: true },
    { id: "live",     label: "Live",     filter: "Filter matches…",          fpl: false },
    { id: "table",    label: "Table",    filter: "Filter clubs…",            fpl: false },
    { id: "leagues",  label: "Leagues",  filter: "Filter managers…",         fpl: true },
    { id: "fixtures", label: "Fixtures", filter: "Filter clubs…",            fpl: false },
    { id: "players",  label: "Players",  filter: "Search players…",          fpl: false },
    { id: "news",     label: "News",     filter: root.statto ? "Filter team news…"
                                                             : "Filter news and prices…", fpl: false }
  ]
  readonly property var tabs: {
    var out = []
    for (var i = 0; i < allTabs.length; i++)
      if (!root.statto || !allTabs[i].fpl) out.push(allTabs[i])
    return out
  }
  readonly property string tab: tabs[Math.min(tabIndex, tabs.length - 1)].id

  // ------------------------------------------------------------------ state
  property var state: ({})
  property var gsettings: ({ greeted: false, appMode: "gaffer", entryId: 0, mode: "center",
                             barIcon: true, barSection: "right", shortcut: "", watchlist: [],
                             fixtureWeeks: 6, leagueMemberCap: 120 })
  property bool loaded: false
  property string view: "list"           // list | greeter | settings

  // "gaffer" plays the fantasy game; "statto" just follows the football.
  readonly property string appMode: gsettings.appMode || "gaffer"
  readonly property bool statto: appMode === "statto"

  readonly property bool needsSetup: !root.statto
                                     && (!gsettings.entryId || state.needs_setup === true)
  readonly property bool dropdown: gsettings.mode === "dropdown"

  readonly property string stateDir: root.home + "/.local/state/gaffer"
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return decodeURIComponent(u.replace(/^file:\/\//, "")).replace(/\/$/, "")
  }

  // Seconds to the next deadline, ticking locally between daemon refreshes so
  // the clock never looks stuck.
  readonly property real deadlineLeft: {
    root.tick               // re-evaluate every second
    if (!root.state || !root.state.deadline) return -1
    var t = new Date(root.state.deadline).getTime()
    if (isNaN(t)) return -1
    return Math.max(0, (t - Date.now()) / 1000)
  }

  // ------------------------------------------------------------------ theme
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  // Secondary text stays well clear of the muted grey the theme offers —
  // dim enough to recede, never so dim it stops being readable.
  readonly property color dim: Util.alpha(foreground, 0.72)
  readonly property color fainter: Util.alpha(foreground, 0.5)
  readonly property color hairline: Util.alpha(foreground, 0.14)

  property int userWidth: 0
  property int userHeight: 0
  property int cardWidth: Math.max(Style.space(620),
    Math.min(userWidth > 0 ? userWidth : Style.space(940), panel.width - Style.gapsOut * 2))
  property int cardHeight: Math.max(Style.space(420),
    Math.min(userHeight > 0 ? userHeight : Style.space(660), panel.height - Style.gapsOut * 2))
  readonly property string sizeFile: root.stateDir + "/size"

  // ------------------------------------------------------ fixed meanings
  // Some colours carry meaning that must not drift with the theme: a yellow
  // card is yellow everywhere, a red card is red, and a difficulty ramp only
  // works if 1 is always the friendly end. These are fixed on purpose.
  //
  // Because they're fixed, a theme could in principle set a background that
  // sits right on top of one of them. Every fixed swatch therefore carries a
  // hairline outline picked against the theme's own background — light on
  // dark themes, dark on light ones — so its edge is always visible.
  readonly property bool lightBackground: {
    var c = root.background
    return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) > 0.5
  }
  readonly property color fixedOutline: root.lightBackground ? Qt.rgba(0, 0, 0, 0.55)
                                                             : Qt.rgba(1, 1, 1, 0.78)

  readonly property color cardYellow: "#e3b505"
  readonly property color cardRed:    "#c62828"

  // Difficulty 1 (kind) through 5 (brutal), with text picked for contrast
  // against the fill rather than against the theme.
  function fdrFill(fdr) {
    if (fdr <= 1) return "#157f4a"
    if (fdr === 2) return "#2f9e5f"
    if (fdr === 3) return "#b8860b"
    if (fdr === 4) return "#c2521c"
    return "#9b1c1c"
  }
  function fdrText(fdr) { return fdr === 3 ? "#12100a" : "#ffffff" }

  // Results, same idea: a win is green wherever you are.
  function resultFill(letter) {
    if (letter === "W") return "#157f4a"
    if (letter === "D") return "#6b6f76"
    return "#9b1c1c"
  }

  // Good news / bad news, borrowed from the theme so it re-skins with it.
  readonly property color goodColor: "#2f9e5f"
  readonly property color badColor: "#c1443c"
  function deltaColor(v) { return v > 0 ? goodColor : (v < 0 ? badColor : root.dim) }

  // Availability is semantic too: amber means a doubt, red means he's out.
  function statusColor(status) {
    if (status === "a" || !status) return root.foreground
    if (status === "d") return root.cardYellow
    return root.badColor
  }

  // ------------------------------------------------------------- persistence
  function saveSize() {
    Quickshell.execDetached(["bash", "-c",
      'mkdir -p "$(dirname "$1")" && printf "%s\\n" "$2" > "$1"', "--",
      root.sizeFile, root.cardWidth + "x" + root.cardHeight])
  }

  function saveSettings() {
    Quickshell.execDetached(["bash", "-c",
      'mkdir -p "$(dirname "$2")" && printf "%s\\n" "$1" > "$2"', "--",
      JSON.stringify(root.gsettings), root.stateDir + "/settings.json"])
  }

  function toggleWatch(playerId) {
    var list = (root.gsettings.watchlist || []).slice()
    var at = list.indexOf(playerId)
    if (at >= 0) list.splice(at, 1)
    else list.push(playerId)
    var next = JSON.parse(JSON.stringify(root.gsettings))
    next.watchlist = list
    root.gsettings = next
    root.saveSettings()
    root.refreshNow()
  }

  function isWatched(playerId) {
    return (root.gsettings.watchlist || []).indexOf(playerId) >= 0
  }

  function refreshNow() {
    refreshProc.running = false
    refreshProc.running = true
  }

  // -------------------------------------------------------------- lifecycle
  function open(payloadJson) { root.openAt(-1) }

  function openAt(anchor) {
    root.opened = true
    root.anchorX = anchor
    root.filterText = ""
    root.selectedIndex = 0
    root.view = root.gsettings.greeted === true ? "list" : "greeter"
    if (root.view === "greeter") { root.greetStep = 0; root.syncDrafts() }
    root.refreshNow()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function dismiss() {
    root.opened = false
    root.filterText = ""
  }

  function toggle() { if (root.opened) root.dismiss(); else root.openAt(-1) }

  property real anchorX: -1

  onTabsChanged: if (root.tabIndex >= root.tabs.length) root.tabIndex = 0

  function switchTab(delta) {
    root.tabIndex = (root.tabIndex + delta + root.tabs.length) % root.tabs.length
    root.selectedIndex = 0
    root.filterText = ""
  }

  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
  }

  Component.onCompleted: GafferState.overlay = root

  // ------------------------------------------------------------ data feeds
  FileView {
    path: root.stateDir + "/state.json"
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        var s = JSON.parse(text())
        if (s && typeof s === "object") { root.state = s; root.loaded = true }
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  FileView {
    path: root.stateDir + "/settings.json"
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        var s = JSON.parse(text())
        if (s && typeof s === "object") root.gsettings = s
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  FileView {
    path: root.sizeFile
    printErrors: false
    onLoaded: {
      var m = String(text() || "").trim().match(/^(\d+)x(\d+)$/)
      if (m) { root.userWidth = parseInt(m[1]); root.userHeight = parseInt(m[2]) }
    }
  }

  // The engine. Runs as a child of the shell so its life matches the shell's;
  // it takes a lock file, so a second copy simply steps aside.
  Process {
    id: daemon
    command: ["python3", root.pluginDir + "/gafferd.py", "daemon"]
    running: true
    onExited: daemonRestart.restart()
  }

  Timer {
    id: daemonRestart
    interval: 10000
    onTriggered: daemon.running = true
  }

  Process {
    id: refreshProc
    command: ["python3", root.pluginDir + "/gafferd.py", "once"]
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.tick++
  }

  // ---------------------------------------------------------------- resize
  component ResizeHandle: MouseArea {
    property int edgeX: 0
    property int edgeY: 0
    property int startW: 0
    property int startH: 0
    property real startGX: 0
    property real startGY: 0
    cursorShape: edgeX !== 0 && edgeY !== 0
      ? (edgeX === edgeY ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
      : (edgeX !== 0 ? Qt.SizeHorCursor : Qt.SizeVerCursor)
    onPressed: function(mouse) {
      startW = root.cardWidth
      startH = root.cardHeight
      var g = mapToItem(null, mouse.x, mouse.y)
      startGX = g.x
      startGY = g.y
    }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      var g = mapToItem(null, mouse.x, mouse.y)
      var fy = root.dropdown ? 1 : 2
      if (edgeX !== 0) root.userWidth = startW + 2 * edgeX * (g.x - startGX)
      if (edgeY !== 0) root.userHeight = startH + fy * edgeY * (g.y - startGY)
    }
    onReleased: root.saveSize()
  }

  // ---------------------------------------------------------------- drafts
  // Every choice is a draft until Save, so nothing touches your bindings,
  // your bar or your team until you say so.
  property int greetStep: 0
  property string draftAppMode: "gaffer"
  property string draftEntry: ""
  property bool draftBarIcon: true
  property string draftBarSection: "right"
  property string draftShortcut: ""
  property var draftNotify: ({})
  property bool capturing: false
  property string captureNote: ""
  property bool editingEntry: false

  function syncDrafts() {
    root.draftAppMode = root.gsettings.appMode || "gaffer"
    root.draftEntry = root.gsettings.entryId ? String(root.gsettings.entryId) : ""
    root.draftBarIcon = root.gsettings.barIcon !== false
    root.draftBarSection = root.gsettings.barSection || "right"
    root.draftShortcut = root.gsettings.shortcut || ""
    root.draftNotify = JSON.parse(JSON.stringify(root.gsettings.notify || {}))
    root.capturing = false
    root.captureNote = ""
    root.editingEntry = false
  }

  function setNotify(key, value) {
    var next = JSON.parse(JSON.stringify(root.draftNotify))
    next[key] = value
    root.draftNotify = next
  }

  function advanceGreeter() {
    if (root.draftAppMode === "statto") root.applyDrafts()   // nothing else to ask
    else root.greetStep = 1
  }

  function applyDrafts() {
    var id = parseInt(String(root.draftEntry).replace(/[^0-9]/g, "")) || 0
    if (root.draftAppMode === "gaffer" && !id) {
      root.greetStep = 1
      root.view = root.gsettings.greeted ? "settings" : "greeter"
      return
    }
    if (root.draftAppMode === "statto") root.draftBarSection = root.draftBarSection || "right"

    var next = JSON.parse(JSON.stringify(root.gsettings))
    next.greeted = true
    next.appMode = root.draftAppMode
    next.entryId = id
    next.barIcon = root.draftBarIcon
    next.barSection = root.draftBarSection
    next.shortcut = root.draftShortcut
    next.notify = root.draftNotify
    root.gsettings = next
    root.saveSettings()

    Quickshell.execDetached(["bash", root.pluginDir + "/gaffer-ctl.sh", "bar",
                             next.barIcon ? "on" : "off", next.barSection])
    if (next.shortcut)
      Quickshell.execDetached(["bash", root.pluginDir + "/gaffer-ctl.sh", "bind", next.shortcut])
    else
      Quickshell.execDetached(["bash", root.pluginDir + "/gaffer-ctl.sh", "unbind"])

    root.view = "list"
    root.greetStep = 0
    root.tabIndex = 0
    root.refreshNow()
  }

  function captureKey(event) {
    if (event.key === Qt.Key_Escape) { root.capturing = false; root.captureNote = ""; return }
    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
    var name = ""
    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) name = String.fromCharCode(65 + (event.key - Qt.Key_A))
    else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) name = String.fromCharCode(48 + (event.key - Qt.Key_0))
    else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F12) name = "F" + (event.key - Qt.Key_F1 + 1)
    if (name === "") return
    if (mods.length === 0) { root.captureNote = "Add a modifier — SUPER, CTRL or ALT"; return }
    root.draftShortcut = mods.join(" + ") + " + " + name
    root.captureNote = ""
    root.capturing = false
  }

  // -------------------------------------------------------------------- ui
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "gaffer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.dropdown ? "transparent" : root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter

      states: State {
        name: "dropdown"
        when: root.dropdown
        AnchorChanges {
          target: card
          anchors.horizontalCenter: undefined
          anchors.verticalCenter: undefined
          anchors.top: card.parent.top
        }
        PropertyChanges {
          target: card
          anchors.topMargin: Style.space(46)
          x: Math.max(Style.gapsOut, Math.min(panel.width - card.width - Style.gapsOut,
               (root.anchorX >= 0 ? root.anchorX : panel.width / 2) - card.width / 2))
        }
      }

      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      ResizeHandle { edgeX: -1; edgeY: 0; width: Style.space(6); anchors { left: parent.left; top: parent.top; bottom: parent.bottom } }
      ResizeHandle { edgeX: 1;  edgeY: 0; width: Style.space(6); anchors { right: parent.right; top: parent.top; bottom: parent.bottom } }
      ResizeHandle { edgeX: 0;  edgeY: 1; height: Style.space(6); anchors { bottom: parent.bottom; left: parent.left; right: parent.right } }
      ResizeHandle { edgeX: 1;  edgeY: 1; width: Style.space(12); height: Style.space(12); anchors { right: parent.right; bottom: parent.bottom } }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // Capturing a hotkey swallows everything until a valid combo lands.
          if (root.capturing) {
            root.captureKey(event)
            event.accepted = true
            return
          }

          if (root.view === "greeter") {
            if (event.key === Qt.Key_Escape) {
              if (root.greetStep === 1) root.greetStep = 0
              else root.dismiss()
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
              if (root.greetStep === 0)
                root.draftAppMode = root.draftAppMode === "gaffer" ? "statto" : "gaffer"
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.greetStep === 0) root.advanceGreeter()
              else root.applyDrafts()
            } else if (event.key === Qt.Key_Backspace) {
              root.draftEntry = root.draftEntry.slice(0, -1)
            } else if (event.text && event.text.match(/[0-9]/)) {
              root.greetStep = 1
              root.draftEntry += event.text
            }
            event.accepted = true
            return
          }

          if (root.view === "settings") {
            if (event.key === Qt.Key_Escape) {
              root.view = "list"
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.applyDrafts()
            } else if (event.key === Qt.Key_Backspace) {
              root.draftEntry = root.draftEntry.slice(0, -1)
            } else if (event.text && event.text.match(/[0-9]/)) {
              root.draftEntry += event.text
            }
            event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Comma && (event.modifiers & Qt.ControlModifier)) {
            root.syncDrafts()
            root.view = "settings"
            event.accepted = true
          } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
            root.refreshNow()
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            root.switchTab(1); event.accepted = true
          } else if (event.key === Qt.Key_Backtab) {
            root.switchTab(-1); event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            root.switchTab(-1); event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.switchTab(1); event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.selectedIndex = Math.max(0, root.selectedIndex - 1); event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.selectedIndex = root.selectedIndex + 1; event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.selectedIndex = Math.max(0, root.selectedIndex - 10); event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.selectedIndex = root.selectedIndex + 10; event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (tabLoader.item && typeof tabLoader.item.activate === "function")
              tabLoader.item.activate(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace) {
            root.setFilter(root.filterText.slice(0, -1)); event.accepted = true
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text); event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          height: root.view === "greeter" ? 0 : headerRow.implicitHeight
          visible: root.view !== "greeter"
          clip: true

          Row {
            id: headerRow
            width: parent.width
            spacing: Style.spacing.lg

            Column {
              width: parent.width - liveBox.width - deadlineBox.width - Style.spacing.lg * 2
              spacing: Style.space(2)

              Text {
                text: root.statto ? "Premier League" : (root.state.team_name || "FPL Gaffer")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                text: {
                  if (root.needsSetup) return "No team linked yet — press Ctrl+, to set one"
                  if (root.statto) {
                    var s = ["Gameweek " + (root.state.gw || "—")]
                    if (root.state.live_matches > 0)
                      s.push(root.state.live_matches + (root.state.live_matches === 1
                             ? " match in play" : " matches in play"))
                    else if (root.state.next_match)
                      s.push("Next: " + root.state.next_match + " " + Fmt.kickoff(root.state.next_kickoff))
                    return s.join("  ·  ")
                  }
                  var bits = []
                  if (root.state.manager) bits.push(root.state.manager)
                  if (root.state.overall_rank)
                    bits.push("OR " + Fmt.commas(root.state.overall_rank)
                              + " of " + Fmt.rank(root.state.total_players))
                  if (root.state.overall_points !== undefined)
                    bits.push(root.state.overall_points + " pts")
                  return bits.join("  ·  ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: parent.width
              }
            }

            // Live gameweek score
            Column {
              id: liveBox
              width: Style.space(150)
              spacing: Style.space(2)

              Row {
                spacing: Style.spacing.sm
                anchors.right: parent.right

                Text {
                  text: root.statto
                          ? String(root.state.live_matches || 0)
                          : (root.state.live_points !== undefined ? String(root.state.live_points) : "—")
                  color: root.state.live_now ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                  font.bold: true
                  anchors.bottom: parent.bottom
                }
                Text {
                  text: root.statto ? "live" : "GW" + (root.state.gw || "—")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(4)
                }
              }

              Text {
                anchors.right: parent.right
                text: {
                  if (root.needsSetup) return ""
                  if (root.statto) {
                    var played = (root.state.league_table || []).length
                             ? (root.state.league_table[0].played || 0) : 0
                    return (root.state.fixtures || []).length + " fixtures this week"
                  }
                  var bits = []
                  if (root.state.players_played !== undefined)
                    bits.push(root.state.players_played + " played")
                  if (root.state.players_to_play)
                    bits.push(root.state.players_to_play + " to play")
                  if (root.state.chip) bits.push(root.state.chip.toUpperCase())
                  if (!root.state.bonus_added && root.state.live_now) bits.push("prov. bonus")
                  return bits.join(" · ")
                }
                color: root.state.live_now ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Deadline
            Column {
              id: deadlineBox
              visible: !root.statto
              width: root.statto ? 0 : Style.space(130)
              spacing: Style.space(2)

              Text {
                anchors.right: parent.right
                text: root.deadlineLeft >= 0 ? Fmt.countdown(root.deadlineLeft) : "—"
                color: root.deadlineLeft >= 0 && root.deadlineLeft < 10800 ? root.badColor : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                anchors.right: parent.right
                text: root.state.next_gw ? "to GW" + root.state.next_gw + " deadline" : "season over"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: root.hairline
          visible: root.view !== "greeter"
        }

        // -------------------------------------------------------- tab strip
        Row {
          id: tabStrip
          visible: root.view === "list"
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.tabs
            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property bool current: index === root.tabIndex

              width: (tabStrip.width - Style.space(4) * (root.tabs.length - 1)) / root.tabs.length
              height: Math.max(Style.space(28), Style.font.body + Style.spacing.controlPaddingY * 2)
              radius: root.cornerRadius
              color: current ? root.selectedBackground : "transparent"

              Text {
                anchors.centerIn: parent
                text: modelData.label
                color: current ? root.selectedText : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: current
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.tabIndex = index; root.selectedIndex = 0; root.filterText = "" }
              }
            }
          }
        }

        // ----------------------------------------------------- filter field
        Rectangle {
          visible: root.view === "list"
          width: parent.width
          height: Math.max(Style.space(26), Style.font.body + Style.spacing.inputPaddingY * 2)
          radius: root.cornerRadius
          color: Util.alpha(root.foreground, 0.05)

          Text {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            verticalAlignment: Text.AlignVCenter
            text: root.filterText !== "" ? root.filterText : root.tabs[root.tabIndex].filter
            color: root.filterText !== "" ? root.foreground : root.fainter
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        // --------------------------------------------------------- contents
        Item {
          width: parent.width
          height: parent.height - y

          // First run: choose how you want to use it, then (only if you
          // play the fantasy game) which team is yours.
          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Style.space(40), Style.space(560))
            spacing: Style.spacing.lg
            visible: root.view === "greeter"

            Text {
              width: parent.width
              text: "FPL Gaffer"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            // Step one — which of the two jobs should it do?
            Column {
              width: parent.width
              spacing: Style.spacing.md
              visible: root.greetStep === 0

              Text {
                width: parent.width
                text: "How do you want to use it?"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
              }

              Repeater {
                model: [
                  { id: "gaffer", title: "FPL Gaffer",
                    blurb: "You play Fantasy Premier League. Adds your squad scored live, "
                           + "provisional bonus, your mini-leagues, price moves and deadline warnings." },
                  { id: "statto", title: "Premier League statto",
                    blurb: "You just follow the football. Scores, the league table, fixtures "
                           + "and player stats — no fantasy team needed." }
                ]
                delegate: Rectangle {
                  required property var modelData
                  readonly property bool chosen: root.draftAppMode === modelData.id

                  width: parent.width
                  height: choiceCol.implicitHeight + Style.spacing.lg * 2
                  radius: root.cornerRadius
                  color: chosen ? Util.alpha(root.accent, 0.14)
                                : Util.alpha(root.foreground, 0.05)
                  border.width: chosen ? 1 : 0
                  border.color: root.accent

                  Column {
                    id: choiceCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Style.spacing.lg
                    spacing: Style.space(3)

                    Text {
                      text: modelData.title
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      text: modelData.blurb
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.draftAppMode = modelData.id; root.advanceGreeter() }
                  }
                }
              }

              Text {
                width: parent.width
                text: "↑↓ to choose  ·  Enter to continue  ·  Esc to close"
                color: root.fainter
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }
            }

            // Step two — the team number, asked for only in Gaffer mode.
            Column {
              width: parent.width
              spacing: Style.spacing.lg
              visible: root.greetStep === 1

              Text {
                width: parent.width
                text: "Type your Fantasy Premier League team number. You'll find it in the "
                      + "address bar when you look at your own points on the FPL site — the "
                      + "digits after /entry/."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
              }
              Rectangle {
                width: parent.width
                height: Math.max(Style.space(38), Style.font.heading + Style.spacing.inputPaddingY * 2)
                radius: root.cornerRadius
                color: Util.alpha(root.foreground, 0.06)
                border.width: 1
                border.color: root.accent

                Text {
                  anchors.centerIn: parent
                  text: root.draftEntry !== "" ? root.draftEntry : "your team number"
                  color: root.draftEntry !== "" ? root.foreground : root.fainter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: root.draftEntry !== ""
                }
              }
              Text {
                width: parent.width
                text: "Enter to save  ·  Esc to go back"
                color: root.fainter
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }

          // Settings, opened with Ctrl+, — same form the greeter uses, plus
          // the bits you'd only change later.
          Loader {
            anchors.fill: parent
            visible: root.view === "settings"
            active: visible
            source: "SettingsView.qml"
            onLoaded: if (item) item.app = root
          }

          // Waiting for the first refresh.
          Text {
            anchors.centerIn: parent
            visible: root.view === "list" && !root.loaded
            text: "Fetching from the Fantasy Premier League…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          Loader {
            id: tabLoader
            anchors.fill: parent
            visible: root.view === "list" && root.loaded
            active: visible
            source: {
              switch (root.tab) {
                case "squad":    return "SquadTab.qml"
                case "live":     return "LiveTab.qml"
                case "table":    return "TableTab.qml"
                case "leagues":  return "LeaguesTab.qml"
                case "fixtures": return "FixturesTab.qml"
                case "players":  return "PlayersTab.qml"
                case "news":     return "NewsTab.qml"
              }
              return ""
            }
            onLoaded: if (item) item.app = root
          }
        }

        // ----------------------------------------------------------- footer
        Item {
          width: parent.width
          height: footerText.implicitHeight
          visible: root.view === "list"

          Text {
            id: footerText
            anchors.left: parent.left
            text: "Tab tabs · ↑↓ move · Enter act · Ctrl+, settings · Ctrl+R refresh · Esc close"
            color: root.fainter
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            text: (root.state.live_now ? "live · " : "") + "updated " + Fmt.ago(root.state.updated)
            color: root.state.live_now ? root.accent : root.fainter
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
