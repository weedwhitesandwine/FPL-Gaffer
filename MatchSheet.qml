import QtQuick
import qs.Commons

// The two things a match card cannot say in a line: who is on the pitch, and
// what the game has actually looked like.
//
// The line-ups are drawn as a pitch rather than listed, because a shape is
// read at a glance and eleven names are not — the home side attacks left to
// right, the away side right to left, exactly as the two halves would be laid
// out on a television graphic. The Premier League publishes the formation as
// lines of players running from the goalkeeper forward, so the pitch is that
// data drawn rather than a guess at it: a back three is three across the
// first line because the league said three.
//
// The statistics underneath are the league's own numbers, split the same way
// the events are — home on the left of the divider, away on the right — so
// the whole card reads down one axis.
Item {
  id: sheet

  property var app: null
  property var fx: null

  readonly property var lineups: sheet.fx && sheet.fx.lineups ? sheet.fx.lineups : null
  readonly property var stats: sheet.fx && sheet.fx.mstats ? sheet.fx.mstats : []
  readonly property color fg: app ? app.foreground : "#fff"
  readonly property color faint: app ? app.fainter : "#888"

  implicitHeight: body.implicitHeight
  height: implicitHeight

  // Both sides walked once: every player on the pitch as one flat list, each
  // carrying where on the grass to draw them — which half, how far up it, and
  // how far across their own line — and, alongside, the most anyone's line
  // holds, which is what decides how tall the pitch has to be. A back five
  // needs five chips stacked without touching.
  //
  // Positions are fractions rather than pixels, so the pitch can be any width
  // the card happens to be.
  readonly property var pitchPlan: {
    var out = { spots: [], widest: 1 }
    if (!sheet.lineups) return out
    var sides = [["home", sheet.lineups.home], ["away", sheet.lineups.away]]
    for (var s = 0; s < sides.length; s++) {
      var side = sides[s][1]
      var lines = side && side.lines ? side.lines : []
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i] || []
        out.widest = Math.max(out.widest, line.length)
        for (var j = 0; j < line.length; j++) {
          out.spots.push({
            player: line[j],
            home: sides[s][0] === "home",
            depth: (i + 0.5) / lines.length,
            across: (j + 0.5) / line.length
          })
        }
      }
    }
    return out
  }

  Column {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.spacing.md

    // ------------------------------------------------------------ line-ups
    Item {
      width: parent.width
      height: visible ? headingRow.implicitHeight : 0
      visible: !!sheet.lineups

      Text {
        textFormat: Text.PlainText
        id: headingRow
        text: "Line-ups"
        color: sheet.faint
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: sheet.lineups
                ? (sheet.lineups.home.formation || "—") + "   ·   "
                  + (sheet.lineups.away.formation || "—")
                : ""
        color: sheet.faint
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
      }
    }

    // The pitch, in the same fixed green the squad screen uses — one palette
    // for both, so a pitch is a pitch wherever it appears. It is deliberately
    // not a theme colour: grass that changes with the wallpaper stops reading
    // as grass, and the shirt numbers need a known background to sit on.
    // Laid out sideways rather than end-on, because two teams have to fit
    // across it and a line of names reads better wide than tall.
    Rectangle {
      id: pitch
      width: parent.width
      height: visible ? Math.max(Style.space(200), sheet.pitchPlan.widest * Style.space(46)) : 0
      visible: !!sheet.lineups
      radius: app ? app.cornerRadius : 0
      color: app ? app.turf : "#0a3a20"
      clip: true

      readonly property color chalk: app ? app.turfLine : Qt.rgba(1, 1, 1, 0.2)
      readonly property int box: Math.round(width * 0.11)

      // Mown bands, running the length of the pitch this time because it is
      // turned on its side. Barely there on purpose.
      Row {
        anchors.fill: parent
        Repeater {
          model: 8
          delegate: Rectangle {
            required property int index
            width: pitch.width / 8
            height: pitch.height
            color: index % 2 === 0 ? (app ? app.turfBand : "#0d4527") : "transparent"
          }
        }
      }

      Rectangle {                                        // halfway line
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: pitch.chalk
      }

      Rectangle {                                        // centre circle
        anchors.centerIn: parent
        width: Math.round(pitch.height * 0.34)
        height: width
        radius: width / 2
        color: "transparent"
        border.width: 1
        border.color: pitch.chalk
      }

      Rectangle {                                        // home penalty area
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: pitch.box
        height: Math.round(pitch.height * 0.55)
        color: "transparent"
        border.width: 1
        border.color: pitch.chalk
      }

      Rectangle {                                        // away penalty area
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: pitch.box
        height: Math.round(pitch.height * 0.55)
        color: "transparent"
        border.width: 1
        border.color: pitch.chalk
      }

      Repeater {
        model: sheet.pitchPlan.spots

        delegate: Item {
          id: spot
          required property var modelData

          readonly property var player: spot.modelData.player
          // The goalkeeper's line sits nearest his own goal, so the home side
          // reads left to right and the away side is the same arithmetic
          // measured from the other end.
          readonly property real half: pitch.width / 2
          readonly property real centreX: spot.modelData.home
            ? Style.space(6) + spot.modelData.depth * (half - Style.space(6))
            : pitch.width - Style.space(6) - spot.modelData.depth * (half - Style.space(6))

          width: Style.space(62)
          height: shirt.height + nameText.height + Style.space(2)
          x: Math.round(spot.centreX - width / 2)
          // Spread across the pitch's height minus one chip, so nobody at
          // either end of a five-man line hangs off the touchline.
          y: Math.round(spot.modelData.across * (pitch.height - height))

          Rectangle {
            id: shirt
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(20)
            height: Style.space(20)
            radius: width / 2
            // The captain wears the armband: a white ring, the same mark the
            // squad screen uses, rather than the theme's accent — which on
            // green is a colour picked to work somewhere else entirely.
            color: app ? app.shirt : "#1c7a48"
            border.width: spot.player && spot.player.c ? 2 : 1
            border.color: spot.player && spot.player.c
              ? "#ffffff" : (app ? app.shirtEdge : Qt.rgba(1, 1, 1, 0.22))

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: spot.player && spot.player.n ? String(spot.player.n) : ""
              color: app ? app.shirtText : "#ffffff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Text {
            textFormat: Text.PlainText
            id: nameText
            anchors.top: shirt.bottom
            anchors.topMargin: Style.space(2)
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: spot.player ? spot.player.name : ""
            color: app ? app.shirtText : "#ffffff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    // ---------------------------------------------------------------- bench
    Item {
      id: benches
      width: parent.width
      height: visible ? Math.max(homeSubs.implicitHeight, awaySubs.implicitHeight) : 0
      visible: !!sheet.lineups
                && ((sheet.lineups.home.subs || []).length > 0
                    || (sheet.lineups.away.subs || []).length > 0)

      function named(list) {
        var bits = []
        for (var i = 0; i < (list || []).length; i++)
          bits.push((list[i].n ? list[i].n + " " : "") + list[i].name)
        return bits.join(",  ")
      }

      Text {
        textFormat: Text.PlainText
        id: homeSubs
        anchors.left: parent.left
        anchors.top: parent.top
        width: (parent.width - Style.spacing.xl) / 2
        text: sheet.lineups ? benches.named(sheet.lineups.home.subs) : ""
        color: sheet.faint
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        id: awaySubs
        anchors.right: parent.right
        anchors.top: parent.top
        width: (parent.width - Style.spacing.xl) / 2
        horizontalAlignment: Text.AlignRight
        text: sheet.lineups ? benches.named(sheet.lineups.away.subs) : ""
        color: sheet.faint
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    // ----------------------------------------------------------- statistics
    Rectangle {
      width: parent.width
      height: visible ? 1 : 0
      visible: sheet.stats.length > 0 && !!sheet.lineups
      color: app ? app.hairline : "#333"
    }

    Column {
      width: parent.width
      spacing: Style.spacing.sm
      visible: sheet.stats.length > 0

      Repeater {
        model: sheet.stats

        // One number each side of a bar split between them. A share is the
        // honest way to draw two counts that are not out of anything — nine
        // shots against eighteen is a bar a third of the way across, and the
        // numbers themselves are there for anyone who wants the counts.
        delegate: Item {
          id: statRow
          required property var modelData
          readonly property real home: Number(modelData.h) || 0
          readonly property real away: Number(modelData.a) || 0
          readonly property real total: home + away
          readonly property real share: total > 0 ? home / total : 0.5

          width: parent.width
          height: label.implicitHeight + Style.space(9)

          function reading(n) {
            var text = (Math.round(n * 10) / 10).toString()
            return modelData.pct ? text + "%" : text
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.top: parent.top
            text: statRow.reading(statRow.home)
            color: sheet.fg
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            id: label
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            text: modelData.label
            color: sheet.faint
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.top: parent.top
            text: statRow.reading(statRow.away)
            color: sheet.fg
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Row {
            id: bar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(3)
            spacing: Style.space(2)

            readonly property real track: Math.max(0, width - spacing)

            Rectangle {
              width: bar.track * statRow.share
              height: parent.height
              radius: height / 2
              color: app ? app.accent : "#fff"
            }

            Rectangle {
              width: bar.track * (1 - statRow.share)
              height: parent.height
              radius: height / 2
              color: Util.alpha(sheet.fg, 0.22)
            }
          }
        }
      }
    }
  }
}
