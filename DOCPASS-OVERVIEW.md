# DocPass — product overview (shareable reference)

> **Purpose of this document:** Single reference for Copilot, stakeholders, or new contributors.  
> **Last updated:** May 2026 (decision engine v1.8.1 — strict separation of evidence verification from requirement-fit confirmation; HR fit-review now drives inbox classification, dashboard badge, doctor wallet chip, doctor alerts, and an HR-only "How this was assessed" audit panel; session detail always opens on Awaiting decision with a Decided fit-reviews history section under Decided)  
> **Live demo:** https://docpass.co.uk (Oracle Cloud VM — Docker + Caddy)  
> **Source repo:** https://github.com/matt1862000/nhs-credential-passport.git

---

## 1. What DocPass is

**DocPass** is a **proof-of-concept pilot** demonstrating how NHS doctors could store mandatory/statutory training evidence in one portable wallet, have it **HR-verified** by their trust, and reuse it when **moving between trusts**.

The concept is **designed in line with the direction of** NHS England’s **Statutory and Mandatory Training (StatMand)** programme — reducing duplication and improving portability across organisations.

### Important disclaimers

- **Not** an official NHS or NHS England system  
- **Not** connected to NHS national systems (no live ESR API)  
- **Illustrative pilot only** — acceptance policies remain those of each employer  
- ESR integration is via **CSV export upload**, not a live feed  

---

## 2. User types

| Type | How identified | Primary experience |
|------|----------------|-------------------|
| **Doctor** | Standard account | Training wallet, share with HR, requirements checklist, trust move planning |
| **HR / trust account** | `premium` flag on user | Verification inbox, cohort management, bulk training issue, compliance reports |

Both types share: dashboard, profile, header nav (bell + envelope), authentication.

### Notifications bell (doctor vs HR)

| User | Bell shows | Bell links to |
|------|------------|---------------|
| **Doctor** | Unread **alerts** (HR actions on their training) | `/static/notifications/` |
| **HR** | **Pending verifications** count (records awaiting HR review) | `/static/hr/` (verification inbox) |

HR accounts do **not** receive in-app alert notifications — the bell is verification-inbox only (no empty “Alerts” section).

### HR email notifications (optional SMTP)

When SMTP is configured, HR users can receive **email** digests and instant alerts (see §6.11). Doctors remain **in-app only** for notifications.

---

## 3. How it works (end-to-end)

1. **Doctor** creates account and completes profile (name, GMC, current trust, etc.)
2. **Doctor** adds training manually or imports from **ESR CSV export**, optionally attaching certificate evidence (PDF/screenshot)
3. Records are stored in a **server-side wallet**; each can become a signed **verifiable credential** (JWT + PDF with QR)
4. **Doctor shares** records with current-trust HR for verification (auto-share when profile is complete; **expired records are never sent** — doctor is prompted to log a renewal instead)
5. **HR** reviews in verification inbox → marks each record **Verified**, **Declined** (with reason), or later **Unverified**. Inbox **auto-refreshes every 15 s**; doctor’s My training list **auto-refreshes every 30 s**.
6. **Doctor** sees outcomes via alerts; declined records float to the **top** of My training and offer **Fix and reshare** (edit module/dates/issuing trust/evidence in place, then re-share in one tap)
7. **Doctor** can download verified PDFs, compare against trust mandatory requirements (with explainable matching — exact, alias, partial, or **semantic embedding**), and plan a move to a new trust’s checklist pack
8. **HR and doctor** can message each other in-app
9. **HR** (optional) receives email when doctors share for verification, or a daily inbox summary

---

## 4. Compliance matching (Stage 2 — shared across the app)

Mandatory topics are matched to wallet records using a **single backend matcher** (`backend/mandatory_matching.py`). Used by:

- **My trust requirements** (`/api/me/compliance-snapshot`)
- **Dashboard** compliance banner
- **Plan a trust move** (`/api/me/trust-move/checklist-preview`)
- **HR cohort** compliance snapshots and CSV export

### Matching logic (in order of strength)

1. **Exact** — module code match, HR `match_hints`, or normalised topic title ↔ record title  
2. **Alias** — global alias map (e.g. “Fire Awareness” → Fire Safety, “IPC” → Infection Prevention and Control) merged with per-topic hints  
3. **Partial** — trust pack `partial_*` hints or cautious substring fallback (min 4 characters)  
4. **Semantic** — Gemini embedding fallback when exact and alias rules do not match (see below)  
5. **None** — no plausible match  

Trust topics and pack JSON can also store `match_module_codes`, `match_name_substrings`, `partial_module_codes`, `partial_name_substrings`, and `partial_hint`.

### Semantic embedding fallback (Stage 2b)

When **exact** and **alias** matching fail, the matcher calls **Google Gemini embeddings** (`models/gemini-embedding-001`) and compares cosine similarity between:

- the mandatory **topic title** (pre-cached per trust pack), and  
- each wallet record’s **module name**.

| Similarity | `match_type` | `status_label` |
|------------|--------------|----------------|
| ≥ 0.90 | `semantic` | Met (semantic match) |
| 0.70 – 0.89 | `semantic_low` | Needs review (possible semantic match) |
| &lt; 0.70 | — | Falls back to partial match if any, else no match |

- **Auth:** service account via `GOOGLE_APPLICATION_CREDENTIALS` (OAuth scope `generative-language.retriever`) — not an API key  
- **Production:** credentials at `/var/lib/docpass/keys/gcp-embeddings.json`, mounted in container as `/app/keys/gcp-embeddings.json`  
- **Caching:** trust-pack topic embeddings cached in memory per pack fingerprint; credential embeddings cached by normalised title  
- **HR verification:** not required for matching — pending records can still show semantic matches; `hr_status` is display-only on requirements  
- **HR requirement-fit decisions:** any topic whose decision is **REQUIRES_REVIEW** (partial, semantic_low, *and* HR-verified exact matches where the decision engine still flags review) appears in the **Requirement fit review** section under the doctor's session view. HR clicks **Satisfies requirement** / **Does not satisfy** — stored per doctor, trust, topic, and credential. Accepted → **Met (HR confirmed)**; rejected → **No match**. Evidence verification ("is the certificate genuine?") and fit confirmation ("does this satisfy *this trust's* requirement?") are two **separate** HR decisions; an HR-verified credential never auto-promotes to MEETS without an explicit fit decision.

