import QtQuick
import qs.Commons
import "Fmt.js" as Fmt

// Settings. Everything here is a draft until you press Save, so nothing
// touches your bindings or your bar until you say so.
Item {
  id: view
  property var app: null

  readonly property bool statto: app ? app.draftAppMode === "statto" : false

  component Section: Column {
    property string title: ""
    width: parent ? parent.width : 0
    spacing: Style.spacing.sm
    Text {
      text: parent.title
      color: app ? app.fainter : "#888"
      font.family: app ? app.fontFamily : "monospace"
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component Toggle: Rectangle {
    property string label: ""
    property string blurb: ""
    property bool checked: false
    signal picked()

    width: parent ? parent.width : 0
    height: toggleCol.implicitHeight + Style.spacing.md * 2
    radius: app ? app.cornerRadius : 0
    color: Util.alpha(app ? app.foreground : "#fff", 0.04)

    Row {
      anchors.fill: parent
      anchors.margins: Style.spacing.md
      spacing: Style.spacing.md

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(34)
        height: Style.space(18)
        radius: height / 2
        color: checked ? Util.alpha(app ? app.accent : "#fff", 0.55)
                       : Util.alpha(app ? app.foreground : "#fff", 0.15)
        Rectangle {
          width: Style.space(14)
          height: Style.space(14)
          radius: height / 2
          anchors.verticalCenter: parent.verticalCenter
          x: checked ? parent.width - width - Style.space(2) : Style.space(2)
          color: app ? app.foreground : "#fff"
          Behavior on x { NumberAnimation { duration: 110 } }
        }
      }

      Column {
        id: toggleCol
        width: parent.width - Style.space(34) - Style.spacing.md
        spacing: Style.space(1)
        Text {
          text: label
          color: app ? app.foreground : "#fff"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.body
        }
        Text {
          visible: blurb !== ""
          width: parent.width
          text: blurb
          color: app ? app.dim : "#aaa"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.picked()
    }
  }

  Flickable {
    anchors.fill: parent
    contentHeight: form.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: form
      width: parent.width
      spacing: Style.spacing.lg

      // ---------------------------------------------------------- what it is
      Section {
        title: "MODE"

        Repeater {
          model: [
            { id: "gaffer", title: "FPL Gaffer mode",
              blurb: "You play Fantasy Premier League — your squad scored live, mini-leagues, "
                     + "price moves and deadline warnings." },
            { id: "statto", title: "Premier League Fan mode",
              blurb: "You just follow the football — scores, table, fixtures and player stats. "
                     + "No fantasy team needed." }
          ]
          delegate: Rectangle {
            required property var modelData
            readonly property bool chosen: !!app && app.draftAppMode === modelData.id

            width: form.width
            height: modeCol.implicitHeight + Style.spacing.md * 2
            radius: app ? app.cornerRadius : 0
            color: chosen ? Util.alpha(app ? app.accent : "#fff", 0.14)
                          : Util.alpha(app ? app.foreground : "#fff", 0.04)
            border.width: chosen ? 1 : 0
            border.color: app ? app.accent : "#fff"

            Column {
              id: modeCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.spacing.md
              spacing: Style.space(1)
              Text {
                text: modelData.title
                color: app ? app.foreground : "#fff"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                width: parent.width
                text: modelData.blurb
                color: app ? app.dim : "#aaa"
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (app) app.draftAppMode = modelData.id
            }
          }
        }
      }

      // ------------------------------------------------------- the team code
      Section {
        title: "YOUR TEAM"
        visible: !view.statto

        Rectangle {
          width: form.width
          height: Math.max(Style.space(38), Style.font.heading + Style.spacing.inputPaddingY * 2)
          radius: app ? app.cornerRadius : 0
          color: Util.alpha(app ? app.foreground : "#fff", 0.06)
          border.width: 1
          border.color: app && app.editingEntry ? app.accent : app.hairline

          Text {
            anchors.centerIn: parent
            text: app && app.draftEntry !== "" ? app.draftEntry : "your team ID"
            color: app && app.draftEntry !== "" ? app.foreground : app.fainter
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.heading
            font.bold: app && app.draftEntry !== ""
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onClicked: if (app) app.editingEntry = true
          }
        }

        Text {
          width: form.width
          text: "Type digits to edit · Ctrl+V to paste · Backspace to correct"
          color: app ? app.fainter : "#888"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
        }

        // How to find it — written out so you never have to go looking.
        Rectangle {
          width: form.width
          height: help.implicitHeight + Style.spacing.md * 2
          radius: app ? app.cornerRadius : 0
          color: Util.alpha(app ? app.foreground : "#fff", 0.04)

          Text {
            id: help
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.spacing.md
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            lineHeight: 1.25
            text: "Your FPL team ID is the number in your own team's web address. This works "
                + "right now, before the season starts, with no leagues and no history:\n\n"
                + "1.  Sign in at fantasy.premierleague.com in a browser.\n"
                + "2.  Open Pick Team from the menu.\n"
                + "3.  In the Points & Rankings box, click Gameweek History.\n"
                + "4.  Look at the address bar. It reads\n"
                + "     fantasy.premierleague.com/en/entry/1234567/history —\n"
                + "     the number in the middle is your team ID.\n\n"
                + "The same number appears if you open Transfers and click Transfer History.\n\n"
                + "To check you have the right one, open\n"
                + "fantasy.premierleague.com/api/entry/YOUR-ID/ in a browser. It should show "
                + "your team name and your own name. If it shows somebody else, you have "
                + "copied the wrong number."
          }
        }
      }

      // ------------------------------------------------------- notifications
      Section {
        title: "NOTIFICATIONS"

        Toggle {
          label: "Live scores"
          blurb: "Every goal in every match, plus full time. Works in both modes."
          checked: app ? app.draftNotify.matchGoals === true : false
          onPicked: if (app) app.setNotify("matchGoals", !app.draftNotify.matchGoals)
        }
        Toggle {
          label: "Kick offs"
          blurb: "A quiet ping as each match gets under way."
          checked: app ? app.draftNotify.kickoff === true : false
          onPicked: if (app) app.setNotify("kickoff", !app.draftNotify.kickoff)
        }
        Toggle {
          label: "Your players score"
          blurb: "Goals, assists and red cards for the players in your squad."
          visible: !view.statto
          checked: app ? app.draftNotify.goals !== false : false
          onPicked: if (app) app.setNotify("goals", !(app.draftNotify.goals !== false))
        }
        Toggle {
          label: "Team news"
          blurb: "When a player's injury or availability note changes."
          checked: app ? app.draftNotify.news !== false : false
          onPicked: if (app) app.setNotify("news", !(app.draftNotify.news !== false))
        }
        Toggle {
          label: "Bonus confirmed"
          blurb: "When the gameweek's bonus points are finally applied."
          visible: !view.statto
          checked: app ? app.draftNotify.bonus !== false : false
          onPicked: if (app) app.setNotify("bonus", !(app.draftNotify.bonus !== false))
        }
        Toggle {
          label: "Price changes"
          blurb: "When someone you own or watch is about to rise or fall tonight."
          visible: !view.statto
          checked: app ? app.draftNotify.prices !== false : false
          onPicked: if (app) app.setNotify("prices", !(app.draftNotify.prices !== false))
        }
        Toggle {
          label: "Deadline warnings"
          blurb: "At 24 hours, 3 hours and 1 hour, naming any doubts in your XI."
          visible: !view.statto
          checked: app ? app.draftNotify.deadline !== false : false
          onPicked: if (app) app.setNotify("deadline", !(app.draftNotify.deadline !== false))
        }
      }

      // ------------------------------------------------------------ the bar
      Section {
        title: "BAR AND HOTKEY"

        Toggle {
          label: "Show in the bar"
          blurb: view.statto ? "Next kick-off, or the live scoreline while matches are on."
                             : "Your live gameweek score, or the countdown to the deadline."
          checked: app ? app.draftBarIcon === true : false
          onPicked: if (app) app.draftBarIcon = !app.draftBarIcon
        }

        Row {
          spacing: Style.space(4)
          visible: app ? app.draftBarIcon : false
          Repeater {
            model: ["left", "center", "right"]
            delegate: Rectangle {
              required property var modelData
              readonly property bool chosen: !!app && app.draftBarSection === modelData
              width: sectionLabel.implicitWidth + Style.spacing.lg
              height: Math.max(Style.space(24), Style.font.bodySmall + Style.spacing.sm * 2)
              radius: app ? app.cornerRadius : 0
              color: chosen ? (app ? app.selectedBackground : "#222")
                            : Util.alpha(app ? app.foreground : "#fff", 0.04)
              Text {
                id: sectionLabel
                anchors.centerIn: parent
                text: modelData
                color: chosen ? (app ? app.selectedText : "#fff") : (app ? app.dim : "#aaa")
                font.family: app ? app.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (app) app.draftBarSection = modelData
              }
            }
          }
        }

        Rectangle {
          width: form.width
          height: Math.max(Style.space(32), Style.font.body + Style.spacing.inputPaddingY * 2)
          radius: app ? app.cornerRadius : 0
          color: Util.alpha(app ? app.foreground : "#fff", 0.04)
          border.width: app && app.capturing ? 1 : 0
          border.color: app ? app.accent : "#fff"

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: app && app.capturing
                    ? (app.captureNote !== "" ? app.captureNote : "Press the keys you want…")
                  : app && app.draftShortcut !== "" ? "Hotkey:  " + app.draftShortcut
                  : "Hotkey:  none — click to set one"
            color: app ? (app.capturing ? app.accent : app.foreground) : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
          }

          Text {
            visible: app && app.draftShortcut !== "" && !app.capturing
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "clear"
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              cursorShape: Qt.PointingHandCursor
              onClicked: if (app) app.draftShortcut = ""
            }
          }

          MouseArea {
            anchors.fill: parent
            anchors.rightMargin: Style.space(50)
            cursorShape: Qt.PointingHandCursor
            onClicked: if (app) { app.capturing = true; app.captureNote = "" }
          }
        }
      }

      // ---------------------------------------------------------- save / back
      Row {
        width: form.width
        spacing: Style.spacing.md

        Rectangle {
          width: Style.space(110)
          height: Math.max(Style.space(30), Style.font.body + Style.spacing.controlPaddingY * 2)
          radius: app ? app.cornerRadius : 0
          color: Util.alpha(app ? app.accent : "#fff", 0.22)
          Text {
            anchors.centerIn: parent
            text: "Save"
            color: app ? app.foreground : "#fff"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            font.bold: true
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (app) app.applyDrafts()
          }
        }

        Rectangle {
          width: Style.space(110)
          height: Math.max(Style.space(30), Style.font.body + Style.spacing.controlPaddingY * 2)
          radius: app ? app.cornerRadius : 0
          color: Util.alpha(app ? app.foreground : "#fff", 0.06)
          Text {
            anchors.centerIn: parent
            text: "Cancel"
            color: app ? app.dim : "#aaa"
            font.family: app ? app.fontFamily : "monospace"
            font.pixelSize: Style.font.body
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (app) app.view = "list"
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Enter saves  ·  Esc goes back"
          color: app ? app.fainter : "#888"
          font.family: app ? app.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
