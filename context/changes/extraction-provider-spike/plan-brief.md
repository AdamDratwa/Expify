# AI Receipt Extraction Provider Spike — Plan Brief

> Full plan: `context/changes/extraction-provider-spike/plan.md`

## What & Why

Choose the AI model that reads receipt photos for Expify, and prove it meets the PRD before any capture screen is built: extracted fields within 10 seconds, and at least 90% of totals correct without correction. This is roadmap item F-01. If no model can do it, we learn that before S-02 `add-first-receipt` is planned, not after. All calls go through OpenRouter, so one key and one adapter cover every model.

## Starting Point

The API is a scaffold (`src/Expify.Api/Program.cs`: health check, template endpoint, SPA fallback) with no AI code, no secrets wiring and no tests. Every push to `master` deploys to production, so anything experimental must be excluded at runtime.

## Desired End State

Running the API locally in Development exposes one extraction endpoint that sends a photo through OpenRouter to Claude Opus 5.5 or a GPT vision model and returns the same JSON either way. A script runs your 20 real receipts through both and writes a committed pass/fail report. A decision record names the winner, or states that neither passed. The OpenRouter key and model are in App Service, ready for S-02.

## Key Decisions Made

| Decision | Choice | Why (1 sentence) |
| --- | --- | --- |
| Access path | OpenRouter for every model; no direct provider SDKs | One key, one adapter, and adding a model is a config entry. |
| Models compared | Claude Opus 5.5 vs a GPT vision model, chosen by aliases `claude` / `gpt` | Same two-way comparison as before; slugs live in config. |
| Test set | 20 of your own JPEG receipts with typed store, date and total | Matches real use; 90% then means at most 2 wrong totals. |
| Latency rule | ≥ 95% of receipts (19/20) within 10 s, wall-clock including the OpenRouter hop; failures count as slow | Tolerates one hiccup and measures the path production will use. |
| Accuracy rule | ≥ 90% (18/20) totals exactly equal to the grosz; store, date and items reported only | Literal reading of "match the receipt without correction". |
| Privacy gate | Neither OpenRouter nor the backend may train on or retain photos beyond abuse monitoring: account settings plus a per-request data-collection deny filter; region and backend recorded, not gating | Protects the owner-only promise with an extra intermediary in the path. |
| Routing filters | Every request requires backends that deny data collection and support the JSON-schema response format | Stops free-text replies from a backend posing as accuracy failures. |
| Harness form | Development-only `/api/dev/receipts/extract?model=…` endpoint + PowerShell replay script | S-02 starts from a working endpoint; the Development-only mapping means production returns 404. |
| Tie-break | More exact totals → lower p95 latency → lower cost per receipt | Accuracy matters most to the user; speed and cost follow. |
| Image prep | Resize to ≤ 2000 px long edge (after EXIF rotation) before upload | Phone photos exceed model limits; S-02 will resize in the browser the same way. |
| Categories | Provisional list, not gated | The final list is Open Roadmap Question 6, decided in S-02. |

## Scope

**In scope:**
- Shared extraction contract, prompt and JSON schema
- One OpenRouter adapter behind a Development-only endpoint
- Replay script with self-tested scoring, plus a privacy-safe committed report
- Decision record, tech-stack note, OpenRouter settings in App Service

**Out of scope:**
- Upload UI, saving receipts or photos, sign-in (S-01/S-02)
- Any production extraction endpoint; direct Anthropic or Azure OpenAI SDKs; pinning a backend region
- Per-model reasoning tuning; a third model in the baseline (you can add one in config)
- Final category list; an API test project; the .NET 10 upgrade

## Architecture / Approach

`run-spike.ps1` → (resized JPEG, multipart) → `POST /api/dev/receipts/extract?model=…` (Development only) → `OpenRouterReceiptExtractor` (alias → slug, with the shared instructions, strict JSON schema and routing filters) → OpenRouter → serving backend → `ExtractedReceipt` JSON (with `servedBy`) → the script times the call, compares it with `truth.csv`, and applies the rules → `spike-report.md` → `decision.md`.

## Phases at a Glance

| Phase | What it delivers | Key risk |
| --- | --- | --- |
| 1. Contract + dev-only endpoint | Endpoint shape, config via user secrets, git-ignored receipts folder | Endpoint accidentally mapped in production; guarded by a Production-mode 404 check |
| 2. OpenRouter adapter | Both model aliases return the same JSON | OpenRouter field names or 200-with-error responses; routing filters leaving no eligible backend |
| 3. Replay & scoring script | Self-tested scoring, report generator | Wrong boundary maths in the pass rules; covered by `-SelfTest` fixtures |
| 4. Run, verdict & handoff | Report, decision record, tech-stack note, App Service settings | Neither model passes, which pushes a PRD or model decision back to you |

**Prerequisites:** an OpenRouter account with credit and privacy settings applied (prompt logging off, training-allowed providers excluded); the two model slugs looked up on OpenRouter; 20 JPEG receipt photos with typed store, date and total (about an hour of prep).
**Estimated effort:** ~2–3 sessions across 4 phases, plus receipt preparation.

## Open Risks & Assumptions

- Latency is measured from your machine through OpenRouter, not from App Service in Poland Central; production numbers may differ slightly.
- OpenRouter may route the same model to different backends; latency can vary, and the report lists the backends seen.
- Claude runs through OpenRouter's OpenAI-compatible API, not Anthropic's SDK, so Anthropic-only controls (effort, refusal fallback) are not used; if a model fails only on latency, tuning its reasoning setting is your call, outside this plan.
- OpenRouter's and the backends' terms on training and retention are checked on the day of the decision and may change later.
- If neither model passes, S-02 stays blocked until you change the model set, go direct to a provider, or change the PRD targets.

## Success Criteria (Summary)

- The report shows the chosen model at ≥ 19/20 receipts within 10 s and ≥ 18/20 exact totals.
- The extraction endpoint is 404 in production; no receipt photo or raw result is committed.
- `decision.md` gives S-02 everything it needs: model, backend, privacy terms, cost, contract.
