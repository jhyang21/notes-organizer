// Tests for the cloud organizer. Every dependency the handler touches is
// injected, so nothing here opens a socket or needs a database.
//
// Run: deno test --allow-net --allow-env supabase/functions/tidynote_organize/

import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  type Deps,
  _resetEntitlementCache,
  _resetIpHashKeyWarning,
  clientIp,
  handleRequest,
  minuteKey,
  monthKey,
  REVENUECAT_TIMEOUT_MS,
  resolvePlan,
  sha256Hex,
} from './index.ts';
import type { OrganizedNote } from './organize.ts';

const VALID_USER = 'tidy:11111111-2222-3333-4444-555555555555';
const IP_HASH_KEY = 'test-ip-hash-secret';
const FIXED_NOW = new Date('2026-08-07T14:03:22.000Z');

const SAMPLE_NOTE: OrganizedNote = {
  title: 'Dentist and Sarah Birthday',
  summary: '',
  sections: [
    { heading: 'To Do', kind: 'checklist', items: [{ text: 'Call the dentist tomorrow', done: false }] },
  ],
};

/** The stubbed completion content: the model's raw output, classification
 * included. The handler must strip `noteKind`/`level` before it reaches the
 * client -- see "classification never reaches the app" below. */
const SAMPLE_COMPLETION = { noteKind: 'tasks', level: 2, ...SAMPLE_NOTE };

