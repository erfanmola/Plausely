#!/bin/sh
# Refresh the README screenshots against deterministic mock data.
# iOS + watchOS steps are simulator-only and never touch the real screen.
# The macOS step drives the real screen (like the macOS UI suite), so it is
# opt-in with PLAUSLEY_MAC_UI=1.
# Run from the repository root: ./scripts/screenshots.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIM_NAME="$(xcrun simctl list devices -j | python3 -c '
import json, sys
found = None
for devices in json.load(sys.stdin).get("devices", {}).values():
    for d in devices:
        if d.get("isAvailable", False) and d.get("name", "").startswith("iPhone"):
            if d["name"] == "iPhone 17":
                print(d["name"])
                sys.exit(0)
            found = found or d["name"]
if found:
    print(found)
else:
    print("iPhone 17")
' 2>/dev/null)"

echo "== iOS screenshots =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:PlauselyiOSUITests/ScreenshotTests/testReadmeScreenshots test

mv /tmp/screenshot-ios-overview.png /tmp/screenshot-ios-breakdowns.png assets/
echo "iOS screenshots refreshed in assets/"

if [ "${PLAUSLEY_MAC_UI:-0}" = "1" ]; then
  echo "== macOS screenshot =="
  # The mac test runner is sandboxed, so the shot travels as an attachment;
  # export it from the newest result bundle (xcresulttool writes the
  # attachment bytes plus a manifest.json).
  RESULT_DIR="$(mktemp -d)"
  xcodebuild -project Plausely.xcodeproj -scheme Plausely-macOS \
    -destination 'platform=macOS' \
    -only-testing:PlauselyMacOSUITests/ScreenshotTests/testReadmeScreenshot test \
    -resultBundlePath "$RESULT_DIR/mac.xcresult"
  xcrun xcresulttool export attachments --path "$RESULT_DIR/mac.xcresult" --output-path "$RESULT_DIR/out"
  # Attachments export under UUID filenames; the manifest maps
  # suggestedHumanReadableName back to our stable shot name.
  MAC_PNG="$(python3 -c '
import json, sys
manifest = json.load(open(sys.argv[1]))
for suite in manifest:
    for a in suite.get("attachments", []):
        if "screenshot-macos-overview" in a.get("suggestedHumanReadableName", ""):
            print(sys.argv[2] + "/" + a["exportedFileName"])
            sys.exit(0)
' "$RESULT_DIR/out/manifest.json" "$RESULT_DIR/out")"
  mv "$MAC_PNG" assets/screenshot-macos-overview.png
  rm -rf "$RESULT_DIR"
  echo "macOS screenshot refreshed in assets/"
else
  echo "-- macOS screenshot skipped (set PLAUSLEY_MAC_UI=1; it takes over the screen) --"
fi

echo "== watchOS screenshots =="
WATCH_NAME="$(xcrun simctl list devices -j | python3 -c '
import json, sys
found = None
for devices in json.load(sys.stdin).get("devices", {}).values():
    for d in devices:
        if d.get("isAvailable", False) and "Watch" in d.get("name", ""):
            if "Series 12" in d["name"]:
                print(d["name"])
                sys.exit(0)
            found = found or d["name"]
if found:
    print(found)
else:
    print("Apple Watch Series 12 (42mm)")
' 2>/dev/null)"
WATCH_UDID="$(xcrun simctl list devices -j | python3 -c '
import json, sys
want = sys.argv[1]
for devices in json.load(sys.stdin).get("devices", {}).values():
    for d in devices:
        if d.get("name") == want:
            print(d["udid"])
            sys.exit(0)
' "$WATCH_NAME")"
xcodebuild -project Plausely.xcodeproj -scheme Plausely-watchOS \
  -configuration Debug -destination "platform=watchOS Simulator,name=$WATCH_NAME" \
  CODE_SIGNING_ALLOWED=NO build
xcrun simctl boot "$WATCH_UDID" 2>/dev/null || true
WATCH_APP="$(find ~/Library/Developer/Xcode/DerivedData/Plausely-*/Build/Products/Debug-watchsimulator -maxdepth 1 -name 'PlauselyWatch.app' 2>/dev/null | head -n 1)"
xcrun simctl install "$WATCH_UDID" "$WATCH_APP"
# Sites list (mock, no phone needed). Terminate first so launch args apply
# to a fresh process (simctl foregrounds a running app otherwise).
xcrun simctl terminate "$WATCH_UDID" ir.developex.Plausely.watchapp 2>/dev/null || true
xcrun simctl launch "$WATCH_UDID" ir.developex.Plausely.watchapp -plausely-mock >/dev/null
sleep 4
xcrun simctl io "$WATCH_UDID" screenshot assets/screenshot-watch-sites.png
# Detail with chart (mock deep-link; simctl cannot tap). The -plausely-watch-shot
# hook scrolls the chart into the fold for the capture.
xcrun simctl terminate "$WATCH_UDID" ir.developex.Plausely.watchapp 2>/dev/null || true
xcrun simctl launch "$WATCH_UDID" ir.developex.Plausely.watchapp -plausely-mock -plausely-watch-site alpha-1.example.com -plausely-watch-shot >/dev/null
sleep 5
xcrun simctl io "$WATCH_UDID" screenshot assets/screenshot-watch-detail.png
xcrun simctl shutdown "$WATCH_UDID" 2>/dev/null || true
echo "watchOS screenshots refreshed in assets/"
