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

## Promotional text (170 max)

```
Ramble into your phone and get a clean note back: title, headings, bullets, and your action items. Every fact, name, number, and date you said stays in.
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

TidyNote takes a voice ramble - or a messy note you already have - and turns it into a note you can actually read: a title, headings, bullets, and the action items you gave yourself.

It organizes. It does not summarize. Every fact, name, number, and date you said stays in the note. Nothing gets compressed into a tidy little paragraph that quietly drops the thing you needed.

HOW IT WORKS

Record a thought. Your iPhone turns speech into text, then structures it. Save the finished note to Apple Notes, copy it, or share it anywhere.

Already have a mess of a note? Share it into TidyNote from the share sheet - from Apple Notes or any app that shares text - and get it back organized.

WHAT IT IS GOOD FOR

- Thinking out loud on a walk and keeping the whole thought
- Meeting notes you typed too fast to punctuate
- A brain dump at 1 a.m. that needs to make sense in the morning
- Long voice memos you never go back and listen to
- Old notes that grew into a wall of text

PRIVATE BY DEFAULT

Tidies that run on your iPhone stay on your iPhone. Audio never leaves your device - not for an on-device tidy, not ever. There is no account, no sign-up, and no tracking.

Premium tidies send the note's text over an encrypted connection so a larger model can organize it, and the text isn't kept once the note comes back. The app asks before it does this the first time, and you can say no.

FREE AND PRO

Tidies that run on your iPhone are free and unlimited.

Premium tidies are capped at 5 a month on the free plan. TidyNote Pro makes them unlimited: $4.99 a month or $39.99 a year, with a 7-day free trial. Payment is charged to your Apple Account at confirmation of purchase, and the subscription renews automatically unless you turn off auto-renew at least 24 hours before the period ends. Manage or cancel it in Settings on your iPhone, under your name then Subscriptions.

REQUIREMENTS

iPhone running iOS 26 or later. Tidies that run on your iPhone need an iPhone that supports Apple Intelligence. On other iPhones, premium tidies do the work.

Privacy Policy: https://jhyang21.github.io/notes-organizer/privacy.html
Terms of Use: https://jhyang21.github.io/notes-organizer/terms.html
```

The subscription sentence in "FREE AND PRO" is required by Apple's paid-app
metadata rules: length of subscription, price, and a link to the terms must all
appear in the description.

## App Review notes

```
NO ACCOUNT - NOTHING TO DEMO-LOGIN
TidyNote has no sign-up, no login, and no password. Please leave the demo account fields empty; there is genuinely nothing to sign in to. On first launch the app generates a random anonymous identifier (a string like "tidy:<UUID>") and uses it only to count premium tidies and to look up subscription status. It is not tied to a name, an email, a device identifier, or an advertising identifier.

TWO KINDS OF TIDY
1. On-device tidy - free and unlimited. Uses Apple's on-device model (FoundationModels). This requires hardware that supports Apple Intelligence: iPhone 15 Pro or newer, on iOS 26. On older hardware the app falls through to premium tidies instead, and says so.
2. Premium tidy - runs on our server. The note's TEXT (never audio) is sent over HTTPS to our endpoint, which returns the organized note. The free plan allows 5 per calendar month; TidyNote Pro removes the cap.

THE FREE LIMIT IS ENFORCED ON THE SERVER
The 5-per-month cap is not a client-side check. The server keeps the counter against the anonymous identifier and returns HTTP 429 (quota_exhausted) on the 6th call, at which point the app shows the "You've used this month's premium tidies" screen with the TidyNote Pro upsell.

HOW TO TEST A PREMIUM TIDY IN SANDBOX
1. Open the app and tap the gear icon (top right of the capture screen) to reach Settings.
2. Tap "Go Pro" to open the paywall. Buy either the monthly or the annual product with a sandbox Apple Account. The 7-day free trial applies.
3. Settings should now read "TidyNote Pro" with "Premium tidies are unlimited."
4. Go back, record a short voice note (or share text in, see below), and let it finish.
5. "Restore Purchases" in Settings re-applies the entitlement.
To exercise the free path instead, use a fresh install without purchasing: the preview screen shows a "Premium tidy - N left this month" button.

ON-DEVICE TIER NEEDS APPLE INTELLIGENCE HARDWARE
If the review device is a simulator or an iPhone older than the iPhone 15 Pro, Apple Intelligence is unavailable and the on-device path cannot run. This is expected and handled: the app routes to a premium tidy while the free quota lasts, and shows a clear explanation rather than an error.

SHARE EXTENSION
TidyNote also appears in the iOS share sheet for text. To test it: open Apple Notes (or any app with text), share the note or selected text, choose TidyNote from the share sheet, and the extension organizes it in place. The extension has no purchase UI - StoreKit purchases are not viable inside a share extension - so if the free quota is exhausted there it says "Open TidyNote to go Pro" instead.

MICROPHONE AND SPEECH PERMISSIONS
Both are requested only when the user taps record. Speech is transcribed by Apple's on-device SpeechAnalyzer; audio is never uploaded anywhere.

PRIVACY POLICY
https://jhyang21.github.io/notes-organizer/privacy.html - it names our cloud sub-processor and its retention period explicitly. The app's own copy avoids vendor names; the policy does not.
```

