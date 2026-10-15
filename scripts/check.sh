#!/bin/sh
# Ordinary reproducible checks for Plausely (task 01.2).
# Run from the repository root: ./scripts/check.sh
# macOS steps use the project's automatic development signing: the app and
# widget share Keychain/app-group entitlements, which ad-hoc signing cannot
# satisfy. iOS simulator steps stay unsigned (the simulator does not enforce
# signatures). Distribution signing is a separate phase-10 concern.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIM_NAME="iPhone 17"

# Simulator devices are machine-local state: a fresh checkout has runtimes
# but no devices, so the iOS steps would fail with "unable to find a
# device". Heal that here: reuse any available iPhone simulator when one
# exists (never multiply devices), else create one "iPhone 17" from the
# newest installed iOS runtime (preferring the iPhone 17 profile, falling
# back to 16 Pro where the installed runtime predates the 17 hardware).
ensure_simulator() {
  existing="$(xcrun simctl list devices -j | python3 -c '
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
' 2>/dev/null)"
  if [ -n "$existing" ]; then
    if [ "$existing" != "$SIM_NAME" ]; then
      echo "-- reusing simulator '$existing' --"
      SIM_NAME="$existing"
    fi
    return 0
  fi
  echo "-- creating '$SIM_NAME' simulator --"
  runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
candidates = [r for r in json.load(sys.stdin).get("runtimes", [])
              if r.get("name", "").startswith("iOS") and r.get("isAvailable", False)]
candidates.sort(key=lambda r: [int(p) for p in str(r.get("version", "0")).split(".")])
print(candidates[-1]["identifier"])
')"
  for type in iPhone-17 iPhone-16-Pro; do
    id="com.apple.CoreSimulator.SimDeviceType.$type"
    if udid="$(xcrun simctl create "$SIM_NAME" "$id" "$runtime" 2>/dev/null)"; then
      echo "-- simulator ready: $SIM_NAME ($type) $udid --"
      return 0
    fi
  done
  echo "error: could not create an iPhone simulator" >&2
  return 1
}

ensure_simulator

echo "== package tests =="
swift test --package-path Packages/PlauselyKit

echo "== macOS Debug build =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-macOS \
  -configuration Debug -destination 'platform=macOS' \
  build

echo "== iOS simulator Debug build (...) =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -configuration Debug -destination "platform=iOS Simulator,name=$SIM_NAME" \
  CODE_SIGNING_ALLOWED=NO build

echo "== macOS UI smoke test =="
# The macOS suite drives the real screen and steals focus, so it never
# runs unattended: opt in with PLAUSLEY_MAC_UI=1 (CI sets it).
if [ "${PLAUSLEY_MAC_UI:-0}" = "1" ]; then
  xcodebuild -project Plausely.xcodeproj -scheme Plausely-macOS \
    -destination 'platform=macOS' test
else
  echo "-- skipped (set PLAUSLEY_MAC_UI=1 to run; it takes over the screen) --"
fi

echo "== iOS simulator UI smoke test (...) =="
# Simulator launches flake occasionally ("Busy" preflight); retry once.
if ! xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  CODE_SIGNING_ALLOWED=NO test; then
  echo "-- retrying iOS UI smoke test once --"
  xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
    -destination "platform=iOS Simulator,name=$SIM_NAME" \
    CODE_SIGNING_ALLOWED=NO test
fi

echo "== macOS Release build =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-macOS \
  -configuration Release -destination 'platform=macOS' \
  build

echo "== iOS simulator Release build (generic) =="
xcodebuild -project Plausely.xcodeproj -scheme Plausely-iOS \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

echo "ALL CHECKS PASSED"
