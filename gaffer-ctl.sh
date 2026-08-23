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
    # This value ends up inside a Lua string in bindings.lua, so it is checked
    # here as well as in the settings card — this file can be run without ever
    # going near the UI. A hotkey is modifiers plus one key and nothing else;
    # anything that does not match that shape is refused rather than escaped,
    # because there is no reason for it to exist.
    if ! [[ $key =~ ^(SUPER|CTRL|ALT|SHIFT)([[:space:]]\+[[:space:]](SUPER|CTRL|ALT|SHIFT))*[[:space:]]\+[[:space:]]([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$ ]]; then
      echo "gaffer-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
    # Staged in the same directory as bindings.lua and renamed over it, so the
    # swap is one atomic step — staging in /tmp and mv-ing across filesystems
    # degrades to a copy, which can leave a half-written config if
    # interrupted. mktemp creates the stage file exclusively under a random
    # name, so nothing can have been planted at it.
    tmp=$(mktemp "$BIND_FILE.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    strip_block > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "FPL Gaffer", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    chmod --reference="$BIND_FILE" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$BIND_FILE"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    tmp=$(mktemp "$BIND_FILE.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    strip_block > "$tmp"
    chmod --reference="$BIND_FILE" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$BIND_FILE"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    # The readout is visible when Gaffer's entry lives in the bar layout of
    # shell.json; hidden (but the plugin still enabled) when the entry lives
    # in the plugins list instead. The shell hot-reloads the file.
    python3 - "$2" "${3:-right}" <<'PY'
import json, os, stat, sys, tempfile
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.gaffer"
p = os.path.expanduser("~/.config/omarchy/shell.json")
# shell.json belongs to the user, not to this plugin, and it is read back
# before it is rewritten — so it gets the ceiling every other read here has,
# put at the read, with the extra byte that identifies an over-sized file.
# Refusing means leaving the file exactly as it stands, which is the right
# answer for a file this script cannot make sense of. The open refuses
# symlinks and non-regular files, so a planted link cannot redirect the read
# and a FIFO cannot block it forever.
MAX_SHELL_JSON = 4 * 1024 * 1024
try:
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise SystemExit
        with os.fdopen(fd, "rb") as f:
            fd = None
            raw = f.read(MAX_SHELL_JSON + 1)
    finally:
        if fd is not None:
            os.close(fd)
    if len(raw) > MAX_SHELL_JSON:
        raise SystemExit
    d = json.loads(raw.decode("utf-8", "replace"))
except SystemExit:
    raise
except Exception:
    raise SystemExit
# Valid JSON of the wrong shape is not a config file, and setdefault will
# happily hand back a string to be subscripted. Each level is checked.
if not isinstance(d, dict):
    raise SystemExit
def eid(w): return w.get("id") if isinstance(w, dict) else w
if not isinstance(d.get("bar"), dict):
    d["bar"] = {}
bar = d["bar"]
if not isinstance(bar.get("layout"), dict):
    bar["layout"] = {}
lay = bar["layout"]
for s in ("left", "center", "right"):
    if not isinstance(lay.get(s), list):
        lay[s] = []
for s in lay:
    if isinstance(lay[s], list):
        lay[s] = [w for w in lay[s] if eid(w) != ID]
if not isinstance(d.get("plugins"), list):
    d["plugins"] = []
d["plugins"] = [w for w in d["plugins"] if eid(w) != ID]
if state == "on":
    lay[sec].append({"id": ID})
else:
    d["plugins"].append({"id": ID})
# Staged under an unpredictable name created exclusively by mkstemp — which
# never follows a symlink — in a directory verified to be owned by us and
# writable by nobody else, then renamed over the destination in one step.
# Writing in place would truncate the user's shell configuration before
# rebuilding it, and a predictable stage name would let a pre-planted symlink
# turn this write into the truncation of whatever the link pointed at.
home_cfg = os.path.dirname(p)
try:
    st = os.stat(home_cfg)
    if st.st_uid != os.getuid() or (st.st_mode & 0o022):
        raise SystemExit
except OSError:
    raise SystemExit
fd, tmp = tempfile.mkstemp(prefix=".shell.json.", suffix=".tmp", dir=home_cfg)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    try:
        os.chmod(tmp, os.stat(p).st_mode & 0o777)
    except OSError:
        pass
    os.replace(tmp, p)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    ;;
  stop)
    # Kill the recorded pid, not a pattern. `pkill -f "gafferd.py daemon"`
    # matches any process whose whole command line contains that text —
    # including the shell that invoked this script, if the phrase happens to
    # appear in it. The engine writes its own pid to a lock file precisely so
    # this can be exact.
    lock="${XDG_STATE_HOME:-$HOME/.local/state}/gaffer/gafferd.lock"
    # A regular, non-symlink file read to a ceiling, rather than cat on
    # whatever a restored backup left at that name: an unbounded cat would
    # hold all of it, and a FIFO there would never return at all.
    pid=""
    if [[ -f $lock && ! -L $lock ]]; then
      pid=$(head -c 64 -- "$lock" 2>/dev/null || true)
    fi
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
