# On-device model benchmark

How the embedded (MLX) model catalog was chosen. Measured on a real
**36-minute** recording: 52k characters of transcript, 43 turns, ~12k prompt
tokens. The meeting content is private and does not appear here; the
methodology and results do.

Each model was loaded once and ran **alone, in sequence**, on the app's two
tasks (summary and point by point) with the production prompts,
`temperature = 0` and the real token limits (2,048 and 8,192).

## Structure: timings and mechanical defects

| Model | Summary | Point by point | |
|---|---|---|---|
| Qwen 3.5 2B | 4 s | 10 s | ✅ |
| Gemma 4 E2B | 4 s | 8 s | ✅ |
| Llama 3.2 3B | 10 s | 15 s | ✅ |
| Qwen 3.5 4B | 10 s | 22 s | ✅ |
| Gemma 4 E4B | 6 s | 29 s | ✅ |
| Llama 3.1 8B | 19 s | 30 s | ✅ |
| Nemotron Nano 9B | 26 s | 39 s | ✅ |
| Qwen 3.5 9B | 20 s | 46 s | ✅ |
| Bonsai 27B | 46 s | 78 s | ✅ |
| Bonsai 8B | 16 s | 177 s | ❌ hits the token ceiling repeating the same sentence |
| Nemotron 3 Nano 4B | 11 s | 95 s | ❌ hits the token ceiling |
| Gemma 4 12B | n/a | n/a | not measured (see limitations) |

Every model that passes answers in the configured language and none invents a
participant name. Both are results of the prompt fixes below.

## Content quality: reading the outputs against the transcript

Clean structure does not mean a good summary. Each output was read against the
full transcript and judged for faithfulness and coverage:

| Model | Verdict |
|---|---|
| **Qwen 3.5 4B** | ⭐ the best on both tasks: covers the whole meeting, details correct |
| **Qwen 3.5 9B** | ⭐ same level, more detail; one isolated artifact (characters from another alphabet) |
| **Gemma 4 E4B** | ⭐ excellent point by point from start to finish; short summaries |
| Nemotron Nano 9B | faithful content, but breaks the requested format (numbers sections, adds meta commentary) |
| Bonsai 27B | full coverage, but repeats the same sentence across several sections |
| Gemma 4 E2B | the fastest, but its point by point **covers only the first minutes** of the meeting |
| Qwen 3.5 2B | same volume as the 4B with shallow content, repeated in circles |
| Llama 3.1 8B | vague, no concrete detail, duplicated sections |
| Llama 3.2 3B | **fabricates the meeting's structure**, narrating questions and answers that never happened |

Catches that no automatic metric would flag:

- One model turned a **joke** made in passing into a formal commitment under
  "Next steps".
- Another invented **a deliverable with a deadline** nobody agreed to,
  mistaking the date of the next meeting for a due date.
- The model with the fastest numbers delivers an 11-section point by point, all
  of it about the first minutes; the rest of the meeting does not exist in the
  text.
- The meeting had **exactly one real commitment**. The good models capture it
  cleanly; the weak ones bury it in task lists nobody signed up for.

## The cut

Five stayed, each with a reason to exist:

| Kept | Role |
|---|---|
| Qwen 3.5 4B | default, the most faithful |
| Qwen 3.5 9B | more detail if you can wait |
| Gemma 4 E4B | the best point by point after the Qwens |
| Nemotron Nano 9B | faithful middle option (defect is only cosmetic) |
| Gemma 4 12B | the only multimodal one; measurement inside the app still pending |

| Removed | Reason |
|---|---|
| Llama 3.2 3B | fabricates meeting structure, disqualifying in an app built on faithfulness |
| Qwen 3.5 2B | shallow and repetitive on both tasks |
| Llama 3.1 8B | vague and dominated by better, smaller options |
| Gemma 4 E2B | ignores most of the meeting in the point by point |
| Bonsai 27B | dominated by Qwen 9B: same download, slower, lower quality |
| Bonsai 8B | ignores the prompt's limit, 3 minutes of repeated text |
| Nemotron 3 Nano 4B | ignores the prompt's limit, hits the token ceiling |

Anyone who had a removed model selected keeps using it: the Settings picker
holds on to the current model even when it is out of the catalog.

## Lessons that shaped the prompts

The process knocked down two assumptions, and the fixes are in production:

1. **Unbounded lists make small models loop.** The point by point prompt said
   "length is not a problem" and the summary prompt asked for bullets with no
   cap; four models repeated the same line until they hit the token ceiling. An
   explicit number ("at most 8 bullets", "at most 12 parts") fixed three of the
   four; the ones it did not fix left the catalog for defects of their own.
   Isolated by ablation, with the token ceiling held constant, to separate
   cause from symptom.
2. **Asking for grouping by person forces invention.** The transcript only
   labels `You`/`Others`; demanding "Next steps grouped by person" made models
   fish for names said out loud and assign tasks to people who never took
   them. A literal example with a fictional name inside the prompt even became
   a "participant" of the meeting. The prompts now tell the model what it does
   not know and instruct it to write the action without a name when the owner
   is unclear.
3. **A language instruction at the top gets lost.** With 12k tokens of
   transcript between the instruction and the answer, 5 of 12 models replied
   in the meeting's language instead of the configured one. Repeating the
   instruction after the transcript zeroed the problem.

## Limitations

1. **Not the app's binary.** Measured via `mlx-lm` (Python): same MLX kernels
   and same weights as the app's `mlx-swift-lm`, but not the same stack.
2. **Gemma 4 12B was not measured**: it is the multimodal variant, which only
   the app's Swift runtime implements. It stays in the catalog as the only
   multimodal option, measurement inside the app still pending.
3. **The content evaluation has a single judge** (Claude, reading the outputs
   against the transcript). It is careful judgment, not a reproducible metric.
4. **One recording, one run per model.** Defects that only show up in another
   kind of meeting were not captured. The loops, for example, did not exist in
   a short recording and only appeared in the 36-minute one.
