#!/bin/sh
# Installs ID Fit into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/joshuan/id-fit/main/install.sh | sh
#
# Pin a version with IDFIT_VERSION=v1.2.3.
#
# Fetching with curl rather than a browser is the point: a browser marks its
# downloads as quarantined, and macOS refuses to open a quarantined app that
# Apple has not notarized. Files fetched with curl carry no such mark.
set -eu

REPO="joshuan/id-fit"
VERSION="${IDFIT_VERSION:-latest}"

if [ "$(uname -s)" != "Darwin" ]; then
	echo "ID Fit runs on macOS only." >&2
	exit 1
fi

if [ "$VERSION" = "latest" ]; then
	url="https://github.com/$REPO/releases/latest/download/IdFit.zip"
else
	url="https://github.com/$REPO/releases/download/$VERSION/IdFit.zip"
fi

dest="/Applications"
if [ ! -w "$dest" ]; then
	dest="$HOME/Applications"
	mkdir -p "$dest"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $url"
curl -fsSL "$url" -o "$tmp/IdFit.zip"
ditto -x -k "$tmp/IdFit.zip" "$tmp"

app="$tmp/IdFit.app"
if [ ! -d "$app" ]; then
	echo "The archive did not contain IdFit.app." >&2
	exit 1
fi

# A broken signature is what makes macOS call an app damaged, so it is worth
# knowing about before the copy rather than after.
codesign --verify "$app" 2>/dev/null || echo "Warning: the signature did not verify."

# Nothing here should be quarantined, but a proxy or a mirrored copy can add
# the flag, and clearing it costs nothing.
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

if [ -d "$dest/IdFit.app" ]; then
	echo "Replacing $dest/IdFit.app"
	rm -rf "$dest/IdFit.app"
fi
ditto "$app" "$dest/IdFit.app"

# Registers the Services entry and "Open With" straight away instead of waiting
# for macOS to notice the new bundle.
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$lsregister" ]; then
	"$lsregister" -f "$dest/IdFit.app" || true
fi

echo "Installed $dest/IdFit.app"
echo "Open it with: open -a \"$dest/IdFit.app\""
