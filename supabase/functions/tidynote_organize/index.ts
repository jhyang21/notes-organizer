// TidyNote's cloud organizer ("premium tidy").
//
// One endpoint, two doors onto the same work: a JSON body carrying a
// transcript, or a multipart body carrying audio we transcribe first. Both end
// in the same place -- text in, an OrganizedNote out. Everything else here
// exists to keep a publishable anon key -- which ships inside the app and is
// therefore extractable -- from turning into an unbounded OpenAI bill:
// per-user and per-IP rate limits, a server-authoritative monthly quota, and a
// RevenueCat entitlement check.
//
// This function is deliberately self-contained. It runs in the same Supabase
// project as Relora but shares no code with it, so a change to Relora's _shared
// helpers can never alter TidyNote's behavior.
//
// The note text is never logged. Neither is the audio: it lives only for the
// length of the transcription call and is written nowhere.
//
// Function secrets this reads, all through `deps.env`:
//   OPENAI_API_KEY          the organizer and the transcriber. Required.
//   TIDYNOTE_OPENAI_MODEL   overrides the chat model. Optional.
//   TIDYNOTE_WHISPER_MODEL  overrides the transcription model. Optional.
//   TIDYNOTE_RC_API_KEY     RevenueCat. Absent means everyone is on free.
//   TIDYNOTE_IP_HASH_KEY    keys the per-IP rate-limit bucket. Absent skips
//                           the IP limit, see `ipRateKey`.
//   TIDYNOTE_ATTEST_MODE    App Attest: `enforce`, `grace`, or `off`.
//                           Anything else, including absent, is `enforce`.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by the platform.

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.56.0';
import { type Classification, type OrganizedNote, organizeText, type TokenUsage } from './organize.ts';
import { sha256 as sha256Bytes, verifyAssertion, verifyAttestation } from './attest.ts';

const MAX_TEXT_CHARS = 60_000;
const APP_USER_ID_PATTERN = /^[A-Za-z0-9:_\-.]{8,80}$/;

// A key ID is the base64 of a SHA-256, so 44 characters with one pad. The
// shape is checked before anything expensive runs; the value is checked by
// the attestation itself.
const KEY_ID_PATTERN = /^[A-Za-z0-9+/\-_]{43}=$/;
const MAX_ATTESTATION_CHARS = 16_000;

// Attesting is cheap for the caller and expensive here -- a chain to verify
// and a row to write -- so it gets its own, much tighter, hourly budget. A
// genuine install attests once per key, so five an hour is already generous.
const ATTESTS_PER_HOUR = 5;
// How far the client's clock may be from ours. The timestamp is half of what
// the attestation signs over, so a wide window is a wide replay window.
const MAX_ATTESTATION_SKEW_SECONDS = 300;

// Two ceilings on one upload, because either alone has a hole. Bytes stop a
// padded or high-bitrate file; the client-reported duration stops a long
// recording that happens to compress small. The client stops recording at 300
// seconds, so the extra 30 is slack for a clip that measures slightly over --
// not a second allowance.
const MAX_AUDIO_BYTES = 12 * 1024 * 1024;
const MAX_AUDIO_SECONDS = 330;

const FREE_MONTHLY_LIMIT = 5;
// Pro is unlimited in product terms and stays marketed that way. The counter is
// an anti-abuse backstop, not a product limit: 500 a month is about 16 a day,
// which no person reaches by using the app but a script does in an afternoon.
// It is enforced: past the ceiling a pro caller gets the same 429 a free one
// gets.
const PRO_MONTHLY_LIMIT = 500;

// Declared-size ceilings, checked before the body is read at all. The
// post-parse checks below are the real ones; these only stop a large upload
// from being buffered before anyone looks at it. The multipart figure is the
// 12 MB audio ceiling plus room for the framing and the small text fields.
const MAX_MULTIPART_BYTES = 13 * 1024 * 1024;
const MAX_JSON_BYTES = 256 * 1024;

const USER_REQUESTS_PER_MINUTE = 6;
const IP_REQUESTS_PER_MINUTE = 20;

const ENTITLEMENT_CACHE_TTL_MS = 5 * 60 * 1000;
/** How long the entitlement lookup waits before it gives up. Exported so the
 * test for the timeout does not have to repeat the number. */