**Example:** pack topic “Information Governance” + wallet record “Protecting patient confidentiality and NHS data” → **Needs review (possible semantic match)** at ~86% similarity (≥90% required for Met).

### Output per topic (API + UI)

| Field | Example |
|-------|---------|
| `status_label` | Met (exact match), Met (possible match), Met (semantic match), Needs review (possible semantic match), Needs review, Expired, No match |
| `match_type` | `exact`, `alias`, `partial`, `semantic`, `semantic_low`, `none` |
| `confidence_score` | 1.0 / 0.8 / 0.5 / 0.90+ (semantic) / 0.70+ (semantic_low) / 0 |
| `confidence_label` | high / medium / low / Met (semantic match) / Needs review (possible semantic match) |
| `reason` | Human-readable explanation (e.g. “Semantic match (86% similar): Protecting patient confidentiality and NHS data”) |
| `portability` | `portable` (CSTF in category), `conditional` (trust policy), `local_only` (Local in category) |
| `status` (legacy) | `met`, `expiring`, `gap` — used for summary counts and cohort rollups |
| `hr_status` | VERIFIED / PENDING / etc. — shown when a matched credential exists; does not gate matching |

### Summary counts

- **met** — exact, alias, or semantic match, in date (includes “possible match”)  
- **expiring** — matched but expiring within 90 days  
- **gap** — no match, expired, partial, or semantic_low (needs review)  
- **needs_review** — partial or semantic_low matches (subset of gap)  

### Explainable decision engine (`backend/decision_engine.py`)

After the matcher runs, a **rule-based decision engine** scores each topic row. Embeddings only feed `similarity_score`; the final `decision` is deterministic and inspectable. Current pinned audit version: **`ENGINE_VERSION = "1.8.1"`**.

| Signal / rule | Points |
|---------------|--------|
| Exact match | +50 |
| Alias match | +40 |
| Semantic similarity | +30 × score |
| Partial match | +15 |
| Category alignment | +25 |
| Expired | −100 |
| Valid &gt; 180 days | +15 |
| Expiring within 30 days | −10 |
| Trusted provider (NHS / e-LfH / trust LMS) | +10 |
| Previously accepted at trust (rollup) | +30 |
| Previously rejected majority at trust | −30 |
| Trust pack `rules` violation | −40 |
| Cross-trust acceptance ≥80% (n≥5) | +15 |
| Cross-trust acceptance ≤30% (n≥5) | −15 |

**Thresholds:** score ≥70 → `MEETS`; 40–69 → `REQUIRES_REVIEW`; &lt;40 → `DOES_NOT_MEET`.  
**Confidence:** `decision_confidence = clamp(score / 100, 0, 1)` → mapped to `decision_confidence_label` (high ≥ 0.70 / medium ≥ 0.40 / low) and a human reason.

**HR evidence verification is intentionally NOT a scoring signal.** A bare HR-verified exact match scores 50 + 15 = 65 → `REQUIRES_REVIEW`, and the row appears in HR's Requirement fit review panel awaiting an explicit Satisfies / Does not satisfy click. Only after HR commits a fit decision does the row become `MEETS` (via `Met (HR confirmed)`) or `DOES_NOT_MEET`. The `hr_verified` flag is still tracked in `signals` for explanation and audit, but contributes 0 to the score (see commit `b609bd3`, engine v1.8.1).

**Doctor APIs (decision envelope included):**

- `GET /api/me/compliance-snapshot` — adds `decision`, `decision_confidence`, `decision_confidence_label`, `decision_confidence_reason`, `decision_score`, `decision_reason`, `decision_reason_short` (drops HR-routing sentence for the doctor view), `decision_factors`, `is_exact_match`, `match_label`, `signals`, `historical_context`, `historical_acceptance_hint`, `decision_engine_version` per topic; snapshot root includes `decision_engine_version`.
- `GET /api/me/trust-move/checklist-preview` — same fields on each preview topic.
- `GET /api/me/fit-review-pending-credentials` — set of wallet credential ids that are HR-verified but still pending HR fit-review for at least one mandatory topic; drives the amber **HR confirming fit** chip on wallet cards.

**Doctor surfaces (`/requirements`, plan-move) intentionally render only the badge + a plain-English why sentence (match nature + validity).** Confidence chip, match label, precedent hint, scoring factors and the HR-routing sentence are all HR-only — the doctor doesn't act on those signals, so showing them is noise.

**HR cohort snapshot** — unchanged (matcher fields only; no decision envelope).

**HR-only audit surface — "How this was assessed":** every Requirement fit review row carries a collapsible `<details>` panel exposing four structured sections built from the decision envelope and `signals` block:

| Section | Shows |
|---------|-------|
| Matching evidence | Match label, category alignment, validity (`Valid · N days remaining` / `Expiring soon · N days` / `Expired`), provider trust |
| Similarity | Semantic similarity %, only when meaningful |
| Scoring factors | `decision_factors` bullet list (e.g. `Exact module match (+50)`) |
| Decision summary | Score, confidence label + reason, decision, engine version |

Closed by default; never rendered on doctor surfaces. The HR-only `signals` block is forwarded by `compliance_snapshot.mandatory_needs_review_by_credential`.

**HR feedback rollup:** `training_decision_stats` materialised from `mandatory_match_decisions` on each fit upsert (idempotent re-upsert). Backfill: `python3 backend/scripts/backfill_decision_stats.py`.

**Trust policy:** optional `rules` on pack `mandatory_examples[*]` (e.g. `max_valid_days`, `require_trusted_provider`) — stored in `match_hints_json` when topics are seeded.

**HR intelligence:**

- `GET /api/hr/mandatory-topics/{topic_id}/recommendations` — accepted alternatives + similar trusts.
- `GET /api/decision-engine/version` — engine version + rule list for audit.
- Each HR fit decision stores `decision_engine_version` in `mandatory_match_decisions`.

---

## 5. Features for doctors

### 5.1 Dashboard (`/static/dashboard/`)

- Training summary stats: in date, expiring (90 days), expired, total
- Trust requirements compliance banner (gaps, needs review, expiring)
- Getting-started checklist: (1) sign in, (2) complete profile, (3) **import from ESR**, (4) **check trust requirements** — with **personalised “what to explore next”** suggestions (unused features only; up to 4 cards)
- Quick links to all doctor tools

