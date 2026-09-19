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
    readonly property string buildId: "0.2.5"
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
    // Now-playing state. artist/title are stream-first (mpv IPC
    // icy-title, M2a); album/year/cover are API-second enrichment (M2b),
    // cleared whenever the stream announces a new track. streamKey is the
    // change gate; lastNotifyAt rate-floors track-change notifications.
    property string artist: ""
    property string title: ""
    property string album: ""
    property string year: ""
    property string cover: ""
    property string streamKey: ""
    property bool paused: false
    property double lastNotifyAt: 0
    // IDs for mpv's observe_property, referenced in both handleMpvMessage
    // and the IPC connect handler -- named constants so a future observed
    // property can't silently collide.
    readonly property int metadataObserveId: 1
    readonly property int pauseObserveId: 2
    readonly property string currentUrl: Rp.streamUrl(root.station, root.quality)
    readonly property string stationTitle: Rp.stationByChan(root.station).title
    // API-second enrichment (M2b): the stream carries identity only;
    // album/year/cover come from now_playing, polled while playing and
    // applied only when the API agrees with the stream's identity (a
    // mid-transition disagreement keeps last-good values, never blanks).
    readonly property string apiBase: "https://api.radioparadise.com/api"
    readonly property int apiPollInterval: 12000
    // Track-change notification: stream identity only (album/cover arrive
    // seconds later via enrichment). Fires while playing with the toggle
    // on, rate-floored so a flapping stream can't spam. Network strings
    // only ever travel as notify-send argv (never a shell string).
    readonly property int notifyFloorMs: 5000

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

        root.kickIpc();
    }

    function stop() {
        wantPlaying = false;
        ipcRetryTimer.stop();
        ipcSocket.connected = false;
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
        ipcSocket.connected = false;
        player.running = false;
        Qt.callLater(function() {
            player.running = true;
            root.kickIpc();
        });
    }

    // (Re)connect the IPC socket to a (re)started mpv: reset the retry
    // budget and let ipcRetryTimer do the attempts. Called on every path
    // that starts mpv (play, station switch, stream-drop restart).
    function kickIpc() {
        ipcRetryTimer.attempts = 0;
        ipcRetryTimer.restart();
    }

    // Stream-first metadata: mpv's `metadata` property carries the ICY
    // frame (`icy-title: "Artist - Title"`). Change-gated so transitional
    // states never flicker the UI; stale API enrichment is cleared and
    // re-filled by the M2b poll.
    function applyStreamTitle(raw) {
        var parts = Rp.splitArtistTitle(Rp.sanitizeText(raw, 256));
        var key = parts.artist + "\n" + parts.title;
        if (key === root.streamKey || (parts.artist === "" && parts.title === ""))
            return ;

        root.streamKey = key;
        root.artist = parts.artist;
        root.title = parts.title;
        root.album = "";
        root.year = "";
        root.cover = "";
        root.maybeNotify();
    }

    // Persisted notification preference (popup toggle). shell.json
    // `trackNotifications` remains the hard override: syncSettings in the
    // widget re-applies it in-memory whenever shell settings change.
    function setNotify(on) {
        root.notifyOnTrackChange = !!on;
        root.saveConfig({
            "notifyOnTrackChange": root.notifyOnTrackChange
        });
    }

    function maybeNotify() {
        if (!root.playing || !root.notifyOnTrackChange)
            return ;

        var now = Date.now();
        if (now - root.lastNotifyAt < root.notifyFloorMs)
            return ;

        root.lastNotifyAt = now;
        var summary = Rp.notifySafe(root.title || root.stationTitle, 128);
        var body = Rp.notifySafe(root.artist, 128);
        if (summary === "")
            return ;

        Quickshell.execDetached(["notify-send", "-a", "Radio Paradise", "-e", "--", summary, body]);
    }

    function handleMpvMessage(line) {
        // Guard against a message already in flight when the socket was
        // torn down (stop/switch flips connected synchronously first).
        if (!ipcSocket.connected)
            return ;

        var msg = null;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            return ;
        }
        if (!msg || msg.event !== "property-change")
            return ;

        if (msg.id === root.metadataObserveId && msg.data && typeof msg.data === "object") {
            // mpv sends the current value immediately on observe_property
            // registration and again on every change, so this seeds state
            // on connect and stays live after -- no get_property needed.
            if (typeof msg.data["icy-title"] === "string")
                root.applyStreamTitle(msg.data["icy-title"]);

        } else if (msg.id === root.pauseObserveId && typeof msg.data === "boolean") {
            // Stored for M3 (pill sync when media keys drive mpv); read-only
            // until the pause observer ships.
            root.paused = msg.data;
        }
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
            ipcSocket.connected = false;
            player.running = false;
            Qt.callLater(function() {
                player.running = true;
                root.kickIpc();
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

    function pollEnrichment() {
        if (!root.playing || apiProc.running)
            return ;

        apiProc.reqChan = root.station;
        apiProc.command = ["/usr/bin/curl", "-sS", "-L", "--max-time", "10", "-A", "rpbar/" + root.buildId, root.apiBase + "/now_playing?chan=" + root.station];
        apiProc.running = true;
    }

    function applyEnrichment(text, reqChan) {
        if (reqChan !== root.station || !root.playing)
            return ;

        var data = null;
        try {
            data = JSON.parse(String(text || ""));
        } catch (e) {
            return ;
        }
        var song = (data && data.song && typeof data.song === "object") ? data.song : null;
        // Live shape is flat ({artist,title,...} at top level); accept a
        // nested {song:{...}} too in case the API varies by channel.
        if (!song && data && typeof data === "object" && typeof data.artist === "string")
            song = data;

        if (!song)
            return ;

        var apiArtist = Rp.sanitizeText(song.artist, 128);
        var apiTitle = Rp.sanitizeText(song.title, 256);
        // Identity gate: enrichment must describe the track actually
        // playing. (now_playing has no song_id; the artist/title pair is
        // the identity. nowplaying_list_v2022 has song_id but costs a
        // heavier payload for no M2 benefit.)
        if (apiArtist !== root.artist || apiTitle !== root.title)
            return ;

        root.album = Rp.sanitizeText(song.album, 256);
        root.year = Rp.sanitizeText(song.year, 16);
        var cover = Rp.sanitizeText(song.cover_med || song.cover_small || song.cover, 2000);
        root.cover = Rp.isAllowedImageUrl(cover) ? cover : "";
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

        function nowPlaying() : string {
            return JSON.stringify({
                "station": root.station,
                "stationTitle": root.stationTitle,
                "artist": root.artist,
                "title": root.title,
                "album": root.album,
                "year": root.year,
                "cover": root.cover,
                "playing": root.playing,
                "paused": root.paused
            });
        }

        target: "io.github.pdfrg.rpbar"
    }

    // mpv owns the stream. --idle=yes keeps the instance warm across
    // transient restarts; --input-ipc-server is the JSON IPC control
    // plane (M2a observes metadata/pause; milestone 3 drives pause,
    // volume, loadfile back over it).
    Process {
        id: player

        command: ["mpv", "--no-video", "--no-terminal", "--idle=yes", "--input-ipc-server=" + root.socketPath, "--volume=" + root.volume, "--title=Radio Paradise", root.currentUrl]
        onExited: {
            if (root.switchingStation) {
                root.switchingStation = false;
                return ;
            }
            // The process behind the socket is gone: drop the connection
            // so in-flight messages can't land on the next instance's
            // state. restartTimer re-establishes both below.
            ipcSocket.connected = false;
            ipcRetryTimer.stop();
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
            if (root.wantPlaying && !player.running) {
                player.running = true;
                root.kickIpc();
            }
        }
    }

    // A stretch of stable playback earns a fresh reconnect budget.
    Timer {
        interval: 30000
        running: player.running
        onTriggered: root.restartAttempts = 0
    }

    // mpv JSON IPC over Quickshell's native Socket (no socat): stream
    // metadata arrives live via observe_property, and milestone 3 drives
    // pause/volume/loadfile back over the same connection.
    Socket {
        id: ipcSocket

        onConnectionStateChanged: {
            if (connected) {
                ipcRetryTimer.stop();
                // Registered once per connection; mpv replays the current
                // value immediately, then every future change.
                write(JSON.stringify({
                    "command": ["observe_property", root.metadataObserveId, "metadata"]
                }) + "\n");
                write(JSON.stringify({
                    "command": ["observe_property", root.pauseObserveId, "pause"]
                }) + "\n");
                flush();
            }
        }

        parser: SplitParser {
            splitMarker: "\n"
            onRead: function(data) {
                root.handleMpvMessage(data);
            }
        }

    }

    // mpv needs a moment after spawn before the socket file exists; retry
    // bounded (400ms x 20) per kickIpc so a dead mpv never spins forever.
    Timer {
        id: ipcRetryTimer

        property int attempts: 0

        interval: 400
        repeat: true
        onTriggered: {
            attempts += 1;
            if (ipcSocket.connected || attempts > 20) {
                stop();
                return ;
            }
            ipcSocket.path = root.socketPath;
            ipcSocket.connected = true;
        }
    }

    // Enrichment poll cadence: only while the stream is up. Single-flight
    // (pollEnrichment refuses while apiProc runs) so a slow API can never
    // stack requests.
    Timer {
        id: apiPollTimer

        interval: root.apiPollInterval
        running: root.wantPlaying && player.running
        repeat: true
        triggeredOnStart: true
        onTriggered: root.pollEnrichment()
    }

    Process {
        id: apiProc

        property int reqChan: -1

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyEnrichment(text, apiProc.reqChan)
        }

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
