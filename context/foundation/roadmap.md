---
project: Expify
version: 1
status: draft
created: 2026-11-04
updated: 2026-11-04
prd_version: 1
main_goal: speed
top_blocker: time
milestone_id: receipt-tracking-mvp
milestone_seq: 1
milestone_status: open
---

# Roadmap: Expify

> Derived from `context/foundation/prd.md` (v1) + auto-researched codebase baseline.
> Edit-in-place; the next milestone continues this file. Archive only when an independent roadmap replaces it.
> Slices below are listed in dependency order. The "At a glance" table is the index.

## Milestone

**M-1: Receipt tracking MVP** — Status: open

- **Intent:** A signed-in user can photograph a receipt, check and save what AI read from it, see the month's spending by category, and get warned when a category goes over its monthly limit.
- **Source materials:** `context/foundation/prd.md` (v1)
- **Done when:** every F-NN and S-NN below is `done`.
- **Scope anchors:** FR-001–FR-007, FR-009 (all must-have FRs), US-01, the four PRD Non-Functional Requirements, Access Control, Business Logic. FR-008 (nice-to-have) is parked.

## Vision recap

The user cannot easily see where their spending goes: the only source is the bank account view, which takes about two hours to inspect and gets checked a couple of times a year. Expify aims at ongoing tracking instead: each receipt is photographed, read by AI, checked by the user, and immediately shows up in a monthly breakdown by category. What makes this worth building over the bank view is still an open question (see Open Roadmap Questions).

## North star

**S-02: User can upload a receipt photo, correct the AI-extracted fields, and save the receipt** — the north star is the smallest end-to-end slice whose success would prove the product works, so it is placed as early as its prerequisites allow. This one carries the product's riskiest assumption (the belief that, if wrong, sinks the product): that AI can read a receipt in under 10 seconds and get at least 90% of totals right. Under the `speed` goal, everything else is only worth building if this works.

## At a glance

| ID   | Change ID                 | Outcome (user can …)                                                                 | Prerequisites | PRD refs                    | Status   |
| ---- | ------------------------- | ------------------------------------------------------------------------------------ | ------------- | --------------------------- | -------- |
| F-01 | extraction-provider-spike | (foundation) an AI vision provider is chosen and proven against the 10 s / 90% targets | —             | NFR latency, NFR accuracy   | in-progress |
| S-01 | email-password-sign-in    | sign in with email and password and be refused on gated pages when signed out        | —             | FR-001                      | ready    |
| S-02 | add-first-receipt         | upload a receipt photo, review and correct the extracted fields, and save it         | S-01, F-01    | FR-002, FR-003, FR-004, US-01 | proposed |
| S-03 | monthly-category-view     | see the month's spending as a chart grouped by category, with a total               | S-02          | FR-005, FR-006, FR-007, US-01 | proposed |
| S-04 | category-monthly-limits   | set a monthly limit per category and see a warning next to any category over it     | S-03          | FR-009                      | proposed |

## Streams

Navigation aid — groups items that share a Prerequisites chain. Canonical ordering still lives in the dependency graph below; this table is the proposed reading order across parallel tracks.

| Stream | Theme              | Chain                                | Note                                                                  |
| ------ | ------------------ | ------------------------------------ | --------------------------------------------------------------------- |
| A      | Capture to insight | `F-01` → `S-02` → `S-03` → `S-04`    | The required path for the MVP under `speed`; the AI risk is cleared first. |
| B      | Access             | `S-01`                               | Runs in parallel with `F-01`; joins Stream A at `S-02`.               |

## Baseline

What's already in place in the codebase as of `2026-11-04` (auto-researched + user-confirmed).
Foundations below assume these are present and do NOT re-scaffold them.

