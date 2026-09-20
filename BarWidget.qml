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
    readonly property string buildId: "0.10.4"
    property bool popupOpen: false
    // Summon shell (D2 stage 1): Bar.findPanelWidget requires open() +
    // close() functions and opened !== undefined on the widget root, then
    // `omarchy-shell shell summon|toggle|hide <id>` routes here on the
    // focused monitor's copy. Payloads never arrive via summon (shell
    // drops them for bar-widgets) — direct-play lives on the Service's
    // own IpcHandler target instead (playStation).
    readonly property bool opened: popupOpen
    property real wheelAccum: 0
    // Shared now-playing headline (B2/B3): stall vs retry-count vs
    // offline read differently at a glance instead of one "Buffering…".
    readonly property string statusHeadline: {
        if (root.buffering) {
            if (root.radio && root.radio.offline)
                return "Offline? — retrying…";

            if (root.radio && root.radio.restartAttempts > 0)
                return "Reconnecting " + root.radio.restartAttempts + "/5…";

            return "Buffering…";
        }
        if (root.radio && root.radio.title)
            return root.radio.title;

        return root.playing ? "Tuning in…" : "Press play to tune in";
    }
    // Tooltip gate (E): Bar.showTooltip aborts unless
    // target.tooltipHovered === true. The base BarWidget defines none,
    // so the target (root) must expose it from the pill MouseArea state.
    readonly property bool tooltipHovered: visible && opacity > 0 && pillMouse.containsMouse
    // Compact (media present) hides the track in the pill — carry it in
    // the tooltip instead. Full mode already shows it; tooltip stays
    // station-only there. A running sleep timer appends its countdown in
    // both modes (refreshed by the sleepNow tick while open).
    readonly property string tooltipText: {
        var st = root.stationTitle ? "Radio Paradise — " + root.stationTitle : "Radio Paradise";
        var tip = st;
        if (root.compact && root.radio && root.radio.title !== "")
            tip += "\n" + (root.radio.artist !== "" ? root.radio.artist + " - " + root.radio.title : root.radio.title);

        if (root.radio && root.radio.sleepAt > 0)
            tip += "\nSleep timer: " + Rp.sleepLabel(root.radio.sleepAt, Math.max(root.sleepNow, Date.now()));

        return tip;
    }
    // Sub-views (same-size swap of the popup content): schedule
    // (upcoming + current + history) and sleep timer. Only one open at
    // a time; both reset whenever the popup closes.
    property bool historyOpen: false
    property bool sleepOpen: false
    // Now-tick for the sleep countdown label: refreshed by sleepTick
    // below so an open sleep view counts down instead of going stale.
    property double sleepNow: 0

    function buildInfo() {
        return root.buildId;
    }

    function open() {
        root.historyOpen = false;
        root.sleepOpen = false;
        root.popupOpen = true;
    }

    function toggle() {
        root.popupOpen = !root.popupOpen;
        if (!root.popupOpen) {
            root.historyOpen = false;
            root.sleepOpen = false;
        }
    }

    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root, Number(direction) || 0);

        return false;
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
        if (!popupOpen) {
            historyOpen = false;
            sleepOpen = false;
        }
    }
    moduleName: "io.github.pdfrg.rpbar"
    // Per-widget shell.json settings flow to the shared service.
    onRadioChanged: syncSettings()
    onSettingsChanged: syncSettings()
    visible: radio !== null
    implicitWidth: row.implicitWidth + Style.space(14)
    implicitHeight: barSize

    // Sleep countdown freshness: nudge sleepNow (read by the sleep-view
    // label) while the popup is open and a timer runs. 30 s cadence —
    // minute-granularity display can't drift visibly.
    Timer {
        id: sleepTick

        interval: 30000
        repeat: true
        running: root.popupOpen && root.radio && root.radio.sleepAt > 0
        triggeredOnStart: true
        onTriggered: root.sleepNow = Date.now()
    }

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
            // A running sleep timer swaps the note for 󰒲 so it reads
            // without opening the popup; pause keeps its triangle (more
            // immediate state) and stop always cancels the timer anyway.
            text: root.playing && !root.paused ? (root.radio && root.radio.sleepAt > 0 ? "󰒲" : "󰝚") : "󰐊"
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
        id: pillMouse

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
        // Wheel = volume (D3): notched wheels step ±5 via the shared
        // Util.wheelSteps accumulator (touchpad fractions collapse to
        // 120-unit steps). Live IPC write, no respawn (A2).
        onWheel: function(wheel) {
            if (!root.radio || wheel.angleDelta.y === 0)
                return ;

            var w = Util.wheelSteps(root.wheelAccum, wheel.angleDelta.y);
            root.wheelAccum = w.remainder;
            if (w.steps === 0)
                return ;

            root.radio.setVolume(root.radio.volume + w.steps * 5);
        }
        onEntered: {
            if (root.bar && root.tooltipText !== "")
                root.bar.showTooltip(root, root.tooltipText);

        }
        onExited: {
            if (root.bar)
                root.bar.hideTooltip(root);

        }
    }

    // Keyboard-driven popup (D2 stage 2, single-file): KeyboardPanel is a
    // layer-shell PanelWindow with an Exclusive→OnDemand focus prime, so
    // SUPER+key summon lands with keys live — xdg-popup PopupCard never
    // gets focus without a click first. PanelKeyCatcher maps Esc (close),
    // Tab (hop to neighboring panel), 1-7 (station), m (mute),
    // Space/Enter (play/stop), arrows (station dial).
    KeyboardPanel {
        id: popup

        anchorItem: root
        bar: root.bar
        owner: root
        open: root.popupOpen
        focusTarget: keyCatcher
        contentWidth: popup.fittedContentWidth(Style.space(340))
        // All three views share this box: the schedule column is
        // fixed-height (7 rows: up to 3 upcoming + NOW + history fill)
        // and the sleep column is short static content, so swapping
        // views never re-anchors the popup.
        contentHeight: popup.fittedContentHeight(Math.max(mainColumn.implicitHeight, histColumn.implicitHeight, sleepColumn.implicitHeight))

        PanelKeyCatcher {
            id: keyCatcher

            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(direction) {
                root.switchPanel(direction);
            }
            onMoveRequested: function(dx, dy) {
                if (!root.radio || dy === 0)
                    return ;

                root.radio.stepStation(dy > 0 ? 1 : -1);
            }
            onActivateRequested: {
                if (root.radio)
                    root.radio.toggle();

            }
            onTextKey: function(text) {
                if (!root.radio)
                    return ;

                var n = Number(text);
                if (isFinite(n) && n >= 1 && n <= 7) {
                    var list = Rp.stations();
                    if (n - 1 < list.length)
                        root.radio.switchStation(list[n - 1].chan);

                } else if (text === "m" || text === "M") {
                    root.radio.toggleMute();
                }
            }

            Column {
                id: mainColumn

                anchors.fill: parent
                spacing: Style.space(12)
                visible: !root.historyOpen && !root.sleepOpen

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
                        width: Math.max(0, parent.width - mainCaption.implicitWidth - histButton.width - sleepButton.width - parent.spacing * 3)
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

                            root.sleepOpen = false;
                            root.historyOpen = true;
                        }
                    }

                    // Sleep timer sub-view entry. Highlighted while a
                    // timer runs so it reads without opening.
                    Button {
                        id: sleepButton

                        iconText: "󰒲"
                        selected: root.radio ? root.radio.sleepAt > 0 : false
                        foreground: root.bar.foreground
                        horizontalPadding: Style.spacing.controlPaddingX
                        verticalPadding: Style.spacing.controlPaddingY
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: {
                            root.historyOpen = false;
                            root.sleepOpen = true;
                        }
                    }

                }

                // Media-widget parity: Title / Artist / Album (Year).
                TrackRow {
                    bar: root.bar
                    radio: root.radio
                    headline: root.statusHeadline
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

                // Volume (A1): live IPC write, no respawn (A2). Right-click
                // the slider to mute. Past-100% fill warns like world-radio.
                Column {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                        text: "VOLUME"
                        color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 2
                        font.bold: true
                    }

                    Row {
                        width: parent.width
                        spacing: Style.space(8)

                        Button {
                            id: muteButton

                            iconText: root.radio && root.radio.muted ? "󰖁" : "󰕾"
                            foreground: root.bar.foreground
                            horizontalPadding: Style.spacing.controlPaddingX
                            verticalPadding: Style.spacing.controlPaddingY
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: {
                                if (root.radio)
                                    root.radio.toggleMute();

                            }
                        }

                        PanelSlider {
                            bar: root.bar
                            width: parent.width - muteButton.width - parent.spacing - volReadout.width - parent.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            value: root.radio ? root.radio.volume : 70
                            minimum: 0
                            maximum: 130
                            step: 1
                            integer: true
                            fillColor: value > 100 ? "#e05561" : (root.bar ? root.bar.foreground : Color.foreground)
                            onMoved: function(v) {
                                if (root.radio)
                                    root.radio.setVolume(v);

                            }
                            onRightClicked: {
                                if (root.radio)
                                    root.radio.toggleMute();

                            }
                        }

                        Text {
                            id: volReadout

                            text: root.radio ? (root.radio.muted ? "muted" : root.radio.volume + "%") : ""
                            textFormat: Text.PlainText
                            color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            anchors.verticalCenter: parent.verticalCenter
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

            // Schedule sub-view (0.9.0): upcoming (block, with "in X min"
            // cues) + current (accent edge bar) + history ("N min ago"),
            // all in the same TrackRow presentation. Fixed 7 rows total
            // (up to 3 upcoming + NOW + history fill) so this column never
            // exceeds the main column: the shared popup box above never
            // resizes on swap.
            Column {
                id: histColumn

                readonly property int upcomingCount: root.radio ? root.radio.upcomingItems.length : 0
                readonly property int historyCount: root.radio ? root.radio.historyItems.length : 0
                readonly property int historyShown: Math.max(0, Math.min(histColumn.historyCount, 6 - histColumn.upcomingCount))

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
                    headline: root.statusHeadline
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

            // Sleep timer sub-view (session-only): same box, short static
            // content so swapping views never re-anchors the popup.
            Column {
                id: sleepColumn

                anchors.fill: parent
                spacing: Style.space(12)
                visible: root.sleepOpen

                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Button {
                        iconText: "󰅖"
                        foreground: root.bar.foreground
                        horizontalPadding: Style.spacing.controlPaddingX
                        verticalPadding: Style.spacing.controlPaddingY
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.sleepOpen = false
                    }

                    Text {
                        text: "SLEEP TIMER"
                        color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "grey"
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 2
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }

                }

                Text {
                    text: {
                        var mins = root.radio ? Rp.sleepMins(root.radio.sleepAt, Math.max(root.sleepNow, Date.now())) : 0;
                        return mins > 0 ? "Stopping in " + mins + " min" : "Stop playback automatically after…";
                    }
                    textFormat: Text.PlainText
                    color: root.bar ? root.bar.foreground : "white"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                    width: parent.width
                }

                Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Repeater {
                        model: [{
                            "label": "Off",
                            "min": 0
                        }, {
                            "label": "15 min",
                            "min": 15
                        }, {
                            "label": "30 min",
                            "min": 30
                        }, {
                            "label": "60 min",
                            "min": 60
                        }]

                        delegate: Button {
                            required property var modelData
                            // Highlight the chosen duration (sleepMinutes),
                            // not the countdown — remaining time drifts but
                            // the choice doesn't.
                            readonly property bool current: {
                                if (modelData.min === 0)
                                    return !(root.radio && root.radio.sleepAt > 0);

                                return root.radio ? root.radio.sleepMinutes === modelData.min : false;
                            }

                            text: modelData.label
                            selected: current
                            foreground: root.bar.foreground
                            horizontalPadding: Style.spacing.controlPaddingX
                            verticalPadding: Style.spacing.controlPaddingY
                            onClicked: {
                                if (root.radio)
                                    root.radio.setSleep(modelData.min);

                            }
                        }

                    }

                }

                Text {
                    text: "Session-only: cancelled if you stop or switch stations, never saved."
                    textFormat: Text.PlainText
                    color: root.bar ? Qt.darker(root.bar.foreground, 2) : "grey"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    width: parent.width
                }

            }

        }

    }

}
