# DocPass Manual QA Checklist

Use this as a **pre-release checklist** to systematically verify **functionality** and **user-facing text**.

- Conventions:
  - Each check is written as **Action → Expected behaviour → Expected text**
  - When **Expected text** is quoted, it should match **exactly** (allowing for names/dates to vary).
- Suggested accounts:
  - 1x **Doctor** account at the same trust as HR
  - 1x **HR (premium)** account for that trust

---

## 10-minute smoke test (do this before every deploy)

- [ ] **Doctor: sign in** → reaches dashboard → **Expected text**: “Your dashboard”
- [ ] **Doctor: open profile** (`/static/profile/`) → edit form visible → **Expected text**: “Your profile”, “Full name”, “GMC number”, “Current trust”
- [ ] **Doctor: open My training** (`/static/staff/`) → list loads → **Expected text**: “My training”
- [ ] **Doctor: add one record** (Add training tab) → submit succeeds → record appears in list → **Expected text**: button “Add training”
- [ ] **Doctor: share to HR** (either auto-share after add, or per-card verify button if shown) → record shows “Pending verification” state → **Expected text**: “Pending verification”
- [ ] **HR: open Verify shared training** (`/static/hr/`) → inbox loads → **Expected text**: “Verify shared training”, “Needs action”, “Completed”
- [ ] **HR: open the shared set** → sees “Awaiting decision” view → **Expected text**: “Evidence verification”, “Awaiting decision”, “Verify selected”, “Decline selected”
- [ ] **HR: verify the record** → record moves to Decided/Verified → **Expected text**: “Verified”
- [ ] **Doctor: confirm update** → within 30s, record updates to Verified state (polling) → **Expected text**: “Verified”

---

## Authentication & account basics

### Sign-in / sign-out

- [ ] **Sign in with valid credentials** → session starts → arrives at dashboard
- [ ] **Sign out** (Menu → Sign out) → session cleared → cannot access `/static/dashboard/` without signing in

### Register (should be disabled)

- [ ] **Attempt self-service signup** (if UI route exists in this deployment) → blocked → **Expected text**: “Accounts are created by your HR team.”

### Change password

- [ ] **Change password** → can sign in with new password; old password fails

---

## Dashboard (`static/dashboard/index.html`)

- [ ] **Open dashboard** (`/static/dashboard/`) → loads → **Expected text**: “Your dashboard”
- [ ] **Menu** → opens panel with links → **Expected text**: “Menu”, “Dashboard”, “Profile”, “Sign out”

### Doctor cards (spot-check links)

- [ ] **My training** card → goes to `/static/staff/`
- [ ] **Import from ESR** card → goes to `/static/staff/#import`
- [ ] **My trust requirements** card → goes to `/static/requirements/` (note: this route may live outside this folder)
- [ ] **Moving trust** card → goes to `/static/plan-move/` (note: may live outside this folder)
- [ ] **Messages** card → goes to `/static/messages/` (note: may live outside this folder)
- [ ] **Alerts** card → goes to `/static/notifications/` (note: may live outside this folder)

### HR cards (premium only)

- [ ] **Premium gating** (non-premium) → **Expected text**: “This page is only for HR accounts.”
- [ ] **Verify shared training** → `/static/hr/`
- [ ] **Add or remove doctors** → `/static/hr/cohorts/`
- [ ] **Add training for doctors** → `/static/hr/bulk.html`
- [ ] **Mandatory training requirements** → `/static/hr/mandatory/`
- [ ] **Expiring training** → `/static/hr/expiring.html`
- [ ] **Messages** → `/static/hr/messages/`
- [ ] **Message templates** → `/static/hr/welcome-templates.html`
- [ ] **Search doctors and groups** → `/static/hr/cohorts/?search=1`
- [ ] **Audit log** → `/static/hr/audit.html` (note: may live outside this folder)

---

## Profile (`static/profile/index.html`)

