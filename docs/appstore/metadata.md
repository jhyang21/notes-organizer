# App Store listing — TidyNote 1.0.6

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

Every tidy runs on our servers. Your recording, or the text you share in, goes over an encrypted connection to be turned into text and organized, and it isn't kept once the note comes back. The app explains what it sends before the first tidy, and nothing is sent until you agree.

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
NO ACCOUNT, NOTHING TO SIGN IN TO
TidyNote has no sign-up, login, or password; the demo fields are empty on purpose. On first launch the app creates a random anonymous ID ("tidy:<UUID>") used only to count tidies and check subscription status. It is not tied to a name, email, device ID, or ad ID. iPhone only, English only.

FIRST-RUN SCREEN
Before anything is sent, one screen explains that recordings and shared text go over HTTPS to our servers, are transcribed and organized by an AI model, and are not kept. The user taps "Agree and Continue". The Privacy Policy is linked on that screen, in Settings, and on the paywall.

EVERY TIDY IS A SERVER CALL
Nothing is organized offline; the review device needs a network connection. The app records audio, uploads it, our provider transcribes and organizes it, and the note comes back. Shared text takes the same route without transcription. Neither the recording nor the text is stored.

LIMITS YOU MAY HIT WHILE TESTING
- Free plan: 5 tidies a month, counted server-side. The 6th shows "You've used this month's tidies" with the Pro offer. Deleting and reinstalling the app resets the count.
- Rate limit: 6 tidies a minute per install. A 7th inside the same minute shows a "try again" screen; wait one minute.
- After a delete-and-reinstall, the very first tidy may fail once with "The tidy service hit a snag" while the device re-registers its App Attest key. Tap Try Again; it succeeds.

HOW TO TEST A SUBSCRIPTION IN SANDBOX
1. Tap the gear icon (top right) to open Settings.
2. Tap "Go Pro". Yearly is preselected with live App Store prices. The button reads "Start 7-Day Free Trial" if the sandbox account has not used the trial, else "Subscribe for $39.99/year" (or the monthly price). The line under it states the trial, price, auto-renewal, and how to cancel. Confirm the purchase; Settings then reads "TidyNote Pro".
3. "Restore Purchases" re-applies the entitlement. "Manage Subscription" opens the system sheet.
Without purchasing, Settings and the capture screen show tidies left this month.

SHARE EXTENSION
TidyNote appears in the share sheet for text. Open the app once first; the extension works only after the first-run screen. Share a note from Apple Notes (switch its share sheet from Collaborate to Send Copy) or selected text from any app, pick TidyNote, and the organized version appears. It never edits the source note: "Save to Apple Notes" creates a new note. StoreKit does not run in extensions, so a spent quota there says "Open TidyNote to go Pro".

WIDGET, CONTROL CENTER, SIRI
All three open the app with "tidynote://record", which starts a recording once the app is on screen. None record or touch data on their own. Add the "Start a Tidy" widget, add the Control Center control on iOS 18+, or say "Start a tidy in TidyNote". A tap during a recording is ignored; the app just comes to the front.

MICROPHONE
Requested only when the user taps Record. The recording is uploaded over HTTPS, transcribed and organized, and not kept by us; the provider holds it for abuse monitoring only, about 30 days.

BACKGROUND AUDIO MODE
Declared so a recording the user started keeps going if they lock the phone or switch apps mid-sentence. Nothing records unless the user tapped Record; recording stops after 10 seconds of silence or 5 minutes. No playback, no background upload. To see it: tap Record, lock the phone, keep talking, unlock.

DIAGNOSTICS IS HIDDEN
Settings ends with a version line; tap it five times to reveal an on-device log for TestFlight testers. It never leaves the device.

PRIVACY POLICY
https://jhyang21.github.io/notes-organizer/privacy.html names our sub-processors and retention periods. Support: Settings → Contact Support.
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
subscription product. Both must now be taken on-device from the native
paywall — one with Yearly selected, one with Monthly selected — and pushed
with `python scripts/asc_metadata.py review-screenshots monthly.png annual.png`.

## What is already in App Store Connect

App `6799307936`, all written through the API on 2026-08-08; the listing
text and the review screenshots were last pushed on 2026-09-03.

| Object | ID | State |
|---|---|---|
| App Store version | `74f6eb9d-c264-488b-9576-5dd243cf38c4` | 1.0.5 build 32 attached — rename to 1.0.6 and attach the 1.0.6 build before Add for Review |
| en-US version localization | `1606cd73-b50b-4bbe-a43e-5c86f8dd58cc` | description, keywords, promo text, support and marketing URLs |
| en-US app info localization | `2aec22f3-5190-40a8-9837-383aa308fbd0` | name, subtitle, privacy policy URL |
| App Review detail | `eb9ff962-5d41-4c12-8ed1-d3c70a7b7450` | Andrew Yang, demo account not required |
| Age rating declaration | `c1e60ebf-8dde-4035-9330-149646af5b69` | every question answered none/false → 4+ |
| Review screenshot, monthly | `07c5df0c-2d13-4904-a489-28e3e25efa58` | delivered, 1290 × 2796 |
| Review screenshot, annual | `85dc485e-e5cd-4013-89e4-746f7d6cdd53` | delivered, 1290 × 2796 |

The review contact phone is the one already on file for Andrew on the Relora
app's review detail in this same account, reused rather than invented.

The current review screenshots are Pillow redraws of the old RevenueCat
paywall template. They must be replaced with on-device shots of the native
paywall before submission. The RevenueCat dashboard paywall stays published,
but the app no longer renders it.
