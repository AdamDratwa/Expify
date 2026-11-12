<!-- IMPL-REVIEW-REPORT -->
# Implementation Review: AI Receipt Extraction Provider Spike

- **Plan**: context/changes/extraction-provider-spike/plan.md
- **Scope**: Full plan (commits 03817b6..4fa1861)
- **Reviewed phases**: 1, 2, 3, 4
- **Date**: 2026-11-12
- **Verdict**: NEEDS ATTENTION
- **Findings**: 0 critical, 4 warnings, 5 observations

## Verdicts

| Dimension | Verdict |
|-----------|---------|
| Plan Adherence | WARNING |
| Scope Discipline | PASS |
| Safety & Quality | WARNING |
| Architecture | PASS |
| Pattern Consistency | PASS |
| Success Criteria | PASS |

Phases 2 and 3 match their contracts, and follow-ups F5 and F6 from the Phase 1 review are in place. The Phase 1 fixes still hold.

The automated checks were re-run on HEAD on 2026-11-12:
- `dotnet build`: 0 warnings, 0 errors.
- No vulnerable packages.
- The script's `-SelfTest` passes.
- `git check-ignore` covers both spike folders, and `receipts/` and `out/` are clean.
- Development: no photo returns 400, an unknown alias returns 400, and a blank key returns 503 naming `Extraction:OpenRouter:ApiKey`.
- Production: the extract endpoint and `/swagger` return 404, and `/api/health` returns 200.

These deviations were approved by the owner and are not findings:
- The 2-receipt dry run instead of 20 receipts.
- The GPT verdict by judgment.
- The latency target relaxed to 20 s (the PRD edit is queued).
- Containment matching for store names.
- Progress rows 4.4 and 4.5 checked as resolved by decision.

## Findings

### F1 — Real store names from the owner's receipts are committed in the script's self-test

- **Severity**: ⚠️ WARNING
- **Impact**: 🔎 MEDIUM — real tradeoff; pause to reason through it
- **Dimension**: Safety & Quality
- **Location**: tools/extraction-spike/run-spike.ps1:117-118 (comment), :311-316 (fixtures); commit 0f21e5c
- **Detail**: The containment-rule fixtures and their comment use the two store names from the owner's dry-run receipts: a national chain, and a local co-op shop with its full legal name. The review agent confirmed this by counting matches against the private `truth.csv` and `results.csv` without printing them. That breaks the change's own rule that receipt data never gets committed, and the local co-op shows where the owner shops. Nothing is pushed yet; master is ahead of origin.
- **Fix A ⭐ Recommended**: Replace the names with invented ones of the same shape (a short sign inside a quoted legal name, with ł/Ł), then fold the change into 0f21e5c with a non-interactive autosquash rebase before pushing. Rewrite the Phase 3 and 4 Progress SHAs to the new hashes.
  - Strength: The names never reach the public history, and the self-test keeps the same coverage.
  - Tradeoff: Rewrites 0f21e5c, 4e60989 and 4fa1861, so the Progress SHA suffixes for Phases 3 and 4 must be updated afterwards.
  - Confidence: HIGH — nothing is pushed, so a rewrite affects no one else.
  - Blind spot: Whether another clone or branch already has these commits.
- **Fix B**: Replace the names in a new commit and leave history as it is.
  - Strength: No history rewrite, and every recorded SHA stays valid.
  - Tradeoff: The names stay in 0f21e5c and will be public once pushed.
  - Confidence: HIGH — a simple edit.
  - Blind spot: How much it matters to you that your shops are visible in the history.
- **Decision**: SKIPPED (owner, 2026-11-12) — names stay in the self-test and will be public once pushed

### F2 — decision.md claims the spike script can re-measure production; it can't

- **Severity**: ⚠️ WARNING
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Plan Adherence
- **Location**: context/changes/extraction-provider-spike/decision.md ("What S-02 inherits", verification path); tools/extraction-spike/run-spike.ps1:584
- **Detail**: The script hard-codes `/api/dev/receipts/extract`, and that route is mapped only in Development. Re-measuring from App Service would need S-02 to expose the same shape on a production route, plus a configurable route in the script.
- **Fix**: Reword it: the script can re-measure once S-02 exposes an endpoint with the same contract, and `run-spike.ps1` gains a `-Route` parameter at that point.
- **Decision**: SKIPPED (owner, 2026-11-12)

### F3 — Progress row 4.7 says the App Service settings exist, but decision.md lists them as still to do

- **Severity**: ⚠️ WARNING
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Plan Adherence
- **Location**: context/changes/extraction-provider-spike/decision.md (Follow-ups: "App Service settings"); plan.md Progress 4.7
- **Detail**: The owner confirmed the settings on 2026-11-12. The agent could not check the names because `az` needed a multi-factor sign-in. decision.md still says "the owner sets …".
- **Fix**: Change that follow-up to say the owner set both settings on 2026-11-12 and they were not independently checked (az needed MFA).
- **Decision**: SKIPPED (owner, 2026-11-12)

### F4 — The agreed tie-break would have picked Claude; the decision doesn't say so

