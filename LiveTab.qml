import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// The gameweek's matches, with your own players called out under each one,
// and — while a match is still running — the bonus race, so you can see who
// is on course for the 3, 2 and 1 before the game makes it official.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""

  readonly property var rows: {
    var out = []
    var fixtures = st.fixtures || []
    var squad = st.squad || []
    var races = st.bonus_races || []

    for (var i = 0; i < fixtures.length; i++) {
      var f = fixtures[i]
      if (!Fmt.matches(f.label, q)) continue

      var mine = []
      for (var j = 0; j < squad.length; j++) {
        var p = squad[j]
        if (p.team === f.home || p.team === f.away) mine.push(p)
      }
      var race = null
      for (var k = 0; k < races.length; k++) if (races[k].fixture === f.id) race = races[k]

      out.push({ fixture: f, mine: mine, race: race })
    }
    return out
  }

  function activate(index) {}

  ListView {
    id: list
    anchors.fill: parent
    clip: true
    spacing: Style.spacing.sm
    model: tab.rows
    currentIndex: app ? Math.min(app.selectedIndex, tab.rows.length - 1) : 0
    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
    boundsBehavior: Flickable.StopAtBounds

    delegate: Rectangle {
      id: matchCard
      required property var modelData
      required property int index
      readonly property bool current: index === list.currentIndex
      readonly property var fx: matchCard.modelData.fixture

      width: list.width
      height: content.implicitHeight + Style.spacing.md * 2
      radius: app ? app.cornerRadius : 0
      color: current ? (app ? app.selectedBackground : "#222") : Util.alpha(app ? app.foreground : "#fff", 0.03)

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (app) app.selectedIndex = index
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.spacing.md
        spacing: Style.spacing.sm

        // Scoreline
        Row {
          width: parent.width
          spacing: Style.spacing.md

          Text {
            width: Style.space(200)
            text: fx.label
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          // Clock: minute while live, FT when done, kickoff time before
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: clockText.implicitWidth + Style.spacing.md
            height: clockText.implicitHeight + Style.space(3)
            radius: app ? app.cornerRadius : 0
            color: fx.started && !fx.finished
                   ? Util.alpha(app ? app.accent : "#fff", 0.22) : "transparent"
            Text {
              id: clockText
              anchors.centerIn: parent
              text: fx.finished ? "FT"
                   : fx.started ? (fx.minutes || 0) + "'"
                   : Fmt.kickoff(fx.kickoff)
              color: fx.started && !fx.finished ? (app ? app.accent : "#fff")
                                                : (app ? app.dim : "#aaa")
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.bodySmall
              font.bold: fx.started && !fx.finished
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.mine.length > 0
                  ? modelData.mine.length + (modelData.mine.length === 1 ? " of yours" : " of yours")
                  : ""
            color: app ? app.fainter : "#888"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }
        }

        // Who did what — scorers, assists and cards for both sides.
        Column {
          width: parent.width
          spacing: Style.space(1)
          visible: matchCard.fx.detail !== null && matchCard.fx.detail !== undefined

          Repeater {
            model: matchCard.fx.detail ? [
              { label: "goal",   swatch: "",        home: matchCard.fx.detail.goals_scored.home, away: matchCard.fx.detail.goals_scored.away },
              { label: "assist", swatch: "",        home: matchCard.fx.detail.assists.home,      away: matchCard.fx.detail.assists.away },
              { label: "o.g.",   swatch: "",        home: matchCard.fx.detail.own_goals.home,    away: matchCard.fx.detail.own_goals.away },
              { label: "",       swatch: "yellow",  home: matchCard.fx.detail.yellow_cards.home, away: matchCard.fx.detail.yellow_cards.away },
              { label: "",       swatch: "red",     home: matchCard.fx.detail.red_cards.home,    away: matchCard.fx.detail.red_cards.away }
            ] : []

            delegate: Row {
              required property var modelData
              visible: modelData.home.length > 0 || modelData.away.length > 0
              spacing: Style.spacing.md

              function names(list) {
                var bits = []
                for (var i = 0; i < list.length; i++)
                  bits.push(list[i].name + (list[i].count > 1 ? " ×" + list[i].count : ""))
                return bits.join(", ")
              }

              // A booking is a little card; everything else is a word.
              Item {
                width: Style.space(42)
                height: Style.font.bodySmall

                Text {
                  visible: modelData.swatch === ""
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label
                  color: app ? app.fainter : "#888"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                }
                Rectangle {
                  visible: modelData.swatch !== ""
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7); height: Style.space(10)
                  radius: Style.space(1)
                  color: modelData.swatch === "red" ? (app ? app.cardRed : "#c62828")
                                                    : (app ? app.cardYellow : "#e3b505")
                  border.width: 1
                  border.color: app ? app.fixedOutline : "#fff"
                }
              }
              Text {
                width: Style.space(220)
                text: parent.names(modelData.home)
                color: app ? app.dim : "#aaa"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                width: Style.space(220)
                text: parent.names(modelData.away)
                color: app ? app.dim : "#aaa"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }
          }
        }

        // Your players in this match
        Flow {
          width: parent.width
          spacing: Style.spacing.sm
          visible: modelData.mine.length > 0

          Repeater {
            model: modelData.mine
            delegate: Rectangle {
              required property var modelData
              width: pill.implicitWidth + Style.spacing.md
              height: pill.implicitHeight + Style.space(4)
              radius: app ? app.cornerRadius : 0
              color: Util.alpha(app ? app.foreground : "#fff", modelData.counting ? 0.09 : 0.04)

              Text {
                id: pill
                anchors.centerIn: parent
                text: {
                  var s = modelData.name
                  if (modelData.captain) s += " (C)"
                  if (modelData.benched) s += " [b]"
                  s += "  " + modelData.applied
                  if (modelData.provisional) s += " ~" + modelData.provisional
                  return s
                }
                color: modelData.counting ? (app ? app.foreground : "#fff") : (app ? app.fainter : "#888")
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
                font.bold: modelData.captain
              }
            }
          }
        }

        // Bonus race — only while the bonus is still up for grabs
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: modelData.race !== null && modelData.race !== undefined

          Text {
            text: "Bonus race"
            color: app ? app.fainter : "#888"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: modelData.race ? modelData.race.rows : []
            delegate: Row {
              required property var modelData
              spacing: Style.spacing.md

              Text {
                width: Style.space(26)
                text: modelData.bonus > 0 ? "+" + modelData.bonus : ""
                color: app ? app.accent : "#fff"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Text {
                width: Style.space(140)
                text: modelData.name + "  " + modelData.team
                color: app ? app.foreground : "#fff"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                text: modelData.bps + " bps"
                color: app ? app.dim : "#aaa"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }

    Text {
      anchors.centerIn: parent
      visible: tab.rows.length === 0
      text: "No matches this gameweek match that."
      color: app ? app.dim : "#aaa"
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.subtitle
    }
  }
}