- **Frontend:** partial — Angular 22 scaffold with empty routes (`src/Expify.Web/src/app/app.routes.ts`), HTTP client provided, placeholder page, `/api` dev proxy.
- **Backend / API:** partial — minimal API in `src/Expify.Api/Program.cs`: `/api/health`, template `/weatherforecast`, forwarded headers, SPA fallback.
- **Data:** absent — no database or photo storage wired; Azure SQL and Blob Storage are planned in `infrastructure.md` and are to arrive "with the feature that needs them" (`deploy-plan.md`).
- **Auth:** absent — no identity, cookie, or auth middleware.
- **Deploy / infra:** present — `.github/workflows/deploy.yml` deploys to App Service `expify-adr` via OIDC on push to `master`, with a `/api/health` smoke test.
- **Observability:** absent — default framework logging and `az webapp log tail` only.

## Foundations

### F-01: Choose and prove the AI receipt extraction provider

- **Outcome:** (foundation) an AI vision provider is chosen, its key is stored as an app secret, and a throwaway check on a handful of real receipt photos shows whether it returns store, date, items, categories, and total within 10 seconds with ≥ 90% of totals correct.
- **Change ID:** extraction-provider-spike
- **PRD refs:** NFR "extracted fields appear within 10 seconds", NFR "at least 90% of extracted totals match", `infrastructure.md` §Out of Scope ("Choice of AI vision provider")
- **Unlocks:** S-02; the unknown "which provider meets the 10 s / 90% targets, in which region, at what privacy terms"; the verification path (sample receipts + expected totals) S-02 reuses.
- **Prerequisites:** —
- **Parallel with:** S-01
- **Blockers:** — (needs an account with whichever provider is chosen)
- **Unknowns:**
  - Which provider meets the 10 s / 90% targets and keeps receipt photos private enough for the owner-only NFR? — Owner: user. Block: no (this foundation answers it).
- **Risk:** Sequenced first because it is the riskiest assumption; if no provider meets the targets, the NFRs change before any capture UI is built, not after.
- **Status:** in-progress

## Slices

### S-01: Sign in with email and password

- **Outcome:** user can sign in with email and password, and any gated page or `/api` call made while signed out is refused.
- **Change ID:** email-password-sign-in
- **PRD refs:** FR-001, Access Control, NFR "no receipt photo or spending record is visible to anyone other than its owner", NFR "usable in a mobile phone browser"
- **Prerequisites:** —
- **Parallel with:** F-01
- **Blockers:** —
- **Unknowns:**
  - How does an account come into existence — self-registration or one account created by hand? The PRD names only sign-in. — Owner: user. Block: no (plan the smallest option that supports multiple isolated accounts).
- **Risk:** Comes before capture because every receipt must belong to an owner from the first save; this is also the first slice to bring in persistent data, so it settles the data store in the smallest possible scope.
- **Status:** ready

### S-02: Upload, review, and save a receipt

