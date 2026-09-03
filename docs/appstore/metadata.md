# App Store listing — TidyNote 1.0.0

The record of what is set in App Store Connect for app `6799307936`
(`com.immform.notesorganizer`, platform iOS). Edit here first, then push to ASC
so the two never drift.

## Names and URLs

| Field | Value | Limit |
|---|---|---|
| App name | `TidyNote - Notes Organizer` | 30 |
| Subtitle | `Voice memo to clean outline` | 30 |
| Support URL | `https://jhyang21.github.io/notes-organizer/` | — |
| Marketing URL | `https://jhyang21.github.io/notes-organizer/` | — |
| Privacy Policy URL | `https://jhyang21.github.io/notes-organizer/privacy.html` | — |
| Terms of Use URL | `https://jhyang21.github.io/notes-organizer/terms.html` | — |
| Copyright | `2026 immForm` | — |
| Age rating | 4+ (no objectionable content of any kind) | — |
| Primary category | Productivity | — |

Name and subtitle live on the `appInfoLocalization`; the URLs above live on the
`appStoreVersionLocalization`, except the privacy policy URL, which lives on the
`appInfoLocalization`.

## Pushing to App Store Connect

`scripts/asc_metadata.py` pushes the promotional text, keywords, description
and App Review notes below to the objects listed at the end of this file. It
reads the fenced blocks here, PATCHes only the fields that differ, then reads
each one back and stops unless the live value is byte-identical. Set
`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the path to the `.p8` key) and
run `check` first, then `push`. The `review-screenshots` command replaces the
two subscription review screenshots. Name and subtitle change rarely and are
still edited by hand.

## Promotional text (170 max)

```
Ramble into your phone and get a clean note back: a title, the structure it needs, and your to-dos as a checklist. Every fact, name, number, and date you said stays in.
```

## Keywords (100 max, comma-separated, no spaces)

```
dictation,transcribe,speech,bullets,structure,format,meeting,ideas,brain dump,audio,journal,recorder
```

Apple indexes the name, the subtitle, and this field together, so a word in any
one of them is wasted in the others. Nothing here repeats tidy, note, notes, or
organizer (from the name), or voice, memo, clean, or outline (from the
subtitle). The subtitle was rewritten for the same reason: the earlier "Tidy up
messy notes fast" spent its 30 characters on words the name already carried.

## Description (4000 max)

```
Talk it out. Get a clean note.

TidyNote takes a voice ramble - or a messy note you already have - and turns it into a note you can actually read: a title, only the structure the note needs, and the to-dos you gave yourself as a checklist. A list stays a list, a journal entry stays in your words, and a Wi-Fi password stays exactly as you typed it.

It organizes. It does not summarize. Every fact, name, number, and date you said stays in the note. Nothing gets compressed into a tidy little paragraph that quietly drops the thing you needed.

HOW IT WORKS

Record a thought. TidyNote turns your speech into text, then structures it. Save the finished note to Apple Notes, copy it, or share it anywhere.

Already have a mess of a note? Share it into TidyNote from the share sheet - from Apple Notes or any app that shares text - and get it back organized.

WHAT IT IS GOOD FOR

- Thinking out loud on a walk and keeping the whole thought
- Meeting notes you typed too fast to punctuate
- A brain dump at 1 a.m. that needs to make sense in the morning
- Long voice memos you never go back and listen to
- Old notes that grew into a wall of text

PRIVACY

Every tidy runs on our servers. Your recording, or the text you share in, goes over an encrypted connection to be turned into text and organized, and it isn't kept once the note comes back. The app asks before it sends anything the first time, and you can say no.

There is no account, no sign-up, and no tracking. Nothing you save is stored by us - finished notes go where you send them.

FREE AND PRO

Five tidies a month free. TidyNote Pro makes them unlimited: $4.99 a month or $39.99 a year, with a 7-day free trial. Payment is charged to your Apple Account at confirmation of purchase, and the subscription renews automatically unless you turn off auto-renew at least 24 hours before the period ends. Manage or cancel it in Settings on your iPhone, under your name then Subscriptions.

REQUIREMENTS

iPhone running iOS 17 or later.

Privacy Policy: https://jhyang21.github.io/notes-organizer/privacy.html
Terms of Use: https://jhyang21.github.io/notes-organizer/terms.html
```

The subscription sentence in "FREE AND PRO" is required by Apple's paid-app
metadata rules: length of subscription, price, and a link to the terms must all
appear in the description.

## App Review notes

```
NO ACCOUNT - NOTHING TO DEMO-LOGIN
TidyNote has no sign-up, no login, and no password. Please leave the demo account fields empty. On first launch the app generates a random anonymous identifier ("tidy:<UUID>") and uses it only to count tidies and look up subscription status. It is not tied to a name, email, device identifier, or advertising identifier.

EVERY TIDY IS A SERVER CALL
Nothing is organized offline. The app records audio, uploads it over HTTPS, and our provider turns it into text and organizes it; the note comes back to the phone. Shared text takes the same route without transcription. We store neither the recording nor the text. The free plan's 5-tidies-a-month cap is enforced on the server, which returns HTTP 429 on the 6th tidy; the app then shows the "You've used this month's tidies" screen with the TidyNote Pro upsell. The review device needs a network connection.

