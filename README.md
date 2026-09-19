# rpbar

Omarchy 4 (Quickshell) plugin for [Radio Paradise](https://radioparadise.com):
7 stations streamed via mpv, with MPRIS so the built-in media widget stays
in the loop.

Status: milestone 2 — live track metadata (stream + RP API), cover art,
track-change notifications, station popup switches.

## Install

```sh
./scripts/install.sh
```

This rsync-copies the plugin to `~/.config/omarchy/plugins/io.github.pdfrg.rpbar`
(never a symlink — inotify hot-reload does not traverse symlinks) and
restarts the shell. Re-run after every change with a bumped `buildId`.

## Use

- Left-click the pill: play / stop.
- Right-click the pill: popup with now-playing + cover, 7 stations,
  transport, and a track-notifications toggle (on by default).
- The stream answers to media keys via MPRIS (mpv-mpris autoloads).

Track info is stream-first (ICY title over mpv IPC) with album / year /
cover filled in from the RP API seconds later.

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
