# smoke

Twenty fixtures that exercise the behaviors in `docs/ai/note-behavior.md`: the
modality table, the redundancy budget, verbatim exactness, existing checkbox
state, level choice, and prompt injection. Each fixture carries a `watch` line
saying what must be true of its output. Nothing here asserts automatically —
you read the outputs.

**Run this before changing the prompt, and again after.** A prompt edit that
fixes one fixture routinely breaks another.

```sh
cd supabase/functions/tidynote_organize
EVAL_LIVE=1 deno run --allow-net --allow-env --allow-read --allow-write \
  smoke/smoke.ts --prompt v2
```

`--prompt v1` runs the old prompt for comparison. `--id <id>` (repeatable) runs
one fixture and patches its block into the existing `smoke/out/<prompt>.md`.
The runner refuses to start without `EVAL_LIVE=1` and `OPENAI_API_KEY`.

Cost: 20 fixtures against `gpt-5-mini` is a few cents. `smoke/out/` is
gitignored.
