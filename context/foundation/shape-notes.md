---
project: Expify
context_type: greenfield
created: 2026-11-03
updated: 2026-11-03
checkpoint:
  current_phase: 8
  phases_completed: [1, 2, 3, 4, 5, 6, 7]
  gray_areas_resolved:
    - topic: limit period
      decision: one calendar month
    - topic: limit flag display
      decision: a warning next to the category total in the app
    - topic: pain category
      decision: missing capability
    - topic: primary persona
      decision: just me (personal spending)
    - topic: login method
      decision: email and password login
    - topic: role model
      decision: one flat account type; each account sees only its own receipts
    - topic: first session data source
      decision: upload a receipt photo with AI extraction; scoped down to one receipt and one month
    - topic: first session size
      decision: scope down (user chose the smaller flow)
    - topic: MVP estimate
      decision: about 3 weeks after-hours after adding limits (mvp_weeks: 3; was 2 before limits)
    - topic: limit source
      decision: the user sets the limit for each category
    - topic: limit feature priority
      decision: must-have (FR-009)
    - topic: review before save
      decision: extracted fields are shown for review; analysis updates only after the user saves
    - topic: US-01 starting state
      decision: user already has saved receipts when adding another
  frs_drafted: 9
  quality_check_status: accepted
---

# Shape notes

## Seed idea

A system that lets users manage their daily spending by retrieving, managing and displaying information from photos of receipts taken by the user. It should include RAG functionality and use AI to group, sum, count spendings, then let the user filter, search, and display information in a good graphical way.

Typical flow:
1. User photographs a receipt.
2. Receipt is uploaded.
3. OCR extracts text.
4. AI identifies: store, purchase date, products, categories, total amount.
5. Data is stored.
6. User asks questions in natural language, e.g. "How much did I spend on groceries last month?"

Scope confirmed for shaping: a web API plus a frontend application.

Adjustment accepted from the earlier idea check (not yet confirmed as a requirement): three milestones — capture and review; list, filter, and chart; natural-language questions.

## Vision & Problem Statement

The user cannot easily see where their spending goes. Their spending information is only available through their bank account, and inspecting it is very difficult. They check a couple of times a year, and each check takes about two hours.

The stated direction is ongoing tracking: the user wants to see spending as it happens, not only when they run a periodic check. The user has not yet stated the specific insight that makes this worth building over their current bank view (see Open Questions).

## User & Persona

Primary persona: the user, managing their own personal daily spending. The moment they reach for this: when they want to know where their money went, such as how much went to groceries last month.

## Access Control

Email and password login. One flat account type with no roles. Each account can see and change only its own receipts. A gated route called without a signed-in account is refused.

## MVP Flow

Locked first session, scoped down from the original:

1. The user logs in.
2. The user uploads one receipt photo.
3. The AI extracts the store, date, items, categories, and total. The user reviews and corrects them.
4. The user saves the receipt.
5. The user views that month's spending grouped by category.

Timeline: mvp_weeks: 3 (user re-estimate after adding the limit feature, about 45 hours at 15 hours a week). The earlier 2-week estimate was made before the limit feature was added.

## Success Criteria

### Primary
- A signed-in user uploads one receipt photo, reviews the AI-extracted fields, saves the receipt, and sees that month's spending grouped by category.

### Secondary
- Spending from several receipts across several months appears in the grouped monthly view.

### Guardrails
- No receipt is saved without the user's review.
- A user sees only their own receipts and photos.

## User Stories

### US-01: User adds another receipt and reviews its analysis

- **Given** a signed-in user who already has saved receipts
- **When** they upload a photo of another receipt
- **Then** the system extracts the store, date, items, categories, and total, shows them for review, and updates the analysis of their spending only after they save

## Functional Requirements

- FR-001: The user can sign in with email and password. Priority: must-have. (Implied by the locked flow and access control; not picked explicitly.)
  > Socratic: Counter-argument considered: a single user doesn't need accounts. Resolution: no counter-argument raised; stands as written.
- FR-002: The user can upload a photo of a receipt. Priority: must-have.
  > Socratic: Counter-argument considered: blurry or dim photos. Resolution: no counter-argument raised; stands as written.
- FR-003: The user can review and correct the AI-extracted store, date, items, categories, and total before saving. Priority: must-have.
  > Socratic: Counter-argument considered: review becomes a chore. Resolution: no counter-argument raised; stands as written.
- FR-004: The user can save a reviewed receipt. Priority: must-have. (Implied by the locked flow; not picked explicitly.)
  > Socratic: Counter-argument considered: a saved receipt may need editing later. Resolution: no counter-argument raised; stands as written.
- FR-005: The user can view their spending in a graphical form in the frontend application. Priority: must-have.
  > Socratic: Counter-argument considered: a plain table is enough for an MVP. Resolution: no counter-argument raised; stands as written.
- FR-006: The user can see how much they spent in each category. Priority: must-have.
  > Socratic: Counter-argument considered: AI-assigned categories may be wrong. Resolution: no counter-argument raised; stands as written.
- FR-007: The user can see their total spending. Priority: must-have.
  > Socratic: Counter-argument considered: one receipt's total adds little yet. Resolution: no counter-argument raised; stands as written.
- FR-008: The user can view spending for previous months and see whether they are progressing. Priority: nice-to-have.
  > Socratic: Counter-argument considered: comparing months needs several months of data. Resolution: no counter-argument raised; stands as written.
- FR-009: The user can set a monthly limit for a category and see, in the app, when that category's spending for the calendar month goes over it. Priority: must-have. (Added in Phase 5 from the business rule.)
  > Socratic: Counter-argument raised by the user: a limit may be ignored, so the flag may not change behavior. Resolution: not decided; see Open Questions.

## Business Logic

The app tells the user when their spending in a category, within one calendar month, exceeds the limit they set for it.

Inputs: the receipts the user has saved, with their categories and totals, and the limit the user sets for each category.

Output: for each category in a calendar month, a flag when that month's spending total exceeds the category's limit.

How the user encounters it: a warning next to the category total in the app.

## Non-Functional Requirements

- No receipt photo or spending record is visible to anyone other than its owner.
- After a receipt photo is uploaded, the extracted fields appear within 10 seconds.
- At least 90% of extracted totals match the receipt without correction.
- The product is usable in a mobile phone browser.

## Product Framing

- Product type: web app (a frontend with a backend API), as confirmed in the scope.
- Target scale: small. Single user (you). Request rate and data volume are not yet stated.
- Timeline: mvp_weeks 3 (see MVP Flow). Hard deadline: 2027-01-10 (the third submission term, 23:59). After-hours only: yes, about 15 hours a week.

## Non-Goals

- **Natural-language questions about spending** — not in the MVP. This is deferred, not dropped: the seed's RAG requirement still stands for a later milestone.
- **Email or push alerts when a limit is exceeded** — the limit flag appears only inside the app.

## Quality cross-check

Result: all six checks present (Access Control, Business Logic, Project artifacts, Timeline-cost ack, Non-Goals; Preserved behavior n/a for greenfield).

Open items carried to /10x-prd: Open Questions 1–3 above. Nothing blocks the PRD.

## Open Questions

1. **What insight makes this worth building over the bank account view?** — Owner: user. Block: no (the stated direction is ongoing tracking).
2. **Does US-01 belong to the first session?** — US-01 starts from a user with saved receipts, but the scoped-down first session covers one receipt. Owner: user. Block: no (it likely belongs to the next milestone).
3. **Is the counter-argument on FR-009 resolved?** — The user raised that a limit may be ignored, so the flag may not change behavior. Owner: user. Block: no (the requirement is must-have unless the user changes it).
