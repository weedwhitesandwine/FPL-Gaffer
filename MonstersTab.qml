import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// Monsters — a bit of fun. Nine ways to be remarkable, each with a podium of
// three. Ported from the categories Neil's earlier FPL Gaffer used.
//
// The medals are fixed colours, like the cards and the difficulty ramp:
// gold, silver and bronze mean the same thing in every theme, and each
// carries a hairline outline so it survives any background.
//
// Early in a season most of these are empty, and that is the honest answer
// rather than a bug — a category says so in words instead of showing blanks.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property var board: st.monsters || ({ minutes: 90, categories: [] })

  // Two panels across when there is room, one when there is not — laid out
  // as independent columns rather than rows, so a short panel does not leave
  // a hole beneath it waiting for its neighbour to finish.
  readonly property int columns: Math.max(1, Math.floor(width / Style.space(430)))
  readonly property int panelWidth:
    (width - Style.spacing.md * (columns - 1)) / columns

  function columnFor(which) {
    var out = []
    var cats = tab.board.categories || []
    for (var i = 0; i < cats.length; i++)
      if (tab.columns === 1 || i % tab.columns === which) out.push(cats[i])
    return out
  }

  function activate(index) {}

  // Every category keeps three places whether or not anyone has filled them.
  // A podium with one man on it still has a second and third step, and boxes
  // that all stand the same height separate far more cleanly than boxes that
  // shrink to fit whatever they happen to hold.
  function podium(category) {
    var out = []
    var players = category.players || []
    for (var i = 0; i < 3; i++) out.push(i < players.length ? players[i] : null)
    return out
  }

  // Gold, silver, bronze. Fixed on purpose — a podium reads by colour.
  function medal(place) {
    return place === 0 ? "#d4af37" : (place === 1 ? "#aeb7c0" : "#c17f3a")
  }

  Flickable {
    anchors.fill: parent
    contentHeight: grid.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Row {
      id: grid
      width: parent.width
      spacing: Style.spacing.lg

      Repeater {
        model: tab.columns

        delegate: Column {
          required property int index
          width: tab.panelWidth
          spacing: Style.spacing.lg

          Repeater {
            model: tab.columnFor(parent.index)

            delegate: Rectangle {
          id: panel
          required property var modelData

          width: tab.panelWidth
          height: panelBody.implicitHeight + Style.spacing.lg * 2

          radius: app ? app.cornerRadius : 0
          color: Util.alpha(app ? app.foreground : "#fff", 0.05)
          border.width: 1
          border.color: Util.alpha(app ? app.foreground : "#fff", 0.16)

          Column {
            id: panelBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.spacing.lg
            spacing: Style.spacing.sm

            // ------------------------------------------------ the category
            Item {
              width: parent.width
              height: titleCol.implicitHeight

              Text {
                id: glyph
                anchors.left: parent.left
                anchors.top: parent.top
                width: Style.space(26)
                text: panel.modelData.glyph
                color: app ? app.accent : "#fff"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.heading
              }

              Column {
                id: titleCol
                anchors.left: glyph.right
                anchors.leftMargin: Style.spacing.sm
                anchors.right: statTag.left
                anchors.rightMargin: Style.spacing.sm
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: panel.modelData.title
                  color: app ? app.foreground : "#fff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: panel.modelData.blurb
                  color: app ? app.dim : "#aaa"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Text {
                id: statTag
                anchors.right: parent.right
                anchors.top: parent.top
                text: panel.modelData.stat
                color: app ? app.fainter : "#888"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
              }
            }

            // -------------------------------------------------- the podium
            Column {
              width: parent.width
              spacing: Style.space(3)

              Repeater {
                model: tab.podium(panel.modelData)

                delegate: Rectangle {
                  id: place
                  required property var modelData
                  required property int index
                  readonly property bool winner: index === 0
                  readonly property bool empty: place.modelData === null
                                                || place.modelData === undefined
                  // Only the first empty step of a category nobody has
                  // troubled says so; the rest simply stand empty.
                  readonly property bool speaks:
                    place.empty && (panel.modelData.players || []).length === 0
                    && place.index === 0

                  width: parent.width
                  height: Math.max(Style.space(30),
                                   Style.font.body + Style.spacing.sm * 2
                                   + (winner ? Style.space(4) : 0))
                  radius: app ? app.cornerRadius : 0
                  color: place.empty
                           ? Util.alpha(app ? app.foreground : "#fff", 0.02)
                           : Util.alpha(app ? app.foreground : "#fff", winner ? 0.09 : 0.05)

                  // The medal, as a bar down the leading edge.
                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Style.space(4)
                    radius: width / 2
                    color: tab.medal(place.index)
                    opacity: place.empty ? 0.22 : 1.0
                    border.width: place.empty ? 0 : 1
                    border.color: app ? app.fixedOutline : "#fff"
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: !place.empty
                    cursorShape: Qt.PointingHandCursor
                    onDoubleClicked: if (app) app.revealPlayer((place.modelData || {}).id)
                  }

                  // An empty step still shows its number, and the first one
                  // of an untroubled category says so in words.
                  Text {
                    visible: place.empty
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(16)
                    text: String(place.index + 1)
                    color: tab.medal(place.index)
                    opacity: 0.45
                    font.family: app ? app.fontFamily : "monospace"
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  Text {
                    visible: place.empty
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.md + Style.space(24)
                    anchors.verticalCenter: parent.verticalCenter
                    text: place.speaks ? "Nobody has managed it yet" : "—"
                    color: app ? app.fainter : "#888"
                    font.family: app ? app.fontFamily : "monospace"
                    font.pixelSize: Style.font.bodySmall
                  }

                  Row {
                    visible: !place.empty
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.md
                    anchors.rightMargin: Style.spacing.md
                    spacing: Style.spacing.sm

                    Text {
                      width: Style.space(16)
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(place.index + 1)
                      color: tab.medal(place.index)
                      font.family: app ? app.fontFamily : "monospace"
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: String((place.modelData || {}).name || "")
                      color: app ? app.foreground : "#fff"
                      font.family: app ? app.fontFamily : "monospace"
                      font.pixelSize: place.winner ? Style.font.subtitle : Style.font.body
                      font.bold: place.winner
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, Style.space(120))
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: String((place.modelData || {}).team || "") + " "
                            + String((place.modelData || {}).pos || "")
                      color: app ? app.fainter : "#888"
                      font.family: app ? app.fontFamily : "monospace"
                      font.pixelSize: Style.font.caption
                    }

                    // Set-piece duties spell themselves out; everything else
                    // is a number.
                    Text {
                      visible: !place.empty
                               && String((place.modelData || {}).duties || "") !== ""
                      anchors.verticalCenter: parent.verticalCenter
                      text: String((place.modelData || {}).duties || "")
                      color: app ? app.accent : "#fff"
                      font.family: app ? app.fontFamily : "monospace"
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    visible: !place.empty
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    text: place.empty ? "" : String((place.modelData || {}).value || "")
                    color: app ? app.foreground : "#fff"
                    font.family: app ? app.fontFamily : "monospace"
                    font.pixelSize: place.winner ? Style.font.title : Style.font.body
                    font.bold: true
                  }
                }
              }

            }
          }
            }
          }
        }
      }
    }
  }

  // A standing note, so an empty board early in a season explains itself.
  Text {
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    visible: (tab.board.categories || []).length === 0
    text: "Monsters need " + tab.board.minutes + " minutes played before they count."
    color: app ? app.dim : "#aaa"
    font.family: app ? app.fontFamily : "monospace"
    font.pixelSize: Style.font.subtitle
  }
}
