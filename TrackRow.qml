import QtQuick
import Quickshell
import qs.Commons

// Shared now-playing / schedule row (0.9.0): 64px art + Title / Artist /
// Album (Year · ★ rating · time-cue). Fixed 64px height so the history
// sub-view never resizes the popup. artGate (popup-open) keeps closed
// popups fetch-free; isCurrent draws the accent edge bar marking the
// playing track.
Item {
    id: row

    required property var bar
    property string headline: ""
    property string artist: ""
    property string album: ""
    property string year: ""
    property string rating: ""
    property string timeCue: ""
    property string coverFile: ""
    property string cover: ""
    property bool artGate: true
    property bool isCurrent: false
    property var radio: null

    width: parent ? parent.width : 0
    implicitHeight: Style.space(64)

    Row {
        anchors.fill: parent
        spacing: Style.space(10)

        Item {
            width: Style.space(64)
            height: Style.space(64)
            clip: true

            Image {
                id: artImage

                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                // Cached file first (instant reopen, offline);
                // remote while the first fetch lands. Gated on
                // popup-open so a closed popup never fetches.
                sourceSize.width: Style.space(128)
                sourceSize.height: Style.space(128)
                source: row.artGate ? (row.coverFile || row.cover ? (row.coverFile || row.cover) : "") : (row.coverFile ? row.coverFile : "")
                visible: status === Image.Ready
            }

            Text {
                anchors.centerIn: parent
                visible: artImage.status !== Image.Ready
                text: "󰝚"
                color: row.bar ? row.bar.foreground : "white"
                font.family: row.bar ? row.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.displayLarge
            }

            // Current-track marker: accent edge bar (no metric change,
            // so row heights stay uniform across the schedule view).
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Math.max(2, Style.space(3))
                color: Color.accent
                visible: row.isCurrent
            }

            // Clickable cover: left opens this station's RP player page
            // (now playing, bio, lyrics, comments); right opens the large
            // (500px) art in the image viewer (C5, /tmp one-shot, never
            // the bar/toast cache file). Works on the placeholder too --
            // the station page needs no track (large art needs a cover).
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                    if (!row.radio)
                        return ;

                    if (mouse.button === Qt.RightButton)
                        row.radio.openLargeArtFor(row.cover);
                    else
                        row.radio.openPlayerPage();
                }
            }

        }

        Column {
            spacing: Style.space(2)
            width: parent.width - Style.space(74)
            anchors.verticalCenter: parent.verticalCenter

            Text {
                text: row.headline
                textFormat: Text.PlainText
                color: row.bar ? row.bar.foreground : "white"
                font.family: row.bar ? row.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
            }

            Text {
                text: row.artist
                textFormat: Text.PlainText
                color: row.bar ? Qt.darker(row.bar.foreground, 1.3) : "grey"
                font.family: row.bar ? row.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: parent.width
                visible: text !== ""
            }

            Row {
                id: albumRow

                spacing: Style.space(4)
                width: parent.width
                visible: row.album !== "" || row.rating !== "" || row.timeCue !== ""

                Text {
                    text: row.album
                    textFormat: Text.PlainText
                    color: row.bar ? Qt.darker(row.bar.foreground, 1.6) : "grey"
                    font.family: row.bar ? row.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: Math.max(0, albumRow.width - (yearText.visible ? yearText.implicitWidth + albumRow.spacing : 0) - (ratingText.visible ? ratingText.implicitWidth + albumRow.spacing : 0) - (cueText.visible ? cueText.implicitWidth + albumRow.spacing : 0))
                    visible: text !== ""
                }

                Text {
                    id: yearText

                    text: row.year ? "(" + row.year + ")" : ""
                    textFormat: Text.PlainText
                    color: row.bar ? Qt.darker(row.bar.foreground, 2) : "grey"
                    font.family: row.bar ? row.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    visible: text !== ""
                }

                // Average RP user rating (0-10 scale), hidden when the
                // payloads carry none.
                Text {
                    id: ratingText

                    text: row.rating ? "★ " + row.rating : ""
                    textFormat: Text.PlainText
                    color: Color.accent
                    font.family: row.bar ? row.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    visible: text !== ""
                }

                Text {
                    id: cueText

                    text: row.timeCue ? "· " + row.timeCue : ""
                    textFormat: Text.PlainText
                    color: Color.accent
                    font.family: row.bar ? row.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    visible: text !== ""
                }

            }

        }

    }

}