### 5.2 Training wallet (`/static/staff/`)

- **View my training** — list with expiry status and HR verification state; sort **A–Z** or by **expiry date** (soonest first); **declined records float to the top** so they're impossible to miss. Cards that are HR-verified but still awaiting an HR requirement-fit decision get an amber **HR confirming fit** chip alongside the green **In Date** / blue **Verified by HR** chips — fed by `GET /api/me/fit-review-pending-credentials` (polled every 30 s, so the chip disappears the moment HR clicks Satisfies / Does not satisfy)
- **Auto-refresh** — list polls every **30 s** (paused when the tab is hidden) so HR verify/decline outcomes show up without a manual reload
- **Add a record** — manual entry; optional certificate upload
- **Import from ESR** — multi-step wizard (help → CSV → column map → preview → evidence → import); trust format detection; **needs-fix** panel for rows that fail validation (exact title match against wallet, not fuzzy)
- **ESR evidence** — certificate/screenshot bytes stored server-side in `csv_import_evidence` table; wallet entries hold `import_evidence_id` only (avoids duplicating base64 in browser `localStorage` and quota errors on large imports)
- **Filters** — e.g. not shared with HR, pending, verified, declined
- **Share with HR** — send records for verification; bulk "share all not yet shared"
- **Auto-share** — new records auto-submitted when profile is complete. **Expired records are excluded** both client-side (button disabled, hint shown in a red box: "Expired training isn't sent to HR. Tap **Renew** to log a new completion…") and server-side (`POST /api/me/shares` strips expired ids; 400 if everything submitted is expired). Portfolio/reference-pack shares are unaffected.
- **Renew / reshare** — option to reshare after adding a renewal record
- **Fix and reshare** (declined records) — focused modal lets the doctor edit module / completion date / expiry date / issuing organisation (with ODS autosuggest) **and** swap the evidence file, then re-shares in one tap. File-only changes move the existing HR row back to **Pending verification**; signed-detail changes replace the declined record with a corrected one so HR sees a single new Pending row instead of duplicates.
- **Download verified PDFs** — ZIP export of HR-verified evidence only
- **Revoke** credentials where applicable

### 5.3 HR verification (doctor side)

- Share individual or multiple records to trust HR inbox
- Track status per record: **not shared → pending → verified / declined**
- **Portfolio / reference pack** share mode for already-verified records when moving trusts

### 5.4 Trust requirements (`/static/requirements/`)

- Loads **`/api/me/compliance-snapshot`** (server wallet — not client-side matching)
- Colour-coded status labels with **reason** text and portability/confidence badges (including **Met (semantic match)** when embedding fallback applies)
- Summary pills: Met, Expiring soon, Needs review, Gap / expired
- Driven by HR-configured mandatory topics at the doctor’s **current trust**

### 5.5 Plan a trust move (`/static/plan-move/`)

- Select leaving trust (from profile) and joining destination trust (ODS autocomplete)
- Loads destination pack JSON + **`/api/me/trust-move/checklist-preview?pack_id=…`**
- Same matcher and labels as trust requirements
- Recognition hints when training was issued at leaving trust (pack-specific)
- Wizard to update profile trust and send HR-verified **portfolio reference pack**

### 5.6 Alerts (`/static/notifications/`)

In-app notifications sent **to doctors only** when HR acts on their training:

| Alert kind | When triggered |
|------------|----------------|
| Training verified | HR verifies a record |
| Training declined | HR declines (optional reason) |
| Verification reverted | HR unverifies a record |
| Training recorded by HR | HR adds/issues training on a doctor’s behalf |
| Requirement satisfied | HR clicks **Satisfies requirement** in fit review (links to `/requirements`) |
| Requirement not satisfied | HR clicks **Does not satisfy** in fit review (links to `/requirements`) |

### 5.7 Messages (`/static/messages/`)

- Direct messaging with trust HR
- Can start conversations with supported trusts
- Unread badge on envelope icon in header

### 5.8 Profile (`/static/profile/`)

- Display name, GMC, current trust
- **Visibility settings** (doctors only) — who can see verified training
- **Change password** — current + new + confirm, validated server-side (`POST /api/auth/change-password`)
- **HR:** default welcome message template for new cohort members
- **HR:** "Show the welcome message review before adding doctors" preference — opt-in path back to the welcome modal once it's been dismissed with **Don't show again** from the Add doctors flow
- **HR:** email notification preferences (daily digest + instant share alerts) — see §6.11
- **HR:** automatic expiry reminders toggle (in-app messages to doctors at 30 days, 7 days, and after expiry)
- Profile completeness gates auto-share and some flows

### 5.9 Forgot / reset password (`/static/auth/forgot.html` → `/static/auth/reset.html`)

- "Forgot password?" link on sign-in (`/static/auth/`) opens a one-field form
- Server **never confirms whether the email exists** — always returns "If that account exists, we've sent reset instructions to its email. The link is valid for 15 minutes." (`POST /api/auth/forgot-password`)
- Email contains a single-use link to `/static/auth/reset.html?token=…`. Tokens are random 32-byte URL-safe strings; only the SHA-256 hash is stored in `password_resets`. **15-minute expiry**, single-use, all outstanding tokens invalidated after a successful reset.
- Success state: form collapses, heading switches to **Password changed**, only a "Sign in with your new password" link remains.
- Rate limit: 5/min per IP on both forgot and reset endpoints.

### 5.10 Verifiable credentials & PDF export

- Each completion can be issued as a signed JWT (W3C-style VC) + PDF with QR for **download within DocPass** (verified training export)
- Signing uses RS256 and `did:web` (`/.well-known/did.json`) — infrastructure for issued credentials, not a public-facing verifier UI
- **No public verifier portal** — external parties do not verify credentials via a standalone DocPass page in the pilot

---

## 6. Features for HR / trust accounts

HR accounts see **Trust tools** on the dashboard instead of the doctor wallet. Card titles use full labels; bottom **action links** are shortened (e.g. **Onboard**, **Open**, **Review**, **Add**, **Manage**).

### 6.1 Verify shared training (`/static/hr/`)

