# Notes Organizer

A native SwiftUI iPhone app that turns messy input — a voice ramble, or an
existing Apple Note shared into the app — into a cleanly structured Apple
Note. It organizes; it does not summarize. Apple Notes stays the source of
truth. Everything runs on-device (Apple FoundationModels for organizing,
SpeechAnalyzer for transcription): no backend, no accounts, no API costs.

## How it works

Speak into the app, or share an Apple Note (or any text) into it from the
share sheet. The on-device model turns that text into a title, sections with
bullets, and action items, and shows a preview. Saving hands Apple Notes a
Markdown file, which Notes imports as real rich text — headings, bullets,
and checkboxes all survive.

## Architecture

The app (`App/`) and the share extension (`ShareExtension/`) are two thin
targets that both sit on top of `Packages/NotesOrganizerKit`, a Swift
package holding everything they share: the note model, the organizer and
its prompt, transcript chunking and merging, Markdown/plain-text rendering,
and the SwiftUI preview and save-actions views. Anything used by both
targets lives in the package rather than being duplicated. Model-adjacent
code sits behind a `NoteOrganizing` protocol with a mock implementation, so
the unit test suite runs on CI without a real on-device model.

## Building

This repo is authored on Windows — there's no local Xcode, and the
`.xcodeproj` is generated from `project.yml` via XcodeGen and never
committed. See `CLAUDE.md` for exact build/test commands and the
invariants that keep the project buildable without a Mac in hand.

## CI and TestFlight

Every push runs `.github/workflows/ci.yml` on a `macos-26` runner: it
generates the Xcode project, builds the app and share extension unsigned,
and runs the `NotesOrganizerKit` test suite. Every push to `main` that
passes CI also triggers `.github/workflows/testflight.yml`, which uses
fastlane to sign, build, and upload a new TestFlight beta. Details on the
fastlane lane and required secrets are in `CLAUDE.md`.

## More

`CLAUDE.md` is the source of truth for invariants, build commands, and the
TestFlight pipeline. The full product plan (architecture, repo layout,
milestones) lives outside this repo — see the pointer at the top of
`CLAUDE.md`.
