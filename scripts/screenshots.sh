#!/bin/sh
# Refresh the iOS README screenshots against deterministic mock data.
# The screenshot test always writes to /tmp (xcodebuild sanitizes the
# test runner's environment); this script runs it and moves the captures
# into assets/. Simulator-only: never touches the real screen.
# Run from the repository root: ./scripts/screenshots.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:PlauselyiOSUITests/ScreenshotTests/testReadmeScreenshots test

mv /tmp/screenshot-ios-overview.png /tmp/screenshot-ios-breakdowns.png assets/
echo "screenshots refreshed in assets/"
