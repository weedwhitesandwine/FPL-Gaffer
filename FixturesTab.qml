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
    var dir = tab.sortAsc ? 1 : -1
    var key = tab.sortKey
    source.sort(function(a, b) {
      if (key === "club") {
        var an = String(a.name || "").toLowerCase()
        var bn = String(b.name || "").toLowerCase()
        return (an < bn ? -1 : (an > bn ? 1 : 0)) * dir
      }
      if (key === "avg") {
        var av = a.games > 0 ? a.avg : 99
        var bv = b.games > 0 ? b.avg : 99
        if (av === bv) return String(a.name).localeCompare(String(b.name))
        return (av - bv) * dir
      }
      var gw = parseInt(key.replace("gw", ""))
      var ag = tab.gwValue(a, gw)
      var bg = tab.gwValue(b, gw)
      if (ag === bg) return String(a.name).localeCompare(String(b.name))
      return (ag - bg) * dir
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

  // Click any heading to rank by it — the club name, the average difficulty
  // of the whole run, or the difficulty of a single gameweek — and click the
  // same one again to reverse it. Ranking by one week answers a real
  // question: who has the kind fixture the week I need a captain.
  property string sortKey: "club"
  property bool sortAsc: true

  // A club not playing that week sorts last however you order it: a blank is
  // not an easy fixture, it is no fixture. A double counts as the average of
  // its two games.
  function gwValue(row, gw) {
    var weeks = tab.grid.gameweeks || []
    var idx = weeks.indexOf(gw)
    if (idx < 0) return 99
    var cell = row.cells[idx]
    if (!cell || cell.length === 0) return 99
    var total = 0
    for (var i = 0; i < cell.length; i++) total += cell[i].fdr
    return total / cell.length
  }

  function sortOn(key) {
    if (tab.sortKey === key) tab.sortAsc = !tab.sortAsc
    else { tab.sortKey = key; tab.sortAsc = true }
    if (app) app.selectedIndex = 0
  }

  function activate(index) {}

  Column {
    anchors.fill: parent
    spacing: Style.spacing.sm

    // Headings — these are the sort control.
    Item {
      width: parent.width
      height: Math.max(Style.space(20), Style.font.caption + Style.spacing.sm)

      // One heading: its label, an arrow when it is the one in charge, and a
      // click target that covers the whole cell rather than just the word.
      component Heading: Item {
        property string label: ""
        property string sortId: ""
        property bool alignRight: false
        property bool centre: false
        readonly property bool active: tab.sortKey === sortId

        height: parent ? parent.height : 0

        Row {
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: (alignRight || centre) ? undefined : parent.left
          anchors.right: alignRight ? parent.right : undefined
          anchors.horizontalCenter: centre ? parent.horizontalCenter : undefined
          spacing: Style.space(2)

          Text {
            text: parent.parent.label
            color: parent.parent.active ? (app ? app.accent : "#fff")
                                        : (app ? app.fainter : "#888")
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
            font.bold: parent.parent.active
          }
          Text {
            visible: parent.parent.active
            text: tab.sortAsc ? "▲" : "▼"
            color: app ? app.accent : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          anchors.fill: parent
          anchors.topMargin: -Style.space(3)
          anchors.bottomMargin: -Style.space(3)
          cursorShape: Qt.PointingHandCursor
          onClicked: tab.sortOn(parent.sortId)
        }
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.rowPaddingX
        spacing: 0

        Heading { width: Style.space(140); label: "CLUB"; sortId: "club" }
        Heading { width: Style.space(46);  label: "AVG";  sortId: "avg"; alignRight: true }

        Repeater {
          model: tab.grid.gameweeks || []
          delegate: Heading {
            required property var modelData
            width: tab.cellWidth
            label: "GW" + modelData
            sortId: "gw" + modelData
            centre: true
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

          Item {
            width: Style.space(140)
            height: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
            Row {
            anchors.left: parent.left
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
          }

          Text {
            width: Style.space(46)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: modelData.games > 0 ? Number(modelData.avg).toFixed(1) : "—"
            font.bold: tab.sortKey === "avg"
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