export const REVENUECAT_TIMEOUT_MS = 5_000;
const DEFAULT_MODEL = 'gpt-5-mini';
const WHISPER_TIMEOUT_MS = 45_000;
const DEFAULT_WHISPER_MODEL = 'whisper-1';
// Whisper imitates the style of its prompt, so this asks for the punctuation
// and casing it otherwise omits. It is a style sample, not an instruction.
const WHISPER_PROMPT = 'A personal voice note. Use normal punctuation and sentence casing.';

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

export interface QuotaState {
  used: number;
  limit: number;
  remaining: number;
  month: string;
}

export type Plan = 'free' | 'pro';

/**
 * How hard App Attest is enforced.
 *
 * `enforce` is the only safe resting state and so is the default for anything
 * unrecognized, including a missing secret: a typo in the value must not
 * silently turn the control off. `grace` is for the window while an
 * unattested build is still in the wild -- it logs and lets the request
 * through. `off` is for an emergency, when verification itself is what is
 * broken.
 */
export type AttestMode = 'enforce' | 'grace' | 'off';

/** One stored App Attest key. `public_key` is a JWK as JSON, because that is
 * what WebCrypto imports and PostgREST is happy to hold a string. */
export interface AttestKeyRow {
  key_id: string;
  app_user_id: string;
  rp_id: string;
  public_key: string;
  counter: number;
  last_seen_at?: string;
}

/** Everything the handler touches that isn't pure, injected so tests never open
 * a socket or need a database. */
export interface Deps {
  fetch: typeof fetch;
  env(key: string): string | undefined;
  now(): Date;
  consumeRate(key: string, window: string, limit: number): Promise<boolean>;
  consumeQuota(userId: string, month: string, limit: number): Promise<{ allowed: boolean; used: number }>;
  /** Overrides REVENUECAT_TIMEOUT_MS. Only the timeout test sets it, so its
   * hang does not cost the suite five real seconds. Production leaves it out. */
  revenueCatTimeoutMs?: number;
  /** Injected so index_test.ts can drive the routing without a real chain --
   * `attest_test.ts` is where the verification itself is tested. */
  verifyAttestation: typeof verifyAttestation;
  verifyAssertion: typeof verifyAssertion;
  getAttestKey(keyId: string): Promise<AttestKeyRow | null>;
  putAttestKey(row: AttestKeyRow): Promise<void>;
  touchAttestKey(keyId: string, counter: number): Promise<void>;
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

function jsonResponse(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    // No CORS headers, anywhere. The only client is the iOS app, which sends
    // no Origin and does not need them. Leaving them off means a browser page
    // holding the extractable anon key cannot call this function at all.
    headers: { 'Content-Type': 'application/json' },
  });
}

function errorResponse(code: string, message: string, status: number, extra?: Record<string, unknown>): Response {
  return jsonResponse({ error: { code, message }, ...extra }, status);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

export function monthKey(now: Date): string {
  return now.toISOString().slice(0, 7); // 2026-08
}

export function minuteKey(now: Date): string {
  return now.toISOString().slice(0, 16); // 2026-08-07T14:03
}

/** The window the attest limits count in. Attesting is rare enough that a
 * minute is the wrong unit -- an hour is. */
export function hourKey(now: Date): string {
  return now.toISOString().slice(0, 13); // 2026-08-07T14
}

/** Anything but `grace` or `off` is `enforce`, including a missing value. */
export function attestMode(raw: string | undefined): AttestMode {
  return raw === 'grace' || raw === 'off' ? raw : 'enforce';
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

/** First hop of X-Forwarded-For. Later hops are appended by our own proxies, so
 * only the first entry identifies the caller.
 *
 * The header cannot be forged from outside: the platform replaces whatever the
 * caller sent with the real client address before this function sees it.
 * Verified live on 2026-09-03 by firing 45 parallel requests with fresh app
 * user ids and 45 different forged X-Forwarded-For values, which returned 20
 * successes and 25 rate-limited replies. Had the forgery worked, all 45 would
 * have landed in separate buckets and all 45 would have succeeded. */
export function clientIp(req: Request): string | null {
  const header = req.headers.get('x-forwarded-for');
  if (!header) return null;
  const first = header.split(',')[0]?.trim();
  return first ? first : null;
}

/** True once the missing-secret line has been logged in this isolate. The line
 * is worth seeing, but not once per request. */
let ipHashKeyWarned = false;

/** Exposed so tests start from a clean flag. */
export function _resetIpHashKeyWarning(): void {
  ipHashKeyWarned = false;
}

/**
 * The rate-limit bucket name for a caller's IP, keyed with a secret.
 *
 * A plain SHA-256 of an IPv4 address anonymizes nothing: the whole space is
 * 2^32 and a laptop enumerates it, so anyone who reads the rate-limit table
 * reads the addresses. The HMAC makes the bucket name useless without
 * TIDYNOTE_IP_HASH_KEY, a Supabase function secret set to any long random
 * string. Rotating it only resets the minute windows in flight.
 *
 * Returns null when the secret is missing. Falling back to a fixed key would
 * drop every caller in the world into one bucket of 20 a minute, so the IP
 * limit is skipped for that request instead. The per-user limit and the monthly
 * quota still apply.
 *
 * `prefix` keeps the counters apart: an address attesting has its own budget
 * from the same address organizing, so spending one never spends the other.
 */
async function ipRateKey(deps: Deps, ip: string, prefix = 'ip'): Promise<string | null> {
  const secret = deps.env('TIDYNOTE_IP_HASH_KEY');
  if (!secret) {
    if (!ipHashKeyWarned) {
      ipHashKeyWarned = true;
      console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'ip_limit_unconfigured' }));
    }
    return null;
  }

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(ip));
  const hex = Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
  return `${prefix}:${hex}`;
}