- Inbox of **shared sets** from doctors grouped by doctor
- **Auto-refresh** — both the inbox list and an open set poll every **15 s** (paused when the tab is hidden), so new doctor submissions appear without manual reload
- **Inbox tabs (Needs action / Completed):** a doctor remains in **Needs action** until *both* the evidence work (PENDING items) *and* the requirement-fit work (REQUIRES_REVIEW topics with no `hr_fit_decision`) are complete. The inbox row shows a new **"N awaiting fit review"** chip beside the existing pending / verified / declined chips. Backend: `/api/hr/shares` computes `fit_pending_count` per session via `mandatory_needs_review_by_credential` and returns `actionable_fit_pending_items` + `actionable_total` for badges.
- **Session detail tabs (Awaiting decision / Decided):** every Review click lands on **Awaiting decision** by default (no persistence across opens), so HR never misses the actionable work.
- Filter: needs action / completed; by module; by record status
- Per-record actions: **Verify**, **Decline** (with reason), **Unverify**
- **Declined-record handling:** when a doctor uses **Fix and reshare**, the existing declined row is moved back to **Pending verification** rather than creating a duplicate "resubmission" entry. If the doctor changed a signed detail (module/dates), HR sees a single fresh Pending row instead.
- **Expired training is never in the inbox** — server-side guard on `POST /api/me/shares` strips expired credentials before a share session is created
- **Requirement fit review (Awaiting decision tab only)** — separate section below verification: **Satisfies requirement** / **Does not satisfy** (not mixed with Verify/Decline). Each row carries a collapsible HR-only **▸ How this was assessed** audit panel (Matching evidence / Similarity / Scoring factors / Decision summary). On click, the doctor receives a `Requirement satisfied` / `Requirement not satisfied` alert linking to `/requirements`.
- **Decided requirement fit reviews (Decided tab only)** — read-only history of past Satisfies / Does not satisfy calls for the doctor at this trust, newest first; populated by the additive `mandatory_fit_decisions` array on `/api/hr/shares/{session_id}`.
- Bulk verify / bulk decline within a set
- Header **bell** — hover preview shows **Training to verify** only; badge = combined evidence-pending + fit-pending count (`actionable_total`), so a doctor whose evidence is fully verified but who still has an outstanding fit decision still surfaces in the bell

### 6.2 Search doctors (`/static/hr/search.html`)

- Search by name, email, or GMC (autocomplete)
- View a doctor’s verified training
- Add a single completion with evidence for a doctor
- Row actions order: View training → Add training → Message → **Delete** (last)
- Deep-link support: `?doctor=<user_id>&name=…` opens a doctor directly; `?q=` auto-opens on single match

### 6.3 Add training for doctors (`/static/hr/bulk.html`)

- Wizard: search/select doctors, pick cohort, or upload roster
- Issue same module and dates for all selected
- Records created as HR-verified; doctor gets alert

### 6.4 Add doctors (`/static/hr/cohorts/`)

- Page title **Add doctors**; list heading **Your groups** (cohorts remain the underlying grouping model)
- On-board doctors using **personal email** as login; create groups and add/remove members; roster import
- **Create cohort wizard:** when adding from **All Doctors**, search with **autosuggest** (name, email, GMC) filters the picker locally; selections preserved while filtering
- Send welcome messages (queued until profile complete)
- Broadcast message to a group
- Compliance snapshot / export per group (uses shared matcher)
- Pending verification view per group

### 6.5 Mandatory training requirements (`/static/hr/mandatory/`)

- Define mandatory training topics the trust expects (with optional `match_hints`)
- Seed from trust checklist pack
- Reorder topics
- Used for doctor requirements view and compliance snapshots

### 6.6 Expiring training (`/static/hr/expiring.html`)

- Report of doctors at the trust with wallet records expiring in **7, 30, or 90 days**
- Mandatory topics: automatic in-app reminders to doctors at 30 days, 7 days, and expiry (HR toggle in Profile)
- Dashboard widget: count of affected doctors (90-day window)

### 6.7 Audit log (`/static/hr/audit.html`)

- Searchable log of HR actions: verify, decline, unverify, issue training
- Download as CSV

### 6.8 Messages (`/static/hr/messages/`)

- Conversations with doctors at the trust
- Start conversation with doctor (search)
- Broadcast to multiple doctors
- Attachments supported
- Message templates for welcomes (`/static/hr/welcome-templates.html`)

### 6.9 Compliance & reporting (API-backed)

- Trust expiring report
- Cohort compliance snapshot and CSV export (status labels in matrix)
- Doctor compliance snapshot (`/me/compliance-snapshot`)

### 6.10 Email notifications (HR — Profile)

Configured in **Profile** (`/static/profile/#email-notifications`) when SMTP is set on the server.

| Type | Trigger | Default |
|------|---------|---------|
| **Daily digest** | Cron (e.g. 7am UTC) — pending verifications + unread messages per HR trust | On |
| **Instant alert** | Doctor shares training for **verification** (not portfolio/reference pack) | On |

- Emails sent to the HR account’s login email (or `HR_EMAIL_OVERRIDE` during pilot)
- Opt-out via Profile checkboxes; saved with **Save and go to dashboard**
- If inbox is empty (0 pending, 0 unread), daily digest sends nothing
- Old URL `/static/hr/email-notifications.html` redirects to Profile

**Pilot note:** `HR_EMAIL_OVERRIDE=raihan.talukdar@nhs.net` routes all HR emails to one inbox without changing login emails.

### 6.11 Sign-in MFA for demo HR accounts (email OTP)

Email-OTP multi-factor authentication on `/api/auth/login`, scoped via `MFA_REQUIRED_EMAILS` (default: `sheffieldhr@nhs.net,rotherhamhr@nhs.net`). Doctors and any other accounts are unaffected.

**Flow**

1. HR submits email + password. Password check is unchanged (`bcrypt`).
2. If the email is gated and no valid trust cookie is present, the API:
   - generates a **6-digit code** (`secrets.randbelow`) and a 32-byte challenge token
   - stores **SHA-256 hashes only** in `mfa_codes` (10-minute expiry, single-use, max 5 attempts before the row burns)
   - sets an HttpOnly `mfa_pending` cookie carrying the raw challenge token
   - emails the code via `email_service` to `_mfa_delivery_email` (honours `HR_EMAIL_OVERRIDE` → demo codes land on `raihan.talukdar@nhs.net`)
   - returns `{ ok: true, mfa_required: true, delivery_hint: "sh***@nhs.net", expires_in_minutes: 10 }` **without** a session cookie
