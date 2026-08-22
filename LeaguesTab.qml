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
            id: label
            anchors.centerIn: parent
            text: modelData.name + "  " + modelData.size
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

    Text {
      width: parent.width
      visible: tab.league !== null
      text: tab.league && tab.league.computed
            ? "Scored live from every member's team."
            : "Official standings — this league is too big to re-score live."
      color: tab.league && tab.league.computed ? (app ? app.accent : "#fff") : (app ? app.fainter : "#888")
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.caption
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
        spacing: Style.spacing.md
        Text { width: Style.space(50); text: "RANK"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { width: Style.space(190); text: "TEAM"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { width: Style.space(150); text: "MANAGER"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { width: Style.space(56); horizontalAlignment: Text.AlignRight; text: "CHIP"
               color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { width: Style.space(48); horizontalAlignment: Text.AlignRight; text: "GW"
               color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { width: Style.space(56); horizontalAlignment: Text.AlignRight; text: "TOTAL"
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
          spacing: Style.spacing.md

          Row {
            width: Style.space(50)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)
            Text {
              text: String(shown)
              color: app ? app.foreground : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.body
            }
            Text {
              visible: moved !== 0 && modelData.last_rank > 0
              text: moved > 0 ? "▲" : "▼"
              color: app ? app.deltaColor(moved) : "#aaa"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: Style.space(190)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name || "—"
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            font.bold: isMe
            elide: Text.ElideRight
          }

          Text {
            width: Style.space(150)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.player || "—"
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            width: Style.space(56)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: modelData.chip ? String(modelData.chip).toUpperCase() : ""
            color: app ? app.accent : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }

          Text {
            width: Style.space(48)
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
            width: Style.space(56)
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