/** The size the caller says the body is. Null when the header is absent or is
 * not a number, which leaves the decision to the checks that read the body. */
function declaredBodyBytes(req: Request): number | null {
  const raw = req.headers.get('content-length');
  if (raw === null) return null;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

function quotaState(used: number, limit: number, month: string): QuotaState {
  return { used, limit, remaining: Math.max(limit - used, 0), month };
}

/** A form part read as text. A missing part and a part that turned out to be a
 * file both read as absent, which is what every caller here wants. */
function formField(form: FormData, name: string): string {
  const value = form.get(name);
  return typeof value === 'string' ? value : '';
}

// ---------------------------------------------------------------------------
// Entitlement
// ---------------------------------------------------------------------------

const entitlementCache = new Map<string, { isPro: boolean; expiresAtMs: number }>();

/** Exposed so tests start from a clean cache. */
export function _resetEntitlementCache(): void {
  entitlementCache.clear();
}

function entitlementIsActive(expiresDate: unknown, now: Date): boolean {
  // A null expiry is a non-expiring (lifetime) entitlement, not a missing one.
  if (expiresDate === null || expiresDate === undefined) return true;
  const parsed = Date.parse(String(expiresDate));
  return Number.isFinite(parsed) && parsed > now.getTime();
}

/**
 * Resolves the caller's plan.
 *
 * Every failure path returns `free`, deliberately. RevenueCat being unreachable
 * must not lock a paying user out *and* must not hand out unlimited cloud runs:
 * downgrading to free keeps them working, and the monthly quota caps the blast
 * radius. Until M10 sets TIDYNOTE_RC_API_KEY there is no Pro tier at all, so an
 * absent key takes the same path.
 */
export async function resolvePlan(deps: Deps, appUserId: string): Promise<Plan> {
  const apiKey = deps.env('TIDYNOTE_RC_API_KEY');
  if (!apiKey) return 'free';

  const nowMs = deps.now().getTime();
  const cached = entitlementCache.get(appUserId);
  if (cached && cached.expiresAtMs > nowMs) return cached.isPro ? 'pro' : 'free';

  try {
    const response = await deps.fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
      // Without a bound, a RevenueCat that accepts the connection and then
      // stalls holds this request open until the platform kills it.
      {
        headers: { Authorization: `Bearer ${apiKey}` },
        signal: AbortSignal.timeout(deps.revenueCatTimeoutMs ?? REVENUECAT_TIMEOUT_MS),
      },
    );
    // A transient RevenueCat error is not evidence about this user, so it is
    // never cached -- the next request asks again.
    if (!response.ok) return 'free';

    const body = await response.json();
    const entitlements = body?.subscriber?.entitlements ?? body?.entitlements;
    const pro = entitlements?.pro;
    const isPro = Boolean(pro) && entitlementIsActive(pro.expires_date, deps.now());

    entitlementCache.set(appUserId, { isPro, expiresAtMs: nowMs + ENTITLEMENT_CACHE_TTL_MS });
    return isPro ? 'pro' : 'free';
  } catch {
    return 'free';
  }
}

// ---------------------------------------------------------------------------
// Whisper
// ---------------------------------------------------------------------------

/** Turns the uploaded audio into text. The file is forwarded straight from the
 * parsed form to OpenAI and dropped -- it is never buffered to disk, stored, or
 * written to a log. */