- [ ] **Open profile** → loads → **Expected text**: “Your profile”
- [ ] **Core fields present** → **Expected text**: “Full name”, “GMC number”, “Current trust”
- [ ] **Current trust autosuggest** → typing shows suggestions → selecting fills a canonical trust name

### HR-only section: welcome defaults

- [ ] **HR sees welcome section** → **Expected text**: “Default welcome message for new group members”
- [ ] **Toggle present** → **Expected text**: “Review welcome message before sending”
- [ ] **Toggle description** → **Expected text**: “When adding doctors, show a preview to confirm or edit before sending. Leave unchecked to send your default welcome automatically.”

### HR-only section: email notifications (`#email-notifications`)

- [ ] **Open `/static/profile/#email-notifications`** → scrolls to Email notifications → **Expected text**: “Email notifications”
- [ ] **Fields present** → **Expected text**: “Send notifications to”, “Daily summary”, “Instant alert”, “Automatic expiry reminders”
- [ ] **Lead paragraph** → **Expected text**: “Get verification inbox and message alerts by email so you do not have to check DocPass every day.”

### Doctor-only section: visibility controls

- [ ] **Visibility section shows for doctors** → **Expected text**: “Who can see my verified training?”
- [ ] **Radio options present** → **Expected text**:
  - “Trusts I’ve messaged”
  - “My current trust only”
  - “Specific trusts I choose”
  - “All HR users”
- [ ] **Allowlist UI** (when “Specific trusts I choose” selected) → add/remove trust tags works → **Expected text**: “Allowed trusts”, button “Add”

---

## Doctor: My training (`static/staff/index.html`)

### Global expectations

- [ ] **Tabs present** → **Expected text**: “My training”, “Import from ESR”, “Add training”, “Moving trust”, “Export”
- [ ] **Auto-refresh** → page updates without manual reload (polling) roughly every 30 seconds when visible

### List: filters + sorting

- [ ] **Search training** filter works (typing narrows list) → **Expected text**: placeholder “Module name…”
- [ ] **Filter by status** dropdown works → includes Declined/Expired/etc
- [ ] **Sort by** works (A–Z / Expiry)
- [ ] **Declined on top** when showing All training (Declined cards appear first)

### Card states (spot-check)

- [ ] **Valid record** shows **Expected text**: “In Date”
- [ ] **Expiring record** shows **Expected text**: “Expiring soon”
- [ ] **Expired record** shows **Expected text**: “EXPIRED”
- [ ] **Pending share** shows **Expected text**: “Pending verification”
- [ ] **Verified** shows **Expected text**: “Verified”
- [ ] **Declined** shows **Expected text**: “DECLINED” and a red info box

### Expired records: do not send to HR

- [ ] **Expired record shows hint box** → **Expected text**: “Expired training isn't sent to HR. Tap Renew to log a new completion — that will be shared with HR automatically.”
- [ ] **Verify with HR is disabled** on expired record (if button is visible) → tooltip indicates renew required

### Renew

- [ ] **Renew button appears** for expiring/expired records
- [ ] **Renew** opens renewal flow (doctor can log a new completion)

### Fix and reshare (declined flow)

- [ ] **Declined record shows helper text** → **Expected text**: “HR declined this record.”
- [ ] **Declined helper text** → **Expected text**: “Use Fix and reshare to update the evidence or any details (module, dates, issuing trust).”
- [ ] **Fix and reshare button** opens modal

#### Fix-and-reshare modal

- [ ] **Modal title** → **Expected text**: “Fix and reshare with HR”
- [ ] **Intro line** → **Expected text**: “Update anything HR flagged — evidence, module, dates, or issuing trust — then re-share.”
- [ ] **Decline reason appears** when present → **Expected text**: “HR’s reason for declining:”
- [ ] **Fields present** → **Expected labels**:
  - “Module”
  - “Competency title” (when module is “Other”)
  - “Completion date”
  - “Expiry date”
  - “Issuing organisation”
  - “Issuing organisation ODS code”
  - “Replacement certificate or evidence”
