# Cross-vendor models per role (Phase 2)

Any chain role can run on a **non-Claude model** (GPT, Gemini, Qwen, … via
OpenRouter) — most usefully the **reviewers**: a foreign model reviewing Claude's
implementation has different blind spots, which is the point of a second opinion.

## How it works

`claude` only speaks the Anthropic Messages API; OpenRouter & most vendors are
OpenAI-compatible. A translating proxy bridges that. Each role is its own headless
`claude -p` process, so the chain injects `ANTHROPIC_BASE_URL` (+ `ANTHROPIC_AUTH_TOKEN`)
**per role process** — sibling roles keep talking to the native Anthropic API.

```
reviewer-correctness ─ ANTHROPIC_BASE_URL=http://localhost:4000 ─▶ LiteLLM /v1/messages ─▶ OpenRouter ─▶ gpt-5.x
implementer          ─ (no injection) ────────────────────────────▶ api.anthropic.com  ─▶ claude
```

## Setup (LiteLLM in front of OpenRouter)

1. `pip install 'litellm[proxy]'`
2. `litellm-config.yaml`:

   ```yaml
   model_list:
     - model_name: openai/gpt-5.2
       litellm_params:
         model: openrouter/openai/gpt-5.2
         api_key: os.environ/OPENROUTER_API_KEY
   ```

3. `OPENROUTER_API_KEY=sk-or-… litellm --config litellm-config.yaml --port 4000`
4. In the target repo's `sprint.conf`:

   ```bash
   SPRINT_PROXY_URL="http://localhost:4000"
   SPRINT_MODEL_REVIEWER_CORRECTNESS="openrouter:openai/gpt-5.2"
   ```

5. Proxy auth token (if your LiteLLM requires one) goes in the **machine-local**
   `~/.config/sprint/env` (sourced after `sprint.conf`, never committed):

   ```bash
   SPRINT_PROXY_TOKEN="sk-litellm-…"
   ```

## Graceful — but never silent

Degradation is acceptable; *unnoticed* degradation is not:

- **Proxy unconfigured/unreachable** (reachability probe before each cross-vendor
  phase): the role falls back to the Claude chain and the fallback is **recorded**.
- **Foreign reviewer writes unusable verdict JSON** (the reviewer sidecars are
  fail-closed): **one** retry on Claude before the fail-closed verdict applies —
  a JSON-untrue foreign model degrades to a Claude review instead of looping the
  chain. Also recorded.
- Every recorded fallback is surfaced as **❌ in `TODO.review.md`** under
  `### Model fallbacks`, which raises the `## 🔎 Review-Findings` pointer in
  `TODO.md` and an `AGENT_LOG.md` entry (and a desktop notification with
  `SPRINT_NOTIFY=1`). Treat it as a defect to fix: your change was reviewed, but
  **not** by the foreign model you configured.

## Recommendations

- Put **reviewers** on a foreign vendor, keep the **implementer** on Claude (it has
  the heaviest tool-use: multi-step edits + commits). Mixing the two reviewers
  (one foreign, one Claude) keeps a native review even during a proxy outage.
- Tool-use fidelity of foreign models behind the proxy is not guaranteed — watch the
  first runs in `TODO.run.log` before trusting a new model with a fail-closed role.
