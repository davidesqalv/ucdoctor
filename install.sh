#!/bin/bash
# Build UC Doctor, install it to ~/Applications, and start it now and at every login.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Swift isn't installed. Run: xcode-select --install   (then run ./install.sh again)"
    exit 1
fi

LABEL="io.github.davidesqalv.ucdoctor" # matches CFBundleIdentifier in Info.plist
APP="$HOME/Applications/UC Doctor.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

swift build -c release
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ucdoctor 2>/dev/null || true # any copy started by hand

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HOME/Library/LaunchAgents"
cp .build/release/ucdoctor "$APP/Contents/MacOS/ucdoctor"
cp Info.plist "$APP/Contents/Info.plist"
rm -rf build/AppIcon.iconset
.build/release/ucdoctor make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ucdoctor</string><string>--background</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"
touch "$APP" # refresh the Dock/Finder icon cache
sleep 1
open "$APP" # bring up the window on the copy launchd just started
echo "UC Doctor is running. Close the window and it keeps logging; click its Dock icon to reopen."
echo "Event log: ~/Library/Logs/UC Doctor/events.log"
echo "CLI:       \"$APP/Contents/MacOS/ucdoctor\" status | watch | kick [--hard]"
echo "Remove:    ./uninstall.sh"
