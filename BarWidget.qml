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
    readonly property bool paused: radio ? radio.paused : false
    // 3-state pill (P1): note = playing (status); dimmed triangle =
    // externally paused (matches omarchy.media); plain triangle = stopped.
    readonly property string stationTitle: radio ? radio.stationTitle : ""
    // Conditional pill: compact (station name only) when omarchy.media
    // shares this bar, full ("ABBR: Artist - Title") when it doesn't.
    // The rev/serial locals only exist to re-evaluate live when plugins
    // or the bar layout change; moduleWidgets() is per-bar, so this is
    // correct on multi-monitor setups.
    readonly property bool mediaOnBar: {
        var rev = bar && bar.shell && bar.shell.pluginRegistry ? bar.shell.pluginRegistry.registryRevision : 0;
        var serial = bar ? bar.barConfigSerial : 0;
        if (rev < -1 || serial < -1)
            return false;

        return bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets("omarchy.media").length > 0 : false;
    }
    readonly property bool compact: root.vertical || root.mediaOnBar
    readonly property string trackText: radio ? Rp.pillText(radio.station, radio.artist, radio.title) : ""
    readonly property bool scrollMode: radio ? radio.pillWidthMode !== "grow" : true
    readonly property int pillMaxWidth: radio ? radio.pillMaxWidth : 180
    readonly property string buildId: "0.5.0"
    property bool popupOpen: false

    function buildInfo() {
        return root.buildId;
    }

    function close() {
        popupOpen = false;
    }

    function syncSettings() {
        if (radio) {
            radio.notifyOnTrackChange = setting("trackNotifications", true) !== false;
            var mode = setting("pillWidthMode", radio.pillWidthMode);
            if (mode === "grow" || mode === "scroll")
                radio.pillWidthMode = mode;

            var maxW = Number(setting("pillMaxWidth", radio.pillMaxWidth));
            if (!isNaN(maxW))
                radio.pillMaxWidth = Math.max(80, Math.min(600, Math.round(maxW)));

        }
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
            // Note = playing (status indicator, cf. waybar mpris);
            // triangle = stopped (press to play) or paused-dimmed
            // (press to resume, cf. omarchy.media).
            text: root.playing && !root.paused ? "󰝚" : "󰐊"
            color: root.playing && !root.paused ? Color.accent : (root.bar ? Qt.darker(root.bar.barForeground, root.paused ? 2 : 1.5) : "grey")
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
        }

        Text {
            id: compactText

            anchors.verticalCenter: parent.verticalCenter
            visible: root.compact
            text: root.stationTitle || "Radio Paradise"
            textFormat: Text.PlainText
            color: root.bar ? root.bar.barForeground : "white"
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
        }

        // Full pill (no media on this bar): fixed max width in pixels
        // with marquee scroll, cloned from omarchy.media's scrollClip.
        Item {
            id: scrollClip

            width: Math.min(root.pillMaxWidth, fullLabel.implicitWidth)
            height: glyph.height
            clip: true
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.compact && root.scrollMode && !root.vertical && root.trackText !== ""

            Text {
                id: fullLabel

                property bool needsScroll: implicitWidth > scrollClip.width

                anchors.verticalCenter: parent.verticalCenter
                text: root.trackText
                textFormat: Text.PlainText
                color: root.bar ? root.bar.barForeground : "white"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body

                NumberAnimation on x {
                    running: fullLabel.needsScroll && !root.popupOpen && !root.vertical
                    loops: Animation.Infinite
                    duration: Math.max(6000, fullLabel.implicitWidth * 25)
                    from: scrollClip.width
                    to: -fullLabel.implicitWidth
                    easing.type: Easing.Linear
                }

            }

        }

        Text {
            id: growText

            anchors.verticalCenter: parent.verticalCenter
            visible: !root.compact && (!root.scrollMode || root.vertical)
            text: root.trackText || "Radio Paradise"
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

            Row {
                spacing: Style.space(10)
                width: parent.width

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
                        source: root.popupOpen ? (root.radio && (root.radio.coverFile || root.radio.cover) ? (root.radio.coverFile || root.radio.cover) : "") : (root.radio && root.radio.coverFile ? root.radio.coverFile : "")
                        visible: status === Image.Ready
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: artImage.status !== Image.Ready
                        text: "󰝚"
                        color: root.bar ? root.bar.foreground : "white"
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.displayLarge
                    }

                }

                Column {
                    spacing: Style.space(2)
                    width: parent.width - Style.space(74)
                    anchors.verticalCenter: parent.verticalCenter

                    // Media-widget parity: Title / Artist / Album (Year).
                    Text {
                        text: root.radio && root.radio.title ? root.radio.title : (root.playing ? "Tuning in…" : "Press play to tune in")
                        textFormat: Text.PlainText
                        color: root.bar ? root.bar.foreground : "white"
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        elide: Text.ElideRight
                        width: parent.width
                    }

                    Text {
                        text: root.radio ? root.radio.artist : ""
                        textFormat: Text.PlainText
                        color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : "grey"
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                        width: parent.width
                        visible: text !== ""
                    }

                    Row {
                        id: albumRow

                        spacing: Style.space(4)
                        width: parent.width
                        visible: root.radio && root.radio.album !== ""

                        Text {
                            text: root.radio ? root.radio.album : ""
                            textFormat: Text.PlainText
                            color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : "grey"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                            width: Math.max(0, albumRow.width - (yearText.visible ? yearText.implicitWidth + albumRow.spacing : 0))
                        }

                        Text {
                            id: yearText

                            text: root.radio && root.radio.year ? "(" + root.radio.year + ")" : ""
                            textFormat: Text.PlainText
                            color: root.bar ? Qt.darker(root.bar.foreground, 2) : "grey"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            visible: text !== ""
                        }

                    }

                }

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
                            // Note = now playing here (status marker, not
                            // an action); triangle = select this station.
                            text: current ? "󰝚" : "󰐊"
                            color: current ? Color.accent : (root.bar ? root.bar.foreground : "white")
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
                            // Clicking the current station is a no-op:
                            // re-selecting it would only restart the
                            // stream. Stop lives on the button below.
                            if (root.radio && root.radio.station !== modelData.chan)
                                root.radio.switchStation(modelData.chan);

                        }
                    }

                }

            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(8)

                // Station dial (P2): MPRIS prev/next are dead by nature
                // on a single-item stream playlist, so the skip
                // affordance lives here. Steps with wrap-around; live
                // switch while playing, select-only while stopped.
                Button {
                    iconText: "󰒮"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: {
                        if (root.radio)
                            root.radio.stepStation(-1);

                    }
                }

                Button {
                    iconText: root.playing && !root.paused ? "󰓛" : "󰐊"
                    text: root.playing ? (root.paused ? "Resume" : "Stop") : "Play"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: {
                        if (root.radio)
                            root.radio.toggle();

                    }
                }

                Button {
                    iconText: "󰒭"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: {
                        if (root.radio)
                            root.radio.stepStation(1);

                    }
                }

            }

            Toggle {
                width: parent.width
                label: "Track notifications"
                description: "Notify on every track change while playing."
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                checked: root.radio ? root.radio.notifyOnTrackChange : true
                onClicked: {
                    if (root.radio)
                        root.radio.setNotify(!root.radio.notifyOnTrackChange);

                }
            }

            Toggle {
                width: parent.width
                label: "Scroll long track text"
                description: "Off lets the pill grow wider instead. Applies when the media widget is not on the bar."
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                checked: root.scrollMode
                onClicked: {
                    if (root.radio)
                        root.radio.setPillWidthMode(root.scrollMode ? "grow" : "scroll");

                }
            }

        }

    }

}
