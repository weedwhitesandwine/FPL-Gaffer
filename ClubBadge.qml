import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// One club crest. The engine downloads these once and keeps them in the state
// directory, so this only ever loads a file from this machine — the screens
// never reach the network themselves, and a crest that failed to arrive
// simply leaves a gap the club's three letters already fill.
Item {
  id: badge

  property var app: null
  property string club: ""
  property int size: Style.space(22)

  readonly property string path: {
    var all = app && app.state ? app.state.badges : null
    if (!all || !badge.club) return ""
    var p = all[badge.club]
    return typeof p === "string" ? p : ""
  }

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size
  visible: image.status === Image.Ready

  Image {
    id: image
    anchors.fill: parent
    source: Fmt.fileUrl(badge.path)
    // The file is 70 pixels square and drawn at about a third of that. Asking
    // for it at the size it is used at keeps the decoded copy that size too.
    sourceSize.width: badge.size * 2
    sourceSize.height: badge.size * 2
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
    cache: true
  }
}
