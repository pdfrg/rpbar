# SECURITY.md — rpbar capability and trust-boundary disclosure

rpbar (`io.github.pdfrg.rpbar`) is a Quickshell `service` + `bar-widget`
plugin. Like all Omarchy plugins it runs **unsandboxed inside the
long-running shell process with your user permissions**. This file lists
everything it can do, so reviewers and users don't have to take that on
faith.

## Subprocesses (all one-shot and argv-only, except mpv noted)

Every tool is invoked by **absolute path**, with arguments passed as an
argv array — never through a shell string — except the two `sh -c` glue
commands below, whose scripts are static text with paths supplied only
via environment variables. `curl` calls carry `--max-time`,
`--max-filesize`, `--fail`, and never follow redirects (no `-L`:
verified live, every RP endpoint answers directly, so a 3xx fails
closed). Metadata-bearing `Text` sinks render as `Text.PlainText`;
notification strings pass `notifySafe` (drops `<`, so no rich-text tag
can form).

| Tool | Purpose | Input shaping |
|---|---|---|
| `/usr/bin/mpv` | the one long-lived audio engine (`--no-video --idle=yes --input-ipc-server=…`), respawned on drops/station switches | stream URL is app-constructed from a hardcoded https base + a menu-validated quality (`Rp.streamUrl`/`qualityOrDefault`); `--volume=` from clamped config; `--title=` is a static string |
| `/usr/bin/curl` | `now_playing` enrichment poll (12 s, while playing), event-driven `/play` block + `nowplaying_list_v2022` history fetches, cover-art downloads into the art cache | URLs are app-constructed (fixed API base + numeric chan; covers allow-listed + digits-only id); `--max-filesize` 32768 (now_playing, ~0.3 KB live) / 262144 (block ~12–15 KB, list ~14–24 KB live) / 524288 (art) / 1048576 (large art); response text over 1 MiB is refused before `JSON.parse` (`maxApiText`) |
| `/usr/bin/notify-send` | track-change toasts (with cached art icon), "gave up reconnecting" + sleep-timer notices | static strings + `notifySafe`-sanitized metadata as argv; icon is always our own cache file, never a remote URL |
| `/usr/share/omarchy/bin/omarchy-launch-browser` | open this station's Radio Paradise player page from the cover | URL is app-constructed (`Rp.playerPageUrl`) and re-checked against `isAllowedLinkUrl` (https + `radioparadise.com/` only) before launch |
| `/usr/bin/xdg-open` | open the one-shot large (500px) cover in the image viewer | path is `<own-cache-dir>/rpbar-large-<digits>.jpg` (digits-only id); no-op unless the download exited 0 |
| `/usr/bin/mkdir -p` | create config / socket / art / large-art dirs at startup | paths derived from `$HOME` + fixed suffixes |
| `/usr/bin/cat` | existence probe for a cached cover; config re-read for merge-saves | paths are our own cache file / own config file only |
| `/usr/bin/sh -c` (static script, env-only paths) | startup orphan cleanup: kill only processes holding our socket path, unlink the stale socket | `SOCK` via environment, `PATH=/usr/bin:/bin`; the `pkill` pattern is a static string with the self-match bracket trick |
| `/usr/bin/sh -c` (static script, env-only paths) | trim the art cache to the newest 50 files | `ART_DIR` via environment, `PATH=/usr/bin:/bin`; only our own `<digits>.jpg` names can match |

No `sudo`, `pkexec`, `setcap`, package installs, or privilege escalation of
any kind. No compiler, downloader, or runtime dependency beyond the table.

## Network

- Only to Radio Paradise over https, and only three hosts:
  `stream.radioparadise.com` (audio, via mpv), `api.radioparadise.com`
  (track/schedule metadata), `img.radioparadise.com` (cover art).
  Remote images and links are allow-listed (`isAllowedImageUrl`,
  `isAllowedLinkUrl`) before any `Image.source` or browser use, and cover
  filenames are derived from a digits-only id (`coverId`), never from URL
  text.
- No login, no API keys, no credentials of any kind — there is nothing
  to leak into argv, URLs, or logs, so no credential broker is needed.
  Stream URLs handed to mpv are public and carry no auth material.
- No telemetry, no other hosts.

## Files read

- `~/.config/rpbar/config.json` — own config (station, quality, volume,
  notification + pill preferences). Re-read at shell start (external
  edits need `omarchy restart shell`); saves merge over a fresh disk
  read, never serialize in-memory state alone.
- `~/.config/omarchy/shell.json` — this widget's entry only, for the
  documented hard overrides (`trackNotifications`, `pillWidthMode`,
  `pillMaxWidth`). Read-only; the plugin never writes outside its own
  config.
- `~/.cache/rpbar/art/<digits>.jpg` — own cover cache (existence probe
  before display).

## Files written (all under `$HOME`, all documented with undo)

- `~/.config/rpbar/config.json` — preference saves, atomic merge write.
- `~/.cache/rpbar/art/` — cover thumbnails (newest 50 kept).
- `~/.cache/rpbar/large/` — one-shot large art for the image viewer.
- `$XDG_RUNTIME_DIR/mpv/rpbar-socket` — mpv JSON IPC socket (runtime only).
- Nothing under `/usr`, `/etc`, `~/.config/hypr/`, or
  `~/.config/omarchy/` is written by the plugin. (Keybinding lines are a
  manual user edit, not plugin code.)

**Removal:** `omarchy plugin remove io.github.pdfrg.rpbar`, then optionally
`rm -rf ~/.config/rpbar ~/.cache/rpbar` and drop the keybinding /
`shell.json` overrides. No services, timers, or packages are installed.

## Always-on behavior (`keepLoaded: true`)

- One `/usr/bin/mpv` child holds the stream while playing (stopped =
  no child, no network).
- A 12 s `now_playing` poll enriches metadata while playing only
  (single-flight; event-driven schedule fetches on top). Nothing polls
  while stopped.
- A 30 s stable-playback timer resets the reconnect budget; a 15 s
  sleep-timer tick runs only while a sleep timer is set.

## Known residuals (accepted, documented)

- State files go through Quickshell `FileView` / `cat`, which follow
  symlinks — no `O_NOFOLLOW` primitive exists in QML. Contents are
  treated as data: config values are type-checked, clamped, and
  menu-validated before use; API text is size-bounded and parsed as
  JSON, never executed.
- The large-art download targets a predictable cache path. It lives in
  our own cache dir (not shared `/tmp`), the filename is digits-only,
  and `curl --remove-on-error` deletes partial writes — but a
  same-user pre-placed symlink at that path would still be followed by
  `curl -o`, as would any same-user plant inside our own cache dirs.
  A same-user attacker already owns everything the plugin can touch;
  cross-user plants are impossible (dirs are home-private).
- `curl --max-filesize` is enforced against declared and received
  sizes, plus the 1 MiB parse-time refusal above it — belt and braces
  against a faulty server streaming without end.
- If Radio Paradise ever moves an endpoint behind a redirect, that
  fetch fails closed (offline indicator) instead of following, by
  design — no redirect is followed anywhere.
