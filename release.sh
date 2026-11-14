#!/bin/zsh
# Publishes a new version of Albumine on GitHub, ready for automatic updates.
#
#   ./release.sh 1.1 notes.md
#
# Steps: sets the version in build.sh, builds (Developer ID signature and Apple notarization
# when configured), zips, signs the archive with the update key
# (Keychain, see Resources/update-key.swift), commits, tags vX.Y, pushes and creates the
# GitHub release with Albumine-X.Y.zip and Albumine-X.Y.zip.sig attached.
set -e
cd "$(dirname "$0")"

VERSION="$1"
NOTES="$2"
if [[ -z "$VERSION" || -z "$NOTES" || ! -f "$NOTES" ]]; then
  echo "usage: ./release.sh <version, e.g. 1.1> <release notes file (Markdown)>"
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Invalid version: $VERSION"; exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Uncommitted changes: commit them first."; exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "Tag v$VERSION already exists."; exit 1
fi

# Version (CFBundleVersion = digits only: 1.1 → 110, 1.0.1 → 101)
parts=(${(s:.:)VERSION})
BUILD=$(( ${parts[1]} * 100 + ${parts[2]:-0} * 10 + ${parts[3]:-0} ))
sed -i '' -E "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$VERSION</string>|" build.sh
sed -i '' -E "s|<key>CFBundleVersion</key><string>[^<]*</string>|<key>CFBundleVersion</key><string>$BUILD</string>|" build.sh

./build.sh
DIR=".build/release-$VERSION"
ZIP="$DIR/Albumine-$VERSION.zip"
mkdir -p "$DIR"
ditto -c -k --keepParent Albumine.app "$ZIP"      # replaces any previous archive

# Apple notarization (optional): needs a Developer ID signature (see build.sh) and notarytool
# credentials stored once with
#   xcrun notarytool store-credentials albumine-notary --apple-id <id> --team-id <team> --password <app-specific password>
# The profile name can be changed with ALBUMINE_NOTARY_PROFILE.
PROFILE="${ALBUMINE_NOTARY_PROFILE:-albumine-notary}"
if codesign -dvv Albumine.app 2>&1 | grep -q "Authority=Developer ID Application"; then
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Notarizing (a few minutes)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple Albumine.app
    ditto -c -k --keepParent Albumine.app "$ZIP"  # the archive now carries the notarization ticket
    echo "Notarized."
  else
    echo "⚠️  Developer ID signature found but no notarytool profile \"$PROFILE\": not notarized."
  fi
fi
swift Resources/update-key.swift sign "$ZIP"      # writes (or replaces) $ZIP.sig
swift Resources/update-key.swift verify "$ZIP"

git add build.sh
git commit -m "Version $VERSION"
git tag -a "v$VERSION" -m "Albumine $VERSION"
git push
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$ZIP.sig" --title "Albumine $VERSION" --notes-file "$NOTES"
echo "✅ Albumine $VERSION published"
