.pragma library

// Pure helpers shared by the panel, its tabs, the controller and the bar
// widget. Nothing here reads QML ids or component state; whatever a helper
// needs is passed in, so each one can be tested on its own (tests/test_utils.py).

// Keys ------------------------------------------------------------------

// Hyprland's name for the key, or "" for one a chord cannot end on.
function keyName(event) {
  var key = event.text ? event.text.toUpperCase() : ""
  if (event.key === Qt.Key_BracketLeft) key = "BRACKETLEFT"
  else if (event.key === Qt.Key_BracketRight) key = "BRACKETRIGHT"
  else if (event.key === Qt.Key_Comma) key = "COMMA"
  else if (event.key === Qt.Key_Period) key = "PERIOD"
  else if (event.key === Qt.Key_Slash) key = "SLASH"
  else if (event.key === Qt.Key_Backslash) key = "BACKSLASH"
  else if (event.key === Qt.Key_Semicolon) key = "SEMICOLON"
  else if (event.key === Qt.Key_Apostrophe) key = "APOSTROPHE"
  else if (event.key === Qt.Key_Minus) key = "MINUS"
  else if (event.key === Qt.Key_Equal) key = "EQUAL"
  else if (event.key === Qt.Key_QuoteLeft) key = "GRAVE"
  else if (event.key === Qt.Key_Space) key = "SPACE"
  else if (event.key === Qt.Key_Tab) key = "TAB"
  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) key = "RETURN"
  else if (event.key === Qt.Key_Backspace) key = "BACKSPACE"
  else if (event.key === Qt.Key_Delete) key = "DELETE"
  else if (event.key === Qt.Key_Left) key = "LEFT"
  else if (event.key === Qt.Key_Right) key = "RIGHT"
  else if (event.key === Qt.Key_Up) key = "UP"
  else if (event.key === Qt.Key_Down) key = "DOWN"
  else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F35)
    key = "F" + String(event.key - Qt.Key_F1 + 1)
  else if (event.key === Qt.Key_Escape) key = "ESCAPE"
  return key
}

// "SUPER + CTRL + S", modifiers always in this order; Escape cancels, so it
// never becomes a chord.
function chordFromEvent(event) {
  var parts = []
  if (event.modifiers & Qt.MetaModifier) parts.push("SUPER")
  if (event.modifiers & Qt.ControlModifier) parts.push("CTRL")
  if (event.modifiers & Qt.AltModifier) parts.push("ALT")
  if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
  var key = keyName(event)
  if (!key || key === "ESCAPE") return ""
  parts.push(key)
  return parts.join(" + ")
}

// A chord already bound to one of our own commands by hand is adoptable,
// not a conflict; only a chord bound to something else needs attention.
function realConflicts(conflicts, adoptable) {
  var chords = adoptable.map(function (a) { return String(typeof a === "object" ? (a.chord || a.key || "") : a).toUpperCase() })
  return conflicts.filter(function (c) { return chords.indexOf(String(c).toUpperCase()) < 0 })
}

// Voices ----------------------------------------------------------------

// Voices are stored as filenames like "en_US-amy-medium". That is an
// identifier, not a name. Providers whose voice names are already words -
// kokoro's af_heart - are left exactly as they are.
function titleCase(word) {
  var w = String(word)
  return w.length ? w.charAt(0).toUpperCase() + w.slice(1) : w
}

function voiceName(key) {
  var parts = String(key).split("-")
  if (parts.length >= 3 && /^[a-z]{2,3}_[A-Za-z]{2,4}$/.test(parts[0]))
    return titleCase(parts[1].replace(/_/g, " "))
  return String(key)
}

function voiceLabel(key) {
  var parts = String(key).split("-")
  if (parts.length >= 3 && /^[a-z]{2,3}_[A-Za-z]{2,4}$/.test(parts[0]))
    return voiceName(key) + " · " + parts[0] + " · " + parts.slice(2).join("-")
  return String(key)
}

// A provider addressed by filename (piper) sends plain keys and we make them
// readable here; one that lists {value, label} pairs names its own voices.
function voiceOptions(list) {
  return list.map(function (v) {
    if (v && typeof v === "object") return { label: String(v.label || v.value), value: String(v.value) }
    return { label: voiceLabel(v), value: String(v) }
  })
}

function qualityRank(q) {
  return ({ "x_low": 0, "low": 1, "medium": 2, "high": 3 })[String(q)] ?? 1
}

// The items whose named fields contain the query, ignoring case.
function filterByQuery(list, query, fields) {
  var q = String(query).toLowerCase().trim()
  if (!q) return list.slice()
  return list.filter(function (item) {
    return fields.some(function (f) { return String(item[f]).toLowerCase().indexOf(q) >= 0 })
  })
}

// The catalogue as the browser lists it: searched, sorted by `mode`, and
// tagged with the section each voice belongs in.
function catalogueRows(all, query, mode, activeVoice) {
  var out = filterByQuery(all, query, ["key", "lang", "country"])
  function byName(a, b) { return String(a.name).localeCompare(String(b.name)) }
  out.sort(function (a, b) {
    // Installed always leads, so the list you can act on is never buried
    // under a hundred you have not downloaded.
    var aState = a.installed ? 0 : (a.key === activeVoice ? 1 : 2)
    var bState = b.installed ? 0 : (b.key === activeVoice ? 1 : 2)
    if (aState !== bState) return aState - bState
    if (mode === "name") return byName(a, b)
    if (mode === "size") return (b.sizeMB - a.sizeMB) || byName(a, b)
    if (mode === "quality") return (qualityRank(b.quality) - qualityRank(a.quality)) || byName(a, b)
    return String(a.lang).localeCompare(String(b.lang)) || byName(a, b)
  })
  // ListView sections need the group on the item itself.
  return out.map(function (v) {
    return { key: v.key, name: v.name, lang: v.lang, country: v.country,
             quality: v.quality, sizeMB: v.sizeMB, installed: v.installed,
             group: v.installed ? "Installed" : (v.key === activeVoice ? "Needs repair" : "Available") }
  })
}

