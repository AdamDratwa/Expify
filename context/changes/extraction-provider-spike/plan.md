# AI Receipt Extraction Provider Spike Implementation Plan

## Overview

Pick the AI model and service that will read receipts in Expify, and prove it against the PRD's two extraction targets before any capture UI is built (roadmap F-01, unlocks S-02 `add-first-receipt`). All calls go through **OpenRouter** with one API key. We compare **Claude Opus 5.5** and **a GPT vision model** on the same 20 real receipts through a Development-only API endpoint, score them with a replay script, and record the verdict in a decision record.

PRD targets being proven:

- "After a receipt photo is uploaded, the extracted fields appear within 10 seconds."
- "At least 90% of extracted totals match the receipt without correction."

## Current State Analysis

- The API is a single minimal-API file, `src/Expify.Api/Program.cs`, with `/api/health`, the template `/weatherforecast`, a `/api/{**rest}` 404 fallback and the SPA fallback. No services, options classes, or test project exist.
- `src/Expify.Api/Expify.Api.csproj` references only `Microsoft.AspNetCore.OpenApi`; no user-secrets ID is set.
- No AI code, no provider account wiring, no receipt data.
- `context/foundation/infrastructure.md` explicitly leaves "Choice of AI vision provider and its own region and latency" out of scope; secrets are meant to live in App Service app settings.
- Every push to `master` deploys to production, so anything that must not reach production has to be excluded at runtime, not by convention.

## Desired End State

- `POST /api/dev/receipts/extract?model=claude|gpt` exists **only when the app runs in the Development environment**. It sends the photo through OpenRouter to the model mapped to that alias and returns one JSON shape whichever model answered.
- `tools/extraction-spike/run-spike.ps1` replays a git-ignored folder of 20 receipt photos plus a typed ground-truth CSV through both models and writes `context/changes/extraction-provider-spike/spike-report.md` with per-model pass/fail on the two rules.
- `context/changes/extraction-provider-spike/decision.md` names the chosen model (OpenRouter slug), the backend providers that served it, OpenRouter's and the backend's privacy terms, the measured latency and accuracy, and the cost per receipt — or records that neither passed.
- `context/foundation/tech-stack.md` names OpenRouter and the chosen model; the OpenRouter key and model slug are in App Service configuration (set by the user).

Verification: the report shows, for the winner, at least 19 of 20 receipts completed within 10 s and at least 18 of 20 totals exactly equal to the typed value; the endpoint returns 404 when the app runs in Production.

### Key Discoveries:

- Development-only wiring pattern already exists: `if (app.Environment.IsDevelopment()) app.MapOpenApi();` — `src/Expify.Api/Program.cs:24-27`.
- New endpoints must be mapped before the `/api/{**rest}` 404 fallback — `src/Expify.Api/Program.cs:57`.
- AGENTS.md hard rule: every endpoint the frontend calls lives under `/api/...`; run the API with the `http` launch profile for local work.
- OpenRouter exposes an OpenAI-compatible chat-completions API at `https://openrouter.ai/api/v1/chat/completions`. It accepts image content parts as data URIs and a JSON-schema `response_format`, and has a per-request `provider` routing object for data-policy and parameter-support filters. Field names are verified against OpenRouter's current docs at implementation time.
- Using a typed `HttpClient` with `System.Text.Json` keeps OpenRouter-specific fields (`provider` routing) first-class and adds no NuGet dependency.

## What We're NOT Doing

- No upload UI, no persistence of receipts or photos, no sign-in — those are S-01/S-02.
- No production endpoint: the extraction route is never mapped outside Development.
- No direct provider SDKs (Anthropic, Azure OpenAI): everything goes through OpenRouter.
- Not pinning a backend region: OpenRouter routes the request; the serving backend is recorded, not controlled.
- Not deciding the final category list (Open Roadmap Question 6). The spike uses a provisional list; category accuracy is reported, not gated.
- Not gating on store, date, or item accuracy — reported only.
- Not tuning per-model reasoning or effort settings — each model runs with OpenRouter's defaults. A third model (e.g. Gemini) is a config entry the user may add, not part of the baseline comparison.
- No API test project; the scoring rules are verified by the script's self-test.
- No .NET 10 upgrade (Open Roadmap Question 7, separate change).
- Receipt photos, ground truth and raw results are never committed.

