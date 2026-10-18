#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
BUILD_MODE="${DUALSPACE_BUILD_MODE:-release}"
BUILD_OUTPUT="${DUALSPACE_OUTPUT_DIR:-$TASK_ROOT/dist}"
BUILD_OUTPUT="${BUILD_OUTPUT:A}"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c "$BUILD_MODE" -debug-info-format none
mkdir -p "$BUILD_OUTPUT"
PACKAGE_STAGE="$(mktemp -d "$BUILD_OUTPUT/.package.XXXXXX")"
APP="$PACKAGE_STAGE/DualSpace.app"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$BUILD_MODE/DualSpace" "$APP/Contents/MacOS/DualSpace"
cp ".build/$BUILD_MODE/DualSpaceLauncher" "$APP/Contents/Resources/DualSpaceLauncher"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.dualspace.manager</string>
<key>CFBundleName</key><string>DualSpace</string>
<key>CFBundleDisplayName</key><string>DualSpace</string>
<key>CFBundleExecutable</key><string>DualSpace</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>CFBundleIconFile</key><string>DualSpace.png</string>
</dict></plist>
PLIST
if [[ "${DUALSPACE_STANDARD_STORAGE:-0}" != "1" ]]; then
    /usr/libexec/PlistBuddy -c "Add :DualSpaceWorkspace string ${DUALSPACE_HOME:-$TASK_ROOT/.local}" "$APP/Contents/Info.plist"
fi
swift scripts/make-icon.swift "$APP/Contents/Resources/DualSpace.png"
codesign --force --sign - --options runtime --timestamp=none "$APP/Contents/Resources/DualSpaceLauncher"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
FINAL_APP="$BUILD_OUTPUT/DualSpace.app"
PREVIOUS_APP="$BUILD_OUTPUT/.DualSpace-previous-$$.bundle"
if [[ -d "$FINAL_APP" ]]; then
    mv "$FINAL_APP" "$PREVIOUS_APP"
fi
if mv "$APP" "$FINAL_APP"; then
    if [[ -d "$PREVIOUS_APP" ]]; then rm -rf "$PREVIOUS_APP"; fi
else
    if [[ -d "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$FINAL_APP"; fi
    exit 1
fi
print "Built $FINAL_APP"
