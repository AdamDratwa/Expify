<!-- IMPL-REVIEW-REPORT -->
# Implementation Review: AI Receipt Extraction Provider Spike

- **Plan**: context/changes/extraction-provider-spike/plan.md
- **Scope**: Phase 1 of 4 (commit 03817b6, plus uncommitted working-tree edits to Program.cs and Expify.Api.csproj, at the user's request)
- **Reviewed phases**: 1
- **Date**: 2026-11-09
- **Verdict**: REJECTED (the critical finding is only in the uncommitted Swagger edits; commit 03817b6 on its own would be APPROVED)
- **Findings**: 1 critical, 2 warnings, 3 observations

## Verdicts

| Dimension | Verdict |
|-----------|---------|
| Plan Adherence | PASS |
| Scope Discipline | WARNING |
| Safety & Quality | FAIL |
| Architecture | PASS |
| Pattern Consistency | PASS |
| Success Criteria | PASS |

All 5 planned items match the plan: the contract, the prompt and schema, the options and UserSecretsId, the dev-only endpoint, and the ignore rules with the README and CSV. Every Phase 1 automated check passed again on the current working tree on 2026-11-09:

- 1.1 build: 0 warnings, 0 errors.
- 1.2 and 1.3: Development returns 400.
- 1.4: Production returns 404 for the extract endpoint and 200 for `/api/health`.
- 1.5: both spike paths are ignored.
- 1.6: a search for `ApiKey` or `sk-or` in either appsettings file found nothing.

## Findings

### F1 — Swagger UI and swagger.json are served in Production

- **Severity**: ❌ CRITICAL
- **Impact**: 🔎 MEDIUM — real tradeoff; pause to reason through it
- **Dimension**: Safety & Quality
- **Location**: src/Expify.Api/Program.cs:12 (AddSwaggerGen), src/Expify.Api/Program.cs:90-95 (UseSwagger/UseSwaggerUI)
- **Detail**:
  - **The defect:** `UseSwagger()` and `UseSwaggerUI()` are uncommitted edits, and they sit outside any `IsDevelopment()` check.
  - **Verified:** with `ASPNETCORE_ENVIRONMENT=Production`, `/swagger/index.html` and `/swagger/v1/swagger.json` both return 200.
  - **Impact:** every push to master deploys, so the next push publishes the API docs on https://expify-adr.azurewebsites.net.
  - **Rules broken:** the plan says that anything which must not reach production is excluded at runtime (plan line 18). It also breaks the file's own pattern, where `MapOpenApi`, the options binding and the extract endpoint are all inside dev-only checks.
  - **Fragile placement:** the calls come after `MapFallback`/`MapFallbackToFile`. This works only because WebApplication runs endpoints at the end of the pipeline.
- **Fix A ⭐ Recommended**: Move `UseSwagger()`/`UseSwaggerUI()` into the existing `if (app.Environment.IsDevelopment())` block next to `MapOpenApi()`.
  - Strength: Matches the dev-only pattern already in Program.cs and keeps the Swagger UI you added for exercising the endpoint locally.
  - Tradeoff: Two OpenAPI generators remain (built-in `/openapi/v1.json` plus Swashbuckle).
  - Confidence: HIGH — Production exposure verified by curl; the same gate already hides the extract endpoint (404 verified).
  - Blind spot: `AddSwaggerGen` services are still registered in Production (inert, but loaded).
- **Fix B**: Remove the Swashbuckle packages and calls and rely on the built-in, already dev-gated `/openapi/v1.json`.
  - Strength: One generator, three fewer packages, nothing to gate.
  - Tradeoff: Loses the interactive UI; .NET 9's built-in OpenAPI has no UI without another package.
  - Confidence: MED — depends on why the UI was added.
  - Blind spot: Your intended use of the Swagger UI.
- **Decision**: FIXED (Fix A) — UseSwagger/UseSwaggerUI moved into the IsDevelopment() block next to MapOpenApi()

### F2 — Swagger doc advertises a JWT Bearer scheme the app doesn't have

- **Severity**: ⚠️ WARNING
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Safety & Quality
- **Location**: src/Expify.Api/Program.cs:14-37
- **Detail**: `AddSecurityDefinition("Bearer", …JWT…)` plus a global `AddSecurityRequirement` mark every operation, `/api/health` included, as needing a Bearer token. This is confirmed in the served swagger.json. The app has no authentication, and the planned sign-in (S-01) uses same-origin cookies, not JWT. The docs are wrong and point clients the wrong way.
- **Fix**: Delete the security definition and requirement. When S-01 adds auth, describe the cookie scheme instead.
- **Decision**: FIXED — replaced with plain `AddSwaggerGen()`; removed the `Microsoft.OpenApi.Models` using

### F3 — Unplanned Swagger and /weatherforecast edits mixed into the change's working tree

- **Severity**: ⚠️ WARNING
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Scope Discipline
- **Location**: src/Expify.Api/Program.cs, src/Expify.Api/Expify.Api.csproj:12-14 (uncommitted)
- **Detail**: Three Swashbuckle 9.0.6 packages, the Swagger setup and the removal of the template `/weatherforecast` endpoint and `WeatherForecast` record are not in plan.md. They are uncommitted on top of 03817b6, in the same Program.cs that Phase 2 will edit, so the Phase 2 touched-file staging would sweep them into `feat(extraction-provider-spike): … (p2)`. Removing weatherforecast is harmless and sensible. The packages build cleanly, have no known vulnerabilities, and resolve to Microsoft.OpenApi 1.6.31 alongside Microsoft.AspNetCore.OpenApi 9.0.21.
- **Fix**: After F1/F2, commit these edits on their own as a separate `chore(api): …` commit before Phase 2 starts, so the change history stays clean.
- **Decision**: FIXED — committed separately as 268952d `chore(api): add dev-only Swagger UI, drop weatherforecast template` (includes F1/F2 fixes; verified prod /swagger 404, dev /swagger 200 with no security scheme)

### F4 — Oversized uploads: size check after full buffering; >30 MB throws an unhandled exception

- **Severity**: 💡 OBSERVATION
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Safety & Quality
- **Location**: src/Expify.Api/Program.cs:119-124, 140
- **Detail**:
  - **Late check:** `ReadFormAsync` reads the whole body, buffering anything over 64 KB to disk, before the 10 MB check runs. An 11–12 MB upload correctly returns 400, but only after all of it has been read.
  - **Unhandled failure:** an upload over 35 MB goes past Kestrel's 30,000,000-byte limit and throws `BadHttpRequestException`. Only `InvalidDataException` is caught, so the response is the developer exception page with a stack trace.
  - **Why it's only an observation:** the endpoint is Development-only, so this is acceptable for the spike. S-02's real upload endpoint must not copy the pattern.
- **Fix**: Add a request-size limit to the endpoint (`.WithMetadata(new RequestSizeLimitAttribute(…))`) and catch `BadHttpRequestException` to return 413. Alternatively, accept the risk for the spike and note it for S-02.
- **Decision**: FIXED — `RequestSizeLimitAttribute(10 MB + 64 KB)` on the endpoint and `BadHttpRequestException` (413) caught → 413 ProblemDetails; verified 12 MB and 35 MB → 413, 5 MB passes the size check (uncommitted)

### F5 — Extractor exceptions other than ExtractionFailedException will surface as 500

- **Severity**: 💡 OBSERVATION
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Safety & Quality
- **Location**: src/Expify.Api/Program.cs:167-178
- **Detail**: Only `ExtractionFailedException` is mapped to 502. `HttpRequestException`, `JsonException`, or the `TaskCanceledException` that HttpClient throws on timeout would come back as 500, but the plan requires 502 for every provider failure. There is no extractor yet (Phase 2), so this can't be tested today.
- **Fix**: In the Phase 2 adapter, wrap transport, JSON and timeout failures in `ExtractionFailedException`. Tell a timeout apart from a client cancellation with `ct.IsCancellationRequested`.
- **Decision**: FIXED (queued) — recorded as a Phase 2 item in `follow-ups/review-fixes.md`; no extractor exists yet to change

### F6 — providerMs times the whole ExtractAsync call, not only the OpenRouter call

- **Severity**: 💡 OBSERVATION
- **Impact**: 🏃 LOW — quick decision; fix is obvious and narrowly scoped
- **Dimension**: Plan Adherence
- **Location**: src/Expify.Api/Program.cs:170-173
- **Detail**: The plan says to measure `providerMs` "around the OpenRouter call only". The endpoint times the whole `ExtractAsync`, which includes local base64 encoding and parsing, and overwrites whatever value the extractor sets. The extra time is a few milliseconds and the same for both models, so the comparison still holds. The rules use the script's wall-clock time anyway, not `providerMs`.
- **Fix**: In Phase 2, have the adapter time the HTTP call itself and remove the `receipt with { ProviderMs = … }` overwrite in the endpoint.
- **Decision**: FIXED (queued) — recorded as a Phase 2 item in `follow-ups/review-fixes.md`; lands with the adapter
