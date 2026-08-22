import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// Every player in the game. Type to search by name or club, use the chips to
// narrow by position, and click any column heading to rank by it — click the
// same heading again to flip the order.
//
// There is deliberately no separate row of sort buttons: the columns are
// already on screen, and a second list of the same words only leaves you
// wondering which one is in charge.
Item {
  id: tab
  property var app: null

  readonly property var st: app && app.state ? app.state : ({})
  readonly property string q: app ? app.filterText : ""
  readonly property bool statto: app ? app.statto : false

  property string position: "all"
  property string sortKey: "points"
  property bool sortDesc: true

  // One definition per column, used for the heading, the sorting and the
  // cell — so a column cannot be labelled one thing and filled with another.
  readonly property var columns: statto
    ? [
        { key: "name",    label: "PLAYER", w: 168, align: "left",  kind: "name" },
        { key: "pos",     label: "POS",    w: 40,  align: "left",  kind: "text" },
        { key: "goals",   label: "G",      w: 44,  align: "right", kind: "int", strong: true },
        { key: "assists", label: "A",      w: 44,  align: "right", kind: "int", strong: true },
        { key: "minutes", label: "MINS",   w: 54,  align: "right", kind: "int" },
        { key: "xg",      label: "xG",     w: 48,  align: "right", kind: "dec" },
        { key: "xa",      label: "xA",     w: 48,  align: "right", kind: "dec" },
        { key: "xgi",     label: "xGI",    w: 48,  align: "right", kind: "dec" },
        { key: "defcon",  label: "DEF",    w: 46,  align: "right", kind: "int" }
      ]
    : [
        { key: "name",     label: "PLAYER", w: 168, align: "left",  kind: "name" },
        { key: "pos",      label: "POS",    w: 40,  align: "left",  kind: "text" },
        { key: "cost",     label: "PRICE",  w: 62,  align: "right", kind: "price" },
        { key: "points",   label: "PTS",    w: 46,  align: "right", kind: "int", strong: true },
        { key: "form",     label: "FORM",   w: 52,  align: "right", kind: "raw" },
        { key: "selected", label: "OWNED",  w: 58,  align: "right", kind: "pct" },
        { key: "tin",      label: "IN",     w: 58,  align: "right", kind: "big" },
        { key: "tout",     label: "OUT",    w: 58,  align: "right", kind: "big" },
        { key: "xgi",      label: "xGI",    w: 48,  align: "right", kind: "dec" },
        { key: "defcon",   label: "DEF",    w: 46,  align: "right", kind: "int" },
        { key: "ep",       label: "PRED",   w: 52,  align: "right", kind: "raw" }
      ]

  readonly property int colGap: Style.spacing.md

  onStattoChanged: {
    tab.sortKey = statto ? "goals" : "points"
    tab.sortDesc = true
  }

  function sortBy(column) {
    if (tab.sortKey === column.key) {
      tab.sortDesc = !tab.sortDesc
    } else {
      tab.sortKey = column.key
      // Numbers are most useful biggest-first; names are not.
      tab.sortDesc = column.kind !== "name" && column.kind !== "text"
    }
    if (app) app.selectedIndex = 0
  }

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
    var dir = tab.sortDesc ? 1 : -1
    var textual = key === "name" || key === "pos"
    out.sort(function(a, b) {
      if (textual) {
        var av = String(a[key] || "").toLowerCase()
        var bv = String(b[key] || "").toLowerCase()
        return av < bv ? dir : (av > bv ? -dir : 0)
      }
      return (Number(b[key] || 0) - Number(a[key] || 0)) * dir
    })
    return out
  }

  // Someone double-clicked this player elsewhere: find him in the current
  // order, select him and scroll him into the middle of the view.
  //
  // Two things make that harder than it looks. The view has no valid height
  // the instant it is built, so scrolling immediately does nothing; and the
  // refresh that fires when the overlay opens rebuilds this list a moment
  // later, which resets the scroll. So the request is held until the scroll
  // has actually been applied, and re-applied if the rows change underneath
  // it in the meantime.
  property int revealIndex: -1

  function tryReveal() {
    if (!app || !app.pendingPlayerId) return
    for (var i = 0; i < tab.rows.length; i++) {
      if (tab.rows[i].id === app.pendingPlayerId) {
        tab.revealIndex = i
        app.selectedIndex = i
        revealTimer.restart()
        return
      }
    }
  }

  Timer {
    id: revealTimer
    interval: 160
    repeat: false
    onTriggered: {
      if (tab.revealIndex < 0 || tab.revealIndex >= tab.rows.length) return
      list.positionViewAtIndex(tab.revealIndex, ListView.Center)
      tab.revealIndex = -1
      if (app) app.pendingPlayerId = 0
    }
  }

  onAppChanged: tab.tryReveal()
  onRowsChanged: tab.tryReveal()

  function activate(index) {
    var r = rows[Math.min(index, rows.length - 1)]
    if (r && app) app.toggleWatch(r.id)
  }

  function cellText(column, p) {
    var v = p[column.key]
    switch (column.kind) {
      case "int":   return String(v || 0)
      case "raw":   return v ? String(v) : "—"
      case "pct":   return (v === undefined || v === null) ? "—" : v + "%"
      case "big":   return Fmt.rank(v || 0)
      case "price": return (v === undefined || v === null) ? "—" : Number(v).toFixed(1)
      case "dec":   return (v === undefined || v === null) ? "—" : Number(v).toFixed(1)
      default:      return (v === undefined || v === null) ? "" : String(v)
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.spacing.sm

    // Position filter — the one control the columns cannot provide — with a
    // key for the two markers that appear beside a name.
    Row {
      width: parent.width
      spacing: Style.spacing.lg

      Row {
      spacing: Style.space(3)
      Repeater {
        model: ["all", "GKP", "DEF", "MID", "FWD"]
        delegate: Rectangle {
          required property var modelData
          readonly property bool active: tab.position === modelData
          width: chipText.implicitWidth + Style.spacing.lg
          height: Math.max(Style.space(24), Style.font.bodySmall + Style.spacing.sm * 2)
          radius: app ? app.cornerRadius : 0
          color: active ? (app ? app.selectedBackground : "#222")
                        : Util.alpha(app ? app.foreground : "#fff", 0.05)
          Text {
            textFormat: Text.PlainText
            id: chipText
            anchors.centerIn: parent
            text: modelData === "all" ? "All" : modelData
            color: active ? (app ? app.selectedText : "#fff") : (app ? app.dim : "#aaa")
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            font.bold: active
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { tab.position = modelData; if (app) app.selectedIndex = 0 }
          }
        }
      }
      }

      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.md

        Row {
          spacing: Style.space(3)
          Text {
            textFormat: Text.PlainText
            text: "P"
            color: app ? app.accent : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: "takes penalties"
            color: app ? app.fainter : "#888"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          spacing: Style.space(3)
          Text {
            textFormat: Text.PlainText
            text: "★"
            color: app ? app.accent : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            text: "on your watchlist — Enter to add"
            color: app ? app.fainter : "#888"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // Column headings — these are the sort control.
    Item {
      width: parent.width
      height: Math.max(Style.space(22), Style.font.bodySmall + Style.spacing.sm)

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.rowPaddingX
        spacing: tab.colGap

        Repeater {
          model: tab.columns
          delegate: Item {
            id: head
            required property var modelData
            readonly property bool active: tab.sortKey === head.modelData.key

            width: Style.space(head.modelData.w)
            height: parent.height

            Row {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: head.modelData.align === "left" ? parent.left : undefined
              anchors.right: head.modelData.align === "right" ? parent.right : undefined
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: head.modelData.label
                color: head.active ? (app ? app.accent : "#fff") : (app ? app.fainter : "#888")
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                font.bold: head.active
              }
              Text {
                textFormat: Text.PlainText
                visible: head.active
                text: tab.sortDesc ? "▼" : "▲"
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
              onClicked: tab.sortBy(head.modelData)
            }
          }
        }
      }

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: app ? app.hairline : "#333"
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
        id: row
        required property var modelData
        required property int index
        readonly property bool current: index === list.currentIndex

        width: list.width
        height: Math.max(Style.space(26), Style.font.body + Style.spacing.sm * 2)
        radius: app ? app.cornerRadius : 0
        color: current ? (app ? app.selectedBackground : "#222")
             : row.modelData.owned ? Util.alpha(app ? app.accent : "#fff", 0.08) : "transparent"

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (app) app.selectedIndex = row.index
          onDoubleClicked: tab.activate(row.index)
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.rightMargin: Style.spacing.rowPaddingX
          spacing: tab.colGap

          Repeater {
            model: tab.columns
            delegate: Item {
              id: cell
              required property var modelData
              readonly property var col: cell.modelData
              readonly property var p: row.modelData
              readonly property bool sorted: tab.sortKey === cell.col.key

              width: Style.space(cell.col.w)
              height: row.height

              // The name carries its club and its markers, so it gets a
              // small layout of its own rather than a single label.
              Row {
                visible: cell.col.kind === "name"
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: cell.p.name
                  color: app ? app.statusColor(cell.p.status) : "#fff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.body
                  font.bold: cell.p.owned
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, Style.space(100))
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: cell.p.team
                  color: app ? app.fainter : "#888"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  visible: app ? app.isWatched(cell.p.id) : false
                  anchors.verticalCenter: parent.verticalCenter
                  text: "★"
                  color: app ? app.accent : "#fff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  visible: cell.p.pens === 1
                  anchors.verticalCenter: parent.verticalCenter
                  text: "P"
                  color: app ? app.accent : "#fff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              // Price carries the direction it is drifting.
              Row {
                visible: cell.col.kind === "price"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: tab.cellText(cell.col, cell.p)
                  color: app ? app.foreground : "#fff"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                  font.bold: cell.sorted
                }
                Text {
                  textFormat: Text.PlainText
                  visible: Math.abs(cell.p.price_pct || 0) >= 50
                  text: (cell.p.price_pct || 0) > 0 ? "▲" : "▼"
                  color: app ? app.deltaColor(cell.p.price_pct || 0) : "#aaa"
                  font.family: app ? app.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                }
              }

              // Everything else is one value in one place.
              Text {
                textFormat: Text.PlainText
                visible: cell.col.kind !== "name" && cell.col.kind !== "price"
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: cell.col.align === "right" ? Text.AlignRight : Text.AlignLeft
                text: tab.cellText(cell.col, cell.p)
                color: (cell.col.strong === true) || cell.sorted ? (app ? app.foreground : "#fff")
                                                                 : (app ? app.dim : "#aaa")
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
                font.bold: (cell.col.strong === true) || cell.sorted
                elide: Text.ElideRight
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
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