## Implementation Approach

Build a thin extraction contract inside the API with one OpenRouter adapter behind it, and expose it only in Development so the deploy-on-push pipeline cannot ship it. Models are chosen by alias (`claude`, `gpt`) mapped in configuration to OpenRouter model slugs, so the comparison set changes without code. Keep measurement outside the API: a PowerShell replay script downscales photos the way the future browser upload will, times each HTTP call wall-clock (which therefore includes OpenRouter's hop, as production would), compares results with typed ground truth, and applies the agreed pass rules. The verdict lands in committed Markdown (report + decision) that S-02 builds on.

**Agreed rules:**

- **Latency:** a model passes when at least 95% of receipts (19 of 20) return a parsed result within 10,000 ms, measured wall-clock from sending the photo to receiving the parsed response. The reported p95 is the nearest-rank value (19th fastest of 20). A failed call or timeout counts as over 10 s.
- **Accuracy:** a model passes when at least 90% of receipts (18 of 20) have an extracted total exactly equal to the typed total, to the grosz. A failed call counts as a mismatch.
- **Privacy eligibility:** neither OpenRouter nor the serving backend may train on, or retain photos beyond, short abuse monitoring. This is enforced by OpenRouter account settings (prompt logging off, training-allowed providers excluded) plus a per-request data-collection deny filter. Processing region and serving backend are recorded but do not disqualify.
- **Tie-break when both pass:** more exact totals → lower p95 latency → lower cost per receipt.
- **Neither passes:** the decision record says so, with the numbers; S-02 stays unplannable until the user revisits the model set or the PRD targets.

## Critical Implementation Details

- **Antiforgery on file upload:** minimal-API endpoints that bind `IFormFile` carry antiforgery metadata; mark the dev endpoint with `.DisableAntiforgery()`. It is dev-only and cookie-less.
- **Image preparation:** phone photos (3–12 MB) exceed model image limits and slow every model down. The script resizes each photo to a long edge of at most 2000 px, as JPEG quality 85, **after applying the EXIF orientation tag** (System.Drawing does not auto-rotate). HEIC is not readable, so the receipt set must be JPEG. Resize time is excluded from the measured latency, matching S-02 where the browser resizes before upload.
- **Warm-up:** one untimed call per model before the timed run, so local JIT/TLS setup is not charged to the first receipt (production runs on an Always On B1 instance).
- **Routing filters on every request:** send the `provider` routing object with data collection denied and "require parameters" on, so OpenRouter routes only to backends that honor the no-training policy **and** support the JSON-schema response format. Without the second filter, a backend that ignores `response_format` can return free text, which then shows up as a spurious accuracy failure.
- **Errors look like successes:** OpenRouter can return HTTP 200 with an `error` object or an empty/refused choice. Treat a missing `choices[0].message.content`, a `finish_reason` other than a normal stop, or content that fails schema parsing as the 502 path.

## Phase 1: Extraction contract and dev-only endpoint

### Overview

Define the shared result shape and extractor abstraction, wire configuration through user secrets, and map a Development-only endpoint that validates input and routes by model alias. No extractor is registered yet.

### Changes Required:

#### 1. Extraction contract

**File**: `src/Expify.Api/Extraction/ReceiptExtraction.cs`

**Intent**: One result shape and interface that the adapter returns, so the script and later S-02 depend on a single contract regardless of model.

**Contract**: `IReceiptExtractor` with `Task<ExtractedReceipt> ExtractAsync(string modelAlias, Stream image, string mediaType, CancellationToken ct)`. `ExtractedReceipt` carries: `store` (string?), `purchaseDate` (`yyyy-MM-dd` string?), `currency` (string, expected `PLN`), `total` (decimal?), `items` (list of `{ name, price (decimal?), category }`), plus run metadata `modelAlias`, `model` (OpenRouter slug), `servedBy` (backend provider reported by OpenRouter, if present), `providerMs`, `inputTokens`, `outputTokens`. JSON uses camelCase.

#### 2. Shared prompt and schema

**File**: `src/Expify.Api/Extraction/ExtractionPrompt.cs`

**Intent**: Keep the instructions, the provisional category list and the JSON schema in one place so every model gets identical instructions and S-02 can lift them.

**Contract**: Exposes the instruction text (Polish receipts; read the printed total, not a sum of items; use `null` when a field is unreadable; dates as `yyyy-MM-dd`; prices as decimals with a dot), the provisional category list (marked provisional in a comment, pending Open Roadmap Question 6), and a strict JSON schema matching the fields above minus the run metadata (`additionalProperties: false`, all fields required, nullable where `null` is allowed).

#### 3. Configuration

**File**: `src/Expify.Api/Extraction/ExtractionOptions.cs`, `src/Expify.Api/Expify.Api.csproj`

**Intent**: Bind OpenRouter settings from configuration; the key comes from `dotnet user-secrets` locally and never from committed files.

**Contract**: Section `Extraction:OpenRouter` with `ApiKey`, `BaseUrl = "https://openrouter.ai/api/v1"`, and `Models` — a map from alias to OpenRouter model slug, with `claude` → the Claude Opus 5.5 slug and `gpt` → the chosen GPT vision model slug (exact slugs looked up on OpenRouter at setup and stored in `appsettings.Development.json`, which holds no secrets). The csproj gains a `UserSecretsId` (via `dotnet user-secrets init`). No key in `appsettings*.json`.

#### 4. Dev-only endpoint

**File**: `src/Expify.Api/Program.cs`

**Intent**: Map the extraction route only inside the Development branch, before the `/api/{**rest}` fallback, so production returns 404 for it.

**Contract**: `POST /api/dev/receipts/extract?model=<alias>`, multipart form with a single `photo` file (`image/jpeg`, `image/png` or `image/webp`, ≤ 10 MB). Responses: `200` with `ExtractedReceipt`; `400` for a missing or unsupported photo or an alias not in `Extraction:OpenRouter:Models`; `503` when the OpenRouter key is not configured (message names `Extraction:OpenRouter:ApiKey`, never a value); `502` when the call fails, is refused, or returns output that doesn't match the schema. The endpoint measures `providerMs` around the OpenRouter call only. `.DisableAntiforgery()`. The extractor is resolved from DI; registration happens in Phase 2.

#### 5. Spike folder and ignore rules

**File**: `.gitignore`, `tools/extraction-spike/README.md`, `tools/extraction-spike/truth.example.csv`

**Intent**: Give the receipts and raw results a home that git never tracks, and document how to prepare them.

**Contract**: Ignore `tools/extraction-spike/receipts/` and `tools/extraction-spike/out/`. `truth.example.csv` has header `file,store,date,total` and two fake rows (total as `12.34`, date as `2026-11-01`). The README explains: photograph 20 receipts as JPEG, put them in `receipts/`, copy the example to `receipts/truth.csv`, type the printed store, date and total; and set up the OpenRouter account privacy settings before the first call.

### Success Criteria:

#### Automated Verification:

- API builds: `dotnet build Expify.sln`
- In Development, `POST /api/dev/receipts/extract?model=claude` without a photo returns 400
- In Development, the endpoint with a photo and `model=unknown` returns 400
- In Production (`ASPNETCORE_ENVIRONMENT=Production`, `dotnet run --project src/Expify.Api --no-launch-profile --urls http://localhost:5066`), the endpoint returns 404 and `/api/health` still returns 200
- `git check-ignore tools/extraction-spike/receipts/a.jpg tools/extraction-spike/out/x.csv` reports both paths ignored

#### Manual Verification:

- `appsettings.json` and `appsettings.Development.json` contain no API key

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human before proceeding to the next phase.

---

## Phase 2: OpenRouter adapter

### Overview

Implement one OpenRouter extractor behind `IReceiptExtractor`, register it, and prove one receipt goes through each model alias.

### Changes Required:

#### 1. OpenRouter adapter

**File**: `src/Expify.Api/Extraction/OpenRouterReceiptExtractor.cs`

**Intent**: Send the photo plus the shared instructions to the model mapped to the alias and map the structured JSON reply to `ExtractedReceipt`.

**Contract**: Typed `HttpClient` (via `IHttpClientFactory`) posting to `{BaseUrl}/chat/completions` with `Authorization: Bearer <key>`, plus OpenRouter's optional app-identification headers set to a generic app name (`Expify`). Body: `model` = slug for the alias; `messages` = a system message with the instructions and a user message with the image as a base64 data-URI content part; `response_format` = strict JSON schema from `ExtractionPrompt`; `provider` routing with data collection denied and require-parameters on; `max_tokens` about 16,000. No per-model reasoning settings. Parse `choices[0].message.content` as JSON against the schema; map `usage` tokens and the serving backend (when OpenRouter reports it). Any 200-with-error, empty content, abnormal `finish_reason` or schema mismatch → 502. Non-2xx → 502 with OpenRouter's error message (never the key).

#### 2. Registration

**File**: `src/Expify.Api/Program.cs`

**Intent**: Register the extractor and bind `ExtractionOptions` inside the Development-only branch, so production neither needs nor loads the OpenRouter settings.

**Contract**: The endpoint from Phase 1 resolves `model=claude` and `model=gpt` through the configured map; any other alias is still 400.

### Success Criteria:

#### Automated Verification:

- API builds: `dotnet build Expify.sln`
- No vulnerable packages: `dotnet list Expify.sln package --vulnerable --include-transitive` reports none
- With the OpenRouter key removed from user secrets, `model=claude` returns 503 and the message names `Extraction:OpenRouter:ApiKey` without printing any key
- The Production-environment check from Phase 1 still returns 404 for the endpoint

#### Manual Verification:

- Prerequisite done by the user: an OpenRouter account with credit, prompt logging off and training-allowed providers excluded in its privacy settings; the API key in `dotnet user-secrets`; both model slugs present in `appsettings.Development.json`
- One real receipt sent with `model=claude` returns plausible store, date, items, categories and total, with `servedBy` filled in
- The same receipt with `model=gpt` returns the same shape

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human before proceeding to the next phase.

---

## Phase 3: Replay and scoring script

### Overview

A PowerShell 7 script that prepares the photos, runs both models over the set, applies the agreed rules and writes the report.

### Changes Required:

#### 1. Replay script

**File**: `tools/extraction-spike/run-spike.ps1`

**Intent**: Turn a folder of receipts and a ground-truth CSV into a pass/fail verdict per model, without touching the API's code.

**Contract**:

- Parameters: `-ReceiptsDir` (default `tools/extraction-spike/receipts`), `-ApiBase` (default `http://localhost:5066`), `-Models` (default `claude,gpt`), `-ReportPath` (default `context/changes/extraction-provider-spike/spike-report.md`), per-model prices per million input/output tokens (taken by the user from the OpenRouter model pages), and `-SelfTest`.
- Preparation: validate `truth.csv` (every row has a matching JPEG; totals parse as decimals with a dot), apply EXIF orientation, and resize to a long edge of ≤ 2000 px at JPEG quality 85 into `out/resized/`.
- Run: one untimed warm-up call per model, then for each receipt call each model in turn (interleaved, so network conditions are shared), with a 60 s client timeout. Record wall-clock ms, HTTP status, the returned fields and `servedBy`.
- Scoring: total match = decimal equality after rounding both sides to 2 places; date match = exact `yyyy-MM-dd`; store match = case-, whitespace- and diacritics-insensitive equality (reported only). Errors and timeouts count as over 10 s and as a total mismatch.
- Verdict per model: latency pass when the count of calls ≤ 10,000 ms is at least `ceil(0.95 × N)`; accuracy pass when exact totals are at least `ceil(0.9 × N)`; p95 by nearest rank; average tokens and cost per receipt; the set of backends that served the calls.
- Outputs: `out/results.csv` (full values, git-ignored), and the committed report with only aggregates and per-receipt pass/fail by file name (no store names or amounts).
- `-SelfTest` runs the scoring and verdict functions on built-in fixtures and exits non-zero on any failure.

#### 2. Report shape

**File**: `context/changes/extraction-provider-spike/spike-report.md` (generated)

**Intent**: A committed, privacy-safe record of the measurement.

**Contract**: Header with run date, N, model aliases and slugs. A table per model: calls ≤ 10 s (count / N), p95 ms, median ms, exact totals (count / N), date matches, store matches, errors, backends seen, average input/output tokens, cost per receipt, LATENCY PASS/FAIL, ACCURACY PASS/FAIL. Then per-receipt rows by file name with ✓/✗ per rule and model.

### Success Criteria:

#### Automated Verification:

- `pwsh -NoProfile -File tools/extraction-spike/run-spike.ps1 -SelfTest` exits 0, with fixtures covering: 18/20 exact totals → accuracy PASS; 17/20 → FAIL; 19/20 calls within 10 s → latency PASS; 18/20 → FAIL; `12.30` vs `12.3` → match; `12.31` vs `12.30` → mismatch; an error row → counts against both rules
- The script refuses to run when `truth.csv` references a missing photo (non-zero exit, message names the file)

#### Manual Verification:

- A dry run on 2 receipts produces `out/results.csv` and a report whose numbers match a hand check
- A photo taken in portrait arrives upright in `out/resized/`
- The generated report contains no store names or amounts

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human before proceeding to the next phase.

---

## Phase 4: Run, verdict and handoff

### Overview

Run the full 20-receipt comparison, decide, and hand the decision to S-02.

### Changes Required:

#### 1. Measurement run

**File**: `context/changes/extraction-provider-spike/spike-report.md`

**Intent**: Produce the committed report from the real set.

**Contract**: The user prepares 20 JPEG receipts and `truth.csv`; the API runs with the `http` profile; the script runs with both models.

#### 2. Decision record

**File**: `context/changes/extraction-provider-spike/decision.md`

**Intent**: Name the winner, or record that none passed, with everything S-02 needs to plan.

**Contract**: Sections: Verdict (model alias and OpenRouter slug, backends that served it); Results (copied headline numbers from the report); Rules applied (latency, accuracy, tie-break as agreed); Privacy terms (OpenRouter's data policy and the account settings used, plus the serving backend's API terms on training and retention, with links and date checked; processing region where known); Cost per receipt; What S-02 inherits (the endpoint contract, the prompt/schema file, the routing filters, the provisional-category caveat, the 2000 px client-side resize); If neither passed (numbers, and the options for the user: change the model set, add per-model reasoning settings, go direct to a provider, or change the PRD targets).

#### 3. Tech stack note

**File**: `context/foundation/tech-stack.md`

**Intent**: Record the chosen AI path where later skills look for stack decisions.

**Contract**: An `## AI extraction provider` section naming OpenRouter, the chosen model slug, and a pointer to `decision.md`. Skipped if neither passed.

#### 4. Production setting (user action)

**File**: — (App Service configuration)

**Intent**: The roadmap outcome includes the key stored as an app secret, ready for S-02.

**Contract**: The user sets `Extraction__OpenRouter__ApiKey` and the winning model's slug (`Extraction__OpenRouter__Models__<alias>`) on `expify-adr`. The agent may verify names only, never values.

### Success Criteria:

#### Automated Verification:

- `spike-report.md` exists and has a PASS/FAIL line for both rules for every model run
- `decision.md` contains the sections Verdict, Results, Rules applied, Privacy terms, Cost per receipt, What S-02 inherits
- `git status --porcelain` shows no files under `tools/extraction-spike/receipts/` or `tools/extraction-spike/out/`

#### Manual Verification:

- The full 20-receipt run completed for both models
- The verdict follows the agreed rules and tie-break when checked against the report
- Privacy terms for OpenRouter and the winner's serving backend were checked against their current terms, with the date recorded
- The OpenRouter settings exist in App Service configuration (`az webapp config appsettings list -g rg-expify -n expify-adr --query [].name` lists the names)
- `tech-stack.md` names OpenRouter and the model (or the decision says neither passed)

**Implementation Note**: After completing this phase and all automated verification passes, pause for the human's final confirmation.

---

## Testing Strategy

### Unit Tests:

- The scoring and verdict logic is covered by `run-spike.ps1 -SelfTest`: boundary counts for both rules, decimal-equality edge cases, and error rows.

### Integration Tests:

- The real 20-receipt run in Phase 4 is the integration test of the adapter and routing end to end.

### Manual Testing Steps:

1. Run the API in Development; send one receipt per model alias and read the JSON.
2. Run the API in Production mode; confirm the endpoint is 404.
3. Dry-run the script on 2 receipts; hand-check the report.
4. Full run on 20 receipts; check the verdict against the rules.

## Performance Considerations

- The 10 s budget is measured from a local machine through OpenRouter. Production on App Service in Poland Central may differ slightly; the decision record notes the measurement location.
- OpenRouter can route the same model to different backends between calls, so latency can vary; the report lists the backends seen so a slow backend is visible.
- Models run with default reasoning settings. If a model fails only on latency, a re-run with lower reasoning is the user's call, not part of this plan.

## Migration Notes

None. Nothing persistent is created, and the endpoint never exists in production.

## References

- Roadmap item: `context/foundation/roadmap.md` (F-01 `extraction-provider-spike`)
- PRD NFRs: `context/foundation/prd.md` (Non-Functional Requirements)
- Infrastructure constraints: `context/foundation/infrastructure.md` (Operational Story → Secrets; Out of Scope)
- Dev-only pattern: `src/Expify.Api/Program.cs:24-27`; API 404 fallback: `src/Expify.Api/Program.cs:57`

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles. See `references/progress-format.md`.

### Phase 1: Extraction contract and dev-only endpoint

#### Automated

- [x] 1.1 API builds: `dotnet build Expify.sln` — 03817b6
- [x] 1.2 In Development, `POST /api/dev/receipts/extract?model=claude` without a photo returns 400 — 03817b6
- [x] 1.3 In Development, the endpoint with a photo and `model=unknown` returns 400 — 03817b6
- [x] 1.4 In Production (`ASPNETCORE_ENVIRONMENT=Production`, `dotnet run --project src/Expify.Api --no-launch-profile --urls http://localhost:5066`), the endpoint returns 404 and `/api/health` still returns 200 — 03817b6
- [x] 1.5 `git check-ignore tools/extraction-spike/receipts/a.jpg tools/extraction-spike/out/x.csv` reports both paths ignored — 03817b6

#### Manual

- [x] 1.6 `appsettings.json` and `appsettings.Development.json` contain no API key — 03817b6

### Phase 2: OpenRouter adapter

#### Automated

- [ ] 2.1 API builds: `dotnet build Expify.sln`
- [ ] 2.2 No vulnerable packages: `dotnet list Expify.sln package --vulnerable --include-transitive` reports none
- [ ] 2.3 With the OpenRouter key removed from user secrets, `model=claude` returns 503 and the message names `Extraction:OpenRouter:ApiKey` without printing any key
- [ ] 2.4 The Production-environment check from Phase 1 still returns 404 for the endpoint

#### Manual

- [ ] 2.5 Prerequisite done by the user: an OpenRouter account with credit, prompt logging off and training-allowed providers excluded in its privacy settings; the API key in `dotnet user-secrets`; both model slugs present in `appsettings.Development.json`
- [ ] 2.6 One real receipt sent with `model=claude` returns plausible store, date, items, categories and total, with `servedBy` filled in
- [ ] 2.7 The same receipt with `model=gpt` returns the same shape

### Phase 3: Replay and scoring script

#### Automated

- [ ] 3.1 `pwsh -NoProfile -File tools/extraction-spike/run-spike.ps1 -SelfTest` exits 0, with fixtures covering: 18/20 exact totals → accuracy PASS; 17/20 → FAIL; 19/20 calls within 10 s → latency PASS; 18/20 → FAIL; `12.30` vs `12.3` → match; `12.31` vs `12.30` → mismatch; an error row → counts against both rules
- [ ] 3.2 The script refuses to run when `truth.csv` references a missing photo (non-zero exit, message names the file)

#### Manual

- [ ] 3.3 A dry run on 2 receipts produces `out/results.csv` and a report whose numbers match a hand check
- [ ] 3.4 A photo taken in portrait arrives upright in `out/resized/`
- [ ] 3.5 The generated report contains no store names or amounts

### Phase 4: Run, verdict and handoff

#### Automated

- [ ] 4.1 `spike-report.md` exists and has a PASS/FAIL line for both rules for every model run
- [ ] 4.2 `decision.md` contains the sections Verdict, Results, Rules applied, Privacy terms, Cost per receipt, What S-02 inherits
- [ ] 4.3 `git status --porcelain` shows no files under `tools/extraction-spike/receipts/` or `tools/extraction-spike/out/`

#### Manual

- [ ] 4.4 The full 20-receipt run completed for both models
- [ ] 4.5 The verdict follows the agreed rules and tie-break when checked against the report
- [ ] 4.6 Privacy terms for OpenRouter and the winner's serving backend were checked against their current terms, with the date recorded
- [ ] 4.7 The OpenRouter settings exist in App Service configuration (`az webapp config appsettings list -g rg-expify -n expify-adr --query [].name` lists the names)
- [ ] 4.8 `tech-stack.md` names OpenRouter and the model (or the decision says neither passed)