3. Sign-in page swaps to a 6-digit code panel: numeric input with iOS SMS autofill (`autocomplete="one-time-code"`), **Trust this device for 30 days** checkbox, **Send a new code** link (30-second cooldown), and a **Use a different account** escape hatch.
4. `POST /api/auth/mfa-verify` consumes the code + challenge pair, sets the real session cookie, clears `mfa_pending`, and (if remembered) sets an HttpOnly `mfa_trust` cookie whose SHA-256 hash is stored in `mfa_trusted_devices` with a 30-day expiry.
5. `POST /api/auth/mfa-resend` issues a fresh code against the current challenge cookie (3/min rate limit).

**Security properties**

- Email-only attacker can't sign in (also needs the `mfa_pending` cookie); cookie-only attacker can't sign in (also needs the emailed digits).
- Codes are hashed at rest; trust tokens are hashed at rest. Server reveals only `delivery_hint` (e.g. `sh***@nhs.net`).
- Rate limits: `/auth/login` 10/min, `/auth/mfa-verify` 10/min, `/auth/mfa-resend` 3/min.
- Trust cookie is per-user (`WHERE user_id = ? AND token_hash = ?`); revoking the DB row instantly invalidates the cookie.

---

## 7. Shared UI / navigation

- **NHS-style** header with DocPass logo
- **Menu** — Dashboard, Profile, Sign out
- **Bell** — hover preview (stable hover bridge; no reload flicker)  
  - Doctors: alerts preview  
  - HR: **Training to verify** only (no alerts footer)  
- **Envelope** — messages preview on hover; unread badges
- **Landing page** (`/static/index.html`) — StatMand-aligned pitch; redirects signed-in users to dashboard

---

## 8. Trust checklist packs

Pre-configured JSON packs under `static/trust/config/` (e.g. Sheffield `RHQ`, Rotherham `RXE`) used for:

- Plan a trust move (destination requirements + checklist preview API)
- HR mandatory topic seeding
- Recognition rules when joining from another trust (`recognition_when_joining`)

Each pack includes `mandatory_examples` with labels, categories, match hints, and optional partial-match hints.

---

## 9. Technical architecture

### Stack

| Layer | Technology |
|-------|------------|
| Backend | Python 3.11, FastAPI, SQLite |
| Auth | Session cookies (httponly, secure, SameSite=Lax), bcrypt passwords |
| Credentials | RS256 JWT, did:web public key, ReportLab PDF + QR |
| Frontend | Vanilla HTML/CSS/JS (no React) |
| Production | **Oracle Cloud VM only** — Docker + **Caddy** reverse proxy (TLS, security headers). Render is **not** used. |
| Email | SMTP (Resend) — optional; HR notifications only |

### Production infrastructure (Oracle — sole production host)

| Component | Detail |
|-----------|--------|
| **Host** | Oracle Always Free VM (Ubuntu 24.04, UK London) |
| **Public IP** | `132.145.43.9` |
| **Domain** | `docpass.co.uk` (123 Reg DNS A record) |
| **App container** | `docpass` — uvicorn on `127.0.0.1:8000` |
| **Reverse proxy** | Caddy — `/etc/caddy/Caddyfile` |
| **Persistent data** | `/var/lib/docpass/data/credentials.db` |
| **Signing keys** | `/var/lib/docpass/keys/` (JWT signing + GCP service account for embeddings) |
| **Daily HR digest cron** | `/var/lib/docpass/send-hr-digest.sh` (optional) |

### Security (pilot hardening)

| Control | Implementation |
|---------|----------------|
| **HTTPS** | Caddy automatic TLS (Let’s Encrypt) |
| **Security headers** | Caddy on `docpass.co.uk` and `www.docpass.co.uk`: HSTS, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, CSP, `Referrer-Policy` |
| **CORS** | Whitelist (`docpass.co.uk`, `BASE_URL`, localhost) — no `*` |
| **Rate limiting** | `slowapi` — 10/min on login/register/mfa-verify; 5/min on forgot/reset-password; 3/min on mfa-resend |
| **Session cookies** | httponly, secure, SameSite=Lax |
| **MFA (HR demo accounts)** | Email-OTP gate on emails in `MFA_REQUIRED_EMAILS`; 6-digit codes hashed at rest (SHA-256), 10-min expiry, single-use, max 5 attempts; optional 30-day "trust this device" HttpOnly cookie (`mfa_trust`) whose hash sits in `mfa_trusted_devices` |
| **Password reset** | Random 32-byte URL-safe tokens, SHA-256 hashed in `password_resets`, 15-min expiry, single-use, no user enumeration; outstanding tokens invalidated on success |
| **Backup** | `deploy/backup.sh` + daily cron (3am) |

**CSP note:** Current policy uses `'unsafe-inline'` for scripts/styles (inline HTML). OWASP ZAP may flag this at Medium — acceptable for pilot; tightening requires refactoring static pages.

### Key backend modules

| Module | Role |
|--------|------|
| `backend/main.py` | FastAPI app, static files, DID endpoint, CORS, rate limit |
| `backend/auth_api.py` | Auth, wallet, HR, messaging, notifications, compliance APIs |
| `backend/db.py` | SQLite schema and data access |
| `backend/credential_service.py` | Issue/revoke credentials |
| `backend/mandatory_matching.py` | **Shared** topic ↔ wallet matcher (exact, alias, partial, **semantic embedding**) |
| `backend/compliance_snapshot.py` | Snapshots, cohort matrix, pack checklist preview |
| `backend/trust_packs.py` | Trust checklist pack loading and seeding |
| `backend/csv_import.py` | ESR CSV parsing |
| `backend/email_service.py` | SMTP send (graceful skip if `SMTP_HOST` unset) |
| `backend/hr_email.py` | HR daily digest + instant share alerts |
| `backend/hr_email_cli.py` | CLI: `python -m backend.hr_email_cli daily` |
| `backend/rate_limit.py` | slowapi limiter (client IP behind Caddy) |
| `backend/test_mandatory_matching.py` | Unit tests for matcher |

### Key frontend modules