- [ ] **Issuing organisation autosuggest** works inside modal → suggestions appear; selecting fills ODS code
- [ ] **Submit** → closes modal on success → **Expected text**: button “Re-share with HR”

### Export tab

- [ ] **Export tab lists only HR-verified rows** (no pending/declined)
- [ ] **Download selected PDFs (ZIP)** works
- [ ] **Download all PDFs (ZIP)** works

---

## Doctor: ESR import (`static/staff/index.html#import`)

- [ ] **Wizard loads** → can proceed through steps with Back/Next
- [ ] **Upload CSV** accepts file; analysis step shows mapping hints
- [ ] **Upload evidence** accepts PDF/PNG/JPG/WEBP
- [ ] **Import into my wallet** completes → results summary shown
- [ ] **Expired imported items are NOT sent to HR for verification** (they may remain in wallet but should not create HR inbox rows)

---

## HR: Verify shared training (`static/hr/index.html`)

### Premium gating

- [ ] **Non-premium user** → blocked → **Expected text**: “This page is only for HR accounts.”

### Inbox view

- [ ] **Heading** → **Expected text**: “Verify shared training”
- [ ] **Lead** → **Expected text**: “Review training sent by doctors and mark records as verified or declined.”
- [ ] **Tabs** → **Expected text**: “Needs action”, “Completed”
- [ ] **Filters** present → **Expected text**: “Module”, “Record status”
- [ ] **Table columns** → **Expected text**: “Doctor”, “Received”, “Records”
- [ ] **Auto-refresh** inbox every ~15 seconds (when visible; not mid-action)

### Session view

- [ ] **Back button** → **Expected text**: “← Back to inbox”
- [ ] **Tabs** → **Expected text**: “Awaiting decision”, “Decided”
- [ ] **Bulk bar** appears when selecting rows → **Expected text**: “Verify selected”, “Decline selected”
- [ ] **Decline requires reason** (where prompted) → reason appears for doctor in declined panel
- [ ] **Unverify available** under Decided → sends record back for review
- [ ] **Evidence modal** opens for evidence view → **Expected text**: “Evidence”, button “Close”

### Requirement fit review

- [ ] **Requirement fit review section** appears only for verified items (not pending/declined)
- [ ] **Fit decisions** can be recorded (satisfies / does not satisfy) and persist on reload

---

## HR: Cohorts / Groups (`static/hr/cohorts/index.html`)

### Premium gating

- [ ] **Non-premium user** → blocked → **Expected text**: “This page is only for HR accounts.”

### Group list

- [ ] **Heading** → **Expected text**: “All Groups”
- [ ] **Default group exists** → “All Doctors”
- [ ] **Create group** flow works; group appears in list

### Add doctors

- [ ] **Heading in detail view** → **Expected text**: “Add or remove doctors”
- [ ] **Add manually** → can add one doctor (personal email, full name, GMC) and save
- [ ] **Upload spreadsheet** → can upload CSV/Excel and preview parsed rows
- [ ] **Welcome options inline**:
  - checkbox **Expected text**: “Don’t send a welcome message”
  - section **Expected text**: “Customise welcome message”

### Welcome review modal (when enabled)

- [ ] **Modal title** → **Expected text**: “Review welcome message”
- [ ] **Buttons present** → **Expected text**: “Edit message”, “Don’t send welcome”, “Send welcome”, “Use template”

### Compliance + members

- [ ] **Compliance tab** shows topic matrix and allows CSV export
- [ ] **Members tab** allows removing selected and removing all; delete accounts where available

### Cohort verification banner

- [ ] **Pending verification banner** links to HR verify inbox → CTA link targets `/static/hr/`
- [ ] **Banner text** should not imply manual sharing is required now that auto-share exists

---

## HR: Bulk add training (`static/hr/bulk.html`)

### Premium gating

- [ ] **Non-premium user** → blocked → **Expected text**: “This page is only for HR accounts.”

### Wizard

- [ ] **Heading** → **Expected text**: “Add training for doctors”
- [ ] **Start modes work**:
  - Search for doctors
  - Use a group
  - Upload roster file
