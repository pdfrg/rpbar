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
- Right-click the pill: popup with now-playing (Title / Artist /
  Album (Year)) + cover, 7 stations, transport with prev/next-station
  dial, and a track-notifications toggle (on by default). Clicking
  the current station does nothing; Stop is the stop path.
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
  "notifyOnTrackChange": true
}
```

After hand-editing, run `omarchy restart shell` (reopening the popup is
not enough — `FileView.watchChanges` quirk).

To force notifications off regardless of the popup toggle, add
`"trackNotifications": false` to this widget's entry in
`~/.config/omarchy/shell.json`.

## Develop

```sh
./check
./scripts/install.sh
omarchy-shell io.github.pdfrg.rpbar buildInfo
```

(`shell call <id> ...` only routes to panel/overlay/menu loaders — this
plugin is service + bar-widget, so it exposes its own `IpcHandler` target
instead, with `play` / `stop` / `toggle` / `switchStation <chan>` too.)
