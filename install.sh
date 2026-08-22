#!/bin/bash
# Install FPL Gaffer.
#
# Nothing is written until you have seen the full list of what will be
# written and where, and said yes.
set -euo pipefail

ID="io.github.weedwhitesandwine.gaffer"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The shell only loads plugins from its own plugin directory, so that is the
# default — but you may point it at a different Omarchy config root.
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"

# Settings, cache and logs. Fixed, not a choice — and deliberately NOT
# inside the plugin folder. Omarchy watches that folder recursively with
# inotify and reloads the plugin on every write, so a state file there
# would reload your shell once a minute all the way through a match.
DATA_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/gaffer"

ASSUME_YES=0
DRY_RUN=0
DO_UNINSTALL=0

FILES=(manifest.json qmldir Gaffer.qml GafferState.qml BarWidget.qml Fmt.js
       SquadTab.qml LiveTab.qml TableTab.qml LeaguesTab.qml FixturesTab.qml
       PlayersTab.qml NewsTab.qml SettingsView.qml
       gafferd.py gaffer-ctl.sh README.md LICENSE)

# Shipped if present, skipped without complaint if not. preview.png is the
# catalogue thumbnail; it is a convention rather than anything the shell
# reads, so its absence must never fail an install.
OPTIONAL_FILES=(preview.png)

usage() {
  cat <<USAGE
FPL Gaffer installer

  ./install.sh [options]

  --plugin-dir DIR   where the plugin code goes
                     (default: $PLUGIN_DIR)
  --uninstall        remove the plugin code, and ask separately about data
  --dry-run          print what would happen and change nothing
  -y, --yes          skip the confirmation prompt
  -h, --help         this

The plugin directory must be somewhere the Omarchy shell scans, or the
shell will not find it.

Settings, cache and logs always go to
    $DATA_DIR
That is not adjustable: it follows the XDG state directory, and it must
stay outside the plugin folder because Omarchy reloads a plugin on every
write inside it.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-dir) PLUGIN_DIR="${2:?--plugin-dir needs a path}"; shift 2 ;;
    --uninstall)  DO_UNINSTALL=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || { echo "Not a terminal — re-run with --yes to proceed." >&2; exit 1; }
  local reply
  read -r -p "$1 [y/N] " reply
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

# --------------------------------------------------------------- uninstall
if [[ $DO_UNINSTALL -eq 1 ]]; then
  echo "This will remove:"
  echo "    $PLUGIN_DIR"
  [[ -d $PLUGIN_DIR ]] || echo "    (not present — nothing to remove)"
  echo
  echo "Your settings, cache and logs in"
  echo "    $DATA_DIR"
  echo "will be LEFT ALONE unless you ask for them separately."
  echo

  if [[ $DRY_RUN -eq 1 ]]; then echo "(dry run — nothing changed)"; exit 0; fi

  if [[ -d $PLUGIN_DIR ]] && confirm "Remove the plugin code?"; then
    rm -rf "$PLUGIN_DIR"
    echo "Removed $PLUGIN_DIR"
  else
    echo "Left the plugin code in place."
  fi

  if [[ -d $DATA_DIR ]] && confirm "Also remove your settings, cache and logs in $DATA_DIR?"; then
    rm -rf "$DATA_DIR"
    echo "Removed $DATA_DIR"
  else
    echo "Left $DATA_DIR in place."
  fi

  echo
  echo "Remove the bar entry with:  ./gaffer-ctl.sh bar off"
  echo "Remove the hotkey with:     ./gaffer-ctl.sh unbind"
  exit 0
fi

# ----------------------------------------------------------------- install
UPGRADE=0
[[ -d $PLUGIN_DIR ]] && UPGRADE=1

BACKUP=""
if [[ $UPGRADE -eq 1 ]]; then
  BACKUP="$DATA_DIR/backups/$(date +%Y%m%d-%H%M%S)"
fi

echo "FPL Gaffer will write to exactly two places:"
echo
present_optional=0
for f in "${OPTIONAL_FILES[@]}"; do [[ -f "$SRC/$f" ]] && present_optional=$((present_optional + 1)); done
echo "  1. Plugin code — $(( ${#FILES[@]} + present_optional )) files"
echo "      $PLUGIN_DIR"
if [[ $UPGRADE -eq 1 ]]; then
  echo "      — a copy already exists there; it will be moved to"
  echo "        $BACKUP"
fi
echo
echo "  2. Settings, cache and logs — created on first run, not now"
echo "      $DATA_DIR"
echo "      (kept out of the plugin folder deliberately: Omarchy reloads a"
echo "       plugin on every write inside it, and this changes every minute"
echo "       while matches are being played)"
echo
echo "Nothing else is touched. The bar entry and the hotkey are opt-in, and"
echo "are written only when you turn them on in settings."
echo

if [[ $DRY_RUN -eq 1 ]]; then echo "(dry run — nothing changed)"; exit 0; fi
confirm "Install?" || { echo "Cancelled — nothing was written."; exit 1; }

for f in "${FILES[@]}"; do
  [[ -f "$SRC/$f" ]] || { echo "Missing source file: $f" >&2; exit 1; }
done

# Stage the whole thing and move it into place in one go. The shell watches
# the plugin directory and reloads on every change, so installing file by
# file would make the bar flicker once per file.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/gaffer-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

for f in "${FILES[@]}"; do cp "$SRC/$f" "$STAGE/$f"; done
for f in "${OPTIONAL_FILES[@]}"; do
  [[ -f "$SRC/$f" ]] && cp "$SRC/$f" "$STAGE/$f"
done
chmod +x "$STAGE/gaffer-ctl.sh" "$STAGE/gafferd.py"

mkdir -p "$(dirname "$PLUGIN_DIR")"
if [[ $UPGRADE -eq 1 ]]; then
  mkdir -p "$(dirname "$BACKUP")"
  mv "$PLUGIN_DIR" "$BACKUP"
fi
mv "$STAGE" "$PLUGIN_DIR"
chmod 755 "$PLUGIN_DIR"
trap - EXIT

echo
echo "Installed to $PLUGIN_DIR"
[[ $UPGRADE -eq 1 ]] && echo "Previous version kept at $BACKUP"
echo "Your data will live in $DATA_DIR"
echo
echo "Now run:  omarchy restart shell"
echo "Then enable FPL Gaffer in the plugin manager, or add it to the bar with:"
echo "  ./gaffer-ctl.sh bar on right"
