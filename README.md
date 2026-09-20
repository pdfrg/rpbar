# rpbar

Omarchy 4 (Quickshell) plugin for [Radio Paradise](https://radioparadise.com):
7 stations streamed via mpv, with MPRIS so the built-in media widget stays
in the loop.

Status: track metadata (stream + RP API), cached cover art, rich
track-change notifications, 3-line popup.

## Install

```sh
./scripts/install.sh
```

This rsync-copies the plugin to `~/.config/omarchy/plugins/io.github.pdfrg.rpbar`
(never a symlink — inotify hot-reload does not traverse symlinks) and
restarts the shell. Re-run after every change with a bumped `buildId`.

## Use

- Left-click the pill: play / stop (note glyph = playing). Pausing
  via media keys / the media widget shows a dimmed triangle; clicking
  it resumes.
- Dropped streams reconnect on their own (up to 5 tries, then one
  "Gave up reconnecting" toast): the pill dims and the popup shows
  "Buffering…" while stalled. Stopping during a stall stays stopped.
- The pill adapts to the built-in media widget: when `omarchy.media`
  shares the bar, the pill stays compact (station name only — the
  media widget already shows `Artist - Title`). When media is absent,
  the pill shows the track itself (`MM: Artist - Title`, with
  per-station abbreviations MM/ML/R/G/B/S/K). Detection is per-bar
  and switches live when the bar layout changes.
- Right-click the pill: popup with now-playing (Title / Artist /
  Album (Year)) + cover, 7 stations, a quality row (AAC 128 / AAC 320 /
  MP3 192 / FLAC+; serenity offers 64k AAC and FLAC only), transport with prev/next-station
  dial, and a track-notifications toggle (on by default). Clicking
  the current station does nothing; Stop is the stop path. Clicking
  the cover opens the station's Radio Paradise page (now playing,
  bio, lyrics, comments) in the default browser — pause rpbar first
  if your browser autoplays the web player.
- The stream answers to media keys via MPRIS (mpv-mpris autoloads).
  Prev/next keys have no stream meaning (single-item playlist) and do
  nothing — use the popup dial to change stations.
  The media widget shows the ICY "Artist - Title" one-liner: mpv
  exposes metadata read-only, so the 3-line split is impossible
  from our side (verified against mpv-mpris source).

Track info is stream-first (ICY title over mpv IPC) with album / year /
cover filled in from the RP API seconds later. Covers cache to
`~/.cache/rpbar/art/` (kept to the newest 50) so popup reopens and
revisits are instant. Notifications fire once per track when
enrichment lands, with the cached art attached.

## Configure

`~/.config/rpbar/config.json` (created on first save):

```json
{
  "station": 0,
  "quality": "aac-128",
  "volume": 70,
  "notifyOnTrackChange": true,
  "pillWidthMode": "scroll",
  "pillMaxWidth": 180
}
```

`pillWidthMode` controls the track-showing pill (media absent):
`"scroll"` keeps a fixed `pillMaxWidth` (pixels, default 180, same as
the media widget) and marquees long text; `"grow"` lets the pill widen
with the text. Toggle it from the popup ("Scroll long track text").

After hand-editing, run `omarchy restart shell` (reopening the popup is
not enough — `FileView.watchChanges` quirk).

To force notifications off regardless of the popup toggle, add
`"trackNotifications": false` to this widget's entry in
`~/.config/omarchy/shell.json`. Same entry also accepts
`"pillWidthMode": "grow"` and `"pillMaxWidth": <pixels>` as hard
overrides for the track-pill width behavior.

## Develop

```sh
./check
./scripts/install.sh
omarchy-shell io.github.pdfrg.rpbar buildInfo
```

(`shell call <id> ...` only routes to panel/overlay/menu loaders — this
plugin is service + bar-widget, so it exposes its own `IpcHandler` target
instead, with `play` / `stop` / `toggle` / `switchStation <chan>` too.)
