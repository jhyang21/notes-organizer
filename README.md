# Notes Organizer

A native SwiftUI iPhone app that turns messy input — a voice ramble, or an
existing Apple Note shared into the app — into a cleanly structured Apple
Note. It organizes; it does not summarize. Apple Notes stays the source of
truth. The AI runs in the cloud — OpenAI, reached through a Supabase edge
function we own — so there are no accounts to make, but there is a backend
and there are API costs. A RevenueCat subscription pays for them.

## How it works

Speak into the app, or share an Apple Note (or any text) into it from the
share sheet. A recording is uploaded to the edge function and transcribed by
Whisper; text shared in skips that step. Either way a GPT model turns the
text into a title, sections with bullets, and action items, and the app
shows a preview. Saving shares the note as plain text: the share sheet, then
Notes, then its Save button — headings and checkboxes arrive as text lines.

The free plan allows five tidies a calendar month, counted on the server
against an anonymous per-install identifier. TidyNote Pro lifts the cap.

## Architecture

The app (`App/`) and the share extension (`ShareExtension/`) are two thin
targets that both sit on top of `Packages/NotesOrganizerKit`, a Swift
package holding everything they share: the note model, the cloud client,
plain-text rendering, and the SwiftUI preview and save-actions views. Anything used by both
targets lives in the package rather than being duplicated. The cloud client
sits behind a `NoteOrganizing` protocol and takes an injected `Transport`,
so the unit test suite runs on CI without touching the network.

The server side lives in `supabase/functions/tidynote_organize`: one edge
function that holds the OpenAI key, counts the month's tidies, rate-limits
by IP hash, and returns the organized note.

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