async function transcribe(deps: Deps, audio: File, model: string, apiKey: string, locale: string): Promise<string> {
  const form = new FormData();
  form.append('file', audio);
  form.append('model', model);
  form.append('response_format', 'text');
  // A hint, not a constraint: naming the language stops Whisper guessing wrong
  // on a short or noisy clip. The region half of a BCP-47 tag means nothing to
  // the API, so only the language subtag goes over.
  if (locale) form.append('language', locale.slice(0, 2));
  form.append('prompt', WHISPER_PROMPT);

  const response = await deps.fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
    signal: AbortSignal.timeout(WHISPER_TIMEOUT_MS),
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`whisper status ${response.status}: ${detail.slice(0, 200)}`);
  }
  // response_format is text, so the body is the transcript itself.
  return await response.text();
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/** Rate limiting is advisory: if the counter itself is broken, serving the
 * request is better than a hard outage. The quota below is the real ceiling. */
async function withinRate(deps: Deps, key: string, window: string, limit: number): Promise<boolean> {
  try {
    return await deps.consumeRate(key, window, limit);
  } catch (error) {
    console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'rate_limit_unavailable', message: String(error) }));
    return true;
  }
}

/** What `handleAttest` hands back: the reply, plus the two fields the caller's
 * log line needs and cannot read off it. */
interface AttestOutcome {
  response: Response;
  code?: string;
  userTag?: string;
}

/**
 * Registers one App Attest key against one app user id.
 *
 * The challenge is not server-issued. A server-issued nonce would need a round
 * trip and a store to remember it in, and would buy little here: the app signs
 * over its own id and a timestamp, the timestamp has to be within five minutes
 * of ours, and the whole exchange is inside TLS. A replay is therefore limited
 * to re-registering the same key under the same id within five minutes, which
 * changes nothing.
 *
 * Answers 204 with no body. There is nothing to tell the client except that it
 * worked, and a body would be one more thing to keep in step with the app.
 */
async function handleAttest(req: Request, deps: Deps, payload: Record<string, unknown>): Promise<AttestOutcome> {
  const fail = (code: string, message: string, status: number, userTag?: string): AttestOutcome => ({
    response: errorResponse(code, message, status),
    code,
    userTag,
  });

  const appUserId = typeof payload.appUserId === 'string' ? payload.appUserId : '';
  const keyId = typeof payload.keyId === 'string' ? payload.keyId : '';
  const attestation = typeof payload.attestation === 'string' ? payload.attestation : '';
  const timestamp = typeof payload.timestamp === 'number' ? payload.timestamp : Number.NaN;

  if (!APP_USER_ID_PATTERN.test(appUserId)) return fail('invalid_request', 'appUserId is missing or malformed.', 400);
  if (!KEY_ID_PATTERN.test(keyId)) return fail('invalid_request', 'keyId is missing or malformed.', 400);
  if (attestation.length === 0 || attestation.length > MAX_ATTESTATION_CHARS) {
    return fail('invalid_request', 'attestation is missing or malformed.', 400);
  }
  if (!Number.isFinite(timestamp)) return fail('invalid_request', 'timestamp is missing or malformed.', 400);

  const userTag = (await sha256Hex(appUserId)).slice(0, 12);
  const now = deps.now();
  const window = hourKey(now);

  if (!(await withinRate(deps, `attest:u:${appUserId}`, window, ATTESTS_PER_HOUR))) {
    return fail('rate_limited', 'Too many attestation attempts. Try again later.', 429, userTag);
  }
  const ip = clientIp(req);
  if (ip) {
    const ipKey = await ipRateKey(deps, ip, 'attest:ip');
    if (ipKey && !(await withinRate(deps, ipKey, window, ATTESTS_PER_HOUR))) {
      return fail('rate_limited', 'Too many attestation attempts. Try again later.', 429, userTag);
    }
  }

  if (Math.abs(Math.floor(now.getTime() / 1000) - timestamp) > MAX_ATTESTATION_SKEW_SECONDS) {
    return fail('attestation_stale', 'The attestation timestamp is too far from server time.', 400, userTag);
  }

  const clientDataHash = await sha256Bytes(new TextEncoder().encode(`${appUserId}|${timestamp}`));

  let verified: { publicKeyJwk: JsonWebKey; rpId: string };
  try {
    verified = await deps.verifyAttestation({ keyId, attestation, clientDataHash, now });
  } catch (error) {
    // The reason never goes back to the caller. Naming the failed step is a
    // free hint to anyone assembling a forgery, and a genuine app has only one
    // useful move either way: drop the key and generate another.
    console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'attestation_rejected', user: userTag, message: String(error) }));
    return fail('attestation_invalid', 'This key could not be attested.', 401, userTag);
  }

  try {
    await deps.putAttestKey({
      key_id: keyId,
      app_user_id: appUserId,
      rp_id: verified.rpId,
      public_key: JSON.stringify(verified.publicKeyJwk),
      counter: 0,
      last_seen_at: now.toISOString(),
    });
  } catch (error) {
    // Separated from the verification failure above so a database outage never
    // reads to the client as "your key is bad".
    console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'attest_store_failed', user: userTag, message: String(error) }));
    return fail('attestation_unavailable', 'Verification is unavailable. Try again shortly.', 503, userTag);
  }

  return { response: new Response(null, { status: 204 }), userTag };
}

