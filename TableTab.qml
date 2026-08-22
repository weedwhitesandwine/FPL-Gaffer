import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// The actual Premier League table. The API carries won/drawn/lost fields on
// each club but never fills them in, so this is worked out from the score of
// every match that has been played. Clubs you have players from are marked.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""

  // Which clubs you're invested in, so the table reads as yours.
  readonly property var myClubs: {
    var set = {}
    var squad = st.squad || []
    for (var i = 0; i < squad.length; i++) set[squad[i].team] = (set[squad[i].team] || 0) + 1
    return set
  }

  readonly property var rows: {
    var out = []
    var table = st.league_table || []
    for (var i = 0; i < table.length; i++) {
      var r = table[i]
      if (!Fmt.matches(r.name, q) && !Fmt.matches(r.team, q)) continue
      out.push(r)
    }
    return out
  }

  function activate(index) {}

  // Column widths live here once. The heading row and the data rows both
  // read them, which is the only reliable way to keep a table lined up.
  readonly property int wPos:   Style.space(30)
  readonly property int wClub:  Style.space(172)
  readonly property int wStat:  Style.space(34)
  readonly property int wPts:   Style.space(42)
  readonly property int wForm:  Style.space(78)
  readonly property int formLead: Style.space(12)
  readonly property int wGap:   Style.space(56)
  readonly property int wSquad: Style.space(104)
  readonly property int colGap: Style.spacing.md
  readonly property var statLabels: ["PL", "W", "D", "L", "GF", "GA", "GD"]

  // European places and relegation, drawn as a thin edge marker.
  // Europe and the drop mean the same thing in every theme, so these are
  // fixed too — Champions League green, Europa blue, relegation red.
  function zoneColor(position) {
    if (position <= 4) return "#157f4a"
    if (position === 5) return "#2563a8"
    if (position >= 18) return "#9b1c1c"
    return "transparent"
  }

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
        spacing: tab.colGap

        Text { width: tab.wPos; text: "#"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { width: tab.wClub; text: "CLUB"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Repeater {
          model: tab.statLabels
          delegate: Text {
            required property var modelData
            width: tab.wStat
            horizontalAlignment: Text.AlignRight
            text: modelData
            color: app ? app.fainter : "#888"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }
        }
        Text { width: tab.wPts; horizontalAlignment: Text.AlignRight; text: "PTS"
               color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Item { width: tab.formLead; height: 1 }
        Text { width: tab.wForm; text: "FORM"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }

        // Set apart from the league's own figures, because this one is about
        // your team rather than the club's season.
        Item { width: tab.wGap; height: 1 }
        Text { width: tab.wSquad; horizontalAlignment: Text.AlignHCenter
               visible: !(app && app.statto)
               text: "SQUAD PLAYERS"; color: app ? app.fainter : "#888"
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
        readonly property int mine: tab.myClubs[modelData.team] || 0

        width: list.width
        height: Math.max(Style.space(26), Style.font.body + Style.spacing.sm * 2)
        radius: app ? app.cornerRadius : 0
        color: current ? (app ? app.selectedBackground : "#222")
                       : (mine > 0 ? Util.alpha(app ? app.accent : "#fff", 0.07) : "transparent")

        // Zone marker down the left edge
        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Style.space(2)
          radius: width
          color: tab.zoneColor(modelData.position)
        }

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

          Text {
            width: tab.wPos
            anchors.verticalCenter: parent.verticalCenter
            text: String(modelData.position)
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: tab.wClub
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            font.bold: mine > 0
            elide: Text.ElideRight
          }

          Repeater {
            model: [modelData.played, modelData.won, modelData.drawn, modelData.lost,
                    modelData.gf, modelData.ga, Fmt.signed(modelData.gd)]
            delegate: Text {
              required property var modelData
              width: tab.wStat
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              text: String(modelData)
              color: app ? app.dim : "#aaa"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            width: tab.wPts
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: String(modelData.points)
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Item { width: tab.formLead; height: 1 }

          // Last five results, most recent last.
          //
          // Wrapped in a plain Item of fixed width. A Row sizes itself from
          // its children, so an empty one collapses and drags every column
          // after it out of line — which is exactly what happened to every
          // club that had not played yet.
          Item {
            width: tab.wForm
            height: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter

            Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Repeater {
              model: modelData.form
              delegate: Rectangle {
                required property var modelData
                width: Style.space(12); height: Style.space(12)
                radius: Style.space(2)
                color: app ? app.resultFill(modelData) : "#333"
                border.width: 1
                border.color: app ? app.fixedOutline : "#fff"
                Text {
                  anchors.centerIn: parent
                  text: modelData
                  color: "#ffffff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
            }
          }

          // How many of your players come from this club.
          Item { width: tab.wGap; height: 1 }
          Text {
            width: tab.wSquad
            visible: !(app && app.statto)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: mine > 0 ? String(mine) : ""
            color: app ? app.accent : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: tab.rows.length === 0
        text: "No clubs match that."
        color: app ? app.dim : "#aaa"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
      }
    }
  }
}
