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
    // Stream stalled (cache wait) or idling after a drop until the
    // reconnect lands: pill dims, popup shows Buffering…, no toast.
    readonly property bool buffering: radio ? radio.buffering : false
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
    readonly property string buildId: "0.9.3"
    property bool popupOpen: false
    // Schedule sub-view (0.9.0): same-size swap of the popup content
    // (upcoming + current + history). Resets whenever the popup closes.
    property bool historyOpen: false

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

    onPopupOpenChanged: {
        if (!popupOpen)
            historyOpen = false;

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
            // (press to resume, cf. omarchy.media). A stall dims the
            // note but keeps it: the stream is conceptually still on.
            text: root.playing && !root.paused ? "󰝚" : "󰐊"
            color: root.playing && !root.paused && !root.buffering ? Color.accent : (root.bar ? Qt.darker(root.bar.barForeground, root.paused || root.buffering ? 2 : 1.5) : "grey")
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
        // Both views share this box: the history column is fixed-height
        // (6 rows), so swapping views never re-anchors the popup.
        contentHeight: popup.fittedContentHeight(Math.max(mainColumn.implicitHeight, histColumn.implicitHeight))

        Column {
            id: mainColumn

            anchors.fill: parent
            spacing: Style.space(12)
            visible: !root.historyOpen

            Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                    id: mainCaption

                    text: "RADIO PARADISE"
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 2
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    width: Math.max(0, parent.width - mainCaption.implicitWidth - histButton.width - parent.spacing * 2)
                    height: 1
                }

                // Schedule sub-view entry: upcoming + current + history
                // in the same-size box (no re-anchor glitch).
                Button {
                    id: histButton

                    iconText: "󰥔"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: {
                        if (root.radio)
                            root.radio.viewSchedule();

                        root.historyOpen = true;
                    }
                }

            }

            // Media-widget parity: Title / Artist / Album (Year).
            TrackRow {
                bar: root.bar
                radio: root.radio
                headline: root.buffering ? "Buffering…" : (root.radio && root.radio.title ? root.radio.title : (root.playing ? "Tuning in…" : "Press play to tune in"))
                artist: root.radio ? root.radio.artist : ""
                album: root.radio ? root.radio.album : ""
                year: root.radio ? root.radio.year : ""
                rating: root.radio ? root.radio.rating : ""
                coverFile: root.radio ? root.radio.coverFile : ""
                cover: root.radio ? root.radio.cover : ""
                artGate: root.popupOpen
                isCurrent: true
            }

            Repeater {
                model: Rp.stations()

                delegate: Rectangle {
                    required property var modelData
                    readonly property bool current: root.radio ? root.radio.station === modelData.chan : false

                    width: mainColumn.width
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

            Column {
                width: parent.width
                spacing: Style.space(6)

                Text {
                    text: "QUALITY"
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 2
                    font.bold: true
                }

                Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Repeater {
                        model: Rp.qualitiesFor(root.radio ? root.radio.station : 0)

                        delegate: Button {
                            required property var modelData
                            readonly property bool current: root.radio ? root.radio.quality === modelData.value : false

                            text: modelData.label
                            selected: current
                            foreground: root.bar.foreground
                            horizontalPadding: Style.spacing.controlPaddingX
                            verticalPadding: Style.spacing.controlPaddingY
                            onClicked: {
                                // Tapping the current quality is a no-op:
                                // re-selecting it would only restart the
                                // stream (setQuality guards this too).
                                if (root.radio && root.radio.quality !== modelData.value)
                                    root.radio.setQuality(modelData.value);

                            }
                        }

                    }

                }

                Text {
                    text: root.radio ? Rp.qualityNote(root.radio.station) : ""
                    textFormat: Text.PlainText
                    color: root.bar ? Qt.darker(root.bar.foreground, 2) : "grey"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                    visible: text !== ""
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

        // Schedule sub-view (0.9.0): upcoming (block, with "in X min"
        // cues) + current (accent edge bar) + history ("N min ago"),
        // all in the same TrackRow presentation. Fixed 6 rows total so
        // this column never exceeds the main column: the shared popup
        // box above never resizes on swap.
        Column {
            id: histColumn

            readonly property int upcomingCount: root.radio ? root.radio.upcomingItems.length : 0
            readonly property int historyCount: root.radio ? root.radio.historyItems.length : 0
            readonly property int historyShown: Math.max(0, Math.min(histColumn.historyCount, 5 - histColumn.upcomingCount))

            anchors.fill: parent
            spacing: Style.space(12)
            visible: root.historyOpen

            Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                    iconText: "󰅖"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.historyOpen = false
                }

                Text {
                    text: "SCHEDULE"
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 2
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                }

            }

            Text {
                text: "UP NEXT"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
                font.bold: true
                visible: histColumn.upcomingCount > 0
            }

            Repeater {
                model: root.radio ? root.radio.upcomingItems.slice(0, 3) : []

                delegate: TrackRow {
                    required property var modelData

                    bar: root.bar
                    radio: root.radio
                    headline: modelData.title || "—"
                    artist: modelData.artist
                    album: modelData.album
                    year: modelData.year
                    rating: modelData.rating
                    timeCue: Rp.formatIn(modelData.playTime, Date.now())
                    coverFile: modelData.coverFile
                    cover: modelData.cover
                    artGate: root.popupOpen
                }

            }

            Text {
                text: "NOW"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
                font.bold: true
            }

            TrackRow {
                bar: root.bar
                radio: root.radio
                headline: root.buffering ? "Buffering…" : (root.radio && root.radio.title ? root.radio.title : (root.playing ? "Tuning in…" : "Press play to tune in"))
                artist: root.radio ? root.radio.artist : ""
                album: root.radio ? root.radio.album : ""
                year: root.radio ? root.radio.year : ""
                rating: root.radio ? root.radio.rating : ""
                timeCue: root.playing ? "now playing" : ""
                coverFile: root.radio ? root.radio.coverFile : ""
                cover: root.radio ? root.radio.cover : ""
                artGate: root.popupOpen
                isCurrent: true
            }

            Text {
                text: "RECENTLY PLAYED"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
                font.bold: true
                visible: histColumn.historyShown > 0
            }

            Repeater {
                model: root.radio ? root.radio.historyItems.slice(0, histColumn.historyShown) : []

                delegate: TrackRow {
                    required property var modelData

                    bar: root.bar
                    radio: root.radio
                    headline: modelData.title || "—"
                    artist: modelData.artist
                    album: modelData.album
                    year: modelData.year
                    rating: modelData.rating
                    timeCue: Rp.formatAgo(modelData.playTime, modelData.duration, Date.now())
                    coverFile: modelData.coverFile
                    cover: modelData.cover
                    artGate: root.popupOpen
                }

            }

            Text {
                text: "No schedule yet — press play."
                textFormat: Text.PlainText
                color: root.bar ? Qt.darker(root.bar.foreground, 2) : "grey"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                visible: histColumn.upcomingCount === 0 && histColumn.historyCount === 0 && (!root.radio || root.radio.schedChan === -1)
            }

        }

    }

}
