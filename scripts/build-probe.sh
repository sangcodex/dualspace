#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/ModuleCache"
APP="$TASK_ROOT/examples/build/ProfileProbe.app"
if [[ "${DUALSPACE_PROBE_SANDBOX:-0}" == "1" ]]; then
  APP="$TASK_ROOT/examples/build/ProfileProbeSandbox.app"
fi
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" examples/ProfileProbe.swift -o "$APP/Contents/MacOS/ProfileProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.dualspace.probe</string>
<key>CFBundleName</key><string>Profile Probe</string>
<key>CFBundleDisplayName</key><string>Profile Probe</string>
<key>CFBundleExecutable</key><string>ProfileProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :ProbeWorkspaceRoot string $TASK_ROOT/.local" "$APP/Contents/Info.plist"
if [[ "${DUALSPACE_PROBE_SANDBOX:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.dualspace.probe.sandbox' "$APP/Contents/Info.plist"
  ENTITLEMENTS="$TASK_ROOT/examples/build/probe-sandbox-entitlements.plist"
  cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign --force --sign - "$APP"
fi
print "Built $APP"
