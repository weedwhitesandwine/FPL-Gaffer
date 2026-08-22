import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// Your fifteen, scored live — as a pitch or as a list.
//
// The pitch is the default because a squad is a shape, not a spreadsheet:
// you read a formation faster than you read eleven rows. The list is there
// when you want the numbers side by side.
//
// Points shown are what each player is actually contributing right now —
// captain doubled, bench greyed unless Bench Boost is on or an auto-sub is
// projected to bring them in, and likely bonus folded in before the game
// makes it official.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""
  readonly property var squad: st.squad || []

  property string layout: "pitch"          // pitch | list

  readonly property var rows: {
    var out = []
    for (var i = 0; i < squad.length; i++) {
      var r = squad[i]
      if (!Fmt.matches(r.name, q) && !Fmt.matches(r.team, q) && !Fmt.matches(r.pos, q)) continue
      out.push(r)
    }
    return out
  }

  // The starting XI split into its four lines, plus the bench.
  function line(pos) {
    var out = []
    for (var i = 0; i < squad.length; i++)
      if (squad[i].position <= 11 && squad[i].pos === pos) out.push(squad[i])
    return out
  }
  readonly property var keepers:  line("GKP")
  readonly property var defence:  line("DEF")
  readonly property var midfield: line("MID")
  readonly property var attack:   line("FWD")
  readonly property var bench: {
    var out = []
    for (var i = 0; i < squad.length; i++) if (squad[i].position > 11) out.push(squad[i])
    return out
  }
  readonly property string formation:
    defence.length + "-" + midfield.length + "-" + attack.length

  function activate(index) {
    var r = rows[Math.min(index, rows.length - 1)]
    if (r && app) app.toggleWatch(r.id)
  }

  // Availability, said in as few characters as will fit on a card.
  function flag(p) {
    if (!p || p.status === "a" || !p.status) return ""
    if (p.status === "d")
      return (p.chance !== null && p.chance !== undefined) ? p.chance + "%" : "DOUBT"
    if (p.status === "s") return "SUSP"
    if (p.status === "i") return "INJ"
    if (p.status === "u") return "GONE"
    return "OUT"
  }
  function flagColor(p) {
    if (!p) return "transparent"
    return p.status === "d" ? (app ? app.cardYellow : "#e3b505")
                            : (app ? app.cardRed : "#c62828")
  }

  // Anyone in the eleven who might not play. This is the line you actually
  // want to see before a deadline.
  readonly property var doubts: {
    var out = []
    for (var i = 0; i < squad.length; i++) {
      var p = squad[i]
      if (p.position > 11) continue
      if (p.status && p.status !== "a") out.push(p)
    }
    return out
  }

  // -------------------------------------------------------------- summary
  component Stat: Column {
    property string k: ""
    property string v: ""
    property color tone: app ? app.foreground : "#fff"
    spacing: Style.space(1)
    Text {
      text: parent.k
      color: app ? app.fainter : "#888"
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.caption
    }
    Text {
      text: parent.v
      color: parent.tone
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  // ---------------------------------------------------------- player card
  component PlayerCard: Rectangle {
    id: pc
    property var p: null
    property bool compact: false

    readonly property bool counting: p ? p.counting : false
    readonly property bool matched: {
      if (!p) return false
      var needle = tab.q
      if (!String(needle || "").trim()) return true
      return Fmt.matches(p.name, needle) || Fmt.matches(p.team, needle)
             || Fmt.matches(p.pos, needle)
    }
    readonly property bool filtering: String(tab.q || "").trim() !== ""
    readonly property bool selected: {
      if (!app || !p) return false
      var sel = tab.rows[app.selectedIndex]
      return !!sel && sel.id === p.id
    }

    width: compact ? Style.space(104) : Style.space(124)
    height: cardCol.implicitHeight + Style.spacing.sm * 2
    radius: app ? Math.max(app.cornerRadius, Style.space(3)) : 0
    color: selected ? (app ? app.selectedBackground : "#222")
                    : Util.alpha(app ? app.foreground : "#fff", counting ? 0.10 : 0.05)
    opacity: !matched ? 0.2 : (counting ? 1.0 : 0.66)

    // A live match gets a lit edge; the captain gets a solid one.
    border.width: (matched && filtering) || (p && p.live) || (p && p.captain) ? 1 : 0
    border.color: p && p.captain ? (app ? app.accent : "#fff")
                : (matched && filtering) ? (app ? app.accent : "#fff")
                : Util.alpha(app ? app.accent : "#fff", 0.55)

    Behavior on opacity { NumberAnimation { duration: 160 } }

    Column {
      id: cardCol
      anchors.centerIn: parent
      width: pc.width - Style.spacing.sm * 2
      spacing: Style.space(1)

      // points, big — the number you actually look for
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(3)

        Text {
          text: pc.p ? String(pc.p.applied) : "0"
          color: pc.p && pc.p.applied > 0 ? (app ? app.foreground : "#fff")
                                          : (app ? app.dim : "#aaa")
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.heading
          font.bold: true
        }
        Text {
          visible: pc.p && pc.p.provisional > 0
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(2)
          text: pc.p ? "~" + pc.p.provisional : ""
          color: app ? app.accent : "#fff"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: pc.p ? pc.p.name : ""
        color: app && pc.p ? app.statusColor(pc.p.status) : "#fff"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.bodySmall
        font.bold: pc.p && pc.p.captain
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: {
          if (!pc.p) return ""
          if (pc.p.live) return pc.p.team + " · " + pc.p.when
          if (pc.p.played) return pc.p.team + " · " + pc.p.minutes + "'"
          return pc.p.team + " · " + pc.p.when
        }
        color: pc.p && pc.p.live ? (app ? app.accent : "#fff") : (app ? app.fainter : "#888")
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // Availability — fixed amber for a doubt, fixed red for an out,
      // outlined so it reads on any theme. Given its own line so it can
      // never crowd the kick-off time above it.
      Rectangle {
        visible: tab.flag(pc.p) !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        width: flagText.implicitWidth + Style.space(8)
        height: visible ? flagText.implicitHeight + Style.space(3) : 0
        radius: Style.space(2)
        color: tab.flagColor(pc.p)
        border.width: 1
        border.color: app ? app.fixedOutline : "#fff"

        Text {
          id: flagText
          anchors.centerIn: parent
          text: tab.flag(pc.p)
          color: pc.p && pc.p.status === "d" ? "#12100a" : "#ffffff"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      // what he actually did — only when there's something to say
      Text {
        visible: text !== ""
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: {
          if (!pc.p) return ""
          var bits = []
          if (pc.p.goals) bits.push(pc.p.goals + "G")
          if (pc.p.assists) bits.push(pc.p.assists + "A")
          if (pc.p.cs) bits.push("CS")
          if (pc.p.saves >= 3) bits.push(pc.p.saves + "SV")
          if (pc.p.red) bits.push("RC")
          return bits.join(" ")
        }
        color: pc.p && pc.p.red ? (app ? app.badColor : "#a33") : (app ? app.dim : "#aaa")
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
      }
    }

    // Captain's armband, top right
    Rectangle {
      visible: pc.p && (pc.p.captain || pc.p.vice)
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(3)
      width: Style.space(14); height: Style.space(14)
      radius: width / 2
      color: pc.p && pc.p.captain ? (app ? app.accent : "#fff") : "transparent"
      border.width: pc.p && pc.p.vice ? 1 : 0
      border.color: app ? app.dim : "#888"
      Text {
        anchors.centerIn: parent
        text: pc.p && pc.p.captain ? "C" : "V"
        color: pc.p && pc.p.captain ? (app ? app.background : "#000") : (app ? app.dim : "#888")
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    // Auto-sub arrow, top left
    Text {
      visible: pc.p && (pc.p.subbed_in || pc.p.subbed_out)
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: Style.space(3)
      text: pc.p && pc.p.subbed_in ? "↑" : "↓"
      color: pc.p && pc.p.subbed_in ? (app ? app.goodColor : "#3a3") : (app ? app.badColor : "#a33")
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    // A quiet pulse while his match is actually being played
    Rectangle {
      visible: pc.p && pc.p.live
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(4)
      width: Style.space(5); height: Style.space(5)
      radius: width / 2
      color: app ? app.accent : "#fff"
      SequentialAnimation on opacity {
        running: pc.p && pc.p.live
        loops: Animation.Infinite
        NumberAnimation { from: 1.0; to: 0.25; duration: 900; easing.type: Easing.InOutQuad }
        NumberAnimation { from: 0.25; to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (!app || !pc.p) return
        for (var i = 0; i < tab.rows.length; i++)
          if (tab.rows[i].id === pc.p.id) { app.selectedIndex = i; break }
      }
      onDoubleClicked: if (app && pc.p) app.toggleWatch(pc.p.id)
    }
  }

  // ------------------------------------------------------------------- ui
  Column {
    anchors.fill: parent
    spacing: Style.spacing.sm

    // Summary strip
    Rectangle {
      width: parent.width
      height: summary.implicitHeight + Style.spacing.md * 2
      radius: app ? app.cornerRadius : 0
      color: Util.alpha(app ? app.foreground : "#fff", 0.05)

      Row {
        id: summary
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.md
        spacing: Style.spacing.xl

        Stat { k: "Formation"; v: tab.formation }
        Stat {
          k: "Captain"
          v: (tab.st.captain || "—") + (tab.st.captain_points ? "  " + tab.st.captain_points : "")
        }
        Stat { k: "Bench"; v: (tab.st.bench_points !== undefined ? tab.st.bench_points + " pts" : "—") }
        Stat { k: "Value"; v: Fmt.money(tab.st.value) + " · " + Fmt.money(tab.st.bank) + " itb" }
        Stat {
          k: "Transfers"
          v: (tab.st.transfers || 0) + (tab.st.hits ? "  −" + tab.st.hits : "")
          tone: tab.st.hits ? (app ? app.badColor : "#a33") : (app ? app.foreground : "#fff")
        }
        Stat {
          k: "Chip"
          v: tab.st.chip ? String(tab.st.chip).toUpperCase() : "none"
          tone: tab.st.chip ? (app ? app.accent : "#fff") : (app ? app.foreground : "#fff")
        }
      }

      // Pitch / list switch
      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.md
        spacing: Style.space(3)

        Repeater {
          model: [{ id: "pitch", label: "Pitch" }, { id: "list", label: "List" }]
          delegate: Rectangle {
            required property var modelData
            readonly property bool active: tab.layout === modelData.id
            width: switchLabel.implicitWidth + Style.spacing.lg
            height: Math.max(Style.space(22), Style.font.caption + Style.spacing.sm * 2)
            radius: app ? app.cornerRadius : 0
            color: active ? (app ? app.selectedBackground : "#222")
                          : Util.alpha(app ? app.foreground : "#fff", 0.05)
            Text {
              id: switchLabel
              anchors.centerIn: parent
              text: modelData.label
              color: active ? (app ? app.selectedText : "#fff") : (app ? app.dim : "#aaa")
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
              font.bold: active
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: tab.layout = modelData.id
            }
          }
        }
      }
    }

    // Availability warnings, ahead of everything else — including the reason
    // the club gave, because "75%" on its own never tells you enough.
    Rectangle {
      width: parent.width
      height: visible ? doubtText.implicitHeight + Style.spacing.sm * 2 : 0
      visible: tab.doubts.length > 0
      radius: app ? app.cornerRadius : 0
      color: Util.alpha(app ? app.cardRed : "#c62828", 0.16)
      border.width: 1
      border.color: Util.alpha(app ? app.cardRed : "#c62828", 0.55)

      Text {
        id: doubtText
        anchors.fill: parent
        anchors.margins: Style.spacing.sm
        text: {
          var bits = []
          for (var i = 0; i < tab.doubts.length; i++) {
            var p = tab.doubts[i]
            var line = p.name + " (" + tab.flag(p) + ")"
            if (p.news) line += " — " + p.news
            bits.push(line)
          }
          var head = tab.doubts.length === 1 ? "1 doubt in your XI:  "
                                             : tab.doubts.length + " doubts in your XI:  "
          return head + bits.join("     ")
        }
        color: app ? app.foreground : "#fff"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    // Projected auto-subs
    Rectangle {
      width: parent.width
      height: visible ? subsText.implicitHeight + Style.spacing.sm * 2 : 0
      visible: (tab.st.autosubs || []).length > 0
      radius: app ? app.cornerRadius : 0
      color: Util.alpha(app ? app.accent : "#fff", 0.12)

      Text {
        id: subsText
        anchors.fill: parent
        anchors.margins: Style.spacing.sm
        text: {
          var subs = tab.st.autosubs || []
          var bits = []
          for (var i = 0; i < subs.length; i++) bits.push(subs[i].on + " for " + subs[i].off)
          return "Auto-subs projected:  " + bits.join(",  ")
        }
        color: app ? app.foreground : "#fff"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    // ------------------------------------------------------------- pitch
    Item {
      id: pitchArea
      width: parent.width
      height: parent.height - y
      visible: tab.layout === "pitch"

      readonly property int benchHeight: Style.space(118)

      Rectangle {
        id: pitch
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: parent.height - pitchArea.benchHeight - Style.spacing.sm
        radius: app ? app.cornerRadius : 0
        // A pitch has to read as a pitch, but it must not shout over the
        // theme — so the markings are the theme's own foreground at a
        // whisper, over the theme's own background.
        color: Util.alpha(app ? app.foreground : "#fff", 0.03)
        clip: true

        // Mown bands, running across the pitch the way you'd see them from
        // behind the goal. Barely there on purpose — they should register as
        // texture, never as furniture.
        Column {
          anchors.fill: parent
          Repeater {
            model: 8
            delegate: Rectangle {
              required property int index
              width: pitch.width
              height: pitch.height / 8
              color: index % 2 === 0 ? Util.alpha(app ? app.foreground : "#fff", 0.014)
                                     : "transparent"
            }
          }
        }

        // Markings
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          color: Util.alpha(app ? app.foreground : "#fff", 0.07)
          visible: false
        }
        Rectangle {                                    // halfway line
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: 1
          color: Util.alpha(app ? app.foreground : "#fff", 0.08)
        }
        Rectangle {                                    // centre circle
          anchors.centerIn: parent
          width: Math.min(pitch.width, pitch.height) * 0.28
          height: width
          radius: width / 2
          color: "transparent"
          border.width: 1
          border.color: Util.alpha(app ? app.foreground : "#fff", 0.08)
        }
        Rectangle {                                    // penalty box, top
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          width: pitch.width * 0.42
          height: pitch.height * 0.14
          color: "transparent"
          border.width: 1
          border.color: Util.alpha(app ? app.foreground : "#fff", 0.07)
        }
        Rectangle {                                    // penalty box, bottom
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          width: pitch.width * 0.42
          height: pitch.height * 0.14
          color: "transparent"
          border.width: 1
          border.color: Util.alpha(app ? app.foreground : "#fff", 0.07)
        }

        // The four lines
        Column {
          anchors.fill: parent
          anchors.margins: Style.spacing.md

          Repeater {
            model: [tab.keepers, tab.defence, tab.midfield, tab.attack]
            delegate: Item {
              id: pitchLine
              required property var modelData
              width: pitch.width - Style.spacing.md * 2
              height: (pitch.height - Style.spacing.md * 2) / 4

              Row {
                anchors.centerIn: parent
                spacing: Style.spacing.md
                Repeater {
                  model: pitchLine.modelData
                  delegate: PlayerCard {
                    required property var modelData
                    p: modelData
                  }
                }
              }
            }
          }
        }
      }

      // Bench
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: pitchArea.benchHeight
        radius: app ? app.cornerRadius : 0
        color: Util.alpha(app ? app.foreground : "#fff", 0.04)

        Text {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.margins: Style.spacing.sm
          text: "BENCH" + (tab.st.chip === "bboost" ? "  ·  boosted, all counting" : "")
          color: tab.st.chip === "bboost" ? (app ? app.accent : "#fff") : (app ? app.fainter : "#888")
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.spacing.sm
          spacing: Style.spacing.md
          Repeater {
            model: tab.bench
            delegate: PlayerCard {
              required property var modelData
              p: modelData
              compact: true
            }
          }
        }
      }
    }

    // -------------------------------------------------------------- list
    Item {
      width: parent.width
      height: parent.height - y
      visible: tab.layout === "list"

      Column {
        anchors.fill: parent
        spacing: Style.spacing.sm

        // Column headings
        Item {
          width: parent.width
          height: Style.font.caption + Style.spacing.sm
          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            spacing: Style.spacing.md
            Text { width: Style.space(34); text: "POS"; color: app ? app.fainter : "#888"
                   font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
            Text { width: Style.space(150); text: "PLAYER"; color: app ? app.fainter : "#888"
                   font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
            Text { width: Style.space(120); text: "FIXTURE"; color: app ? app.fainter : "#888"
                   font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
            Text { width: Style.space(80); text: "KICK OFF"; color: app ? app.fainter : "#888"
                   font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
            Text { width: Style.space(44); horizontalAlignment: Text.AlignRight; text: "MIN"
                   color: app ? app.fainter : "#888"
                   font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
            Text { width: Style.space(130); text: "RETURNS"; color: app ? app.fainter : "#888"
                   font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
            Text { width: Style.space(44); horizontalAlignment: Text.AlignRight; text: "BPS"
                   color: app ? app.fainter : "#888"
                   font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
            Text { width: Style.space(44); horizontalAlignment: Text.AlignRight; text: "PTS"
                   color: app ? app.fainter : "#888"
                   font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
          }
        }

        ListView {
          id: list
          width: parent.width
          height: parent.height - y
          clip: true
          model: tab.rows
          currentIndex: app ? Math.min(app.selectedIndex, tab.rows.length - 1) : 0
          onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
          boundsBehavior: Flickable.StopAtBounds

          delegate: Item {
            id: listRow
            required property var modelData
            required property int index
            readonly property bool current: index === list.currentIndex
            readonly property bool firstBench: listRow.modelData.position === 12

            width: list.width
            height: (firstBench ? Style.space(14) : 0)
                    + Math.max(Style.space(26), Style.font.body + Style.spacing.sm * 2)

            Item {
              visible: listRow.firstBench
              width: parent.width
              height: Style.space(14)
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width; height: 1
                color: app ? app.hairline : "#333"
              }
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: benchLabel.implicitWidth + Style.spacing.md
                height: parent.height
                color: app ? app.background : "#000"
                Text {
                  id: benchLabel
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BENCH"
                  color: app ? app.fainter : "#888"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Math.max(Style.space(26), Style.font.body + Style.spacing.sm * 2)
              radius: app ? app.cornerRadius : 0
              color: listRow.current ? (app ? app.selectedBackground : "#222") : "transparent"
              opacity: listRow.modelData.counting ? 1.0 : 0.62

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.md

                Text {
                  width: Style.space(34)
                  anchors.verticalCenter: parent.verticalCenter
                  text: listRow.modelData.pos
                  color: app ? app.dim : "#aaa"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                }

                Row {
                  width: Style.space(150)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)
                  Text {
                    text: listRow.modelData.name
                    color: app ? app.statusColor(listRow.modelData.status) : "#fff"
                    font.family: app ? app.fontFamily : "monospace"
                    font.pixelSize: Style.font.body
                    font.bold: listRow.modelData.captain
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, Style.space(108))
                  }
                  Rectangle {
                    visible: listRow.modelData.captain || listRow.modelData.vice
                    width: Style.space(15); height: Style.space(15)
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: listRow.modelData.captain ? (app ? app.accent : "#fff") : "transparent"
                    border.width: listRow.modelData.vice ? 1 : 0
                    border.color: app ? app.dim : "#888"
                    Text {
                      anchors.centerIn: parent
                      text: listRow.modelData.captain ? "C" : "V"
                      color: listRow.modelData.captain ? (app ? app.background : "#000")
                                                       : (app ? app.dim : "#888")
                      font.family: app ? app.fontFamily : "monospace"
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                  Text {
                    visible: listRow.modelData.subbed_in || listRow.modelData.subbed_out
                    anchors.verticalCenter: parent.verticalCenter
                    text: listRow.modelData.subbed_in ? "↑" : "↓"
                    color: listRow.modelData.subbed_in ? (app ? app.goodColor : "#3a3")
                                                       : (app ? app.badColor : "#a33")
                    font.family: app ? app.fontFamily : "monospace"
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    visible: app ? app.isWatched(listRow.modelData.id) : false
                    anchors.verticalCenter: parent.verticalCenter
                    text: "★"
                    color: app ? app.accent : "#fff"
                    font.family: app ? app.fontFamily : "monospace"
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Rectangle {
                  visible: tab.flag(listRow.modelData) !== ""
                  anchors.verticalCenter: parent.verticalCenter
                  width: visible ? listFlag.implicitWidth + Style.space(6) : 0
                  height: listFlag.implicitHeight + Style.space(2)
                  radius: Style.space(2)
                  color: tab.flagColor(listRow.modelData)
                  border.width: 1
                  border.color: app ? app.fixedOutline : "#fff"
                  Text {
                    id: listFlag
                    anchors.centerIn: parent
                    text: tab.flag(listRow.modelData)
                    color: listRow.modelData.status === "d" ? "#12100a" : "#ffffff"
                    font.family: app ? app.fontFamily : "monospace"
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  width: Style.space(120)
                  anchors.verticalCenter: parent.verticalCenter
                  text: listRow.modelData.fixture || "—"
                  color: app ? app.foreground : "#fff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                // Kick-off, or the live clock once the match is under way
                Text {
                  width: Style.space(80)
                  anchors.verticalCenter: parent.verticalCenter
                  text: listRow.modelData.when
                  color: listRow.modelData.live ? (app ? app.accent : "#fff")
                                                : (app ? app.dim : "#aaa")
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                  font.bold: listRow.modelData.live
                  elide: Text.ElideRight
                }

                Text {
                  width: Style.space(44)
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  text: listRow.modelData.played ? listRow.modelData.minutes + "'" : "—"
                  color: app ? app.dim : "#aaa"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: Style.space(130)
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    var m = listRow.modelData
                    var bits = []
                    if (m.goals) bits.push(m.goals + "G")
                    if (m.assists) bits.push(m.assists + "A")
                    if (m.cs) bits.push("CS")
                    if (m.saves >= 3) bits.push(m.saves + " sv")
                    if (m.defcon) bits.push(m.defcon + " DC")
                    if (m.bonus) bits.push("+" + m.bonus + " bon")
                    else if (m.provisional) bits.push("~" + m.provisional + " bon")
                    if (m.yellow) bits.push("YC")
                    if (m.red) bits.push("RC")
                    return bits.join(" ")
                  }
                  color: listRow.modelData.red ? (app ? app.badColor : "#a33")
                       : listRow.modelData.provisional ? (app ? app.accent : "#fff")
                       : (app ? app.dim : "#aaa")
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  width: Style.space(44)
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  text: listRow.modelData.bps ? String(listRow.modelData.bps) : "—"
                  color: app ? app.dim : "#aaa"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: Style.space(44)
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  text: String(listRow.modelData.applied)
                  color: listRow.modelData.applied > 0 ? (app ? app.foreground : "#fff")
                                                       : (app ? app.dim : "#aaa")
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.body
                  font.bold: listRow.modelData.applied > 0
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (app) app.selectedIndex = listRow.index
                onDoubleClicked: tab.activate(listRow.index)
              }
            }
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: tab.squad.length === 0
      text: tab.st.needs_setup ? "Link your team to see your squad." : "Waiting for your squad…"
      color: app ? app.dim : "#aaa"
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.subtitle
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
