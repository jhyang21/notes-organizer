// Tests for the cloud organizer. Every dependency the handler touches is
// injected, so nothing here opens a socket or needs a database.
//
// Run: deno test --allow-net --allow-env supabase/functions/tidynote_organize/

import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  type Deps,
  type OrganizedNote,
  _resetEntitlementCache,
  clientIp,
  handleRequest,
  minuteKey,
  monthKey,
  parseNote,
  resolvePlan,
  sha256Hex,
} from './index.ts';

const VALID_USER = 'tidy:11111111-2222-3333-4444-555555555555';
const FIXED_NOW = new Date('2026-08-07T14:03:22.000Z');

const SAMPLE_NOTE: OrganizedNote = {
  title: 'Dentist and Sarah Birthday',
  sections: [{ heading: 'To Do', bullets: ['Call the dentist tomorrow'] }],
  actionItems: ['Call the dentist tomorrow'],
};

function openAiSuccess(note: unknown = SAMPLE_NOTE): Response {
  return new Response(
    JSON.stringify({
      choices: [{ message: { content: JSON.stringify(note) } }],
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
    env: (key: string) => (options.env ?? { OPENAI_API_KEY: 'sk-test' })[key],
    now: () => options.now ?? FIXED_NOW,
    consumeRate: (key, window, limit) => {
      calls.rate.push({ key, window, limit });
      return options.rate ? options.rate(key, window, limit) : Promise.resolve(true);
    },
    consumeQuota: (userId, month, limit) => {
      calls.quota.push({ userId, month, limit });
      return options.quota ? options.quota(userId, month, limit) : Promise.resolve({ allowed: true, used: 1 });
    },
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

Deno.test('parseNote tolerates missing and mistyped fields', () => {
  const note = parseNote(JSON.stringify({ title: 'T', sections: [{ heading: 'H', bullets: ['a', 7] }] }));
  assertEquals(note.title, 'T');
  assertEquals(note.sections[0].bullets, ['a']);
  assertEquals(note.actionItems, []);
});

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

Deno.test('OPTIONS is a CORS preflight', async () => {
  const { deps } = makeDeps();
  const response = await handleRequest(new Request('https://example.test', { method: 'OPTIONS' }), deps);
  assertEquals(response.status, 204);
  assertEquals(response.headers.get('Access-Control-Allow-Origin'), '*');
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
  assertEquals(calls.rate[1].key, `ip:${await sha256Hex('203.0.113.9')}`);
  assertEquals(calls.rate[1].limit, 20);
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

Deno.test('an active pro entitlement is never blocked by the quota', async () => {
  _resetEntitlementCache();
  const { deps, calls } = makeDeps({
    env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_RC_API_KEY: 'rc-test' },
    // Even a hard "no" from the counter must not stop a paying user.
    quota: () => Promise.resolve({ allowed: false, used: 900 }),
    fetchImpl: (url) =>
      Promise.resolve(
        url.includes('revenuecat')
          ? new Response(JSON.stringify({ subscriber: { entitlements: { pro: { expires_date: '2099-01-01T00:00:00Z' } } } }), { status: 200 })
          : openAiSuccess(),
      ),
  });

  const response = await handleRequest(makeRequest({ text: 'hello there', appUserId: VALID_USER }), deps);
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.plan, 'pro');
  assertEquals(body.quota.limit, 1_000_000);
  assertEquals(calls.quota[0].limit, 1_000_000);
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

Deno.test('the upstream request carries the model, the ported prompt and the wrapped transcript', async () => {
  const { deps, calls } = makeDeps({ env: { OPENAI_API_KEY: 'sk-test', TIDYNOTE_OPENAI_MODEL: 'gpt-4o-mini' } });
  await handleRequest(makeRequest({ text: 'call the dentist', appUserId: VALID_USER }), deps);

  const call = calls.fetch[0];
  assertEquals(call.url, 'https://api.openai.com/v1/chat/completions');
  const sent = JSON.parse(String(call.init?.body));
  assertEquals(sent.model, 'gpt-4o-mini');
  assertEquals(sent.response_format.json_schema.strict, true);
  assertEquals(sent.response_format.json_schema.schema.required, ['title', 'sections', 'actionItems']);
  assertEquals(sent.messages[1].content, '<transcript>call the dentist</transcript>');
  assertStringIncludes(sent.messages[0].content, 'organizer, not a summarizer');
  assertStringIncludes(sent.messages[0].content, 'Length is never a reason to summarize');
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
