// The cloud organize call, isolated from the handler.
//
// Import-safe: nothing here reads an env var or does anything at module load
// beyond defining constants and functions, so this file can be imported by
// tests (and by future callers) with no side effects and no network access.
//
// The pipeline is build -> complete -> parse -> sanitize, wired together by
// `organizeText`. Each step is exported separately so tests can drive them one
// at a time.

import { PROMPT_VERSION, PROMPTS } from './prompt.ts';

// ---------------------------------------------------------------------------
// Schema-level vocabulary
// ---------------------------------------------------------------------------

export const SECTION_KINDS = [
  'paragraph',
  'bullets',
  'checklist',
  'numbered',
  'verbatim',
] as const;
export type SectionKind = typeof SECTION_KINDS[number];

export const NOTE_KINDS = [
  'journal',
  'meeting',
  'tasks',
  'list',
  'reference',
  'howto',
  'idea',
  'draft',
  'study',
  'mixed',
] as const;

export const LEVELS = [0, 1, 2, 3, 4] as const;

// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

export interface NoteItem {
  text: string;
  done: boolean;
}

export interface NoteSection {
  heading: string;
  kind: SectionKind;
  items: NoteItem[];
}

/** The shape that reaches the app. Classification (`noteKind`, `level`) never
 * does -- it exists only to steer the model and to log. */
export interface OrganizedNote {
  title: string;
  summary: string;
  sections: NoteSection[];
}

export interface Classification {
  noteKind: string;
  level: number;
}

export type ParsedNote = OrganizedNote & { classification: Classification };

/** Which door the text came in through. Told to the model so it can weigh a
 * voice ramble and a pasted note differently; never itself a fact in the
 * output. */
export type NoteSource = 'voice' | 'shared';

// ---------------------------------------------------------------------------
// Structured-output schema
// ---------------------------------------------------------------------------
//
// Key order matters: `noteKind` and `level` come first so the model commits to
// them before it starts writing prose. Every object node lists every one of
// its own keys in `required` and sets `additionalProperties: false`, which is
// what OpenAI's strict structured outputs mode demands.

export const NOTE_JSON_SCHEMA = {
  name: 'organized_note',
  strict: true,
  schema: {
    type: 'object',
    additionalProperties: false,
    required: ['noteKind', 'level', 'title', 'summary', 'sections'],
    properties: {
      noteKind: {
        type: 'string',
        enum: NOTE_KINDS,
        description: 'What kind of note the input is. Decide this first.',
      },
      level: {
        type: 'integer',
        enum: LEVELS,
        description:
          'How much to change the note: 0 keep as written, 1 clean whitespace and markers, 2 group and order, 3 also cut filler, 4 condense prose into bullets and add a short lead summary. Never lose a fact.',
      },
      title: {
        type: 'string',
        description: 'Short and specific, 3-8 words. Never generic.',
      },
      summary: {
        type: 'string',
        description:
          'Empty string unless level is 4. One or two sentences that add a lead; never repeats the sections.',
      },
      sections: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['heading', 'kind', 'items'],
          properties: {
            heading: {
              type: 'string',
              description: '1-4 words, or empty when no label helps',
            },
            kind: {
              type: 'string',
              enum: SECTION_KINDS,
              description:
                'paragraph = prose, one item per paragraph; bullets = unordered points; checklist = tasks with a done state; numbered = ordered steps; verbatim = lines reproduced exactly: codes, passwords, addresses, Wi-Fi details, URLs, commands, quotes.',
            },
            items: {
              type: 'array',
              items: {
                type: 'object',
                additionalProperties: false,
                required: ['text', 'done'],
                properties: {
                  text: { type: 'string' },
                  done: {
                    type: 'boolean',
                    description:
                      'Only meaningful when kind is checklist; otherwise false',
                  },
                },
              },
            },
          },
        },
      },
    },
  },
} as const;

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

export interface OrganizeMessage {
  role: 'system' | 'user';
  content: string;
}

export interface OrganizeRequest {
  model: string;
  messages: OrganizeMessage[];
  response_format: {
    type: 'json_schema';
    json_schema: typeof NOTE_JSON_SCHEMA;
  };
  temperature?: number;
}

/** gpt-5 and o-series reject any temperature but the default. The model is
 * env-swappable, so decide per request rather than assuming one family. */
function supportsTemperature(model: string): boolean {
  return !/^(gpt-5|o\d)/i.test(model);
}

export function buildOrganizeRequest(
  text: string,
  model: string,
  opts: { source: NoteSource; promptVersion?: string },
): OrganizeRequest {
  const version = opts.promptVersion ?? PROMPT_VERSION;
  const systemPrompt = PROMPTS[version];
  if (!systemPrompt) throw new Error(`unknown prompt version: ${version}`);

  const request: OrganizeRequest = {
    model,
    messages: [
      { role: 'system', content: systemPrompt },
      {
        role: 'user',
        content: `<note source="${opts.source}">\n${text}\n</note>`,
      },
    ],
    response_format: { type: 'json_schema', json_schema: NOTE_JSON_SCHEMA },
  };
  if (supportsTemperature(model)) request.temperature = 0.2;
  return request;
}

