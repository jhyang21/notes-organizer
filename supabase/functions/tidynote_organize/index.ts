// TidyNote's cloud organizer ("premium tidy").
//
// One endpoint: take a raw transcript, return an OrganizedNote. Everything else
// here exists to keep a publishable anon key -- which ships inside the app and
// is therefore extractable -- from turning into an unbounded OpenAI bill:
// per-user and per-IP rate limits, a server-authoritative monthly quota, and a
// RevenueCat entitlement check.
//
// This function is deliberately self-contained. It runs in the same Supabase
// project as Relora but shares no code with it, so a change to Relora's _shared
// helpers can never alter TidyNote's behavior.
//
// The note text is never logged.

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.56.0';
import { SYSTEM_PROMPT } from './prompt.ts';

const MAX_TEXT_CHARS = 60_000;
const APP_USER_ID_PATTERN = /^[A-Za-z0-9:_\-.]{8,80}$/;

const FREE_MONTHLY_LIMIT = 5;
// Pro is unlimited in product terms. It still goes through the same counter so
// fair-use abuse is visible in the table; the ceiling is only high enough that
// no human reaches it.
const PRO_MONTHLY_LIMIT = 1_000_000;

const USER_REQUESTS_PER_MINUTE = 6;
const IP_REQUESTS_PER_MINUTE = 20;

const ENTITLEMENT_CACHE_TTL_MS = 5 * 60 * 1000;
const OPENAI_TIMEOUT_MS = 60_000;
const DEFAULT_MODEL = 'gpt-5-mini';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

/** Mirrors `OrganizedNote` in NotesOrganizerKit. The domain model is the wire
 * format -- there is no DTO layer, so these two must not drift. */
export interface OrganizedNote {
  title: string;
  sections: { heading: string; bullets: string[] }[];
  actionItems: string[];
}

export interface QuotaState {
  used: number;
  limit: number;
  remaining: number;
  month: string;
}

export type Plan = 'free' | 'pro';

/** Everything the handler touches that isn't pure, injected so tests never open
 * a socket or need a database. */
export interface Deps {
  fetch: typeof fetch;
  env(key: string): string | undefined;
  now(): Date;
  consumeRate(key: string, window: string, limit: number): Promise<boolean>;
  consumeQuota(userId: string, month: string, limit: number): Promise<{ allowed: boolean; used: number }>;
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

function jsonResponse(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
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

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

/** First hop of X-Forwarded-For. Later hops are appended by our own proxies, so
 * only the first entry identifies the caller. */
export function clientIp(req: Request): string | null {
  const header = req.headers.get('x-forwarded-for');
  if (!header) return null;
  const first = header.split(',')[0]?.trim();
  return first ? first : null;
}

function quotaState(used: number, limit: number, month: string): QuotaState {
  return { used, limit, remaining: Math.max(limit - used, 0), month };
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
      { headers: { Authorization: `Bearer ${apiKey}` } },
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
// OpenAI
// ---------------------------------------------------------------------------

const NOTE_JSON_SCHEMA = {
  name: 'organized_note',
  strict: true,
  schema: {
    type: 'object',
    additionalProperties: false,
    required: ['title', 'sections', 'actionItems'],
    properties: {
      title: { type: 'string' },
      sections: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['heading', 'bullets'],
          properties: {
            heading: { type: 'string' },
            bullets: { type: 'array', items: { type: 'string' } },
          },
        },
      },
      actionItems: { type: 'array', items: { type: 'string' } },
    },
  },
} as const;

/** gpt-5 and o-series reject any temperature but the default. The model is
 * env-swappable, so decide per request rather than assuming one family. */
function supportsTemperature(model: string): boolean {
  return !/^(gpt-5|o\d)/i.test(model);
}

export function parseNote(raw: string): OrganizedNote {
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  const sections = Array.isArray(parsed.sections) ? parsed.sections : [];
  const actionItems = Array.isArray(parsed.actionItems) ? parsed.actionItems : [];
  return {
    title: typeof parsed.title === 'string' ? parsed.title : '',
    sections: sections.map((section) => {
      const value = (section ?? {}) as Record<string, unknown>;
      const bullets = Array.isArray(value.bullets) ? value.bullets : [];
      return {
        heading: typeof value.heading === 'string' ? value.heading : '',
        bullets: bullets.filter((bullet): bullet is string => typeof bullet === 'string'),
      };
    }),
    actionItems: actionItems.filter((item): item is string => typeof item === 'string'),
  };
}

interface OrganizeOutcome {
  note: OrganizedNote;
  usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
}

async function organize(deps: Deps, text: string, model: string, apiKey: string): Promise<OrganizeOutcome> {
  const body: Record<string, unknown> = {
    model,
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: `<transcript>${text}</transcript>` },
    ],
    response_format: { type: 'json_schema', json_schema: NOTE_JSON_SCHEMA },
  };
  if (supportsTemperature(model)) body.temperature = 0.2;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), OPENAI_TIMEOUT_MS);

  let response: Response;
  try {
    response = await deps.fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    // The model name comes from an env var so it can be swapped without a
    // deploy. If the new model turns out to reject `temperature`, retry once
    // without it rather than making the swap a code change.
    if (response.status === 400 && body.temperature !== undefined) {
      const detail = await response.text();
      if (detail.toLowerCase().includes('temperature')) {
        delete body.temperature;
        response = await deps.fetch('https://api.openai.com/v1/chat/completions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
          body: JSON.stringify(body),
          signal: controller.signal,
        });
      } else {
        throw new Error(`openai status 400: ${detail.slice(0, 200)}`);
      }
    }

    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`openai status ${response.status}: ${detail.slice(0, 200)}`);
    }

    const payload = await response.json();
    const message = payload?.choices?.[0]?.message;
    if (message?.refusal) throw new Error('model refused the transcript');
    const content = message?.content;
    if (typeof content !== 'string' || content.length === 0) {
      throw new Error('empty completion content');
    }
    return { note: parseNote(content), usage: payload?.usage };
  } finally {
    clearTimeout(timer);
  }
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