// Playback --------------------------------------------------------------

function idleNowPlaying() {
  return { status: "idle", text: "", chars: 0, elapsed: null, duration: null, rate: 1, provider: "", voice: "", canPause: false, canLiveRate: false }
}

// Sentences, with any too long to read at a glance (OCR often has no
// punctuation at all) cut at a word boundary so each fits the screen.
// Each phrase keeps its offset in the text, which places the reader.
function splitPhrases(text) {
  var out = [], start = 0
  function push(end) {
    var piece = text.slice(start, end), lead = piece.length - piece.replace(/^\s+/, "").length
    var at = start + lead
    piece = piece.trim()
    while (piece.length > 160) {
      var cut = piece.lastIndexOf(" ", 140)
      if (cut < 60) cut = 140
      out.push({ text: piece.slice(0, cut).trim(), start: at })
      at += cut; piece = piece.slice(cut).replace(/^\s+/, function(m) { at += m.length; return "" })
    }
    if (piece.length) out.push({ text: piece, start: at })
    start = end
  }
  for (var i = 0; i < text.length; ++i) {
    var c = text.charAt(i)
    if (c === "\n") { push(i + 1); continue }
    if (".!?…".indexOf(c) < 0) continue
    var j = i + 1
    while (j < text.length && ".!?…\"'”’)]".indexOf(text.charAt(j)) >= 0) j++
    if (j >= text.length || /\s/.test(text.charAt(j))) { push(j); i = j - 1 }
  }
  push(text.length)
  return out
}

// Speech runs at an even pace closely enough to place the reader by the
// share of audio already played: the last phrase starting at or before `at`.
function phraseAt(phrases, at) {
  var found = 0
  for (var i = 0; i < phrases.length; ++i) if (phrases[i].start <= at) found = i
  return found
}

// Providers -------------------------------------------------------------

function byName(list, name) {
  return list.find(function (m) { return m.name === name }) || null
}

// Installed means "present", which is not the same as usable. Unproven is
// not unusable; only an engine proven unable to work is refused.
function isUsable(m) {
  return m.status === "ready" || m.status === "untested"
}

// Only engines this plugin installs (an `# install:` header) can be removed
// here; system packages such as Tesseract belong to the package manager.
function canUninstall(m) {
  return !!m && !!m.install
    && ((m.installedDevices || []).length > 0 || ["ready", "untested", "failing"].indexOf(m.status) >= 0)
}

// Providers declaring the same `# family:` share one row as its variants.
function groupByFamily(providers) {
  var out = [], families = {}
  for (var i = 0; i < providers.length; ++i) {
    var p = providers[i]
    if (!p.family) { out.push({ family: "", members: [p] }); continue }
    if (!families[p.family]) { families[p.family] = { family: p.family, members: [] }; out.push(families[p.family]) }
    families[p.family].members.push(p)
  }
  for (var j = 0; j < out.length; ++j)
    out[j].members.sort(function(a, b) { return String(a.variant).localeCompare(String(b.variant)) })
  return out
}

// A variant counts as installed if its engine for any device is present.
function variantInstalled(m) {
  return m.status !== "missing" || (m.installedDevices || []).length > 0
}

function variantSummary(m) {
  var info = m.installInfo || {}
  var size = String((info.cpu || info["default"] || {}).size || "").replace(/^about /, "~")
  return [size, m.variantNote || ""].filter(function(part) { return part !== "" }).join(" · ")
}

// Speech and OCR engine rows say the same things about the same states.
function engineStatusText(m) {
  return m.status === "failing" ? "Not working" : m.status === "ready" ? "● Ready" : ""
}

function engineActionText(m) {
  if (m.status === "failing") return m.install ? "Repair" : "Retry"
  return "Install"
}

// OCR languages are stored as "eng+deu"; nothing set means English.
function langCodes(langs) {
  return String(langs || "eng").split("+").filter(function (c) { return c.length })
}

// Time and format -------------------------------------------------------

function clockText(seconds) {
  var s = Math.max(0, Math.round(seconds))
  return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
}

// A job's percent as a bar's fill; never empty, so a started job shows.
function progressFraction(percent) {
  return Math.max(0.02, Math.min(1, (Number(percent) || 0) / 100))
}

function withAlpha(color, alpha) {
  return Qt.rgba(color.r, color.g, color.b, alpha)
}

// Qt.resolvedUrl gives file:// URLs, percent-encoded; processes need a path.
function localPath(url) {
  var value = String(url)
  return value.indexOf("file://") === 0 ? decodeURIComponent(value.slice(7)) : value
}

// Items -----------------------------------------------------------------

// The first Popup anywhere under `item`, found by the properties every
// Popup has, or null.
function findPopup(item) {
  var kids = item ? item.children : []
  for (var i = 0; i < kids.length; i++) {
    var data = kids[i].data || []
    for (var j = 0; j < data.length; j++)
      if (data[j] && data[j].closePolicy !== undefined && data[j].opened !== undefined) return data[j]
    var deeper = findPopup(kids[i])
    if (deeper) return deeper
  }
  return null
}

function isInside(item, ancestor) {
  for (var current = item; current; current = current.parent)
    if (current === ancestor) return true
  return false
}
