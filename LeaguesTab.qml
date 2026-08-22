import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// Your mini-leagues. Small leagues are re-scored live from every member's
// team, so the order you see is the order as it stands right now rather than
// the one frozen at the deadline; large leagues fall back to the official
// standings. Your own row is always highlighted.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""
  readonly property var tables: st.tables || []

  property int leagueIndex: 0
  readonly property var league: tables.length > 0
    ? tables[Math.min(leagueIndex, tables.length - 1)] : null

  readonly property var rows: {
    if (!league) return []
    var out = []
    for (var i = 0; i < league.rows.length; i++) {
      var r = league.rows[i]
      if (!Fmt.matches(r.name, q) && !Fmt.matches(r.player, q)) continue
      out.push(r)
    }
    return out
  }

  // Shared column widths, so the headings and the rows cannot drift apart.
  readonly property int wRank:    Style.space(56)
  readonly property int wTeam:    Style.space(200)
  readonly property int wManager: Style.space(160)
  readonly property int wChip:    Style.space(58)
  readonly property int wGw:      Style.space(52)
  readonly property int wTotal:   Style.space(60)
  readonly property int colGap:   Style.spacing.md

  function activate(index) {
    // Enter cycles to the next league.
    if (tables.length > 1) {
      tab.leagueIndex = (tab.leagueIndex + 1) % tables.length
      if (app) app.selectedIndex = 0
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.spacing.sm

    // League picker
    Flow {
      width: parent.width
      spacing: Style.space(4)
      visible: tab.tables.length > 0

      Repeater {
        model: tab.tables
        delegate: Rectangle {
          required property var modelData
          required property int index
          readonly property bool current: index === tab.leagueIndex

          width: label.implicitWidth + Style.spacing.lg
          height: Math.max(Style.space(24), Style.font.bodySmall + Style.spacing.sm * 2)
          radius: app ? app.cornerRadius : 0
          color: current ? (app ? app.selectedBackground : "#222")
                         : Util.alpha(app ? app.foreground : "#fff", 0.04)

          Text {
            textFormat: Text.PlainText
            id: label
            anchors.centerIn: parent
            text: modelData.name + "  " + Fmt.rank(modelData.size)
            color: current ? (app ? app.selectedText : "#fff") : (app ? app.dim : "#aaa")
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            font.bold: current
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { tab.leagueIndex = index; if (app) app.selectedIndex = 0 }
          }
        }
      }
    }

    Row {
      width: parent.width
      visible: tab.league !== null
      spacing: Style.spacing.lg

      Text {
        textFormat: Text.PlainText
        text: {
          if (!tab.league) return ""
          if (tab.league.computed) return "Scored live from every member's team."
          if (tab.league.size > tab.league.shown)
            return "Top " + tab.league.shown + " of " + Fmt.commas(tab.league.size) + "."
          return "Official standings."
        }
        color: tab.league && tab.league.computed ? (app ? app.accent : "#fff")
                                                 : (app ? app.fainter : "#888")
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
      }

      // In a league of millions you will not be in the first fifty, so your
      // own standing is stated rather than left for you to hunt for.
      Text {
        textFormat: Text.PlainText
        visible: tab.league && !tab.league.in_view && tab.league.your_rank
        text: {
          if (!tab.league || !tab.league.your_rank) return ""
          var line = "You: " + Fmt.commas(tab.league.your_rank)
          var moved = Fmt.movement(tab.league.your_rank, tab.league.your_last_rank)
          if (moved !== 0 && tab.league.your_last_rank)
            line += (moved > 0 ? "  ▲" : "  ▼") + Fmt.commas(Math.abs(moved))
          return line
        }
        color: app ? app.accent : "#fff"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    // Column headings
    Item {
      width: parent.width
      height: Style.font.caption + Style.spacing.sm
      visible: tab.league !== null
      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.rowPaddingX
        spacing: tab.colGap
        Text { textFormat: Text.PlainText; width: tab.wRank; text: "RANK"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; width: tab.wTeam; text: "TEAM"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; width: tab.wManager; text: "MANAGER"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; width: tab.wChip; horizontalAlignment: Text.AlignRight; text: "CHIP"
               color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; width: tab.wGw; horizontalAlignment: Text.AlignRight; text: "GW"
               color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; width: tab.wTotal; horizontalAlignment: Text.AlignRight; text: "TOTAL"
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

      delegate: Rectangle {
        required property var modelData
        required property int index
        readonly property bool current: index === list.currentIndex
        readonly property bool isMe: !!tab.league && modelData.entry === tab.league.me
        readonly property int shown: modelData.live_rank ? modelData.live_rank : modelData.rank
        readonly property int moved: Fmt.movement(shown, modelData.last_rank)

        width: list.width
        height: Math.max(Style.space(26), Style.font.body + Style.spacing.sm * 2)
        radius: app ? app.cornerRadius : 0
        color: current ? (app ? app.selectedBackground : "#222")
             : isMe ? Util.alpha(app ? app.accent : "#fff", 0.13) : "transparent"

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (app) app.selectedIndex = index
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.rightMargin: Style.spacing.rowPaddingX
          spacing: tab.colGap

          Item {
            width: tab.wRank
            height: Style.font.body
            anchors.verticalCenter: parent.verticalCenter

            Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)
            Text {
              textFormat: Text.PlainText
              text: String(shown)
              color: app ? app.foreground : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              visible: moved !== 0 && modelData.last_rank > 0
              text: moved > 0 ? "▲" : "▼"
              color: app ? app.deltaColor(moved) : "#aaa"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: tab.wTeam
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name || "—"
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            font.bold: isMe
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: tab.wManager
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.player || "—"
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: tab.wChip
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: modelData.chip ? String(modelData.chip).toUpperCase() : ""
            color: app ? app.accent : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: tab.wGw
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: modelData.live_gw !== null && modelData.live_gw !== undefined
                  ? String(modelData.live_gw) : String(modelData.event_total)
            color: modelData.live_gw !== null && modelData.live_gw !== undefined
                   ? (app ? app.accent : "#fff") : (app ? app.dim : "#aaa")
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            width: tab.wTotal
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: modelData.live_total !== null && modelData.live_total !== undefined
                  ? String(modelData.live_total) : String(modelData.total)
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: tab.rows.length === 0
        text: tab.tables.length === 0
              ? "No mini-leagues found for this team."
              : "No managers match that."
        color: app ? app.dim : "#aaa"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
      }
    }
  }
}