| Module | Role |
|--------|------|
| `static/shared/auth.js` | Session, login, display name, wallet sync |
| `static/shared/nav-account.js` | Header bells, badges, hover previews |
| `static/wallet/wallet-store.js` | Wallet client helpers |
| `static/hr/hr-app.js` | HR inbox and verification UI |
| `static/moving/trust-mover.js` | Plan-a-move checklist (calls checklist-preview API) |
| `static/requirements/index.html` | Trust requirements UI (calls compliance-snapshot API) |
| `static/staff/index.html` | Main doctor training wallet app |
| `static/profile/index.html` | Profile, visibility, HR welcome template, HR email prefs |

### Environment variables (production)

| Variable | Purpose |
|----------|---------|
| `BASE_URL` | Public URL for links in emails and credentials |
| `SESSION_SECRET` | Session cookie signing |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_USE_TLS` | HR email (Resend: `smtp.resend.com`, user `resend`, password = API key) |
| `EMAIL_FROM` | e.g. `DocPass <noreply@docpass.co.uk>` |
| `HR_EMAIL_OVERRIDE` | Optional — route all HR emails (incl. MFA codes) to one address (pilot) |
| `MFA_REQUIRED_EMAILS` | Comma-separated list of accounts gated by email-OTP MFA on sign-in. Default: `sheffieldhr@nhs.net,rotherhamhr@nhs.net` |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to GCP service account JSON for Gemini embeddings (production: `/app/keys/gcp-embeddings.json` in container) |

See `deploy/email.env.example` for a template.

**GCP setup for semantic matching:** enable **Gemini API** (Generative Language API) on the GCP project; service account needs access with scope `generative-language.retriever`. Credentials file on VM: `/var/lib/docpass/keys/gcp-embeddings.json` (mode `600`, owned by container user `1000:1000`).

### Repository & deployment

- **GitHub:** `https://github.com/matt1862000/nhs-credential-passport.git`
- **Branch:** `main`
- **Local run:**
  ```bash
  cd nhs-credential-passport
  python3 -m venv venv && source venv/bin/activate
  pip install -r backend/requirements.txt
  ./run.sh
  ```
- Open: http://localhost:8000/static/dashboard/

**Production deploy (Oracle SSH):**
```bash
cd ~/docpass/app && git pull origin main
sudo docker build -t docpass .
sudo docker rm -f docpass
sudo docker run -d --name docpass --restart unless-stopped \
  -p 127.0.0.1:8000:8000 \
  --env-file /var/lib/docpass/docpass.env \
  -v /var/lib/docpass/data:/app/data \
  -v /var/lib/docpass/keys:/app/keys \
  docpass
```

Production env file `/var/lib/docpass/docpass.env` includes `BASE_URL`, `SESSION_SECRET`, SMTP settings, `HR_EMAIL_OVERRIDE`, `CRON_SECRET`, `HR_EXPIRY_REMINDERS_ENABLED`, etc.

Caddy config lives on the VM at `/etc/caddy/Caddyfile` (not in git).

### What is NOT in Git (backup separately if needed)

| Path | Contents |
|------|----------|
| `venv/` | Python virtualenv — recreate with pip |
| `.env` | Local env overrides |
| `keys/` | JWT signing keys (production: `/var/lib/docpass/keys/`) |
| `*.db` | SQLite database — **user data** |
| `/etc/caddy/Caddyfile` | Production reverse proxy + security headers |

---

## 10. Main pages (URL map)

| URL | Audience | Purpose |
|-----|----------|---------|
| `/static/index.html` | Public | Landing |
| `/static/auth/` | All | Sign in (with **MFA step** for `MFA_REQUIRED_EMAILS` accounts) |
| `/static/auth/forgot.html` | All | Request password reset email |
| `/static/auth/reset.html` | All | Set a new password via reset token |
| `/static/dashboard/` | All | Home hub |
| `/static/profile/` | All | Profile, visibility, HR welcome + **email prefs** |
| `/static/profile/#email-notifications` | HR | Email notification settings (anchor) |
| `/static/staff/` | Doctor | Training wallet |
| `/static/requirements/` | Doctor | Current trust checklist (smart matching) |
| `/static/plan-move/` | Doctor | Destination trust comparison (smart matching) |
| `/static/notifications/` | Doctor | Alerts history |
| `/static/messages/` | Doctor | HR messaging |
| `/static/hr/` | HR | Verification inbox |
| `/static/hr/search.html` | HR | Doctor search |
| `/static/hr/bulk.html` | HR | Add training for doctors |
| `/static/hr/cohorts/` | HR | Add doctors / group management |
| `/static/hr/mandatory/` | HR | Mandatory training requirements |
| `/static/hr/expiring.html` | HR | Expiring report |
| `/static/hr/audit.html` | HR | Audit log |
| `/static/hr/messages/` | HR | Messaging |
| `/static/hr/welcome-templates.html` | HR | Message templates |
| `/static/hr/email-notifications.html` | HR | Redirect → Profile `#email-notifications` |
| `/docs` | Dev | OpenAPI / Swagger |

---

## 11. Key API routes (summary)

### Auth
- `POST /auth/register`, `/auth/login`, `/auth/logout`
- `GET /auth/me`, `POST /auth/change-password`
- `POST /auth/forgot-password`, `POST /auth/reset-password` — token-based reset (15-min single-use, no enumeration)
- `POST /auth/mfa-verify`, `POST /auth/mfa-resend` — email-OTP step for `MFA_REQUIRED_EMAILS` accounts
- Rate limited: login/register/mfa-verify 10/min, forgot/reset-password 5/min, mfa-resend 3/min (per IP)

### Doctor wallet & sharing
- `GET /me/wallet`, `PUT /me/wallet`, `GET /me/verified-map`
- `POST /me/shares`, `POST /me/shares/withdraw`
- Instant HR email triggered on share for verification (background task)

### Compliance & requirements
- `GET /me/trust-requirements` — mandatory topic list for current trust
- `GET /me/compliance-snapshot` — **enriched** topic vs wallet match (all Stage 2 fields plus full decision envelope: `decision`, `decision_confidence_label/reason`, `decision_reason`, `decision_reason_short`, `decision_factors`, `is_exact_match`, `match_label`, `signals`, `historical_context`, `historical_acceptance_hint`, `decision_engine_version`)
- `GET /me/trust-move/checklist-preview?pack_id=sheffield` — destination pack vs wallet (same matcher and envelope)
- `GET /me/fit-review-pending-credentials` — credential ids HR-verified but pending fit review (drives wallet "HR confirming fit" chip)
- `GET /me/trust-move/candidates`, `POST /me/trust-move/complete`

