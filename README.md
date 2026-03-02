# NHS E-Learning Credential Passport — Phase 2 MVP

From-idea-to-pilot build: **issue**, **verify**, and **revoke** e-learning credentials with no ESR integration. Uses W3C-style Verifiable Credentials (signed JWT) and did:web for the public key.

## What’s in this repo

- **Credential schema** — W3C-aligned claims (staff name, NHS/ESR ID, CSTF module, completion/expiry, issuing Trust).
- **Issuing service** — POST completion records → signed JWT + verification URL + PDF (with QR).
- **Verifier portal** — Paste credential ID or full verification URL → VALID / EXPIRED / REVOKED / UNVERIFIED.
- **Staff web app** — Add credentials (manual form), see list, share (link + QR + PDF), revoke, expiry dashboard.
- **did:web** — `/.well-known/did.json` exposes the issuer public key for signature verification.

---

## Run locally

```bash
cd nhs-credential-passport
python3 -m venv venv
source venv/bin/activate   # Windows: venv\Scripts\activate
pip install -r backend/requirements.txt
uvicorn backend.main:app --reload --host 0.0.0.0 --port 8000
```

Or use the run script: `./run.sh` (uses `PORT` from env if set).

Then open:

- **Staff app:** http://localhost:8000/static/staff/
- **Verifier:** http://localhost:8000/static/verifier/
- **API docs:** http://localhost:8000/docs
- **Public key:** http://localhost:8000/.well-known/did.json

---

## Deploy as a real web app (live URL, no local machine needed)

### Option A — Render (free tier, no card required)

1. **Push this project to GitHub**  
   Either push the whole repo or create a new repo that contains only the `nhs-credential-passport` folder (so the repo root is this folder).

2. **Create a Web Service on Render**  
   - Go to [dashboard.render.com](https://dashboard.render.com) → **New** → **Web Service**.  
   - Connect your GitHub and select the repo (and set **Root Directory** to `nhs-credential-passport` if this app lives in a subfolder).  
   - **Build & deploy:**  
     - **Environment:** Docker.  
     - Render will use the `Dockerfile` in the repo (or in the root directory you set).  
   - **Start command** is already in the Dockerfile; no need to set it.  
   - Click **Create Web Service**.

3. **Set BASE_URL after first deploy**  
   - Once the service is live, copy the URL (e.g. `https://nhs-credential-passport-xxxx.onrender.com`).  
   - In the service → **Environment** → add:  
     - **KEY:** `BASE_URL`  
     - **VALUE:** `https://nhs-credential-passport-xxxx.onrender.com` (your actual URL, no trailing slash).  
   - Save; Render will redeploy. Verification links and did:web will then use the correct public URL.

4. **Optional: use Blueprint**  
   If your repo root is this folder, you can use **New** → **Blueprint** and point to the `render.yaml` in the repo so the service is created from that file. You still need to set `BASE_URL` in the dashboard after the first deploy.

### Option B — Docker (any host or cloud)

```bash
cd nhs-credential-passport
docker build -t nhs-credential-passport .
docker run -p 8000:8000 -e BASE_URL=https://your-domain.com nhs-credential-passport
```

For persistent keys and database across restarts:

```bash
docker compose up --build
```

Then set `BASE_URL` in the environment or in `docker-compose.yml` to your public URL when you put it behind a domain/HTTPS.

---

## Environment variables

| Variable    | Description |
|------------|-------------|
| `BASE_URL` | Public URL of the app (no trailing slash). Required in production so verification links and did:web work. |
| `PORT`     | Port to listen on. Set automatically by Render; default 8000 for local/Docker. |

See `.env.example`; copy to `.env` for local overrides (do not commit `.env`).

---

## Flow

1. **Staff** — In the staff app, add a completion record (name, ID, module, dates, Trust). Submit to issue a credential. It appears in “My credentials” with Share (link/QR) and Download PDF. You can revoke any credential.
2. **Verifier** — In the verifier, paste the credential ID or the full verification link. The app shows VALID (green), EXPIRED (amber), REVOKED (red), or UNVERIFIED (grey). Valid/Expired responses include the decoded claims when a JWT is provided.

## Tech

- **Backend:** FastAPI, SQLite (credential registry: id, revoked, expiry), RS256 JWT (python-jose), ReportLab + qrcode for PDF.
- **Frontend:** Vanilla HTML/JS; staff app uses localStorage for “my credentials” (no login at MVP).

## Security (MVP)

- No authentication on issue/revoke (demo only).
- Private key is stored under `keys/` (or in a Docker volume); do not commit or expose.
- Verification is public; only minimal data is stored in the registry (no full PII).

## Next (Phase 3)

- ESR CSV import and bulk issue.
- ESR API integration.
- Pilot with real Trusts and evaluation report.
