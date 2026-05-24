# DocPass — product overview (shareable reference)

> **Purpose of this document:** Single reference for Copilot, stakeholders, or new contributors.  
> **Last updated:** May 2026 (HR copy refresh, Add doctors page, dashboard CTAs, All Doctors search)  
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
4. **Doctor shares** records with current-trust HR for verification (auto-share when profile is complete)
5. **HR** reviews in verification inbox → marks each record **Verified**, **Declined** (with reason), or later **Unverified**
6. **Doctor** sees outcomes via alerts, can download verified PDFs, compare against trust mandatory requirements (with explainable matching), and plan a move to a new trust’s checklist pack
7. **HR and doctor** can message each other in-app
8. **HR** (optional) receives email when doctors share for verification, or a daily inbox summary

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
4. **None** — no plausible match  

Trust topics and pack JSON can also store `match_module_codes`, `match_name_substrings`, `partial_module_codes`, `partial_name_substrings`, and `partial_hint`.

### Output per topic (API + UI)

| Field | Example |
|-------|---------|
| `status_label` | Met (exact match), Met (possible match), Needs review, Expired, No match |
| `match_type` | `exact`, `alias`, `partial`, `none` |
| `confidence_score` | 1.0 / 0.8 / 0.5 / 0 |
| `confidence_label` | high / medium / low |
| `reason` | Human-readable explanation (e.g. “Matched by alias: Fire Awareness → Fire Safety”) |
| `portability` | `portable` (CSTF in category), `conditional` (trust policy), `local_only` (Local in category) |
| `status` (legacy) | `met`, `expiring`, `gap` — used for summary counts and cohort rollups |

### Summary counts

- **met** — exact or alias match, in date (includes “possible match”)  
- **expiring** — matched but expiring within 90 days  
- **gap** — no match, expired, or needs review  
- **needs_review** — partial matches only (subset of gap)  

---

## 5. Features for doctors

### 5.1 Dashboard (`/static/dashboard/`)

- Training summary stats: in date, expiring (90 days), expired, total
- Trust requirements compliance banner (gaps, needs review, expiring)
- Getting-started guide (profile, add training, share with HR, etc.) with **personalised “what to explore next”** suggestions (unused features only; up to 4 cards)
- Quick links to all doctor tools

### 5.2 Training wallet (`/static/staff/`)

- **View my training** — list with expiry status and HR verification state; sort **A–Z** or by **expiry date** (soonest first)
- **Add a record** — manual entry; optional certificate upload
- **Import from ESR** — bulk import from ESR export file
- **Filters** — e.g. not shared with HR, pending, verified, declined
- **Share with HR** — send records for verification; bulk “share all not yet shared”
- **Auto-share** — new records auto-submitted when profile is complete
- **Renew / reshare** — option to reshare after adding a renewal record
- **Download verified PDFs** — ZIP export of HR-verified evidence only
- **Revoke** credentials where applicable

### 5.3 HR verification (doctor side)

- Share individual or multiple records to trust HR inbox
- Track status per record: **not shared → pending → verified / declined**
- **Portfolio / reference pack** share mode for already-verified records when moving trusts

### 5.4 Trust requirements (`/static/requirements/`)

- Loads **`/api/me/compliance-snapshot`** (server wallet — not client-side matching)
- Colour-coded status labels with **reason** text and portability/confidence badges
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

### 5.7 Messages (`/static/messages/`)

- Direct messaging with trust HR
- Can start conversations with supported trusts
- Unread badge on envelope icon in header

### 5.8 Profile (`/static/profile/`)

- Display name, GMC, current trust
- **Visibility settings** (doctors only) — who can see verified training
- **HR:** default welcome message template for new cohort members
- **HR:** email notification preferences (daily digest + instant share alerts) — see §6.11
- **HR:** automatic expiry reminders toggle (in-app messages to doctors at 30 days, 7 days, and after expiry)
- Profile completeness gates auto-share and some flows

### 5.9 Verifiable credentials & PDF export

- Each completion can be issued as a signed JWT (W3C-style VC) + PDF with QR for **download within DocPass** (verified training export)
- Signing uses RS256 and `did:web` (`/.well-known/did.json`) — infrastructure for issued credentials, not a public-facing verifier UI
- **No public verifier portal** — external parties do not verify credentials via a standalone DocPass page in the pilot

---

## 6. Features for HR / trust accounts

