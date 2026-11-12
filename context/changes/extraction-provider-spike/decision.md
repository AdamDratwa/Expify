# Decision: AI receipt extraction provider

- **Change**: `extraction-provider-spike` (roadmap F-01)
- **Decided**: 2026-11-12, by the project owner
- **Evidence**: [`spike-report.md`](spike-report.md), a 2-receipt dry run on 2026-11-09. The planned 20-receipt run was skipped by decision (see Verdict).

## Verdict

**Use GPT-6.1 Sol through OpenRouter**: alias `gpt`, OpenRouter slug `openai/gpt-6.1-sol`. Every call in the dry run was served by the **OpenAI** backend.

This is the owner's judgment, not a result of the plan's 20-receipt rules. The dry run showed both models reading the totals correctly. It also showed that neither model meets the 10-second target, so a bigger sample was not expected to change the decision. The planned verdict rules were therefore not applied in full:

- **Accuracy:** 2 of 2 totals were exact. That is consistent with the ≥ 90% target, but not proven on 20 receipts.
- **Latency:** fails the PRD's 10 s target. **Decision: relax the target to 20 s** (see Follow-ups). S-02 shows a "reading your receipt…" state while it waits.

GPT was chosen over Claude Opus 5.5. Both were equally accurate on the dry run, but GPT costs about half as much per receipt and matched the store name on both receipts, while Claude matched one of the two. Its latency was higher, but under 20 s.

## Results

From `spike-report.md`: N = 2, measured from the owner's machine through the local API and OpenRouter, after one warm-up call per model, with photos resized to ≤ 2000 px.

| | `gpt` (openai/gpt-6.1-sol) | `claude` (anthropic/claude-opus-5.5) |
| --- | --- | --- |
| Calls ≤ 10 s | 0 / 2 | 1 / 2 |
| Median / p95 latency | 14.8 s / 14.8 s | 7.8 s / 14.1 s |
| Exact totals | 2 / 2 | 2 / 2 |
| Date matches | 2 / 2 | 2 / 2 |
| Store matches (containment rule, re-scored offline) | 2 / 2 | 1 / 2 |
| Errors | 0 | 0 |
| Backend | OpenAI | Claude Platform on AWS |
| Average input / output tokens | 1046 / 954 | 1660 / 869 |
| Cost per receipt | ~0.012 USD | ~0.024 USD |

The committed report's store row shows 0 / 2 for both models. It was generated before the containment rule was added in Phase 3 (`0f21e5c`) and while `truth.csv` still had a mis-encoded store name. The store figures in this table come from applying the final `Test-StoreMatch` to the answers saved in that run, with the store name corrected; no new API calls were made. The decision does not depend on store matching.

An earlier single call during Phase 2 used a full-size photo that was not resized. It took 13.7 s for GPT and 12.4 s for Claude, and GPT read 15,150 input tokens against Claude's 5,699. Resizing to 2000 px is what brought input tokens down to the numbers above.

## Rules applied

The agreed rules, kept for the record:

- **Latency:** pass if at least 95% of calls (19 of 20) return a parsed result within 10,000 ms, measured wall-clock. A failed call or timeout counts as over 10 s. **Not met; the target is to be relaxed to 20 s.**
- **Accuracy:** pass if at least 90% of extracted totals (18 of 20) exactly equal the typed total, to the grosz. A failed call counts as a mismatch. **Met on N = 2; not proven on N = 20.**
- **Privacy eligibility:** neither OpenRouter nor the serving backend may train on photos or keep them beyond short abuse monitoring. **Met** (see Privacy terms).
- **Tie-break when both pass:** more exact totals, then lower p95, then lower cost. Not applied, because neither model passed latency. Cost decided it under the owner's judgment.

## Privacy terms

Checked on 2026-11-12. The OpenRouter account settings were confirmed by the owner on 2026-11-09.

- **OpenRouter** ([privacy policy](https://openrouter.ai/privacy), last updated 2026-08-31; [privacy and logging docs](https://openrouter.ai/docs/features/privacy-and-logging)):
  - "OpenRouter does not use your Inputs or Outputs for model training."
  - Image files are not persisted "beyond the duration necessary to route the request", except for abuse detection, security, billing or legal compliance.
  - Account settings used: prompt logging off, and providers that may train excluded.
  - Every request also carries `provider.data_collection: "deny"` and `require_parameters: true` (`OpenRouterReceiptExtractor`).
- **OpenAI API, the serving backend** ([your data](https://developers.openai.com/api/docs/guides/your-data)):
  - API data "is not used to train or improve OpenAI models" unless you opt in.
  - Abuse-monitoring logs for `/v1/chat/completions` are kept for up to 30 days.
  - Zero data retention and EU data residency (`eu.api.openai.com`) need approval from OpenAI sales. They are not available through OpenRouter on this account.
- **Processing region:** not controlled. OpenRouter routes the request, and OpenAI's default processing is US. The PRD's owner-only requirement is met (no training, short retention). The data does not stay in the EU.

## Cost per receipt

About **0.012 USD** (≈ 0.05 PLN) with GPT-6.1 Sol at 2 / 10 USD per 1M input / output tokens, averaged over 1,046 input and 954 output tokens on resized photos. This is from 2 receipts, so treat it as an order of magnitude.

## What S-02 inherits

- **Contract:** `IReceiptExtractor` and `ExtractedReceipt` (`src/Expify.Api/Extraction/ReceiptExtraction.cs`) and `ExtractionFailedException`, which maps to 502.
- **Prompt and schema:** `src/Expify.Api/Extraction/ExtractionPrompt.cs`. The category list is **provisional**, pending Open Roadmap Question 6. The schema rejects categories outside the list.
- **Adapter:** `OpenRouterReceiptExtractor`, with the routing filters `data_collection: "deny"` and `require_parameters: true`, a strict JSON-schema `response_format`, and a 90 s client timeout. It is registered only in Development today. S-02 must register it for production, behind sign-in.
- **Configuration:** `Extraction:OpenRouter:ApiKey` (user secrets locally; the App Service setting `Extraction__OpenRouter__ApiKey` in production) and `Extraction:OpenRouter:Models:gpt` = `openai/gpt-6.1-sol` (`Extraction__OpenRouter__Models__gpt`).
- **Client-side resize:** before upload, the browser resizes to a long edge of ≤ 2000 px at JPEG quality 85 and applies the EXIF orientation. This keeps input tokens and latency down.
- **Upload limits:** 10 MB per photo, enforced while streaming (`RequestSizeLimit`), so an oversized upload gets 413 (review finding F4). The dev endpoint is a reference only; S-02's real endpoint must not echo internal error details.
- **UX:** expect around 15 s per receipt. Show a progress state, and design for a 20 s budget.
- **Verification path:** `tools/extraction-spike/run-spike.ps1` together with a git-ignored `receipts/` folder and `truth.csv`. It can re-measure latency from production once S-02 exists.

## Follow-ups

- **PRD:** change the NFR "extracted fields appear within 10 seconds" to "within 20 seconds" in `context/foundation/prd.md`. That is the owner's decision recorded here; the edit is not made in this change.
- **Re-measure:** in S-02, measure from App Service (Poland Central) with a larger set of real receipts. If totals fall below 90%, revisit this decision.
- **App Service settings:** the owner sets `Extraction__OpenRouter__ApiKey` and `Extraction__OpenRouter__Models__gpt` on `expify-adr`. Only the names are verified, never the values.
