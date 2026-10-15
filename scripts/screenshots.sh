#!/bin/sh
# Refresh the iOS README screenshots against deterministic mock data.
# The screenshot test always writes to /tmp (xcodebuild sanitizes the
# test runner's environment); this script runs it and moves the captures
# into assets/. Simulator-only: never touches the real screen.
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

xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:PlauselyiOSUITests/ScreenshotTests/testReadmeScreenshots test

mv /tmp/screenshot-ios-overview.png /tmp/screenshot-ios-breakdowns.png assets/
echo "screenshots refreshed in assets/"
