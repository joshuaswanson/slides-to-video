#!/bin/bash
# Builds "Slides to Video.app" as a universal binary and packs it into a DMG in macos/dist/.
# Usage: macos/Packaging/build_dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' ../pyproject.toml)
APP_VERSION=$(sed -n 's/.*packageVersion = "\(.*\)"/\1/p' Sources/SlidesToVideoKit/Speech/WorkerLaunch.swift)
if [ "$VERSION" != "$APP_VERSION" ]; then
    echo "pyproject.toml ($VERSION) and WorkerLaunch.packageVersion ($APP_VERSION) differ" >&2
    exit 1
fi

# Downloaded apps install their worker from the v$VERSION tag on GitHub, so it must exist there
# and point at the commit being built.
TAG_COMMIT=$(git ls-remote origin "refs/tags/v$VERSION^{}" | cut -f1)
if [ -z "$TAG_COMMIT" ]; then
    echo "Tag v$VERSION is not on GitHub. Push it first: git tag -a v$VERSION -m v$VERSION && git push origin v$VERSION" >&2
    exit 1
fi
if [ "$TAG_COMMIT" != "$(git rev-parse HEAD)" ]; then
    echo "Tag v$VERSION points at ${TAG_COMMIT:0:7}, not the checked-out commit $(git rev-parse --short HEAD)" >&2
    exit 1
fi

APP_NAME="Slides to Video"
DIST=dist
APP="$DIST/$APP_NAME.app"
DMG="$DIST/SlidesToVideo-$VERSION.dmg"

swift build -c release --arch arm64 --arch x86_64
PRODUCTS=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/SlidesToVideo" "$APP/Contents/MacOS/SlidesToVideo"
cp -R "$PRODUCTS/SlidesToVideo_SlidesToVideoKit.bundle" "$APP/Contents/Resources/"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>io.github.joshuaswanson.SlidesToVideo</string>
    <key>CFBundleExecutable</key><string>SlidesToVideo</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>github.com/joshuaswanson/slides-to-video</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "$DMG"
