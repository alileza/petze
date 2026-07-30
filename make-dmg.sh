#!/bin/bash
# Build petze.dmg: petze.app + Applications shortcut, ready to drag-install.
set -e
cd "$(dirname "$0")"

./make-app.sh

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R petze.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f petze.dmg
hdiutil create -volname "petze" -srcfolder "$STAGE" -ov -format UDZO -quiet petze.dmg
echo "Built petze.dmg ($(du -h petze.dmg | cut -f1 | tr -d ' '))"