function openAiSuccess(completion: unknown = SAMPLE_COMPLETION): Response {
  return new Response(
    JSON.stringify({
      choices: [{ message: { content: JSON.stringify(completion) } }],
      usage: { prompt_tokens: 120, completion_tokens: 60, total_tokens: 180 },
    }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
}

interface FetchCall {
  url: string;
  init?: RequestInit;
}

interface StubOptions {
  env?: Record<string, string>;
  now?: Date;
  rate?: (key: string, window: string, limit: number) => Promise<boolean>;
  quota?: (userId: string, month: string, limit: number) => Promise<{ allowed: boolean; used: number }>;
  fetchImpl?: (url: string, init?: RequestInit) => Promise<Response>;
  revenueCatTimeoutMs?: number;
}

function makeDeps(options: StubOptions = {}) {
  const calls = {
    rate: [] as { key: string; window: string; limit: number }[],
    quota: [] as { userId: string; month: string; limit: number }[],
    fetch: [] as FetchCall[],
  };

  const deps: Deps = {
    fetch: ((input: string | URL | Request, init?: RequestInit) => {
      const url = typeof input === 'string' ? input : input.toString();
      calls.fetch.push({ url, init });
      return options.fetchImpl ? options.fetchImpl(url, init) : Promise.resolve(openAiSuccess());
    }) as typeof fetch,
    env: (key: string) => (options.env ?? { OPENAI_API_KEY: 'sk-test', TIDYNOTE_IP_HASH_KEY: IP_HASH_KEY })[key],
    now: () => options.now ?? FIXED_NOW,
    consumeRate: (key, window, limit) => {
      calls.rate.push({ key, window, limit });
      return options.rate ? options.rate(key, window, limit) : Promise.resolve(true);
    },
    consumeQuota: (userId, month, limit) => {
      calls.quota.push({ userId, month, limit });
      return options.quota ? options.quota(userId, month, limit) : Promise.resolve({ allowed: true, used: 1 });
    },
    revenueCatTimeoutMs: options.revenueCatTimeoutMs,
  };

  return { deps, calls };
}

function makeRequest(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request('https://example.test/functions/v1/tidynote_organize', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

const TRANSCRIPT = 'Call the dentist tomorrow at nine and pick up milk.';

/** Whisper is asked for response_format=text, so its body is the transcript
 * itself rather than a JSON envelope. */
function whisperSuccess(transcript: string = TRANSCRIPT): Response {
  return new Response(transcript, { status: 200, headers: { 'Content-Type': 'text/plain' } });
}

function audioFile(bytes = 2048): File {
  return new File([new Uint8Array(bytes)], 'note.m4a', { type: 'audio/mp4' });
}

/** A multipart request shaped like the one the app sends. `audio: null` leaves
 * the part out altogether. */
function makeVoiceRequest(
  fields: { audio?: File | null; appUserId?: string; durationSeconds?: string; locale?: string } = {},
): Request {
  const form = new FormData();
  if (fields.audio !== null) form.append('audio', fields.audio ?? audioFile());
  form.append('appUserId', fields.appUserId ?? VALID_USER);
  form.append('clientVersion', '1.3.0');
  form.append('durationSeconds', fields.durationSeconds ?? '12');
  if (fields.locale) form.append('locale', fields.locale);
  return new Request('https://example.test/functions/v1/tidynote_organize', { method: 'POST', body: form });
}

/** makeDeps with a fetch that answers both upstream calls a voice request
 * makes: Whisper first, then the chat completion. */
function makeVoiceDeps(options: StubOptions & { whisper?: () => Promise<Response> } = {}) {
  const whisper = options.whisper ?? (() => Promise.resolve(whisperSuccess()));
  const rest: NonNullable<StubOptions['fetchImpl']> = options.fetchImpl ?? (() => Promise.resolve(openAiSuccess()));
  return makeDeps({
    ...options,
    fetchImpl: (url, init) => (url.includes('/audio/transcriptions') ? whisper() : rest(url, init)),
  });
}

/** The form the handler sent to Whisper. */
function whisperForm(call: FetchCall): FormData {
  return call.init?.body as FormData;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Deno.test('monthKey and minuteKey are UTC and correctly truncated', () => {
  assertEquals(monthKey(FIXED_NOW), '2026-08');
  assertEquals(minuteKey(FIXED_NOW), '2026-08-07T14:03');
});

Deno.test('clientIp takes only the first forwarded hop', () => {
  const req = new Request('https://example.test', { headers: { 'x-forwarded-for': '203.0.113.9, 10.0.0.1' } });
  assertEquals(clientIp(req), '203.0.113.9');
  assertEquals(clientIp(new Request('https://example.test')), null);
});

Deno.test('sha256Hex is stable hex', async () => {
  assertEquals(
    await sha256Hex('abc'),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  );
});

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

Deno.test('OPTIONS is answered bare, with no CORS grant', async () => {
  const { deps } = makeDeps();
  const response = await handleRequest(new Request('https://example.test', { method: 'OPTIONS' }), deps);
  assertEquals(response.status, 204);
  assertEquals(response.headers.get('access-control-allow-origin'), null);
});

Deno.test('no response carries a CORS header, so no browser page can call this', async () => {
  const { deps } = makeDeps();
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('access-control-allow-origin'), null);
});

Deno.test('GET is rejected', async () => {
  const { deps } = makeDeps();
  const response = await handleRequest(new Request('https://example.test', { method: 'GET' }), deps);
  assertEquals(response.status, 405);
  assertEquals((await response.json()).error.code, 'method_not_allowed');
});

Deno.test('non-JSON body is an invalid request', async () => {
  const { deps } = makeDeps();
  const response = await handleRequest(makeRequest('not json at all'), deps);
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.code, 'invalid_request');
});

Deno.test('malformed appUserId is rejected before anything else runs', async () => {
  const { deps, calls } = makeDeps();
  for (const appUserId of ['', 'short', 'has spaces here', 'bad/slash/value', 'x'.repeat(81)]) {
    const response = await handleRequest(makeRequest({ text: 'hello there', appUserId }), deps);
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.code, 'invalid_request');
  }
  // No quota or rate budget is spent on a request that never had a valid id.
  assertEquals(calls.rate.length, 0);
  assertEquals(calls.quota.length, 0);
});

Deno.test('empty and whitespace-only text are rejected', async () => {
  const { deps, calls } = makeDeps();
  for (const text of ['', '   \n\t  ']) {
    const response = await handleRequest(makeRequest({ text, appUserId: VALID_USER }), deps);
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.code, 'invalid_request');
  }
  assertEquals(calls.quota.length, 0);
});

Deno.test('text over 60000 characters is too long', async () => {
  const { deps, calls } = makeDeps();
  const response = await handleRequest(makeRequest({ text: 'a'.repeat(60_001), appUserId: VALID_USER }), deps);
  assertEquals(response.status, 413);
  assertEquals((await response.json()).error.code, 'too_long');
  assertEquals(calls.quota.length, 0);
});

Deno.test('a JSON body that declares more than 256 KB is refused before it is read', async () => {
  const { deps, calls } = makeDeps();
  const response = await handleRequest(
    makeRequest({ text: 'hello there', appUserId: VALID_USER }, { 'content-length': String(256 * 1024 + 1) }),
    deps,
  );
  assertEquals(response.status, 413);
  assertEquals((await response.json()).error.code, 'too_long');
  assertEquals(calls.quota.length, 0);
  assertEquals(calls.fetch.length, 0);
});

Deno.test('a multipart body that declares more than 13 MB is refused before it is read', async () => {
  const { deps, calls } = makeVoiceDeps();
  const request = new Request('https://example.test/functions/v1/tidynote_organize', {
    method: 'POST',
    headers: { 'Content-Type': 'multipart/form-data; boundary=x', 'content-length': String(13 * 1024 * 1024 + 1) },
    body: 'ignored, the header decides',
  });
  const response = await handleRequest(request, deps);
  assertEquals(response.status, 413);
  assertEquals((await response.json()).error.code, 'audio_too_large');
  assertEquals(calls.quota.length, 0);
  assertEquals(calls.fetch.length, 0);
});

Deno.test('a body with no content-length is judged on what it actually contains', async () => {
  const { deps } = makeDeps();
  const request = makeRequest({ text: 'hello there', appUserId: VALID_USER });
  assertEquals(request.headers.get('content-length'), null);
  assertEquals((await handleRequest(request, deps)).status, 200);
});

Deno.test('text at exactly 60000 characters is accepted', async () => {
  const { deps } = makeDeps();
  const response = await handleRequest(makeRequest({ text: 'a'.repeat(60_000), appUserId: VALID_USER }), deps);
  assertEquals(response.status, 200);
});

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

Deno.test('per-user and per-IP limits use the right keys, windows and ceilings', async () => {
  const { deps, calls } = makeDeps();
  await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }, { 'x-forwarded-for': '203.0.113.9' }), deps);

  assertEquals(calls.rate.length, 2);
  assertEquals(calls.rate[0], { key: `u:${VALID_USER}`, window: '2026-08-07T14:03', limit: 6 });
  assertEquals(calls.rate[1].window, '2026-08-07T14:03');
  assertEquals(calls.rate[1].limit, 20);

  // Keyed, not a bare digest. The bare digest of an IPv4 address is reversible
  // by enumeration, so seeing it here would be the bug this guards against.
  const ipKey = calls.rate[1].key;
  assert(ipKey.startsWith('ip:'));
  assertEquals(ipKey.length, 'ip:'.length + 64);
  assert(ipKey !== `ip:${await sha256Hex('203.0.113.9')}`);
});

