// RpLogic.js — pure Radio Paradise helpers (no Quickshell imports).
// Unit-testable with plain `node --check` / node test harnesses.
//
// v1 scope: 7 stations x 1 quality (default aac-128). The URL table below
// is ground truth from live HEAD probes (2026-09-19); the website player
// bundle confirms the aac/flac construction, per-channel option lists come
// from RP's CMS and are NOT hardcodable (see PLAN.md §1).

// Station catalog: chan numbers are the RP API ids (list_chan); titles
// are the API titles; streamName feeds the per-channel URL builder.
function stations() {
  return [
    { chan: 0, slug: "main-mix", streamName: "main-mix", title: "The Main Mix" },
    { chan: 1, slug: "mellow", streamName: "mellow", title: "Mellow Mix" },
    { chan: 2, slug: "rock", streamName: "rock", title: "RockIt!" },
    { chan: 3, slug: "global", streamName: "global", title: "The Globe" },
    { chan: 5, slug: "beyond", streamName: "beyond", title: "Beyond..." },
    { chan: 42, slug: "serenity", streamName: "serenity", title: "Serenity" },
    { chan: 945, slug: "kfat", streamName: "kfat", title: "KFAT" }
  ]
}

function stationByChan(chan) {
  var list = stations()
  for (var i = 0; i < list.length; i++) {
    if (list[i].chan === chan) return list[i]
  }
  return list[0]
}

// Tuning-dial step: index of chan, moved by delta with wrap-around.
// Unknown chan starts from the top (index 0 + delta).
function stepChan(chan, delta) {
  var list = stations()
  var idx = -1
  for (var i = 0; i < list.length; i++) {
    if (list[i].chan === chan) { idx = i; break }
  }
  var next = idx === -1 ? 0 : (idx + delta) % list.length
  if (next < 0) next += list.length
  return list[next].chan
}

// v1 stream URLs at the default aac-128 quality. Exceptions (probed):
// - chan 0 (Main Mix) uses the bare path: /aac-128 (no main-mix-128).
// - chan 42 (Serenity) has NO 128 variant; bare /serenity is 64k aac.
// - other chans use /{stream_name}-128.
var streamBase = "https://stream.radioparadise.com/"

function defaultQuality() {
  return "aac-128"
}

function streamUrl(chan, quality) {
  var q = String(quality || defaultQuality())
  if (chan === 0) return streamBase + q
  if (chan === 42) {
    if (q === "aac-128" || q === "aac-64") return streamBase + "serenity"
    return streamBase + "serenity-flac"
  }
  var st = stationByChan(chan)
  if (q.indexOf("aac-") === 0) return streamBase + st.streamName + "-" + q.substring(4)
  return streamBase + st.streamName + "-128"
}

// Split an in-stream "Artist - Title" string on the first " - ".
// Returns {artist, title}; a string with no separator is a bare title.
function splitArtistTitle(s) {
  var t = String(s || "")
  var sep = t.indexOf(" - ")
  if (sep < 0) return { artist: "", title: t.trim() }
  return {
    artist: t.substring(0, sep).trim(),
    title: t.substring(sep + 3).trim()
  }
}

// Sanitize untrusted text (stream metadata, API fields) before display:
// strip C0/C1 controls + bidi overrides, trim, cap length.
function sanitizeText(s, maxLen) {
  var cap = maxLen > 0 ? maxLen : 256
  var t = String(s || "").replace(/[\u0000-\u001F\u007F-\u009F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, "")
  t = t.trim()
  if (t.length > cap) t = t.substring(0, cap)
  return t
}

// Notification-safe text: sanitizeText plus dropping "<", the only way
// to open a rich-text tag. Deleting rather than escaping: with no tag
// left the text can't be detected as rich, so an entity would show up
// literally. ">" is kept (can't start a tag; "a -> b" reads correctly).
function notifySafe(s, maxLen) {
  return sanitizeText(s, maxLen).replace(/</g, "")
}

// RP cover id for the on-disk art cache: ".../covers/m/11697.jpg" ->
// "11697". Anything else -> "" (never derive a filename from it).
function coverId(u) {
  var m = /^https:\/\/img\.radioparadise\.com\/covers\/[sml]\/([0-9]+)\.jpg$/i.exec(String(u || ""))
  return m ? m[1] : ""
}

// Allow-list for remote images (cover art) before any Image.source use.
// https only, RP hosts only.
function isAllowedImageUrl(u) {
  var s = String(u || "")
  if (s.indexOf("https://") !== 0) return false
  var hosts = [
    "https://img.radioparadise.com/",
    "https://stream.radioparadise.com/",
    "https://api.radioparadise.com/"
  ]
  for (var i = 0; i < hosts.length; i++) {
    if (s.indexOf(hosts[i]) === 0) return true
  }
  return false
}