### Notifications (doctors only)
- `GET /me/notifications`, `GET /me/notifications/unread-count`
- `POST /me/notifications/{id}/read`, `POST /me/notifications/read-all`

### HR verification
- `GET /hr/shares` — sessions list; also returns `actionable_pending_items` (evidence), `actionable_fit_pending_items`, `actionable_total`, `fit_pending_by_doctor`; each session row carries `fit_pending_count`
- `GET /hr/shares/{session_id}` — session detail; payload extended with `mandatory_needs_review` per item, plus `mandatory_fit_decisions` (decided history) and `signals` block on each fit-review topic for the HR-only audit panel
- `POST /hr/shares/{session_id}/items/{credential_id}/verify|decline|unverify`
- `POST /hr/doctors/{doctor_user_id}/mandatory-fit-decisions` — Satisfies / Does not satisfy; persists `mandatory_match_decisions`, writes audit log, and emits a doctor notification (`hr_fit_accepted` / `hr_fit_rejected`)

### HR email preferences
- `GET /hr/email-preferences` — digest/instant toggles, delivery email, inbox snapshot
- `PUT /hr/email-preferences` — update toggles

### HR doctor management
- `GET /hr/doctors/search`
- `GET /hr/doctors/{id}/training`, `POST /hr/doctors/{id}/add-training`
- `POST /hr/bulk-training`

### HR compliance & audit
- `GET /hr/compliance/expiring`, `GET /hr/audit-log`
- `GET /hr/cohorts/{id}/compliance-snapshot`, compliance CSV export

### Messaging
- `GET/POST /me/messages/*` (doctor)
- `GET/POST /hr/messages/*` (HR, including broadcast)

### Cohorts
- `GET/POST /hr/cohorts`, members, welcome send, cohort message

---

## 12. StatMand alignment (conceptual)

DocPass demonstrates ideas aligned with StatMand direction:

- **Single place** for mandatory training evidence  
- **HR attestation** of what has been checked  
- **Reduced re-collection** when doctors move trusts  
- **Explainable checklist comparison** against trust/destination requirements (rule-based + semantic embedding for near-matches)  
- **Portability hints** (CSTF vs local topics)  
- **CSTF-style** mandatory topic matching (not claiming official CSTF compliance)

---

## 13. What DocPass does not do (yet / by design)

- Live ESR API integration  
- National NHS identity (CIS2, NHSmail SSO, etc.)  
- Push notifications or email alerts **for doctors** (in-app only)  
- HR in-app alert notifications (HR bell = verification inbox only)  
- **Public verifier portal** or HR **verifier links** for third parties (removed from pilot scope)  
- Canonical national module registry (alias map + hints + **semantic embeddings** for near-matches, not a national module catalogue)  
- Strict CSP without `'unsafe-inline'` (would require frontend refactor)  
- **MFA for doctors and other HR accounts** — email-OTP step is currently scoped to the two demo HR accounts in `MFA_REQUIRED_EMAILS`; widening it is a config change only  
- TOTP / SMS / WebAuthn second factors (email OTP only today)  
- Legal/compliance sign-off as an NHS product  

---

## 14. Glossary

| Term | Meaning |
|------|---------|
| **Wallet** | Doctor’s stored training records on the server |
| **Credential** | Signed JWT + optional PDF representing one completion |
| **Share / share set** | Batch of records sent to HR for verification |
| **Verified map** | Per-credential HR status (shared, pending, verified, declined) |
| **Trust pack** | JSON checklist of mandatory topics for a destination trust |
| **Match hints** | Per-topic codes/substrings HR or pack JSON use to match wallet records |
| **Alias map** | Built-in synonyms (Fire Awareness → Fire Safety, etc.) |
| **Semantic match** | Embedding-based link when topic title and wallet record title mean the same thing but differ in wording (≥90% similarity → Met; 70–89% → Needs review) |
| **Premium account** | HR/trust user |
| **Cohort / group** | Named group of on-boarded doctors for bulk HR actions (UI: **Your groups** on Add doctors page) |
| **StatMand** | NHS England Statutory and Mandatory Training programme |
| **Portfolio / reference pack** | Share of already HR-verified records when moving trusts |
| **Daily digest** | Scheduled email summarising HR pending verifications and unread messages |
| **Fix and reshare** | Doctor action on a declined record — edit module/dates/issuing trust/evidence in a focused modal, then re-share (the existing declined HR row updates rather than creating a duplicate) |
| **MFA challenge** | Server-side `mfa_codes` row pairing a SHA-256-hashed 6-digit code with a SHA-256-hashed challenge token (cookie); both must match within 10 minutes for sign-in to complete |
| **Trusted device** | 32-byte random token issued at MFA success when the user ticks "Trust this device for 30 days"; only its SHA-256 hash is stored, in `mfa_trusted_devices` |
| **Password reset token** | Random 32-byte URL-safe string emailed to a user as a reset link; only the SHA-256 hash is stored, 15-min expiry, single-use |
| **Evidence verification** | HR's first decision on a shared credential — *is this certificate genuine?* — surfaced as Verify / Decline on each share item. Independent of fit confirmation. |
| **Requirement-fit confirmation** | HR's separate decision after a credential is verified — *does this credential satisfy this trust's mandatory requirement?* — surfaced as Satisfies requirement / Does not satisfy in the Requirement fit review section. A credential never auto-MEETS a mandatory topic on the back of evidence verification alone. |
| **Decision engine version** | `ENGINE_VERSION` constant in `backend/decision_engine.py` (currently `1.8.1`) pinned on every decision envelope and on each persisted `mandatory_match_decisions` row for audit replay. |
| **`actionable_total`** | API field on `/api/hr/shares` = pending evidence items + pending requirement-fit reviews. Drives the HR dashboard card badge and top-nav bell so a doctor whose evidence is fully verified but who still has an outstanding fit decision remains visible as actionable work. |
| **HR confirming fit chip** | Amber wallet chip shown to the doctor when one of their HR-verified credentials is awaiting an HR requirement-fit decision for a mandatory topic. Disappears the moment HR clicks Satisfies / Does not satisfy. |

---

## 15. Recent milestones (2026)