- **Outcome:** user can upload a receipt photo from a phone browser, see the AI-extracted store, date, items, categories, and total within 10 seconds, correct any field, and save the receipt with its photo; nothing is saved without that review.
- **Change ID:** add-first-receipt
- **PRD refs:** FR-002, FR-003, FR-004, US-01, NFR latency, NFR accuracy, NFR owner-only visibility, NFR mobile browser, Success Criteria §Guardrails
- **Prerequisites:** S-01, F-01
- **Parallel with:** —
- **Blockers:** —
- **Unknowns:**
  - Are categories a fixed list the AI must choose from, or free text? (See Open Roadmap Question 6.) — Owner: user. Block: no (must be settled in this slice's plan; S-03 and S-04 inherit it).
  - What happens when extraction fails or a photo is unreadable? — Owner: user. Block: no.
- **Risk:** This is the north star; it integrates the provider from F-01 with owner-scoped storage of photos and records, so a regression in either the 10 s budget or owner isolation shows up here first.
- **Status:** proposed

### S-03: See the month's spending by category

- **Outcome:** user can open a monthly view showing a chart of spending grouped by category, the amount per category, and the month's total, updated as soon as a reviewed receipt is saved.
- **Change ID:** monthly-category-view
- **PRD refs:** FR-005, FR-006, FR-007, US-01, Success Criteria §Primary, Success Criteria §Secondary, NFR mobile browser
- **Prerequisites:** S-02
- **Parallel with:** —
- **Blockers:** —
- **Unknowns:**
  - Can the user switch to another month in this view, or only see the current one? The Secondary criterion mentions several months; FR-008 (comparing months) is parked. — Owner: user. Block: no.
- **Risk:** Comes after capture because it reads only saved receipts; the main risk is a chart that is unreadable on a phone screen.
- **Status:** proposed

### S-04: Set category limits and see over-limit warnings

- **Outcome:** user can set a monthly limit for a category and see a warning next to that category's total when the calendar month's spending exceeds it.
- **Change ID:** category-monthly-limits
- **PRD refs:** FR-009, Business Logic, NFR mobile browser
- **Prerequisites:** S-03
- **Parallel with:** —
- **Blockers:** —
- **Unknowns:**
  - Is the FR-009 counter-argument (a limit may be ignored) resolved? — Owner: user. Block: no (FR-009 stays must-have unless changed).
- **Risk:** Last because the warning sits next to the category totals from S-03 and depends on stable categories from S-02; it is the first slice to cut if time runs out.
- **Status:** proposed

## Backlog Handoff

| Roadmap ID | Change ID                 | Suggested issue title                                       | Ready for `/10x-plan` | Notes |
| ---------- | ------------------------- | ----------------------------------------------------------- | --------------------- | ----- |
| F-01       | extraction-provider-spike | Choose AI receipt extraction provider and prove 10 s / 90% | yes                   | Run `/10x-plan extraction-provider-spike` |
| S-01       | email-password-sign-in    | Sign in with email and password                             | yes                   | Run `/10x-plan email-password-sign-in`; settle account creation in the plan |
| S-02       | add-first-receipt         | Upload, review, and save a receipt                          | no                    | Waits for S-01 and F-01 |
| S-03       | monthly-category-view     | Monthly spending chart by category with total               | no                    | Waits for S-02 |
| S-04       | category-monthly-limits   | Monthly category limits with over-limit warning             | no                    | Waits for S-03 |

## Open Roadmap Questions

1. **What insight makes this worth building over the bank account view?** — Owner: user. Block: roadmap-wide, non-blocking (Vision second paragraph is a TODO).
2. **Does US-01 belong to the first session?** — US-01 starts from a user with saved receipts, but the scoped-down first session covers one receipt. Owner: user. Block: none (S-02 and S-03 cover both the first and later receipts).
3. **Is the counter-argument on FR-009 resolved?** — The user raised that a limit may be ignored, so the flag may not change behavior. Owner: user. Block: none (S-04 proceeds as must-have).
4. **Should sign-in (FR-001) and save (FR-004) be must-have?** — Both are implied by the locked MVP flow and access control. Owner: user. Block: none (roadmap treats both as must-have).
5. **What request rate and data volume should the app handle?** — Owner: user. Block: none.
6. **Are receipt categories a fixed list or free text assigned by the AI?** — Grouping (S-03) and per-category limits (S-04) need stable category names. Owner: user. Block: S-02 plan must decide it.
7. **When does the .NET 9 → .NET 10 upgrade happen?** — .NET 9 support ends 2026-11-10; `deploy-plan.md` lists the upgrade as the first follow-up change. Not a PRD item, so it is not a slice here. Owner: user. Block: roadmap-wide, non-blocking (schedule it as a standalone change before or after S-01).

## Parked

- **Natural-language questions about spending (RAG)** — Why parked: PRD §Non-Goals; deferred to a later milestone, not dropped.
- **Email or push alerts when a limit is exceeded** — Why parked: PRD §Non-Goals; the warning appears only in the app.
- **Comparing previous months to see progress (FR-008)** — Why parked: PRD §Non-Goals, nice-to-have; the MVP covers one month of receipts.
- **Editing or deleting a saved receipt, and a receipt list** — Why parked: no FR declares it (FR-004's counter-argument mentions later editing); `speed` keeps it out of M-1.

## Milestone History

## Done
