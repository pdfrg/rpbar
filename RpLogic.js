// RpLogic.js — pure Radio Paradise helpers (no Quickshell imports).
// Unit-testable with plain `node --check` / node test harnesses.
//
// v1 scope: 7 stations x 1 quality (default aac-128). The URL table below
// is ground truth from live HEAD probes (2026-09-19); the website player
// bundle confirms the aac/flac construction, per-channel option lists come
// from RP's CMS and are NOT hardcodable (see PLAN.md §1).

// Station catalog: chan numbers are the RP API ids (list_chan); titles
// are the API titles; streamName feeds the per-channel URL builder;
// playerSlug feeds the clickable-art station page (identical to the
// website slugs today, kept as its own field so a future RP rename of
// one can't silently break the other).
function stations() {
  return [
    { chan: 0, slug: "main-mix", streamName: "main-mix", playerSlug: "main-mix", title: "The Main Mix" },
    { chan: 1, slug: "mellow", streamName: "mellow", playerSlug: "mellow", title: "Mellow Mix" },
    { chan: 2, slug: "rock", streamName: "rock", playerSlug: "rock", title: "RockIt!" },
    { chan: 3, slug: "global", streamName: "global", playerSlug: "global", title: "The Globe" },
    { chan: 5, slug: "beyond", streamName: "beyond", playerSlug: "beyond", title: "Beyond..." },
    { chan: 42, slug: "serenity", streamName: "serenity", playerSlug: "serenity", title: "Serenity" },
    { chan: 945, slug: "kfat", streamName: "kfat", playerSlug: "kfat", title: "KFAT" }
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

// Volume clamp shared by slider, wheel, and CLI (mpv ceiling 130).
function clampVolume(v) {
  var n = Math.round(Number(v))
  if (!isFinite(n)) return 70
  return Math.max(0, Math.min(130, n))
}

// Per-station persisted maps ({chan: value}). Unknown/missing entries fall
// back; volumes clamp, qualities validate against the station menu.
function volumeFor(map, chan, fallback) {
  var fb = clampVolume(fallback === undefined ? 70 : fallback)
  if (!map || typeof map !== "object") return fb
  var v = map[String(chan)]
  if (v === undefined) v = map[chan]
  if (v === undefined) return fb
  return clampVolume(v)
}

function qualityForStation(map, chan, fallback) {
  var fb = qualityOrDefault(chan, fallback)
  if (!map || typeof map !== "object") return fb
  var q = map[String(chan)]
  if (q === undefined) q = map[chan]
  if (q === undefined || q === null || q === "") return fb
  return qualityOrDefault(chan, q)
}

// Large cover URL for the R-click art viewer: same numeric id as any
// s/m/l cover, always the l (500px) variant. Anything else -> "".
function largeCoverUrl(u) {
  var id = coverId(u)
  if (id === "") return ""
  var abs = "https://img.radioparadise.com/covers/l/" + id + ".jpg"
  return isAllowedImageUrl(abs) ? abs : ""
}

// One-shot large-art download path (session viewer, never the bar/toast
// cache file). dir is the caller's own cache dir ("/tmp" default); the
// filename is digits-only from coverId, so no traversal is possible.
// "" when the cover has no usable id.
function largeArtTmpPath(u, dir) {
  var id = coverId(u)
  if (id === "") return ""
  var d = String(dir || "/tmp")
  if (d.charAt(d.length - 1) === "/") d = d.substring(0, d.length - 1)
  return d + "/rpbar-large-" + id + ".jpg"
}

// Ceiling minutes until sleepAt (0 = none/elapsed). Companions with
// sleepLabel for strings that read better without "left".
function sleepMins(sleepAtMs, nowMs) {
  var end = Number(sleepAtMs)
  var now = Number(nowMs)
  if (!(end > 0) || !(now >= 0)) return 0
  return Math.max(0, Math.ceil((end - now) / 60000))
}

// Sleep countdown label for the popup ("12 min left" / ""). "" when no
// timer or already elapsed.
function sleepLabel(sleepAtMs, nowMs) {
  var end = Number(sleepAtMs)
  var now = Number(nowMs)
  if (!(end > 0) || !(now >= 0)) return ""
  var mins = Math.ceil((end - now) / 60000)
  if (mins <= 0) return ""
  return mins + " min left"
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

// Station player page for clickable album art (verified against the RP
// website; unknown chans fall back to the Main Mix).
function playerPageUrl(chan) {
  return "https://radioparadise.com/player/info/" + stationByChan(chan).playerSlug
}

// Allow-list for browsable links before any browser launch. https only,
// RP page host only (mirrors isAllowedImageUrl).
function isAllowedLinkUrl(u) {  var s = String(u || "")
  if (s.indexOf("https://") !== 0) return false
  var hosts = [
    "https://radioparadise.com/",
    "https://www.radioparadise.com/"
  ]
  for (var i = 0; i < hosts.length; i++) {
    if (s.indexOf(hosts[i]) === 0) return true
  }
  return false
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
// strip C0/C1 controls + bidi overrides + line/paragraph separators
// (U+2028/29 break even single-line Text, wrecking fixed row heights),
// trim, cap length.
function sanitizeText(s, maxLen) {
  var cap = maxLen > 0 ? maxLen : 256
  var t = String(s || "").replace(/[\u0000-\u001F\u007F-\u009F\u061C\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]/g, "")
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

// ---- Schedule (0.9.0): upcoming via /play block, history via list ----

// Absolute https cover URL from a possibly-relative path + base. base is
// cover_base_url ("https://img.../") or image_base ("//img.../").
// Relative paths must look like covers/x/N.jpg; anything else -> "".
// The result still has to pass isAllowedImageUrl.
function resolveCoverUrl(path, base) {
  var p = String(path || "")
  if (p === "") return ""
  if (p.indexOf("https://") === 0) return isAllowedImageUrl(p) ? p : ""
  if (!/^covers\//.test(p)) return ""
  var b = String(base || "")
  if (b.indexOf("//") === 0) b = "https:" + b
  if (b.indexOf("https://") !== 0) return ""
  if (b.charAt(b.length - 1) !== "/") b += "/"
  if (p.charAt(0) === "/") p = p.substring(1)
  var abs = b + p
  return isAllowedImageUrl(abs) ? abs : ""
}

// One normalized schedule entry shared by block + list parsing.
// coverFile is filled in later by the Service art pipeline ("" = none).
// ratingRaw is the RP average (block `rating` string or list
// `listener_rating` number); stored display-ready via formatRating.
function scheduleEntry(artist, title, album, year, coverUrl, songId, playTimeMs, durationMs, eventId, ratingRaw) {
  return {
    artist: sanitizeText(artist, 128),
    title: sanitizeText(title, 256),
    album: sanitizeText(album, 256),
    year: sanitizeText(year, 16),
    cover: String(coverUrl || ""),
    songId: String(songId === undefined || songId === null ? "" : songId),
    playTime: Number(playTimeMs) || 0,
    duration: Number(durationMs) || 0,
    event: String(eventId === undefined || eventId === null ? "" : eventId),
    rating: formatRating(ratingRaw),
    coverFile: ""
  }
}

// Identity of a schedule entry, comparable to Service streamKey
// (artist + "\n" + title, both sanitized).
function entryKey(e) {
  if (!e || typeof e !== "object") return "\n"
  return sanitizeText(e.artist, 128) + "\n" + sanitizeText(e.title, 256)
}

// /play block shape: {block_id, image_base, song: {"0": {...}, ...}}.
// Block songs use cover_medium/cover_small/cover_large (+cover) and
// sched_time_millis. Never throws; malformed -> {blockId:"", items:[]}.
function parseBlock(text) {
  var data = null
  try { data = JSON.parse(String(text || "")) } catch (e) { return { blockId: "", items: [] } }
  if (!data || typeof data !== "object") return { blockId: "", items: [] }
  var songs = data.song
  if (!songs || typeof songs !== "object") return { blockId: "", items: [] }
  var keys = []
  for (var k in songs) {
    if (songs[k] && typeof songs[k] === "object" && isFinite(Number(k))) keys.push(Number(k))
  }
  keys.sort(function(a, b) { return a - b })
  var items = []
  for (var i = 0; i < keys.length; i++) {
    var s = songs[String(keys[i])]
    var cover = resolveCoverUrl(s.cover_medium || s.cover_med || s.cover_small || s.cover || s.cover_large, data.image_base)
    items.push(scheduleEntry(s.artist, s.title, s.album, s.year, cover, s.song_id, s.sched_time_millis, s.duration, s.event, s.rating))
  }
  return { blockId: String(data.block_id === undefined || data.block_id === null ? "" : data.block_id), items: items }
}

// Split block items into upcoming relative to the stream identity.
// A block song matching streamKey is the current one; songs after it are
// upcoming. No match (block gap) -> items still scheduled in the future.
// maxN caps the result; nowMs injectable for tests.
function splitSchedule(items, streamKey, nowMs, maxN) {
  var list = items || []
  var cap = maxN > 0 ? maxN : 3
  var now = Number(nowMs) || 0
  var idx = -1
  for (var i = 0; i < list.length; i++) {
    if (entryKey(list[i]) === streamKey) { idx = i; break }
  }
  var out = []
  for (var j = idx + 1; j < list.length && out.length < cap; j++) {
    if (idx === -1 && !(list[j].playTime > now)) continue
    out.push(list[j])
  }
  return out
}

// nowplaying_list_v2022 shape: {song: [{...}], cover_base_url}.
// History = entries NOT matching streamKey (current excluded), capped.
// List songs use cover/cover_med/cover_small + play_time (ms epoch).
// Never throws; malformed -> [].
function parsePlaylist(text, streamKey, maxN) {
  var data = null
  try { data = JSON.parse(String(text || "")) } catch (e) { return [] }
  if (!data || typeof data !== "object") return []
  var songs = data.song
  if (!songs || typeof songs.length !== "number") return []
  var cap = maxN > 0 ? maxN : 5
  var out = []
  for (var i = 0; i < songs.length && out.length < cap; i++) {
    var s = songs[i]
    if (!s || typeof s !== "object") continue
    var cover = resolveCoverUrl(s.cover_med || s.cover_small || s.cover || s.cover_large, data.cover_base_url)
    var e = scheduleEntry(s.artist, s.title, s.album, s.year, cover, s.song_id, s.play_time, s.duration, s.event, s.listener_rating)
    if (entryKey(e) === streamKey) continue
    out.push(e)
  }
  return out
}

// RP average user rating (0-10 scale) display-ready with one decimal
// (rptui parity): "6.5", "7" -> "7.0". Accepts the block `rating` string
// or the list `listener_rating` number. Missing/zero -> "" (hidden,
// never a placeholder).
function formatRating(v) {
  if (v === undefined || v === null || v === "")
    return ""
  var n = Number(String(v).trim())
  if (!isFinite(n) || n <= 0)
    return ""
  return n.toFixed(1)
}

// Toast body lines for the track-change notification. Omarchy's
// NotificationCard renders the summary + at most 3 body lines
// (maximumLineCount: 3), so the rating is folded into the last content
// line — `Album (Year) · ★ 6.5`, falling back to the artist or title
// line when album is missing — never a 4th line that would be elided.
// All fields are notification-sanitized here; returns at most 3 lines.
function toastLines(title, artist, album, year, rating) {
  var lines = []
  var t = notifySafe(title, 128)
  if (t === "") return lines
  lines.push(t)
  var a = notifySafe(artist, 128)
  if (a !== "") lines.push(a)
  var albumLine = notifySafe(album, 128)
  if (albumLine !== "") {
    var y = notifySafe(year, 16)
    lines.push(y !== "" ? albumLine + " (" + y + ")" : albumLine)
  }
  var r = notifySafe(rating, 8)
  if (r !== "") lines[lines.length - 1] += " · ★ " + r
  return lines.slice(0, 3)
}

// Relative cue for upcoming rows: "in 3 min" / "in 1 h 5 min" /
// "starting soon" / "now". "" when the schedule time is missing.
function formatIn(schedMs, nowMs) {
  var sched = Number(schedMs)
  var now = Number(nowMs)
  if (!(sched > 0) || !(now >= 0)) return ""
  var d = sched - now
  if (d <= 0) return "now"
  var mins = Math.floor(d / 60000)
  if (mins < 1) return "starting soon"
  if (mins < 60) return "in " + mins + " min"
  var h = Math.floor(mins / 60), m = mins % 60
  return m === 0 ? "in " + h + " h" : "in " + h + " h " + m + " min"
}

// Relative cue for history rows from end-of-play: "just now" /
// "25 min ago" / "2 h 5 min ago". "" when play time is missing.
function formatAgo(playMs, durMs, nowMs) {
  var play = Number(playMs)
  var now = Number(nowMs)
  if (!(play > 0) || !(now >= 0)) return ""
  var mins = Math.floor((now - (play + (Number(durMs) || 0))) / 60000)
  if (!(mins >= 1)) return "just now"
  if (mins < 60) return mins + " min ago"
  var h = Math.floor(mins / 60), m = mins % 60
  return m === 0 ? h + " h ago" : h + " h " + m + " min ago"
}
