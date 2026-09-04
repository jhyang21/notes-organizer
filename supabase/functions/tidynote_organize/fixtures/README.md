# Test fixtures

## `attestation.json`

Not in the repo, and not required: `attest_test.ts` skips the two tests that
read it when the file is absent.

`verifyAssertion` can be tested from nothing, because an assertion is signed by
a key the test generates. `verifyAttestation` cannot: the attestation chain ends
at Apple's App Attest root, and nothing off a real device can mint a certificate
under it. So the only honest test of the full attestation path is a real
attestation from a real build, captured once and checked in locally by whoever
runs it.

### Capturing one

1. Run a **debug** build of the app on a physical iPhone. App Attest returns
   `isSupported == false` in the Simulator, so nothing is produced there.
2. Tidy anything. On the first cloud call `DeviceAttestor` generates a key,
   attests it, and — in `DEBUG` only — prints one line to the Xcode console:

   ```
   TIDYNOTE_ATTEST_FIXTURE {"keyId":"...","attestation":"...","appUserId":"tidy:...","timestamp":1756900000}
   ```

   The line is printed whether or not the server accepted the registration, so
   a fixture can be captured before the function is deployed.
3. Copy the JSON after the prefix into
   `supabase/functions/tidynote_organize/fixtures/attestation.json`, and add a
   `capturedAt` field with the moment you captured it, ISO 8601:

   ```json
   {
     "keyId": "...",
     "attestation": "...",
     "appUserId": "tidy:...",
     "timestamp": 1756900000,
     "capturedAt": "2026-09-03T18:20:00Z"
   }
   ```

   `capturedAt` is what the certificate chain is judged against. The leaf Apple
   issues is short-lived, so a fixture checked against today's clock would start
   failing within days. Without the field the test falls back to `timestamp`.
4. Run the suite with read access, which the tests otherwise do not ask for:

   ```sh
   deno test --allow-net --allow-env --allow-read supabase/functions/tidynote_organize/
   ```

   Without `--allow-read` — which is how CI runs — the two fixture tests report
   as ignored rather than failing.

### What is in it

Nothing secret. The attestation is a public certificate chain plus a public
key, the key ID is a hash of that key, and the app user id is an anonymous
install identifier with no account behind it. It is still left out of the repo
by default, because a fixture pinned to one device and one week is a test that
rots rather than one that guards anything.

If you do check one in, add `capturedAt` — without it the chain is judged
against a timestamp the client chose, which is the one field in the file an
attacker would control in the real flow.
