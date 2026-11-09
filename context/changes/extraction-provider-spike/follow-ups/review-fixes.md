# Review fixes queued for later phases

From `reviews/impl-review-phase-1.md` (2026-11-09). Apply these while implementing the phase named.

## Phase 2 — OpenRouter adapter

- [ ] **F5: every provider failure must become 502.** In `OpenRouterReceiptExtractor`, catch `HttpRequestException`, `JsonException`, and the `TaskCanceledException` / `OperationCanceledException` that HttpClient throws on timeout, and rethrow each as `ExtractionFailedException`. The endpoint maps only that exception to 502, so anything else becomes a 500. When `ct.IsCancellationRequested` is true the client cancelled, so let that propagate instead of reporting it as a provider failure. Never put the API key in the exception message.
- [ ] **F6: `providerMs` should time only the OpenRouter HTTP call.** The adapter should time the `SendAsync`/`PostAsync` call itself and set `ProviderMs` on the `ExtractedReceipt` it returns. Then remove the endpoint's `Stopwatch` and the `receipt with { ProviderMs = … }` overwrite in `Program.cs`, so the endpoint returns `Results.Ok(receipt)`. Base64 encoding and parsing are then no longer counted.
