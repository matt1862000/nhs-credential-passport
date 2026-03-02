"""
NHS E-Learning Credential Passport — Phase 2 MVP API.
Issuing service, verification endpoint, revoke, and did:web public key.
"""
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, FileResponse
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
    """Issue credentials from completion records. No auth at MVP. Optional certificate upload."""
    base = str(request.base_url).rstrip("/")
    results = issue_credentials(body.records, base)
    credentials_out = []
    for i, r in enumerate(results):
        info = IssuedCredentialInfo(
            credential_id=r["credential_id"],
            verification_url=r["verification_url"],
            jwt=r["jwt"],
            pdf_base64=r.get("pdf_base64"),
        )
        if i == 0 and body.certificate_base64:
            info.certificate_base64 = body.certificate_base64
            info.certificate_filename = body.certificate_filename or "certificate"
        credentials_out.append(info)
    return IssueResponse(credentials=credentials_out)


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
index_html_path = os.path.join(static_dir, "index.html")
if os.path.isdir(static_dir):
    app.mount("/static", StaticFiles(directory=static_dir, html=True), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    """Home page — NHS design principles. Served from static/index.html so design is always applied."""
    if os.path.isfile(index_html_path):
        with open(index_html_path, encoding="utf-8") as f:
            return HTMLResponse(content=f.read(), headers={"Cache-Control": "no-cache, no-store, must-revalidate"})
    # Fallback if file missing (e.g. in tests)
    return HTMLResponse(
        content="<html><body><h1>NHS E-Learning Credential Passport</h1><p><a href='/static/'>Go to app</a></p></body></html>",
        headers={"Cache-Control": "no-cache"},
    )


@app.get("/verifier", response_class=RedirectResponse)
def verifier_redirect():
    return RedirectResponse(url="/static/verifier/", status_code=302)


@app.get("/staff", response_class=RedirectResponse)
def staff_redirect():
    return RedirectResponse(url="/static/staff/", status_code=302)
