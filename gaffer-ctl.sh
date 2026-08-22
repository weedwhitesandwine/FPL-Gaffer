#!/bin/bash
# FPL Gaffer settings helper. Runs ONLY when the user makes a choice in
# Gaffer's greeter or settings view — never on its own.
#
#   gaffer-ctl.sh bind "SUPER + P"   manage Gaffer's hotkey as a marked block
#                                    in ~/.config/hypr/bindings.lua (replaces
#                                    only its own block, never other lines)
#   gaffer-ctl.sh unbind             remove that block
#   gaffer-ctl.sh bar on|off [sec]   add/remove the Gaffer readout in the bar
#                                    layout (~/.config/omarchy/shell.json)
#   gaffer-ctl.sh stop               stop the background data engine
#   gaffer-ctl.sh clear-cache        forget every cached API response
set -e

ID="io.github.weedwhitesandwine.gaffer"
BIND_FILE="$HOME/.config/hypr/bindings.lua"
MARK_IN="-- >>> gaffer hotkey (managed by FPL Gaffer settings — change it there)"
MARK_OUT="-- <<< gaffer hotkey"

strip_block() {
  awk '
    index($0, ">>> gaffer hotkey") { skip = 1; next }
    index($0, "<<< gaffer hotkey") { skip = 0; next }
    !skip { print }
  ' "$BIND_FILE"
}

case "$1" in
  bind)
    key="$2"
    [[ -n $key && -f $BIND_FILE ]] || exit 1
    tmp=$(mktemp)
    strip_block > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "FPL Gaffer", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    mv "$tmp" "$BIND_FILE"
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    tmp=$(mktemp)
    strip_block > "$tmp"
    mv "$tmp" "$BIND_FILE"
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    # The readout is visible when Gaffer's entry lives in the bar layout of
    # shell.json; hidden (but the plugin still enabled) when the entry lives
    # in the plugins list instead. The shell hot-reloads the file.
    python3 - "$2" "${3:-right}" <<'PY'
import json, os, sys
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.gaffer"
p = os.path.expanduser("~/.config/omarchy/shell.json")
try:
    d = json.load(open(p))
except Exception:
    raise SystemExit
def eid(w): return w.get("id") if isinstance(w, dict) else w
bar = d.setdefault("bar", {})
lay = bar.setdefault("layout", {})
for s in ("left", "center", "right"):
    lay.setdefault(s, [])
for s in lay:
    lay[s] = [w for w in lay[s] if eid(w) != ID]
d.setdefault("plugins", [])
d["plugins"] = [w for w in d["plugins"] if eid(w) != ID]
if state == "on":
    lay[sec].append({"id": ID})
else:
    d["plugins"].append({"id": ID})
json.dump(d, open(p, "w"), indent=2)
PY
    ;;
  stop)
    # Kill the recorded pid, not a pattern. `pkill -f "gafferd.py daemon"`
    # matches any process whose whole command line contains that text —
    # including the shell that invoked this script, if the phrase happens to
    # appear in it. The engine writes its own pid to a lock file precisely so
    # this can be exact.
    lock="${XDG_STATE_HOME:-$HOME/.local/state}/gaffer/gafferd.lock"
    pid=$(cat "$lock" 2>/dev/null || true)
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      # Make sure it really is ours before signalling it.
      if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "gafferd.py"; then
        kill "$pid" 2>/dev/null || true
        echo "Stopped the engine (pid $pid)."
      else
        echo "Lock file points at pid $pid, which is not the engine — leaving it alone." >&2
      fi
    else
      echo "The engine does not appear to be running."
    fi
    ;;
  clear-cache)
    # Cached responses accumulate slowly across a season — mostly one small
    # file per manager per gameweek from scoring mini-leagues live. Nothing
    # here is precious; it is all re-fetched on the next refresh. This is a
    # deliberate, user-run command: the plugin never deletes anything itself.
    dir="${XDG_STATE_HOME:-$HOME/.local/state}/gaffer/cache"
    if [[ -d $dir ]]; then
      before=$(du -sh "$dir" 2>/dev/null | cut -f1)
      count=$(find "$dir" -maxdepth 1 -name '*.json' | wc -l)
      find "$dir" -maxdepth 1 -name '*.json' -delete
      echo "Cleared $count cached responses ($before)."
      echo "They will be fetched again on the next refresh."
    else
      echo "No cache to clear."
    fi
    ;;
esac
