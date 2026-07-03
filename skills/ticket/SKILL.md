---
name: ticket
description: Turn a rough idea or question into ONE clean, structured TODO.md item — grounded in the real codebase and refined with the user — ready to trigger the Sprint plan→implement→review hook chain. Use when capturing a task, triaging a "should we…?" question, or queuing work for the autonomous chain.
argument-hint: <rough idea or question, like a quick TODO note>
---

You are turning a rough idea into **one well-formed task** in `TODO.md`. The rough idea:

$ARGUMENTS

This is a refinement workflow, not an implementation. **Do not write code.** Do not write to
`TODO.md` until the task is crisp and the user has approved it. Work in these steps:

## 1. Read the constitution
Find the project's constitution files and read them — obey their conventions, especially the
**risk tiers** and any autonomous-agent / TODO-lifecycle rules.
- If `sprint.conf` exists, read the files listed in `SPRINT_CONSTITUTION_FILES` (in order).
- Otherwise read whichever of `AGENTS.md`, `CLAUDE.md` exist (and any project-specific guide they
  reference, e.g. a frontend `CLAUDE.md`).
- Skim `.githooks/README.md` if present, so you describe the downstream effect correctly.
If none of these exist, tell the user the repo isn't bootstrapped yet and offer `/sprint:bootstrap`.

## 2. Ground the idea in the real code (don't guess)
Find the actual symbols/files the idea touches and its blast radius:
- **Code graph** (preferred, if available): the `mcp__codegraph__*` tools
  (`codegraph_search`, `…_callers`, `…_callees`, `…_impact`, `…_context`), or the CLI
  (`codegraph context "<the idea>"`, `codegraph callers <symbol>`, `codegraph impact <symbol>`);
  run `codegraph sync .` first if the index looks stale.
- **Fallback** (no code graph): use Grep/Glob to locate the relevant symbols and their callers.
Read the few files that actually matter. Name concrete functions/files and where the change lands.

## 3. Interrogate it (the core of this skill)
Challenge the idea against what the code already does. Surface:
- Is it a **question or a task**? If it's really a question ("…or am I missing something?"),
  answer it from the code first — existing logic may already cover part of it.
- The **real scope** and the smallest change that delivers value.
- The **risk tier** (per the constitution / `AGENTS.md`). If high-risk, say so — it will **not**
  be auto-implemented; the chain defers it to a human.
- The **decisions that are the user's to make**, not yours (product/UX/policy choices).
Ask the user those few decisions with **AskUserQuestion**. Do not invent answers to genuine
product decisions; do correct wrong assumptions using evidence from the codebase.

## 4. Draft ONE structured item (the four ingredients)
Write a draft with:
1. a **clear imperative task** (no question),
2. the **risk tier**,
3. a **concrete done-criterion** (which targeted test must be green / which behavior is verifiable),
4. **file/function hints** from step 2.
Keep it to the smallest valuable change. Show the draft and refine until the user is happy.

## 5. Write it into `TODO.md`, then hand off
- Add the approved item as a `- [ ]` entry near the top of `TODO.md`.
- Ask whether to make it the **single active item** — if yes, move the other currently-active
  items into a `<!-- … -->` block (or under `## 🚧 Deferred`) per the skip convention, so the
  chain picks up only this one.
- **Do not commit automatically.** Tell the user: committing `TODO.md` starts the
  plan→implement→review chain (implementation lands on the impl branch, nothing auto-merges).
  Offer to commit if they want the process to start now.

Keep the dialogue tight: ground first, ask only the decisions that matter, then write.