Deno.test('the IP bucket is stable for one address and different for another', async () => {
  const bucketFor = async (ip: string) => {
    const { deps, calls } = makeDeps();
    await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }, { 'x-forwarded-for': ip }), deps);
    return calls.rate[1].key;
  };
  assertEquals(await bucketFor('203.0.113.9'), await bucketFor('203.0.113.9'));
  assert(await bucketFor('203.0.113.9') !== await bucketFor('203.0.113.10'));
});

Deno.test('without the hash secret the IP limit is skipped, not collapsed into one bucket', async () => {
  _resetIpHashKeyWarning();
  const warnings: string[] = [];
  const realError = console.error;
  console.error = (line: unknown) => warnings.push(String(line));
  try {
    const { deps, calls } = makeDeps({ env: { OPENAI_API_KEY: 'sk-test' } });
    for (const ip of ['203.0.113.9', '203.0.113.10']) {
      const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }, { 'x-forwarded-for': ip }), deps);
      assertEquals(response.status, 200);
    }
    // Only the per-user limit ran. A shared fallback key would have put every
    // caller on the planet into one bucket of 20 a minute.
    assert(!calls.rate.some((call) => call.key.startsWith('ip:')));
  } finally {
    console.error = realError;
  }
  assertEquals(warnings.filter((line) => line.includes('ip_limit_unconfigured')).length, 1);
});

