#!/bin/sh
# Ordinary reproducible checks for Plausely (task 01.2).
# Run from the repository root: ./scripts/check.sh
# macOS builds/tests are ad-hoc signed (CODE_SIGN_IDENTITY=-) so Gatekeeper
# never prompts for the locally built app or UI-test runner; iOS simulator
# steps stay unsigned (the simulator does not enforce signatures).
# Distribution signing is a separate phase-10 concern.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== package tests =="
swift test --package-path Packages/PlauselyKit

echo "== macOS Debug build =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-macOS \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- build

echo "== iOS simulator Debug build (iPhone 17) =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build

echo "== macOS UI smoke test =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-macOS \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- test

echo "== iOS simulator UI smoke test (iPhone 17) =="
# Simulator launches flake occasionally ("Busy" preflight); retry once.
if ! xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO test; then
  echo "-- retrying iOS UI smoke test once --"
  xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    CODE_SIGNING_ALLOWED=NO test
fi

echo "== macOS Release build =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-macOS \
  -configuration Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- build

echo "== iOS simulator Release build (generic) =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

echo "ALL CHECKS PASSED"
