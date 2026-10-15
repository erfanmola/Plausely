# Contributing

## One command

```sh
./scripts/check.sh
```

Everything must stay green: package tests, both Debug builds, both UI
suites, both Release builds. UI suites run in deterministic mock mode
(`-plausely-mock-sites`); they never touch a real server.

During development, verify only what changed: package tests for the
touched target plus builds of the affected apps. The full gate stays
for pre-commit and release checks, not every small edit.

## Rules that keep parity honest

- **Server output wins.** Every value, column, label, and interaction must
  match the pinned Plausible CE dashboard for the same query. Display
  rounding is the only tolerance. Never sum uniques, never invent zeros
  for nulls, never bridge chart gaps.
- **Unknown transport is a blocker, not a guess.** If an endpoint shape is
  unverified, stop and say so. No fabricated schemas, no silent fallbacks
  between dashboard and public API paths.
- **One task, one area.** Keep diffs scoped: contracts, client, one report
  family, or one platform surface at a time. The Xcode project file has a
  single owner per change — never merge competing project edits.
- **No secrets in git.** Session material, captures, and passwords never
  enter the repository. Fixtures must be synthetic and reviewed.
- **Accessibility is a feature.** Every report keeps an inspectable,
  VoiceOver-reachable equivalent. Direction is never color-only.

## Commit hygiene

Stage explicit paths (`git add` by name, never `git add .`), inspect the
full diff before committing, and write ordinary intent-based messages.
No assistant attribution or generated-by trailers — ever.
