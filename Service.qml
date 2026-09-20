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
    // MPRIS verdict (F5, probed live 2026-09-19, NOT implemented): the
    // 3-line split is impossible from our side. mpv 0.41 answers
    // `set_property metadata` with "error accessing property"
    // (read-only) and `set_property media-title` the same; only
    // `force-media-title` is writable, and that's still one line.
    // mpv-mpris (mpris.c) maps xesam:title <- media-title,
    // xesam:artist <- metadata/by-key/Artist|uploader, xesam:album <-
    // metadata/by-key/Album, and rebuilds Metadata only on
    // media-title/duration change. Art is doubly out: mpris:artUrl
    // comes from mpv `cover-art-files`, but mpv-mpris caches the art
    // URL per stream URL (cached_path), so per-track art would stick
    // on later tracks = track-art mismatch, worse than no art (user
    // rule). Result: omarchy.media keeps the ICY "Artist - Title"
    // one-liner (max info, no games); our popup + toast carry the
    // rich display. Re-probe if mpv/mpv-mpris change.

    id: root

    // Injected by omarchy-shell (the first-party service loader).
    property var shell: null
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + String(Quickshell.env("UID") || "1000"))
    readonly property string socketDir: runtimeDir + "/mpv"
    readonly property string socketPath: socketDir + "/rpbar-socket"
    readonly property string configDir: home + "/.config/rpbar"
    readonly property string configPath: configDir + "/config.json"
    readonly property string buildId: "0.9.3"
    // Playback state. wantPlaying is the intent (survives the stream-drop
    // restart backoff); playing reflects the live process.
    property bool wantPlaying: false
    readonly property bool playing: wantPlaying && player.running
    property int station: 0
    property string quality: Rp.defaultQuality()
    property int volume: 70
    property bool notifyOnTrackChange: true
    // Conditional-pill width behavior (no-media mode only): "scroll" keeps
    // a fixed max width and marquees; "grow" lets the pill widen with the
    // text. pillMaxWidth is pixels (media widget default: 180).
    property string pillWidthMode: "scroll"
    property int pillMaxWidth: 180
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
    // RP average user rating (0-10, display-ready via Rp.formatRating,
    // "" = hidden). Block-sourced only — the light poll carries no
    // rating field and must never clear a block-set value.
    property string rating: ""
    property string cover: ""
    property string streamKey: ""
    // When the current streamKey was set (ms epoch). The toast waits for
    // the block verdict for this track (see maybeToast): the block fetch
    // fires on every track change, so this is ~one fetch, not a poll.
    property double streamKeySetAt: 0
    property bool paused: false
    // True while mpv is stalled waiting for cache (transient) or idling
    // after a dead stream (until the reconnect lands). Drives the dimmed
    // pill / "Buffering…" popup state; never toasts on its own.
    property bool buffering: false
    property double lastNotifyAt: 0
    // IDs for mpv's observe_property, referenced in both handleMpvMessage
    // and the IPC connect handler -- named constants so a future observed
    // property can't silently collide.
    readonly property int metadataObserveId: 1
    readonly property int pauseObserveId: 2
    readonly property int pausedForCacheObserveId: 3
    readonly property int idleActiveObserveId: 4
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
    // Delayed rich toast (F6): one per track, fired when enrichment
    // completes (album/year/cover known) rather than at stream change.
    // lastToastKey stops the 12 s poll re-firing; the 5 s floor stops a
    // flapping stream spamming. Omarchy renders its own toasts and never
    // shows the -a app name, so "Radio Paradise" is the summary header.
    // Network strings travel as notify-send argv only (never a shell
    // string); the icon is our own cache file (never a remote URL).
    property string lastToastKey: ""
    // Toast grace (0.9.2): how long the single toast waits for the block
    // verdict before firing without the rating. Only reached when the
    // block fetch fails or hangs — normally the verdict lands in ~a fetch.
    readonly property int toastGraceMs: 15000
    // On-disk art cache (F1): ~/.cache/rpbar/art/<coverid>.jpg. Popup
    // reopens, notification icons, and the MPRIS art probe all read the
    // file -- instant and offline after the first fetch. Downloads are
    // bounded (15 s, 512 KB, allow-listed RP host only); the id comes
    // from Rp.coverId, never from raw URL text.
    readonly property string artDir: home + "/.cache/rpbar/art"
    readonly property int artCacheKeep: 50
    property string coverFile: ""
    // Schedule (0.9.0): upcoming from the /play block, history from
    // nowplaying_list_v2022. blockItems is the raw block (current +
    // upcoming, schedule order); upcomingItems is the splitSchedule view
    // (max 3); historyItems is past-only, current excluded (max 5).
    // Entries are Rp.scheduleEntry objects; coverFile is stamped in by
    // the art queue as downloads land (slice-reassign notifies views).
    property var blockItems: []
    property var upcomingItems: []
    property var historyItems: []
    property string schedBlockId: ""
    property int schedChan: -1
    property double blockFetchedAt: 0
    property double histFetchedAt: 0
    // Scheduled end of the last known block song (sched+duration, ms
    // epoch). Drives the block-gap refetch latch in pollEnrichment.
    property double blockEndMs: 0
    // Art pre-cache queue: cover ids (Rp.coverId strings), current
    // first, then upcoming, then history. artQueued dedupes within a
    // pass; the marker is cleared on completion so later fetches retry.
    property var artQueue: []
    property var artQueued: ({
    })

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
        root.paused = false;
        root.buffering = false;
        if (!player.running)
            player.running = true;

        root.kickIpc();
    }

    function stop() {
        wantPlaying = false;
        root.paused = false;
        root.buffering = false;
        ipcRetryTimer.stop();
        restartTimer.stop();
        ipcSocket.connected = false;
        player.running = false;
    }

    // wantPlaying = intent to have audio; paused = mpv actually holding
    // (usually via media keys / media widget, which drive mpv directly).
    // Toggle resumes a pause instead of stopping it.
    function toggle() {
        if (root.paused && root.wantPlaying)
            root.setPaused(false);
        else if (wantPlaying)
            stop();
        else
            play();
    }

    // M3 IPC write (pause IS runtime-writable, unlike metadata): the
    // resume path for external pauses. Fire-and-forget; the pause
    // observer confirms and corrects `paused` either way.
    function setPaused(on) {
        if (!ipcSocket.connected)
            return ;

        ipcSocket.write(JSON.stringify({
            "command": ["set_property", "pause", !!on]
        }) + "\n");
        ipcSocket.flush();
    }

    function switchStation(chan) {
        var st = Rp.stationByChan(chan);
        root.station = st.chan;
        root.paused = false;
        // A new station means a new schedule: drop the old block/history
        // (wrong-station data is worse than none) until the fetch lands.
        root.blockItems = [];
        root.upcomingItems = [];
        root.historyItems = [];
        root.schedBlockId = "";
        root.schedChan = -1;
        root.blockEndMs = 0;
        // The new station may not offer the current quality (e.g. aac-320
        // -> serenity): fall back to its default instead of failing.
        root.quality = Rp.qualityOrDefault(root.station, root.quality);
        root.saveConfig({
            "station": root.station,
            "quality": root.quality
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

    // Station dial (P2): prev/next station with wrap-around. Same
    // semantics as tapping a row: switches live while playing,
    // selects-only while stopped.
    function stepStation(delta) {
        root.switchStation(Rp.stepChan(root.station, Number(delta) || 0));
    }

    // Quality chooser: validated against the station menu (unknown values
    // fall back to the station default). Live switch while playing via
    // the same respawn path as a station switch; select-only while
    // stopped. Tapping the current quality is a no-op (avoids a pointless
    // stream restart).
    function setQuality(q) {
        var nq = Rp.qualityOrDefault(root.station, q);
        if (nq === root.quality)
            return ;

        root.quality = nq;
        root.paused = false;
        root.saveConfig({
            "quality": root.quality
        });
        if (!wantPlaying)
            return ;

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
    // that starts mpv (play, station switch, stream-drop restart). Also
    // refreshes the schedule (block + history + art URLs in one shot).
    function kickIpc() {
        ipcRetryTimer.attempts = 0;
        ipcRetryTimer.restart();
        root.fetchSchedule();
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
        root.streamKeySetAt = Date.now();
        root.artist = parts.artist;
        root.title = parts.title;
        root.album = "";
        root.year = "";
        root.rating = "";
        root.cover = "";
        root.coverFile = "";
        // Fast path: the new track may already be prefetched as upcoming
        // (with album/year/art from the block) — enrich + toast instantly
        // instead of waiting for the light poll. Then refresh the
        // schedule: the block position moved and history grew by one.
        root.applyBlockMatch();
        root.fetchSchedule();
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

    // Conditional-pill width preference (popup toggle). shell.json
    // `pillWidthMode` / `pillMaxWidth` remain the hard overrides, applied
    // in-memory by syncSettings in the widget.
    function setPillWidthMode(mode) {
        root.pillWidthMode = mode === "grow" ? "grow" : "scroll";
        root.saveConfig({
            "pillWidthMode": root.pillWidthMode
        });
    }

    function setPillMaxWidth(w) {
        var nv = Math.round(Number(w));
        if (isNaN(nv))
            return ;

        root.pillMaxWidth = Math.max(80, Math.min(600, nv));
        root.saveConfig({
            "pillMaxWidth": root.pillMaxWidth
        });
    }

    // Clickable album art: open this station's RP player page (now
    // playing, bio, lyrics, comments) in the default browser. The URL is
    // app-constructed and allow-listed; launched argv-only via
    // omarchy-launch-browser (correct app-scope + Hyprland focus), never
    // a shell string. Note: the web player may autoplay depending on the
    // browser's autoplay setting -- see README.
    function openPlayerPage() {
        var url = Rp.playerPageUrl(root.station);
        if (!Rp.isAllowedLinkUrl(url))
            return ;

        Quickshell.execDetached(["omarchy-launch-browser", url]);
    }

    function maybeToast() {
        if (!root.playing || !root.notifyOnTrackChange)
            return ;

        if (root.title === "" || root.lastToastKey === root.streamKey)
            return ;

        // Block verdict (0.9.2): two enrichment paths race here — the
        // light poll (no rating) and the block match (with rating). The
        // toast fires once per track, so it must wait until the block
        // fetch triggered by this track change has landed; otherwise a
        // light-poll win permanently drops the rating line. A dead/hung
        // block fetch falls back to a rating-less toast after the grace.
        var blockVerdict = root.schedChan === root.station && root.blockFetchedAt >= root.streamKeySetAt;
        if (!blockVerdict && Date.now() - root.streamKeySetAt < root.toastGraceMs)
            return ;

        // Cover expected but not cached yet: the download completion
        // re-enters here, so the single toast carries art. A track
        // change in between strands this (lastToastKey never set for
        // the old key) -- correct, the new track toasts instead.
        if (Rp.coverId(root.cover) !== "" && root.coverFile === "")
            return ;

        var now = Date.now();
        if (now - root.lastNotifyAt < root.notifyFloorMs)
            return ;

        root.lastNotifyAt = now;
        root.lastToastKey = root.streamKey;
        // Body lines via Rp.toastLines: at most 3 (omarchy's
        // NotificationCard elides past maximumLineCount 3), rating folded
        // into the last line so it is never the cut-off 4th.
        var lines = Rp.toastLines(root.title, root.artist, root.album, root.year, root.rating);
        var args = ["notify-send", "-a", "Radio Paradise", "-e", "--", "Radio Paradise", lines.join("\n")];
        if (root.coverFile !== "")
            args = ["notify-send", "-a", "Radio Paradise", "-e", "-i", root.coverFile.substring("file://".length), "--", "Radio Paradise", lines.join("\n")];

        Quickshell.execDetached(args);
    }

    // Dead-stream reconnect (end-file error/eof, process crash): single
    // owner of the restart budget. Paces attempts through restartTimer
    // (2.5 s) so a dead network can't spin; a permanently dead stream
    // still gives up with one "Gave up reconnecting" toast.
    function reconnectStream() {
        if (root.restartAttempts >= 5) {
            wantPlaying = false;
            root.buffering = false;
            Quickshell.execDetached(["notify-send", "-a", "Radio Paradise", "Stream dropped", "Gave up reconnecting -- press play to retry."]);
            return ;
        }
        root.restartAttempts++;
        restartTimer.restart();
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
        if (!msg || typeof msg !== "object")
            return ;

        // Dead-stream signal: with --idle=yes mpv does NOT exit on a
        // dropped stream -- it emits end-file and idles, so onExited
        // never fires. error/eof while we want audio means reconnect;
        // stop/quit/redirect are our own commands (or playlist
        // resolution) and anything while not wanting audio means ignore.
        if (msg.event === "end-file") {
            var reason = String(msg.reason || "");
            if ((reason === "error" || reason === "eof") && root.wantPlaying && !root.switchingStation)
                root.reconnectStream();

            return ;
        }
        if (msg.event !== "property-change")
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
        } else if (msg.id === root.pausedForCacheObserveId && typeof msg.data === "boolean") {
            // Transient stall: wait, never reconnect. Clears itself when
            // the buffer refills; mpv's own network-timeout (60 s) raises
            // end-file first if the stall is really a dead stream.
            root.buffering = msg.data;
        } else if (msg.id === root.idleActiveObserveId && typeof msg.data === "boolean") {
            // Corroborating latch only (nothing loaded post-end-file):
            // a loaded file means the reconnect landed, so clear.
            if (!msg.data)
                root.buffering = false;

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
            root.quality = Rp.qualityOrDefault(root.station, obj.quality);

        if (typeof obj.volume === "number")
            root.volume = Math.max(0, Math.min(130, Math.round(obj.volume)));

        if (typeof obj.notifyOnTrackChange === "boolean")
            root.notifyOnTrackChange = obj.notifyOnTrackChange;

        if (obj.pillWidthMode === "grow" || obj.pillWidthMode === "scroll")
            root.pillWidthMode = obj.pillWidthMode;

        if (typeof obj.pillMaxWidth === "number")
            root.pillMaxWidth = Math.max(80, Math.min(600, Math.round(obj.pillMaxWidth)));

        root.pluginConfigLoaded = true;
    }

    function pollEnrichment() {
        if (!root.playing || apiProc.running)
            return ;

        apiProc.reqChan = root.station;
        apiProc.command = ["/usr/bin/curl", "-sS", "-L", "--max-time", "10", "-A", "rpbar/" + root.buildId, root.apiBase + "/now_playing?chan=" + root.station];
        apiProc.running = true;
        // Block-gap latch (rptui pattern): while the stream sits on the
        // last known block song — or past its scheduled end — the next
        // block may have been released, so refetch it and keep upcoming
        // live. Scoped to the gap window; quiet the rest of the time.
        if (!blockProc.running && root.schedChan === root.station && root.blockItems.length > 0 && root.streamKey !== "") {
            var last = root.blockItems[root.blockItems.length - 1];
            if (Rp.entryKey(last) === root.streamKey || (root.blockEndMs > 0 && Date.now() > root.blockEndMs - 90000))
                root.blockRefetch();

        }
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
        root.fetchCoverFile();
        // Album arrived: toast now if no art is expected, else when
        // the cover download completes (maybeToast gates both).
        root.maybeToast();
    }

    function coverFileFor(id) {
        return id === "" ? "" : root.artDir + "/" + id + ".jpg";
    }

    // Schedule fetch (0.9.0): the /play block (current + upcoming with
    // sched_time_millis, ~10KB, no auth) and nowplaying_list_v2022
    // (20-song history, ~24KB). Event-driven only — never on a timer —
    // so a bar widget can't become a poll loop. bitrate=3 is rptui's
    // default; the audio URLs are ignored (we stream), only metadata.
    function fetchSchedule() {
        root.blockRefetch();
        if (!listProc.running) {
            listProc.reqChan = root.station;
            listProc.command = ["/usr/bin/curl", "-sS", "-L", "--max-time", "10", "-A", "rpbar/" + root.buildId, root.apiBase + "/nowplaying_list_v2022?chan=" + root.station];
            listProc.running = true;
        }
    }

    function blockRefetch() {
        if (blockProc.running)
            return ;

        blockProc.reqChan = root.station;
        blockProc.command = ["/usr/bin/curl", "-sS", "-L", "--max-time", "10", "-A", "rpbar/" + root.buildId, root.apiBase + "/play?event=0&elapsed=1&bitrate=3&action=start&info=true&chan=" + root.station];
        blockProc.running = true;
    }

    // Popup entry point: refresh only when stale or foreign-station.
    function viewSchedule() {
        var now = Date.now();
        if (root.schedChan !== root.station || now - root.blockFetchedAt > 60000 || now - root.histFetchedAt > 60000)
            root.fetchSchedule();

    }

    function applyBlock(text, reqChan) {
        if (reqChan !== root.station)
            return ;

        var res = Rp.parseBlock(text);
        if (res.items.length === 0)
            return ;

        root.blockItems = res.items;
        root.schedBlockId = res.blockId;
        root.schedChan = reqChan;
        root.blockFetchedAt = Date.now();
        var last = res.items[res.items.length - 1];
        root.blockEndMs = last.playTime > 0 ? last.playTime + (last.duration > 0 ? last.duration : 240000) : 0;
        root.upcomingItems = Rp.splitSchedule(res.items, root.streamKey, Date.now(), 3);
        // The new block may already describe the playing track (or the
        // track that just announced) — enrich from it immediately.
        root.applyBlockMatch();
        root.queueArtForSchedule();
    }

    // Enrich the current track from the prefetched block when the block
    // agrees with the stream identity. Same gate semantics as the light
    // poll (identity match or nothing); idempotent, so the light poll
    // landing later changes nothing. Returns true on a match.
    function applyBlockMatch() {
        if (root.streamKey === "" || root.schedChan !== root.station)
            return false;

        for (var i = 0; i < root.blockItems.length; i++) {
            var it = root.blockItems[i];
            if (Rp.entryKey(it) === root.streamKey) {
                root.album = it.album;
                root.year = it.year;
                root.rating = it.rating;
                if (it.cover !== "")
                    root.cover = it.cover;

                root.fetchCoverFile();
                root.maybeToast();
                return true;
            }
        }
        return false;
    }

    function applyHistory(text, reqChan) {
        if (reqChan !== root.station)
            return ;

        root.historyItems = Rp.parsePlaylist(text, root.streamKey, 5);
        root.histFetchedAt = Date.now();
        root.queueArtForSchedule();
    }

    function fetchCoverFile() {
        if (Rp.coverId(root.cover) === "") {
            root.coverFile = "";
            return ;
        }
        // Already resolved: nothing to do (avoids re-queueing every
        // 12 s poll for the current track).
        if (root.coverFile === root.coverFileFor(Rp.coverId(root.cover)))
            return ;

        // Current track jumps the queue; the pump serializes the rest.
        root.queueArt(root.cover, true);
    }

    // Enqueue one cover URL (front = current track priority). Dupes
    // within a pass are dropped via artQueued; the marker clears on
    // completion so later schedule fetches can retry failed downloads.
    // Queue items keep their own URL: cover sizes (s/m/l) share a cache
    // id but are different downloads.
    function queueArt(url, front) {
        var id = Rp.coverId(url);
        if (id === "" || root.artQueued[id])
            return ;

        root.artQueued[id] = true;
        if (front)
            root.artQueue.unshift({
            "id": id,
            "url": String(url)
        });
        else
            root.artQueue.push({
            "id": id,
            "url": String(url)
        });
        root.pumpArtQueue();
    }

    // Pre-cache art for the visible schedule, priority-ordered: current,
    // then upcoming in play order, then history. Cached files resolve
    // instantly through the existence probe; misses download bounded.
    function queueArtForSchedule() {
        root.queueArt(root.cover, true);
        for (var u = 0; u < root.upcomingItems.length; u++) {
            if (root.upcomingItems[u].coverFile === "")
                root.queueArt(root.upcomingItems[u].cover, false);

        }
        for (var h = 0; h < root.historyItems.length; h++) {
            if (root.historyItems[h].coverFile === "")
                root.queueArt(root.historyItems[h].cover, false);

        }
    }

    function pumpArtQueue() {
        if (artCheckProc.running || artDlProc.running)
            return ;

        if (root.artQueue.length === 0)
            return ;

        var head = root.artQueue.shift();
        artCheckProc.wantId = head.id;
        artCheckProc.wantPath = root.coverFileFor(head.id);
        artCheckProc.wantUrl = head.url;
        artCheckProc.command = ["/bin/cat", artCheckProc.wantPath];
        artCheckProc.running = true;
    }

    // Stamp a landed cover file onto every holder (current + schedule)
    // and nudge the views. Stale completions (id no longer referenced)
    // change nothing.
    function stampArt(id, fileUrl) {
        var touched = false;
        if (Rp.coverId(root.cover) === id && root.coverFile !== fileUrl) {
            root.coverFile = fileUrl;
            // Current-track art landed after enrichment: the deferred
            // toast fires now (with art), and the popup picks it up live.
            root.maybeToast();
            touched = true;
        }
        for (var b = 0; b < root.blockItems.length; b++) {
            if (Rp.coverId(root.blockItems[b].cover) === id && root.blockItems[b].coverFile !== fileUrl) {
                root.blockItems[b].coverFile = fileUrl;
                touched = true;
            }
        }
        for (var h = 0; h < root.historyItems.length; h++) {
            if (Rp.coverId(root.historyItems[h].cover) === id && root.historyItems[h].coverFile !== fileUrl) {
                root.historyItems[h].coverFile = fileUrl;
                touched = true;
            }
        }
        // upcomingItems aliases blockItems entries; reassigning both
        // arrays notifies the Repeaters (fresh delegates, cached images).
        if (touched) {
            root.upcomingItems = root.upcomingItems.slice();
            root.historyItems = root.historyItems.slice();
        }
    }

    function onArtCheckDone(exitOk, wantPath, wantId, wantUrl) {
        // wantId/path/url were paired at pump time. A stale completion
        // (e.g. station switched mid-flight) simply matches no holder in
        // stampArt and changes nothing.
        if (exitOk) {
            delete root.artQueued[wantId];
            root.stampArt(wantId, "file://" + wantPath);
            root.pumpArtQueue();
            return ;
        }
        // Cache miss: bounded download of the queued URL (never a fresh
        // property read — the schedule may have moved on). The queued
        // marker stays until the download completes, so the id can't be
        // enqueued twice concurrently.
        artDlProc.wantId = wantId;
        artDlProc.wantPath = wantPath;
        artDlProc.command = ["/usr/bin/curl", "-sS", "-L", "--fail", "--remove-on-error", "--max-time", "15", "--max-filesize", "524288", "-A", "rpbar/" + root.buildId, "-o", wantPath, String(wantUrl)];
        artDlProc.running = true;
    }

    function onArtDownloaded(exitOk, wantPath, wantId) {
        delete root.artQueued[wantId];
        if (exitOk)
            root.stampArt(wantId, "file://" + wantPath);

        // Trim to the newest artCacheKeep files. Names are our own
        // <digits>.jpg writes, so the pipeline can't escape the dir.
        artTrimProc.command = ["/usr/bin/sh", "-c", "cd \"$ART_DIR\" 2>/dev/null && /bin/ls -t *.jpg 2>/dev/null | /usr/bin/tail -n +51 | /usr/bin/xargs -r /usr/bin/rm --"];
        artTrimProc.environment = {
            "ART_DIR": root.artDir,
            "PATH": "/usr/bin:/bin"
        };
        artTrimProc.running = true;
        root.pumpArtQueue();
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

        function stepStation(delta: string) : string {
            root.stepStation(Number(delta));
            return "ok";
        }

        function setQuality(quality: string) : string {
            root.setQuality(quality);
            return root.quality;
        }

        function nowPlaying() : string {
            return JSON.stringify({
                "station": root.station,
                "stationTitle": root.stationTitle,
                "quality": root.quality,
                "artist": root.artist,
                "title": root.title,
                "album": root.album,
                "year": root.year,
                "rating": root.rating,
                "cover": root.cover,
                "coverFile": root.coverFile,
                "playing": root.playing,
                "paused": root.paused,
                "buffering": root.buffering,
                "pillWidthMode": root.pillWidthMode,
                "pillMaxWidth": root.pillMaxWidth
            });
        }

        // Schedule plane (0.9.0): current block id + upcoming/history
        // entries for popup verification without clicking.
        function schedule() : string {
            return JSON.stringify({
                "station": root.station,
                "blockId": root.schedBlockId,
                "streamKey": root.streamKey,
                "upcoming": root.upcomingItems,
                "history": root.historyItems
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
            // state. reconnectStream paces and budgets the recovery.
            ipcSocket.connected = false;
            ipcRetryTimer.stop();
            if (!root.wantPlaying)
                return ;

            root.reconnectStream();
        }
    }

    Timer {
        id: restartTimer

        interval: 2500
        onTriggered: {
            if (!root.wantPlaying)
                return ;

            if (!player.running) {
                player.running = true;
                root.kickIpc();
            } else if (ipcSocket.connected) {
                // Warm idle instance after end-file: reload in place, no
                // respawn, MPRIS registration survives.
                ipcSocket.write(JSON.stringify({
                    "command": ["loadfile", root.currentUrl, "replace"]
                }) + "\n");
                ipcSocket.flush();
            } else {
                // Socket dead but the process lives (orphan): respawn it.
                root.switchingStation = true;
                player.running = false;
                Qt.callLater(function() {
                    player.running = true;
                    root.kickIpc();
                });
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
                write(JSON.stringify({
                    "command": ["observe_property", root.pausedForCacheObserveId, "paused-for-cache"]
                }) + "\n");
                write(JSON.stringify({
                    "command": ["observe_property", root.idleActiveObserveId, "idle-active"]
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

    // Schedule workers (0.9.0): block = current + upcoming, list =
    // history. Single-flight each via fetchSchedule's running guards; a
    // stale completion whose chan no longer matches is dropped.
    Process {
        id: blockProc

        property int reqChan: -1

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyBlock(text, blockProc.reqChan)
        }

    }

    Process {
        id: listProc

        property int reqChan: -1

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyHistory(text, listProc.reqChan)
        }

    }

    // Art-cache workers (see queueArt/pumpArtQueue). Serialized through
    // the queue: one check/download at a time, never killed mid-flight
    // (that would leave a partial file). A stale completion whose id no
    // longer matches any holder is dropped, never applied.
    Process {
        id: artCheckProc

        property string wantId: ""
        property string wantPath: ""
        property string wantUrl: ""

        onExited: function(exitCode, exitStatus) {
            root.onArtCheckDone(exitCode === 0, artCheckProc.wantPath, artCheckProc.wantId, artCheckProc.wantUrl);
        }
    }

    Process {
        id: artDlProc

        property string wantId: ""
        property string wantPath: ""

        onExited: function(exitCode, exitStatus) {
            root.onArtDownloaded(exitCode === 0, artDlProc.wantPath, artDlProc.wantId);
        }
    }

    Process {
        id: artTrimProc
    }

    Process {
        id: dirSetup

        command: ["/usr/bin/mkdir", "-p", root.configDir, root.socketDir, root.artDir]
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
