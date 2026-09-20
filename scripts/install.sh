#!/bin/bash
# Install the plugin into the omarchy user plugin dir (real dir, not symlink:
# inotify hot-reload does not traverse symlinks), then restart the shell.
# rescanPlugins does NOT reload a running keepLoaded instance, so polling
# for the new buildId just burns 30 s -- restart unconditionally, wait for
# the shell to come back, and report what the live instance says.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DST="$HOME/.config/omarchy/plugins/io.github.pdfrg.rpbar"
/usr/bin/mkdir -p "$DST"

EXPECT=$(/usr/bin/grep -o 'buildId: "[^"]*"' "$SRC/Service.qml" | /usr/bin/head -1 | /usr/bin/cut -d'"' -f2)

# A reused buildId makes the check below vacuous (old code reporting
# the same id looks "reloaded"). Refuse unless the live shell reports
# something different -- bump buildId in Service.qml (and BarWidget.qml)
# for a new change.
# NOTE: verification goes through this plugin's own IpcHandler target
# (`omarchy-shell io.github.pdfrg.rpbar buildInfo`), NOT
# `omarchy-shell shell call ... buildInfo`: `shell call` only routes to
# panel/overlay/menu loaders, and this plugin is service + bar-widget,
# so that route always answers "unknown".
CALL="omarchy-shell io.github.pdfrg.rpbar buildInfo"
if [ -n "$EXPECT" ] && [ "${1:-}" != "--force" ]; then
  LIVE=$($CALL 2>/dev/null || true)
  if [ "$LIVE" = "$EXPECT" ]; then
    echo "build $EXPECT is already live -- bump buildId for a new change (--force to reinstall anyway)"
    exit 1
  fi
fi

CHANGES=$(/usr/bin/rsync -ai --delete \
  --exclude .git/ \
  --exclude scripts/ \
  --exclude PLAN.md \
  --exclude AGENTS.md \
  --exclude fixes.txt \
  --exclude initial-ideas.txt \
  --exclude project-outline.txt \
  "$SRC/" "$DST/" | /usr/bin/wc -l)

# Surface the restart result on mismatch: a lock-gated refusal (exit 1
# with "Refusing to restart ... while the session is locked") otherwise
# looks identical to a still-starting shell, which cost a debug session.
RESTART_MSG=$(omarchy restart shell 2>&1 || true)
/usr/bin/sleep 10
GOT=$($CALL 2>/dev/null || true)
if [ "$GOT" = "$EXPECT" ]; then
  echo "installed $SRC -> $DST ($CHANGES files, build $GOT live)"
  exit 0
fi
echo "installed $SRC -> $DST ($CHANGES files) -- shell reports '${GOT:-nothing}', expected $EXPECT (shell may still be starting; retry the buildInfo call)"
[ -n "$RESTART_MSG" ] && echo "restart said: $RESTART_MSG"
exit 1
