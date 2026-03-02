"""
NHS E-Learning Credential Passport — Phase 2 MVP API.
Issuing service, verification endpoint, revoke, and did:web public key.
"""
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware

from . import crypto
from . import db
from .credential_service import issue_credentials, verify_credential, revoke_credential, get_verification_url_base
from .models import CompletionRecord, IssueRequest, IssueResponse, IssuedCredentialInfo, VerifyResponse

# Base URL for verification links (default for local dev)
BASE_URL = os.environ.get("BASE_URL", "http://localhost:8000")


@asynccontextmanager
async def lifespan(app: FastAPI):
    crypto.ensure_keys()
    db.init_db()
    yield


app = FastAPI(
    title="NHS E-Learning Credential Passport",
    description="Phase 2 MVP — issue, verify, revoke credentials",
    lifespan=lifespan,
)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


# ---------- API ----------

@app.post("/api/credentials/issue", response_model=IssueResponse)
def api_issue(request: Request, body: IssueRequest):
    """Issue credentials from completion records. No auth at MVP."""
    base = str(request.base_url).rstrip("/")
    results = issue_credentials(body.records, base)
    return IssueResponse(
        credentials=[
            IssuedCredentialInfo(
                credential_id=r["credential_id"],
                verification_url=r["verification_url"],
                jwt=r["jwt"],
                pdf_base64=r.get("pdf_base64"),
            )
            for r in results
        ]
    )


@app.get("/api/credentials/verify/{credential_id}", response_model=VerifyResponse)
def api_verify(credential_id: str, jwt: str = None):
    """Verify a credential by ID; optionally pass JWT in query (e.g. from QR link)."""
    return verify_credential(credential_id=credential_id, jwt_str=jwt)


@app.post("/api/credentials/revoke/{credential_id}")
def api_revoke(credential_id: str):
    """Revoke a credential. No auth at MVP (in production, holder-only)."""
    if revoke_credential(credential_id):
        return {"ok": True, "credential_id": credential_id}
    raise HTTPException(status_code=404, detail="Credential not found")


# ---------- did:web (public key for verifiers) ----------

@app.get("/.well-known/did.json")
def well_known_did():
    """Public key for did:web — verifiers use this to validate signatures."""
    jwk_dict = crypto.get_public_jwk_dict()
    return {
        "id": crypto.get_issuer_did(BASE_URL),
        "verificationMethod": [{
            "id": f"{crypto.get_issuer_did(BASE_URL)}#key-1",
            "type": "JsonWebKey2020",
            "controller": crypto.get_issuer_did(BASE_URL),
            "publicKeyJwk": jwk_dict,
        }],
    }


# ---------- Static / frontends ----------

# Mount static files (verifier and staff apps)
static_dir = os.path.join(os.path.dirname(__file__), "..", "static")
if os.path.isdir(static_dir):
    app.mount("/static", StaticFiles(directory=static_dir, html=True), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    """Home page — NHS design principles."""
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>NHS E-Learning Credential Passport</title>
      <style>
        :root {
          --nhsuk-text: #212b32;
          --nhsuk-link: #005eb8;
          --nhsuk-link-hover: #003d82;
          --nhsuk-focus: #ffeb3b;
          --nhsuk-body-bg: #f0f4f5;
          --nhsuk-secondary-text: #4c6272;
        }
        * { box-sizing: border-box; }
        body { font-family: Frutiger, 'Frutiger Linotype', Arial, sans-serif; background: var(--nhsuk-body-bg); color: var(--nhsuk-text); line-height: 1.5; margin: 0; min-height: 100vh; }
        .nhsuk-header { background: var(--nhsuk-link); color: #fff; padding: 1rem 0; }
        .nhsuk-header__container { max-width: 960px; margin: 0 auto; padding: 0 1.5rem; }
        .nhsuk-header__logo { display: block; margin-bottom: 0.5rem; }
        .nhsuk-header__title { font-size: 1.5rem; font-weight: 700; margin: 0; }
        .nhsuk-main { max-width: 960px; margin: 0 auto; padding: 2rem 1.5rem; }
        .nhsuk-page-heading { font-size: 2rem; font-weight: 700; margin: 0 0 0.5rem 0; }
        .nhsuk-body-s { color: var(--nhsuk-secondary-text); margin-bottom: 1.5rem; }
        .nhsuk-list { list-style: none; padding: 0; margin: 0; }
        .nhsuk-list li { margin-bottom: 1rem; padding: 1rem; background: #fff; border-left: 4px solid var(--nhsuk-link); }
        .nhsuk-list a { color: var(--nhsuk-link); font-weight: 600; font-size: 1.125rem; text-decoration: none; }
        .nhsuk-list a:hover { color: var(--nhsuk-link-hover); text-decoration: underline; }
        .nhsuk-list a:focus { outline: 3px solid var(--nhsuk-focus); outline-offset: 2px; }
        .nhsuk-list p { margin: 0.25rem 0 0 0; font-size: 0.9375rem; color: var(--nhsuk-secondary-text); font-weight: 400; }
      </style>
    </head>
    <body>
      <header class="nhsuk-header" role="banner">
        <div class="nhsuk-header__container">
          <img src="https://www.sheffieldpartnership.nhs.uk/themes/custom/omega_bigbluedoor/logo.svg" alt="NHS" class="nhsuk-header__logo" width="120" height="51">
          <h1 class="nhsuk-header__title">NHS E-Learning Credential Passport</h1>
        </div>
      </header>
      <main class="nhsuk-main" id="maincontent" role="main">
        <h2 class="nhsuk-page-heading">Welcome</h2>
        <p class="nhsuk-body-s">Share and verify e-learning credentials so staff and Trusts can avoid duplicate training. Phase 2 MVP — no ESR integration yet.</p>
        <ul class="nhsuk-list">
          <li><a href="/static/staff/">Staff app</a><p>View your credentials, add new ones, share by link or QR, download PDF, or revoke.</p></li>
          <li><a href="/static/verifier/">Verify a credential</a><p>Paste a credential ID or verification URL to check it is valid, expired, or revoked.</p></li>
          <li><a href="/.well-known/did.json">Public key (did:web)</a><p>For verifiers: issuer public key for signature verification.</p></li>
        </ul>
        <p class="nhsuk-body-s" style="margin-top:2rem;">Built to the <a href="https://service-manual.nhs.uk/design-system/design-principles" target="_blank" rel="noopener" style="color:var(--nhsuk-link);">NHS design principles</a>.</p>
      </main>
    </body>
    </html>
    """


@app.get("/verifier", response_class=RedirectResponse)
def verifier_redirect():
    return RedirectResponse(url="/static/verifier/", status_code=302)


@app.get("/staff", response_class=RedirectResponse)
def staff_redirect():
    return RedirectResponse(url="/static/staff/", status_code=302)