- **Severity**: ⚠️ WARNING
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Plan Adherence
- **Location**: context/changes/extraction-provider-spike/decision.md (Verdict, Rules applied)
- **Detail**:
  - **The tie-break:** the agreed order is exact totals, then lower p95, then cost. Both models had 2/2 totals, so the next step is p95, where Claude was faster (14.1 s against GPT's 14.8 s). That makes Claude the winner before cost is ever considered.
  - **What the decision does instead:** it says the tie-break was "not applied" and picks GPT on cost and store matching.
  - **The store figures:** they were re-scored offline and are not in the committed report.
  - **Why this matters:** the override is legitimate, but a later reader should not have to work it out.
- **Fix**: Add a sentence to the Verdict saying the agreed tie-break would have chosen Claude (lower p95), and that the owner chose GPT on cost (about half per receipt) because both miss 10 s anyway.
- **Decision**: SKIPPED (owner, 2026-11-12)

### F5 — The timeout is described wrongly in Program.cs and decision.md

- **Severity**: 💡 OBSERVATION
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Safety & Quality
- **Location**: src/Expify.Api/Program.cs:27-29; decision.md ("Adapter" bullet)
- **Detail**: The comment says the 90 s server timeout makes a slow model report as a 502. The script's 60 s client timeout fires first, so the script sees `timeout` and the 90 s limit never applies during the spike. decision.md presents the 90 s timeout as part of the adapter, but it is set where the client is registered, so lifting the class alone would drop it.
- **Fix**: Correct the comment (90 s is the server's upper bound; the script gives up at 60 s), and in decision.md say the timeout is set in the `AddHttpClient` registration.
- **Decision**: FIXED — Program.cs comment corrected; decision.md Adapter bullet now says the timeout is set in `AddHttpClient` (uncommitted)

### F6 — Some adapter failures are mislabelled, and two exceptions could still become 500

- **Severity**: 💡 OBSERVATION
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Safety & Quality
- **Location**: src/Expify.Api/Extraction/OpenRouterReceiptExtractor.cs:52, :76-83
- **Detail**: A `JsonException` from the model's content (inside `ParseFields`) is reported as "OpenRouter returned a reply that is not valid JSON". It is really a model output or schema problem. An `IOException` or `InvalidOperationException` (for example an invalid charset) thrown while reading the body is not wrapped, so it would surface as a 500 instead of a 502. This is not verified at runtime, and the risk is low.
- **Fix**: Catch the content parse separately and report it as a schema mismatch, and add `IOException`/`InvalidOperationException` to the wrapped exceptions around the send and read.
- **Decision**: FIXED — content parse wrapped separately ("The model reply is not valid JSON"); IOException/InvalidOperationException during send/read → ExtractionFailedException (502). Build clean (uncommitted)

### F7 — Memory use per request and an unbounded response body (matters for S-02)

- **Severity**: 💡 OBSERVATION
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Safety & Quality
- **Location**: src/Expify.Api/Extraction/OpenRouterReceiptExtractor.cs:34-40, :51-52
- **Detail**: A 10 MB photo is held about four times at once: the MemoryStream, the base64 string, `ToJsonString()` and the UTF-8 `StringContent`. That is roughly 80-100 MB on the large object heap. `JsonNode` also escapes `+`, which adds about 8%, and the response body has no size cap. This is fine for a Development-only spike with resized photos, but it matters on a B1 App Service in production.
- **Fix**: Add a line to decision.md's "What S-02 inherits": stream the request with `Utf8JsonWriter` (or relaxed escaping) and set `MaxResponseContentBufferSize`.
- **Decision**: FIXED — "Memory" bullet added to decision.md "What S-02 inherits" (uncommitted)

### F8 — Small photos keep their EXIF metadata (possibly GPS) when sent to OpenRouter

- **Severity**: 💡 OBSERVATION
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Safety & Quality
- **Location**: tools/extraction-spike/run-spike.ps1:483
- **Detail**: When a photo's long edge is already ≤ 2000 px, the script saves the original image object. That keeps every EXIF property except orientation, which may include GPS location. Resized photos are redrawn, which drops all of it. Phone photos are usually larger than 2000 px, so this is unlikely to have happened.
- **Fix**: Always redraw the image into a new bitmap, or remove every property item before saving.
- **Decision**: SKIPPED (owner, 2026-11-12)

### F9 — Script input and warm-up hardening

- **Severity**: 💡 OBSERVATION
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Safety & Quality
- **Location**: tools/extraction-spike/run-spike.ps1:392, :794, :821
- **Detail**:
  - **File-name collision:** `x.jpg` and `x.jpeg` both map to the same resized file, so one receipt would be scored silently against the other's photo.
  - **Path escape:** a `file` value containing `..\` could read from outside `receipts/` and write outside `out/resized`.
  - **Warm-up:** it stops the run only on 400, 404 or 503. A 500, 413 or 415 only prints a warning, and the paid run continues.
  - **Current exposure:** none, because only the owner writes `truth.csv`.
- **Fix**: Reject `file` values that contain a path separator, check for duplicates on the name without its extension, and also stop the warm-up on 413, 415 and 500.
- **Decision**: SKIPPED (owner, 2026-11-12)