export async function handleRequest(req: Request, deps: Deps): Promise<Response> {
  const startedAt = Date.now();
  let plan: Plan = 'free';
  let userTag = 'none';
  let status = 500;
  let code: string | undefined;
  let usage: OrganizeOutcome['usage'];
  const model = deps.env('TIDYNOTE_OPENAI_MODEL') || DEFAULT_MODEL;

  try {
    if (req.method === 'OPTIONS') {
      status = 204;
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (req.method !== 'POST') {
      status = 405;
      code = 'method_not_allowed';
      return errorResponse(code, 'Use POST.', status);
    }

    // --- validate ---------------------------------------------------------
    let payload: { text?: unknown; appUserId?: unknown; clientVersion?: unknown };
    try {
      payload = await req.json();
    } catch {
      status = 400;
      code = 'invalid_request';
      return errorResponse(code, 'Body must be JSON.', status);
    }

    const rawText = typeof payload.text === 'string' ? payload.text : '';
    const text = rawText.trim();
    const appUserId = typeof payload.appUserId === 'string' ? payload.appUserId : '';

    if (!APP_USER_ID_PATTERN.test(appUserId)) {
      status = 400;
      code = 'invalid_request';
      return errorResponse(code, 'appUserId is missing or malformed.', status);
    }

    userTag = (await sha256Hex(appUserId)).slice(0, 12);

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
      const ipKey = `ip:${await sha256Hex(ip)}`;
      if (!(await withinRate(deps, ipKey, window, IP_REQUESTS_PER_MINUTE))) {
        status = 429;
        code = 'rate_limited';
        return errorResponse(code, 'Too many requests. Try again in a moment.', status);
      }
    }

    // --- entitlement + quota ---------------------------------------------
    plan = await resolvePlan(deps, appUserId);
    const month = monthKey(now);
    const limit = plan === 'pro' ? PRO_MONTHLY_LIMIT : FREE_MONTHLY_LIMIT;

    let used: number;
    if (plan === 'pro') {
      // Counted for fair-use visibility only. A counter failure must never
      // stand between a paying user and their note.
      try {
        used = (await deps.consumeQuota(appUserId, month, limit)).used;
      } catch (error) {
        console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'pro_quota_count_failed', message: String(error) }));
        used = 0;
      }
    } else {
      let result: { allowed: boolean; used: number };
      try {
        result = await deps.consumeQuota(appUserId, month, limit);
      } catch (error) {
        // Failing open here would uncap free spend, which is the one thing the
        // quota exists to prevent. Fail closed and let the client offer a retry.
        console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'quota_unavailable', message: String(error) }));
        status = 503;
        code = 'quota_unavailable';
        return errorResponse(code, 'Usage service is unavailable. Try again shortly.', status);
      }
      if (!result.allowed) {
        status = 429;
        code = 'quota_exhausted';
        return errorResponse(code, 'Monthly premium tidies used', status, {
          quota: quotaState(result.used, limit, month),
        });
      }
      used = result.used;
    }

    // --- organize ---------------------------------------------------------
    const openAiKey = deps.env('OPENAI_API_KEY');
    if (!openAiKey) {
      status = 502;
      code = 'upstream_error';
      return errorResponse(code, 'Organizer is not configured.', status);
    }

    let outcome: OrganizeOutcome;
    try {
      outcome = await organize(deps, text, model, openAiKey);
    } catch (error) {
      console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'upstream_failed', message: String(error) }));
      status = 502;
      code = 'upstream_error';
      return errorResponse(code, 'The tidy service could not organize this note.', status);
    }

    usage = outcome.usage;
    status = 200;
    return jsonResponse({ note: outcome.note, quota: quotaState(used, limit, month), plan }, 200);
  } catch (error) {
    console.error(JSON.stringify({ tag: 'tidynote_organize', event: 'unhandled', message: String(error) }));
    status = 500;
    code = 'internal_error';
    return errorResponse(code, 'Something went wrong.', status);
  } finally {
    // One line per request. Note text never appears here, and the user id is
    // reduced to a hash prefix -- enough to correlate a complaint, not enough to
    // rebuild the id.
    console.log(
      JSON.stringify({
        tag: 'tidynote_organize',
        ms: Date.now() - startedAt,
        status,
        plan,
        user: userTag,
        model,
        ...(code ? { code } : {}),
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
  };
}

if (import.meta.main) {
  Deno.serve((req) => handleRequest(req, productionDeps()));
}
