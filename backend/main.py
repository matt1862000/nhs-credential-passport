"""
NHS Training Passport — Phase 2 MVP API.
Issuing service, verification endpoint, revoke, and did:web public key.
"""
import os
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, Request, HTTPException, File, UploadFile, Query
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

from . import crypto
from . import db
from .credential_service import (
    issue_credentials,
    verify_credential,
    revoke_credential,
    get_verification_url_base,
    wallet_dedupe_keys,
)
from .models import (
    CompletionRecord,
    IssueRequest,
    IssueResponse,
    IssuedCredentialInfo,
    VerifyResponse,
    CsvImportResponse,
    CsvImportInvalidRow,
)
from .csv_import import (
    parse_completion_csv,
    csv_template_header,
    MAX_CSV_BYTES,
    MAX_CSV_EVIDENCE_BYTES,
)
from .auth_api import router as auth_router, require_user_id

# Base URL for verification links (default for local dev)
BASE_URL = os.environ.get("BASE_URL", "http://localhost:8000")


def _normalize_evidence_content_type(content_type: Optional[str], filename: Optional[str]) -> Optional[str]:
    ct = (content_type or "").split(";")[0].strip().lower()
    if ct in ("image/jpeg", "image/png", "image/webp", "application/pdf"):
        return ct
    fn = (filename or "").lower()
    if fn.endswith(".pdf"):
        return "application/pdf"
    if fn.endswith(".png"):
        return "image/png"
    if fn.endswith(".jpg") or fn.endswith(".jpeg"):
        return "image/jpeg"
    if fn.endswith(".webp"):
        return "image/webp"
    return None


def _decode_csv_bytes(raw: bytes) -> Optional[str]:
    """ESR exports are often Windows-1252; browsers use UTF-8."""
    for enc in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return None


@asynccontextmanager
async def lifespan(app: FastAPI):
    crypto.ensure_keys()
    db.init_db()
    yield


app = FastAPI(
    title="NHS Training Passport",
    description="Phase 2 MVP — issue, verify, revoke credentials",
    lifespan=lifespan,
)
# Trust X-Forwarded-* from Render/nginx so request.url uses public https host (fixes share / verify links).
app.add_middleware(ProxyHeadersMiddleware, trusted_hosts="*")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.include_router(auth_router)


# ---------- API ----------

@app.post("/api/credentials/issue", response_model=IssueResponse)
def api_issue(request: Request, body: IssueRequest):
    """Issue credentials from completion records. Requires a signed-in account."""
    uid = require_user_id(request)
    base = str(request.base_url).rstrip("/")
    wallet_raw = db.user_wallet_get(uid)
    existing_keys = wallet_dedupe_keys(wallet_raw)
    results, skipped = issue_credentials(body.records, base, skip_duplicate_keys=existing_keys)
    credentials_out = []
    cert_used = False
    for i, r in enumerate(results):
        if r is None:
            continue
        rec = body.records[i] if i < len(body.records) else None
        info = IssuedCredentialInfo(
            credential_id=r["credential_id"],
            verification_url=r["verification_url"],
            jwt=r["jwt"],
            pdf_base64=r.get("pdf_base64"),
            module_name=rec.module_name if rec else None,
            expiry_date=rec.expiry_date.isoformat() if rec else None,
        )
        if not cert_used and body.certificate_base64:
            info.certificate_base64 = body.certificate_base64
            info.certificate_filename = body.certificate_filename or "certificate"
            cert_used = True
        credentials_out.append(info)
    return IssueResponse(credentials=credentials_out, skipped_duplicate_count=skipped)


@app.get("/api/credentials/verify/{credential_id}", response_model=VerifyResponse)
def api_verify(credential_id: str, jwt: str = None):
    """Verify a credential by ID; optionally pass JWT in query (e.g. from QR link)."""
    return verify_credential(credential_id=credential_id, jwt_str=jwt)


@app.post("/api/credentials/revoke/{credential_id}")
def api_revoke(request: Request, credential_id: str):
    """Revoke a credential. Requires a signed-in account."""
    require_user_id(request)
    if revoke_credential(credential_id):
        return {"ok": True, "credential_id": credential_id}
    raise HTTPException(status_code=404, detail="Credential not found")


@app.get("/api/credentials/import-csv/template")
def api_csv_template(request: Request):
    """Download a one-line CSV header template for bulk import (signed-in users only)."""
    require_user_id(request)
    return Response(
        content=csv_template_header(),
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": 'attachment; filename="elearning-import-template.csv"',
            "Cache-Control": "no-store",
        },
    )