Deno.test('exceeding the user limit returns 429 rate_limited and never reaches the model', async () => {
  const { deps, calls } = makeDeps({ rate: (key) => Promise.resolve(!key.startsWith('u:')) });
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 429);
  assertEquals((await response.json()).error.code, 'rate_limited');
  assertEquals(calls.quota.length, 0);
  assertEquals(calls.fetch.length, 0);
});

Deno.test('exceeding the IP limit returns 429 rate_limited', async () => {
  const { deps } = makeDeps({ rate: (key) => Promise.resolve(!key.startsWith('ip:')) });
  const response = await handleRequest(
    makeRequest({ text: 'hello there', appUserId: VALID_USER }, { 'x-forwarded-for': '203.0.113.9' }),
    deps,
  );
  assertEquals(response.status, 429);
  assertEquals((await response.json()).error.code, 'rate_limited');
});

Deno.test('a broken rate limiter does not block the request', async () => {
  const { deps } = makeDeps({ rate: () => Promise.reject(new Error('db down')) });
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 200);
});

// ---------------------------------------------------------------------------
// Quota
// ---------------------------------------------------------------------------

Deno.test('free users are charged against a limit of 5 in the current UTC month', async () => {
  const { deps, calls } = makeDeps();
  await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(calls.quota, [{ userId: VALID_USER, month: '2026-08', limit: 5 }]);
});

Deno.test('an exhausted quota returns 429 with the quota block', async () => {
  const { deps, calls } = makeDeps({ quota: () => Promise.resolve({ allowed: false, used: 5 }) });
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);

  assertEquals(response.status, 429);
  const body = await response.json();
  assertEquals(body.error.code, 'quota_exhausted');
  assertEquals(body.error.message, 'Monthly premium tidies used');
  assertEquals(body.quota, { used: 5, limit: 5, remaining: 0, month: '2026-08' });
  // Nothing is spent upstream once the wall is hit.
  assertEquals(calls.fetch.length, 0);
});

Deno.test('a quota counter outage fails closed rather than uncapping free spend', async () => {
  const { deps, calls } = makeDeps({ quota: () => Promise.reject(new Error('db down')) });
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 503);
  assertEquals((await response.json()).error.code, 'quota_unavailable');
  assertEquals(calls.fetch.length, 0);
});

// ---------------------------------------------------------------------------
// Entitlement
// ---------------------------------------------------------------------------

Deno.test('no RevenueCat key means everyone is free and RevenueCat is never called', async () => {
  _resetEntitlementCache();
  const { deps, calls } = makeDeps();
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals((await response.json()).plan, 'free');
  assert(!calls.fetch.some((call) => call.url.includes('revenuecat')));
});

/** RevenueCat answering that this user holds a live pro entitlement. */
function revenueCatPro(url: string): Response {
  return url.includes('revenuecat')
    ? new Response(JSON.stringify({ subscriber: { entitlements: { pro: { expires_date: '2099-01-01T00:00:00Z' } } } }), { status: 200 })
    : openAiSuccess();
}

Deno.test('an active pro entitlement is charged against the fair-use ceiling of 500', async () => {
  _resetEntitlementCache();
  const { deps, calls } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    quota: () => Promise.resolve({ allowed: true, used: 42 }),
    fetchImpl: (url) => Promise.resolve(revenueCatPro(url)),
  });

  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.plan, 'pro');
  assertEquals(body.quota, { used: 42, limit: 500, remaining: 458, month: '2026-08' });
  assertEquals(calls.quota[0].limit, 500);
});

