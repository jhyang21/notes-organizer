// Live smoke run for the organize prompt.
//
// Spends real OpenAI tokens, so it refuses to run without EVAL_LIVE=1. Run
// from the function folder:
//
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     smoke/smoke.ts --prompt v2
//   deno run ... smoke/smoke.ts --prompt v1
//   deno run ... smoke/smoke.ts --prompt v2 --id modality-five --id injection
//
// Writes smoke/out/<prompt>.md and prints one line per fixture.

import {
  type NoteSection,
  type NoteSource,
  type OrganizedNote,
  organizeText,
} from "../organize.ts";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

interface Fixture {
  id: string;
  source: NoteSource;
  kind_hint: string;
  text: string;
  watch: string;
}

const HERE = new URL(".", import.meta.url);

async function loadFixtures(): Promise<Fixture[]> {
  const raw = await Deno.readTextFile(new URL("notes.jsonl", HERE));
  return raw
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as Fixture);
}

// ---------------------------------------------------------------------------
// A tiny port of the client renderer
// ---------------------------------------------------------------------------
//
// Mirrors `PlainTextRenderer` in NotesOrganizerKit: what the smoke output
// shows has to be what the app would paste into Apple Notes.

function renderSection(section: NoteSection): string[] {
  const lines: string[] = [];
  if (section.heading.length > 0) lines.push(section.heading.toUpperCase());

  switch (section.kind) {
    case "paragraph":
      section.items.forEach((item, index) => {
        if (index > 0) lines.push("");
        lines.push(item.text);
      });
      break;
    case "checklist":
      for (const item of section.items) {
        lines.push(`${item.done ? "☑" : "☐"} ${item.text}`);
      }
      break;
    case "numbered":
      section.items.forEach((item, index) => {
        lines.push(`${index + 1}. ${item.text}`);
      });
      break;
    case "verbatim":
      for (const item of section.items) lines.push(item.text);
      break;
    case "bullets":
    default:
      for (const item of section.items) lines.push(`• ${item.text}`);
      break;
  }
  return lines;
}

function renderNote(note: OrganizedNote): string {
  const lines: string[] = [note.title];
  if (note.summary.length > 0) {
    lines.push("");
    lines.push(note.summary);
  }
  for (const section of note.sections) {
    lines.push("");
    lines.push(...renderSection(section));
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

interface Args {
  prompt: string;
  ids: string[];
}

function parseArgs(argv: string[]): Args {
  let prompt = "v2";
  const ids: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--prompt") prompt = argv[++i] ?? prompt;
    else if (argv[i] === "--id") {
      const value = argv[++i];
      if (value) ids.push(value);
    } else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return { prompt, ids };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

if (import.meta.main) {
  if (Deno.env.get("EVAL_LIVE") !== "1") {
    console.error("refusing to run: set EVAL_LIVE=1 (this call costs money)");
    Deno.exit(1);
  }
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    console.error("refusing to run: OPENAI_API_KEY is not set");
    Deno.exit(1);
  }

  const args = parseArgs(Deno.args);
  const model = Deno.env.get("OPENAI_ORGANIZE_MODEL") ?? "gpt-5-mini";
  const all = await loadFixtures();
  const fixtures = args.ids.length > 0
    ? all.filter((fixture) => args.ids.includes(fixture.id))
    : all;
  if (fixtures.length === 0) {
    console.error("no fixtures matched");
    Deno.exit(1);
  }

  const outDir = new URL("out/", HERE);
  await Deno.mkdir(outDir, { recursive: true });
  const outPath = new URL(`${args.prompt}.md`, outDir);

  // A partial run (--id) patches the existing file rather than truncating it.
  const previous = new Map<string, string>();
  try {
    const existing = await Deno.readTextFile(outPath);
    for (const block of existing.split(/\n(?=## )/)) {
      const match = block.match(/^## ([^\n]+)/);
      if (match) previous.set(match[1].trim(), block.trimEnd());
    }
  } catch { /* first run */ }

  for (const fixture of fixtures) {
    let block: string;
    let row: string;
    try {
      const result = await organizeText(
        fetch,
        apiKey,
        fixture.text,
        model,
        fixture.source,
        args.prompt,
      );
      const output = renderNote(result.note);
      const ratio = (output.length / fixture.text.length).toFixed(2);
      const { noteKind, level } = result.classification;
      block = [
        `## ${fixture.id}`,
        "",
        `- source: \`${fixture.source}\`  kind_hint: \`${fixture.kind_hint}\``,
        `- watch: ${fixture.watch}`,
        `- classification: noteKind=\`${noteKind}\` level=\`${level}\` ` +
        `sections=${result.note.sections.length} ratio=${ratio}`,
        "",
        "INPUT",
        "",
        "```",
        fixture.text,
        "```",
        "",
        "OUTPUT",
        "",
        "```",
        output,
        "```",
      ].join("\n");
      row = [
        fixture.id.padEnd(22),
        noteKind.padEnd(10),
        `L${level}`,
        `${result.note.sections.length}s`.padStart(3),
        ratio.padStart(6),
      ].join(" ");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      block = [
        `## ${fixture.id}`,
        "",
        `- source: \`${fixture.source}\`  kind_hint: \`${fixture.kind_hint}\``,
        `- watch: ${fixture.watch}`,
        `- ERROR: ${message}`,
      ].join("\n");
      row = `${fixture.id.padEnd(22)} ERROR ${message}`;
    }
    previous.set(fixture.id, block);
    console.log(row);
  }

  const order = all.map((fixture) => fixture.id).filter((id) =>
    previous.has(id)
  );
  const header = `# smoke: prompt ${args.prompt} (${model})\n`;
  const body = order.map((id) => previous.get(id)).join("\n\n");
  await Deno.writeTextFile(outPath, `${header}\n${body}\n`);
  console.error(`\nwrote ${outPath.pathname} (${fixtures.length} fixtures)`);
}