- [ ] **Training details fields present** → **Expected text**: “Module”, “Completion date”, “Expiry date”, “Issuing Trust name”, “Issuing Trust ODS code”
- [ ] **Shared evidence** (optional) is applied to all rows where appropriate
- [ ] **Result summary** accurately reports issued/skipped/errors

---

## HR: Mandatory requirements (`static/hr/mandatory/index.html`)

### Premium gating

- [ ] **Non-premium user** → blocked → **Expected text**: “This page is only for HR accounts.”

### Manage topics

- [ ] **Heading** → **Expected text**: “Mandatory training requirements”
- [ ] **Seed trust pack** (where offered) works once; does not re-seed duplicates
- [ ] **Add topic** works; fields persist after reload
- [ ] **Edit topic** works; Cancel returns to view mode
- [ ] **Delete topic** works
- [ ] **Reorder** topics persists (if UI supports drag / reorder controls)

---

## HR: Messages (`static/hr/messages/index.html`)

- [ ] **Heading** → **Expected text**: “Messages”
- [ ] **Search** finds doctors/groups
- [ ] **Open thread** loads message history
- [ ] **Send** sends a message; appears in thread; doctor receives it
- [ ] **Broadcast** to selected recipients works (if enabled)
- [ ] **Templates**: can use a template; can save/update/delete in library

---

## HR: Expiring training (`static/hr/expiring.html`)

- [ ] **Heading** → **Expected text**: “Expiring training”
- [ ] **Filters** work (window, module/topic, cohort)
- [ ] **Send reminders** works (when available) and results in doctor notifications/messages

---

## HR: Message templates (`static/hr/welcome-templates.html`)

- [ ] **Heading** → **Expected text**: “Message templates”
- [ ] **Create template** works (Name + Message)
- [ ] **Edit template** loads into form; update persists
- [ ] **Delete template** removes it from list

---

## Verifier / public verification

Note: verifier pages may live outside this folder in the parent repo, but should be tested in the deployed app.

- [ ] **Credential verify endpoint** (`/api/credentials/verify/{credential_id}`) returns expected status (VALID / EXPIRED / REVOKED / UNVERIFIED)
- [ ] **DID document** (`/.well-known/did.json`) returns issuer public keys (JWK)
- [ ] **Bundle link** (`/api/public/verifier-link/{token}`) renders training bundle in verifier UI; revoked links return 410

---

## Cross-cutting copy spot-checks (high-signal strings)

Tick these after any copy/UX change.

- [ ] HR inbox lead: “Review training sent by doctors and mark records as verified or declined.”
- [ ] HR inbox tabs: “Needs action” / “Completed”
- [ ] Staff Fix-and-reshare modal title: “Fix and reshare with HR”
- [ ] Staff Fix-and-reshare intro: “Update anything HR flagged — evidence, module, dates, or issuing trust — then re-share.”
- [ ] Expired hint: “Expired training isn't sent to HR. Tap Renew to log a new completion — that will be shared with HR automatically.”
- [ ] Profile toggle: “Review welcome message before sending”
- [ ] Premium gating: “This page is only for HR accounts.”

---

## Notes on routes that may live outside this folder

This repository appears to be deployed as part of a larger tree (`WalkingWR/static/`). In some deployments, these routes are used but their HTML lives elsewhere:

- `/static/index.html` (landing)
- `/static/auth/` (sign-in, onboarding)
- `/static/verifier/` and `/static/verifier/bundle.html`
- `/static/plan-move/`
- `/static/requirements/`
- `/static/messages/` (doctor)
- `/static/notifications/` (doctor)
- `/static/hr/audit.html`

If your deployment includes these routes, add/keep a checklist section for them here.

---

## Maintenance rules

- Keep this file updated in the **same change** as any feature/copy change.
- If a UI text string changes, update the **quoted** “Expected text” entries above so regressions are easy to catch.
- If a bug fix affects a workflow, add a specific regression checkbox under the relevant section.

