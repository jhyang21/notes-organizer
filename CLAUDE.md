# CLAUDE.md — notes-organizer

## What this is

A native SwiftUI iPhone app that turns messy input — a voice ramble, or an
existing Apple Note shared into the app — into a cleanly structured Apple
Note. It organizes; it does not summarize. Apple Notes stays the source of
truth. The AI runs in the cloud: the app uploads the recording or the shared
text to a Supabase edge function (`supabase/functions/tidynote_organize`),
which calls OpenAI for transcription and organizing and returns the note.
The backend shares the `relora-prod` Supabase project, with every object
prefixed `tidynote_`. There are no accounts — installs are identified by an
anonymous `tidy:<UUID>` — and RevenueCat carries subscription status.

The architecture is the repo layout: `App/` (the app), `ShareExtension/`
(the appex), `Widgets/` (the widget and the Control Center control, both
deep-linking `tidynote://` into the app),
`Packages/NotesOrganizerKit/` (everything they share),
`supabase/functions/tidynote_organize/` (the edge function), `fastlane/` and
`.github/workflows/` (the pipeline), `docs/appstore/` (listing copy and
review notes).

## Invariants

- **Never commit an `.xcodeproj`.** The project is generated from
  `project.yml` via XcodeGen — run `xcodegen generate` after any checkout or
  change to `project.yml`. `.xcodeproj` is gitignored.
- **Never commit secrets.** No `.p8` keys, no match passwords, no API
  tokens. CI secrets live in GitHub repo settings only.
- **All shared logic lives in `Packages/NotesOrganizerKit`.** Anything used
  by both the app and the share extension — models, the organizer,
  the sanitizer, renderers — goes in the package, not
  duplicated in `App/` or `ShareExtension/`.
- **Kit tests never touch the network — cloud calls go through an injected
  `Transport`.** `CloudOrganizer` takes a `Transport` closure
  (`(URLRequest) -> (Data, URLResponse)`); tests hand it a stub and assert
  on the request they get. The organizer sits behind a `NoteOrganizing`
  protocol so callers can be tested against a mock too. Nothing in CI
  reaches a real endpoint or spends a token.
- Repo is authored on Windows — there is no local Xcode. Everything is
  written as plain text and verified via GitHub Actions
  (`macos-26` runners). Don't assume a local build; push and watch CI.

## Edge function

`supabase/functions/tidynote_organize/organize.ts` holds the OpenAI call:
the strict JSON schema, request building, parsing and the server-side
sanitizer. It must stay import-safe (no top-level side effects, no env
reads) because the tests and the smoke set import it. `prompt.ts` is a
`PROMPTS` map keyed by version; `PROMPT_VERSION` picks the one in
production. `docs/ai/note-behavior.md` is the spec every prompt is written
from: note kinds, transformation levels, rules, the redundancy budget.

- **Do not change a prompt without running the smoke set** in
  `supabase/functions/tidynote_organize/smoke/` (live, about $0.05 a run)
  and reading every output against its watch line.
- Tests: `deno test --allow-net --allow-env supabase/functions/tidynote_organize/`
  (dependency-injected, no network). CI runs them on Ubuntu.
- Deploy: `npx supabase functions deploy tidynote_organize --project-ref qcooviiralmdnfvbrtae`
  from the repo root. Deploy only this function; the project is shared with
  Relora. Send one warm-up request after a schema change: the strict-schema
  grammar compiles on first use.

## Build & test

```sh
xcodegen generate                 # regenerate NotesOrganizer.xcodeproj

# App + extension (no signing, matches CI):
xcodebuild build \
  -project NotesOrganizer.xcodeproj -scheme NotesOrganizer \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

# App-layer tests (NotesOrganizerTests, hosted by the app):
xcodebuild test \
  -project NotesOrganizer.xcodeproj -scheme NotesOrganizer \
  -destination 'platform=iOS Simulator,name=<discovered at runtime>' \
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

## TestFlight pipeline

`fastlane` (Gemfile, `fastlane/Appfile`, `fastlane/Matchfile`,
`fastlane/Fastfile`) builds and uploads a beta via the `beta` lane:
`setup_ci` → `app_store_connect_api_key` → `match` (readonly: false) →
`build_app` (build number from `CURRENT_PROJECT_VERSION` xcarg, since
`xcodegen generate` would clobber an `agvtool`-set version) →
`upload_to_testflight`.

`.github/workflows/testflight.yml` runs this lane on every push to main
(and via `gh workflow run testflight.yml`). Build number =
`github.run_number`.

Required repo secrets (GitHub → Settings → Secrets and variables →
Actions), all set 2026-08-08: `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_KEY_P8_BASE64` (the App Store Connect API key, base64-encoded),
`MATCH_PASSWORD`, `MATCH_GIT_TOKEN` (a PAT scoped to the certificates
repo below).

Certificates and provisioning profiles live in a separate private repo,
`https://github.com/jhyang21/ios-certificates`, managed
headlessly by fastlane `match` — nothing there is created or edited by
hand. Since 2026-09-01 that repo is **shared with the Relora iOS app**
(`jhyang21/relora-ios`): both pipelines use the team's one Apple
Distribution certificate. A `match nuke` or a `MATCH_PASSWORD` rotation
here breaks both apps.

`match` mints profiles; it does not create App IDs with capabilities. A
new target's bundle ID has to be registered in the developer portal
first, with whatever capabilities its entitlements claim, or the next
`beta` run fails on that ID.

No `Gemfile.lock` is committed (see the Gemfile's own comment for why);
CI runs a plain `bundle install`.

## History

M0 through M7 built the MVP, M8 onward moved it to the cloud and to the App
Store. There is no milestone document: `git log` is the record. Read the
recent commits before picking up work.