Deno.test('a pro caller past the fair-use ceiling is refused like anyone else', async () => {
  _resetEntitlementCache();
  const { deps, calls } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    // 500 a month is not reachable by hand. A "no" here is a script on a
    // stolen key, and the ceiling exists to stop it.
    quota: () => Promise.resolve({ allowed: false, used: 900 }),
    fetchImpl: (url) => Promise.resolve(revenueCatPro(url)),
  });

  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 429);
  const body = await response.json();
  assertEquals(body.error.code, 'quota_exhausted');
  assertEquals(body.quota, { used: 900, limit: 500, remaining: 0, month: '2026-08' });
  // Nothing is spent upstream once the ceiling is hit.
  assert(!calls.fetch.some((call) => call.url.includes('openai')));
});

Deno.test('a counter that throws still lets a paying user through', async () => {
  _resetEntitlementCache();
  const { deps } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    quota: () => Promise.reject(new Error('db down')),
    fetchImpl: (url) => Promise.resolve(revenueCatPro(url)),
  });

  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.plan, 'pro');
  // An outage is not evidence of abuse, so the count reads as zero rather than
  // as a wall.
  assertEquals(body.quota, { used: 0, limit: 500, remaining: 500, month: '2026-08' });
});

Deno.test('an expired pro entitlement is free', async () => {
  _resetEntitlementCache();
  const { deps } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    fetchImpl: (url) =>
      Promise.resolve(
        url.includes('revenuecat')
          ? new Response(JSON.stringify({ subscriber: { entitlements: { pro: { expires_date: '2020-01-01T00:00:00Z' } } } }), { status: 200 })
          : openAiSuccess(),
      ),
  });
  assertEquals(await resolvePlan(deps, VALID_USER), 'free');
});

Deno.test('a null expiry is a lifetime entitlement', async () => {
  _resetEntitlementCache();
  const { deps } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    fetchImpl: () => Promise.resolve(new Response(JSON.stringify({ subscriber: { entitlements: { pro: { expires_date: null } } } }), { status: 200 })),
  });
  assertEquals(await resolvePlan(deps, VALID_USER), 'pro');
});

Deno.test('an unreachable RevenueCat falls open to free', async () => {
  _resetEntitlementCache();
  const { deps } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    fetchImpl: () => Promise.reject(new Error('network')),
  });
  assertEquals(await resolvePlan(deps, VALID_USER), 'free');
});

Deno.test('a RevenueCat that never answers is abandoned, and the caller stays free', async () => {
  _resetEntitlementCache();
  // 50 ms rather than the production five seconds, so the suite does not wait
  // out a real timeout to prove the timeout exists.
  const timeoutMs = 50;
  const { deps, calls } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    revenueCatTimeoutMs: timeoutMs,
    // Settles only when the handler's own signal fires. Without a timeout on
    // the fetch this test would hang forever, which is the point.
    fetchImpl: (_url, init) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
      }),
  });

  const startedAt = Date.now();
  assertEquals(await resolvePlan(deps, VALID_USER), 'free');
  const elapsed = Date.now() - startedAt;
  assert(calls.fetch[0].init?.signal instanceof AbortSignal);
  // The injected bound is what fired, not the production one.
  assert(elapsed >= timeoutMs, `gave up after ${elapsed}ms`);
  assert(elapsed < REVENUECAT_TIMEOUT_MS, `gave up after ${elapsed}ms`);
});

Deno.test('a resolved entitlement is cached, a failed one is not', async () => {
  _resetEntitlementCache();
  let hits = 0;
  const proOptions: StubOptions = {
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    fetchImpl: () => {
      hits += 1;
      return Promise.resolve(new Response(JSON.stringify({ subscriber: { entitlements: { pro: { expires_date: null } } } }), { status: 200 }));
    },
  };
  const { deps } = makeDeps(proOptions);
  assertEquals(await resolvePlan(deps, VALID_USER), 'pro');
  assertEquals(await resolvePlan(deps, VALID_USER), 'pro');
  assertEquals(hits, 1);

  _resetEntitlementCache();
  let failures = 0;
  const { deps: failingDeps } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    fetchImpl: () => {
      failures += 1;
      return Promise.resolve(new Response('nope', { status: 500 }));
    },
  });
  assertEquals(await resolvePlan(failingDeps, 'tidy:other-user-id-value'), 'free');
  assertEquals(await resolvePlan(failingDeps, 'tidy:other-user-id-value'), 'free');
  assertEquals(failures, 2);
});