## App Privacy (nutrition labels)

Set in App Store Connect under App Privacy. Nothing is used for tracking, and
nothing is linked to the user's identity.

| Data type | Collected | Purpose | Linked to identity | Tracking |
|---|---|---|---|---|
| User Content (other user content — the note's text, only on a premium tidy) | Yes | App Functionality | No | No |
| Identifiers (User ID — the anonymous `tidy:<UUID>`) | Yes | App Functionality | No | No |
| Purchases (Purchase History) | Yes | App Functionality | No | No |

Not collected: contact info, health, financial info, location, contacts,
browsing history, search history, usage data, diagnostics, audio data. Audio
never leaves the device, and the on-device diagnostics log is never transmitted.

## Screenshots

Still owed — Andrew captures these on his device. Apple requires at least one
6.9-inch iPhone set (1320 × 2868 or 1290 × 2796). Worth showing, in order: the
capture screen mid-recording, a finished organized note in the preview, the
Settings plan row, and the paywall.

The subscription review screenshot is a separate requirement, one per
subscription product, and is already uploaded (see below).

## What is already in App Store Connect

App `6799307936`, all written through the API on 2026-08-08.

| Object | ID | State |
|---|---|---|
| App Store version | `74f6eb9d-c264-488b-9576-5dd243cf38c4` | 1.0.0, PREPARE_FOR_SUBMISSION |
| en-US version localization | `1606cd73-b50b-4bbe-a43e-5c86f8dd58cc` | description, keywords, promo text, support and marketing URLs |
| en-US app info localization | `2aec22f3-5190-40a8-9837-383aa308fbd0` | name, subtitle, privacy policy URL |
| App Review detail | `eb9ff962-5d41-4c12-8ed1-d3c70a7b7450` | Andrew Yang, demo account not required |
| Age rating declaration | `c1e60ebf-8dde-4035-9330-149646af5b69` | every question answered none/false → 4+ |
| Review screenshot, monthly | `c5587cc8-d0d5-42bc-b96f-6bec9b80883d` | delivered, 1290 × 2796 |
| Review screenshot, annual | `1c5d8845-71dd-46c0-be77-c70a7289cbdc` | delivered, 1290 × 2796 |

The review contact phone is the one already on file for Andrew on the Relora
app's review detail in this same account, reused rather than invented.

The subscription review screenshot is a redraw of the published RevenueCat
paywall carrying the real App Store prices. RevenueCat's own renderer still
falls back to sample prices ($9.99 / $69.99) because it has not synced the real
ones from App Store Connect, and a review screenshot showing prices no one will
ever be charged is a rejection risk. Replace it with a device screenshot of the
real paywall whenever one exists.
