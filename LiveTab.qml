import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// The gameweek's matches, laid out like a match card: the two clubs either
// side of the scoreline, and everything that happened underneath split down
// the middle, home on the left and away on the right, so you never have to
// work out which side a goal belongs to.
//
// Your own players are called out along the bottom, and while a match is
// still running the bonus race sits below that — who is on course for the 3,
// 2 and 1 before the game makes it official.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""
  readonly property bool statto: app ? app.statto : false

  readonly property var rows: {
    var out = []
    var fixtures = st.fixtures || []
    var squad = st.squad || []
    var races = st.bonus_races || []

    for (var i = 0; i < fixtures.length; i++) {
      var f = fixtures[i]
      if (!Fmt.matches(f.label, q) && !Fmt.matches(f.home_name, q)
          && !Fmt.matches(f.away_name, q)) continue

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
    spacing: Style.spacing.md
    model: tab.rows
    currentIndex: app ? Math.min(app.selectedIndex, tab.rows.length - 1) : 0
    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
    boundsBehavior: Flickable.StopAtBounds

    delegate: Rectangle {
      id: card
      required property var modelData
      required property int index
      readonly property bool current: index === list.currentIndex
      readonly property var fx: card.modelData.fixture
      readonly property bool inPlay: card.fx.started && !card.fx.finished

      // Every event the feed reports, as one list this card can walk twice.
      readonly property var events: card.fx.detail ? [
        { label: "goal",   swatch: "", home: card.fx.detail.goals_scored.home, away: card.fx.detail.goals_scored.away },
        { label: "assist", swatch: "", home: card.fx.detail.assists.home,      away: card.fx.detail.assists.away },
        { label: "o.g.",   swatch: "", home: card.fx.detail.own_goals.home,    away: card.fx.detail.own_goals.away },
        { label: "pen missed", swatch: "", home: card.fx.detail.penalties_missed.home, away: card.fx.detail.penalties_missed.away },
        { label: "",  swatch: "yellow", home: card.fx.detail.yellow_cards.home, away: card.fx.detail.yellow_cards.away },
        { label: "",  swatch: "red",    home: card.fx.detail.red_cards.home,    away: card.fx.detail.red_cards.away }
      ] : []

      width: list.width
      height: body.implicitHeight + Style.spacing.lg * 2
      radius: app ? app.cornerRadius : 0
      color: current ? (app ? app.selectedBackground : "#222")
                     : Util.alpha(app ? app.foreground : "#fff", 0.035)
      border.width: card.inPlay ? 1 : 0
      border.color: Util.alpha(app ? app.accent : "#fff", 0.5)

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (app) app.selectedIndex = card.index
      }

      // One event line, written outward from the middle: the home side reads
      // left to right, the away side right to left, so both hug the divider.
      component EventLine: Item {
        property var entry: null
        property bool homeSide: true
        readonly property var people: entry ? (homeSide ? entry.home : entry.away) : []

        width: parent ? parent.width : 0
        height: visible ? Math.max(Style.font.bodySmall, Style.space(13)) + Style.space(3) : 0
        visible: people !== undefined && people.length > 0

        Row {
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: homeSide ? parent.left : undefined
          anchors.right: homeSide ? undefined : parent.right
          layoutDirection: homeSide ? Qt.LeftToRight : Qt.RightToLeft
          spacing: Style.spacing.sm

          // A booking is a little card; everything else says what it was.
          Item {
            width: entry.swatch === "" ? tagText.implicitWidth : Style.space(7)
            height: Style.space(13)

            Text {
              textFormat: Text.PlainText
              id: tagText
              visible: entry.swatch === ""
              anchors.verticalCenter: parent.verticalCenter
              text: entry.label
              color: app ? app.fainter : "#888"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
            Rectangle {
              visible: entry.swatch !== ""
              anchors.centerIn: parent
              width: Style.space(7); height: Style.space(10)
              radius: Style.space(1)
              color: entry.swatch === "red" ? (app ? app.cardRed : "#c62828")
                                            : (app ? app.cardYellow : "#e3b505")
              border.width: 1
              border.color: app ? app.fixedOutline : "#fff"
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var bits = []
              for (var i = 0; i < people.length; i++)
                bits.push(people[i].name + (people[i].count > 1 ? " ×" + people[i].count : ""))
              return bits.join(", ")
            }
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.spacing.lg
        spacing: Style.spacing.md

        // ---------------------------------------------------- the scoreline
        Item {
          width: parent.width
          height: Math.max(Style.font.display, Style.space(30))

          // The clock and stake sit in a 150-wide gutter on the right, so the
          // same gutter is left empty on the left: without it the scoreline
          // centres on what is left of the row and reads visibly off-centre.
          readonly property int gutter: Style.space(150)
          readonly property int sideWidth: (width - Style.space(120) - gutter * 2) / 2

          Text {                                            // home club
            textFormat: Text.PlainText
            anchors.right: parent.horizontalCenter
            anchors.rightMargin: Style.space(60)
            anchors.verticalCenter: parent.verticalCenter
            width: parent.sideWidth
            horizontalAlignment: Text.AlignRight
            text: card.fx.home_name || card.fx.home
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Text {                                            // score, or "v"
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(120)
            horizontalAlignment: Text.AlignHCenter
            text: card.fx.started && card.fx.hs !== null
                    ? card.fx.hs + " – " + card.fx.as : "v"
            color: card.inPlay ? (app ? app.accent : "#fff") : (app ? app.foreground : "#fff")
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: card.fx.started ? Style.font.display : Style.font.title
            font.bold: true
          }

          Text {                                            // away club
            textFormat: Text.PlainText
            anchors.left: parent.horizontalCenter
            anchors.leftMargin: Style.space(60)
            anchors.verticalCenter: parent.verticalCenter
            width: parent.sideWidth
            text: card.fx.away_name || card.fx.away
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Row {                                             // clock and stake
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: card.modelData.mine.length > 0
                      ? card.modelData.mine.length + " of yours" : ""
              color: app ? app.fainter : "#888"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: clockText.implicitWidth + Style.spacing.lg
              height: clockText.implicitHeight + Style.space(5)
              radius: app ? app.cornerRadius : 0
              color: card.inPlay ? Util.alpha(app ? app.accent : "#fff", 0.22)
                                 : Util.alpha(app ? app.foreground : "#fff", 0.07)
              Text {
                textFormat: Text.PlainText
                id: clockText
                anchors.centerIn: parent
                // The league's own clock where we have it — it knows about
                // stoppage time and about the interval; the fantasy feed's
                // bare minute count knows about neither.
                text: card.fx.finished ? "FT"
                     : card.fx.started ? (card.fx.clock || (card.fx.minutes || 0) + "'")
                     : Fmt.kickoff(card.fx.kickoff)
                color: card.inPlay ? (app ? app.accent : "#fff") : (app ? app.dim : "#aaa")
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
                font.bold: card.inPlay
              }
            }
          }
        }

        // ------------------------------------------- what happened, by side
        Item {
          width: parent.width
          height: Math.max(homeCol.implicitHeight, awayCol.implicitHeight)

          Column {
            id: homeCol
            anchors.left: parent.left
            anchors.top: parent.top
            width: (parent.width - Style.spacing.xl) / 2
            spacing: 0
            Repeater {
              model: card.events
              delegate: EventLine {
                required property var modelData
                entry: modelData
                homeSide: true
              }
            }
          }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: app ? app.hairline : "#333"
          }

          Column {
            id: awayCol
            anchors.right: parent.right
            anchors.top: parent.top
            width: (parent.width - Style.spacing.xl) / 2
            spacing: 0
            Repeater {
              model: card.events
              delegate: EventLine {
                required property var modelData
                entry: modelData
                homeSide: false
              }
            }
          }
        }

        // ------------------------------------------------- your own players
        Item {
          width: parent.width
          height: visible ? mineFlow.implicitHeight + Style.spacing.sm : 0
          visible: card.modelData.mine.length > 0

          Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: app ? app.hairline : "#333"
          }

          Flow {
            id: mineFlow
            anchors.top: parent.top
            anchors.topMargin: Style.spacing.sm
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: card.modelData.mine
              delegate: Rectangle {
                required property var modelData
                width: pill.implicitWidth + Style.spacing.md
                height: pill.implicitHeight + Style.space(5)
                radius: app ? app.cornerRadius : 0
                color: Util.alpha(app ? app.foreground : "#fff",
                                  modelData.counting ? 0.10 : 0.04)

                Text {
                  textFormat: Text.PlainText
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
                  color: modelData.counting ? (app ? app.foreground : "#fff")
                                            : (app ? app.fainter : "#888")
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                  font.bold: modelData.captain
                }

                // Same gesture as on the pitch: double-click to look him up.
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onDoubleClicked: if (app) app.revealPlayer(modelData.id)
                }
              }
            }
          }
        }

        // ------------------------------------- the bonus race, or the referee
        // Bonus points are a fantasy scoring mechanic — "6 bps" means nothing
        // to somebody who just watches the football. Fan mode gets the man in
        // the middle in that slot instead, which is a fact about the match
        // rather than a fact about the game played on top of it.
        Item {
          width: parent.width
          height: visible ? raceCol.implicitHeight + Style.spacing.sm : 0
          visible: tab.statto ? !!card.fx.referee
                              : (card.modelData.race !== null && card.modelData.race !== undefined)

          Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: app ? app.hairline : "#333"
          }

          Column {
            id: raceCol
            anchors.top: parent.top
            anchors.topMargin: Style.spacing.sm
            width: parent.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: tab.statto ? "Referee" : "Bonus race"
              color: app ? app.fainter : "#888"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              visible: tab.statto
              text: card.fx.referee || ""
              color: app ? app.foreground : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: (!tab.statto && card.modelData.race) ? card.modelData.race.rows : []
              delegate: Row {
                required property var modelData
                spacing: Style.spacing.md

                Text {
                  textFormat: Text.PlainText
                  width: Style.space(30)
                  text: modelData.bonus > 0 ? "+" + modelData.bonus : ""
                  color: app ? app.accent : "#fff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  width: Style.space(170)
                  text: modelData.name + "  " + modelData.team
                  color: app ? app.foreground : "#fff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
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
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: tab.rows.length === 0
      text: "No matches this gameweek match that."
      color: app ? app.dim : "#aaa"
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.subtitle
    }
  }
}
