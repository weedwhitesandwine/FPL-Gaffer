import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// Difficulty grid: clubs down the side, the coming gameweeks across. Green
// is kind, red is brutal; capitals mean a home game. A cell holding two
// matches is a double gameweek, an empty cell is a blank — both worth
// planning around, and both visible at a glance here.
//
// Listed alphabetically, so you can find a club without knowing the rule.
// The AVG column still says how kind the run is, lowest being kindest.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""
  readonly property var grid: st.grid || ({ gameweeks: [], rows: [] })

  readonly property var myClubs: {
    var set = {}
    var squad = st.squad || []
    for (var i = 0; i < squad.length; i++) set[squad[i].team] = true
    return set
  }

  readonly property var rows: {
    var out = []
    var source = (grid.rows || []).slice()
    source.sort(function(a, b) {
      var an = String(a.name || "").toLowerCase()
      var bn = String(b.name || "").toLowerCase()
      return an < bn ? -1 : (an > bn ? 1 : 0)
    })
    for (var i = 0; i < source.length; i++) {
      var r = source[i]
      if (!Fmt.matches(r.name, q) && !Fmt.matches(r.team, q)) continue
      out.push(r)
    }
    return out
  }

  readonly property int cellWidth: Math.max(Style.space(52),
    (width - Style.space(190)) / Math.max(1, (grid.gameweeks || []).length))

  function activate(index) {}

  Column {
    anchors.fill: parent
    spacing: Style.spacing.sm

    // Gameweek headings
    Item {
      width: parent.width
      height: Style.font.caption + Style.spacing.sm
      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.rowPaddingX
        spacing: 0

        Text {
          width: Style.space(140)
          text: "CLUB"
          color: app ? app.fainter : "#888"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
        }
        Text {
          width: Style.space(46)
          horizontalAlignment: Text.AlignRight
          text: "AVG"
          color: app ? app.fainter : "#888"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
        }
        Repeater {
          model: tab.grid.gameweeks || []
          delegate: Text {
            required property var modelData
            width: tab.cellWidth
            horizontalAlignment: Text.AlignHCenter
            text: "GW" + modelData
            color: app ? app.fainter : "#888"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    ListView {
      id: list
      width: parent.width
      height: parent.height - y - legend.height - Style.spacing.sm
      clip: true
      model: tab.rows
      currentIndex: app ? Math.min(app.selectedIndex, tab.rows.length - 1) : 0
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
      boundsBehavior: Flickable.StopAtBounds

      delegate: Rectangle {
        required property var modelData
        required property int index
        readonly property bool current: index === list.currentIndex
        readonly property bool mine: tab.myClubs[modelData.team] === true

        width: list.width
        height: Math.max(Style.space(28), Style.font.body + Style.spacing.sm * 2)
        radius: app ? app.cornerRadius : 0
        color: current ? (app ? app.selectedBackground : "#222") : "transparent"

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (app) app.selectedIndex = index
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.rowPaddingX
          spacing: 0

          Row {
            width: Style.space(140)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm
            Text {
              text: modelData.name
              color: app ? app.foreground : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.body
              font.bold: mine
              elide: Text.ElideRight
              width: Math.min(implicitWidth, Style.space(112))
            }
            Text {
              visible: mine
              anchors.verticalCenter: parent.verticalCenter
              text: "★"
              color: app ? app.accent : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: Style.space(46)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: modelData.games > 0 ? Number(modelData.avg).toFixed(1) : "—"
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: modelData.cells
            delegate: Item {
              id: cell
              required property var modelData
              readonly property var games: cell.modelData

              width: tab.cellWidth
              height: Math.max(Style.space(28), Style.font.body + Style.spacing.sm * 2)

              // Blank gameweek — this club simply isn't playing.
              Text {
                anchors.centerIn: parent
                visible: cell.games.length === 0
                text: "—"
                color: app ? app.fainter : "#888"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
              }

              Column {
                anchors.centerIn: parent
                width: cell.width - Style.space(4)
                spacing: 1
                visible: cell.games.length > 0

                Repeater {
                  model: cell.games
                  delegate: Rectangle {
                    required property var modelData
                    width: parent.width
                    height: Math.max(Style.space(13), Style.font.caption + Style.space(3))
                    radius: Style.space(2)
                    color: app ? app.fdrFill(modelData.fdr) : "#333"
                    border.width: 1
                    border.color: app ? app.fixedOutline : "#fff"

                    Text {
                      anchors.centerIn: parent
                      // Capitals for home, lower case for away — the way
                      // fixture tickers have always done it.
                      text: modelData.home ? String(modelData.opp).toUpperCase()
                                           : String(modelData.opp).toLowerCase()
                      color: app ? app.fdrText(modelData.fdr) : "#fff"
                      font.family: app ? app.fontFamily : "monospace"
                      font.pixelSize: Style.font.caption
                      font.bold: modelData.home
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // Legend
    Row {
      id: legend
      width: parent.width
      spacing: Style.spacing.lg

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Difficulty"
        color: app ? app.fainter : "#888"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
      }
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)
        Repeater {
          model: [1, 2, 3, 4, 5]
          delegate: Rectangle {
            required property var modelData
            width: Style.space(22); height: Style.space(13)
            radius: Style.space(2)
            color: app ? app.fdrFill(modelData) : "#333"
            border.width: 1
            border.color: app ? app.fixedOutline : "#fff"
            Text {
              anchors.centerIn: parent
              text: String(modelData)
              color: app ? app.fdrText(modelData) : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "CAPS = home  ·  two rows = double  ·  — = blank  ·  ★ = you own someone"
        color: app ? app.fainter : "#888"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
      }
    }
  }
}