@app.post("/api/credentials/import-csv", response_model=CsvImportResponse)
async def api_import_csv(
    request: Request,
    file: UploadFile = File(...),
    evidence: Optional[UploadFile] = File(None),
    dry_run: bool = Query(False),
):
    """
    Upload UTF-8 CSV: validate rows, optionally issue all valid rows (dry_run=false).
    When dry_run=false and there is at least one valid row, an evidence file is required
    (e.g. ESR Compliance screenshot or PDF). See GET .../import-csv/template for column names.
    """
    uid = require_user_id(request)
    raw = await file.read()
    if len(raw) > MAX_CSV_BYTES:
        raise HTTPException(status_code=413, detail="CSV file too large")
    text = _decode_csv_bytes(raw)
    if text is None:
        raise HTTPException(status_code=400, detail="CSV encoding not recognised (try UTF-8 or Windows-1252)")

    parsed, fatal = parse_completion_csv(text)
    if fatal:
        return CsvImportResponse(dry_run=dry_run, fatal_error=fatal)

    invalid_rows = [CsvImportInvalidRow(row=p.row_number, message=p.error) for p in parsed if p.error]
    valid = [p for p in parsed if p.record is not None]
    base = str(request.base_url).rstrip("/")

    if dry_run:
        return CsvImportResponse(
            dry_run=True,
            total_data_rows=len(parsed),
            valid_row_count=len(valid),
            invalid=invalid_rows,
        )

    if not valid:
        return CsvImportResponse(
            dry_run=False,
            total_data_rows=len(parsed),
            valid_row_count=0,
            invalid=invalid_rows,
        )

    ev_bytes: Optional[bytes] = None
    ev_name = ""
    ev_ct = ""
    if evidence is None or not (evidence.filename or "").strip():
        raise HTTPException(
            status_code=400,
            detail="Evidence file required — upload a screenshot or PDF of your training record (e.g. ESR Compliance).",
        )
    ev_raw = await evidence.read()
    if len(ev_raw) > MAX_CSV_EVIDENCE_BYTES:
        raise HTTPException(status_code=413, detail="Evidence file too large (max 10 MB)")
    ev_ct_norm = _normalize_evidence_content_type(evidence.content_type, evidence.filename)
    if not ev_ct_norm:
        raise HTTPException(
            status_code=400,
            detail="Evidence must be a PDF or image (JPEG, PNG, or WebP).",
        )
    ev_bytes = ev_raw
    ev_name = (evidence.filename or "evidence").strip()
    ev_ct = ev_ct_norm

    # One JSON with dozens of PDFs exceeds typical proxy timeouts; skip PDFs for multi-row CSV.
    include_pdf = len(valid) <= 1
    wallet_raw = db.user_wallet_get(uid)
    existing_keys = wallet_dedupe_keys(wallet_raw)
    results, skipped_dups = issue_credentials(
        [p.record for p in valid],
        base,
        include_pdf=include_pdf,
        skip_duplicate_keys=existing_keys,
    )
    credentials_out: list[IssuedCredentialInfo] = []
    for p, r in zip(valid, results):
        if r is None:
            continue
        rec = p.record
        assert rec is not None
        credentials_out.append(
            IssuedCredentialInfo(
                credential_id=r["credential_id"],
                verification_url=r["verification_url"],
                jwt=r["jwt"],
                pdf_base64=r.get("pdf_base64"),
                module_name=rec.module_name,
                expiry_date=rec.expiry_date.isoformat(),
            )
        )

    issued_count = len(credentials_out)
    if ev_bytes is not None:
        try:
            db.csv_import_evidence_save(
                uid,
                ev_name,
                ev_ct,
                ev_bytes,
                credentials_issued=issued_count,
            )
        except Exception:
            # Do not fail the import if audit storage fails
            pass

    return CsvImportResponse(
        dry_run=False,
        total_data_rows=len(parsed),
        valid_row_count=len(valid),
        invalid=invalid_rows,
        credentials=credentials_out,
        skipped_duplicate_count=skipped_dups,
    )


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
        content="<html><body><h1>NHS Training Passport</h1><p><a href='/static/'>Go to app</a></p></body></html>",
        headers={"Cache-Control": "no-cache"},
    )


@app.get("/verifier", response_class=RedirectResponse)
def verifier_redirect():
    return RedirectResponse(url="/static/verifier/", status_code=302)


@app.get("/staff", response_class=RedirectResponse)
def staff_redirect():
    return RedirectResponse(url="/static/staff/", status_code=302)


@app.get("/dashboard", response_class=RedirectResponse)
def dashboard_redirect():
    return RedirectResponse(url="/static/dashboard/", status_code=302)


@app.get("/profile", response_class=RedirectResponse)
def profile_redirect():
    return RedirectResponse(url="/static/profile/", status_code=302)


@app.get("/auth", response_class=RedirectResponse)
def auth_redirect():
    return RedirectResponse(url="/static/auth/", status_code=302)


@app.get("/sign-in", response_class=RedirectResponse)
def sign_in_redirect():
    return RedirectResponse(url="/static/auth/?mode=signin", status_code=302)


@app.get("/register", response_class=RedirectResponse)
def register_redirect():
    return RedirectResponse(url="/static/auth/?mode=register", status_code=302)


@app.get("/plan-move", response_class=RedirectResponse)
def plan_move_redirect():
    return RedirectResponse(url="/static/plan-move/", status_code=302)
