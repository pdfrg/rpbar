import QtQuick
import Quickshell
import "RpLogic.js" as Rp
import qs.Commons
import qs.Ui

// rpbar pill: station + transport glyph; left-click plays/stops, right-click
// opens the station popup. The Service singleton owns playback; this widget
// is a thin view over it (one stream for all monitors).
BarWidget {
    id: root

    readonly property var radio: bar && bar.shell ? bar.shell.serviceFor("io.github.pdfrg.rpbar") : null
    // wantPlaying, not playing: during the stream-drop restart backoff the
    // stream is conceptually on, and a left-click should still mean "stop".
    readonly property bool playing: radio ? radio.wantPlaying : false
    readonly property string stationTitle: radio ? radio.stationTitle : ""
    readonly property string buildId: "0.1.2"
    property bool popupOpen: false

    function buildInfo() {
        return root.buildId;
    }

    function close() {
        popupOpen = false;
    }

    function syncSettings() {
        if (radio)
            radio.notifyOnTrackChange = setting("trackNotifications", true) !== false;

    }

    function pillText() {
        if (!radio)
            return "RP";

        var s = root.playing ? "■ " : "▶ ";
        return s + (root.stationTitle || "Radio Paradise");
    }

    moduleName: "io.github.pdfrg.rpbar"
    // Per-widget shell.json settings flow to the shared service.
    onRadioChanged: syncSettings()
    onSettingsChanged: syncSettings()
    visible: radio !== null
    implicitWidth: row.implicitWidth + Style.space(14)
    implicitHeight: barSize

    Row {
        id: row

        anchors.centerIn: parent
        spacing: Style.space(5)

        Text {
            id: glyph

            anchors.verticalCenter: parent.verticalCenter
            text: root.playing ? "󰏤" : "󰐊"
            color: root.playing ? Color.accent : (root.bar ? Qt.darker(root.bar.barForeground, 1.5) : "grey")
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.stationTitle || "Radio Paradise"
            textFormat: Text.PlainText
            color: root.bar ? root.bar.barForeground : "white"
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
        }

    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
            if (!root.radio)
                return ;

            if (mouse.button === Qt.LeftButton)
                root.radio.toggle();
            else
                root.popupOpen = !root.popupOpen;
        }
        onEntered: {
            if (root.bar)
                root.bar.showTooltip(root, root.stationTitle ? "Radio Paradise — " + root.stationTitle : "Radio Paradise");

        }
        onExited: {
            if (root.bar)
                root.bar.hideTooltip(root);

        }
    }

    PopupCard {
        id: popup

        anchorItem: root
        bar: root.bar
        owner: root
        open: root.popupOpen
        contentWidth: popup.fittedContentWidth(Style.space(340))
        contentHeight: popup.fittedContentHeight(column.implicitHeight)

        Column {
            id: column

            anchors.fill: parent
            spacing: Style.space(12)

            Text {
                text: "RADIO PARADISE"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
                font.bold: true
            }

            Text {
                text: root.radio && (root.radio.artist || root.radio.title) ? (root.radio.artist ? root.radio.artist + " — " + root.radio.title : root.radio.title) : "Press play to tune in"
                textFormat: Text.PlainText
                color: root.bar ? root.bar.foreground : "white"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
            }

            Repeater {
                model: Rp.stations()

                delegate: Rectangle {
                    required property var modelData
                    readonly property bool current: root.radio ? root.radio.station === modelData.chan : false

                    width: column.width
                    height: stationRow.implicitHeight + Style.space(8)
                    radius: Style.cornerRadius
                    color: current ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                    Row {
                        id: stationRow

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Style.space(6)
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)

                        Text {
                            text: current ? "󰏤" : "󰐊"
                            color: root.bar ? root.bar.foreground : "white"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: modelData.title
                            textFormat: Text.PlainText
                            color: root.bar ? root.bar.foreground : "white"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: current
                            anchors.verticalCenter: parent.verticalCenter
                        }

                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.radio)
                                root.radio.switchStation(modelData.chan);

                        }
                    }

                }

            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(8)

                Button {
                    iconText: root.playing ? "󰓛" : "󰐊"
                    text: root.playing ? "Stop" : "Play"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: {
                        if (root.radio)
                            root.radio.toggle();

                    }
                }

            }

        }

    }

}
