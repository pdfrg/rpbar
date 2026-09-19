// rpbar service: owns the single mpv playback process so bar widgets on
// every monitor share one stream. Milestone 1: play/stop + station switch
// (respawn); stream-first metadata, API enrichment, and IPC transport
// (pause/volume/loadfile) arrive in milestones 2-3.

import QtQuick
import Quickshell
import Quickshell.Io
import "RpLogic.js" as Rp

// MPRIS: mpv auto-loads the system mpv-mpris script for every plain
// instance -- NEVER pass --load-scripts=no (that opts out and would leave
// the media widget empty).
Item {
    id: root

    // Injected by omarchy-shell (the first-party service loader).
    property var shell: null
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + String(Quickshell.env("UID") || "1000"))
    readonly property string socketDir: runtimeDir + "/mpv"
    readonly property string socketPath: socketDir + "/rpbar-socket"
    readonly property string configDir: home + "/.config/rpbar"
    readonly property string configPath: configDir + "/config.json"
    readonly property string buildId: "0.1.2"
    // Playback state. wantPlaying is the intent (survives the stream-drop
    // restart backoff); playing reflects the live process.
    property bool wantPlaying: false
    readonly property bool playing: wantPlaying && player.running
    property int station: 0
    property string quality: Rp.defaultQuality()
    property int volume: 70
    property bool notifyOnTrackChange: true
    property bool pluginConfigLoaded: false
    property bool switchingStation: false
    property int restartAttempts: 0
    // Now-playing placeholders (stream-first metadata + API enrichment
    // land in milestone 2; the properties already exist so the pill and
    // popup can bind today).
    property string artist: ""
    property string title: ""
    property string album: ""
    property string year: ""
    property string cover: ""
    readonly property string currentUrl: Rp.streamUrl(root.station, root.quality)
    readonly property string stationTitle: Rp.stationByChan(root.station).title

    // IPC freshness probe: omarchy-shell io.github.pdfrg.rpbar buildInfo
    // (NOT `shell call ...`: that only routes to panel/overlay/menu
    // loaders, and this plugin is service + bar-widget, so it answers
    // "unknown" there. The IpcHandler below registers this target.)
    function buildInfo() {
        return root.buildId;
    }

    function play() {
        wantPlaying = true;
        restartAttempts = 0;
        if (!player.running)
            player.running = true;

    }

    function stop() {
        wantPlaying = false;
        player.running = false;
    }

    function toggle() {
        if (wantPlaying)
            stop();
        else
            play();
    }

    function switchStation(chan) {
        var st = Rp.stationByChan(chan);
        root.station = st.chan;
        root.saveConfig({
            "station": root.station
        });
        if (!wantPlaying)
            return ;

        // Killing the process is asynchronous: the old exit can land after
        // the new instance starts, so the guard below (not the restart
        // budget) owns that one exit.
        switchingStation = true;
        player.running = false;
        Qt.callLater(function() {
            player.running = true;
        });
    }

    function setVolume(v) {
        var nv = Math.max(0, Math.min(130, Math.round(v)));
        root.volume = nv;
        root.saveConfig({
            "volume": root.volume
        });
        // Pre-IPC (milestone 3): volume applies via the mpv command line,
        // so a live stream respawns to pick it up.
        if (wantPlaying && player.running) {
            switchingStation = true;
            player.running = false;
            Qt.callLater(function() {
                player.running = true;
            });
        }
    }

    // Config save merge (amla pattern): overlay only the dirty keys onto a
    // fresh disk read so hand edits and stale in-memory state are never
    // clobbered. A missing/unreadable file degrades to the dirty keys.
    function saveConfig(dirty) {
        if (!root.pluginConfigLoaded)
            return ;

        configSaveProc.pending = JSON.stringify(dirty || {
        });
        configSaveProc.command = ["/bin/cat", root.configPath];
        configSaveProc.running = true;
    }

    function applyConfigText(text) {
        var obj = {
        };
        try {
            obj = JSON.parse(String(text || "{}"));
        } catch (e) {
            obj = {
            };
        }
        if (typeof obj.station === "number" && Rp.stationByChan(obj.station).chan === obj.station)
            root.station = obj.station;

        if (typeof obj.quality === "string" && obj.quality.length > 0)
            root.quality = obj.quality;

        if (typeof obj.volume === "number")
            root.volume = Math.max(0, Math.min(130, Math.round(obj.volume)));

        if (typeof obj.notifyOnTrackChange === "boolean")
            root.notifyOnTrackChange = obj.notifyOnTrackChange;

        root.pluginConfigLoaded = true;
    }

    Component.onCompleted: {
        dirSetup.running = true;
    }

    // CLI control plane (verification + manual testing without clicking).
    IpcHandler {
        function buildInfo() : string {
            return root.buildId;
        }

        function play() : string {
            root.play();
            return "ok";
        }

        function stop() : string {
            root.stop();
            return "ok";
        }

        function toggle() : string {
            root.toggle();
            return "ok";
        }

        function switchStation(chan: string) : string {
            root.switchStation(Number(chan));
            return "ok";
        }

        target: "io.github.pdfrg.rpbar"
    }

    // mpv owns the stream. --idle=yes keeps the instance warm across
    // transient restarts; --input-ipc-server is the milestone-3 control
    // plane (pause/volume/loadfile over Quickshell Socket).
    Process {
        id: player

        command: ["mpv", "--no-video", "--no-terminal", "--idle=yes", "--input-ipc-server=" + root.socketPath, "--volume=" + root.volume, "--title=Radio Paradise", root.currentUrl]
        onExited: {
            if (root.switchingStation) {
                root.switchingStation = false;
                return ;
            }
            if (!root.wantPlaying)
                return ;

            if (root.restartAttempts >= 5) {
                root.wantPlaying = false;
                Quickshell.execDetached(["notify-send", "-a", "Radio Paradise", "Stream dropped", "Gave up reconnecting -- press play to retry."]);
                return ;
            }
            root.restartAttempts++;
            restartTimer.restart();
        }
    }

    Timer {
        id: restartTimer

        interval: 2500
        onTriggered: {
            if (root.wantPlaying && !player.running)
                player.running = true;

        }
    }

    // A stretch of stable playback earns a fresh reconnect budget.
    Timer {
        interval: 30000
        running: player.running
        onTriggered: root.restartAttempts = 0
    }

    Process {
        id: dirSetup

        command: ["/usr/bin/mkdir", "-p", root.configDir, root.socketDir]
        running: false
    }

    FileView {
        id: pluginConfigFile

        path: root.configPath
        watchChanges: false
        printErrors: false
        onLoaded: root.applyConfigText(text())
        onLoadFailed: root.pluginConfigLoaded = true
    }

    Process {
        id: configSaveProc

        property string pending: ""

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var disk = {
                };
                try {
                    disk = JSON.parse(String(text || ""));
                } catch (e) {
                }
                var dirty = {
                };
                try {
                    dirty = JSON.parse(configSaveProc.pending);
                } catch (e) {
                }
                for (var k in dirty) {
                    if (dirty[k] !== undefined)
                        disk[k] = dirty[k];

                }
                pluginConfigFile.setText(JSON.stringify(disk, null, 2) + "\n");
            }
        }

    }

}
