"""
NHS E-Learning Credential Passport — Phase 2 MVP API.
Issuing service, verification endpoint, revoke, and did:web public key.
"""
import os
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, Request, HTTPException, File, UploadFile, Query
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware

from . import crypto
from . import db
from .credential_service import issue_credentials, verify_credential, revoke_credential, get_verification_url_base
from .models import (
    CompletionRecord,
    IssueRequest,
    IssueResponse,
    IssuedCredentialInfo,
    VerifyResponse,
    CsvImportResponse,
    CsvImportInvalidRow,
)
from .csv_import import parse_completion_csv, csv_template_header, MAX_CSV_BYTES

# Base URL for verification links (default for local dev)
BASE_URL = os.environ.get("BASE_URL", "http://localhost:8000")


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
        rec = body.records[i] if i < len(body.records) else None
        info = IssuedCredentialInfo(
            credential_id=r["credential_id"],
            verification_url=r["verification_url"],
            jwt=r["jwt"],
            pdf_base64=r.get("pdf_base64"),
            module_name=rec.module_name if rec else None,
            expiry_date=rec.expiry_date.isoformat() if rec else None,
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


@app.get("/api/credentials/import-csv/template")
def api_csv_template():
    """Download a one-line CSV header template for bulk import."""
    return Response(
        content=csv_template_header(),
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": 'attachment; filename="elearning-import-template.csv"',
            "Cache-Control": "no-store",
        },
    )


@app.post("/api/credentials/import-csv", response_model=CsvImportResponse)
async def api_import_csv(request: Request, file: UploadFile = File(...), dry_run: bool = Query(False)):
    """
    Upload UTF-8 CSV: validate rows, optionally issue all valid rows (dry_run=false).
    See GET .../import-csv/template for column names and aliases (e.g. employee_name).
    """
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

    results = issue_credentials([p.record for p in valid], base)
    credentials_out: list[IssuedCredentialInfo] = []
    for p, r in zip(valid, results):
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

    return CsvImportResponse(
        dry_run=False,
        total_data_rows=len(parsed),
        valid_row_count=len(valid),
        invalid=invalid_rows,
        credentials=credentials_out,
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
        content="<html><body><h1>NHS E-Learning Credential Passport</h1><p><a href='/static/'>Go to app</a></p></body></html>",
        headers={"Cache-Control": "no-cache"},
    )


@app.get("/verifier", response_class=RedirectResponse)
def verifier_redirect():
    return RedirectResponse(url="/static/verifier/", status_code=302)


@app.get("/staff", response_class=RedirectResponse)
def staff_redirect():
    return RedirectResponse(url="/static/staff/", status_code=302)
