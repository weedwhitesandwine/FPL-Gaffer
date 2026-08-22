#!/bin/bash
# Copy FPL Gaffer into the Omarchy plugins folder in one go.
#
# The shell watches that folder and reloads on every change, so installing
# file by file makes the bar flicker repeatedly. Staging into a temporary
# folder and moving it into place keeps that down to a single reload.
set -e

ID="io.github.weedwhitesandwine.gaffer"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$ID"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/gaffer-install.XXXXXX")"
# Backups go OUTSIDE the plugins folder — the shell scans everything in
# there, so a copy left alongside would be loaded as a second plugin.
BACKUP="$HOME/.local/state/gaffer/backups"

for f in manifest.json qmldir Gaffer.qml GafferState.qml BarWidget.qml Fmt.js \
         SquadTab.qml LiveTab.qml TableTab.qml LeaguesTab.qml SettingsView.qml \
         FixturesTab.qml PlayersTab.qml NewsTab.qml \
         gafferd.py gaffer-ctl.sh README.md LICENSE; do
  cp "$SRC/$f" "$STAGE/$f"
done
chmod +x "$STAGE/gaffer-ctl.sh" "$STAGE/gafferd.py"

mkdir -p "$(dirname "$DEST")" "$BACKUP"
if [ -d "$DEST" ]; then
  mv "$DEST" "$BACKUP/$(date +%Y%m%d-%H%M%S)"
fi
mv "$STAGE" "$DEST"
chmod 755 "$DEST"

echo "FPL Gaffer installed to $DEST"
echo "any previous version was moved to $BACKUP"
echo "Enable it in the Omarchy plugin manager, or add it to shell.json."