HR accounts see **Trust tools** on the dashboard instead of the doctor wallet. Card titles use full labels; bottom **action links** are shortened (e.g. **Onboard**, **Open**, **Review**, **Add**, **Manage**).

### 6.1 Verify shared training (`/static/hr/`)

- Inbox of **shared sets** from doctors grouped by doctor
- Filter: needs action / completed; by module; by record status
- Per-record actions: **Verify**, **Decline** (with reason), **Unverify**
- Bulk verify / bulk decline within a set
- Header **bell** — hover preview shows **Training to verify** only; badge = pending verification count

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
| **Signing keys** | `/var/lib/docpass/keys/` |
| **Daily HR digest cron** | `/var/lib/docpass/send-hr-digest.sh` (optional) |

### Security (pilot hardening)

| Control | Implementation |
|---------|----------------|
| **HTTPS** | Caddy automatic TLS (Let’s Encrypt) |
| **Security headers** | Caddy on `docpass.co.uk` and `www.docpass.co.uk`: HSTS, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, CSP, `Referrer-Policy` |
| **CORS** | Whitelist (`docpass.co.uk`, `BASE_URL`, localhost) — no `*` |
| **Rate limiting** | `slowapi` — 10/min on login and register |
| **Session cookies** | httponly, secure, SameSite=Lax |
| **Backup** | `deploy/backup.sh` + daily cron (3am) |

**CSP note:** Current policy uses `'unsafe-inline'` for scripts/styles (inline HTML). OWASP ZAP may flag this at Medium — acceptable for pilot; tightening requires refactoring static pages.

### Key backend modules

| Module | Role |
|--------|------|
| `backend/main.py` | FastAPI app, static files, DID endpoint, CORS, rate limit |
| `backend/auth_api.py` | Auth, wallet, HR, messaging, notifications, compliance APIs |
| `backend/db.py` | SQLite schema and data access |
| `backend/credential_service.py` | Issue/revoke credentials |
| `backend/mandatory_matching.py` | **Shared** topic ↔ wallet matcher (exact, alias, partial) |
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
| `HR_EMAIL_OVERRIDE` | Optional — route all HR emails to one address (pilot) |

See `deploy/email.env.example` for a template.

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
| `/static/auth/` | All | Sign in / register |
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
- Rate limited: login and register (10/min per IP)

### Doctor wallet & sharing
- `GET /me/wallet`, `PUT /me/wallet`, `GET /me/verified-map`
- `POST /me/shares`, `POST /me/shares/withdraw`
- Instant HR email triggered on share for verification (background task)

### Compliance & requirements
- `GET /me/trust-requirements` — mandatory topic list for current trust
- `GET /me/compliance-snapshot` — **enriched** topic vs wallet match (all Stage 2 fields)
- `GET /me/trust-move/checklist-preview?pack_id=sheffield` — destination pack vs wallet (same matcher)
- `GET /me/trust-move/candidates`, `POST /me/trust-move/complete`

### Notifications (doctors only)
- `GET /me/notifications`, `GET /me/notifications/unread-count`
- `POST /me/notifications/{id}/read`, `POST /me/notifications/read-all`

### HR verification
- `GET /hr/shares`, `GET /hr/shares/{session_id}`
- `POST /hr/shares/{session_id}/items/{credential_id}/verify|decline|unverify`

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
- **Explainable checklist comparison** against trust/destination requirements  
- **Portability hints** (CSTF vs local topics)  
- **CSTF-style** mandatory topic matching (not claiming official CSTF compliance)

---

## 13. What DocPass does not do (yet / by design)

- Live ESR API integration  
- National NHS identity (CIS2, NHSmail SSO, etc.)  
- Push notifications or email alerts **for doctors** (in-app only)  
- HR in-app alert notifications (HR bell = verification inbox only)  
- **Public verifier portal** or HR **verifier links** for third parties (removed from pilot scope)  
- Canonical national module registry / ML fuzzy matching (alias map + hints only)  
- Strict CSP without `'unsafe-inline'` (would require frontend refactor)  
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
| **Premium account** | HR/trust user |
| **Cohort / group** | Named group of on-boarded doctors for bulk HR actions (UI: **Your groups** on Add doctors page) |
| **StatMand** | NHS England Statutory and Mandatory Training programme |
| **Portfolio / reference pack** | Share of already HR-verified records when moving trusts |
| **Daily digest** | Scheduled email summarising HR pending verifications and unread messages |

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

---

*End of document — suitable for upload to Microsoft Copilot, GitHub Copilot chat context, or stakeholder sharing.*
