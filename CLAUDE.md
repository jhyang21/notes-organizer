# CLAUDE.md — notes-organizer

## What this is

A native SwiftUI iPhone app that turns messy input — a voice ramble, or an
existing Apple Note shared into the app — into a cleanly structured Apple
Note. It organizes; it does not summarize. Apple Notes stays the source of
truth. All AI runs on-device (Apple FoundationModels + SpeechAnalyzer): no
backend, no accounts, no API costs.

Full plan: `C:\Users\1025y\.claude\plans\use-this-product-one-pager-prancy-feigenbaum.md`
(sections: Architecture, Repo layout, Milestones). Read it before starting
any milestone.

## Invariants

- **Never commit an `.xcodeproj`.** The project is generated from
  `project.yml` via XcodeGen — run `xcodegen generate` after any checkout or
  change to `project.yml`. `.xcodeproj` is gitignored.
- **Never commit secrets.** No `.p8` keys, no match passwords, no API
  tokens. CI secrets live in GitHub repo settings only.
- **All shared logic lives in `Packages/NotesOrganizerKit`.** Anything used
  by both the app and the share extension — models, the organizer,
  chunking/merging/sanitizing, renderers — goes in the package, not
  duplicated in `App/` or `ShareExtension/`.
- **Unit tests never call the real FoundationModels model.** CI simulators
  have no Apple Intelligence model available. Model-adjacent code sits
  behind a `NoteOrganizing` protocol with a mock implementation for tests;
  only the mock is exercised in CI.
- Repo is authored on Windows — there is no local Xcode. Everything is
  written as plain text and verified via GitHub Actions
  (`macos-26` runners). Don't assume a local build; push and watch CI.

## Build & test

```sh
xcodegen generate                 # regenerate NotesOrganizer.xcodeproj

# App + extension (no signing, matches CI):
xcodebuild build \
  -project NotesOrganizer.xcodeproj -scheme NotesOrganizer \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

# NotesOrganizerKit unit tests run directly against the package —
# xcodebuild recognizes Package.swift and builds an implicit scheme
# matching the package name, which lets tests target an iOS Simulator
# destination (`swift test` alone only builds for the host/macOS):
cd Packages/NotesOrganizerKit
xcodebuild test -scheme NotesOrganizerKit \
  -destination 'platform=iOS Simulator,name=<discovered at runtime>'
```

See `.github/workflows/ci.yml` for the exact commands CI runs, including how
it discovers a valid simulator name at runtime.

## Milestones

M0 (this skeleton) through M7 are tracked in the plan's Milestones section.
Current state and what's next live there, not here — check it before
picking up work.