// ---------------------------------------------------------------------------
// Upstream call and success shape
// ---------------------------------------------------------------------------

Deno.test('a successful tidy returns note, quota and plan', async () => {
  _resetEntitlementCache();
  const { deps } = makeDeps({ quota: () => Promise.resolve({ allowed: true, used: 3 }) });
  const response = await handleRequest(makeRequest({ text: 'call the dentist', appUserId: VALID_USER, clientVersion: '1.2.0' }), deps);

  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.note, SAMPLE_NOTE);
  assertEquals(body.quota, { used: 3, limit: 5, remaining: 2, month: '2026-08' });
  assertEquals(body.plan, 'free');
});

Deno.test('note is sanitized before it leaves', async () => {
  _resetEntitlementCache();
  const dirty = {
    noteKind: 'list',
    level: 2,
    title: 'Groceries',
    summary: '',
    sections: [{
      heading: 'Store',
      kind: 'bullets',
      items: [{ text: 'Buy milk', done: false }, { text: 'Buy milk', done: false }],
    }],
  };
  const { deps } = makeDeps({ fetchImpl: () => Promise.resolve(openAiSuccess(dirty)) });
  const response = await handleRequest(makeRequest({ text: 'call the dentist', appUserId: VALID_USER }), deps);
  const body = await response.json();
  assertEquals(body.note.sections[0].items, [{ text: 'Buy milk', done: false }]);
});

Deno.test('classification never reaches the app', async () => {
  _resetEntitlementCache();
  const { deps } = makeDeps();
  const response = await handleRequest(makeRequest({ text: 'call the dentist', appUserId: VALID_USER }), deps);
  const body = await response.json();
  assertEquals(Object.keys(body.note).sort(), ['sections', 'summary', 'title']);
});

Deno.test('the upstream request carries the model, the raw note and the source hint', async () => {
  const { deps, calls } = makeDeps({ env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_OPENAI_MODEL: 'gpt-4o-mini' } });
  await handleRequest(makeRequest({ text: 'call the dentist', appUserId: VALID_USER }), deps);

  const call = calls.fetch[0];
  assertEquals(call.url, 'https://api.openai.com/v1/chat/completions');
  const sent = JSON.parse(String(call.init?.body));
  assertEquals(sent.model, 'gpt-4o-mini');
  assertEquals(sent.messages[1].content, 'call the dentist');
  assert(sent.messages[0].content.includes('shared from Apple Notes'));
  // A model outside the reasoning families takes the low temperature.
  assertEquals(sent.temperature, 0.2);
});

Deno.test('reasoning models are sent no temperature', async () => {
  const { deps, calls } = makeDeps({ env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_OPENAI_MODEL: 'gpt-5-mini' } });
  await handleRequest(makeRequest({ text: 'call the dentist', appUserId: VALID_USER }), deps);
  const sent = JSON.parse(String(calls.fetch[0].init?.body));
  assertEquals(sent.model, 'gpt-5-mini');
  assertEquals(sent.temperature, undefined);
});

Deno.test('the default model is used when the env var is unset', async () => {
  const { deps, calls } = makeDeps();
  await handleRequest(makeRequest({ text: 'call the dentist', appUserId: VALID_USER }), deps);
  assertEquals(JSON.parse(String(calls.fetch[0].init?.body)).model, 'gpt-5-mini');
});