| Change | Summary |
|--------|---------|
| HR terminology refresh | User-facing **doctor** (not clinician) across HR UI, messages, and API error text |
| Add doctors page | `/static/hr/cohorts/` retitled **Add doctors**; list **Your groups**; on-board copy on dashboard |
| Dashboard HR CTAs | Short action links: Onboard, Open, Review, Add, Manage |
| All Doctors search | Create-cohort step 3: local search + autosuggest when copying from All Doctors |
| Mandatory training requirements | Page and dashboard card renamed from “Mandatory requirements” |
| Add training for doctors | Bulk page title aligned with dashboard card |
| Staff training sort | My training list: A–Z or expiry (soonest first) |
| HR inbox counts | Pending verification badge reconciled with actionable inbox items |
| HR expiry reminders | Profile toggle; automatic in-app messages to doctors (30d / 7d / expired) |
| Personalised getting started | Dashboard suggests unused features only (ESR vs add record, etc.) |
| Oracle Cloud production | Production on Oracle VM only (Docker + Caddy); `docpass.co.uk` — **Render not used** |
| Auth & CORS hardening | Rate limit on login/register; CORS whitelist; session cookie flags |
| Server backup | `deploy/backup.sh` + daily cron |
| HR email notifications | Daily digest + instant share alerts via Resend SMTP |
| Email prefs in Profile | Moved from separate page; old URL redirects |
| `HR_EMAIL_OVERRIDE` | Pilot env var to route all HR emails to one inbox |
| Security headers | Caddy: HSTS, X-Frame-Options, CSP, nosniff, Referrer-Policy |
| Unified notifications bell | Single bell + envelope; HR sees verify inbox in bell preview |
| HR bell simplified | Alerts section removed for HR; bell links to verification inbox |
| Stage 2 compliance matching | Shared matcher, explainable statuses, alias/partial rules |
| Trust-move alignment | Plan-a-move uses same API matcher as requirements |
| Semantic embedding matching | Gemini `gemini-embedding-001` fallback when exact/alias fail; cosine similarity thresholds 0.90 / 0.70; GCP service account auth |
| ESR import evidence storage | Server-side `csv_import_evidence` table; wallet stores `import_evidence_id` — fixes localStorage quota on bulk import |
| ESR needs-fix matching | Exact wallet title match only (removed fuzzy prune that hid valid fix rows) |
| Onboarding checklist | Steps 3–4 swapped: import from ESR before check trust requirements; step 4 links to requirements page |
| HR requirement-fit decisions | HR accepts/rejects uncertain partial and semantic matches; stored decisions override compliance snapshot |
| HR welcome modal | Defaults to send-welcome; **Don't show again** preference saved per user, re-enable from Profile |
| Expired training not sent to HR | Client-side guard (red hint box + disabled Verify-with-HR), server-side filter on `POST /api/me/shares` (400 if everything submitted is expired); portfolio shares unaffected |
| Declined records pinned to top | Doctor's My training surfaces declined items first so they're not buried |
| HR verify auto-refresh | Inbox list and open share session both poll every **15 s** (paused when tab is hidden) |
| Doctor My training auto-refresh | List polls every **30 s** so HR outcomes show without manual reload |
| Fix and reshare modal | Doctor edits module / dates / issuing organisation (with ODS autosuggest) / evidence in place; file-only changes flip the existing HR row back to Pending, signed-detail changes replace it with a corrected one |
| Forgot password flow | `/static/auth/forgot.html` + `/static/auth/reset.html`; SHA-256 hashed 32-byte tokens, 15-min single-use, no enumeration, rate-limited; success state collapses the form and shows "Password changed" |
| Change password in Profile | Current + new + confirm form wired to `POST /api/auth/change-password` |
| Email-OTP MFA (HR demo accounts) | Sign-in step for `MFA_REQUIRED_EMAILS` (default: `sheffieldhr@nhs.net`, `rotherhamhr@nhs.net`): 6-digit code, 10-min expiry, max 5 attempts, optional 30-day trusted device; codes routed through `HR_EMAIL_OVERRIDE` |
| Manual QA checklist | `QA-CHECKLIST.md` — comprehensive role-by-role test script for systematic regression checks |
| Decision engine v1.7 → v1.8.1 | Audit-relevant explanation upgrade: natural-language `decision_reason` (match + validity + framing, no jargon), `decision_reason_short` for doctor surfaces (drops HR-routing sentence), `is_exact_match`, `match_label`, `decision_confidence_label/reason`, contextual REQUIRES_REVIEW framing (no more "not an exact match" contradiction). v1.8 added a +25 hr_verified signal; **v1.8.1 reverted it** — evidence verification and fit confirmation are now strictly separate decisions |
| Doctor surfaces de-cluttered | `/requirements` and plan-move now show only the decision badge + a plain-English why sentence per row. Confidence chip, match label, precedent hint, scoring factors and HR-routing sentence are HR-only |
| HR Requirement fit review on Awaiting decision | Fit-review panel hidden from the Decided tab so the same rows can't appear twice. Session view always opens on Awaiting decision |
| Decided requirement fit reviews section | New read-only history table on the Decided tab listing past Satisfies / Does not satisfy calls (newest first); polled after each decision so a fresh row appears immediately |
| "How this was assessed" audit panel | HR-only collapsible `<details>` on every fit-review row, surfacing structured Matching evidence / Similarity / Scoring factors / Decision summary built from the decision envelope (incl. the `signals` block now forwarded to HR) |
| Wallet "HR confirming fit" chip | Doctor wallet cards show an amber chip when the credential is HR-verified but still pending an HR fit decision for a mandatory topic; backed by `GET /api/me/fit-review-pending-credentials` |
| Fit-decision doctor alerts | Clicking Satisfies / Does not satisfy emits `hr_fit_accepted` / `hr_fit_rejected` notifications to the doctor with deep links to `/requirements` |
| Inbox classification by fit-pending | A doctor stays in HR's **Needs action** until evidence *and* fit reviews are all done. Inbox row carries a new "N awaiting fit review" chip. Dashboard card badge and top-nav bell read the combined `actionable_total` (evidence + fit) so a fully evidence-verified doctor with an outstanding fit decision still surfaces |

---

*End of document — suitable for upload to Microsoft Copilot, GitHub Copilot chat context, or stakeholder sharing.*
