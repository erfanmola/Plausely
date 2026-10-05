# Plausely

Native iOS and macOS dashboard client for Plausible Community Edition.
One Swift codebase: two SwiftUI shells (`Apps/`) over a local package
(`Packages/PlauselyKit` with `AnalyticsCore`, `PlausibleClient`, `DashboardUI`).

Status: project bootstrap only. No dashboard implementation yet; all analytics
behavior lands in later phases against verified server contracts.

## Build (unsigned local builds)

```sh
./scripts/check.sh
```

Requires Xcode 27 with iOS 17 / macOS 14 SDKs. See `scripts/check.sh` for the
exact verified commands.