// ---------------------------------------------------------------------------
// The OpenAI call
// ---------------------------------------------------------------------------

const OPENAI_TIMEOUT_MS = 60_000;

/** The OpenAI `usage` block, as far as the handler's log line cares. */
export interface TokenUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
}

export interface OrganizeCompletion {
  content: string;
  usage?: TokenUsage;
}

/** Fetch, timeout, and one temperature retry. */
export async function completeOrganize(
  fetchImpl: typeof fetch,
  apiKey: string,
  request: OrganizeRequest,
): Promise<OrganizeCompletion> {
  const body: Record<string, unknown> = { ...request };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), OPENAI_TIMEOUT_MS);

  try {
    let response = await fetchImpl(
      'https://api.openai.com/v1/chat/completions',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${apiKey}`,
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      },
    );

    // The model name comes from an env var so it can be swapped without a
    // deploy. If the new model turns out to reject `temperature`, retry once
    // without it rather than making the swap a code change.
    if (response.status === 400 && body.temperature !== undefined) {
      const detail = await response.text();
      if (detail.toLowerCase().includes('temperature')) {
        delete body.temperature;
        response = await fetchImpl(
          'https://api.openai.com/v1/chat/completions',
          {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              Authorization: `Bearer ${apiKey}`,
            },
            body: JSON.stringify(body),
            signal: controller.signal,
          },
        );
      } else {
        throw new Error(`openai status 400: ${detail.slice(0, 200)}`);
      }
    }

    if (!response.ok) {
      const detail = await response.text();
      throw new Error(
        `openai status ${response.status}: ${detail.slice(0, 200)}`,
      );
    }

    const payload = await response.json();
    const message = payload?.choices?.[0]?.message;
    if (message?.refusal) throw new Error('model refused the transcript');
    const content = message?.content;
    if (typeof content !== 'string' || content.length === 0) {
      throw new Error('empty completion content');
    }
    return { content, usage: payload?.usage };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

function isSectionKind(value: unknown): value is SectionKind {
  return typeof value === 'string' &&
    (SECTION_KINDS as readonly string[]).includes(value);
}

/** Tolerant on purpose: the model is asked for strict JSON, but this is the
 * one seam where a malformed or drifted completion must not crash the
 * handler. Only a non-JSON body or a missing `sections` array is fatal --
 * everything else is coerced to a safe default. */
export function parseNote(raw: string): ParsedNote {
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  if (!Array.isArray(parsed.sections)) {
    throw new Error('missing sections array');
  }

  const level = typeof parsed.level === 'number' &&
      (LEVELS as readonly number[]).includes(parsed.level)
    ? parsed.level
    : -1;
  const noteKind = typeof parsed.noteKind === 'string'
    ? parsed.noteKind
    : 'unknown';
  const title = typeof parsed.title === 'string' ? parsed.title : '';
  const summary = typeof parsed.summary === 'string' ? parsed.summary : '';

  const sections: NoteSection[] = parsed.sections.map((section) => {
    const value = (section ?? {}) as Record<string, unknown>;
    const heading = typeof value.heading === 'string' ? value.heading : '';
    const kind: SectionKind = isSectionKind(value.kind)
      ? value.kind
      : 'bullets';
    const rawItems = Array.isArray(value.items) ? value.items : [];
    const items: NoteItem[] = rawItems.map((item) => {
      if (typeof item === 'string') return { text: item, done: false };
      const itemValue = (item ?? {}) as Record<string, unknown>;
      return {
        text: typeof itemValue.text === 'string' ? itemValue.text : '',
        done: typeof itemValue.done === 'boolean' ? itemValue.done : false,
      };
    });
    return { heading, kind, items };
  });

  return { title, summary, sections, classification: { noteKind, level } };
}

// ---------------------------------------------------------------------------
// Sanitizing
// ---------------------------------------------------------------------------

export const MAX_HEADING_CHARS = 60;
export const GLOBAL_DEDUP_MIN_WORDS = 3;

const LEADING_MARKER_RE =
  /^[•\-*–—]\s*|^\d+[.)]\s*|^☐\s*|^☑\s*|^\[ \]\s*|^\[x\]\s*/i;
const TRAILING_PUNCTUATION_RE = /[.!;:,]+$/;

/** Every run of whitespace -- including newlines -- becomes a single space,
 * and the result is trimmed. Mirrors `TextShaping.collapseWhitespace` in
 * NotesOrganizerKit. */
function collapseWhitespace(text: string): string {
  return text.split(/\s+/).filter((part) => part.length > 0).join(' ');
}

/** Cuts `text` to `maxLength` characters at the last word boundary within
 * that limit, rather than mid-word -- no ellipsis. Mirrors
 * `TextShaping.truncate` in NotesOrganizerKit. */
function truncateAtWordBoundary(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  const truncated = text.slice(0, maxLength);
  const lastSpace = truncated.lastIndexOf(' ');
  return lastSpace >= 0 ? truncated.slice(0, lastSpace) : truncated;
}

/** A key two differently-worded restatements of the same fact still share:
 * normalize width and case, drop one leading list marker and any trailing
 * punctuation, collapse whitespace. */
export function dedupKey(text: string): string {
  let key = text.normalize('NFKC').toLowerCase();
  key = key.replace(LEADING_MARKER_RE, '');
  key = key.replace(TRAILING_PUNCTUATION_RE, '');
  key = key.replace(/\s+/g, ' ').trim();
  return key;
}

function wordCount(key: string): number {
  return key.length === 0 ? 0 : key.split(' ').length;
}

interface ItemRef {
  sectionIndex: number;
  itemIndex: number;
  kind: SectionKind;
  key: string;
}

export function sanitizeNote(note: OrganizedNote): OrganizedNote {
  const title = collapseWhitespace(note.title);
  let summary = collapseWhitespace(note.summary);
  if (summary.length > 0 && summary.toLowerCase() === title.toLowerCase()) {
    summary = '';
  }

  const sections: NoteSection[] = note.sections.map((section) => {
    const heading = truncateAtWordBoundary(
      collapseWhitespace(section.heading),
      MAX_HEADING_CHARS,
    );

    if (section.kind === 'verbatim') {
      const items = section.items.map((item) => ({
        text: item.text.replace(/\r/g, ''),
        done: false,
      }));
      let start = 0;
      while (start < items.length && items[start].text.trim().length === 0) {
        start++;
      }
      let end = items.length;
      while (end > start && items[end - 1].text.trim().length === 0) end--;
      return { heading, kind: section.kind, items: items.slice(start, end) };
    }

    const isChecklist = section.kind === 'checklist';
    const cleaned: NoteItem[] = [];
    let previousKey: string | null = null;
    for (const item of section.items) {
      const text = collapseWhitespace(item.text);
      if (text.length === 0) continue;
      const key = dedupKey(text);
      if (previousKey !== null && key === previousKey) continue; // adjacent duplicate
      previousKey = key;
      cleaned.push({ text, done: isChecklist ? item.done : false });
    }
    return { heading, kind: section.kind, items: cleaned };
  });

  // Cross-section dedup. Keys under GLOBAL_DEDUP_MIN_WORDS words never
  // participate -- "Milk" under two different store headings is meant to
  // survive. Verbatim sections never participate either.
  const refs: ItemRef[] = [];
  sections.forEach((section, sectionIndex) => {
    if (section.kind === 'verbatim') return;
    section.items.forEach((item, itemIndex) => {
      const key = dedupKey(item.text);
      if (wordCount(key) < GLOBAL_DEDUP_MIN_WORDS) return;
      refs.push({ sectionIndex, itemIndex, kind: section.kind, key });
    });
  });

  const byKey = new Map<string, ItemRef[]>();
  for (const ref of refs) {
    const bucket = byKey.get(ref.key);
    if (bucket) bucket.push(ref);
    else byKey.set(ref.key, [ref]);
  }

  // Only rule: a checklist item wins over a non-checklist restatement of the
  // same fact. Two non-checklist restatements of the same fact (e.g. the same
  // weekly task noted under two different day headings) both survive -- there
  // is no "first occurrence wins" pass among non-checklist sections.
  const drop = new Set<string>(); // "sectionIndex:itemIndex"
  for (const occurrences of byKey.values()) {
    const hasChecklist = occurrences.some((ref) => ref.kind === 'checklist');
    if (!hasChecklist) continue;
    for (const ref of occurrences) {
      if (ref.kind !== 'checklist') {
        drop.add(`${ref.sectionIndex}:${ref.itemIndex}`);
      }
    }
  }

  const deduped: NoteSection[] = sections.map((section, sectionIndex) => {
    if (section.kind === 'verbatim') return section;
    const items = section.items.filter((_, itemIndex) =>
      !drop.has(`${sectionIndex}:${itemIndex}`)
    );
    return { ...section, items };
  });

  return {
    title,
    summary,
    sections: deduped.filter((section) => section.items.length > 0),
  };
}

// ---------------------------------------------------------------------------
// The whole pipeline
// ---------------------------------------------------------------------------

export interface OrganizeResult {
  note: OrganizedNote;
  classification: Classification;
  usage?: TokenUsage;
}

export async function organizeText(
  fetchImpl: typeof fetch,
  apiKey: string,
  text: string,
  model: string,
  source: NoteSource,
): Promise<OrganizeResult> {
  const request = buildOrganizeRequest(text, model, { source });
  const completion = await completeOrganize(fetchImpl, apiKey, request);
  const parsed = parseNote(completion.content);
  const note = sanitizeNote({
    title: parsed.title,
    summary: parsed.summary,
    sections: parsed.sections,
  });
  return {
    note,
    classification: parsed.classification,
    usage: completion.usage,
  };
}
