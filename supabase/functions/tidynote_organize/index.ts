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

import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.56.0";
import {
  type Classification,
  type OrganizedNote,
  organizeText,
} from "./organize.ts";

const MAX_TEXT_CHARS = 60_000;
const APP_USER_ID_PATTERN = /^[A-Za-z0-9:_\-.]{8,80}$/;

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
const PRO_MONTHLY_LIMIT = 500;

const USER_REQUESTS_PER_MINUTE = 6;
const IP_REQUESTS_PER_MINUTE = 20;

const ENTITLEMENT_CACHE_TTL_MS = 5 * 60 * 1000;
const DEFAULT_MODEL = "gpt-5-mini";
const WHISPER_TIMEOUT_MS = 45_000;
const DEFAULT_WHISPER_MODEL = "whisper-1";
// Whisper imitates the style of its prompt, so this asks for the punctuation
// and casing it otherwise omits. It is a style sample, not an instruction.
const WHISPER_PROMPT =
  "A personal voice note. Use normal punctuation and sentence casing.";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

export interface QuotaState {
  used: number;
  limit: number;
  remaining: number;
  month: string;
}

export type Plan = "free" | "pro";

/** Everything the handler touches that isn't pure, injected so tests never open
 * a socket or need a database. */
export interface Deps {
  fetch: typeof fetch;
  env(key: string): string | undefined;
  now(): Date;
  consumeRate(key: string, window: string, limit: number): Promise<boolean>;
  consumeQuota(
    userId: string,
    month: string,
    limit: number,
  ): Promise<{ allowed: boolean; used: number }>;
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

function jsonResponse(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function errorResponse(
  code: string,
  message: string,
  status: number,
  extra?: Record<string, unknown>,
): Response {
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
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/** First hop of X-Forwarded-For. Later hops are appended by our own proxies, so
 * only the first entry identifies the caller. */
export function clientIp(req: Request): string | null {
  const header = req.headers.get("x-forwarded-for");
  if (!header) return null;
  const first = header.split(",")[0]?.trim();
  return first ? first : null;
}

function quotaState(used: number, limit: number, month: string): QuotaState {
  return { used, limit, remaining: Math.max(limit - used, 0), month };
}

/** A form part read as text. A missing part and a part that turned out to be a
 * file both read as absent, which is what every caller here wants. */
function formField(form: FormData, name: string): string {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}

// ---------------------------------------------------------------------------
// Entitlement
// ---------------------------------------------------------------------------

const entitlementCache = new Map<
  string,
  { isPro: boolean; expiresAtMs: number }
>();

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
export async function resolvePlan(
  deps: Deps,
  appUserId: string,
): Promise<Plan> {
  const apiKey = deps.env("TIDYNOTE_RC_API_KEY");
  if (!apiKey) return "free";

  const nowMs = deps.now().getTime();
  const cached = entitlementCache.get(appUserId);
  if (cached && cached.expiresAtMs > nowMs) {
    return cached.isPro ? "pro" : "free";
  }

  try {
    const response = await deps.fetch(
      `https://api.revenuecat.com/v1/subscribers/${
        encodeURIComponent(appUserId)
      }`,
      { headers: { Authorization: `Bearer ${apiKey}` } },
    );
    // A transient RevenueCat error is not evidence about this user, so it is
    // never cached -- the next request asks again.
    if (!response.ok) return "free";

    const body = await response.json();
    const entitlements = body?.subscriber?.entitlements ?? body?.entitlements;
    const pro = entitlements?.pro;
    const isPro = Boolean(pro) &&
      entitlementIsActive(pro.expires_date, deps.now());

    entitlementCache.set(appUserId, {
      isPro,
      expiresAtMs: nowMs + ENTITLEMENT_CACHE_TTL_MS,
    });
    return isPro ? "pro" : "free";
  } catch {
    return "free";
  }
}

// ---------------------------------------------------------------------------
// Whisper
// ---------------------------------------------------------------------------

/** Turns the uploaded audio into text. The file is forwarded straight from the
 * parsed form to OpenAI and dropped -- it is never buffered to disk, stored, or
 * written to a log. */
async function transcribe(
  deps: Deps,
  audio: File,
  model: string,
  apiKey: string,
  locale: string,
): Promise<string> {
  const form = new FormData();
  form.append("file", audio);
  form.append("model", model);
  form.append("response_format", "text");
  // A hint, not a constraint: naming the language stops Whisper guessing wrong
  // on a short or noisy clip. The region half of a BCP-47 tag means nothing to
  // the API, so only the language subtag goes over.
  if (locale) form.append("language", locale.slice(0, 2));
  form.append("prompt", WHISPER_PROMPT);

  const response = await deps.fetch(
    "https://api.openai.com/v1/audio/transcriptions",
    {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
      signal: AbortSignal.timeout(WHISPER_TIMEOUT_MS),
    },
  );

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(
      `whisper status ${response.status}: ${detail.slice(0, 200)}`,
    );
  }
  // response_format is text, so the body is the transcript itself.
  return await response.text();
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/** Rate limiting is advisory: if the counter itself is broken, serving the
 * request is better than a hard outage. The quota below is the real ceiling. */
async function withinRate(
  deps: Deps,
  key: string,
  window: string,
  limit: number,
): Promise<boolean> {
  try {
    return await deps.consumeRate(key, window, limit);
  } catch (error) {
    console.error(
      JSON.stringify({
        tag: "tidynote_organize",
        event: "rate_limit_unavailable",
        message: String(error),
      }),
    );
    return true;
  }
}

export async function handleRequest(
  req: Request,
  deps: Deps,
): Promise<Response> {
  const startedAt = Date.now();
  let plan: Plan = "free";
  let userTag = "none";
  let status = 500;
  let code: string | undefined;
  let usage: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  } | undefined;
  let classification: Classification | undefined;
  let note: OrganizedNote | undefined;
  let mode: "text" | "voice" = "text";
  let audioBytes: number | undefined;
  const model = deps.env("TIDYNOTE_OPENAI_MODEL") || DEFAULT_MODEL;

  try {
    if (req.method === "OPTIONS") {
      status = 204;
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (req.method !== "POST") {
      status = 405;
      code = "method_not_allowed";
      return errorResponse(code, "Use POST.", status);
    }

    // --- validate ---------------------------------------------------------
    // The content type is the whole routing decision. Clients that predate the
    // voice path send JSON and must not be able to tell this function grew a
    // second door.
    mode = (req.headers.get("content-type") ?? "").toLowerCase().includes(
        "multipart/form-data",
      )
      ? "voice"
      : "text";

    let appUserId: string;
    let text = "";
    let audio: File | null = null;
    let locale = "";
    let durationSeconds = 0;

    if (mode === "voice") {
      let form: FormData;
      try {
        form = await req.formData();
      } catch {
        status = 400;
        code = "invalid_request";
        return errorResponse(
          code,
          "Body must be a well-formed multipart form.",
          status,
        );
      }
      appUserId = formField(form, "appUserId");
      locale = formField(form, "locale");
      // Advisory: the client measures it, so it is a cheap way to reject a long
      // recording before reading the bytes, not a figure to be trusted.
      durationSeconds = Number(formField(form, "durationSeconds"));
      const part = form.get("audio");
      audio = part instanceof File ? part : null;
    } else {
      let payload: {
        text?: unknown;
        appUserId?: unknown;
        clientVersion?: unknown;
      };
      try {
        payload = await req.json();
      } catch {
        status = 400;
        code = "invalid_request";
        return errorResponse(code, "Body must be JSON.", status);
      }

      const rawText = typeof payload.text === "string" ? payload.text : "";
      text = rawText.trim();
      appUserId = typeof payload.appUserId === "string"
        ? payload.appUserId
        : "";
    }

    if (!APP_USER_ID_PATTERN.test(appUserId)) {
      status = 400;
      code = "invalid_request";
      return errorResponse(code, "appUserId is missing or malformed.", status);
    }

    userTag = (await sha256Hex(appUserId)).slice(0, 12);

    if (mode === "voice") {
      if (!audio) {
        status = 400;
        code = "invalid_request";
        return errorResponse(code, "audio is missing.", status);
      }
      audioBytes = audio.size;
      if (audio.size > MAX_AUDIO_BYTES) {
        status = 413;
        code = "audio_too_large";
        return errorResponse(
          code,
          `audio exceeds ${MAX_AUDIO_BYTES} bytes.`,
          status,
        );
      }
      if (durationSeconds > MAX_AUDIO_SECONDS) {
        status = 413;
        code = "audio_too_large";
        return errorResponse(
          code,
          `audio exceeds ${MAX_AUDIO_SECONDS} seconds.`,
          status,
        );
      }
    } else {
      if (text.length === 0) {
        status = 400;
        code = "invalid_request";
        return errorResponse(code, "text is empty.", status);
      }
      // Measured on the trimmed text, which is what actually reaches the model.
      if (text.length > MAX_TEXT_CHARS) {
        status = 413;
        code = "too_long";
        return errorResponse(
          code,
          `text exceeds ${MAX_TEXT_CHARS} characters.`,
          status,
        );
      }
    }

    // --- rate limit -------------------------------------------------------
    const now = deps.now();
    const window = minuteKey(now);

    if (
      !(await withinRate(
        deps,
        `u:${appUserId}`,
        window,
        USER_REQUESTS_PER_MINUTE,
      ))
    ) {
      status = 429;
      code = "rate_limited";
      return errorResponse(
        code,
        "Too many requests. Try again in a moment.",
        status,
      );
    }

    const ip = clientIp(req);
    if (ip) {
      const ipKey = `ip:${await sha256Hex(ip)}`;
      if (!(await withinRate(deps, ipKey, window, IP_REQUESTS_PER_MINUTE))) {
        status = 429;
        code = "rate_limited";
        return errorResponse(
          code,
          "Too many requests. Try again in a moment.",
          status,
        );
      }
    }

    // --- entitlement + quota ---------------------------------------------
    plan = await resolvePlan(deps, appUserId);
    const month = monthKey(now);
    const limit = plan === "pro" ? PRO_MONTHLY_LIMIT : FREE_MONTHLY_LIMIT;

    let used: number;
    if (plan === "pro") {
      // Counted for fair-use visibility only. A counter failure must never
      // stand between a paying user and their note.
      try {
        used = (await deps.consumeQuota(appUserId, month, limit)).used;
      } catch (error) {
        console.error(
          JSON.stringify({
            tag: "tidynote_organize",
            event: "pro_quota_count_failed",
            message: String(error),
          }),
        );
        used = 0;
      }
    } else {
      let result: { allowed: boolean; used: number };
      try {
        result = await deps.consumeQuota(appUserId, month, limit);
      } catch (error) {
        // Failing open here would uncap free spend, which is the one thing the
        // quota exists to prevent. Fail closed and let the client offer a retry.
        console.error(
          JSON.stringify({
            tag: "tidynote_organize",
            event: "quota_unavailable",
            message: String(error),
          }),
        );
        status = 503;
        code = "quota_unavailable";
        return errorResponse(
          code,
          "Usage service is unavailable. Try again shortly.",
          status,
        );
      }
      if (!result.allowed) {
        status = 429;
        code = "quota_exhausted";
        return errorResponse(code, "Monthly premium tidies used", status, {
          quota: quotaState(result.used, limit, month),
        });
      }
      used = result.used;
    }

    // --- transcribe -------------------------------------------------------
    const openAiKey = deps.env("OPENAI_API_KEY");
    if (!openAiKey) {
      status = 502;
      code = "upstream_error";
      return errorResponse(code, "Organizer is not configured.", status);
    }

    // Voice only -- a JSON request already has its text. The quota was charged
    // above, before this call, on purpose: charging after transcription would
    // let a user whose quota is spent keep uploading audio and get Whisper runs
    // free for the rest of the month.
    if (audio) {
      let transcript: string;
      try {
        transcript = await transcribe(
          deps,
          audio,
          deps.env("TIDYNOTE_WHISPER_MODEL") || DEFAULT_WHISPER_MODEL,
          openAiKey,
          locale,
        );
      } catch (error) {
        console.error(
          JSON.stringify({
            tag: "tidynote_organize",
            event: "transcription_failed",
            message: String(error),
          }),
        );
        status = 502;
        code = "upstream_error";
        return errorResponse(
          code,
          "The tidy service could not transcribe this recording.",
          status,
        );
      }

      text = transcript.trim();
      // Silence, or a recording of nothing but background noise. The user gets
      // a distinct code so the app can say "we heard nothing" rather than
      // blaming the organizer.
      if (text.length === 0) {
        status = 422;
        code = "empty_transcript";
        return errorResponse(
          code,
          "No speech was found in the recording.",
          status,
        );
      }
      if (text.length > MAX_TEXT_CHARS) {
        status = 413;
        code = "too_long";
        return errorResponse(
          code,
          `text exceeds ${MAX_TEXT_CHARS} characters.`,
          status,
        );
      }
    }

    // --- organize ---------------------------------------------------------
    try {
      const source = mode === "voice" ? "voice" : "shared";
      const outcome = await organizeText(
        deps.fetch,
        openAiKey,
        text,
        model,
        source,
      );
      note = outcome.note;
      classification = outcome.classification;
      usage = outcome.usage as typeof usage;
    } catch (error) {
      console.error(
        JSON.stringify({
          tag: "tidynote_organize",
          event: "upstream_failed",
          message: String(error),
        }),
      );
      status = 502;
      code = "upstream_error";
      return errorResponse(
        code,
        "The tidy service could not organize this note.",
        status,
      );
    }

    status = 200;
    // The transcript is returned only to the caller who sent audio -- it is the
    // one thing they have no other copy of. A JSON caller already holds its own
    // text, so its response shape is unchanged. `note` is title/summary/sections
    // only -- classification (`noteKind`, `level`) steered the model and is
    // logged below, but it never reaches the client.
    return jsonResponse(
      {
        note,
        quota: quotaState(used, limit, month),
        plan,
        ...(mode === "voice" ? { transcript: text } : {}),
      },
      200,
    );
  } catch (error) {
    console.error(
      JSON.stringify({
        tag: "tidynote_organize",
        event: "unhandled",
        message: String(error),
      }),
    );
    status = 500;
    code = "internal_error";
    return errorResponse(code, "Something went wrong.", status);
  } finally {
    // One line per request. Note text never appears here, nor any part of the
    // audio -- audio_bytes is a size, not content -- and the user id is reduced
    // to a hash prefix: enough to correlate a complaint, not enough to rebuild
    // the id.
    console.log(
      JSON.stringify({
        tag: "tidynote_organize",
        ms: Date.now() - startedAt,
        status,
        plan,
        mode,
        user: userTag,
        model,
        ...(audioBytes !== undefined ? { audio_bytes: audioBytes } : {}),
        ...(code ? { code } : {}),
        ...(classification
          ? { note_kind: classification.noteKind, level: classification.level }
          : {}),
        ...(note ? { sections: note.sections.length } : {}),
        ...(usage?.prompt_tokens !== undefined
          ? { prompt_tokens: usage.prompt_tokens }
          : {}),
        ...(usage?.completion_tokens !== undefined
          ? { completion_tokens: usage.completion_tokens }
          : {}),
        ...(usage?.total_tokens !== undefined
          ? { total_tokens: usage.total_tokens }
          : {}),
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
    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) {
      throw new Error(
        "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected by the platform and must be present",
      );
    }
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
      const { data, error } = await serviceClient().rpc(
        "tidynote_consume_rate",
        {
          p_key: key,
          p_window: window,
          p_limit: limit,
        },
      );
      if (error) throw new Error(error.message);
      return data === true;
    },
    async consumeQuota(userId, month, limit) {
      const { data, error } = await serviceClient().rpc(
        "tidynote_consume_quota",
        {
          p_user_id: userId,
          p_month: month,
          p_limit: limit,
        },
      );
      if (error) throw new Error(error.message);
      // A set-returning function arrives as an array of rows.
      const row = Array.isArray(data) ? data[0] : data;
      if (!row) throw new Error("tidynote_consume_quota returned no row");
      return { allowed: row.allowed === true, used: Number(row.used ?? 0) };
    },
  };
}

if (import.meta.main) {
  Deno.serve((req) => handleRequest(req, productionDeps()));
}
