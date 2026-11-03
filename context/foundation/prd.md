---
project: Expify
version: 1
status: draft
created: 2026-11-03
context_type: greenfield
product_type: web-app
target_scale:
  users: small
  qps: null          # TODO: request rate not stated — see Open Questions
  data_volume: null  # TODO: data volume not stated — see Open Questions
timeline_budget:
  mvp_weeks: 3
  hard_deadline: 2027-01-10
  after_hours_only: true
---

# Vision & Problem Statement

The user cannot easily see where their spending goes. Their spending information is available only through their bank account, and inspecting it is very difficult. They check a couple of times a year, and each check takes about two hours.

# TODO: insight — see Open Questions

The stated direction is ongoing tracking: the user wants to see spending as it happens, not only when they run a periodic check. The insight that makes this worth building over the current bank view has not been stated.

# User & Persona

Primary persona: the user, managing their own personal daily spending. They reach for this product when they want to know where their money went, such as how much went to groceries last month.

# Success Criteria

### Primary
- A signed-in user uploads one receipt photo, reviews the AI-extracted fields, saves the receipt, and sees that month's spending grouped by category.

### Secondary
- Spending from several receipts across several months appears in the grouped monthly view.

### Guardrails
- No receipt is saved without the user's review.
- A user sees only their own receipts and photos.

# User Stories

### US-01: User adds another receipt and reviews its analysis

- **Given** a signed-in user who already has saved receipts
- **When** they upload a photo of another receipt
- **Then** the system extracts the store, date, items, categories, and total, shows them for review, and updates the analysis of their spending only after they save

# Functional Requirements

- FR-001: The user can sign in with email and password. Priority: must-have.
  > Note: implied by the locked MVP flow and access control; not explicitly selected by the user. See Open Questions.
  > Socratic: Counter-argument considered: a single user doesn't need accounts. Resolution: no counter-argument raised; stands as written.
- FR-002: The user can upload a photo of a receipt. Priority: must-have.
  > Socratic: Counter-argument considered: blurry or dim photos. Resolution: no counter-argument raised; stands as written.
- FR-003: The user can review and correct the AI-extracted store, date, items, categories, and total before saving. Priority: must-have.
  > Socratic: Counter-argument considered: review becomes a chore. Resolution: no counter-argument raised; stands as written.
- FR-004: The user can save a reviewed receipt. Priority: must-have.
  > Note: implied by the locked MVP flow; not explicitly selected by the user. See Open Questions.
  > Socratic: Counter-argument considered: a saved receipt may need editing later. Resolution: no counter-argument raised; stands as written.
- FR-005: The user can view their spending in a graphical form in the frontend application. Priority: must-have.
  > Socratic: Counter-argument considered: a plain table is enough for an MVP. Resolution: no counter-argument raised; stands as written.
- FR-006: The user can see how much they spent in each category. Priority: must-have.
  > Socratic: Counter-argument considered: AI-assigned categories may be wrong. Resolution: no counter-argument raised; stands as written.
- FR-007: The user can see their total spending. Priority: must-have.
  > Socratic: Counter-argument considered: one receipt's total adds little yet. Resolution: no counter-argument raised; stands as written.
- FR-008: The user can view spending for previous months and see whether they are progressing. Priority: nice-to-have.
  > Socratic: Counter-argument considered: comparing months needs several months of data. Resolution: no counter-argument raised; stands as written.
- FR-009: The user can set a monthly limit for a category and see, in the app, when that category's spending for the calendar month goes over it. Priority: must-have.
  > Note: added from the business rule during shaping.
  > Socratic: Counter-argument raised by the user: a limit may be ignored, so the flag may not change behavior. Resolution: not decided; see Open Questions.

# Non-Functional Requirements

- No receipt photo or spending record is visible to anyone other than its owner.
- After a receipt photo is uploaded, the extracted fields appear within 10 seconds.
- At least 90% of extracted totals match the receipt without correction.
- The product is usable in a mobile phone browser.

# Business Logic

The app tells the user when their spending in a category, within one calendar month, exceeds the limit they set for it.

Inputs: the receipts the user has saved, with their categories and totals, and the limit the user sets for each category.

Output: for each category in a calendar month, a flag when that month's spending total exceeds the category's limit.

How the user encounters it: a warning next to the category total in the app.

# Access Control

Email and password login. One flat account type with no roles. Each account can see and change only its own receipts. A gated route called without a signed-in account is refused.

# Non-Goals

- **Natural-language questions about spending** — not in the MVP. Deferred to a later milestone, not dropped: the RAG requirement from the original idea still stands.
- **Email or push alerts when a limit is exceeded** — the limit flag appears only inside the app.
- **Comparing previous months to see progress (FR-008)** — nice-to-have; out of MVP scope, because the MVP covers one month of receipts.

# Open Questions

1. **What insight makes this worth building over the bank account view?** — Owner: user. Block: no (Vision second paragraph is a TODO).
2. **Does US-01 belong to the first session?** — US-01 starts from a user with saved receipts, but the scoped-down first session covers one receipt. Owner: user. Block: no (it likely belongs to the next milestone).
3. **Is the counter-argument on FR-009 resolved?** — The user raised that a limit may be ignored, so the flag may not change behavior. Owner: user. Block: no (FR-009 stays must-have unless the user changes it).
4. **Should sign-in (FR-001) and save (FR-004) be must-have?** — Both are implied by the locked MVP flow and access control, but the user did not select them explicitly. Owner: user. Block: no.
5. **What request rate and data volume should the app handle?** — Not stated; only a single user is known. Owner: user. Block: no (ballpark for target_scale).
