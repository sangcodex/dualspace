#!/bin/zsh
# Build a portable release without replacing the local development app.
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
./scripts/check-privacy.sh
mkdir -p "$TASK_ROOT/dist"
DMG_STAGE="$(mktemp -d "$TASK_ROOT/dist/.dmg.XXXXXX")"
DMG_CONTENTS="$DMG_STAGE/image"
MOUNT_POINT="$DMG_STAGE/mount"
USE_DISKUTIL=0
if diskutil image create from --help >/dev/null 2>&1; then
    USE_DISKUTIL=1
fi
detach_image() {
    if (( USE_DISKUTIL )); then
        diskutil eject "$MOUNT_POINT" >/dev/null
    else
        hdiutil detach "$MOUNT_POINT" -quiet
    fi
}
cleanup() {
    if [[ -d "$MOUNT_POINT" ]] && [[ "$(stat -f %d "$MOUNT_POINT")" != "$(stat -f %d "$DMG_STAGE")" ]]; then
        if ! detach_image; then
            print -u2 -- "Could not detach $MOUNT_POINT; staging files retained."
            return
        fi
    fi
    rm -rf "$DMG_STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DUALSPACE_BUILD_MODE=release DUALSPACE_STANDARD_STORAGE=1 DUALSPACE_OUTPUT_DIR="$DMG_CONTENTS" ./scripts/build.sh
APP="$DMG_CONTENTS/DualSpace.app"
APP_PLIST="$APP/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :DualSpaceWorkspace' "$APP_PLIST" >/dev/null 2>&1; then
    print -u2 'Distribution app contains a development workspace setting.'
    exit 1
fi
scan_result=0
rg --text --quiet --hidden --no-ignore -e '(/Users|/home)/[[:alnum:]_.-]+/' -- "$APP" || scan_result=$?
if (( scan_result != 1 )); then
    print -u2 'Distribution app failed the private-path scan. No image was published.'
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/DualSpace")"
LAUNCHER_ARCHS="$(lipo -archs "$APP/Contents/Resources/DualSpaceLauncher")"
if [[ "$APP_ARCHS" != "$LAUNCHER_ARCHS" ]]; then
    print -u2 'App and launcher architectures do not match.'
    exit 1
fi
ARCH_LABEL="${APP_ARCHS// /-}"
DMG_NAME="DualSpace-$VERSION-$ARCH_LABEL.dmg"
ln -s /Applications "$DMG_CONTENTS/Applications"
print 'Creating compressed disk image...'
if (( USE_DISKUTIL )); then
    diskutil image create from --format UDZO --volumeName DualSpace "$DMG_CONTENTS" "$DMG_STAGE/$DMG_NAME"
else
    hdiutil create -volname DualSpace -srcfolder "$DMG_CONTENTS" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 -nospotlight -srcowners off "$DMG_STAGE/$DMG_NAME"
fi
print 'Verifying disk image...'
hdiutil verify -quiet "$DMG_STAGE/$DMG_NAME"
mkdir -p "$MOUNT_POINT"
if (( USE_DISKUTIL )); then
    diskutil image attach --readOnly --nobrowse --mountPoint "$MOUNT_POINT" "$DMG_STAGE/$DMG_NAME"
else
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_STAGE/$DMG_NAME"
fi
codesign --verify --deep --strict "$MOUNT_POINT/DualSpace.app"
cmp "$APP_PLIST" "$MOUNT_POINT/DualSpace.app/Contents/Info.plist"
[[ "$(readlink "$MOUNT_POINT/Applications")" == /Applications ]]
detach_image
(
    cd "$DMG_STAGE"
    shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)
mv -f "$DMG_STAGE/$DMG_NAME" "$TASK_ROOT/dist/$DMG_NAME"
mv -f "$DMG_STAGE/$DMG_NAME.sha256" "$TASK_ROOT/dist/$DMG_NAME.sha256"
print -r -- "Packaged $TASK_ROOT/dist/$DMG_NAME"
print -r -- "Checksum $TASK_ROOT/dist/$DMG_NAME.sha256"
print 'Verified read-only image, app signature, architecture and portable storage configuration.'