export async function handleRequest(req: Request, deps: Deps): Promise<Response> {
  const startedAt = Date.now();
  let plan: Plan = 'free';
  let userTag = 'none';
  let status = 500;
  let code: string | undefined;
  let usage: TokenUsage | undefined;
  let classification: Classification | undefined;
  let note: OrganizedNote | undefined;
  let mode: 'text' | 'voice' = 'text';
  let op: 'organize' | 'attest' = 'organize';
  let audioBytes: number | undefined;
  const model = deps.env('TIDYNOTE_OPENAI_MODEL') || DEFAULT_MODEL;

  try {
    if (req.method === 'OPTIONS') {
      status = 204;
      return new Response(null, { status: 204 });
    }
    if (req.method !== 'POST') {
      status = 405;
      code = 'method_not_allowed';
      return errorResponse(code, 'Use POST.', status);
    }

    // --- validate ---------------------------------------------------------
    // The content type is the whole routing decision. Clients that predate the
    // voice path send JSON and must not be able to tell this function grew a
    // second door.
    mode = (req.headers.get('content-type') ?? '').toLowerCase().includes('multipart/form-data') ? 'voice' : 'text';

    let appUserId: string;
    let text = '';
    let audio: File | null = null;
    let locale = '';
    let durationSeconds = 0;

    // The declared-size checks stay ahead of the read, so an oversized upload
    // is refused before it is buffered.
    const declared = declaredBodyBytes(req);
    if (mode === 'voice' && declared !== null && declared > MAX_MULTIPART_BYTES) {
      status = 413;
      code = 'audio_too_large';
      return errorResponse(code, `upload exceeds ${MAX_MULTIPART_BYTES} bytes.`, status);
    }
    if (mode === 'text' && declared !== null && declared > MAX_JSON_BYTES) {
      status = 413;
      code = 'too_long';
      return errorResponse(code, `body exceeds ${MAX_JSON_BYTES} bytes.`, status);
    }

    // Read once, as bytes, because the App Attest assertion signs over exactly
    // these bytes. Parsing first and re-serializing would sign a different
    // string: key order, whitespace and multipart boundaries would all have to
    // survive a round trip, and none of them are guaranteed to.
    const bodyBytes = new Uint8Array(await req.arrayBuffer());

    if (mode === 'voice') {
      let form: FormData;
      try {
        form = await new Response(bodyBytes, {
          headers: { 'content-type': req.headers.get('content-type') ?? '' },
        }).formData();
      } catch {
        status = 400;
        code = 'invalid_request';
        return errorResponse(code, 'Body must be a well-formed multipart form.', status);
      }
      appUserId = formField(form, 'appUserId');
      locale = formField(form, 'locale');
      // Advisory: the client measures it, so it is a cheap way to reject a long
      // recording before reading the bytes, not a figure to be trusted.
      durationSeconds = Number(formField(form, 'durationSeconds'));
      const part = form.get('audio');
      audio = part instanceof File ? part : null;
    } else {
      let payload: { op?: unknown; text?: unknown; appUserId?: unknown; clientVersion?: unknown };
      try {
        payload = JSON.parse(new TextDecoder().decode(bodyBytes));
      } catch {
        status = 400;
        code = 'invalid_request';
        return errorResponse(code, 'Body must be JSON.', status);
      }
      if (payload === null || typeof payload !== 'object') {
        status = 400;
        code = 'invalid_request';
        return errorResponse(code, 'Body must be JSON.', status);
      }

      // The one request that is not a tidy: an install registering its App
      // Attest key. It answers and returns before any of the organize path
      // runs, and spends no quota.
      if (payload.op === 'attest') {
        op = 'attest';
        const outcome = await handleAttest(req, deps, payload as Record<string, unknown>);
        status = outcome.response.status;
        code = outcome.code;
        userTag = outcome.userTag ?? userTag;
        return outcome.response;
      }

      const rawText = typeof payload.text === 'string' ? payload.text : '';
      text = rawText.trim();
      appUserId = typeof payload.appUserId === 'string' ? payload.appUserId : '';
    }

    if (!APP_USER_ID_PATTERN.test(appUserId)) {
      status = 400;
      code = 'invalid_request';
      return errorResponse(code, 'appUserId is missing or malformed.', status);
    }

    userTag = (await sha256Hex(appUserId)).slice(0, 12);

    if (mode === 'voice') {
      if (!audio) {
        status = 400;
        code = 'invalid_request';
        return errorResponse(code, 'audio is missing.', status);
      }
      audioBytes = audio.size;
      if (audio.size > MAX_AUDIO_BYTES) {
        status = 413;
        code = 'audio_too_large';
        return errorResponse(code, `audio exceeds ${MAX_AUDIO_BYTES} bytes.`, status);
      }
      if (durationSeconds > MAX_AUDIO_SECONDS) {
        status = 413;
        code = 'audio_too_large';
        return errorResponse(code, `audio exceeds ${MAX_AUDIO_SECONDS} seconds.`, status);
      }
    } else {
      if (text.length === 0) {
        status = 400;
        code = 'invalid_request';
        return errorResponse(code, 'text is empty.', status);
      }
      // Measured on the trimmed text, which is what actually reaches the model.
      if (text.length > MAX_TEXT_CHARS) {
        status = 413;
        code = 'too_long';
        return errorResponse(code, `text exceeds ${MAX_TEXT_CHARS} characters.`, status);
      }
    }

    // --- attestation ------------------------------------------------------
    // Ahead of the rate limit and the quota on purpose: a caller who cannot
    // prove it is the app must not be able to spend either of them, not even
    // to exhaust someone else's.
    const attest = attestMode(deps.env('TIDYNOTE_ATTEST_MODE'));
    const keyIdHeader = req.headers.get('x-tidynote-key-id');
    const assertionHeader = req.headers.get('x-tidynote-assertion');

    if (attest === 'off') {
      // The kill switch. Nothing is required and nothing is checked, because
      // the reason to reach for this is verification itself being broken.
    } else if (keyIdHeader !== null || assertionHeader !== null) {
      // Half a pair proves nothing, and reading it as "absent" would let any
      // caller opt out of enforcement by sending one header.
      if (keyIdHeader === null || assertionHeader === null) {
        status = 401;
        code = 'attestation_invalid';
        return errorResponse(code, 'This request is not attested.', status);
      }

      let row: AttestKeyRow | null;
      try {
        // Shape first, so a header of arbitrary length or content never
        // becomes a query. A key id that cannot exist reads as one that does
        // not, which is the same 401 either way.
        row = KEY_ID_PATTERN.test(keyIdHeader) ? await deps.getAttestKey(keyIdHeader) : null;
      } catch (error) {
        // The key store being unreachable is an outage, not a forgery. A 401
        // here would tell a genuine install to throw its hardware key away and
        // start an attestation storm on the way back up.
        console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'attest_lookup_failed', user: userTag, message: String(error) }));
        status = 503;
        code = 'attestation_unavailable';
        return errorResponse(code, 'Verification is unavailable. Try again shortly.', status);
      }

      let counter: number;
      try {
        if (!row) throw new Error('unknown key id');
        // The key is bound to the id it attested under, so borrowing another
        // install's app user id fails here even holding a real device key.
        if (row.app_user_id !== appUserId) throw new Error('key belongs to another app user');
        ({ counter } = await deps.verifyAssertion({
          assertion: assertionHeader,
          // The bytes as they arrived. Hashed here rather than beside the read
          // so a request nobody asked to attest never pays for the digest.
          clientDataHash: await sha256Bytes(bodyBytes),
          publicKeyJwk: JSON.parse(row.public_key),
          rpId: row.rp_id,
          previousCounter: Number(row.counter ?? 0),
        }));
      } catch (error) {
        console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'assertion_rejected', user: userTag, message: String(error) }));
        status = 401;
        code = 'attestation_invalid';
        return errorResponse(code, 'This request is not attested.', status);
      }

      try {
        await deps.touchAttestKey(keyIdHeader, counter);
      } catch (error) {
        // The signature was good. A lost counter write costs replay protection
        // for this one key until the next write lands, which is a smaller harm
        // than refusing a request that proved who sent it.
        console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'attest_touch_failed', user: userTag, message: String(error) }));
      }
    } else if (attest === 'enforce') {
      status = 426;
      code = 'update_required';
      return errorResponse(code, 'This version of TidyNote is no longer supported. Update to keep tidying.', status);
    } else {
      // Grace. One line per unattested caller, which is how we watch the old
      // builds drain away before enforcement is switched on.
      console.log(JSON.stringify({ tag: 'tidynote_organize', event: 'unattested', user: userTag }));
    }

    // --- rate limit -------------------------------------------------------
    const now = deps.now();
    const window = minuteKey(now);

    if (!(await withinRate(deps, `u:${appUserId}`, window, USER_REQUESTS_PER_MINUTE))) {
      status = 429;
      code = 'rate_limited';
      return errorResponse(code, 'Too many requests. Try again in a moment.', status);
    }

    const ip = clientIp(req);
    if (ip) {
      const ipKey = await ipRateKey(deps, ip);
      if (ipKey && !(await withinRate(deps, ipKey, window, IP_REQUESTS_PER_MINUTE))) {
        status = 429;
        code = 'rate_limited';
        return errorResponse(code, 'Too many requests. Try again in a moment.', status);
      }
    }

    // --- entitlement + quota ---------------------------------------------
    plan = await resolvePlan(deps, appUserId);
    const month = monthKey(now);
    const limit = plan === 'pro' ? PRO_MONTHLY_LIMIT : FREE_MONTHLY_LIMIT;

    // A definite "no" from a working counter is honoured on either plan: past
    // the ceiling the traffic is a script on a stolen key, not a customer.
    //
    // A counter that throws is a different thing -- an outage -- and there the
    // two plans part. For pro it must never stand between a paying user and
    // their note. For free, failing open would uncap the one spend the quota
    // exists to cap, so it fails closed and the client offers a retry.
    let result: { allowed: boolean; used: number };
    try {
      result = await deps.consumeQuota(appUserId, month, limit);
    } catch (error) {
      if (plan === 'pro') {
        console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'pro_quota_count_failed', message: String(error) }));
        result = { allowed: true, used: 0 };
      } else {
        console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'quota_unavailable', message: String(error) }));
        status = 503;
        code = 'quota_unavailable';
        return errorResponse(code, 'Usage service is unavailable. Try again shortly.', status);
      }
    }
    if (!result.allowed) {
      status = 429;
      code = 'quota_exhausted';
      return errorResponse(code, 'Monthly premium tidies used', status, {
        quota: quotaState(result.used, limit, month),
      });
    }
    const used = result.used;

    // --- transcribe -------------------------------------------------------
    const openAiKey = deps.env('OPENAI_API_KEY');
    if (!openAiKey) {
      status = 502;
      code = 'upstream_error';
      return errorResponse(code, 'Organizer is not configured.', status);
    }

    // Voice only -- a JSON request already has its text. The quota was charged
    // above, before this call, on purpose: charging after transcription would
    // let a user whose quota is spent keep uploading audio and get Whisper runs
    // free for the rest of the month.
    if (audio) {
      let transcript: string;
      try {
        transcript = await transcribe(deps, audio, deps.env('TIDYNOTE_WHISPER_MODEL') || DEFAULT_WHISPER_MODEL, openAiKey, locale);
      } catch (error) {
        console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'transcription_failed', message: String(error) }));
        status = 502;
        code = 'upstream_error';
        return errorResponse(code, 'The tidy service could not transcribe this recording.', status);
      }

      text = transcript.trim();
      // Silence, or a recording of nothing but background noise. The user gets
      // a distinct code so the app can say "we heard nothing" rather than
      // blaming the organizer.
      if (text.length === 0) {
        status = 422;
        code = 'empty_transcript';
        return errorResponse(code, 'No speech was found in the recording.', status);
      }
      if (text.length > MAX_TEXT_CHARS) {
        status = 413;
        code = 'too_long';
        return errorResponse(code, `text exceeds ${MAX_TEXT_CHARS} characters.`, status);
      }
    }

    // --- organize ---------------------------------------------------------
    try {
      const outcome = await organizeText(deps.fetch, openAiKey, text, model, mode === 'voice' ? 'voice' : 'shared');
      note = outcome.note;
      classification = outcome.classification;
      usage = outcome.usage;
    } catch (error) {
      console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'upstream_failed', message: String(error) }));
      status = 502;
      code = 'upstream_error';
      return errorResponse(code, 'The tidy service could not organize this note.', status);
    }

    status = 200;
    // The transcript is returned only to the caller who sent audio -- it is the
    // one thing they have no other copy of. A JSON caller already holds its own
    // text, so its response shape is unchanged. `note` is title/summary/sections
    // only -- classification (`noteKind`, `level`) steered the model and is
    // logged below, but it never reaches the client.
    return jsonResponse(
      { note, quota: quotaState(used, limit, month), plan, ...(mode === 'voice' ? { transcript: text } : {}) },
      200,
    );
  } catch (error) {
    console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'unhandled', message: String(error) }));
    status = 500;
    code = 'internal_error';
    return errorResponse(code, 'Something went wrong.', status);
  } finally {
    // One line per request. Note text never appears here, nor any part of the
    // audio -- audio_bytes is a size, not content -- and the user id is reduced
    // to a hash prefix: enough to correlate a complaint, not enough to rebuild
    // the id.
    console.log(
      JSON.stringify({
        tag: 'tidynote_organize',
        ms: Date.now() - startedAt,
        status,
        plan,
        mode,
        op,
        user: userTag,
        model,
        ...(audioBytes !== undefined ? { audio_bytes: audioBytes } : {}),
        ...(code ? { code } : {}),
        ...(classification ? { note_kind: classification.noteKind, level: classification.level } : {}),
        ...(note ? { sections: note.sections.length } : {}),
        ...(usage?.prompt_tokens !== undefined ? { prompt_tokens: usage.prompt_tokens } : {}),
        ...(usage?.completion_tokens !== undefined ? { completion_tokens: usage.completion_tokens } : {}),
        ...(usage?.total_tokens !== undefined ? { total_tokens: usage.total_tokens } : {}),
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Production wiring
// ---------------------------------------------------------------------------

let cachedClient: SupabaseClient | null = null;

function serviceClient(): SupabaseClient {
  if (!cachedClient) {
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected by the platform and must be present');
    cachedClient = createClient(url, key, { auth: { persistSession: false } });
  }
  return cachedClient;
}

export function productionDeps(): Deps {
  return {
    fetch: (input, init) => fetch(input, init),
    env: (key) => Deno.env.get(key),
    now: () => new Date(),
    async consumeRate(key, window, limit) {
      const { data, error } = await serviceClient().rpc('tidynote_consume_rate', {
        p_key: key,
        p_window: window,
        p_limit: limit,
      });
      if (error) throw new Error(error.message);
      return data === true;
    },
    async consumeQuota(userId, month, limit) {
      const { data, error } = await serviceClient().rpc('tidynote_consume_quota', {
        p_user_id: userId,
        p_month: month,
        p_limit: limit,
      });
      if (error) throw new Error(error.message);
      // A set-returning function arrives as an array of rows.
      const row = Array.isArray(data) ? data[0] : data;
      if (!row) throw new Error('tidynote_consume_quota returned no row');
      return { allowed: row.allowed === true, used: Number(row.used ?? 0) };
    },
    verifyAttestation,
    verifyAssertion,
    // Plain table reads and writes rather than an RPC: there is no atomicity to
    // arrange here, and the service role reaches the table directly. RLS is on
    // with no policies, so nothing else can.
    async getAttestKey(keyId) {
      const { data, error } = await serviceClient()
        .from('tidynote_attest_keys')
        .select('key_id, app_user_id, rp_id, public_key, counter')
        .eq('key_id', keyId)
        .maybeSingle();
      if (error) throw new Error(error.message);
      if (!data) return null;
      return {
        key_id: data.key_id,
        app_user_id: data.app_user_id,
        rp_id: data.rp_id,
        public_key: data.public_key,
        counter: Number(data.counter ?? 0),
      };
    },
    async putAttestKey(row) {
      const { error } = await serviceClient()
        .from('tidynote_attest_keys')
        .upsert(row, { onConflict: 'key_id' });
      if (error) throw new Error(error.message);
    },
    async touchAttestKey(keyId, counter) {
      const { error } = await serviceClient()
        .from('tidynote_attest_keys')
        .update({ counter, last_seen_at: new Date().toISOString() })
        .eq('key_id', keyId);
      if (error) throw new Error(error.message);
    },
  };
}

if (import.meta.main) {
  Deno.serve((req) => handleRequest(req, productionDeps()));
}
