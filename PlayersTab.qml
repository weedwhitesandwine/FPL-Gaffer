import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// Every player in the game, searchable and sortable. Type to search by name
// or club; the row of chips filters by position and switches the sort. Enter
// stars a player, which puts them on the price and news watch.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""
  readonly property bool statto: app ? app.statto : false

  property string position: "all"
  property string sortKey: "points"

  // Fantasy points and bonus points only exist inside the game, so the
  // football-only mode sorts and shows what actually happened on the pitch.
  readonly property var sorts: statto
    ? [
        { id: "goals",   label: "Goals" },
        { id: "assists", label: "Assists" },
        { id: "xg",      label: "xG" },
        { id: "xa",      label: "xA" },
        { id: "xgi",     label: "xGI" },
        { id: "minutes", label: "Minutes" },
        { id: "defcon",  label: "Def" }
      ]
    : [
        { id: "points",   label: "Points" },
        { id: "form",     label: "Form" },
        { id: "xgi",      label: "xGI" },
        { id: "defcon",   label: "Def" },
        { id: "cost",     label: "Price" },
        { id: "selected", label: "Owned" },
        { id: "tin",      label: "Transfers in" },
        { id: "ep",       label: "Predicted" }
      ]

  onStattoChanged: tab.sortKey = statto ? "goals" : "points"

  readonly property var rows: {
    var all = st.all_players || []
    var out = []
    for (var i = 0; i < all.length; i++) {
      var p = all[i]
      if (tab.position !== "all" && p.pos !== tab.position) continue
      if (!Fmt.matches(p.name, q) && !Fmt.matches(p.team, q)) continue
      out.push(p)
    }
    var key = tab.sortKey
    out.sort(function(a, b) { return Number(b[key] || 0) - Number(a[key] || 0) })
    return out.slice(0, 300)
  }

  function activate(index) {
    var r = rows[Math.min(index, rows.length - 1)]
    if (r && app) app.toggleWatch(r.id)
  }

  component Chip: Rectangle {
    property string label: ""
    property bool active: false
    signal picked()
    width: chipText.implicitWidth + Style.spacing.lg
    height: Math.max(Style.space(22), Style.font.caption + Style.spacing.sm * 2)
    radius: app ? app.cornerRadius : 0
    color: active ? (app ? app.selectedBackground : "#222")
                  : Util.alpha(app ? app.foreground : "#fff", 0.04)
    Text {
      id: chipText
      anchors.centerIn: parent
      text: parent.label
      color: parent.active ? (app ? app.selectedText : "#fff") : (app ? app.dim : "#aaa")
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.caption
      font.bold: parent.active
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.picked()
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.spacing.sm

    Row {
      width: parent.width
      spacing: Style.spacing.lg

      Row {
        spacing: Style.space(3)
        Repeater {
          model: ["all", "GKP", "DEF", "MID", "FWD"]
          delegate: Chip {
            required property var modelData
            label: modelData === "all" ? "All" : modelData
            active: tab.position === modelData
            onPicked: { tab.position = modelData; if (app) app.selectedIndex = 0 }
          }
        }
      }

      Rectangle { width: 1; height: Style.space(18); color: app ? app.hairline : "#333"
                  anchors.verticalCenter: parent.verticalCenter }

      Row {
        spacing: Style.space(3)
        Repeater {
          model: tab.sorts
          delegate: Chip {
            required property var modelData
            label: modelData.label
            active: tab.sortKey === modelData.id
            onPicked: { tab.sortKey = modelData.id; if (app) app.selectedIndex = 0 }
          }
        }
      }
    }

    // Column headings
    Item {
      width: parent.width
      height: Style.font.caption + Style.spacing.sm
      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.rowPaddingX
        spacing: Style.spacing.md
        Text { width: Style.space(160); text: "PLAYER"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Text { width: Style.space(34); text: "POS"; color: app ? app.fainter : "#888"
               font.family: app ? app.fontFamily : "monospace"; font.pixelSize: Style.font.caption }
        Repeater {
          model: tab.statto
            ? [ { w: 46, t: "G" }, { w: 46, t: "A" }, { w: 52, t: "MINS" },
                { w: 46, t: "xG" }, { w: 46, t: "xA" }, { w: 46, t: "xGI" },
                { w: 46, t: "DEF" } ]
            : [ { w: 52, t: "PRICE" }, { w: 46, t: "PTS" }, { w: 46, t: "FORM" },
                { w: 52, t: "OWNED" }, { w: 46, t: "xGI" }, { w: 46, t: "DEF" },
                { w: 52, t: "PRED" } ]
          delegate: Text {
            required property var modelData
            width: Style.space(modelData.w)
            horizontalAlignment: Text.AlignRight
            text: modelData.t
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
      height: parent.height - y
      clip: true
      model: tab.rows
      currentIndex: app ? Math.min(app.selectedIndex, tab.rows.length - 1) : 0
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
      boundsBehavior: Flickable.StopAtBounds
      cacheBuffer: 400

      delegate: Rectangle {
        required property var modelData
        required property int index
        readonly property bool current: index === list.currentIndex
        readonly property bool watched: app ? app.isWatched(modelData.id) : false

        width: list.width
        height: Math.max(Style.space(26), Style.font.body + Style.spacing.sm * 2)
        radius: app ? app.cornerRadius : 0
        color: current ? (app ? app.selectedBackground : "#222")
             : modelData.owned ? Util.alpha(app ? app.accent : "#fff", 0.08) : "transparent"

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (app) app.selectedIndex = index
          onDoubleClicked: tab.activate(index)
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.rightMargin: Style.spacing.rowPaddingX
          spacing: Style.spacing.md

          Item {
            width: Style.space(160)
            height: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
            Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              text: modelData.name
              color: app ? app.statusColor(modelData.status) : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.body
              font.bold: modelData.owned
              elide: Text.ElideRight
              width: Math.min(implicitWidth, Style.space(92))
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.team
              color: app ? app.fainter : "#888"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
            Text {
              visible: watched
              anchors.verticalCenter: parent.verticalCenter
              text: "★"
              color: app ? app.accent : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
            Text {
              visible: modelData.pens === 1
              anchors.verticalCenter: parent.verticalCenter
              text: "P"
              color: app ? app.accent : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
          }

          Text {
            width: Style.space(34)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.pos
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
          }

          // Price, with the direction it's drifting. Fantasy only.
          Row {
            visible: !tab.statto
            width: tab.statto ? 0 : Style.space(52)
            anchors.verticalCenter: parent.verticalCenter
            layoutDirection: Qt.RightToLeft
            spacing: Style.space(2)
            Text {
              visible: Math.abs(modelData.price_pct || 0) >= 50
              text: (modelData.price_pct || 0) > 0 ? "▲" : "▼"
              color: app ? app.deltaColor(modelData.price_pct || 0) : "#aaa"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
            }
            Text {
              text: Number(modelData.cost).toFixed(1)
              color: app ? app.foreground : "#fff"
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.bodySmall
            }
          }

          Repeater {
            model: tab.statto
              ? [ { w: 46, v: String(modelData.goals || 0), bold: true },
                  { w: 46, v: String(modelData.assists || 0), bold: true },
                  { w: 52, v: String(modelData.minutes || 0), bold: false },
                  { w: 46, v: modelData.xg !== undefined && modelData.xg !== null
                              ? Number(modelData.xg).toFixed(1) : "—", bold: false },
                  { w: 46, v: modelData.xa !== undefined && modelData.xa !== null
                              ? Number(modelData.xa).toFixed(1) : "—", bold: false },
                  { w: 46, v: modelData.xgi !== undefined && modelData.xgi !== null
                              ? Number(modelData.xgi).toFixed(1) : "—", bold: false },
                  { w: 46, v: String(modelData.defcon || 0), bold: false } ]
              : [ { w: 46, v: String(modelData.points), bold: true },
                  { w: 46, v: String(modelData.form), bold: false },
                  { w: 52, v: modelData.selected + "%", bold: false },
                  { w: 46, v: modelData.xgi !== undefined && modelData.xgi !== null
                              ? Number(modelData.xgi).toFixed(1) : "—", bold: false },
                  { w: 46, v: String(modelData.defcon || 0), bold: false },
                  { w: 52, v: modelData.ep ? String(modelData.ep) : "—", bold: false } ]
            delegate: Text {
              required property var modelData
              width: Style.space(modelData.w)
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              text: modelData.v
              color: modelData.bold ? (app ? app.foreground : "#fff") : (app ? app.dim : "#aaa")
              font.family: app ? app.fontFamily : "monospace"
              font.pixelSize: Style.font.bodySmall
              font.bold: modelData.bold
            }
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: tab.rows.length === 0
        text: "No players match that."
        color: app ? app.dim : "#aaa"
        font.family: app ? app.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
      }
    }
  }
}
