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
  readonly property var squad: st.squad || []

  property string viewMode: "pitch"        // pitch | list

  // The whole squad, always. There is no filter on this tab: fifteen names
  // are already on screen, so a search box over them only adds a control
  // that appears to do nothing.
  readonly property var rows: squad

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
    readonly property bool selected: {
      if (!app || !p) return false
      var sel = tab.rows[app.selectedIndex]
      return !!sel && sel.id === p.id
    }

    width: compact ? Style.space(146) : Style.space(152)
    height: cardCol.implicitHeight + Style.spacing.sm * 2
    radius: app ? Math.max(app.cornerRadius, Style.space(3)) : 0
    color: selected ? (app ? app.shirtLit : "#2a9b5e") : (app ? app.shirt : "#1c7a48")
    opacity: counting ? 1.0 : 0.72

    // A live match, the captain, or a filter hit all get a white edge —
    // white always reads on this green, whatever the theme is doing.
    border.width: (p && p.live) || (p && p.captain) || selected ? 1 : 0
    border.color: (p && p.captain) || selected ? "#ffffff" : (app ? app.shirtEdge : "#fff")

    Behavior on opacity { NumberAnimation { duration: 160 } }

    Column {
      id: cardCol
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.sm
      anchors.horizontalCenter: parent.horizontalCenter
      width: pc.width - Style.spacing.sm * 2
      spacing: Style.space(1)

      // points, big — the number you actually look for
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(3)

        Text {
          text: pc.p ? String(pc.p.applied) : "0"
          color: pc.p && pc.p.applied > 0 ? (app ? app.shirtText : "#fff")
                                          : (app ? app.shirtSubtle : "#c9e8d6")
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.display
          font.bold: true
        }
        Text {
          visible: pc.p && pc.p.provisional > 0
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(2)
          text: pc.p ? "~" + pc.p.provisional : ""
          color: app ? app.shirtText : "#fff"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: pc.p ? pc.p.name : ""
        // White always. The badge below already says whether he is a doubt,
        // and coloured text on a green card is hard to read whatever the
        // colour — so the badge carries it and the name stays legible.
        color: app ? app.shirtText : "#fff"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
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
        color: app ? app.shirtSubtle : "#c9e8d6"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.bodySmall
        font.bold: pc.p && pc.p.live
        elide: Text.ElideRight
      }

      // The bottom line is always present, so every card is the same
      // height whether or not this player has anything to report. It shows
      // availability if there is a doubt — that outranks everything — and
      // otherwise what he has actually done.
      Item {
        width: parent.width
        height: Math.max(flagText.implicitHeight + Style.space(3),
                         returnsText.implicitHeight)

        Rectangle {
          visible: tab.flag(pc.p) !== ""
          anchors.centerIn: parent
          width: flagText.implicitWidth + Style.space(8)
          height: flagText.implicitHeight + Style.space(3)
          radius: Style.space(2)
          color: tab.flagColor(pc.p)
          border.width: 1
          border.color: app ? app.fixedOutline : "#fff"

          Text {
            id: flagText
            anchors.centerIn: parent
            text: tab.flag(pc.p)
            color: app ? app.onCard : "#1a1005"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Text {
          id: returnsText
          visible: tab.flag(pc.p) === ""
          anchors.centerIn: parent
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
          color: pc.p && pc.p.red ? (app ? app.cardRed : "#c62828")
                                  : (app ? app.shirtSubtle : "#c9e8d6")
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }

    // Captain's armband, top right
    Rectangle {
      visible: pc.p && (pc.p.captain || pc.p.vice)
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(3)
      width: Style.space(18); height: Style.space(18)
      radius: width / 2
      color: pc.p && pc.p.captain ? "#ffffff" : "transparent"
      border.width: pc.p && pc.p.vice ? 1 : 0
      border.color: "#ffffff"
      Text {
        anchors.centerIn: parent
        text: pc.p && pc.p.captain ? "C" : "V"
        color: pc.p && pc.p.captain ? (app ? app.turf : "#0a3a20") : "#ffffff"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.bodySmall
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
      color: "#ffffff"
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
      color: "#ffffff"
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
      onDoubleClicked: if (app && pc.p) app.revealPlayer(pc.p.id)
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
            readonly property bool active: tab.viewMode === modelData.id
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
              onClicked: tab.viewMode = modelData.id
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
      visible: tab.viewMode === "pitch"

      // The bench stands beside the pitch rather than under it. The pitch
      // has width to spare and no height to spare, so this trade buys the
      // eleven a great deal of room and costs the four almost nothing.
      readonly property int benchWidth: Style.space(174)

      Rectangle {
        id: pitch
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.rightMargin: pitchArea.benchWidth + Style.spacing.sm
        radius: app ? app.cornerRadius : 0
        // Fixed green, on purpose. A pitch drawn in theme colours stops
        // reading as a pitch, and the cards need a known background to be
        // legible against.
        color: app ? app.turf : "#0a3a20"
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
              color: index % 2 === 0 ? (app ? app.turfBand : "#0d4527") : "transparent"
            }
          }
        }

        // Markings
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          color: app ? app.turfLine : "#fff"
          visible: false
        }
        Rectangle {                                    // halfway line
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: 1
          color: app ? app.turfLine : "#fff"
        }
        Rectangle {                                    // centre circle
          anchors.centerIn: parent
          width: Math.min(pitch.width, pitch.height) * 0.28
          height: width
          radius: width / 2
          color: "transparent"
          border.width: 1
          border.color: app ? app.turfLine : "#fff"
        }
        Rectangle {                                    // penalty box, top
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          width: pitch.width * 0.42
          height: pitch.height * 0.14
          color: "transparent"
          border.width: 1
          border.color: app ? app.turfLine : "#fff"
        }
        Rectangle {                                    // penalty box, bottom
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          width: pitch.width * 0.42
          height: pitch.height * 0.14
          color: "transparent"
          border.width: 1
          border.color: app ? app.turfLine : "#fff"
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
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: pitchArea.benchWidth
        radius: app ? app.cornerRadius : 0
        color: app ? app.dugout : "#08301b"

        Text {
          id: benchLabel2
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: Style.spacing.sm
          text: "BENCH" + (tab.st.chip === "bboost" ? " · BOOSTED" : "")
          color: app ? app.shirtSubtle : "#c9e8d6"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          font.bold: tab.st.chip === "bboost"
        }

        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: benchLabel2.bottom
          anchors.topMargin: Style.spacing.md
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
      visible: tab.viewMode === "list"

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
            Item { width: Style.space(14); height: 1 }
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
                    color: app ? app.onCard : "#1a1005"
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

                Item { width: Style.space(14); height: 1 }

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
                onDoubleClicked: if (app) app.revealPlayer(listRow.modelData.id)
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