HOW TO TEST A SUBSCRIPTION IN SANDBOX
1. Tap the gear icon (top right) to reach Settings.
2. Tap "Go Pro" and buy either product with a sandbox Apple Account; the 7-day trial applies. Settings now reads "TidyNote Pro" with "Tidies are unlimited."
3. Record a short voice note (or share text in, see below) and let it finish.
4. "Restore Purchases" re-applies the entitlement; "Manage Subscription" opens the system sheet in place.
Without purchasing, Settings and the capture screen both show the tidies left this month, dropping by one per tidy.

DIAGNOSTICS IS HIDDEN
Settings ends with a version line; tapping it five times reveals a Diagnostics row - an on-device log for TestFlight testers. It never leaves the device and is not part of the product.

SHARE EXTENSION
TidyNote appears in the iOS share sheet for text. Open the app once first - a one-time screen explains what gets sent and asks you to agree; the extension works only after that. Share a note from Apple Notes (switch its share sheet from Collaborate to Send Copy) or selected text from any app, choose TidyNote, and the organized version appears. It never writes back to the shared note: "Save to Apple Notes" saves the result as a new note. There is no purchase UI - StoreKit purchases are not viable in a share extension - so a spent quota says "Open TidyNote to go Pro", or offers a button that opens the app on hosts that allow it. The app's home screen has a "Tidy an Existing Note" button that teaches this flow, since Apple Notes has no read API and the share sheet is the only way in.

WIDGET, CONTROL, AND SIRI SHORTCUT
All three just open the app with "tidynote://record", which starts a recording once the app is on screen; none of them record anything themselves or touch any data. To test: add the "Start a Tidy" widget to the Home or Lock Screen and tap it; on iOS 18, add the "Start a Tidy" control in Control Center; or say "Start a tidy in TidyNote" to Siri. A tap during a recording or upload is ignored on purpose; the app just comes to the front.

MICROPHONE PERMISSION
Requested only when the user taps record. The recording IS uploaded: it goes over HTTPS to our provider, which transcribes and organizes it. Neither we nor the app keep it, and the provider holds it only for abuse monitoring, about 30 days.

BACKGROUND AUDIO MODE
Declared for one reason: to keep a recording running when the user locks the phone or switches apps mid-sentence. Nothing records unless the user taps the microphone first, and a recording stops itself after ten seconds of silence or five minutes. There is no playback, no listening at launch, and no background activity once the recording ends; nothing uploads in the background - a recording that ends there waits until the user returns and taps Send. To see it: tap record, lock the phone, keep talking, then unlock - what was said while locked is in the recording.

PRIVACY POLICY
https://jhyang21.github.io/notes-organizer/privacy.html names our sub-processors and their retention periods, for audio and for text. The app's own copy avoids vendor names; the policy does not.
```

## App Privacy (nutrition labels)

Set in App Store Connect under App Privacy. Nothing is used for tracking, and
nothing is linked to the user's identity.

| Data type | Collected | Purpose | Linked to identity | Tracking |
|---|---|---|---|---|
| User Content (audio data — the recording, uploaded for every voice tidy) | Yes | App Functionality | No | No |
| User Content (other user content — the note's text, uploaded for every tidy) | Yes | App Functionality | No | No |
| Identifiers (User ID — the anonymous `tidy:<UUID>`) | Yes | App Functionality | No | No |
| Purchases (Purchase History) | Yes | App Functionality | No | No |

Audio Data sits under the User Content taxonomy, alongside Other User Content.
The text made from a recording travels with it and is covered by the same two
rows: the recording goes up, the transcript comes back through the same request,
and neither is kept.

Not collected: contact info, health, financial info, location, contacts,
browsing history, search history, usage data, diagnostics. The diagnostics log
stays on the device and is never transmitted.

## Screenshots

Still owed — Andrew captures these on his device. Apple requires at least one
6.9-inch iPhone set (1320 × 2868 or 1290 × 2796). Worth showing, in order: the
capture screen mid-recording, a finished organized note in the preview, the
Settings plan row, and the paywall.

The subscription review screenshot is a separate requirement, one per
subscription product, and is already uploaded (see below).

## What is already in App Store Connect

App `6799307936`, all written through the API on 2026-08-08; the listing
text and the review screenshots were last pushed on 2026-09-03.

| Object | ID | State |
|---|---|---|
| App Store version | `74f6eb9d-c264-488b-9576-5dd243cf38c4` | 1.0.0, PREPARE_FOR_SUBMISSION |
| en-US version localization | `1606cd73-b50b-4bbe-a43e-5c86f8dd58cc` | description, keywords, promo text, support and marketing URLs |
| en-US app info localization | `2aec22f3-5190-40a8-9837-383aa308fbd0` | name, subtitle, privacy policy URL |
| App Review detail | `eb9ff962-5d41-4c12-8ed1-d3c70a7b7450` | Andrew Yang, demo account not required |
| Age rating declaration | `c1e60ebf-8dde-4035-9330-149646af5b69` | every question answered none/false → 4+ |
| Review screenshot, monthly | `07c5df0c-2d13-4904-a489-28e3e25efa58` | delivered, 1290 × 2796 |
| Review screenshot, annual | `85dc485e-e5cd-4013-89e4-746f7d6cdd53` | delivered, 1290 × 2796 |

The review contact phone is the one already on file for Andrew on the Relora
app's review detail in this same account, reused rather than invented.

The subscription review screenshot is a redraw of the published RevenueCat
paywall (violet on white since 2026-09-03) carrying the real App Store prices. RevenueCat's own renderer still
falls back to sample prices ($9.99 / $69.99) because it has not synced the real
ones from App Store Connect, and a review screenshot showing prices no one will
ever be charged is a rejection risk. Replace it with a device screenshot of the
real paywall whenever one exists.
