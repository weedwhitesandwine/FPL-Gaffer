.pragma library

// Pure formatting helpers — no theme, no state, safe to share everywhere.

function money(v) {
  if (v === undefined || v === null) return "—"
  return "£" + Number(v).toFixed(1) + "m"
}

function rank(v) {
  if (v === undefined || v === null) return "—"
  var n = Number(v)
  if (n >= 1000000) return (n / 1000000).toFixed(2) + "m"
  if (n >= 1000) return Math.round(n / 1000) + "k"
  return String(n)
}

function commas(v) {
  if (v === undefined || v === null) return "—"
  return String(v).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function signed(v) {
  if (v === undefined || v === null || v === 0) return "0"
  return (v > 0 ? "+" : "") + v
}

// "3d 4h", "4h 12m", "18m" — enough precision to be useful, never more.
function countdown(seconds) {
  if (seconds === undefined || seconds === null) return "—"
  var s = Math.max(0, Math.floor(seconds))
  var d = Math.floor(s / 86400)
  var h = Math.floor((s % 86400) / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  return m + "m " + (s % 60) + "s"
}

function kickoff(iso) {
  if (!iso) return "TBC"
  var d = new Date(iso)
  if (isNaN(d.getTime())) return "TBC"
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var hh = String(d.getHours()).padStart(2, "0")
  var mm = String(d.getMinutes()).padStart(2, "0")
  return days[d.getDay()] + " " + hh + ":" + mm
}

function ago(iso) {
  if (!iso) return "never"
  var then = new Date(iso).getTime()
  if (isNaN(then)) return "never"
  var s = Math.max(0, Math.floor((Date.now() - then) / 1000))
  if (s < 60) return "just now"
  if (s < 3600) return Math.floor(s / 60) + "m ago"
  if (s < 86400) return Math.floor(s / 3600) + "h ago"
  return Math.floor(s / 86400) + "d ago"
}

// Availability flags, spelled out. FPL uses single letters for these.
function availability(status) {
  switch (status) {
    case "a": return ""
    case "d": return "doubt"
    case "i": return "injured"
    case "s": return "suspended"
    case "u": return "gone"
    case "n": return "ineligible"
    default: return ""
  }
}

function movement(now, before) {
  if (!now || !before) return 0
  return before - now      // positive means climbed
}

function matches(haystack, needle) {
  var q = String(needle || "").trim()
  if (!q) return true
  return String(haystack || "").toLowerCase().indexOf(q.toLowerCase()) >= 0
}