Deno.test('an upstream 500 becomes 502 upstream_error', async () => {
  const { deps } = makeDeps({ fetchImpl: () => Promise.resolve(new Response('boom', { status: 500 })) });
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 502);
  assertEquals((await response.json()).error.code, 'upstream_error');
});

Deno.test('a model refusal becomes 502 upstream_error', async () => {
  const { deps } = makeDeps({
    fetchImpl: () => Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { refusal: 'no' } }] }), { status: 200 })),
  });
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 502);
  assertEquals((await response.json()).error.code, 'upstream_error');
});

Deno.test('undecodable model output becomes 502 upstream_error', async () => {
  const { deps } = makeDeps({
    fetchImpl: () => Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: 'not json' } }] }), { status: 200 })),
  });
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 502);
});

Deno.test('a missing OpenAI key is an upstream error, and the quota is already spent', async () => {
  const { deps } = makeDeps({ env: {} });
  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 502);
  assertEquals((await response.json()).error.code, 'upstream_error');
});

Deno.test('a 400 naming temperature is retried once without it', async () => {
  let attempts = 0;
  const { deps } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_OPENAI_MODEL: 'gpt-4o-mini' },
    fetchImpl: () => {
      attempts += 1;
      if (attempts === 1) {
        return Promise.resolve(new Response(JSON.stringify({ error: { message: "Unsupported value: 'temperature'" } }), { status: 400 }));
      }
      return Promise.resolve(openAiSuccess());
    },
  });

  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 200);
  assertEquals(attempts, 2);
});

// ---------------------------------------------------------------------------
// Voice path
// ---------------------------------------------------------------------------

Deno.test('a multipart request with no audio part is an invalid request', async () => {
  const { deps, calls } = makeVoiceDeps();
  const response = await handleRequest(makeVoiceRequest({ audio: null }), deps);
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.code, 'invalid_request');
  assertEquals(calls.quota.length, 0);
  assertEquals(calls.fetch.length, 0);
});

Deno.test('audio over 12 MB is refused before a quota is spent on it', async () => {
  const { deps, calls } = makeVoiceDeps();
  const response = await handleRequest(makeVoiceRequest({ audio: audioFile(13 * 1024 * 1024) }), deps);
  assertEquals(response.status, 413);
  assertEquals((await response.json()).error.code, 'audio_too_large');
  assertEquals(calls.quota.length, 0);
  assertEquals(calls.fetch.length, 0);
});

Deno.test('a recording longer than the ceiling is refused before a quota is spent on it', async () => {
  const { deps, calls } = makeVoiceDeps();
  const response = await handleRequest(makeVoiceRequest({ durationSeconds: '400' }), deps);
  assertEquals(response.status, 413);
  assertEquals((await response.json()).error.code, 'audio_too_large');
  assertEquals(calls.quota.length, 0);
  assertEquals(calls.fetch.length, 0);
});

Deno.test('a voice tidy charges once, then organizes what Whisper heard', async () => {
  _resetEntitlementCache();
  const { deps, calls } = makeVoiceDeps({ quota: () => Promise.resolve({ allowed: true, used: 1 }) });
  const response = await handleRequest(makeVoiceRequest(), deps);

  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.note, SAMPLE_NOTE);
  assertEquals(body.quota, { used: 1, limit: 5, remaining: 4, month: '2026-08' });
  assertEquals(body.plan, 'free');
  assertEquals(body.transcript, TRANSCRIPT);

  // One transcription, one organize, and exactly one charge for the pair.
  assertEquals(calls.quota.length, 1);
  assertEquals(calls.fetch.length, 2);
  assertEquals(calls.fetch[0].url, 'https://api.openai.com/v1/audio/transcriptions');
  assertEquals(calls.fetch[1].url, 'https://api.openai.com/v1/chat/completions');
  const sent = JSON.parse(String(calls.fetch[1].init?.body));
  assertEquals(sent.messages[1].content, TRANSCRIPT);
  assert(sent.messages[0].content.includes('transcript of a voice recording'));
});

