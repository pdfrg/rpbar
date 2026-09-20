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

// Short station codes for the full (no-media) pill: "MM: Artist - Title".
// From fixes.txt; unknown chans fall back to "RP".
function stationShort(chan) {
  var codes = { 0: "MM", 1: "ML", 2: "R", 3: "G", 5: "B", 42: "S", 945: "K" }
  var c = codes[chan]
  return c !== undefined ? c : "RP"
}

// Full-pill text for when omarchy.media is absent. Artist/title are
// expected sanitized already; sanitized again defensively with caps.
// No track yet -> full station title (same as the compact pill).
function pillText(chan, artist, title) {
  var a = sanitizeText(artist, 128)
  var t = sanitizeText(title, 256)
  if (a !== "" && t !== "") return stationShort(chan) + ": " + a + " - " + t
  if (t !== "") return stationShort(chan) + ": " + t
  if (a !== "") return stationShort(chan) + ": " + a
  return stationByChan(chan).title
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
  var q = qualityOrDefault(chan, quality)
  if (chan === 0) return streamBase + q
  if (chan === 42) return q === "flac" ? streamBase + "serenity-flac" : streamBase + "serenity"
  var st = stationByChan(chan)
  if (q === "aac-320") return streamBase + st.streamName + "-320"
  if (q === "mp3-192") return streamBase + st.streamName + "-192"
  if (q === "flacm") return streamBase + st.streamName + "-flacm"
  return streamBase + st.streamName + "-128"
}

// Curated quality menu per station. Plain flac / non-meta ogg builds
// are deliberately excluded: they carry zero in-stream titles, so the
// pill would go blank until the API fills in seconds later. Serenity
// is the exception — it has no meta build at all, so its only two
// probed variants are offered as-is.
function qualitiesFor(chan) {
  if (chan === 42) return [
    { value: "aac-64", label: "AAC 64" },
    { value: "flac", label: "FLAC" }
  ]
  return [
    { value: "aac-128", label: "AAC 128" },
    { value: "aac-320", label: "AAC 320" },
    { value: "mp3-192", label: "MP3 192" },
    { value: "flacm", label: "FLAC+" }
  ]
}

// One-line note under the popup quality row ("" = no note).
function qualityNote(chan) {
  if (chan === 42) return "Serenity offers 64k AAC and FLAC only."
  return "FLAC+ carries track titles; plain FLAC is not offered."
}

// Station default when the stored quality isn't offered (e.g. aac-320
// selected, then switched to serenity).
function defaultQualityFor(chan) {
  return chan === 42 ? "aac-64" : defaultQuality()
}

// Quality validated against the station menu, else the station default.
function qualityOrDefault(chan, quality) {
  var list = qualitiesFor(chan)
  var q = String(quality || "")
  for (var i = 0; i < list.length; i++) {
    if (list[i].value === q) return q
  }
  return defaultQualityFor(chan)
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
