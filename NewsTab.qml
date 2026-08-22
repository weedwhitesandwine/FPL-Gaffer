import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// Three things worth knowing between deadlines: who's injured or doubtful,
// whose price is about to move, and who's in form but barely owned. Players
// you own float to the top of every list. Enter stars a player so their news
// and price moves reach you as desktop notifications.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""

  readonly property bool statto: app ? app.statto : false

  property string mode: "news"
  readonly property var modes: statto
    ? [ { id: "news", label: "Injuries & team news" } ]
    : [ { id: "news",   label: "Injuries & news" },
        { id: "prices", label: "Price watch" },
        { id: "diffs",  label: "Differentials" } ]

  onStattoChanged: if (statto) tab.mode = "news"

  readonly property var rows: {
    var out = []
    if (mode === "news") {
      var news = st.news || []
      for (var i = 0; i < news.length; i++) {
        var n = news[i]
        if (!Fmt.matches(n.name, q) && !Fmt.matches(n.team, q) && !Fmt.matches(n.news, q)) continue
        out.push(n)
      }
    } else if (mode === "prices") {
      var pw = st.price_watch || []
      for (var j = 0; j < pw.length; j++) {
        var p = pw[j]
        if (!Fmt.matches(p.name, q) && !Fmt.matches(p.team, q)) continue
        out.push(p)
      }
    } else {
      var d = st.differentials || []
      for (var k = 0; k < d.length; k++) {
        var e = d[k]
        if (!Fmt.matches(e.name, q) && !Fmt.matches(e.team, q)) continue
        out.push(e)
      }
    }
    return out
  }

  function activate(index) {
    var r = rows[Math.min(index, rows.length - 1)]
    if (r && app) app.toggleWatch(r.id)
  }

  Column {
    anchors.fill: parent
    spacing: Style.spacing.sm

    Row {
      width: parent.width
      spacing: Style.space(3)

      Repeater {
        model: tab.modes
        delegate: Rectangle {
          required property var modelData
          readonly property bool active: tab.mode === modelData.id
          width: modeLabel.implicitWidth + Style.spacing.lg
          height: Math.max(Style.space(24), Style.font.bodySmall + Style.spacing.sm * 2)
          radius: app ? app.cornerRadius : 0
          color: active ? (app ? app.selectedBackground : "#222")
                        : Util.alpha(app ? app.foreground : "#fff", 0.04)
          Text {
            textFormat: Text.PlainText
            id: modeLabel
            anchors.centerIn: parent
            text: modelData.label
            color: active ? (app ? app.selectedText : "#fff") : (app ? app.dim : "#aaa")
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            font.bold: active
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { tab.mode = modelData.id; if (app) app.selectedIndex = 0 }
          }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: tab.mode === "news"
              ? "Sorted with your own players first, then by how widely owned they are."
            : tab.mode === "prices"
              ? "How far each player has travelled toward a price change tonight, from the game's own projection."
              : "In form, available, and owned by under 8% of managers."
      color: app ? app.fainter : "#888"
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
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
        id: row
        required property var modelData
        required property int index
        readonly property bool current: index === list.currentIndex
        readonly property bool watched: app ? app.isWatched(row.modelData.id) : false

        width: list.width
        height: Math.max(Style.space(30), body.implicitHeight + Style.spacing.sm * 2)
        radius: app ? app.cornerRadius : 0
        color: current ? (app ? app.selectedBackground : "#222")
             : row.modelData.owned ? Util.alpha(app ? app.accent : "#fff", 0.08) : "transparent"

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (app) app.selectedIndex = index
          onDoubleClicked: tab.activate(index)
        }

        Row {
          id: body
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.rightMargin: Style.spacing.rowPaddingX
          spacing: Style.spacing.md

          // Name and club
          Row {
            width: Style.space(170)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            Text {
              textFormat: Text.PlainText
              text: row.modelData.name
              color: app ? app.statusColor(row.modelData.status) : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.body
              font.bold: row.modelData.owned
              elide: Text.ElideRight
              width: Math.min(implicitWidth, Style.space(112))
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: row.modelData.team
              color: app ? app.fainter : "#888"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
            Text {
              textFormat: Text.PlainText
              visible: row.watched
              anchors.verticalCenter: parent.verticalCenter
              text: "★"
              color: app ? app.accent : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
          }

          // --- injuries and news
          Text {
            textFormat: Text.PlainText
            visible: tab.mode === "news"
            width: Style.space(90)
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var word = Fmt.availability(row.modelData.status)
              if (row.modelData.chance !== null && row.modelData.chance !== undefined)
                return word + " " + row.modelData.chance + "%"
              return word
            }
            color: app ? app.statusColor(row.modelData.status) : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            visible: tab.mode === "news"
            width: Math.max(Style.space(80), parent.width - Style.space(300))
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.news || ""
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }

          // --- price watch: a bar showing how close the move is
          Text {
            textFormat: Text.PlainText
            visible: tab.mode === "prices"
            width: Style.space(64)
            anchors.verticalCenter: parent.verticalCenter
            text: Fmt.money(row.modelData.cost)
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            visible: tab.mode === "prices"
            width: Style.space(58)
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.direction === "up" ? "rising" : "falling"
            color: row.modelData.direction === "up" ? (app ? app.goodColor : "#3a3")
                                                    : (app ? app.badColor : "#a33")
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Rectangle {
            visible: tab.mode === "prices"
            width: Math.max(Style.space(60), parent.width - Style.space(400))
            height: Style.space(9)
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.space(2)
            color: Util.alpha(app ? app.foreground : "#fff", 0.10)
            Rectangle {
              width: parent.width * Math.min(1, (row.modelData.progress || 0) / 100)
              height: parent.height
              radius: parent.radius
              color: row.modelData.direction === "up" ? (app ? app.goodColor : "#3a3")
                                                      : (app ? app.badColor : "#a33")
              opacity: 0.85
            }
          }
          Text {
            textFormat: Text.PlainText
            visible: tab.mode === "prices"
            width: Style.space(50)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: Math.round(row.modelData.progress || 0) + "%"
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
          }

          // --- differentials
          Repeater {
            model: tab.mode === "diffs" ? [
              { w: 64, v: Fmt.money(row.modelData.cost) },
              { w: 46, v: row.modelData.pos },
              { w: 56, v: "form " + row.modelData.form },
              { w: 66, v: row.modelData.selected + "% own" },
              { w: 56, v: row.modelData.points + " pts" },
              { w: 66, v: row.modelData.xgi !== undefined && row.modelData.xgi !== null
                          ? "xGI " + Number(row.modelData.xgi).toFixed(1) : "" }
            ] : []
            delegate: Text {
              textFormat: Text.PlainText
              required property var modelData
              width: Style.space(modelData.w)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.v
              color: app ? app.dim : "#aaa"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: tab.rows.length === 0
        text: tab.mode === "prices"
                ? "Nothing is close to a price change right now."
              : tab.mode === "diffs"
                ? "No differentials yet — too early in the season for form to mean much."
                : "No news matches that."
        color: app ? app.dim : "#aaa"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
        width: parent.width - Style.space(40)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }
}