Deno.test('the Whisper request carries the file, the model, plain text and the style prompt', async () => {
  const { deps, calls } = makeVoiceDeps();
  await handleRequest(makeVoiceRequest(), deps);

  const form = whisperForm(calls.fetch[0]);
  // The part is forwarded as it arrived, not re-encoded.
  const file = form.get('file') as File | null;
  assertEquals(file?.name, 'note.m4a');
  assertEquals(file?.size, 2048);
  assertEquals(form.get('model'), 'whisper-1');
  assertEquals(form.get('response_format'), 'text');
  assertStringIncludes(String(form.get('prompt')), 'normal punctuation and sentence casing');
  // No locale was sent, so Whisper is left to detect the language itself.
  assertEquals(form.get('language'), null);
});

Deno.test('the Whisper model is swappable without a deploy', async () => {
  const { deps, calls } = makeVoiceDeps({ env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_WHISPER_MODEL: 'whisper-next' } });
  await handleRequest(makeVoiceRequest(), deps);
  assertEquals(whisperForm(calls.fetch[0]).get('model'), 'whisper-next');
});

Deno.test('a locale is narrowed to the language subtag Whisper understands', async () => {
  const { deps, calls } = makeVoiceDeps();
  await handleRequest(makeVoiceRequest({ locale: 'en-US' }), deps);
  assertEquals(whisperForm(calls.fetch[0]).get('language'), 'en');
});

Deno.test('a failed transcription is 502, and the quota it already spent stays spent', async () => {
  const { deps, calls } = makeVoiceDeps({ whisper: () => Promise.resolve(new Response('boom', { status: 500 })) });
  const response = await handleRequest(makeVoiceRequest(), deps);

  assertEquals(response.status, 502);
  assertEquals((await response.json()).error.code, 'upstream_error');
  // The charge lands before Whisper on purpose, so a failure burns a tidy. That
  // is the accepted cost of not handing free transcription to an exhausted user.
  assertEquals(calls.quota.length, 1);
});

Deno.test('a transcript of nothing but whitespace is 422 empty_transcript', async () => {
  const { deps, calls } = makeVoiceDeps({ whisper: () => Promise.resolve(whisperSuccess('   \n\t  ')) });
  const response = await handleRequest(makeVoiceRequest(), deps);

  assertEquals(response.status, 422);
  assertEquals((await response.json()).error.code, 'empty_transcript');
  // Nothing was worth organizing, so the organizer was never called.
  assertEquals(calls.fetch.length, 1);
});

Deno.test('the voice path hits the same quota wall as the text path', async () => {
  _resetEntitlementCache();
  const { deps, calls } = makeVoiceDeps({ quota: () => Promise.resolve({ allowed: false, used: 5 }) });
  const response = await handleRequest(makeVoiceRequest(), deps);

  assertEquals(response.status, 429);
  const body = await response.json();
  assertEquals(body.error.code, 'quota_exhausted');
  assertEquals(body.quota, { used: 5, limit: 5, remaining: 0, month: '2026-08' });
  // The sixth call of the month reaches neither Whisper nor the organizer.
  assertEquals(calls.fetch.length, 0);
});

Deno.test('a pro entitlement resolves on the voice path too', async () => {
  _resetEntitlementCache();
  const { deps, calls } = makeVoiceDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    fetchImpl: (url) =>
      Promise.resolve(
        url.includes('revenuecat')
          ? new Response(JSON.stringify({ subscriber: { entitlements: { pro: { expires_date: null } } } }), { status: 200 })
          : openAiSuccess(),
      ),
  });

  const response = await handleRequest(makeVoiceRequest(), deps);
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.plan, 'pro');
  assertEquals(body.quota.limit, 500);
  assertEquals(calls.quota[0].limit, 500);
});

Deno.test('the text path gained no transcript field', async () => {
  _resetEntitlementCache();
  const { deps } = makeDeps();
  const response = await handleRequest(makeRequest({ text: 'call the dentist', appUserId: VALID_USER }), deps);
  const body = await response.json();
  assertEquals(Object.keys(body).sort(), ['note', 'plan', 'quota']);
});
